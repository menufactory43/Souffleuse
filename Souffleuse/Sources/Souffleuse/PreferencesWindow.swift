import AppKit
import SouffleuseAX
import SouffleuseContext
import SouffleuseCore
import SouffleuseInput
import SouffleusePersonalization
import SwiftUI

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
        host.view.frame = NSRect(x: 0, y: 0, width: 620, height: 460)

        let w = NSWindow(contentViewController: host)
        w.title = "Préférences"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.setContentSize(NSSize(width: 620, height: 460))
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

    var body: some View {
        TabView {
            GeneralTab(store: store)
                .tabItem { Label("Général", systemImage: "gearshape") }
            ModelTab(store: store)
                .tabItem { Label("Modèle", systemImage: "cpu") }
            EnrichmentTab(store: store, onCaptureToggle: onCaptureToggle)
                .tabItem { Label("Contexte", systemImage: "doc.text.magnifyingglass") }
            PersonalizationTab(
                store: store,
                onOpenViewer: onOpenHistoryViewer,
                onClearAll: onClearPersonalization
            )
            .tabItem { Label("Personnalisation", systemImage: "person.crop.circle.badge.checkmark") }
            AllowlistTab(store: store)
                .tabItem { Label("Par application", systemImage: "list.bullet.rectangle") }
            AboutTab(onOpenOnboarding: onOpenOnboarding)
                .tabItem { Label("À propos", systemImage: "info.circle") }
        }
        .padding(20)
        .frame(width: 620, height: 460)
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
                Text("Sa part dans le souffle").font(.headline)
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

private struct GeneralTab: View {
    @Bindable var store: PreferencesStore
    /// Mirrors AXIsProcessTrusted(). Refreshed on appear and by the
    /// "Vérifier" button — TCC doesn't notify on grant, so we poll on demand.
    @State private var hasAccessibility: Bool = AXClient.isTrusted

    var body: some View {
        Form {
            Section {
                accessibilityBadge
            } header: {
                Text("Autorisations").font(.headline)
            } footer: {
                Text("Sans cet accès, Souffleuse ne peut ni lire le champ où vous écrivez ni y poser le mot juste. Après une mise à jour, si Souffleuse apparaît cochée dans les Réglages mais se dit « absente », retirez l'entrée puis re-glissez l'app.")
                    .font(.callout).foregroundStyle(.secondary)
            }
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
                Picker("Longueur du souffle", selection: $store.completionLength) {
                    ForEach(CompletionLength.allCases, id: \.self) { l in
                        Text(l.label).tag(l)
                    }
                }
            } header: {
                Text("Le souffle").font(.headline)
            } footer: {
                Text("Plus c'est long, plus ça peut s'éloigner de votre intention. Tab accepte ; Esc écarte.")
                    .font(.callout).foregroundStyle(.secondary)
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
                Picker("Valider la traduction avec", selection: $store.commitKey) {
                    ForEach(CommitKey.allCases, id: \.self) { key in
                        Text(key.label).tag(key)
                    }
                }
                Text("La touche qui envoie la réplique dans la langue cible (fonction de traduction, en cours de construction).")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Changer la langue cible avec", selection: $store.targetCycleKey) {
                    ForEach(TargetCycleKey.allCases, id: \.self) { key in
                        Text(key.label).tag(key)
                    }
                }
                Text("Fait défiler la langue cible (EN → ES → DE → IT → Auto) pour la conversation en cours — mémorisée par conversation. Auto suit la langue de votre interlocuteur quand la capture d'écran est active.")
                    .font(.callout).foregroundStyle(.secondary)
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
                Text("Accepter le souffle").font(.headline)
            }
            Section {
                Toggle("Corriger les coquilles", isOn: $store.typoEnabled)
                Toggle("Se taire quand une coquille est en cours", isOn: $store.hideOnTypo)
                    .disabled(!store.typoEnabled)
                Toggle("Expansion emoji (\u{003A}smile\u{003A} → 😄)", isOn: $store.emojiEnabled)
                Toggle("Corriger le texte avant de souffler", isOn: $store.prefixCorrectionEnabled)
            } header: {
                Text("Coups de pouce").font(.headline)
            } footer: {
                Text("Mis en sommeil dans Xcode, VS Code, JetBrains et les terminaux. La correction ne change que ce que voit Souffleuse — votre texte reste tel que tapé.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Text("Au démarrage du Mac : bientôt.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .onAppear { hasAccessibility = AXClient.isTrusted }
    }

    @ViewBuilder
    private var accessibilityBadge: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: hasAccessibility ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(hasAccessibility ? .green : .orange)
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
            Button("Télécharger (\(model.approxSizeMB) Mo)") { manager.download(model) }
                .controlSize(.small)
        case .failed:
            HStack(spacing: 6) {
                Text("échec").foregroundStyle(.red).font(.caption)
                Button("Réessayer") { manager.download(model) }
                    .controlSize(.small)
            }
        }
    }
}

private struct ModelTab: View {
    @Bindable var store: PreferencesStore

    var body: some View {
        Form {
            Section {
                Picker("Voix active", selection: $store.ggufModelID) {
                    ForEach(GGUFModelOption.catalogue, id: \.id) { (m: GGUFModelOption) in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(m.displayName)
                                Text(m.quant)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Text(m.isResolvable ? m.hint : "introuvable sur votre Mac")
                                .font(.caption)
                                .foregroundStyle(m.isResolvable ? Color.secondary : Color.red)
                        }
                        .tag(m.id)
                        .disabled(!m.isResolvable)
                    }
                }
                .pickerStyle(.radioGroup)
                ForEach(GGUFModelOption.catalogue, id: \.id) { (m: GGUFModelOption) in
                    if let d = m.downloadable {
                        HStack(spacing: 8) {
                            Text("\(m.displayName) · \(m.quant)").font(.callout)
                            Spacer()
                            ModelDownloadBadge(manager: store.modelDownloads, model: d)
                        }
                    }
                }
                .onAppear {
                    store.modelDownloads.refresh(GGUFModelOption.catalogue.compactMap(\.downloadable))
                }
            } header: {
                Text("Qui vous souffle").font(.headline)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Une seule voix souffle à la fois.")
                    Text("La grande est plus juste, mais plus lente et plus gourmande en mémoire ; la petite est rapide — c'est le choix par défaut.")
                        .foregroundStyle(.secondary)
                    Text("Une voix absente se télécharge d'un clic ci-dessus.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
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

private struct AllowlistTab: View {
    @Bindable var store: PreferencesStore
    @State private var selection: UUID?
    @State private var draft: AllowlistRule?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Des règles, dans l'ordre : la première qui correspond (application + titre de fenêtre) l'emporte. Partout ailleurs, Souffleuse est active par défaut.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Table(store.allowlist.rules, selection: $selection) {
                TableColumn("Bundle ID") { rule in
                    Text(rule.bundleID).font(.system(.body, design: .monospaced))
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
            .frame(minHeight: 220)

            HStack {
                Button(action: { draft = AllowlistRule(bundleID: "") }) {
                    Image(systemName: "plus")
                }
                Button(action: { if let id = selection { store.allowlist.delete(id); selection = nil } }) {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                Button("Modifier…") {
                    if let id = selection, let r = store.allowlist.rules.first(where: { $0.id == id }) {
                        draft = r
                    }
                }
                .disabled(selection == nil)
                Spacer()
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

private struct RuleEditor: View {
    @State var rule: AllowlistRule
    let onSave: (AllowlistRule) -> Void
    let onCancel: () -> Void

    var regexValid: Bool {
        let pattern = rule.titleRegex.trimmingCharacters(in: .whitespaces)
        if pattern.isEmpty { return true }
        return (try? NSRegularExpression(pattern: pattern)) != nil
    }

    var body: some View {
        Form {
            TextField("Bundle ID", text: $rule.bundleID, prompt: Text("com.apple.mail"))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
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
        .frame(width: 420)
    }
}

private struct AboutTab: View {
    let onOpenOnboarding: () -> Void

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
            HStack {
                Button("Autorisations…", action: onOpenOnboarding)
                Button("Ouvrir le journal") {
                    let url = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/Logs/Souffleuse.log")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Button("Revoir les accès") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                    NSWorkspace.shared.open(url)
                }
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
