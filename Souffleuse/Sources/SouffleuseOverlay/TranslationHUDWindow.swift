import AppKit
import Foundation
import QuartzCore

/// Vue de fond du panneau. Curseur « main » d'affordance de déplacement. Le
/// survol n'est PAS suivi via `NSTrackingArea` (peu fiable sur un panneau
/// non-activating de niveau status-bar — il émet des enter/exit parasites quand
/// la géométrie change pendant le streaming) : l'auto-masquage SONDE plutôt la
/// position réelle de la souris à l'expiration (cf. `scheduleAutoHide`).
private final class HoverView: NSView {
    var onAppearanceChange: (() -> Void)?
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()   // suit clair/sombre du système, en direct
    }
}

/// Panneau flottant de traduction — « la réplique soufflée ». Habillé comme le
/// livret de Souffleuse : papier crème, encre noire en **serif**, accent
/// **bordeaux**, en-tête en petites capitales espacées entre deux filets (motif
/// « programme de théâtre »). Apparition / disparition en **fondu**. Reste
/// affiché tant que la souris le survole ; position mémorisée par app (§3b).
@MainActor
public final class TranslationHUDWindow: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let container: HoverView
    private let header: NSTextField
    private let ruleLeft: NSView
    private let ruleRight: NSView
    private let body: NSTextField
    /// Rangée d'avertissement (garde-fou C : tokens durs disparus). Masquée si vide.
    private let badge: NSTextField
    /// Rangée d'aide en pied (« ↹ Tab remplacer · esc annuler »). Masquée si
    /// vide — même mécanisme que `badge`. Utilisée par le mode preview des
    /// transformations « // » : le panneau reste passif, c'est l'appelant qui
    /// décide d'armer Tab/Esc.
    private let hint: NSTextField
    private var anchorRectQuartz: CGRect = .zero
    private var bodyText: String = ""
    private var badgeText: String = ""
    private var hintText: String = ""
    private var savedOffset: CGSize = .zero
    private var currentBundleID: String?
    private var defaultOriginAppKit: CGPoint = .zero
    /// Vrai dès que l'utilisateur a fait glisser le panneau pendant cet affichage.
    public private(set) var isPinnedByUser = false
    private var programmaticMove = false
    public var onMoved: (@MainActor (String?, CGSize) -> Void)?
    /// Notifie l'app à chaque transition visible/caché du panneau. Branché sur
    /// l'armement du `KeyInterceptor` : tant que le HUD est à l'écran, ⌘↩/⌘⇧→
    /// sont interceptables SANS ghost actif (traduction hors flux de suggestion).
    public var onVisibilityChanged: (@MainActor (Bool) -> Void)?

    private var autoHideTask: Task<Void, Never>?
    private var hideGeneration = 0
    /// Intervalle de re-sondage tant que la souris reste sur le panneau.
    private static let hoverRecheckSeconds: Double = 1.0

    public static let width: CGFloat = 320

    /// Vrai quand « Réduire les animations » est actif (Réglages › Accessibilité).
    /// Le panneau apparaît/disparaît alors d'un coup, sans fondu.
    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - Palette, sensible à l'apparence système
    // Charte partagée des apparitions : `LivretPalette` (source de vérité unique).
    private static func paper(_ dark: Bool) -> NSColor { LivretPalette.paper(dark) }
    private static func ink(_ dark: Bool) -> NSColor { LivretPalette.ink(dark) }
    private static func accent(_ dark: Bool) -> NSColor { LivretPalette.accent(dark) }
    private static func warn(_ dark: Bool) -> NSColor { LivretPalette.warn(dark) }
    private static func rule(_ dark: Bool) -> NSColor { LivretPalette.rule(dark) }
    private static func border(_ dark: Bool) -> NSColor { LivretPalette.border(dark) }

    /// Texte brut de l'en-tête (conservé pour le reconstruire au changement
    /// d'apparence, sa couleur étant portée par la chaîne attribuée).
    private var headerRaw = ""
    /// Apparence sombre actuellement effective pour le panneau ?
    private var isDark: Bool { LivretPalette.isDark(container) }

    /// Serif d'affichage façon livret (Didot, repli serif système).
    private static func didot(size: CGFloat, italic: Bool = false) -> NSFont {
        LivretPalette.didot(size: size, italic: italic)
    }
    private static func serif(size: CGFloat, italic: Bool = false) -> NSFont {
        LivretPalette.serif(size: size, italic: italic)
    }

    public override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 80),
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
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true

        container = HoverView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 80))
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.borderWidth = 1

        header = NSTextField(labelWithString: "")
        header.alignment = .center

        ruleLeft = NSView();  ruleLeft.wantsLayer = true
        ruleRight = NSView(); ruleRight.wantsLayer = true

        body = NSTextField(wrappingLabelWithString: "")
        body.font = Self.serif(size: 15)
        body.alignment = .center
        body.maximumNumberOfLines = 0
        body.lineBreakMode = .byWordWrapping

        badge = NSTextField(wrappingLabelWithString: "")
        badge.font = Self.serif(size: 11, italic: true)
        badge.alignment = .center
        badge.maximumNumberOfLines = 0
        badge.lineBreakMode = .byWordWrapping
        badge.isHidden = true

        hint = NSTextField(wrappingLabelWithString: "")
        hint.font = Self.serif(size: 11, italic: true)
        hint.alignment = .center
        hint.maximumNumberOfLines = 1
        hint.lineBreakMode = .byTruncatingTail
        hint.isHidden = true

        container.addSubview(ruleLeft)
        container.addSubview(ruleRight)
        container.addSubview(header)
        container.addSubview(body)
        container.addSubview(badge)
        container.addSubview(hint)
        panel.contentView = container
        super.init()
        panel.delegate = self
        container.onAppearanceChange = { [weak self] in self?.applyColors() }
        applyColors()
    }

    /// Applique la palette du mode courant (clair/sombre) à tous les éléments.
    /// Couleurs explicites (sRGB) → indépendantes du contexte de dessin ; il
    /// suffit de les ré-appliquer au changement d'apparence.
    private func applyColors() {
        let dark = isDark
        container.layer?.backgroundColor = Self.paper(dark).cgColor
        container.layer?.borderColor = Self.border(dark).cgColor
        ruleLeft.layer?.backgroundColor = Self.rule(dark).cgColor
        ruleRight.layer?.backgroundColor = Self.rule(dark).cgColor
        body.textColor = Self.ink(dark)
        badge.textColor = Self.warn(dark)
        hint.textColor = Self.ink(dark).withAlphaComponent(0.6)
        applyHeader(headerRaw)   // la couleur de l'en-tête vit dans la chaîne attribuée
    }

    // MARK: - API

    public func show(
        at fieldRectQuartz: CGRect,
        header headerText: String,
        body bodyTextValue: String,
        savedOffset: CGSize = .zero,
        bundleID: String? = nil
    ) {
        hideGeneration &+= 1
        autoHideTask?.cancel()
        anchorRectQuartz = fieldRectQuartz
        currentBundleID = bundleID
        self.savedOffset = savedOffset
        isPinnedByUser = false
        headerRaw = headerText
        bodyText = bodyTextValue
        badgeText = ""
        hintText = ""
        applyColors()        // (ré)applique l'apparence courante + construit l'en-tête
        relayout()
        onVisibilityChanged?(true)
        if !panel.isVisible {
            if Self.reduceMotion {
                panel.alphaValue = 1
                panel.orderFrontRegardless()
            } else {
                panel.alphaValue = 0
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().alphaValue = 1
                }
            }
        } else {
            panel.alphaValue = 1
        }
    }

    public func update(_ text: String) {
        bodyText = text
        relayout()
    }

    public func setBadge(_ text: String?) {
        badgeText = text ?? ""
        relayout()
    }

    /// Affiche/retire la ligne d'aide du pied de panneau (mode preview des
    /// transformations « // » : « ↹ Tab remplacer · esc annuler »). nil ou
    /// vide → masquée. `show()` la remet à vide, comme le badge.
    public func setHint(_ text: String?) {
        hintText = text ?? ""
        relayout()
    }

    /// Auto-masquage en fondu après `seconds`. À l'expiration, si la souris est
    /// SUR le panneau (sondage direct, robuste) ou s'il est épinglé, on repousse
    /// au lieu de masquer.
    public func scheduleAutoHide(after seconds: Double) {
        autoHideTask?.cancel()
        autoHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if self.isPinnedByUser { return }
            if self.mouseIsOverPanel() {
                self.scheduleAutoHide(after: Self.hoverRecheckSeconds)
                return
            }
            self.hide()
        }
    }

    private func mouseIsOverPanel() -> Bool {
        panel.isVisible && panel.frame.contains(NSEvent.mouseLocation)
    }

    public func hide() {
        guard panel.isVisible else { return }
        autoHideTask?.cancel()
        // Désarmement dès l'INTENTION de masquer (le fondu de 240 ms ne doit pas
        // prolonger l'interception de ⌘↩ — l'utilisateur a visuellement fini).
        onVisibilityChanged?(false)
        hideGeneration &+= 1
        let g = hideGeneration
        if Self.reduceMotion {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard let self, self.hideGeneration == g else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        }
    }

    /// En-tête « programme » : Didot, capitales, généreusement espacé, bordeaux,
    /// CENTRÉ. NB : poser un `attributedStringValue` ignore `header.alignment` —
    /// le centrage doit vivre dans le `NSParagraphStyle` de la chaîne attribuée.
    private func applyHeader(_ s: String) {
        headerRaw = s
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        header.attributedStringValue = NSAttributedString(
            string: s.uppercased(),
            attributes: [
                .font: Self.didot(size: 11),
                .foregroundColor: Self.accent(isDark),
                .kern: 2.2,
                .paragraphStyle: para,
            ])
    }

    // MARK: - Layout

    private func relayout() {
        body.stringValue = bodyText.isEmpty ? "…" : bodyText
        badge.stringValue = badgeText
        badge.isHidden = badgeText.isEmpty
        hint.stringValue = hintText
        hint.isHidden = hintText.isEmpty
        let pad: CGFloat = 16
        let headerH: CGFloat = 15
        let headerGap: CGFloat = 13   // sous la rangée d'en-tête
        let gap: CGFloat = 8
        let bodyWidth = Self.width - pad * 2

        func textHeight(_ s: String, font: NSFont?, minH: CGFloat) -> CGFloat {
            guard !s.isEmpty else { return 0 }
            let attrs: [NSAttributedString.Key: Any] = [.font: font as Any]
            let bounding = (s as NSString).boundingRect(
                with: NSSize(width: bodyWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs
            )
            return max(minH, ceil(bounding.height))
        }

        let bodyH = textHeight(body.stringValue, font: body.font, minH: 20)
        let badgeH = badgeText.isEmpty ? 0 : textHeight(badgeText, font: badge.font, minH: 15)
        let badgeBlock = badgeText.isEmpty ? 0 : gap + badgeH
        let hintH = hintText.isEmpty ? 0 : textHeight(hintText, font: hint.font, minH: 14)
        let hintBlock = hintText.isEmpty ? 0 : gap + hintH
        let total = pad + headerH + headerGap + bodyH + badgeBlock + hintBlock + pad

        container.frame = NSRect(x: 0, y: 0, width: Self.width, height: total)

        // En-tête centré sur TOUTE la largeur (jamais tronqué), encadré de deux
        // filets posés autour de la largeur RÉELLE du texte (marge de sécurité).
        let headerY = total - pad - headerH
        header.frame = NSRect(x: pad, y: headerY, width: bodyWidth, height: headerH)
        let textW = min(ceil(header.attributedStringValue.size().width) + 8, bodyWidth)
        let centerX = Self.width / 2
        let ruleY = (headerY + headerH / 2).rounded()
        let ruleSideGap: CGFloat = 12
        let leftEnd = centerX - textW / 2 - ruleSideGap
        let rightStart = centerX + textW / 2 + ruleSideGap
        ruleLeft.frame = NSRect(x: pad, y: ruleY, width: max(0, leftEnd - pad), height: 1)
        ruleRight.frame = NSRect(x: rightStart, y: ruleY, width: max(0, (Self.width - pad) - rightStart), height: 1)

        // Corps + badge + hint ancrés en bas (le panneau croît vers le haut au
        // streaming) ; le hint est la rangée la plus basse, sous le badge.
        hint.frame = NSRect(x: pad, y: pad, width: bodyWidth, height: hintH)
        badge.frame = NSRect(x: pad, y: pad + hintBlock, width: bodyWidth, height: badgeH)
        body.frame = NSRect(x: pad, y: pad + hintBlock + badgeBlock, width: bodyWidth, height: bodyH)

        let screen = NSScreen.screens.first ?? NSScreen.main
        let screenH = screen?.frame.height ?? 0
        let screenW = screen?.frame.width ?? 0
        let panelSize = CGSize(width: Self.width, height: total)
        let screenSize = CGSize(width: screenW, height: screenH)
        let defaultOrigin = CGPoint(x: anchorRectQuartz.minX, y: screenH - anchorRectQuartz.minY + 6)
        defaultOriginAppKit = Self.clampedOrigin(
            defaultOrigin: defaultOrigin, offset: .zero,
            panelSize: panelSize, screenSize: screenSize)
        let placed = Self.clampedOrigin(
            defaultOrigin: defaultOrigin, offset: savedOffset,
            panelSize: panelSize, screenSize: screenSize)
        programmaticMove = true
        panel.setFrame(NSRect(x: placed.x, y: placed.y, width: Self.width, height: total), display: true)
        programmaticMove = false
    }

    /// Origine AppKit (bord bas-gauche) du panneau = défaut + offset, clampée à
    /// l'écran (marge 8 pt). Pure, testable sans écran réel.
    nonisolated static func clampedOrigin(
        defaultOrigin: CGPoint, offset: CGSize,
        panelSize: CGSize, screenSize: CGSize
    ) -> CGPoint {
        var x = defaultOrigin.x + offset.width
        var y = defaultOrigin.y + offset.height
        x = min(max(8, x), max(8, screenSize.width - panelSize.width - 8))
        y = min(max(8, y), max(8, screenSize.height - panelSize.height - 8))
        return CGPoint(x: x, y: y)
    }

    // MARK: - NSWindowDelegate (déplacement utilisateur → persistance §3b)

    public func windowDidMove(_ notification: Notification) {
        guard !programmaticMove, panel.isVisible else { return }
        let origin = panel.frame.origin
        let offset = CGSize(
            width: origin.x - defaultOriginAppKit.x,
            height: origin.y - defaultOriginAppKit.y)
        if abs(offset.width - savedOffset.width) < 1, abs(offset.height - savedOffset.height) < 1 { return }
        savedOffset = offset
        isPinnedByUser = true
        autoHideTask?.cancel()
        onMoved?(currentBundleID, offset)
    }
}
