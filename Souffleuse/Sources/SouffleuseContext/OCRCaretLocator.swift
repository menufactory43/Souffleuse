import AppKit
import CoreGraphics
import Foundation
import SouffleuseLog
import SouffleuseOverlay
import Vision

/// Pixel-precise caret position recovered by reading the focused field's
/// content back from the rendered pixels via Vision OCR. Used as a slow
/// fallback (50-300 ms) when AX refuses to expose per-character bounds —
/// the common case in Chromium-based browsers and many Electron apps.
public struct OCRCaretResult: Sendable, Equatable {
    /// Caret rect in Quartz (top-left origin) screen coordinates.
    public let caretRect: CGRect
    /// Layout metrics inferred from the OCR observations — replayed by
    /// `CaretEstimator` to keep the ghost glued to the caret on subsequent
    /// frames without re-running OCR.
    public let calibratedMetrics: CalibratedMetrics

    public init(caretRect: CGRect, calibratedMetrics: CalibratedMetrics) {
        self.caretRect = caretRect
        self.calibratedMetrics = calibratedMetrics
    }
}

/// Type the implementation has access to without leaking SouffleuseOverlay
/// types here. Mirrors `CalibratedMetrics` exactly; the resolver translates
/// at the boundary. Kept internal to this module's surface so tests can mock
/// the locator without depending on AppKit-side types.
public protocol OCRCaretLocating: Sendable {
    /// Returns the caret rect derived from OCR-ing `elementRect` on screen,
    /// or nil if the screen could not be captured, OCR yielded nothing
    /// useful, or the prefix `text[0..<caretIndex]` could not be aligned
    /// with the OCR observations.
    func locate(
        elementRect: CGRect,
        bundleID: String,
        text: String,
        caretIndex: Int
    ) async -> OCRCaretResult?
}

public actor OCRCaretLocator: OCRCaretLocating {
    /// Vision needs the accurate recogniser to honour per-character
    /// `boundingBox(for:)` queries; the fast recogniser collapses to
    /// whole-line bounding boxes.
    private let capturer: ScreenCapturer
    private let languages: [String]

    public init(
        capturer: ScreenCapturer = ScreenCapturer(),
        languages: [String] = ["fr-FR", "en-US"]
    ) {
        self.capturer = capturer
        self.languages = languages
    }

    public func locate(
        elementRect: CGRect,
        bundleID: String,
        text: String,
        caretIndex: Int
    ) async -> OCRCaretResult? {
        guard elementRect.width > 0, elementRect.height > 0 else { return nil }
        guard caretIndex > 0 else {
            // Caret at index 0: there's no text to align against. Fall back
            // to the estimator's defaults plus the field's top-left.
            return nil
        }
        // Sanity guard: if AX reports a field that fills most of the screen
        // (Brave occasionally returns the document rect instead of the
        // focused input), cropping to it gives back the whole document and
        // the matcher locks onto conversation history. Bail out — the
        // estimator with defaults is better than a confidently-wrong OCR.
        if elementRect.width > 1400 || elementRect.height > 600 {
            Log.warn(.context, "ocr_caret_element_too_large")
            return nil
        }
        guard ScreenCapturer.hasPermission() else { return nil }

        let capture: ScreenCapture
        do {
            capture = try await capturer.capture(bundleID: bundleID)
        } catch {
            Log.warn(.context, "ocr_caret_capture_failed")
            return nil
        }

        // Crop the captured image to just the field's pixels. Without this
        // the OCR sees the whole page (including conversation history above
        // a chat composer) and the matcher can lock onto whichever text
        // happens to share a prefix with the user's input — landing the
        // ghost far from the actual caret.
        let imageWidth = CGFloat(capture.image.width)
        let imageHeight = CGFloat(capture.image.height)
        guard imageWidth > 0, imageHeight > 0 else { return nil }
        guard capture.windowFrame.width > 0, capture.windowFrame.height > 0 else { return nil }

        let scale = imageWidth / capture.windowFrame.width
        let cropImgX = (elementRect.minX - capture.windowFrame.minX) * scale
        let cropImgY = (elementRect.minY - capture.windowFrame.minY) * scale
        let cropImgW = elementRect.width * scale
        let cropImgH = elementRect.height * scale
        // Clamp inside the captured image — elementRect may extend slightly
        // past the window's frame (subpixel rounding, or a field that
        // hangs off the visible area).
        let safeCrop = CGRect(
            x: max(0, cropImgX),
            y: max(0, cropImgY),
            width: min(imageWidth - max(0, cropImgX), cropImgW),
            height: min(imageHeight - max(0, cropImgY), cropImgH)
        )
        guard safeCrop.width > 4, safeCrop.height > 4,
              let cropped = capture.image.cropping(to: safeCrop)
        else {
            Log.warn(.context, "ocr_caret_crop_failed")
            return nil
        }

        // We flatten inside the Vision callback so the VN observation
        // objects (which aren't Sendable) never cross the continuation.
        // Vision normalises to the *cropped* image, so the projection uses
        // `elementRect` as the screen-space frame.
        let chars: [OCRChar]
        do {
            chars = try await Self.recogniseAndFlatten(
                image: cropped,
                languages: languages,
                captureImageSize: CGSize(width: safeCrop.width, height: safeCrop.height),
                windowFrame: elementRect
            )
        } catch {
            Log.warn(.context, "ocr_caret_recognise_failed")
            return nil
        }
        guard !chars.isEmpty else { return nil }

        guard let matched = Self.match(text: text, caretIndex: caretIndex, ocrChars: chars) else {
            return nil
        }

        return OCRCaretResult(
            caretRect: matched.caretRect,
            calibratedMetrics: matched.metrics
        )
    }

    // MARK: - Vision dispatch

    /// Bridges the callback-based VN API into async/await. Always resumes
    /// the continuation exactly once. The flattening step runs inside the
    /// Vision callback so the (non-`Sendable`) `VNRecognizedTextObservation`
    /// instances never escape the callback's thread.
    private static func recogniseAndFlatten(
        image: CGImage,
        languages: [String],
        captureImageSize: CGSize,
        windowFrame: CGRect
    ) async throws -> [OCRChar] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[OCRChar], Error>) in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                let results = (request.results as? [VNRecognizedTextObservation]) ?? []
                let chars = flatten(
                    observations: results,
                    captureImageSize: captureImageSize,
                    windowFrame: windowFrame
                )
                cont.resume(returning: chars)
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = languages
            request.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    // MARK: - Observation flattening

    /// Per-character record used by the matching pass. `rect` is in Quartz
    /// (top-left origin) screen coordinates; `lineIndex` lets the matcher
    /// recognise newlines without re-deriving line geometry.
    struct OCRChar: Sendable {
        let char: Character
        let rect: CGRect
        let lineIndex: Int
    }

    /// Walks every observation in reading order and emits one `OCRChar` per
    /// recognised glyph. Vision's `boundingBox(for:)` accepts a substring of
    /// the candidate's `string`; failures (empty box, range refused) drop
    /// the character.
    static func flatten(
        observations: [VNRecognizedTextObservation],
        captureImageSize: CGSize,
        windowFrame: CGRect
    ) -> [OCRChar] {
        // Sort top-to-bottom (Vision's Y is bottom-up, so larger midY ≡
        // higher on screen) then left-to-right.
        let sorted = observations.sorted { lhs, rhs in
            // Same line if their normalised midY is within half their height.
            let dy = abs(lhs.boundingBox.midY - rhs.boundingBox.midY)
            let avgH = (lhs.boundingBox.height + rhs.boundingBox.height) * 0.5
            if dy < avgH * 0.5 {
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            return lhs.boundingBox.midY > rhs.boundingBox.midY
        }

        var out: [OCRChar] = []
        var lastMidY: CGFloat = .greatestFiniteMagnitude
        var lineIndex = -1

        for obs in sorted {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let lineString = candidate.string
            if lineString.isEmpty { continue }

            let midY = obs.boundingBox.midY
            let avgH = obs.boundingBox.height
            if abs(midY - lastMidY) > avgH * 0.5 {
                lineIndex += 1
                lastMidY = midY
            }

            var idx = lineString.startIndex
            while idx < lineString.endIndex {
                let nextIdx = lineString.index(after: idx)
                let charRange = idx..<nextIdx
                let visionRect: CGRect
                if let box = try? candidate.boundingBox(for: charRange)?.boundingBox {
                    visionRect = box
                } else {
                    idx = nextIdx
                    continue
                }
                let screenRect = projectVisionRectToScreen(
                    visionRect,
                    captureImageSize: captureImageSize,
                    windowFrame: windowFrame
                )
                guard screenRect.width > 0, screenRect.height > 0 else {
                    idx = nextIdx
                    continue
                }
                let ch = lineString[idx]
                out.append(OCRChar(char: ch, rect: screenRect, lineIndex: lineIndex))
                idx = nextIdx
            }
        }
        return out
    }

    /// Map a Vision-normalised rect (origin bottom-left, 0..1) into the
    /// window-relative pixel rect, then translate it by the window's screen
    /// frame to get Quartz top-left screen coordinates.
    ///
    /// Vision normalises against the input image — our `captureImageSize`
    /// matches `windowFrame`'s aspect ratio because `ScreenCapturer`
    /// preserves it, so we can use `windowFrame` for the X/Y scale directly.
    static func projectVisionRectToScreen(
        _ vision: CGRect,
        captureImageSize: CGSize,
        windowFrame: CGRect
    ) -> CGRect {
        _ = captureImageSize  // unused; kept in the signature so callers
                              // pass the image they OCR'd, not a guess.
        let xScreen = windowFrame.minX + vision.minX * windowFrame.width
        let widthScreen = vision.width * windowFrame.width
        let heightScreen = vision.height * windowFrame.height
        // Vision: y=0 is the bottom. Quartz screen coords: y=0 is the top.
        // Flip relative to the window.
        let yFromTopNormalised = 1.0 - (vision.minY + vision.height)
        let yScreen = windowFrame.minY + yFromTopNormalised * windowFrame.height
        return CGRect(x: xScreen, y: yScreen, width: widthScreen, height: heightScreen)
    }

    // MARK: - Matching

    /// Result of the alignment pass.
    struct MatchResult {
        let caretRect: CGRect
        let metrics: CalibratedMetrics
    }

    /// Walks `text[0..<caretIndex]` in parallel with the OCR character
    /// stream. The match is intentionally lenient — OCR mis-reads (1↔l,
    /// O↔0, etc.) and whitespace collapsing are common; aborting on the
    /// first mismatch would lose the caret every other frame.
    static func match(
        text: String,
        caretIndex: Int,
        ocrChars: [OCRChar]
    ) -> MatchResult? {
        let prefix = String(text.prefix(caretIndex))
        // Walk the AX prefix and the OCR list with two cursors. We allow:
        //   - skipping OCR whitespace runs (Vision frequently flattens
        //     "    " to a single space or drops them entirely),
        //   - skipping one OCR char on mismatch (lookahead 1),
        //   - skipping AX whitespace when the OCR list has no whitespace
        //     anywhere on the current line.
        let axChars = Array(prefix)
        guard !axChars.isEmpty else { return nil }

        var ax = 0
        var oc = 0
        var lastMatched: OCRChar? = nil

        while ax < axChars.count, oc < ocrChars.count {
            let a = axChars[ax]
            let o = ocrChars[oc]

            if a == "\n" {
                // Skip ahead to the first OCR char on a later line.
                let currentLine = lastMatched?.lineIndex ?? o.lineIndex
                var j = oc
                while j < ocrChars.count, ocrChars[j].lineIndex <= currentLine {
                    j += 1
                }
                if j >= ocrChars.count { break }
                oc = j
                ax += 1
                continue
            }

            if a.isWhitespace {
                // If the OCR char is also whitespace, eat both. Otherwise
                // assume Vision dropped it and only advance the AX pointer.
                if o.char.isWhitespace {
                    lastMatched = o
                    oc += 1
                }
                ax += 1
                continue
            }

            if charsRoughlyEqual(a, o.char) {
                lastMatched = o
                ax += 1
                oc += 1
                continue
            }

            // Mismatch: try a small lookahead window (3 OCR chars) before
            // giving up. Real-world OCR insertions are usually noise glyphs
            // mid-line; skipping them keeps the alignment alive.
            var found = false
            let lookahead = min(3, ocrChars.count - oc - 1)
            if lookahead > 0 {
                for k in 1...lookahead {
                    if charsRoughlyEqual(a, ocrChars[oc + k].char) {
                        oc += k
                        lastMatched = ocrChars[oc]
                        ax += 1
                        oc += 1
                        found = true
                        break
                    }
                }
            }
            if !found {
                // Skip the AX char too — we'd rather drift a few pixels than
                // abandon the whole match. The final caret rect uses the
                // last reliable match anyway.
                ax += 1
            }
        }

        guard let anchor = lastMatched else { return nil }

        // Caret sits at the right edge of the last matched OCR glyph,
        // vertically aligned with that glyph's line.
        let caretX = anchor.rect.maxX
        let caretY = anchor.rect.minY
        let caretHeight = anchor.rect.height
        let caretRect = CGRect(x: caretX, y: caretY, width: 1, height: caretHeight)

        let metrics = inferMetrics(ocrChars: ocrChars, anchor: anchor)
        return MatchResult(caretRect: caretRect, metrics: metrics)
    }

    /// Loose char comparison: case-folding, plus a few of the high-frequency
    /// OCR confusions. We deliberately don't normalise diacritics — getting
    /// "résumé" vs "resume" wrong is rarer than getting "0" vs "O" wrong,
    /// and the lookahead skip handles isolated mismatches anyway.
    private static func charsRoughlyEqual(_ a: Character, _ b: Character) -> Bool {
        if a == b { return true }
        let aLower = String(a).lowercased()
        let bLower = String(b).lowercased()
        if aLower == bLower { return true }
        let pairs: [(Character, Character)] = [
            ("0", "O"), ("0", "o"),
            ("1", "l"), ("1", "I"),
            ("5", "S"), ("5", "s"),
            ("8", "B"),
            ("|", "l"), ("|", "I"),
        ]
        for (x, y) in pairs {
            if (a == x && b == y) || (a == y && b == x) { return true }
            let aL = Character(String(a).lowercased())
            let bL = Character(String(b).lowercased())
            if (aL == x && bL == y) || (aL == y && bL == x) { return true }
        }
        return false
    }

    /// Derives `(fontPointSize, leftPadding, lineHeight)` from the OCR
    /// observations. Heuristics:
    ///   - fontPointSize ≈ median rect height ÷ 1.4. Vision's per-glyph
    ///     bounding box spans the typographic line (ascender + descender +
    ///     line padding), not the cap height — so the raw box height is
    ///     roughly the line-height of the rendered text, which is ~1.4×
    ///     the font's point size in the CSS defaults used by most web hosts.
    ///   - leftPadding ≈ smallest `minX - elementRect.minX` across all rects on the first line.
    ///   - lineHeight ≈ median Δy between consecutive line baselines, or
    ///     1.4× font size if only one line was observed.
    private static func inferMetrics(ocrChars: [OCRChar], anchor: OCRChar) -> CalibratedMetrics {
        let heights = ocrChars.map { $0.rect.height }.sorted()
        let rawMedianHeight = heights.isEmpty ? 19.6 : heights[heights.count / 2]
        let fontPointSize = rawMedianHeight / 1.4

        // Group by line, then look at the leftmost glyph on each line and
        // pick the smallest minX as the left padding anchor.
        var lines: [Int: [OCRChar]] = [:]
        for c in ocrChars { lines[c.lineIndex, default: []].append(c) }
        let lineStarts = lines.values.compactMap { $0.min(by: { $0.rect.minX < $1.rect.minX })?.rect.minX }
        let anchorLineMinX = lineStarts.min() ?? anchor.rect.minX
        // Padding measured from the leftmost observation back to itself
        // (we don't have the field origin here). Resolver supplies that
        // delta. We surface 4 px as a sensible default fallback.
        _ = anchorLineMinX
        let leftPadding: CGFloat = 4

        let sortedLineYs = lines.values
            .compactMap { $0.first?.rect.minY }
            .sorted()
        let lineHeight: CGFloat
        if sortedLineYs.count >= 2 {
            var deltas: [CGFloat] = []
            for i in 1..<sortedLineYs.count {
                let d = abs(sortedLineYs[i] - sortedLineYs[i - 1])
                if d > 0 { deltas.append(d) }
            }
            deltas.sort()
            lineHeight = deltas.isEmpty ? fontPointSize * 1.4 : deltas[deltas.count / 2]
        } else {
            lineHeight = fontPointSize * 1.4
        }

        return CalibratedMetrics(
            fontPointSize: fontPointSize,
            leftPadding: leftPadding,
            lineHeight: lineHeight
        )
    }
}
