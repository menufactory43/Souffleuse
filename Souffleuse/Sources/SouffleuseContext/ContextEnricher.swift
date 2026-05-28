import Foundation

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
            windowTitle: ctx.windowTitle,
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
        do {
            let capture = try await capturer.capture(bundleID: bundleID)
            let exclude = focusedFieldRect.flatMap { Self.projectToVisionNormalised($0, window: capture.windowFrame) }
            let extracted = try await ocr.extract(from: capture.image, excludeNormalised: exclude)
            text = extracted.isEmpty ? nil : extracted
        } catch {
            text = nil
        }
        visibleCache[bundleID] = CacheEntry(timestamp: Date(), visible: text)
        return text
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
