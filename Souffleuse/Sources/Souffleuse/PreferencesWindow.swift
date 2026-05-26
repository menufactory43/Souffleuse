import AppKit
import SouffleuseAX
import SouffleuseContext
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
            ModelTab(store: store, onModelChange: onModelChange)
                .tabItem { Label("Modèle", systemImage: "cpu") }
            EnrichmentTab(store: store, onCaptureToggle: onCaptureToggle)
                .tabItem { Label("Enrichissement", systemImage: "doc.text.magnifyingglass") }
            PersonalizationTab(
                store: store,
                onOpenViewer: onOpenHistoryViewer,
                onClearAll: onClearPersonalization
            )
            .tabItem { Label("Personnalisation", systemImage: "person.crop.circle.badge.checkmark") }
            AllowlistTab(store: store)
                .tabItem { Label("Allowlist", systemImage: "list.bullet.rectangle") }
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
                Toggle("Apprendre de mes frappes", isOn: $store.personalizationEnabled)
                    .onChange(of: store.personalizationEnabled) { _, on in
                        if on && !store.personalizationOnboardingShown {
                            showingOnboarding = true
                        }
                    }
                Text("Stocké chiffré localement (AES-GCM, clé Keychain). Jamais envoyé sur internet.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("Collecte").font(.headline)
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
                Text("Influence sur les suggestions").font(.headline)
            } footer: {
                Text("À zéro, la perso ne touche pas le modèle (collecte seule). Au max, les n-grammes habituels sont fortement boostés.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("Entrées collectées")
                    Spacer()
                    Text("\(entryCount)").font(.system(.body, design: .monospaced))
                }
                HStack {
                    Text("Taille du fichier")
                    Spacer()
                    Text(formatBytes(sizeBytes)).font(.system(.body, design: .monospaced))
                }
                HStack {
                    Button("Voir mes données…", action: onOpenViewer)
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
        .alert("Activer la personnalisation ?", isPresented: $showingOnboarding) {
            Button("Annuler", role: .cancel) {
                store.personalizationEnabled = false
            }
            Button("Activer") {
                store.personalizationOnboardingShown = true
            }
        } message: {
            Text("Souffleuse va enregistrer les phrases que tu acceptes (Tab) pour personnaliser tes futures suggestions. Les données sont chiffrées sur ton Mac et jamais envoyées sur internet. Tu peux les consulter ou les supprimer à tout moment depuis cet onglet.")
        }
        .confirmationDialog(
            "Supprimer toutes les données collectées ?",
            isPresented: $showingClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Tout supprimer", role: .destructive) {
                onClearAll()
                Task { await refresh() }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Le fichier chiffré et la clé Keychain seront détruits. Cette action est irréversible.")
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
                Text("Permissions système").font(.headline)
            } footer: {
                Text("Sans Accessibility, Souffleuse ne peut ni lire le champ texte focalisé ni y écrire la suggestion acceptée. À chaque rebuild de l'app le cdhash change : si Souffleuse apparaît cochée dans Réglages mais l'app dit « manquante », retire l'entrée puis re-glisse le bundle.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Activée", isOn: $store.enabled)
                Text("Raccourci d'activation : ⌃⌥⌘S")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Raccourci kill-switch enrichissement : ⌃⌥⌘E")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Comportement").font(.headline)
            }
            Section {
                Picker("Longueur des suggestions", selection: $store.completionLength) {
                    ForEach(CompletionLength.allCases, id: \.self) { l in
                        Text(l.label).tag(l)
                    }
                }
            } header: {
                Text("Suggestions").font(.headline)
            } footer: {
                Text("Les suggestions plus longues peuvent dévier de l'intention. Tab accepte ; Esc rejette pour ce texte.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Accepter mot par mot", isOn: $store.partialAcceptEnabled)
                Text("Tab insère un seul mot à la fois ; le reste de la suggestion reste en gris. Tab à nouveau pour le mot suivant, Esc pour effacer.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Ajouter un espace après le mot accepté", isOn: $store.trailingSpaceOnPartial)
                    .disabled(!store.partialAcceptEnabled)
                Text("Place le curseur prêt à enchaîner. Désactive si tu préfères contrôler l'espace toi-même.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("Acceptation").font(.headline)
            }
            Section {
                Toggle("Correction typos", isOn: $store.typoEnabled)
                Toggle("Masquer les suggestions quand un typo est suspecté", isOn: $store.hideOnTypo)
                    .disabled(!store.typoEnabled)
                Toggle("Expansion emoji (\u{003A}smile\u{003A} → 😄)", isOn: $store.emojiEnabled)
                Toggle("Corriger les fautes avant de compléter", isOn: $store.prefixCorrectionEnabled)
            } header: {
                Text("Aide à la frappe").font(.headline)
            } footer: {
                Text("Désactivés automatiquement dans Xcode, VS Code, JetBrains, terminaux. La correction avant complétion ne change que ce que voit le modèle — votre texte reste tel que tapé.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Text("Lancement au démarrage : à venir.")
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
                     ? "Accessibility : accordée."
                     : "Accessibility manquante. Souffleuse ne peut pas lire/écrire le champ texte tant que tu ne l'as pas accordée.")
                    .font(.callout)
                    .foregroundStyle(hasAccessibility ? .secondary : .primary)
                if !hasAccessibility {
                    HStack(spacing: 8) {
                        Button("Demander la permission") {
                            // Prompt=true shows the system alert AND opens
                            // Settings to the right pane if not yet trusted.
                            _ = AXClient.ensureTrusted(prompt: true)
                            hasAccessibility = AXClient.isTrusted
                        }
                        Button("Ouvrir Réglages système") {
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

private struct ModelTab: View {
    @Bindable var store: PreferencesStore
    let onModelChange: (String) -> Void

    var body: some View {
        Form {
            Section {
                Picker("Modèle actif", selection: $store.modelID) {
                    ForEach(ModelOption.catalogue) { m in
                        Text(m.displayName).tag(m.id)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: store.modelID) { _, new in onModelChange(new) }
            } header: {
                Text("Modèle").font(.headline)
            } footer: {
                let m = store.currentModel
                VStack(alignment: .leading, spacing: 4) {
                    Text("Disque : \(format(m.approxDiskGB)) GB · RAM : ~\(format(m.approxRamGB)) GB")
                    Text("Langues : \(m.languages)")
                    Text("Téléchargé via Hugging Face au premier usage. La vérification d'intégrité signée Ed25519 arrive avec la phase de distribution.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
    }

    private func format(_ v: Double) -> String {
        String(format: "%.1f", v)
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
                Toggle("Enrichissement contextuel", isOn: $store.enrichmentEnabled)
                Toggle("Inclure capture d'écran (OCR)", isOn: Binding(
                    get: { store.captureEnabled },
                    set: { onCaptureToggle($0) }
                ))
                .disabled(!store.enrichmentEnabled)
                if store.captureEnabled, store.enrichmentEnabled {
                    permissionBadge
                }
            } header: {
                Text("Sources").font(.headline)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Le clipboard et l'OCR ne sont jamais persistés. La capture exclut Souffleuse elle-même.")
                    Text("Note : la capture OCR aide dans les emails (récupère sujet/destinataire) mais peut nuire dans les chats — le modèle base 1B mélange parfois le vocabulaire du message lu avec ta réponse. Désactive-la pour les conversations casual.")
                        .foregroundStyle(.orange)
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Français", isOn: $store.ocrLangFR)
                Toggle("Anglais", isOn: $store.ocrLangEN)
                Toggle("Espagnol", isOn: $store.ocrLangES)
            } header: {
                Text("Langues OCR").font(.headline)
            } footer: {
                Text("Au moins une langue requise. Si aucune n'est cochée, le français est utilisé par défaut.")
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
                     ? "Permission Enregistrement de l'écran : accordée."
                     : "Permission Enregistrement de l'écran manquante. La capture OCR est inactive tant que tu n'as pas accordé Souffleuse dans Réglages > Confidentialité.")
                    .font(.callout)
                    .foregroundStyle(hasScreenRecordingPermission ? .secondary : .primary)
                if !hasScreenRecordingPermission {
                    HStack(spacing: 8) {
                        Button("Demander la permission") {
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
                        Button("Ouvrir Réglages système") {
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
            Text("Règles évaluées dans l'ordre. La première qui matche bundle + titre l'emporte. Apps non listées : mode actif par défaut.")
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
        VStack(alignment: .leading, spacing: 14) {
            Text("Souffleuse \(version)").font(.title2).bold()
            Text("Autocomplete macOS local. Vos mots restent chez vous.")
                .foregroundStyle(.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Conflit avec les prédictions Apple")
                    .font(.headline)
                Text("macOS Sequoia affiche ses propres suggestions inline qui se superposent à celles de Souffleuse. Désactive-les pour éviter le double ghost.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Ouvrir Réglages Clavier") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
                    NSWorkspace.shared.open(url)
                }
            }
            Divider()
            HStack {
                Button("Permissions…", action: onOpenOnboarding)
                Button("Ouvrir le log") {
                    let url = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/Logs/Souffleuse.log")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Button("Révoquer les permissions") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                    NSWorkspace.shared.open(url)
                }
            }
            Spacer()
            Text("Aucune connexion réseau hors téléchargement de modèle. Aucun texte utilisateur n'est écrit dans les logs.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
