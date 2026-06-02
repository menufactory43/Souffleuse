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
        // Safety net: a ghost must never contain a hard line break. A newline
        // (e.g. a prose corpus entry stored as "…Bitcoin.\n") renders the
        // overlay one line ABOVE the caret — the panel is bottom-anchored to
        // the caret rect, so `appKitFrame` measures a two-line box and the
        // visible text floats up. The instant/corpus path is sanitised at the
        // source (OutputFilter.singleLine); this guards every other caller.
        // Newlines become spaces so nothing is silently dropped at render.
        let text = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
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

        // Skip redundant repaints (revertable). The 80 ms poll re-calls show()
        // ~12x/s with identical content; re-running setFrame(display:) every tick
        // wastes work and, when the caret rect jitters a pixel on Electron hosts,
        // makes the ghost shimmer. Only repaint when text or frame actually
        // changed. TO REVERT: delete this guard.
        if panel.isVisible, text == lastText, frame == lastFrame {
            return
        }

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

    /// Vrai quand un ghost est actuellement affiché — lu par l'icône vivante de la
    /// barre des menus pour refléter l'état « elle souffle ».
    public var isVisible: Bool { panel.isVisible }

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
    /// We divide by 1.1 (not the strict 1.2) on purpose: web/Electron line
    /// boxes run tighter than the system stack, and the user prefers a ghost a
    /// hair LARGER than the host text rather than slightly smaller.
    ///
    /// The upper clamp is a conservative 20pt (not 64pt). On empty lines and
    /// at the start of a new paragraph some apps (Notes, TextEdit) return a
    /// line-box rect whose height is the full paragraph leading, not the font
    /// size — feeding that into height/1.1 would produce a ghost ~3× too big.
    /// The per-bundle reliable-font cache in `SouffleuseAppDelegate` is the
    /// primary mitigation (it remembers the last trustworthy AX font for each
    /// app); this 20pt cap is the secondary safety net so the fallback path
    /// can never blow up the overlay beyond a readable body-text size.
    static func estimatedFont(forCaretRectHeight height: CGFloat) -> NSFont? {
        guard height > 1 else { return nil }
        let estimated = height / 1.1
        let clamped = max(12, min(20, estimated))
        return .systemFont(ofSize: clamped)
    }

    /// Dev seam : remonte le ghost d'une ligne au-dessus du caret. Cotypist (notre
    /// concurrent) peint pile sur le caret ; en libérant la ligne du curseur on peut
    /// faire tourner les deux assistants côte à côte dans la *même* app, sur le *même*
    /// préfixe, et comparer la cohérence à l'œil — ce qu'aucun bench TTFT ne donne.
    /// Off par défaut, activé par `SOUFFLEUSE_GHOST_LINE_OFFSET=1`. Lu une fois : un
    /// test de cohérence est une session ponctuelle, pas un réglage utilisateur — donc
    /// pas de surface UI ni de pref persistée. Ne pas laisser activé en prod (le ghost
    /// recouvrirait la ligne du dessus dans un champ multi-ligne).
    static let ghostLineOffsetEnabled: Bool = {
        ProcessInfo.processInfo.environment["SOUFFLEUSE_GHOST_LINE_OFFSET"] == "1"
    }()

    static func appKitFrame(forGhostAfterCaret caret: CGRect, text: String, font: NSFont) -> CGRect {
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let width = ceil(textSize.width) + 4
        let height = max(caret.height, ceil(textSize.height))

        let primaryHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
        // +Y = vers le haut en AppKit. `caret.height` est la hauteur de ligne (les apps
        // qui renvoient un line rect l'exposent directement), donc remonter d'exactement
        // une ligne laisse le caret libre pour le ghost de Cotypist juste en dessous.
        let lineOffset = ghostLineOffsetEnabled ? caret.height : 0
        let appKitY = primaryHeight - caret.maxY + lineOffset
        // Anchor flush against the caret X — Cotypist paints right on the
        // cursor with no horizontal padding, and a 1 px gap reads as "the
        // ghost is offset" in dense text fields.
        let appKitX = caret.origin.x

        return CGRect(x: appKitX, y: appKitY, width: width, height: height)
    }
}
