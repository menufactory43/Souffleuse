import AppKit
import Foundation

/// Vue de fond du panneau. Curseur « main » d'affordance de déplacement. Le
/// survol n'est PAS suivi via `NSTrackingArea` (peu fiable sur un panneau
/// non-activating de niveau status-bar — il émet des enter/exit parasites quand
/// la géométrie change pendant le streaming) : l'auto-masquage SONDE plutôt la
/// position réelle de la souris à l'expiration (cf. `scheduleAutoHide`).
private final class HoverView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

/// Panneau flottant de traduction — « la réplique soufflée ». Pensé dans l'esprit
/// *souffleuse de théâtre* : salle dans la pénombre (charbon chaud), filet doré
/// façon programme, réplique en **serif** sous une lumière de scène, apparition /
/// disparition en **fondu** (fluide). Reste affiché tant que la souris le survole
/// (on peut le lire, le saisir, le déplacer) ; position mémorisée par app (§3b).
///
/// `NSPanel` borderless non-activating, niveau status-bar, toutes les Spaces.
@MainActor
public final class TranslationHUDWindow: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let container: HoverView
    private let header: NSTextField
    private let rule: NSView
    private let body: NSTextField
    /// Rangée d'avertissement ambre (garde-fou C : tokens durs disparus). Masquée
    /// quand vide.
    private let badge: NSTextField
    private var anchorRectQuartz: CGRect = .zero
    private var bodyText: String = ""
    private var badgeText: String = ""
    /// Décalage (points écran AppKit) appliqué à la position par défaut, mémorisé
    /// par app (§3b). `.zero` = position par défaut (bord gauche, au-dessus).
    private var savedOffset: CGSize = .zero
    private var currentBundleID: String?
    private var defaultOriginAppKit: CGPoint = .zero
    /// Vrai dès que l'utilisateur a fait glisser le panneau pendant cet affichage
    /// → on cesse de l'auto-masquer.
    public private(set) var isPinnedByUser = false
    private var programmaticMove = false
    public var onMoved: (@MainActor (String?, CGSize) -> Void)?

    /// Tâche d'auto-masquage en attente (annulée au prochain affichage).
    private var autoHideTask: Task<Void, Never>?
    /// Génération de fondu-sortie : un `show` ou un nouveau `hide` l'incrémente
    /// pour invalider un `orderOut` différé encore en vol.
    private var hideGeneration = 0
    /// Intervalle de re-sondage tant que la souris reste sur le panneau.
    private static let hoverRecheckSeconds: Double = 1.0

    public static let width: CGFloat = 320

    // MARK: - Palette « théâtre »
    private static let bgColor = NSColor(srgbRed: 0.105, green: 0.088, blue: 0.078, alpha: 0.97)
    private static let goldBorder = NSColor(srgbRed: 0.80, green: 0.66, blue: 0.40, alpha: 0.55)
    private static let goldHeader = NSColor(srgbRed: 0.86, green: 0.73, blue: 0.47, alpha: 1)
    private static let goldRule = NSColor(srgbRed: 0.80, green: 0.66, blue: 0.40, alpha: 0.32)
    private static let parchment = NSColor(srgbRed: 0.93, green: 0.90, blue: 0.83, alpha: 1)
    private static let amber = NSColor(srgbRed: 0.90, green: 0.71, blue: 0.36, alpha: 1)

    private static func serif(size: CGFloat, italic: Bool = false) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .regular)
        var desc = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        if italic { desc = desc.withSymbolicTraits(.italic) }
        return NSFont(descriptor: desc, size: size) ?? base
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
        // Reçoit la souris : déplaçable (tiré par son fond) + survol suivi. Non-
        // activating → déplacer ne vole pas le focus à l'app hôte.
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true

        container = HoverView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 80))
        container.wantsLayer = true
        container.layer?.backgroundColor = Self.bgColor.cgColor
        container.layer?.cornerRadius = 14
        container.layer?.borderWidth = 1
        container.layer?.borderColor = Self.goldBorder.cgColor

        header = NSTextField(labelWithString: "")
        header.font = .systemFont(ofSize: 10, weight: .semibold)
        header.textColor = Self.goldHeader

        rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = Self.goldRule.cgColor

        body = NSTextField(wrappingLabelWithString: "")
        body.font = Self.serif(size: 15)
        body.textColor = Self.parchment
        body.maximumNumberOfLines = 0
        body.lineBreakMode = .byWordWrapping

        badge = NSTextField(wrappingLabelWithString: "")
        badge.font = Self.serif(size: 11, italic: true)
        badge.textColor = Self.amber
        badge.maximumNumberOfLines = 0
        badge.lineBreakMode = .byWordWrapping
        badge.isHidden = true

        container.addSubview(header)
        container.addSubview(rule)
        container.addSubview(body)
        container.addSubview(badge)
        panel.contentView = container
        super.init()
        panel.delegate = self
    }

    // MARK: - API

    public func show(
        at fieldRectQuartz: CGRect,
        header headerText: String,
        body bodyTextValue: String,
        savedOffset: CGSize = .zero,
        bundleID: String? = nil
    ) {
        hideGeneration &+= 1            // annule un fondu-sortie en attente
        autoHideTask?.cancel()
        anchorRectQuartz = fieldRectQuartz
        currentBundleID = bundleID
        self.savedOffset = savedOffset
        isPinnedByUser = false
        applyHeader(headerText)
        bodyText = bodyTextValue
        badgeText = ""
        relayout()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1        // au cas où un fondu-sortie était en cours
        }
    }

    /// Met à jour le texte de traduction (appelé pendant le streaming).
    public func update(_ text: String) {
        bodyText = text
        relayout()
    }

    /// Pose (ou efface avec `nil`) la rangée d'avertissement ambre du garde-fou C.
    public func setBadge(_ text: String?) {
        badgeText = text ?? ""
        relayout()
    }

    /// Programme l'auto-masquage en fondu après `seconds`. À l'expiration, si la
    /// souris est SUR le panneau (sondage direct de sa position — robuste, sans
    /// tracking area) ou s'il a été épinglé par un déplacement, on repousse au
    /// lieu de masquer : on peut lire / saisir / déplacer aussi longtemps qu'on
    /// le survole.
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

    /// La souris est-elle actuellement au-dessus du panneau ? `NSEvent.mouseLocation`
    /// et `panel.frame` sont tous deux en coordonnées écran AppKit (bas-gauche).
    private func mouseIsOverPanel() -> Bool {
        panel.isVisible && panel.frame.contains(NSEvent.mouseLocation)
    }

    public func hide() {
        guard panel.isVisible else { return }
        autoHideTask?.cancel()
        hideGeneration &+= 1
        let g = hideGeneration
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.24
            panel.animator().alphaValue = 0
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard let self, self.hideGeneration == g else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        }
    }


    private func applyHeader(_ s: String) {
        // Façon « programme de théâtre » : capitales, légèrement espacées.
        header.attributedStringValue = NSAttributedString(
            string: s.uppercased(),
            attributes: [
                .font: header.font as Any,
                .foregroundColor: Self.goldHeader,
                .kern: 1.4,
            ])
    }

    // MARK: - Layout

    private func relayout() {
        body.stringValue = bodyText.isEmpty ? "…" : bodyText
        badge.stringValue = badgeText
        badge.isHidden = badgeText.isEmpty
        let pad: CGFloat = 14
        let gap: CGFloat = 8
        let headerH: CGFloat = 14
        let ruleTopGap: CGFloat = 7
        let ruleH: CGFloat = 1
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
        let total = pad + headerH + ruleTopGap + ruleH + gap + bodyH + badgeBlock + pad

        container.frame = NSRect(x: 0, y: 0, width: Self.width, height: total)
        header.frame = NSRect(x: pad, y: total - pad - headerH, width: bodyWidth, height: headerH)
        rule.frame = NSRect(x: pad, y: header.frame.minY - ruleTopGap, width: bodyWidth, height: ruleH)
        // Le badge occupe le bas (y = pad) ; le corps est posé au-dessus.
        badge.frame = NSRect(x: pad, y: pad, width: bodyWidth, height: badgeH)
        body.frame = NSRect(x: pad, y: pad + badgeBlock, width: bodyWidth, height: bodyH)

        // Position par défaut : bord GAUCHE du champ, juste AU-DESSUS de son bord
        // haut ; `savedOffset` (déplacement mémorisé) s'y ajoute ; clampé à l'écran.
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
        isPinnedByUser = true   // saisi par l'utilisateur → on ne l'auto-masque plus
        autoHideTask?.cancel()
        onMoved?(currentBundleID, offset)
    }
}
