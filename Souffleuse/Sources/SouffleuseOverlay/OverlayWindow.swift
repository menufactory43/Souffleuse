import AppKit
import Foundation

/// Borderless, non-activating panel that paints ghost-suggestion text at an arbitrary
/// screen rect. Sits above every regular window via `.statusBar` level, never steals
/// focus, never captures mouse events.
@MainActor
public final class OverlayWindow {
    private let panel: NSPanel
    private let label: NSTextField

    public init() {
        self.panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true

        self.label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 15)
        label.textColor = .tertiaryLabelColor
        label.backgroundColor = .clear
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            label.topAnchor.constraint(equalTo: content.topAnchor),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        panel.contentView = content
    }

    public func show(text: String, at caretRectQuartz: CGRect) {
        show(text: text, at: caretRectQuartz, hostText: nil, caretIndex: nil, hostFont: nil)
    }

    /// `hostText` + `caretIndex` are used to correct caret X when the AX rect is a
    /// line rect (some apps, e.g. Notes, return line bounds instead of caret bounds).
    /// `hostFont` is the actual font of the host text (queried via
    /// AXAttributedStringForRange); when provided it's used for both measuring the
    /// line width and rendering the ghost so the ghost visually matches the typed text.
    private var lastFrame: CGRect = .zero
    private var lastText: String = ""

    public func show(text: String, at caretRectQuartz: CGRect, hostText: String?, caretIndex: Int?, hostFont: NSFont?) {
        guard !text.isEmpty else { hide(); return }
        // When AX can't expose the host font (Notes title, some Electron apps,
        // styled rich-text editors), `systemFont(ofSize: 15)` produces width
        // measurements ~50% too small on big text — the ghost then lands
        // *inside* the user's text instead of after the caret. Estimating
        // from the AX rect height (which is the line height in apps that
        // return line rects) gives a usable size in the 12–64 pt range.
        let renderFont = hostFont
            ?? Self.estimatedFont(forCaretRectHeight: caretRectQuartz.height)
            ?? label.font
            ?? .systemFont(ofSize: 15)
        let correctedRect = Self.correctCaretRect(caretRectQuartz, hostText: hostText, caretIndex: caretIndex, font: renderFont)
        let frame = Self.appKitFrame(forGhostAfterCaret: correctedRect, text: text, font: renderFont)

        label.font = renderFont
        label.stringValue = text
        panel.setFrame(frame, display: true)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        lastFrame = frame
        lastText = text
    }

    public func hide() {
        label.stringValue = ""
        lastText = ""
        if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    /// Convert a Quartz (top-left origin) caret rect into an AppKit (bottom-left origin)
    /// rect sized to render `text` immediately after the caret.
    ///
    /// The X position uses `caret.origin.x` because some apps (notably Notes) return
    /// the *line* bounds rather than a 1px caret rect when queried for length=1 — in
    /// that case `origin.x` is the true caret position and `maxX` is the line end.
    /// For apps that return a thin caret rect, `origin.x` still lands at the caret.
    /// Heuristic: when the AX rect is wider than ~30px we treat it as line bounds
    /// (Notes-style) and shift `origin.x` rightward by the measured width of the
    /// current line up to `caretIndex`. Otherwise the rect is assumed to be a true
    /// caret rect and returned untouched.
    static func correctCaretRect(_ rect: CGRect, hostText: String?, caretIndex: Int?, font: NSFont) -> CGRect {
        let likelyLineRect = rect.width > 30
        guard likelyLineRect,
              let hostText,
              let caretIndex,
              caretIndex >= 0, caretIndex <= hostText.count else {
            return rect
        }
        let upto = hostText.index(hostText.startIndex, offsetBy: caretIndex)
        let head = String(hostText[..<upto])
        let lineStart = head.lastIndex(of: "\n").map { hostText.index(after: $0) } ?? hostText.startIndex
        let lineSoFar = String(hostText[lineStart..<upto])
        let measured = (lineSoFar as NSString).size(withAttributes: [.font: font]).width
        return CGRect(x: rect.origin.x + measured, y: rect.origin.y, width: 1, height: rect.height)
    }

    /// Estimate a usable font size when AX doesn't expose the host font.
    /// AX caret rects are typically the line height; line-height ≈ font-size
    /// × 1.2 for the system text rendering stack, so dividing inverts that.
    /// Clamped to the readable range so we never produce a 4pt or 200pt ghost
    /// from a degenerate rect.
    static func estimatedFont(forCaretRectHeight height: CGFloat) -> NSFont? {
        guard height > 1 else { return nil }
        let estimated = height / 1.2
        let clamped = max(12, min(64, estimated))
        return .systemFont(ofSize: clamped)
    }

    static func appKitFrame(forGhostAfterCaret caret: CGRect, text: String, font: NSFont) -> CGRect {
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let width = ceil(textSize.width) + 4
        let height = max(caret.height, ceil(textSize.height))

        let primaryHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
        let appKitY = primaryHeight - caret.maxY
        // Anchor flush against the caret X — Cotypist paints right on the
        // cursor with no horizontal padding, and a 1 px gap reads as "the
        // ghost is offset" in dense text fields.
        let appKitX = caret.origin.x

        return CGRect(x: appKitX, y: appKitY, width: width, height: height)
    }
}
