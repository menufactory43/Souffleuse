import AppKit
import Foundation

/// Borderless, non-activating panel that paints ghost-suggestion text at an arbitrary
/// screen rect. Sits above every regular window via `.statusBar` level, never steals
/// focus, never captures mouse events.
@MainActor
public final class OverlayWindow {
    private let panel: NSPanel
    private let label: NSTextField
    /// Custom-drawn sibling used only for the in-place typo correction: a red
    /// strikethrough over the misspelled word (the host's real glyphs show
    /// through) + the green suggestion painted right after it. Hidden whenever a
    /// normal ghost is shown; toggled instead of recreated so the single panel's
    /// lifecycle (show/hide/accept/esc) stays untouched.
    private let correctionView = CorrectionView()
    /// Custom-drawn sibling used only for the **mid-line** ghost: when the caret
    /// sits inside a line (non-whitespace text follows on the same line), an
    /// inline ghost would paint ON TOP of the user's existing glyphs. So instead
    /// we render the suggestion as a self-contained rounded "pill" floated just
    /// BELOW the caret line — Cotypist's mid-line presentation. Hidden whenever a
    /// normal ghost or correction is shown; toggled, not recreated, so the single
    /// panel's lifecycle stays untouched.
    private let pillView = PillView()

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

        correctionView.translatesAutoresizingMaskIntoConstraints = false
        correctionView.isHidden = true

        pillView.translatesAutoresizingMaskIntoConstraints = false
        pillView.isHidden = true

        let content = NSView()
        content.addSubview(label)
        content.addSubview(correctionView)
        content.addSubview(pillView)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            label.topAnchor.constraint(equalTo: content.topAnchor),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            correctionView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            correctionView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            correctionView.topAnchor.constraint(equalTo: content.topAnchor),
            correctionView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            pillView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pillView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pillView.topAnchor.constraint(equalTo: content.topAnchor),
            pillView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
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
    /// Dernier fragment `typed` peint dans la pill — partie du guard anti-repaint
    /// de `showPill` (le fragment change à chaque frappe, pas toujours le frame).
    private var lastPillTyped: String = ""

    /// Hook DEV (trace de latence bout-en-bout) : appelé à chaque REPAINT
    /// effectif (un appel qui a passé le guard anti-repaint), avec la longueur
    /// du texte peint. Nil en prod — l'overlay reste sans dépendance ; c'est
    /// l'app qui le branche quand `SOUFFLEUSE_LATENCY_TRACE` est posé.
    public var onPaint: ((Int) -> Void)?

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
        var frame = Self.appKitFrame(forGhostAfterCaret: correctedRect, text: text, font: renderFont)

        // A/B (gaté par env) : décale le ghost d'UNE LIGNE vers le haut, au lieu
        // de l'afficher inline après le caret. Utile quand un ghost long (2-4
        // mots) gêne la lecture sur la ligne courante — on le pose au-dessus.
        // AppKit : "vers le haut" = +y. Une ligne ≈ hauteur du caret/ligne hôte
        // (fallback sur la police si l'AX ne donne pas de hauteur fiable).
        // RÉVERSIBLE : retirer ce bloc.
        if ProcessInfo.processInfo.environment["SOUFFLEUSE_GHOST_LINE_UP"] != nil {
            let lineH = correctedRect.height > 1 ? correctedRect.height : renderFont.pointSize * 1.3
            frame.origin.y += lineH
        }

        // Skip redundant repaints (revertable). The 80 ms poll re-calls show()
        // ~12x/s with identical content; re-running setFrame(display:) every tick
        // wastes work and, when the caret rect jitters a pixel on Electron hosts,
        // makes the ghost shimmer. Only repaint when text or frame actually
        // changed. TO REVERT: delete this guard.
        if panel.isVisible, text == lastText, frame == lastFrame {
            return
        }

        correctionView.isHidden = true
        pillView.isHidden = true
        label.isHidden = false
        label.font = renderFont
        label.stringValue = text
        panel.setFrame(frame, display: true)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        lastFrame = frame
        lastText = text
        onPaint?(text.count)
    }

    /// Paint the **mid-line** ghost as a rounded pill floated just below the caret
    /// line (Cotypist parity). Used when non-whitespace text follows the caret on
    /// the same line, where an inline ghost would overlap the user's glyphs. The
    /// pill is self-contained (own background + border), so it reads cleanly over
    /// any host text. `caretRectQuartz` is the caret rect; `hostText`/`caretIndex`
    /// correct the caret X for apps that return line rects (Notes); `hostFont`
    /// sizes the pill text to roughly match the host.
    /// `typed` : fragment du mot EN COURS de frappe (ce que l'utilisateur a déjà
    /// tapé du mot que la suggestion complète). Rendu DEVANT la suggestion dans
    /// une couleur distincte (accent), pour qu'on voie « où on en est » dans le
    /// mot pendant que la pill fond/se recharge — parité avec la bulle mid-line
    /// de Cotypist. Vide à une frontière de mot → pill suggestion seule.
    public func showPill(text: String, typed: String = "", at caretRectQuartz: CGRect, hostText: String?, caretIndex: Int?, hostFont: NSFont?) {
        let text = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard !text.isEmpty else { hide(); return }
        let renderFont = hostFont
            ?? Self.estimatedFont(forCaretRectHeight: caretRectQuartz.height)
            ?? label.font
            ?? .systemFont(ofSize: 15)
        let correctedRect = Self.correctCaretRect(caretRectQuartz, hostText: hostText, caretIndex: caretIndex, font: renderFont)
        let frame = Self.pillFrame(belowCaret: correctedRect, text: text, typed: typed, font: renderFont)

        // Same redundant-repaint guard as the inline ghost: the 80 ms poll
        // re-calls this ~12×/s with identical content, and the caret rect can
        // jitter a pixel on Electron hosts. Only repaint on a real change.
        // `typed` fait partie du guard : pendant la frappe le fragment change
        // alors que le frame peut rester identique au pixel près.
        if panel.isVisible, !pillView.isHidden, text == lastText, typed == lastPillTyped, frame == lastFrame {
            return
        }

        label.isHidden = true
        label.stringValue = ""
        correctionView.isHidden = true
        pillView.isHidden = false
        pillView.configure(typed: typed, suggestion: text, font: renderFont)
        panel.setFrame(frame, display: true)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        lastFrame = frame
        lastText = text
        lastPillTyped = typed
        onPaint?(text.count)
    }

    /// AppKit frame for the mid-line pill: a padded rounded box whose TOP sits a
    /// few points below the caret line (`caret.maxY` in Quartz = line bottom), left
    /// edge aligned so the pill text starts under the caret X. Clamped to the left
    /// screen edge so it never clips off-screen at the start of a line.
    /// `typed` (fragment du mot en cours) est mesuré DANS la largeur et DÉCALE la
    /// pill vers la gauche : le fragment se lit sous ses propres glyphes et la
    /// suggestion reste alignée sous le caret.
    static func pillFrame(belowCaret caret: CGRect, text: String, typed: String = "", font: NSFont) -> CGRect {
        let textSize = ((typed + text) as NSString).size(withAttributes: [.font: font])
        let width = ceil(textSize.width) + PillView.hPad * 2
        let height = ceil(textSize.height) + PillView.vPad * 2

        let primaryHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
        // Quartz Y grows downward, so the bottom of the line is `caret.maxY`; the
        // pill hangs `gap` below it. Convert that Quartz bottom-of-pill to AppKit
        // (origin bottom-left): appKitY = screenH − quartzBottomOfPill.
        let quartzPillBottom = caret.maxY + PillView.gapBelow + height
        let appKitY = primaryHeight - quartzPillBottom
        // Align the pill's text (inset by hPad) under the caret X; clamp ≥ 0.
        let typedWidth = typed.isEmpty
            ? 0
            : ceil((typed as NSString).size(withAttributes: [.font: font]).width)
        let appKitX = max(0, caret.origin.x - PillView.hPad - typedWidth)

        return CGRect(x: appKitX, y: appKitY, width: width, height: height)
    }

    /// Paint the in-place typo correction à la Cotypist from a **pixel-perfect
    /// word rect** (AX `AXBoundsForRange`, native hosts). The strike lands exactly
    /// on the user's glyphs. See `renderCorrection` for the drawing.
    public func showCorrection(original: String, suggestion: String, atWordRectQuartz wordRect: CGRect, font: NSFont?) {
        let renderFont = font
            ?? Self.estimatedFont(forCaretRectHeight: wordRect.height)
            ?? label.font
            ?? .systemFont(ofSize: 15)
        renderCorrection(
            original: original,
            suggestion: suggestion,
            wordRectQuartz: wordRect,
            renderFont: renderFont
        )
    }

    /// Paint the in-place correction when AX can't give a word rect (Chromium/
    /// WebKit): estimate it geometrically from the reliable caret rect. The word
    /// ends `separatorAfterWord` glyphs before the caret and is `original` wide,
    /// all on the caret's line — so we measure those widths in the render font and
    /// subtract from the caret X. Robust everywhere the caret rect is known.
    public func showCorrectionEstimated(
        original: String,
        suggestion: String,
        separatorAfterWord: String,
        caretRectQuartz caret: CGRect,
        font: NSFont?
    ) {
        let renderFont = font
            ?? Self.estimatedFont(forCaretRectHeight: caret.height)
            ?? label.font
            ?? .systemFont(ofSize: 15)
        let sepWidth = (separatorAfterWord as NSString).size(withAttributes: [.font: renderFont]).width
        let wordWidth = (original as NSString).size(withAttributes: [.font: renderFont]).width
        let wordRect = CGRect(
            x: caret.minX - sepWidth - wordWidth,
            y: caret.origin.y,
            width: wordWidth,
            height: caret.height
        )
        renderCorrection(
            original: original,
            suggestion: suggestion,
            wordRectQuartz: wordRect,
            renderFont: renderFont
        )
    }

    /// Shared drawing for both correction paths: a red strikethrough over the
    /// word at `wordRectQuartz` (the host's real glyphs show through) and the
    /// green `suggestion` right after. Reuses the single ghost panel — `hide()`
    /// clears it like any other suggestion.
    private func renderCorrection(original: String, suggestion: String, wordRectQuartz wordRect: CGRect, renderFont: NSFont) {
        let gap = renderFont.pointSize * 0.3
        let suggestionWidth = (suggestion as NSString).size(withAttributes: [.font: renderFont]).width
        let wordWidth = ceil(wordRect.width)

        let width = wordWidth + ceil(gap) + ceil(suggestionWidth) + 4
        let height = max(wordRect.height, ceil(renderFont.boundingRectForFont.height))
        let primaryHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
        // Comparison seam: when the ghost is lifted one line (to run side-by-side
        // with Cotypist on the same word), the correction must lift too — else it
        // paints ON TOP of Cotypist's own render and neither is legible. On the
        // lifted line there are no real glyphs, so we repaint the struck original;
        // in production (offset off) the strike sits over the host's real letters.
        let lifted = Self.ghostLineOffsetEnabled
        let lineOffset = lifted ? wordRect.height : 0
        // +Y is up in AppKit; the panel is anchored to the word's top-left so the
        // strike (drawn at x:0..wordWidth in the view) overlays the real glyphs.
        let frame = CGRect(
            x: wordRect.origin.x,
            y: primaryHeight - wordRect.maxY + lineOffset,
            width: width,
            height: height
        )

        label.isHidden = true
        label.stringValue = ""
        pillView.isHidden = true
        correctionView.isHidden = false
        correctionView.configure(
            original: lifted ? original : nil,
            suggestion: suggestion,
            wordWidth: wordWidth,
            gap: gap,
            font: renderFont
        )
        panel.setFrame(frame, display: true)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        // Force the next ghost to repaint — the redundant-paint guard compares
        // against these, and a correction leaves them describing a stale ghost.
        lastFrame = .zero
        lastText = ""
    }

    /// A word rect is only usable for the in-place strike when it has real
    /// extent. AX sometimes returns zero/degenerate rects (web placeholders);
    /// those must fall back to the caret-anchored `→ suggestion` hint.
    public static func isUsableWordRect(_ rect: CGRect) -> Bool {
        rect.width >= 2 && rect.height >= 2
            && rect.width < 4000 && rect.height < 400
            && rect.origin.x.isFinite && rect.origin.y.isFinite
    }

    public func hide() {
        label.stringValue = ""
        label.isHidden = false
        correctionView.isHidden = true
        pillView.isHidden = true
        lastText = ""
        lastPillTyped = ""
        lastFrame = .zero
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

/// Custom-drawn content for the in-place typo correction. Draws nothing over the
/// word except a red strikethrough line (the host's real glyphs provide the
/// letters), then the green suggestion after a small gap. Non-flipped (AppKit
/// default, origin bottom-left) so the math matches `showCorrection`'s frame.
@MainActor
private final class CorrectionView: NSView {
    /// Non-nil only in the lifted comparison mode: the misspelled word is
    /// repainted (dimmed) under the strike because the real glyphs are on the
    /// line below. In production this is nil — the host's own letters show
    /// through and we draw only the strike line.
    private var original: String?
    private var suggestion: String = ""
    private var wordWidth: CGFloat = 0
    private var gap: CGFloat = 0
    private var font: NSFont = .systemFont(ofSize: 15)

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { false }

    func configure(original: String?, suggestion: String, wordWidth: CGFloat, gap: CGFloat, font: NSFont) {
        self.original = original
        self.suggestion = suggestion
        self.wordWidth = wordWidth
        self.gap = gap
        self.font = font
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !suggestion.isEmpty else { return }

        // Repaint the struck word only when lifted off its real glyphs.
        if let original {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            let ns = original as NSString
            let size = ns.size(withAttributes: attrs)
            ns.draw(at: CGPoint(x: 0, y: (bounds.height - size.height) / 2), withAttributes: attrs)
        }

        // Strikethrough over the (real or repainted) word: a single line at the
        // glyphs' visual mid-height.
        let lineY = bounds.midY
        let path = NSBezierPath()
        path.lineWidth = max(1, font.pointSize * 0.08)
        path.move(to: CGPoint(x: 0, y: lineY))
        path.line(to: CGPoint(x: wordWidth, y: lineY))
        NSColor.systemRed.setStroke()
        path.stroke()

        // Green suggestion right after the struck word.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.systemGreen,
        ]
        let text = suggestion as NSString
        let size = text.size(withAttributes: attrs)
        let textY = (bounds.height - size.height) / 2
        text.draw(at: CGPoint(x: wordWidth + gap, y: textY), withAttributes: attrs)
    }
}

/// Custom-drawn content for the **mid-line pill**: a rounded, bordered capsule
/// with a faint background, holding the suggestion in muted text — Cotypist's
/// presentation when the caret is inside a line. Semantic colours so it adapts
/// to light/dark mode automatically. Non-flipped (AppKit default, origin
/// bottom-left) so the text-centring math matches the frame from `pillFrame`.
@MainActor
final class PillView: NSView {
    /// Horizontal text inset inside the pill (each side). Also drives the X
    /// alignment in `pillFrame`, so the text starts under the caret.
    static let hPad: CGFloat = 9
    /// Vertical text inset inside the pill (each side).
    static let vPad: CGFloat = 4
    /// Vertical gap between the caret line's bottom and the pill's top.
    static let gapBelow: CGFloat = 4

    /// Fragment du mot EN COURS de frappe, rendu en couleur d'accent devant la
    /// suggestion — on voit littéralement le mot se remplir pendant qu'on le tape.
    private var typed: String = ""
    private var text: String = ""
    private var font: NSFont = .systemFont(ofSize: 15)

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { false }

    func configure(typed: String, suggestion: String, font: NSFont) {
        self.typed = typed
        self.text = suggestion
        self.font = font
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }

        // Rounded capsule: inset half a point so the 1px border isn't clipped at
        // the panel edge. Radius = a soft rounded rect (not a full capsule) to
        // match Cotypist's mid-line bubble.
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = min(8, box.height / 2)
        let path = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
        NSColor.windowBackgroundColor.withAlphaComponent(0.98).setFill()
        path.fill()
        path.lineWidth = 1
        NSColor.separatorColor.setStroke()
        path.stroke()

        // Deux runs : le fragment déjà TAPÉ du mot en cours (accent — « c'est toi
        // qui l'as écrit ») suivi de la suggestion en gris. Centrage vertical sur
        // la hauteur du run combiné, inset hPad.
        let suggestionAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        var x = Self.hPad
        if !typed.isEmpty {
            let typedAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.controlAccentColor,
            ]
            let typedNS = typed as NSString
            let typedSize = typedNS.size(withAttributes: typedAttrs)
            typedNS.draw(at: CGPoint(x: x, y: (bounds.height - typedSize.height) / 2),
                         withAttributes: typedAttrs)
            x += typedSize.width
        }
        let ns = text as NSString
        let size = ns.size(withAttributes: suggestionAttrs)
        let textY = (bounds.height - size.height) / 2
        ns.draw(at: CGPoint(x: x, y: textY), withAttributes: suggestionAttrs)
    }
}
