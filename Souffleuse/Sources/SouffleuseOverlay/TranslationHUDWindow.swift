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
    private var anchorRectQuartz: CGRect = .zero
    private var bodyText: String = ""
    private var badgeText: String = ""
    private var savedOffset: CGSize = .zero
    private var currentBundleID: String?
    private var defaultOriginAppKit: CGPoint = .zero
    /// Vrai dès que l'utilisateur a fait glisser le panneau pendant cet affichage.
    public private(set) var isPinnedByUser = false
    private var programmaticMove = false
    public var onMoved: (@MainActor (String?, CGSize) -> Void)?

    private var autoHideTask: Task<Void, Never>?
    private var hideGeneration = 0
    /// Intervalle de re-sondage tant que la souris reste sur le panneau.
    private static let hoverRecheckSeconds: Double = 1.0

    public static let width: CGFloat = 320

    // MARK: - Palette « livret » (papier crème · encre · bordeaux)
    private static let paper = NSColor(srgbRed: 0.937, green: 0.914, blue: 0.843, alpha: 0.98)
    private static let ink = NSColor(srgbRed: 0.12, green: 0.10, blue: 0.085, alpha: 1)
    private static let burgundy = NSColor(srgbRed: 0.46, green: 0.17, blue: 0.17, alpha: 1)
    private static let ruleColor = NSColor(srgbRed: 0.30, green: 0.24, blue: 0.20, alpha: 0.45)
    private static let border = NSColor(srgbRed: 0.46, green: 0.17, blue: 0.17, alpha: 0.38)

    /// Serif d'affichage façon livret : Didot si présent (macOS), sinon le serif
    /// système (New York). `italic` pour la note en marge.
    private static func didot(size: CGFloat, italic: Bool = false) -> NSFont {
        if let d = NSFont(name: italic ? "Didot-Italic" : "Didot", size: size) { return d }
        return serif(size: size, italic: italic)
    }
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
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true

        container = HoverView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 80))
        container.wantsLayer = true
        container.layer?.backgroundColor = Self.paper.cgColor
        container.layer?.cornerRadius = 6
        container.layer?.borderWidth = 1
        container.layer?.borderColor = Self.border.cgColor

        header = NSTextField(labelWithString: "")
        header.alignment = .center

        ruleLeft = NSView();  ruleLeft.wantsLayer = true;  ruleLeft.layer?.backgroundColor = Self.ruleColor.cgColor
        ruleRight = NSView(); ruleRight.wantsLayer = true; ruleRight.layer?.backgroundColor = Self.ruleColor.cgColor

        body = NSTextField(wrappingLabelWithString: "")
        body.font = Self.serif(size: 15)
        body.textColor = Self.ink
        body.alignment = .center
        body.maximumNumberOfLines = 0
        body.lineBreakMode = .byWordWrapping

        badge = NSTextField(wrappingLabelWithString: "")
        badge.font = Self.serif(size: 11, italic: true)
        badge.textColor = Self.burgundy
        badge.alignment = .center
        badge.maximumNumberOfLines = 0
        badge.lineBreakMode = .byWordWrapping
        badge.isHidden = true

        container.addSubview(ruleLeft)
        container.addSubview(ruleRight)
        container.addSubview(header)
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
        hideGeneration &+= 1
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

    /// En-tête « programme » : Didot, capitales, généreusement espacé, bordeaux.
    private func applyHeader(_ s: String) {
        header.attributedStringValue = NSAttributedString(
            string: s.uppercased(),
            attributes: [
                .font: Self.didot(size: 11),
                .foregroundColor: Self.burgundy,
                .kern: 2.2,
            ])
    }

    // MARK: - Layout

    private func relayout() {
        body.stringValue = bodyText.isEmpty ? "…" : bodyText
        badge.stringValue = badgeText
        badge.isHidden = badgeText.isEmpty
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
        let total = pad + headerH + headerGap + bodyH + badgeBlock + pad

        container.frame = NSRect(x: 0, y: 0, width: Self.width, height: total)

        // En-tête centré, encadré de deux filets (motif « —— PROGRAMME —— »).
        let headerY = total - pad - headerH
        let headerW = min(ceil(header.attributedStringValue.size().width) + 2, bodyWidth)
        let headerX = ((Self.width - headerW) / 2).rounded()
        header.frame = NSRect(x: headerX, y: headerY, width: headerW, height: headerH)
        let ruleY = (headerY + headerH / 2).rounded()
        let ruleSideGap: CGFloat = 12
        let leftW = max(0, headerX - ruleSideGap - pad)
        ruleLeft.frame = NSRect(x: pad, y: ruleY, width: leftW, height: 1)
        let rightX = headerX + headerW + ruleSideGap
        ruleRight.frame = NSRect(x: rightX, y: ruleY, width: max(0, (Self.width - pad) - rightX), height: 1)

        // Corps + badge ancrés en bas (le panneau croît vers le haut au streaming).
        badge.frame = NSRect(x: pad, y: pad, width: bodyWidth, height: badgeH)
        body.frame = NSRect(x: pad, y: pad + badgeBlock, width: bodyWidth, height: bodyH)

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
