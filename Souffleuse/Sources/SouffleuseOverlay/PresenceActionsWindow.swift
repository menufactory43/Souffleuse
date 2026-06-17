import AppKit

/// Palette d'actions ouverte au CLIC sur le badge de présence — donne un point
/// d'entrée DÉCOUVRABLE aux transformations « // » (corriger · raccourcir ·
/// reformuler · ton · traduire) sans avoir à taper le trigger. Contrairement au
/// `TransformPickerWindow` (sélection clavier seule, ancré au caret), ce panneau
/// est CLIQUABLE à la souris : c'est une apparition que l'utilisateur vient
/// chercher, pas un overlay qui suit la frappe.
///
/// Topologie identique aux autres apparitions (panneau non-activant niveau
/// status-bar, toutes-spaces) mais `ignoresMouseEvents = false` : l'app hôte
/// garde le focus clavier (panneau non-activant), seuls les clics sur les lignes
/// nous reviennent. Le module Overlay ne dépend pas de SouffleuseCore : l'API
/// prend des `[String]` déjà ordonnés, l'index de la ligne cliquée = la position
/// visuelle (badge ①–⑤). La logique à deux niveaux (« traduire » → langues) vit
/// chez l'appelant, qui ré-appelle `show` avec la nouvelle liste.
@MainActor
public final class PresenceActionsWindow {
    private let panel: NSPanel
    private let container: NSView
    private let titleLabel: NSTextField
    private let rule: NSView
    private var rows: [RowView] = []
    /// Nombre de lignes RÉELLEMENT affichées au dernier `show` — borne la
    /// sélection clavier (une touche au-delà est ignorée, comme le picker « // »).
    private var itemCount = 0

    /// Clic sur une ligne : index 0-based dans la liste passée au dernier `show`.
    private var onSelect: ((Int) -> Void)?
    /// Fermeture sans choix (clic hors panneau / auto-hide) — l'appelant en
    /// profite pour ré-armer le pipeline ghost.
    public var onDismiss: (() -> Void)?

    /// Moniteur de clic GLOBAL (events destinés aux AUTRES apps, le panneau étant
    /// non-activant) : tout clic ailleurs replie la palette. Local au cycle de vie
    /// du `show`, retiré au `hide`.
    private var outsideClickMonitor: Any?

    public private(set) var isVisible = false

    private static let titlePointSize: CGFloat = 11
    private static let labelPointSize: CGFloat = 13
    private static let badgeDiameter: CGFloat = 16
    private static let badgeGap: CGFloat = 7
    private static let rowHeight: CGFloat = 26
    private static let hPadding: CGFloat = 12
    private static let vPadding: CGFloat = 9
    private static let titleHeight: CGFloat = 16
    private static let titleGap: CGFloat = 6

    public init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 80),
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
        // Cliquable : c'est tout l'intérêt du panneau (le badge et les pickers
        // « // » sont, eux, click-through).
        panel.ignoresMouseEvents = false

        container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.borderWidth = 1
        panel.contentView = container

        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = LivretPalette.serif(size: Self.titlePointSize, italic: true)
        titleLabel.alignment = .left
        container.addSubview(titleLabel)

        rule = NSView()
        rule.wantsLayer = true
        container.addSubview(rule)
    }

    /// Affiche (ou remplace en place) la palette `items` sous le badge ancré à
    /// `anchorFrameAppKit` (frame AppKit du badge de présence). `title` coiffe la
    /// liste (ex. « Souffleuse · actions » ou « Traduire vers… »).
    public func show(
        title: String,
        items: [String],
        anchorFrameAppKit: NSRect,
        onSelect: @escaping (Int) -> Void
    ) {
        guard !items.isEmpty else { hide(); return }
        self.onSelect = onSelect
        self.itemCount = items.count
        applyColors()
        layout(title: title, items: items, anchorFrameAppKit: anchorFrameAppKit)
        if !panel.isVisible {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        installOutsideClickMonitor()
        isVisible = true
    }

    /// Sélection au CLAVIER (rangée 1–5) — strictement équivalente à un clic sur
    /// la ligne `rowIndex` (0-based). Une touche au-delà du nombre de lignes
    /// affichées est ignorée (le picker « // » se comporte pareil). L'appelant
    /// route ici les `digit(n)` du `KeyInterceptor` quand `isVisible`.
    public func selectByKeyboard(rowIndex: Int) {
        guard isVisible, rowIndex >= 0, rowIndex < itemCount else { return }
        commit(rowIndex)
    }

    /// Replie la palette. Idempotent. Ne déclenche PAS `onDismiss` (réservé au
    /// repli implicite par clic extérieur).
    public func hide() {
        removeOutsideClickMonitor()
        guard isVisible || panel.isVisible else { return }
        isVisible = false
        onSelect = nil
        itemCount = 0
        panel.orderOut(nil)
    }

    // MARK: - Mise en page

    private func layout(title: String, items: [String], anchorFrameAppKit: NSRect) {
        let dark = LivretPalette.isDark(container)

        // Recyclage des RowView entre deux `show` (passage actions → langues).
        while rows.count < items.count {
            let row = RowView()
            row.onClick = { [weak self] idx in self?.commit(idx) }
            container.addSubview(row)
            rows.append(row)
        }
        for (i, row) in rows.enumerated() {
            row.isHidden = i >= items.count
        }

        titleLabel.stringValue = title
        titleLabel.textColor = LivretPalette.accent(dark)
        titleLabel.sizeToFit()

        // Largeur = max(titre, lignes) ; chaque ligne = badge + écart + libellé.
        let badgeBlock = Self.badgeDiameter + Self.badgeGap
        var contentWidth = ceil(titleLabel.frame.width)
        for (i, text) in items.enumerated() {
            let w = rows[i].configure(index: i, label: text, dark: dark)
            contentWidth = max(contentWidth, badgeBlock + w)
        }
        let width = Self.hPadding * 2 + contentWidth
        let listHeight = CGFloat(items.count) * Self.rowHeight
        let height = Self.vPadding * 2 + Self.titleHeight + Self.titleGap + listHeight

        container.frame = NSRect(x: 0, y: 0, width: width, height: height)

        // Titre + filet en HAUT (AppKit : y grand = haut).
        titleLabel.frame = NSRect(
            x: Self.hPadding,
            y: height - Self.vPadding - Self.titleHeight,
            width: width - Self.hPadding * 2,
            height: Self.titleHeight)
        rule.layer?.backgroundColor = LivretPalette.rule(dark).cgColor
        rule.frame = NSRect(
            x: Self.hPadding,
            y: height - Self.vPadding - Self.titleHeight - Self.titleGap / 2,
            width: width - Self.hPadding * 2,
            height: 1)

        // Lignes de haut en bas, sous le filet.
        var y = height - Self.vPadding - Self.titleHeight - Self.titleGap - Self.rowHeight
        for i in 0..<items.count {
            rows[i].frame = NSRect(x: Self.hPadding, y: y, width: width - Self.hPadding * 2, height: Self.rowHeight)
            y -= Self.rowHeight
        }

        place(width: width, height: height, anchorFrameAppKit: anchorFrameAppKit)
    }

    private static let anchorGap: CGFloat = 4
    private static let screenMargin: CGFloat = 8

    /// Pose la palette sous le coin bas-gauche du badge — mais BASCULE au-dessus
    /// quand il n'y a pas la place en dessous (champ bas sur l'écran : la 5e ligne
    /// passait sous le bord, invisible). Le clamp se fait sur l'écran qui contient
    /// RÉELLEMENT le badge (pas `screens.first`, faux en multi-écran).
    private func place(width: CGFloat, height: CGFloat, anchorFrameAppKit: NSRect) {
        let frame = screenFrame(containing: anchorFrameAppKit)
        let gap = Self.anchorGap
        let margin = Self.screenMargin

        // Candidat « en dessous » (AppKit : y plus petit = plus bas) : top de la
        // palette aligné au bas du badge.
        let belowY = anchorFrameAppKit.minY - height - gap
        // Candidat « au-dessus » : bas de la palette aligné au haut du badge.
        let aboveY = anchorFrameAppKit.maxY + gap

        // Préfère en dessous ; bascule au-dessus si le bas déborde ET que le haut
        // tient. Sinon on garde le dessous et le clamp final le remontera.
        let y: CGFloat
        if belowY < frame.minY + margin && aboveY + height <= frame.maxY - margin {
            y = aboveY
        } else {
            y = belowY
        }

        // Clamp final dans les bornes de l'écran porteur (x et y).
        let x = min(max(frame.minX + margin, anchorFrameAppKit.minX),
                    max(frame.minX + margin, frame.maxX - width - margin))
        let clampedY = min(max(frame.minY + margin, y),
                           max(frame.minY + margin, frame.maxY - height - margin))
        panel.setFrame(NSRect(x: x, y: clampedY, width: width, height: height), display: true)
    }

    /// Cadre UTILE (hors Dock + barre de menus) de l'écran qui contient le badge ;
    /// repli sur l'écran principal. `visibleFrame` évite que la palette passe sous
    /// le Dock (en bas) ou la barre de menus (en haut).
    private func screenFrame(containing anchor: NSRect) -> NSRect {
        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    }

    private func applyColors() {
        let dark = LivretPalette.isDark(container)
        container.layer?.backgroundColor = LivretPalette.paper(dark).cgColor
        container.layer?.borderColor = LivretPalette.border(dark).cgColor
    }

    // MARK: - Sélection / repli

    private func commit(_ index: Int) {
        let handler = onSelect
        // Ne PAS appeler hide() ici : l'appelant décide (un choix « traduire »
        // ré-affiche la palette des langues ; un choix terminal la ferme).
        handler?(index)
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        // Panneau non-activant → un clic dans l'app HÔTE est un event « global ».
        // Un clic sur nos propres lignes est « local » (livré à la fenêtre, jamais
        // vu ici) : ce moniteur ne se déclenche donc que pour un clic EXTÉRIEUR.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self else { return }
            let dismiss = self.onDismiss
            self.hide()
            dismiss?()
        }
    }

    private func removeOutsideClickMonitor() {
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
    }
}

/// Une ligne cliquable : badge ①–⑤ + libellé, surlignage au survol. `mouseUp`
/// (et non `mouseDown`) pour laisser le geste s'annuler en sortant de la ligne.
private final class RowView: NSView {
    var onClick: ((Int) -> Void)?
    private var index = 0
    private let badge = NSTextField(labelWithString: "")
    private let label = NSTextField(labelWithString: "")
    private var hovering = false
    private var dark = false

    private static let badgeDiameter: CGFloat = 16
    private static let badgeGap: CGFloat = 7

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        badge.alignment = .center
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.cornerRadius = Self.badgeDiameter / 2
        addSubview(badge)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Configure la ligne et renvoie la largeur intrinsèque (badge + écart +
    /// libellé), pour que le conteneur dimensionne le panneau.
    @discardableResult
    func configure(index: Int, label text: String, dark: Bool) -> CGFloat {
        self.index = index
        self.dark = dark
        badge.stringValue = String(index + 1)
        badge.layer?.backgroundColor = LivretPalette.accent(dark).cgColor
        label.stringValue = text
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = LivretPalette.ink(dark)
        label.sizeToFit()
        applyHoverBackground()
        return Self.badgeDiameter + Self.badgeGap + ceil(label.frame.width)
    }

    override func layout() {
        super.layout()
        let badgeY = (bounds.height - Self.badgeDiameter) / 2
        badge.frame = NSRect(x: 0, y: badgeY, width: Self.badgeDiameter, height: Self.badgeDiameter)
        let labelH = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(
            x: Self.badgeDiameter + Self.badgeGap,
            y: (bounds.height - labelH) / 2,
            width: bounds.width - Self.badgeDiameter - Self.badgeGap,
            height: labelH)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        applyHoverBackground()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        applyHoverBackground()
    }

    override func mouseUp(with event: NSEvent) {
        // Ne valide que si le relâchement tombe DANS la ligne (geste non annulé).
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?(index)
    }

    private func applyHoverBackground() {
        layer?.backgroundColor = hovering
            ? LivretPalette.accent(dark).withAlphaComponent(0.14).cgColor
            : NSColor.clear.cgColor
    }
}
