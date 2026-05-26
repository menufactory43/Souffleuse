import AppKit
import Foundation

/// Host-specific metrics derived from an OCR observation of the focused
/// text field. When supplied to `CaretEstimator.estimateRect`, these
/// override the default font / padding / line-height heuristics so the
/// estimated caret rect tracks the real glyph layout in apps like Brave
/// where AX refuses to report per-character bounds.
///
/// `fontPointSize` is clamped to the same `[10, 64]` range used elsewhere
/// (see `OverlayWindow.estimatedFont(forCaretRectHeight:)`) so a bogus
/// reading can't produce a giant or sub-readable ghost.
public struct CalibratedMetrics: Sendable, Equatable {
    public let fontPointSize: CGFloat
    public let leftPadding: CGFloat
    public let lineHeight: CGFloat

    public init(fontPointSize: CGFloat, leftPadding: CGFloat, lineHeight: CGFloat) {
        self.fontPointSize = min(max(fontPointSize, 10), 64)
        self.leftPadding = max(0, leftPadding)
        // Always at least as tall as the font itself; otherwise multi-line
        // wraps would stack on top of each other.
        self.lineHeight = max(lineHeight, self.fontPointSize)
    }
}

/// Computes an approximate caret rect from the AX-reported field bounds
/// (`elementRect`) and text + caret index, for hosts that refuse to expose
/// `kAXBoundsForRangeParameterizedAttribute` for web content (Chromium-based
/// browsers, contenteditable, some Electron surfaces).
///
/// The estimate uses:
/// - the field's pixel bounds (top-left + width),
/// - the text content up to the caret,
/// - a font hint (when AX exposed one — rare in browsers) or a sane default
///   (~14pt system, the prevailing default for chat composers and inputs),
/// - a soft-wrap simulation breaking on whitespace at `elementRect.width`.
///
/// Output is intentionally a best-effort approximation: pixel-perfect would
/// require either OCR or a host-specific bridge. The goal is to put the ghost
/// "close enough" that the user reads it as part of their text, instead of
/// hiding it entirely.
public enum CaretEstimator {
    /// Inset from the field's outer rect to where text actually starts.
    /// Browser inputs and chat composers typically sit at 4–10 px; 6 is a
    /// solid mid-value that errs slightly toward the field interior (so the
    /// ghost never sticks out at the left edge).
    public static let defaultPadding: CGFloat = 6

    /// Default font when neither AX nor the caller can hint at the host font.
    /// 14pt system covers most modern chat composers and form inputs. Computed
    /// (not stored) because `NSFont` isn't `Sendable` and would block use from
    /// non-main-actor contexts otherwise.
    public static func defaultFont() -> NSFont { .systemFont(ofSize: 14) }

    /// Multiplier from font size to line height. The system text stack uses
    /// ~1.2; web stylesheets often use 1.4–1.6. We pick 1.4 as a compromise
    /// that errs a hair toward the next line — under-estimating would land
    /// the ghost ON the typed text, which is the bug we're trying to avoid.
    public static let lineHeightMultiplier: CGFloat = 1.4

    /// Compute the estimated caret rect in Quartz (top-left origin) screen
    /// coordinates. Returns nil when inputs are degenerate.
    ///
    /// - Parameters:
    ///   - elementRect: AX-reported field bounds (Quartz coords).
    ///   - text: full text content of the field.
    ///   - caretIndex: caret position as a UTF-16 / UnicodeScalar offset
    ///     into `text` (matches what AX exposes).
    ///   - font: optional font hint. When nil, uses `defaultFont`.
    public static func estimateRect(
        in elementRect: CGRect,
        text: String,
        caretIndex: Int,
        font: NSFont? = nil
    ) -> CGRect? {
        estimateRect(
            in: elementRect,
            text: text,
            caretIndex: caretIndex,
            font: font,
            metrics: nil
        )
    }

    /// Metric-aware overload. When `metrics` is non-nil its font size,
    /// left-padding and line-height replace the defaults; the caller (the
    /// OCR-driven calibration path) is responsible for providing values that
    /// reflect the actual host layout.
    public static func estimateRect(
        in elementRect: CGRect,
        text: String,
        caretIndex: Int,
        font: NSFont?,
        metrics: CalibratedMetrics?
    ) -> CGRect? {
        guard elementRect.width > 0, elementRect.height > 0 else { return nil }
        guard caretIndex >= 0, caretIndex <= text.count else { return nil }

        let renderFont: NSFont
        let lineHeight: CGFloat
        let padding: CGFloat
        if let metrics {
            // Prefer the host's family when AX gave us one; the calibrated
            // font size still wins because OCR measures the actual rendered
            // glyphs while AX often lies about size in web fields.
            if let baseFamily = font?.familyName,
               let calibrated = NSFont(name: baseFamily, size: metrics.fontPointSize) {
                renderFont = calibrated
            } else {
                renderFont = .systemFont(ofSize: metrics.fontPointSize)
            }
            lineHeight = metrics.lineHeight
            padding = metrics.leftPadding
        } else {
            renderFont = font ?? defaultFont()
            lineHeight = ceil(renderFont.pointSize * lineHeightMultiplier)
            padding = defaultPadding
        }
        let availableWidth = max(1, elementRect.width - 2 * padding)

        let endIdx = text.index(text.startIndex, offsetBy: caretIndex)
        let prefix = String(text[..<endIdx])

        // First: split on hard newlines. Each `\n` is an explicit line break
        // that no width calculation can override.
        let hardLines = prefix.components(separatedBy: "\n")
        // Soft-wrap every hard line except the last (since the last is where
        // the caret currently is). Accumulate the visual-line count and the
        // text remaining on the caret's visual line.
        var visualLineCount = 0
        var caretLineText = ""
        for (i, hardLine) in hardLines.enumerated() {
            let isLastHardLine = (i == hardLines.count - 1)
            let wrapResult = softWrap(hardLine, width: availableWidth, font: renderFont)
            if isLastHardLine {
                visualLineCount += wrapResult.fullLineCount
                caretLineText = wrapResult.lastLine
            } else {
                // Whole hard line is "consumed" — count every visual line in it.
                visualLineCount += wrapResult.fullLineCount + 1
            }
        }

        let measuredWidth = (caretLineText as NSString)
            .size(withAttributes: [.font: renderFont])
            .width

        let caretX = elementRect.minX + padding + measuredWidth
        let caretY = elementRect.minY + padding + CGFloat(visualLineCount) * lineHeight

        // Clamp inside the field so a runaway estimate doesn't fly off-screen
        // (e.g. very long single-word lines that wouldn't actually wrap).
        let clampedX = min(max(caretX, elementRect.minX + padding), elementRect.maxX - 1)
        let clampedY = min(max(caretY, elementRect.minY), elementRect.maxY - lineHeight)

        return CGRect(x: clampedX, y: clampedY, width: 1, height: lineHeight)
    }

    /// Simulates greedy whitespace soft-wrap inside `width`. Returns:
    /// - `fullLineCount`: number of *complete* wrapped lines BEFORE the final
    ///   partial line (zero-based; 0 means the text fits on one visual line).
    /// - `lastLine`: text remaining on the trailing visual line — the one the
    ///   caret currently sits on (when this hard line is the caret's).
    ///
    /// We split on space only; long single-token strings overflow `width`
    /// (matching browser default behaviour for unbroken tokens without CSS
    /// `word-break`). The output `lastLine` includes any single token that
    /// alone exceeds `width` so the caller can still measure it.
    static func softWrap(_ line: String, width: CGFloat, font: NSFont) -> (fullLineCount: Int, lastLine: String) {
        if line.isEmpty { return (0, "") }
        // Tokenise on space but keep the space separators so reconstructed
        // segments measure the same as the source text.
        let tokens = tokenise(line)
        var currentLine = ""
        var fullLineCount = 0
        for token in tokens {
            let candidate = currentLine + token
            let candidateWidth = (candidate as NSString).size(withAttributes: [.font: font]).width
            if candidateWidth <= width || currentLine.isEmpty {
                currentLine = candidate
            } else {
                // Wrap before this token.
                fullLineCount += 1
                // Don't carry over leading whitespace onto the new visual line.
                currentLine = String(token.drop(while: { $0 == " " }))
            }
        }
        return (fullLineCount, currentLine)
    }

    /// Split a line into "words and the spaces that follow them" so we can
    /// reconstruct the line by concatenation without losing trailing spaces.
    /// e.g. `"foo bar  baz"` → `["foo ", "bar  ", "baz"]`.
    static func tokenise(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inWord = false
        for ch in line {
            if ch == " " {
                current.append(ch)
                inWord = false
            } else {
                if !inWord && !current.isEmpty && current.last == " " {
                    // Flush the run of spaces + previous word as one token.
                    tokens.append(current)
                    current = ""
                }
                current.append(ch)
                inWord = true
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
