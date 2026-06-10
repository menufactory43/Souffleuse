import AppKit
import ServiceManagement
import SouffleuseAX
import SouffleuseContext
import SouffleuseCore
import SouffleuseInput
import SouffleusePersonalization
import SwiftUI

private extension Color {
    /// Sang-de-bœuf (#8c2b21, `--rouge` du site) — la voix unique de la marque,
    /// posée en `.tint` sur toute la fenêtre Préférences pour remplacer le bleu
    /// système. Éclairci en dark mode pour rester lisible (le site vit toujours
    /// sur paper clair ; l'app, non). C'est le whisper sanctionné de cette
    /// surface : l'accent, pas une refonte — la structure reste native.
    static var sangDeBoeuf: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return dark
                ? NSColor(srgbRed: 0xd0 / 255, green: 0x6a / 255, blue: 0x5d / 255, alpha: 1)
                : NSColor(srgbRed: 0x8c / 255, green: 0x2b / 255, blue: 0x21 / 255, alpha: 1)
        })
    }
}

@MainActor
final class PreferencesWindow {
    private var window: NSWindow?
    private let store: PreferencesStore
    private let onModelChange: (String) -> Void
    private let onCaptureToggle: (Bool) -> Void
    private let onOpenOnboarding: () -> Void
    private let onOpenHistoryViewer: () -> Void
    private let onClearPersonalization: () -> Void

    init(
        store: PreferencesStore,
        onModelChange: @escaping (String) -> Void,
        onCaptureToggle: @escaping (Bool) -> Void,
        onOpenOnboarding: @escaping () -> Void,
        onOpenHistoryViewer: @escaping () -> Void,
        onClearPersonalization: @escaping () -> Void
    ) {
        self.store = store
        self.onModelChange = onModelChange
        self.onCaptureToggle = onCaptureToggle
        self.onOpenOnboarding = onOpenOnboarding
        self.onOpenHistoryViewer = onOpenHistoryViewer
        self.onClearPersonalization = onClearPersonalization
    }

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = PreferencesRoot(
            store: store,
            onModelChange: onModelChange,
            onCaptureToggle: onCaptureToggle,
            onOpenOnboarding: onOpenOnboarding,
            onOpenHistoryViewer: onOpenHistoryViewer,
            onClearPersonalization: onClearPersonalization
        )
        let host = NSHostingController(rootView: root)
        host.view.frame = NSRect(x: 0, y: 0, width: 660, height: 520)

        let w = NSWindow(contentViewController: host)
        w.title = "Préférences"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.setContentSize(NSSize(width: 660, height: 520))
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}

private struct PreferencesRoot: View {
    @Bindable var store: PreferencesStore
    let onModelChange: (String) -> Void
    let onCaptureToggle: (Bool) -> Void
    let onOpenOnboarding: () -> Void
    let onOpenHistoryViewer: () -> Void
    let onClearPersonalization: () -> Void

    // Onglets organisés par FONCTION (les piliers de l'app), pas par accumulation
    // historique : Souffle · Traduction · Ton réunissent chacun tout ce qui touche
    // leur fonction (modèle compris, posé près de ce qu'il affecte). Réglages
    // centralise activation + autorisations + démarrage ; À propos reste l'identité.
    var body: some View {
        TabView {
            SouffleTab(store: store)
                .tabItem { Label("Souffle", systemImage: "wind") }
            TranslationTab(store: store)
                .tabItem { Label("Traduction", systemImage: "globe") }
            ToneTab(store: store)
                .tabItem { Label("Ton", systemImage: "textformat") }
            PersonalizationTab(
                store: store,
                onOpenViewer: onOpenHistoryViewer,
                onClearAll: onClearPersonalization
            )
            .tabItem { Label("Personnalisation", systemImage: "person.crop.circle.badge.checkmark") }
            EnrichmentTab(store: store, onCaptureToggle: onCaptureToggle)
                .tabItem { Label("Contexte", systemImage: "doc.text.magnifyingglass") }
            AllowlistTab(store: store)
                .tabItem { Label("Par application", systemImage: "list.bullet.rectangle") }
            ReglagesTab(store: store, onOpenOnboarding: onOpenOnboarding)
                .tabItem { Label("Réglages", systemImage: "gearshape") }
            AboutTab()
                .tabItem { Label("À propos", systemImage: "info.circle") }
        }
        .padding(20)
        .frame(width: 660, height: 520)
        // La voix unique : un seul accent sang-de-bœuf irrigue toggles, sliders,
        // radios et boutons de toute la fenêtre, à la place du bleu système.
        .tint(.sangDeBoeuf)
    }
}

private struct PersonalizationTab: View {
    @Bindable var store: PreferencesStore
    let onOpenViewer: () -> Void
    let onClearAll: () -> Void

    @State private var entryCount: Int = 0
    @State private var sizeBytes: Int = 0
    @State private var showingOnboarding = false
    @State private var showingClearConfirm = false

    var body: some View {
        Form {
            Section {
                Toggle("Apprendre votre plume", isOn: $store.personalizationEnabled)
                    .onChange(of: store.personalizationEnabled) { _, on in
                        if on && !store.personalizationOnboardingShown {
                            showingOnboarding = true
                        }
                    }
                Text("Gardé sous clé sur votre Mac. Rien ne part en ligne.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Retenir aussi ce que vous écrivez sans accepter", isOn: $store.storeWithoutAccepted)
                    .disabled(!store.personalizationEnabled)
                Text("Souffleuse apprend alors de tout ce que vous tapez, pas seulement des suggestions retenues — un meilleur reflet de votre style. À éviter si vous écrivez des choses sensibles.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("Apprendre de vous").font(.headline)
            }

            Section {
                VStack(alignment: .leading) {
                    Slider(
                        value: $store.personalizationStrength,
                        in: 0.0...2.0
                    ) {
                        Text("Influence")
                    } minimumValueLabel: {
                        Text("Off").font(.callout).foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Text("Max").font(.callout).foregroundStyle(.secondary)
                    }
                    .disabled(!store.personalizationEnabled)
                    Text(String(format: "Valeur : %.2f", store.personalizationStrength))
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Son influence").font(.headline)
            } footer: {
                Text("À zéro, Souffleuse observe sans rien changer. Au maximum, vos tournures familières reviennent fortement.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("Phrases retenues")
                    Spacer()
                    Text("\(entryCount)").font(.system(.body, design: .monospaced))
                }
                HStack {
                    Text("Place occupée")
                    Spacer()
                    Text(formatBytes(sizeBytes)).font(.system(.body, design: .monospaced))
                }
                HStack {
                    Button("Consulter…", action: onOpenViewer)
                    Spacer()
                    Button(role: .destructive) {
                        showingClearConfirm = true
                    } label: {
                        Text("Tout supprimer…")
                    }
                }
            } header: {
                Text("Mes données").font(.headline)
            }
        }
        .formStyle(.grouped)
        .task(id: store.personalizationEnabled) { await refresh() }
        .alert("Apprendre votre plume ?", isPresented: $showingOnboarding) {
            Button("Annuler", role: .cancel) {
                store.personalizationEnabled = false
            }
            Button("Apprendre") {
                store.personalizationOnboardingShown = true
            }
        } message: {
            Text("Souffleuse retiendra les phrases que vous acceptez, pour mieux vous souffler la suite. Tout est gardé sous clé sur votre Mac, jamais envoyé en ligne. Vous pouvez tout consulter ou tout effacer ici, à tout moment.")
        }
        .confirmationDialog(
            "Effacer tout ce que Souffleuse a retenu ?",
            isPresented: $showingClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Tout effacer", role: .destructive) {
                onClearAll()
                Task { await refresh() }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Tout ce que Souffleuse a retenu disparaît pour de bon. Sans retour.")
        }
    }

    private func refresh() async {
        entryCount = await store.history.count()
        sizeBytes = await store.history.sizeBytes()
    }

    private func formatBytes(_ b: Int) -> String {
        if b < 1024 { return "\(b) o" }
        let kb = Double(b) / 1024.0
        return String(format: "%.1f Ko", kb)
    }
}

/// Onglet SOUFFLE — tout ce qui façonne la suggestion fantôme : la voix (modèle
/// GGUF) qui la génère, sa longueur, la manière de l'accepter, et les petites
/// corrections de frappe. Le modèle vit ICI, près de ce qu'il affecte, plutôt
/// que dans un onglet « Modèle » séparé qu'il fallait deviner.
private struct SouffleTab: View {
    @Bindable var store: PreferencesStore

    var body: some View {
        Form {
            GhostModelSection(store: store)

            Section {
                Picker("Longueur du souffle", selection: $store.completionLength) {
                    ForEach(CompletionLength.allCases, id: \.self) { l in
                        Text(l.label).tag(l)
                    }
                }
            } header: {
                Text("La longueur").font(.headline)
            } footer: {
                Text("Plus c'est long, plus ça peut s'éloigner de votre intention. Tab accepte ; Esc écarte.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Souffler au milieu d'une ligne", isOn: $store.midLineGhostEnabled)
                Text("Quand le curseur est posé au milieu d'un texte, le souffle apparaît dans une petite bulle sous la ligne (au lieu de rester muet). Tab l'insère à l'endroit du curseur.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("Au milieu d'une ligne").font(.headline)
            }

            Section {
                Toggle("Accepter mot à mot", isOn: $store.partialAcceptEnabled)
                Text("Tab pose un mot ; le reste attend en gris. Tab encore pour le suivant, Esc pour tout écarter.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Ajouter l'espace après le mot", isOn: $store.trailingSpaceOnPartial)
                    .disabled(!store.partialAcceptEnabled)
                Text("Le curseur se place, prêt pour la suite. Désactivez pour gérer l'espace vous-même.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Tout accepter avec", selection: $store.acceptAllKey) {
                    ForEach(AcceptAllKey.allCases, id: \.self) { key in
                        Text(key.label).tag(key)
                    }
                }
                Text("Une touche qui pose toute la réplique d'un coup — active seulement quand un souffle s'affiche, donc elle ne gêne jamais votre frappe.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("Accepter le souffle").font(.headline)
            }

            Section {
                Toggle("Corriger les coquilles", isOn: $store.typoEnabled)
                Toggle("Se taire quand une coquille est en cours", isOn: $store.hideOnTypo)
                    .disabled(!store.typoEnabled)
                Toggle("Emoji — panneau dès « \u{003A} » et expansion (\u{003A}smile\u{003A} → 😄)", isOn: $store.emojiEnabled)
                Toggle("Corriger le texte avant de souffler", isOn: $store.prefixCorrectionEnabled)
            } header: {
                Text("Corrections").font(.headline)
            } footer: {
                Text("Mis en sommeil dans Xcode, VS Code, JetBrains et les terminaux. La correction ne change que ce que voit Souffleuse — votre texte reste tel que tapé.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Onglet TRADUCTION — extrait de l'ancien « Général » où il était noyé dans la
/// section d'acceptation du ghost. La traduction est un pilier de l'app, au même
/// rang que « Ton » : elle a désormais sa surface propre (moteur + raccourcis),
/// son modèle posé près de sa fonction.
private struct TranslationTab: View {
    @Bindable var store: PreferencesStore

    var body: some View {
        Form {
            Section {
                Picker("Modèle de traduction", selection: $store.translationModel) {
                    ForEach(InstructModel.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                Text("Le moteur de traduction (le souffle français reste inchangé). Qwen 2.5 1.5B traduit mieux l'allemand/italien/japonais mais tient ~1 Go de RAM en plus pendant l'usage — libéré après inactivité. Le changement prend effet à la prochaine traduction.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(InstructModel.allCases, id: \.self) { m in
                    HStack(spacing: 8) {
                        Text(m.displayName).font(.callout)
                        Spacer()
                        ModelDownloadBadge(manager: store.modelDownloads, model: m.downloadable)
                    }
                }
                .onAppear {
                    store.modelDownloads.refresh(InstructModel.allCases.map(\.downloadable))
                }
            } header: {
                Text("Le moteur").font(.headline)
            }

            Section {
                Picker("Traduire à tout moment avec", selection: $store.translateHotKey) {
                    ForEach(TranslateHotKeyOption.allCases, id: \.self) { key in
                        Text(key.label).tag(key)
                    }
                }
                Text("Raccourci global : traduit le champ en cours d'écriture, même sans souffle affiché. Une frappe, d'une main.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Valider la traduction avec", selection: $store.commitKey) {
                    ForEach(CommitKey.allCases, id: \.self) { key in
                        Text(key.label).tag(key)
                    }
                }
                Text("La touche qui envoie la réplique dans la langue cible — active quand un souffle ou le panneau de traduction est affiché.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Changer la langue cible avec", selection: $store.targetCycleKey) {
                    ForEach(TargetCycleKey.allCases, id: \.self) { key in
                        Text(key.label).tag(key)
                    }
                }
                Text("Fait défiler la langue cible (EN → ES → DE → IT → Auto) pour la conversation en cours — mémorisée par conversation. Auto suit la langue de votre interlocuteur quand la capture d'écran est active.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("Raccourcis").font(.headline)
            } footer: {
                Text("La traduction est en cours de construction.")
                    .font(.callout).foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Section « Qui vous souffle » — la galerie des voix, rangée du plus léger au
/// plus lourd, chaque voix présentée en une carte simple : sa vitesse, ses
/// langues, sa mémoire, et surtout un verdict en clair pour CE Mac (« Conseillé »,
/// « À l'aise », « un peu juste », « trop lourd »). Le but : que l'utilisateur
/// sache tout de suite quoi choisir, sans connaître ni les tailles ni le jargon.
private struct GhostModelSection: View {
    @Bindable var store: PreferencesStore

    /// RAM du Mac, lue « en live » à l'ouverture (jamais < 8 Go sur Apple Silicon).
    @State private var ramGB: Int = GGUFModelOption.machineRAMGB()

    private var recommendedID: String {
        GGUFModelOption.recommendedID(machineRAMGB: ramGB, language: store.primaryLanguage)
    }

    var body: some View {
        Section {
            // La langue d'écriture : pilote la voix conseillée (la petite Gemma en
            // français, une voix multilingue sinon). Demandée aussi à l'onboarding.
            Picker("J'écris…", selection: $store.primaryLanguage) {
                ForEach(PrimaryLanguage.allCases, id: \.self) { lang in
                    Text(lang.label).tag(lang)
                }
            }
            .pickerStyle(.segmented)

            // Repère machine : ce que le Mac peut tenir, en une ligne.
            HStack(spacing: 6) {
                Image(systemName: "memorychip")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Ton Mac : \(ramGB) Go de mémoire")
                    .font(.callout).foregroundStyle(.secondary)
            }

            ForEach(GGUFModelOption.catalogue, id: \.id) { (m: GGUFModelOption) in
                GhostModelCard(
                    model: m,
                    isActive: store.ggufModelID == m.id,
                    fit: m.fit(machineRAMGB: ramGB, recommendedID: recommendedID),
                    downloads: store.modelDownloads,
                    onSelect: { if m.isResolvable { store.ggufModelID = m.id } }
                )
            }
            .onAppear {
                ramGB = GGUFModelOption.machineRAMGB()
                store.modelDownloads.refresh(GGUFModelOption.catalogue.compactMap(\.downloadable))
            }
        } header: {
            Text("Qui vous souffle").font(.headline)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Une seule voix souffle à la fois. Choisis « Conseillé » si tu hésites.")
                Text("Les voix « beaucoup de langues » sont meilleures hors français (allemand, italien, espagnol, chinois, japonais…).")
                    .foregroundStyle(.secondary)
                Text("Une voix absente se télécharge d'un clic ; tout reste sur ton Mac.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }
}

/// Une carte de voix : radio de sélection à gauche, identité + étiquettes au
/// centre (vitesse · langues · mémoire · verdict pour ce Mac), action à droite
/// (télécharger / progression / « voix active »).
private struct GhostModelCard: View {
    let model: GGUFModelOption
    let isActive: Bool
    let fit: GGUFModelOption.Fit
    let downloads: ModelDownloadManager
    let onSelect: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Radio : sélectionne la voix (seulement si le fichier est là).
            Button(action: onSelect) {
                Image(systemName: isActive ? "largecircle.fill.circle" : (model.isResolvable ? "circle" : "circle.dotted"))
                    .font(.title3)
                    .foregroundStyle(isActive ? Color.sangDeBoeuf : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!model.isResolvable)
            .accessibilityLabel("Choisir \(model.displayName)")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.displayName).font(.body.weight(.semibold))
                    Text(model.quant).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if fit == .recommended {
                        recommendedChip
                    }
                }
                Text(model.hint)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Étiquettes : vitesse · langues.
                HStack(spacing: 6) {
                    chip(model.speedLabel, systemImage: "speedometer", tint: speedTint)
                    chip(model.languagesLabel, systemImage: "globe", tint: .secondary)
                }
                // Mémoire + verdict pour ce Mac.
                HStack(spacing: 4) {
                    Image(systemName: "memorychip").font(.caption2).foregroundStyle(.secondary)
                    Text("~\(formatGo(model.approxRAMMB)) en mémoire")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("·").font(.caption).foregroundStyle(.secondary)
                    Text(fitMessage).font(.caption.weight(.medium)).foregroundStyle(fitTint)
                }
            }

            Spacer(minLength: 8)

            trailing
        }
        .padding(.vertical, 4)
        .opacity(fit == .tooHeavy ? 0.6 : 1)
    }

    // MARK: - Action à droite

    @ViewBuilder
    private var trailing: some View {
        if let d = model.downloadable, !model.isResolvable {
            // Absente : on propose le téléchargement.
            ModelDownloadBadge(manager: downloads, model: d)
        } else if model.isResolvable {
            if isActive {
                Label("Voix active", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption).foregroundStyle(Color.sangDeBoeuf)
            } else {
                Button("Choisir", action: onSelect).controlSize(.small)
            }
        }
    }

    // MARK: - Étiquettes

    private var recommendedChip: some View {
        Text("Conseillé pour ton Mac")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.green.opacity(0.18), in: Capsule())
            .foregroundStyle(.green)
    }

    private func chip(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.caption2)
            Text(text).font(.caption)
        }
        .foregroundStyle(tint)
        .lineLimit(1)
    }

    private var speedTint: Color {
        switch model.speedLabel {
        case "Rapide": return .green
        case "Lent": return .orange
        default: return .secondary
        }
    }

    private var fitMessage: String {
        switch fit {
        case .recommended: return "le meilleur choix ici"
        case .comfortable: return "à l'aise sur ton Mac"
        case .tight: return "ton Mac est un peu juste"
        case .tooHeavy: return "trop lourd pour ton Mac"
        }
    }

    private var fitTint: Color {
        switch fit {
        case .recommended: return .green
        case .comfortable: return .secondary
        case .tight: return .orange
        case .tooHeavy: return Color.sangDeBoeuf
        }
    }

    /// Mo → « X,X Go », virgule décimale française.
    private func formatGo(_ mb: Int) -> String {
        let go = Double(mb) / 1024.0
        return String(format: "%.1f", go).replacingOccurrences(of: ".", with: ",") + " Go"
    }
}

/// Badge d'état de téléchargement d'un GGUF (traduction ou voix du souffle),
/// réutilisé dans les deux onglets : coche si installé, progression pendant le
/// téléchargement, bouton « Télécharger (N Mo) » / « Réessayer » sinon.
private struct ModelDownloadBadge: View {
    let manager: ModelDownloadManager
    let model: DownloadableModel

    var body: some View {
        switch manager.status(for: model) {
        case .ready:
            Label("Installé", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
        case .downloading(let p):
            HStack(spacing: 6) {
                ProgressView(value: p).frame(width: 90)
                Text("\(Int(p * 100)) %").font(.caption).monospacedDigit()
            }
        case .absent:
            Button("Télécharger (\(formatSize(model.approxSizeMB)))") { manager.download(model) }
                .controlSize(.small)
        case .failed:
            HStack(spacing: 6) {
                Text("échec").foregroundStyle(Color.sangDeBoeuf).font(.caption)
                Button("Réessayer") { manager.download(model) }
                    .controlSize(.small)
            }
        }
    }

    /// Mo → libellé compact : « 811 Mo » sous 1 Go, « 2,4 Go » au-delà.
    private func formatSize(_ mb: Int) -> String {
        if mb < 1024 { return "\(mb) Mo" }
        let go = Double(mb) / 1024.0
        return String(format: "%.1f", go).replacingOccurrences(of: ".", with: ",") + " Go"
    }
}

/// Onglet RÉGLAGES — l'app elle-même : la mettre en scène, lui donner l'accès
/// dont elle a besoin, la lancer au démarrage. Centralise les autorisations qui
/// étaient éparpillées (l'accès écran reste près de sa fonction, dans Contexte).
private struct ReglagesTab: View {
    @Bindable var store: PreferencesStore
    let onOpenOnboarding: () -> Void
    /// Mirrors AXIsProcessTrusted(). Refreshed on appear and by the
    /// "Vérifier" button — TCC doesn't notify on grant, so we poll on demand.
    @State private var hasAccessibility: Bool = AXClient.isTrusted
    /// L'état de l'item de login EST sa source de vérité (pas de pref stockée) :
    /// on lit `SMAppService.mainApp.status` et on resynchronise après chaque bascule.
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("Souffleuse à l'écoute", isOn: $store.enabled)
                Text("Entrer / sortir de scène : ⌃⌥⌘S")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Couper le contexte d'un coup : ⌃⌥⌘E")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Activation").font(.headline)
            }

            Section {
                accessibilityBadge
            } header: {
                Text("Autorisations").font(.headline)
            } footer: {
                Text("Sans cet accès, Souffleuse ne peut ni lire le champ où vous écrivez ni y poser le mot juste. Après une mise à jour, si Souffleuse apparaît cochée dans les Réglages mais se dit « absente », retirez l'entrée puis re-glissez l'app. L'accès à l'écran se règle dans l'onglet Contexte.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Lancer au démarrage du Mac", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            // Échec d'enregistrement (app pas encore dans /Applications,
                            // build dev non installé) → on resynchronise l'état réel
                            // sans bruit, fidèle au house-style « fallback silencieux ».
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Text("Souffleuse démarre en sourdine dans la barre des menus à l'ouverture de session.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("Au démarrage").font(.headline)
            }

            Section {
                HStack {
                    Button("Revoir les autorisations…", action: onOpenOnboarding)
                    Button("Ouvrir les Réglages système") {
                        openAccessibilitySettings()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            hasAccessibility = AXClient.isTrusted
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    @ViewBuilder
    private var accessibilityBadge: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: hasAccessibility ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(hasAccessibility ? .green : .orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(hasAccessibility
                     ? "Accès accordé — Souffleuse peut lire le champ et y souffler."
                     : "Accès manquant. Souffleuse ne peut ni lire ni souffler tant que vous ne l'avez pas accordé.")
                    .font(.callout)
                    .foregroundStyle(hasAccessibility ? .secondary : .primary)
                if !hasAccessibility {
                    HStack(spacing: 8) {
                        Button("Donner l'accès") {
                            // Prompt=true shows the system alert AND opens
                            // Settings to the right pane if not yet trusted.
                            _ = AXClient.ensureTrusted(prompt: true)
                            hasAccessibility = AXClient.isTrusted
                        }
                        Button("Ouvrir les Réglages") {
                            openAccessibilitySettings()
                        }
                        Button("Vérifier") {
                            hasAccessibility = AXClient.isTrusted
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct EnrichmentTab: View {
    @Bindable var store: PreferencesStore
    let onCaptureToggle: (Bool) -> Void
    /// Mirrors ScreenCapturer.hasPermission(). Refreshed on appear and when
    /// the user clicks "Vérifier" — the TCC API doesn't expose a change
    /// notification, so we manually re-query on demand.
    @State private var hasScreenRecordingPermission: Bool = ScreenCapturer.hasPermission()

    var body: some View {
        Form {
            Section {
                Toggle("Tenir compte du contexte", isOn: $store.enrichmentEnabled)
                Toggle("Lire ce qui est à l'écran", isOn: Binding(
                    get: { store.captureEnabled },
                    set: { onCaptureToggle($0) }
                ))
                .disabled(!store.enrichmentEnabled)
                if store.captureEnabled, store.enrichmentEnabled {
                    permissionBadge
                }
            } header: {
                Text("Autour de votre texte").font(.headline)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Le presse-papiers et l'écran ne sont jamais conservés. Souffleuse ne se lit pas elle-même.")
                    Text("Lire l'écran aide dans les emails (sujet, destinataire) mais peut troubler les chats — Souffleuse mêle parfois ce qu'elle lit à votre réponse. Désactivez-la pour les conversations légères.")
                        .foregroundStyle(.orange)
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Français", isOn: $store.ocrLangFR)
                Toggle("Anglais", isOn: $store.ocrLangEN)
                Toggle("Espagnol", isOn: $store.ocrLangES)
            } header: {
                Text("Langues à l'écran").font(.headline)
            } footer: {
                Text("Au moins une langue. Si aucune n'est cochée, le français est utilisé par défaut.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { hasScreenRecordingPermission = ScreenCapturer.hasPermission() }
    }

    /// Renders the macOS Screen Recording permission state directly under
    /// the capture toggle. Without this, the toggle could be ON while the
    /// pipeline silently fails — leaving the user wondering why the LLM
    /// never sees on-screen context. Two buttons: re-trigger the system
    /// prompt (only works the first time per app version, hence the
    /// fallback) and open the relevant pane in System Settings.
    @ViewBuilder
    private var permissionBadge: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: hasScreenRecordingPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(hasScreenRecordingPermission ? .green : .orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(hasScreenRecordingPermission
                     ? "Lecture d'écran autorisée."
                     : "Lecture d'écran non autorisée. Souffleuse ne voit pas l'écran tant que vous ne l'avez pas accordé dans Réglages › Confidentialité.")
                    .font(.callout)
                    .foregroundStyle(hasScreenRecordingPermission ? .secondary : .primary)
                if !hasScreenRecordingPermission {
                    HStack(spacing: 8) {
                        Button("Autoriser") {
                            // forcePermissionPrompt hits ScreenCaptureKit
                            // directly — that's the only reliable way to
                            // make macOS register the app in TCC when
                            // CGRequestScreenCaptureAccess goes silent.
                            Task {
                                await ScreenCapturer.forcePermissionPrompt()
                                await MainActor.run {
                                    hasScreenRecordingPermission = ScreenCapturer.hasPermission()
                                }
                            }
                        }
                        Button("Ouvrir les Réglages") {
                            openScreenRecordingSettings()
                        }
                        Button("Vérifier") {
                            hasScreenRecordingPermission = ScreenCapturer.hasPermission()
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func openScreenRecordingSettings() {
        // System Settings (Ventura+) URL scheme. Lands directly on the
        // Screen Recording privacy pane so the user doesn't have to hunt
        // through nested menus.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Gouttière d'édition partagée par les onglets à règles (Par application · Ton) :
/// le tableau, puis une barre +/−/Modifier au même style et au même rythme dans
/// les deux. Avant, chaque onglet réinventait sa barre avec des boutons-image
/// flottants taille par défaut, au rendu incohérent avec le reste de la fenêtre.
/// Ce composant impose une seule grammaire d'édition — l'intro et les contrôles
/// propres à chaque onglet (ex. le ton par défaut) restent au-dessus, chez l'appelant.
private struct RuleListEditor<TableContent: View>: View {
    let hasSelection: Bool
    let onAdd: () -> Void
    let onRemove: () -> Void
    let onEdit: () -> Void
    @ViewBuilder var table: () -> TableContent

    var body: some View {
        VStack(spacing: 6) {
            table()
            HStack(spacing: 6) {
                Button(action: onAdd) { Image(systemName: "plus").frame(width: 24) }
                    .accessibilityLabel("Ajouter une règle")
                Button(action: onRemove) { Image(systemName: "minus").frame(width: 24) }
                    .disabled(!hasSelection)
                    .accessibilityLabel("Supprimer la règle sélectionnée")
                Button("Modifier…", action: onEdit)
                    .disabled(!hasSelection)
                Spacer()
            }
            .controlSize(.small)
        }
    }
}

private struct AllowlistTab: View {
    @Bindable var store: PreferencesStore
    @State private var selection: UUID?
    @State private var draft: AllowlistRule?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Des règles, dans l'ordre : la première qui correspond (application + titre de fenêtre) l'emporte. Partout ailleurs, Souffleuse est active par défaut.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            RuleListEditor(
                hasSelection: selection != nil,
                onAdd: { draft = AllowlistRule(bundleID: "") },
                onRemove: { if let id = selection { store.allowlist.delete(id); selection = nil } },
                onEdit: {
                    if let id = selection, let r = store.allowlist.rules.first(where: { $0.id == id }) {
                        draft = r
                    }
                }
            ) {
                Table(store.allowlist.rules, selection: $selection) {
                    TableColumn("Application") { rule in
                        // Nom + icône résolus depuis le bundle ID (AppCatalog,
                        // même pattern que l'onglet Ton) ; app introuvable →
                        // ID brut en fallback.
                        if let app = AppCatalog.entry(forBundleID: rule.bundleID) {
                            HStack(spacing: 6) {
                                Image(nsImage: app.icon)
                                    .resizable()
                                    .frame(width: 16, height: 16)
                                Text(app.name)
                            }
                            .help(rule.bundleID)
                        } else {
                            Text(rule.bundleID).font(.system(.callout, design: .monospaced))
                        }
                    }
                    TableColumn("Titre (regex)") { rule in
                        Text(rule.titleRegex.isEmpty ? "—" : rule.titleRegex)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(rule.titleRegex.isEmpty ? .secondary : .primary)
                    }
                    TableColumn("Mode") { rule in
                        Text(rule.mode.label)
                    }
                }
                .frame(minHeight: 240)
            }
        }
        .sheet(item: $draft) { rule in
            RuleEditor(rule: rule) { saved in
                store.allowlist.upsert(saved)
                draft = nil
            } onCancel: {
                draft = nil
            }
        }
    }
}

/// Éditeur de règle d'allowlist. L'app se choisit par NOM + icône (même
/// sélecteur que l'onglet Ton, `AppCatalog`) ; le bundle ID brut survit replié
/// en « Avancé ». Le filtre de titre (regex) reste tel quel — outil
/// volontairement avancé.
private struct RuleEditor: View {
    @State var rule: AllowlistRule
    let onSave: (AllowlistRule) -> Void
    let onCancel: () -> Void

    @State private var apps: [AppEntry] = []
    @State private var filter = ""
    @State private var showAdvanced = false

    var regexValid: Bool {
        let pattern = rule.titleRegex.trimmingCharacters(in: .whitespaces)
        if pattern.isEmpty { return true }
        return (try? NSRegularExpression(pattern: pattern)) != nil
    }

    private var filteredApps: [AppEntry] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Rechercher une application…", text: $filter)
                .textFieldStyle(.roundedBorder)

            List(filteredApps, selection: Binding(
                get: { rule.bundleID.isEmpty ? nil : rule.bundleID },
                set: { rule.bundleID = $0 ?? "" }
            )) { app in
                HStack(spacing: 8) {
                    Image(nsImage: app.icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                    Text(app.name)
                    Spacer()
                    if app.bundleID == rule.bundleID {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
                .tag(app.bundleID)
            }
            .frame(height: 200)
            .overlay {
                if apps.isEmpty {
                    ProgressView()
                } else if filteredApps.isEmpty {
                    Text("Aucune application ne correspond — voir « Avancé ».")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            DisclosureGroup("Avancé — identifiant d'application", isExpanded: $showAdvanced) {
                TextField("Bundle ID", text: $rule.bundleID, prompt: Text("com.apple.mail"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            .font(.callout)

            TextField("Titre (regex, optionnel)", text: $rule.titleRegex, prompt: Text("^Re: .*"))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(regexValid ? .primary : .red)
            Picker("Mode", selection: $rule.mode) {
                ForEach(AllowlistMode.allCases, id: \.self) { m in
                    Text(m.label).tag(m)
                }
            }
            HStack {
                Spacer()
                Button("Annuler", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Enregistrer") { onSave(rule) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.bundleID.trimmingCharacters(in: .whitespaces).isEmpty || !regexValid)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            apps = AppCatalog.entries()
            // Règle hors catalogue (app désinstallée, ID manuel) : ouvre
            // l'avancé pour que l'ID reste visible et modifiable.
            if !rule.bundleID.isEmpty, !apps.contains(where: { $0.bundleID == rule.bundleID }) {
                showAdvanced = true
            }
        }
    }
}

private struct ToneTab: View {
    @Bindable var store: PreferencesStore
    @State private var selection: UUID?
    @State private var draft: ToneRule?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Quand le correspondant écrit en français, ⌘↩ ne traduit pas : la souffleuse relit ton message. Choisis le registre — un défaut, et des exceptions par application.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Ton par défaut", selection: Binding(
                get: { store.tones.defaultTone },
                set: { store.tones.setDefaultTone($0) }
            )) {
                ForEach(Tone.allCases, id: \.self) { t in
                    Text(t.displayName).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            RuleListEditor(
                hasSelection: selection != nil,
                onAdd: { draft = ToneRule(bundleID: "") },
                onRemove: { if let id = selection { store.tones.delete(id); selection = nil } },
                onEdit: {
                    if let id = selection, let r = store.tones.rules.first(where: { $0.id == id }) {
                        draft = r
                    }
                }
            ) {
                Table(store.tones.rules, selection: $selection) {
                    TableColumn("Application") { rule in
                        // Nom + icône résolus depuis le bundle ID ; une app
                        // introuvable (désinstallée) retombe sur l'ID brut.
                        if let app = AppCatalog.entry(forBundleID: rule.bundleID) {
                            HStack(spacing: 6) {
                                Image(nsImage: app.icon)
                                    .resizable()
                                    .frame(width: 16, height: 16)
                                Text(app.name)
                            }
                            .help(rule.bundleID)
                        } else {
                            Text(rule.bundleID).font(.system(.callout, design: .monospaced))
                        }
                    }
                    TableColumn("Ton") { rule in
                        Text(rule.tone.displayName)
                    }
                }
                .frame(minHeight: 240)
            }
        }
        .sheet(item: $draft) { rule in
            ToneRuleEditor(rule: rule) { saved in
                store.tones.upsert(saved)
                draft = nil
            } onCancel: {
                draft = nil
            }
        }
    }
}

/// Éditeur d'exception de ton. L'app se choisit par son NOM et son icône dans
/// la liste des apps installées/ouvertes (recherche au clavier) — plus de
/// champ « Bundle ID » en premier plan, que personne ne connaît. Le champ brut
/// survit replié en « Avancé » pour les cas hors catalogue.
private struct ToneRuleEditor: View {
    @State var rule: ToneRule
    let onSave: (ToneRule) -> Void
    let onCancel: () -> Void

    @State private var apps: [AppEntry] = []
    @State private var filter = ""
    @State private var showAdvanced = false

    private var filteredApps: [AppEntry] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Rechercher une application…", text: $filter)
                .textFieldStyle(.roundedBorder)

            List(filteredApps, selection: Binding(
                get: { rule.bundleID.isEmpty ? nil : rule.bundleID },
                set: { rule.bundleID = $0 ?? "" }
            )) { app in
                HStack(spacing: 8) {
                    Image(nsImage: app.icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                    Text(app.name)
                    Spacer()
                    if app.bundleID == rule.bundleID {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
                .tag(app.bundleID)
            }
            .frame(height: 220)
            .overlay {
                if apps.isEmpty {
                    ProgressView()
                } else if filteredApps.isEmpty {
                    Text("Aucune application ne correspond — voir « Avancé ».")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            DisclosureGroup("Avancé — identifiant d'application", isExpanded: $showAdvanced) {
                TextField("Bundle ID", text: $rule.bundleID, prompt: Text("com.tinyspeck.slackmacgap"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            .font(.callout)

            Picker("Ton", selection: $rule.tone) {
                ForEach(Tone.allCases, id: \.self) { t in
                    Text(t.displayName).tag(t)
                }
            }
            HStack {
                Spacer()
                Button("Annuler", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Enregistrer") { onSave(rule) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.bundleID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            apps = AppCatalog.entries()
            // Édition d'une règle hors catalogue (app désinstallée, ID manuel) :
            // ouvre l'avancé pour que l'ID reste visible et modifiable.
            if !rule.bundleID.isEmpty, !apps.contains(where: { $0.bundleID == rule.bundleID }) {
                showAdvanced = true
            }
        }
    }
}

/// Onglet À PROPOS — l'identité de l'app et les rares dépannages qui lui sont
/// propres. Dégraissé : les boutons d'autorisation qui doublaient l'onglet
/// Réglages ont été retirés (une seule source de vérité pour les accès).
private struct AboutTab: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Souffleuse")
                    .font(.system(size: 32, weight: .semibold, design: .serif))
                Text("Le mot juste, soufflé à voix basse.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Tout reste sur votre Mac — rien ne passe en coulisses.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Text("version \(version)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Le souffle apparaît en double ?")
                    .font(.headline)
                Text("macOS glisse parfois ses propres suggestions par-dessus celles de Souffleuse. Désactivez-les pour n'en garder qu'une voix.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Ouvrir les réglages Clavier") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
                    NSWorkspace.shared.open(url)
                }
                .padding(.top, 2)
            }
            Divider()
            Button("Ouvrir le journal") {
                let url = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Logs/Souffleuse.log")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Spacer()
            Text("Aucune connexion, hormis le premier téléchargement de la voix. Aucun de vos mots n'est écrit dans les journaux.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
