import AppKit
import Foundation
import IOKit.hid
import SouffleuseAX
import SouffleuseContext
import SouffleuseCore

/// Le filet d'identité « théâtre » toléré sur cette surface — un *moment à soi*,
/// pas une UI qui se rend dans l'app d'un autre. Trois gouttes seulement : le
/// sang-de-bœuf sur l'action + le cue en attente, un serif sur les titres. La
/// structure reste 100 % AppKit natif (contrôles, couleurs sémantiques système).
private enum Brand {
    /// Sang-de-bœuf plein (#8c2b21, `--rouge` du site) — pour un REMPLISSAGE
    /// (bezel du bouton), où le texte blanc par-dessus garde le contraste dans
    /// les deux modes. `var` calculée : évite un `static let` non-`Sendable`.
    static var inkRed: NSColor {
        NSColor(srgbRed: 0x8c / 255, green: 0x2b / 255, blue: 0x21 / 255, alpha: 1)
    }

    /// Le cue sang-de-bœuf en tant que TEXTE sur le fond fenêtre — éclairci en
    /// dark mode pour rester lisible (≥4.5:1). Le site vit toujours sur paper
    /// clair ; l'app, non — d'où la variante dynamique.
    static var cue: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return dark
                ? NSColor(srgbRed: 0xd0 / 255, green: 0x6a / 255, blue: 0x5d / 255, alpha: 1)
                : NSColor(srgbRed: 0x8c / 255, green: 0x2b / 255, blue: 0x21 / 255, alpha: 1)
        }
    }

    /// Serif système (New York) — le « marquee » discret, dark-mode et Dynamic
    /// Type friendly. On reste sur le *design* serif plutôt qu'une fonte de marque
    /// non garantie sur le système (Bodoni/Spectral ne sont pas natifs).
    static func serif(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let d = base.fontDescriptor.withDesign(.serif) else { return base }
        return NSFont(descriptor: d, size: size) ?? base
    }

    /// Serif italique — la voix « didascalie » (sous-titre, en-têtes de section).
    static func serifItalic(_ size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .regular)
        let d = (base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor)
            .withSymbolicTraits(.italic)
        return NSFont(descriptor: d, size: size) ?? base
    }
}

/// First-launch window. Walks the user through the steps needed before
/// Souffleuse can actually souffler :
///   1. Accessibility — requise (lire/écrire le champ focalisé).
///   2. Input Monitoring — requise (intercepter Tab/Esc).
///   3. Modèle du souffle (GGUF) — REQUIS : sans lui, `canGenerate == false`,
///      donc aucun ghost. Téléchargé in-app si absent.
///   4. Modèle de traduction — OPTIONNEL (la traduction marche sans, au premier
///      usage le download se déclenchera de toute façon).
///   5. Screen Recording — OPTIONNEL : l'OCR/capture est opt-in, off par défaut.
///      Le bouton « Autoriser » frappe ScreenCaptureKit pour enregistrer le
///      bundle dans TCC (sinon l'app n'apparaît même pas dans la liste Réglages).
///
/// Le bouton « Commencer à écrire » ne s'active qu'une fois les étapes REQUISES
/// satisfaites (AX + Input Monitoring + modèle du souffle prêt). Re-check toutes
/// les secondes pendant que la fenêtre est ouverte → l'utilisateur voit les ✓
/// basculer et la progression de téléchargement avancer en direct.
@MainActor
final class OnboardingWindow {
    private let window: NSWindow
    private let axRow: PermissionRow
    private let imRow: PermissionRow
    private let screenRow: PermissionRow
    private let ghostRow: ModelRow?
    private let translationRow: ModelRow?
    private let finishButton = NSButton(title: "Commencer à écrire", target: nil, action: nil)
    private var finishTarget: ClosureButtonTarget?
    /// Cible du sélecteur de langue — gardée vivante le temps de la fenêtre.
    private var languageTarget: ClosureButtonTarget?
    private var refreshTimer: Timer?
    /// Appelé une fois quand le modèle du souffle PASSE de absent → installé
    /// pendant que la fenêtre est ouverte (fin de téléchargement). Permet à
    /// l'AppDelegate de recharger le moteur sans relancer l'app.
    private let onGhostInstalled: (@MainActor () -> Void)?
    /// État ghost-prêt au dernier `refresh` — `nil` avant le premier. Sert à ne
    /// déclencher `onGhostInstalled` que sur une vraie transition (pas si le
    /// modèle était déjà là au démarrage : le moteur l'a alors chargé au launch).
    private var lastGhostReady: Bool?

    /// - Parameters:
    ///   - modelDownloads: gestionnaire de téléchargement partagé (états `@Observable`).
    ///   - ghost: descripteur du modèle de souffle à proposer (nil = non téléchargeable,
    ///     l'étape ne bloque alors pas).
    ///   - ghostReady: vrai quand le GGUF du souffle est résolvable sur disque — y
    ///     compris via le dossier Cotypist legacy, que `ModelDownloadManager` ne voit pas.
    ///   - translation: descripteur du modèle de traduction (optionnel).
    init(
        modelDownloads: ModelDownloadManager,
        ghostProvider: @escaping () -> DownloadableModel?,
        ghostReady: @escaping () -> Bool,
        translation: DownloadableModel?,
        initialLanguage: PrimaryLanguage,
        onLanguageChange: @escaping @MainActor (PrimaryLanguage) -> Void,
        onGhostInstalled: (@MainActor () -> Void)? = nil
    ) {
        self.onGhostInstalled = onGhostInstalled
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Bienvenue dans Souffleuse"
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window

        // Titres = libellés EXACTS des volets Réglages › Confidentialité en
        // français (« Accessibilité », « Surveillance des entrées ») : ce que
        // l'utilisateur va voir à l'écran, pas le terme TCC anglais.
        self.axRow = PermissionRow(
            title: "Accessibilité",
            description: "Lit le champ de saisie où vous êtes, et y écrit la suggestion que vous acceptez.",
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!,
            isGranted: { AXClientIsTrusted() }
        )

        self.imRow = PermissionRow(
            title: "Surveillance des entrées",
            description: "Capte Tab et Esc, et seulement eux, quand une suggestion est à l'écran.",
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!,
            isGranted: { InputMonitoringIsTrusted() }
        )

        // Capture écran : optionnelle. Le bouton « Autoriser » frappe
        // ScreenCaptureKit directement — seul moyen fiable de faire apparaître
        // l'app dans Réglages › Confidentialité › Enregistrement de l'écran (un
        // simple lien Réglages ne suffit pas tant que le bundle n'est pas
        // enregistré dans TCC).
        self.screenRow = PermissionRow(
            title: "Enregistrement de l'écran",
            description: "Optionnel — laissez Souffleuse lire ce qui est à l'écran (OCR) pour des suggestions plus justes. Reste éteint tant que vous ne l'accordez pas.",
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!,
            optional: true,
            actionTitle: "Autoriser",
            action: { Task { await ScreenCapturer.forcePermissionPrompt() } },
            isGranted: { ScreenCapturer.hasPermission() }
        )

        // Modèle du souffle : requis. La voix proposée SUIT la langue choisie
        // (provider relu à chaque refresh) — change la langue et le téléchargement
        // proposé bascule sur la voix conseillée. `ghostReady` couvre aussi le
        // GGUF déjà présent via Cotypist (dossier legacy) → pas de re-DL inutile.
        self.ghostRow = ghostProvider().map { initial in
            ModelRow(
                title: "Modèle du souffle",
                description: "Requis — le moteur local qui souffle vos suggestions. Une minute environ, 100 % sur votre Mac, rien ne sort.",
                model: initial,
                manager: modelDownloads,
                optional: false,
                isReady: ghostReady,
                modelProvider: ghostProvider
            )
        }

        self.translationRow = translation.map { model in
            ModelRow(
                title: "Modèle de traduction",
                description: "Optionnel — pour la traduction et la relecture par ton. Téléchargé tout seul au premier usage si vous passez.",
                model: model,
                manager: modelDownloads,
                optional: true,
                isReady: { modelDownloads.isReady(model) }
            )
        }

        let title = NSTextField(labelWithString: "Quelques réglages, puis on s'efface")
        title.font = Brand.serif(21, .semibold)

        let subtitle = NSTextField(wrappingLabelWithString: "Souffleuse vit dans votre barre de menus et souffle le mot juste là où vous écrivez. Voici ce qu'il lui faut pour entrer en scène.")
        subtitle.font = Brand.serifItalic(12.5)
        subtitle.textColor = .secondaryLabelColor

        finishButton.bezelStyle = .rounded
        finishButton.keyEquivalent = "\r"
        let finishTarget = ClosureButtonTarget { [weak self] in self?.close() }
        self.finishTarget = finishTarget
        finishButton.target = finishTarget
        finishButton.action = #selector(ClosureButtonTarget.fire)

        // Étape langue : un choix sobre qui pilote la voix conseillée (et la voix
        // proposée au téléchargement juste en dessous). Mémorisé dans les prefs.
        let languageControl = NSSegmentedControl(
            labels: PrimaryLanguage.allCases.map(\.label),
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        languageControl.selectedSegment = (initialLanguage == .french) ? 0 : 1
        let languageTarget = ClosureButtonTarget { [weak self, weak languageControl] in
            guard let languageControl else { return }
            let lang: PrimaryLanguage = languageControl.selectedSegment == 0 ? .french : .multilingual
            onLanguageChange(lang)
            // La voix proposée juste en dessous bascule aussitôt sur la conseillée.
            self?.refresh()
        }
        self.languageTarget = languageTarget
        languageControl.target = languageTarget
        languageControl.action = #selector(ClosureButtonTarget.fire)

        let languageDesc = NSTextField(wrappingLabelWithString: "Sert à vous conseiller la bonne voix : en français, une petite voix rapide suffit ; pour plusieurs langues, une voix multilingue. Modifiable à tout moment.")
        languageDesc.font = .systemFont(ofSize: 11)
        languageDesc.textColor = .secondaryLabelColor
        let languageColumn = NSStackView(views: [languageControl, languageDesc])
        languageColumn.orientation = .vertical
        languageColumn.alignment = .leading
        languageColumn.spacing = 6

        var rows: [NSView] = [
            title, subtitle,
            sectionHeader("Les permissions"),
            axRow.view, imRow.view, screenRow.view,
        ]
        rows.append(sectionHeader("Votre langue"))
        rows.append(languageColumn)
        rows.append(sectionHeader("Les modèles, sur votre Mac"))
        if let ghostRow { rows.append(ghostRow.view) }
        if let translationRow { rows.append(translationRow.view) }
        rows.append(finishButton)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Scroll view : le contenu peut dépasser la hauteur fixe selon les étapes
        // affichées — on ne veut jamais clipper un bouton.
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc

        let content = NSView()
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        window.contentView = content
    }

    func show() {
        refresh()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func close() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        window.orderOut(nil)
    }

    private func refresh() {
        axRow.refresh()
        imRow.refresh()
        screenRow.refresh()
        ghostRow?.refresh()
        translationRow?.refresh()
        // Transition absent → installé du souffle pendant la session : recharge
        // le moteur (sinon il reste vide jusqu'au prochain lancement). On ignore
        // le tout premier refresh (`lastGhostReady == nil`) : un modèle déjà prêt
        // au démarrage a été chargé au launch, pas la peine de recharger.
        let ghostReadyNow = ghostRow?.ready ?? true
        if lastGhostReady == false, ghostReadyNow {
            onGhostInstalled?()
        }
        lastGhostReady = ghostReadyNow
        // Étapes requises : AX + Input Monitoring + modèle du souffle prêt.
        // Traduction et écran sont optionnels → ne bloquent pas.
        let ready = axRow.granted && imRow.granted && ghostReadyNow
        updateFinishButton(enabled: ready)
    }

    private func sectionHeader(_ text: String) -> NSTextField {
        // Didascalie : serif italique en minuscules, jamais l'eyebrow capitales
        // trackées (le tell anti-marque que le système remplace par l'italique).
        let label = NSTextField(labelWithString: text)
        label.font = Brand.serifItalic(13)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Style le bouton de fin : sang-de-bœuf plein + texte blanc quand l'action
    /// est ouverte (la marque marque l'action), bouton neutre désactivé sinon.
    private func updateFinishButton(enabled: Bool) {
        finishButton.isEnabled = enabled
        let label = "Commencer à écrire"
        finishButton.bezelColor = enabled ? Brand.inkRed : nil
        finishButton.attributedTitle = NSAttributedString(string: label, attributes: [
            .foregroundColor: enabled ? NSColor.white : NSColor.tertiaryLabelColor,
            .font: Brand.serif(13, .semibold),
        ])
    }
}

// MARK: - Permission row

@MainActor
private final class PermissionRow {
    let view: NSView
    private(set) var granted: Bool = false

    private let statusLabel = NSTextField(labelWithString: "")
    private let isGranted: () -> Bool
    private let optional: Bool
    private var actionTarget: ClosureButtonTarget?

    init(
        title: String,
        description: String,
        settingsURL: URL,
        optional: Bool = false,
        actionTitle: String? = nil,
        action: (@MainActor () -> Void)? = nil,
        isGranted: @escaping () -> Bool
    ) {
        self.isGranted = isGranted
        self.optional = optional

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: 13)

        let descLabel = NSTextField(wrappingLabelWithString: description)
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = .secondaryLabelColor

        statusLabel.font = .systemFont(ofSize: 13)

        var buttons: [NSView] = []
        // Bouton d'action direct (ex. « Autoriser » → prompt système) avant le
        // lien Réglages, quand fourni.
        if let actionTitle, let action {
            let actionButton = NSButton(title: actionTitle, target: nil, action: nil)
            actionButton.bezelStyle = .rounded
            let target = ClosureButtonTarget(action)
            self.actionTarget = target
            actionButton.target = target
            actionButton.action = #selector(ClosureButtonTarget.fire)
            buttons.append(actionButton)
        }
        let settingsButton = NSButton(title: "Ouvrir Réglages", target: nil, action: nil)
        settingsButton.bezelStyle = .rounded
        settingsButton.target = OnboardingButtonTarget.shared
        settingsButton.action = #selector(OnboardingButtonTarget.openURL(_:))
        settingsButton.identifier = NSUserInterfaceItemIdentifier(settingsURL.absoluteString)
        buttons.append(settingsButton)

        let titleRow = NSStackView(views: [titleLabel, NSView(), statusLabel])
        titleRow.orientation = .horizontal
        titleRow.distribution = .fill
        titleRow.alignment = .firstBaseline

        let buttonRow = NSStackView(views: buttons)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let column = NSStackView(views: [titleRow, descLabel, buttonRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        self.view = column
    }

    func refresh() {
        granted = isGranted()
        if granted {
            // Accordée → l'état se retire, calme (la souffleuse s'efface).
            statusLabel.stringValue = "✓ accordée"
            statusLabel.textColor = .secondaryLabelColor
        } else if optional {
            statusLabel.stringValue = "optionnel"
            statusLabel.textColor = .tertiaryLabelColor
        } else {
            // En attente d'une action requise → le cue sang-de-bœuf, pas un ✗ rouge.
            statusLabel.stringValue = "à accorder"
            statusLabel.textColor = Brand.cue
        }
    }
}

// MARK: - Model download row

@MainActor
private final class ModelRow {
    let view: NSView
    private(set) var ready: Bool = false

    /// Voix courante. `var` car elle peut SUIVRE la langue (via `modelProvider`) :
    /// l'utilisateur change de langue → la voix proposée bascule sans reconstruire la ligne.
    private var model: DownloadableModel
    /// Quand fourni, relu à chaque `refresh()` pour suivre la voix conseillée.
    /// Retourne `nil` si aucune voix n'est téléchargeable → on garde la dernière.
    private let modelProvider: (() -> DownloadableModel?)?
    private let manager: ModelDownloadManager
    private let optional: Bool
    /// Prêt « hors gestionnaire » : couvre le GGUF déjà présent sur disque
    /// (y compris dossier Cotypist legacy) que `ModelDownloadManager` n'inspecte pas.
    private let isReadyExternally: () -> Bool

    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private var actionTarget: ClosureButtonTarget?

    init(
        title: String,
        description: String,
        model: DownloadableModel,
        manager: ModelDownloadManager,
        optional: Bool,
        isReady: @escaping () -> Bool,
        modelProvider: (() -> DownloadableModel?)? = nil
    ) {
        self.model = model
        self.modelProvider = modelProvider
        self.manager = manager
        self.optional = optional
        self.isReadyExternally = isReady

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: 13)

        let descLabel = NSTextField(wrappingLabelWithString: description)
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = .secondaryLabelColor

        statusLabel.font = .systemFont(ofSize: 13)

        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        progress.isHidden = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.widthAnchor.constraint(equalToConstant: 140).isActive = true

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small

        let titleRow = NSStackView(views: [titleLabel, NSView(), statusLabel])
        titleRow.orientation = .horizontal
        titleRow.distribution = .fill
        titleRow.alignment = .firstBaseline

        let controlRow = NSStackView(views: [actionButton, progress])
        controlRow.orientation = .horizontal
        controlRow.spacing = 8

        let column = NSStackView(views: [titleRow, descLabel, controlRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        self.view = column

        // Câblé APRÈS `self.view` : la closure capture `self`, ce qui exige que
        // toutes les propriétés stockées (dont `view`) soient initialisées.
        let target = ClosureButtonTarget { [weak self] in
            guard let self else { return }
            // Toujours télécharger la voix COURANTE (peut avoir suivi la langue).
            if let m = self.modelProvider?() { self.model = m }
            self.manager.download(self.model)
            self.refresh()
        }
        self.actionTarget = target
        actionButton.target = target
        actionButton.action = #selector(ClosureButtonTarget.fire)
    }

    func refresh() {
        // Suit la langue : la voix proposée peut avoir changé depuis le dernier refresh.
        if let m = modelProvider?() { model = m }
        // Déjà sur disque (téléchargé OU présent via Cotypist) → étape satisfaite.
        if isReadyExternally() {
            setReady()
            return
        }
        switch manager.status(for: model) {
        case .ready:
            setReady()
        case .downloading(let p):
            ready = false
            progress.isHidden = false
            progress.doubleValue = p
            actionButton.isHidden = true
            statusLabel.stringValue = "\(Int(p * 100)) %"
            statusLabel.textColor = .secondaryLabelColor
        case .absent:
            ready = false
            progress.isHidden = true
            actionButton.isHidden = false
            actionButton.title = "Télécharger (\(model.approxSizeMB) Mo)"
            statusLabel.stringValue = optional ? "optionnel" : "à télécharger"
            statusLabel.textColor = optional ? .tertiaryLabelColor : Brand.cue
        case .failed:
            ready = false
            progress.isHidden = true
            actionButton.isHidden = false
            actionButton.title = "Réessayer"
            statusLabel.stringValue = "échec"
            statusLabel.textColor = Brand.cue
        }
    }

    private func setReady() {
        ready = true
        progress.isHidden = true
        actionButton.isHidden = true
        statusLabel.stringValue = "✓ installé"
        statusLabel.textColor = .secondaryLabelColor
    }
}

// MARK: - Button targets

/// `NSView` retournant `isFlipped == true` pour empiler le contenu du haut vers
/// le bas dans le `NSScrollView` (sinon AppKit ancre en bas).
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Cible générique pour un `NSButton` pilotant une closure `@MainActor`.
@MainActor
private final class ClosureButtonTarget: NSObject {
    private let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
        super.init()
    }
    @objc func fire() { action() }
}

@MainActor
final class OnboardingButtonTarget: NSObject {
    static let shared = OnboardingButtonTarget()
    @objc func openURL(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let url = URL(string: id) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Permission check helpers

@MainActor
private func AXClientIsTrusted() -> Bool {
    AXClient.isTrusted
}

@MainActor
private func InputMonitoringIsTrusted() -> Bool {
    IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
}
