import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public struct EnrichedContext: Sendable, Equatable {
    public let app: String?
    public let windowTitle: String?
    public let clipboard: String?
    public let visible: String?

    /// Caps per source — kept short on purpose. Cotypist-style: a 1B base model
    /// can't integrate 500-char blocks intelligently, and labelled blocks make
    /// the model imitate the label syntax in its output.
    public static let clipboardCap = 200
    public static let visibleCap = 240

    public init(app: String?, windowTitle: String?, clipboard: String?, visible: String?) {
        self.app = app
        self.windowTitle = windowTitle
        self.clipboard = clipboard
        self.visible = visible
    }

    /// Compact inline prose. No `[Label:]` syntax — those make a base model
    /// imitate the structure. Returns "" if no signal at all.
    public var prefix: String {
        var bits: [String] = []
        if let app, !app.isEmpty {
            if let title = windowTitle, !title.isEmpty {
                bits.append("App \(app), window \"\(title)\".")
            } else {
                bits.append("App \(app).")
            }
        }
        if let clipboard, !clipboard.isEmpty {
            bits.append("Clipboard: \(truncate(clipboard, to: Self.clipboardCap)).")
        }
        if let visible, !visible.isEmpty {
            bits.append("On screen: \(truncate(visible, to: Self.visibleCap)).")
        }
        guard !bits.isEmpty else { return "" }
        return bits.joined(separator: " ") + "\n\n"
    }

    private func truncate(_ s: String, to cap: Int) -> String {
        s.count <= cap ? s : String(s.prefix(cap)) + "…"
    }
}

/// Assembles AppContext + Clipboard + ScreenCapture+OCR into a single
/// prompt prefix. Cached per bundleID with a TTL, invalidated on focus
/// change or explicit reset.
public actor ContextEnricher {
    public static let ttl: TimeInterval = 5.0

    public var captureEnabled: Bool

    private let appProbe: AppContextProbe
    private let clipboard: ClipboardReader
    private let capturer: ScreenCapturer
    private let ocr: VisionOCR

    private struct CacheEntry {
        let timestamp: Date
        let visible: String?
    }
    private var visibleCache: [String: CacheEntry] = [:]
    private var capturing: Bool = false

    public func isCapturing() -> Bool { capturing }

    public init(
        appProbe: AppContextProbe = AppContextProbe(),
        clipboard: ClipboardReader = ClipboardReader(blocklist: ClipboardReader.mergedBlocklist()),
        capturer: ScreenCapturer = ScreenCapturer(),
        ocr: VisionOCR = VisionOCR(),
        captureEnabled: Bool = false
    ) {
        self.appProbe = appProbe
        self.clipboard = clipboard
        self.capturer = capturer
        self.ocr = ocr
        self.captureEnabled = captureEnabled
    }

    public func setCaptureEnabled(_ enabled: Bool) {
        captureEnabled = enabled
        if !enabled { visibleCache.removeAll() }
    }

    public func setOCRLanguages(_ langs: [String]) async {
        await ocr.setLanguages(langs)
        visibleCache.removeAll()
    }

    public func invalidate() {
        visibleCache.removeAll()
    }

    /// Build the enriched context for the current frontmost app.
    /// Cheap on cache hits (no capture, no OCR). `focusedFieldRect` (Quartz
    /// screen coords) tells the OCR layer which region to mask — usually the
    /// focused text field, whose content the LLM already gets verbatim via AX
    /// and shouldn't be duplicated in the visible context.
    public func snapshot(focusedFieldRect: CGRect? = nil) async -> EnrichedContext {
        let ctx = appProbe.snapshot()
        let clip = await clipboard.read(frontmostBundleID: ctx.bundleID)

        var visible: String? = nil
        if captureEnabled, let bid = ctx.bundleID, ScreenCapturer.hasPermission() {
            visible = await visibleFor(bundleID: bid, focusedFieldRect: focusedFieldRect)
        }

        return EnrichedContext(
            app: ctx.promptAppName == "-" ? nil : ctx.promptAppName,
            windowTitle: ctx.cleanedWindowTitle,
            clipboard: clip,
            visible: visible
        )
    }

    private func visibleFor(bundleID: String, focusedFieldRect: CGRect?) async -> String? {
        // The cache key intentionally ignores the field rect — caching is per
        // (bundle, TTL). If the user jumps between fields inside the same app
        // within `ttl`, they'll get a slightly stale visible context. Worth
        // the simplicity.
        if let entry = visibleCache[bundleID],
           Date().timeIntervalSince(entry.timestamp) < Self.ttl {
            return entry.visible
        }
        capturing = true
        defer { capturing = false }
        let text: String?
        var ocrError: String? = nil
        var includeRectScreen: CGRect? = nil
        do {
            let capture = try await capturer.capture(bundleID: bundleID)
            Self.debugDumpCapture(bundleID: bundleID, image: capture.image)
            let exclude = focusedFieldRect.flatMap { Self.projectToVisionNormalised($0, window: capture.windowFrame) }
            // Region-of-interest: anchor an "above-the-focused-field" rectangle
            // so the conversation pane wins the 240-char visible budget against
            // browser chrome (tabs, URL bar, bookmarks) and side panels. Skipped
            // when no focused field rect is available (Chromium AX fallback
            // failure) — falls back to full-window OCR.
            includeRectScreen = focusedFieldRect.flatMap {
                Self.aboveFocusedFieldIncludeRect(focused: $0, window: capture.windowFrame)
            }
            let include = includeRectScreen.flatMap {
                Self.projectToVisionNormalised($0, window: capture.windowFrame)
            }
            let extracted = try await ocr.extract(
                from: capture.image,
                excludeNormalised: exclude,
                includeNormalised: include
            )
            // Strip Intercom-style meta-events ("Attribution : Workflow",
            // "Vous avez mis la conversation en pause", Fin automated steps)
            // before caching so the 240-char visible budget the LLM actually
            // sees is dominated by customer text rather than UI metadata.
            let cleaned = VisibleTextCleaner.clean(extracted)
            text = cleaned.isEmpty ? nil : cleaned
        } catch {
            text = nil
            ocrError = String(describing: error)
        }
        visibleCache[bundleID] = CacheEntry(timestamp: Date(), visible: text)
        Self.debugDumpVisible(
            bundleID: bundleID,
            text: text,
            error: ocrError,
            hasExclude: focusedFieldRect != nil,
            includeRect: includeRectScreen
        )
        return text
    }

    /// Builds an "above-the-focused-field" region of interest in screen
    /// coordinates (Quartz, top-left origin) used to filter Vision observations
    /// to the conversation pane. Heuristic:
    ///   - Horizontal span = focused field width expanded by 100px on each side
    ///     (message bubbles are typically slightly wider than the input)
    ///   - Top = window top + 60px (skips browser chrome / title bar — 60px
    ///     covers Brave/Chrome/Safari title+URL+bookmarks within tolerance and
    ///     a native macOS title bar fits in 28px so it's also safe)
    ///   - Bottom = focused field top - 10px (small gap so the bottom edge of
    ///     a message bubble doesn't get clipped)
    ///
    /// Both axes are clamped to the window frame. Returns nil if the resulting
    /// rect is degenerate (zero or negative height/width).
    static func aboveFocusedFieldIncludeRect(focused: CGRect, window: CGRect) -> CGRect? {
        // 120px clears Brave/Chrome tab bar (≈35) + URL bar (≈30) + bookmarks
        // bar (≈35) + a 20px safety margin. Native macOS apps lose at most
        // their title bar (28px) + a slice of toolbar — acceptable trade-off
        // since their critical content (Mail message body, Notes content) sits
        // well below 120px in the window. The 2026-05-28 OCR diagnostic
        // session validated this with chromeSkip=60 leaking bookmark labels
        // ("TAX-1436", "Clockify", "Bitcoin Addres") into the first 240 chars
        // — the visible budget the LLM actually sees.
        let chromeSkip: CGFloat = 120
        let bottomGap: CGFloat = 10
        let sideMargin: CGFloat = 100
        let top = max(window.minY + chromeSkip, window.minY)
        let bottom = min(focused.minY - bottomGap, window.maxY)
        guard bottom > top else { return nil }
        let left = max(focused.minX - sideMargin, window.minX)
        let right = min(focused.maxX + sideMargin, window.maxX)
        guard right > left else { return nil }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// Opt-in capture dump for live triage of WHICH window region OCR sees.
    /// Gated on `SOUFFLEUSE_PREDICT_LOG`. Writes PNG to `/tmp/souffleuse-capture-<sanitisedBundle>-<ts>.png`
    /// so we can eyeball whether ScreenCapturer is framing the conversation
    /// pane or the sidebar/chrome. Capped to one file per (bundle, second)
    /// to avoid flooding /tmp during prolonged sessions.
    private static func debugDumpCapture(bundleID: String, image: CGImage) {
        guard ProcessInfo.processInfo.environment["SOUFFLEUSE_PREDICT_LOG"]?.isEmpty == false else { return }
        let ts = Int(Date().timeIntervalSince1970)
        let safeBundle = bundleID.replacingOccurrences(of: "/", with: "_")
        let path = "/tmp/souffleuse-capture-\(safeBundle)-\(ts).png"
        let url = URL(fileURLWithPath: path)
        // Skip if a file already exists for this (bundle, second).
        if FileManager.default.fileExists(atPath: path) { return }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    /// Opt-in OCR dump for live triage of what Vision actually returns. Gated
    /// on `SOUFFLEUSE_PREDICT_LOG`. Writes to `/tmp/souffleuse-ocr.log` so the
    /// existing predict-log convention is preserved (never used in production,
    /// never enabled by default, /tmp is acceptable for active debug).
    private static func debugDumpVisible(
        bundleID: String,
        text: String?,
        error: String?,
        hasExclude: Bool,
        includeRect: CGRect?
    ) {
        guard ProcessInfo.processInfo.environment["SOUFFLEUSE_PREDICT_LOG"]?.isEmpty == false else { return }
        let ts = ISO8601DateFormatter().string(from: Date())
        let preview: String
        if let t = text {
            // Replace newlines with ⏎ so each capture is one line and the
            // file is grep/tail-friendly. Cap mirrored from EnrichedContext.
            let single = t.replacingOccurrences(of: "\n", with: "⏎")
            preview = single.count <= 600 ? single : String(single.prefix(600)) + "…"
        } else if let e = error {
            preview = "<error: \(e)>"
        } else {
            preview = "<nil>"
        }
        let includeStr: String = includeRect.map {
            "\(Int($0.minX.rounded())),\(Int($0.minY.rounded())) \(Int($0.width.rounded()))x\(Int($0.height.rounded()))"
        } ?? "nil"
        let line = "[\(ts)] ocr bundle=\(bundleID) excludeFocused=\(hasExclude) includeROI=\(includeStr) len=\(text?.count ?? 0) visible=\(preview.debugDescription)\n"
        let path = "/tmp/souffleuse-ocr.log"
        if let data = line.data(using: .utf8) {
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile(); try? h.write(contentsOf: data); try? h.close()
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
    }

    /// Maps a screen-coordinate (Quartz, top-left origin) rect into Vision's
    /// normalised coordinate system (bottom-left origin, 0..1) within the
    /// captured window image. Returns nil if the field rect falls entirely
    /// outside the window — defensive, shouldn't happen in practice.
    static func projectToVisionNormalised(_ fieldQuartz: CGRect, window: CGRect) -> CGRect? {
        guard window.width > 0, window.height > 0 else { return nil }
        // Field in window-local Quartz coordinates.
        let localX = fieldQuartz.minX - window.minX
        let localTop = fieldQuartz.minY - window.minY
        let localBottom = localTop + fieldQuartz.height
        // Clamp into [0, window.size].
        let clampedX = max(0, min(localX, window.width))
        let clampedRight = max(0, min(localX + fieldQuartz.width, window.width))
        let clampedTop = max(0, min(localTop, window.height))
        let clampedBottom = max(0, min(localBottom, window.height))
        guard clampedRight > clampedX, clampedBottom > clampedTop else { return nil }
        // Flip Y for Vision (bottom-left origin).
        let yBL = window.height - clampedBottom
        let h = clampedBottom - clampedTop
        let w = clampedRight - clampedX
        return CGRect(
            x: clampedX / window.width,
            y: yBL / window.height,
            width: w / window.width,
            height: h / window.height
        )
    }
}
