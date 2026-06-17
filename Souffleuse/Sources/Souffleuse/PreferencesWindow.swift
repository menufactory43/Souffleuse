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
/// Navigation pilotable de la fenêtre Préférences — partagée avec `PreferencesRoot`
/// pour qu'un deep-link externe (ex. « Débloquer Studio ») puisse poser la section
/// active. `@Observable` plutôt qu'un `@State` privé : la sélection est alors
/// contrôlable du dehors ET survit aux reconstructions (changement de langue).
@Observable fileprivate final class PreferencesNavigation {
    var selection: PrefSection? = .souffle
}

@MainActor
final class PreferencesWindow {
    private var window: NSWindow?
    private let nav = PreferencesNavigation()
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

    /// Ouvre (ou ramène au premier plan) en ciblant la section Studio — appelé par
    /// l'invite « Débloquer Studio ».
    func showStudio() {
        nav.selection = .studio
        show()
    }

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = PreferencesRoot(
            store: store,
            nav: nav,
            onModelChange: onModelChange,
            onCaptureToggle: onCaptureToggle,
            onOpenOnboarding: onOpenOnboarding,
            onOpenHistoryViewer: onOpenHistoryViewer,
            onClearPersonalization: onClearPersonalization
        )
        let host = NSHostingController(rootView: root)
        // Plus large que l'ancienne fenêtre à onglets : la sidebar prend ~200 pt,
        // il faut laisser au moins autant au panneau de détail qu'avant.
        host.view.frame = NSRect(x: 0, y: 0, width: 800, height: 560)

        let w = NSWindow(contentViewController: host)
        w.title = tr(fr: "Préférences", en: "Settings")
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 800, height: 560))
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}

/// Les sections des Préférences, rangées par FONCTION (les piliers de l'app),
/// pas par accumulation historique. L'ordre = l'ordre d'affichage dans la
/// sidebar : d'abord ce que l'app FAIT au texte (souffle · traduction · ton ·
/// aides), puis les données/comportement (personnalisation · contexte · par
/// app), enfin le cosmétique et la config (apparence · réglages) — Apparence
/// est volontairement en bas, c'est du réglage de FORME, pas un pilier.
private enum PrefSection: String, CaseIterable, Identifiable {
    // `aides` (coquilles · emoji · transformations « // ») extrait de Souffle :
    // ce sont des aides à la FRAPPE, indépendantes du souffle LLM — les noyer
    // dans Souffle allongeait la page et mélangeait deux fonctions. Posé dans le
    // cluster « actions sur le texte » (traduction · ton · aides).
    case souffle, traduction, ton, aides, personnalisation, contexte, parApp, apparence, reglages, studio, aPropos

    var id: String { rawValue }

    /// Sections affichées dans la sidebar : `studio` (licence) n'apparaît QUE quand
    /// le paywall est armé — kill switch off → invisible, l'app reste « tout inclus ».
    static var visible: [PrefSection] {
        allCases.filter { $0 != .studio || LicenseGate.paywallEnabled }
    }

    /// Sections ENTIÈREMENT payantes (Studio) — cadenas sidebar + bannière quand la
    /// licence n'est pas active. Les onglets MIXTES (Souffle, Aides) ont leurs aides
    /// gratuites ET un bloc Studio ; ils sont gérés au niveau de la section, pas ici.
    var isStudio: Bool {
        switch self {
        case .traduction, .ton, .personnalisation, .contexte: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .souffle: return tr(fr: "Souffle", en: "Whisper")
        case .apparence: return tr(fr: "Apparence", en: "Appearance")
        case .traduction: return tr(fr: "Traduction", en: "Translation")
        case .ton: return tr(fr: "Ton", en: "Tone")
        case .aides: return tr(fr: "Aides à la frappe", en: "Typing aids")
        case .personnalisation: return tr(fr: "Personnalisation", en: "Personalization")
        case .contexte: return tr(fr: "Contexte", en: "Context")
        case .parApp: return tr(fr: "Par application", en: "Per app")
        case .reglages: return tr(fr: "Réglages", en: "General")
        case .studio: return tr(fr: "Studio", en: "Studio")
        case .aPropos: return tr(fr: "À propos", en: "About")
        }
    }

    var systemImage: String {
        switch self {
        case .souffle: return "wind"
        case .apparence: return "paintpalette"
        case .traduction: return "globe"
        case .ton: return "textformat"
        case .aides: return "wand.and.stars"
        case .personnalisation: return "person.crop.circle.badge.checkmark"
        case .contexte: return "doc.text.magnifyingglass"
        case .parApp: return "list.bullet.rectangle"
        case .reglages: return "gearshape"
        case .studio: return "key.fill"
        case .aPropos: return "info.circle"
        }
    }

    /// Termes indexés pour la recherche (FR + EN) : les libellés des réglages de
    /// la section, pour qu'un mot comme « emoji » ou « opacité » trouve sa page.
    /// Pas besoin d'être exhaustif — les mots que l'utilisateur taperait.
    var searchTerms: String {
        switch self {
        case .souffle:
            return "souffle ghost whisper longueur length modèle model accepter accept mot word tab milieu ligne mid-line corriger préfixe"
        case .apparence:
            return "apparence appearance couleur color opacité opacity police font taille gris"
        case .traduction:
            return "traduction translation langue language cible target espagnol anglais allemand italien spanish english"
        case .ton:
            return "ton tone registre formel familier relecture reformuler"
        case .aides:
            return "aides frappe typing coquille typo faute emoji transformation slash // corriger raccourcir reformuler rédiger fix shorten rephrase compose"
        case .personnalisation:
            return "personnalisation personalization historique history apprendre learn style perso"
        case .contexte:
            return "contexte context capture écran screen ocr presse-papier clipboard enrichissement"
        case .parApp:
            return "par application per app allowlist autorisation bundle"
        case .reglages:
            return "réglages general général démarrage launch raccourci hotkey touche mise à jour update"
        case .studio:
            return "studio licence license clé key activer activation acheter buy débloquer unlock pro payant"
        case .aPropos:
            return "à propos about version crédits"
        }
    }

    /// Pliage accents/casse (fr) — « OPACITÉ » et « opacite » doivent matcher.
    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive],
                  locale: Locale(identifier: "fr_FR"))
    }

    /// La section matche-t-elle la requête ? Sous-chaîne sur le libellé OU les
    /// termes indexés, insensible casse/accents.
    func matches(_ query: String) -> Bool {
        let q = Self.fold(query)
        guard !q.isEmpty else { return true }
        return Self.fold(label).contains(q) || Self.fold(searchTerms).contains(q)
    }
}

/// Fenêtre Préférences en layout sidebar (idiome Réglages Système, macOS 14+),
/// en remplacement de l'ancienne barre d'onglets horizontale qui était à l'étroit
/// à 8 entrées et n'aurait pas tenu une de plus. Le CONTENU des sections est
/// inchangé — seul le conteneur change.
///
/// Pourquoi un `HStack { List + détail }` et PAS un `NavigationSplitView` :
/// cette fenêtre est hébergée dans un `NSHostingController`/`NSWindow` créé à la
/// main (pas un `WindowGroup`/scène SwiftUI). Dans ce contexte, le binding de
/// sélection d'un `NavigationSplitView` ne pilote PAS le détail — la navigation
/// se fige sur la première section et le détail rend des lignes vides. Un
/// `List(selection:)` nu dans un `HStack`, lui, met à jour `@State` de façon
/// fiable. Même look de sidebar, navigation qui marche.
private struct PreferencesRoot: View {
    @Bindable var store: PreferencesStore
    @Bindable var nav: PreferencesNavigation
    let onModelChange: (String) -> Void
    let onCaptureToggle: (Bool) -> Void
    let onOpenOnboarding: () -> Void
    let onOpenHistoryViewer: () -> Void
    let onClearPersonalization: () -> Void

    @State private var query = ""

    /// Sections visibles selon la recherche — toutes si la requête est vide.
    private var filteredSections: [PrefSection] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return PrefSection.visible }
        return PrefSection.visible.filter { $0.matches(q) }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                PreferencesSearchField(query: $query)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                if filteredSections.isEmpty {
                    // Filet : requête sans résultat → message, pas une sidebar vide.
                    Spacer()
                    Text(tr(fr: "Aucun réglage", en: "No setting"))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    List(filteredSections, selection: $nav.selection) { section in
                        HStack {
                            Label(section.label, systemImage: section.systemImage)
                            if section.isStudio && !store.license.isPro {
                                Spacer()
                                // Cadenas : signale les sections incluses dans Studio
                                // tant que la licence n'est pas active.
                                Image(systemName: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(section)
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(width: 200)

            Divider()

            detail(for: nav.selection ?? .souffle)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .modifier(StudioGate(
                    locked: (nav.selection ?? .souffle).isStudio && !store.license.isPro,
                    onUnlock: { nav.selection = .studio }))
        }
        .frame(width: 800, height: 560)
        // La voix unique : un seul accent sang-de-bœuf irrigue toggles, sliders,
        // radios et boutons de toute la fenêtre, à la place du bleu système.
        .tint(.sangDeBoeuf)
        // Changement de langue d'interface = LIVE : `tr(...)` lit le Localizer au
        // moment du rendu, mais n'est pas observable par SwiftUI. On force la
        // reconstruction de tout l'arbre quand `uiLanguage` change → tous les
        // libellés (y compris les cartes modèle dont le catalogue se recalcule)
        // basculent immédiatement, sans rouvrir la fenêtre. La sélection de
        // section retombe sur la première : acceptable pour une action aussi rare.
        .id(store.uiLanguage)
    }

    @ViewBuilder
    private func detail(for section: PrefSection) -> some View {
        switch section {
        case .souffle:
            SouffleTab(store: store)
        case .apparence:
            AppearanceTab(store: store)
        case .traduction:
            TranslationTab(store: store)
        case .ton:
            ToneTab(store: store)
        case .aides:
            TypingAidsTab(store: store)
        case .personnalisation:
            PersonalizationTab(
                store: store,
                onOpenViewer: onOpenHistoryViewer,
                onClearAll: onClearPersonalization
            )
        case .contexte:
            EnrichmentTab(store: store, onCaptureToggle: onCaptureToggle)
        case .parApp:
            AllowlistTab(store: store)
        case .reglages:
            ReglagesTab(store: store, onOpenOnboarding: onOpenOnboarding)
        case .studio:
            LicenseTab(store: store)
        case .aPropos:
            AboutTab()
        }
    }
}

/// Ligne de réglage façon Réglages Système : icône à gauche, titre + sous-titre
/// qui explique le POURQUOI (convention maison « le rationale, pas la
/// signature »), contrôle à droite. Introduite ici comme vitrine de l'onglet
/// Apparence ; vouée à gagner les autres sections, une à la fois.
private struct SettingRow<Control: View>: View {
    let systemImage: String
    let title: String
    let subtitle: String
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 2)
    }
}

/// Onglet APPARENCE — comment le souffle SE MONTRE. Deux seuls leviers, tenus
/// court exprès : son opacité (plus ou moins discret avant acceptation) et sa
/// couleur, bornée à DEUX choix — gris neutre (défaut) ou sang-de-bœuf, la voix
/// de marque. Pas de nuancier libre façon cotabby : une seule voix, on ne la
/// dilue pas en douze teintes.
private struct AppearanceTab: View {
    @Bindable var store: PreferencesStore

    var body: some View {
        Form {
            Section {
                SettingRow(
                    systemImage: "circle.lefthalf.filled",
                    title: tr(fr: "Opacité du souffle", en: "Whisper opacity"),
                    subtitle: tr(fr: "À quel point la suggestion reste discrète avant que vous l'acceptiez. Au plus bas elle s'efface presque ; au plus haut elle s'affirme.", en: "How discreet the suggestion stays before you accept it. At the lowest it nearly fades away; at the highest it stands out.")
                ) {
                    HStack(spacing: 8) {
                        Slider(value: $store.ghostOpacity, in: 0.2...1.0)
                            .frame(width: 150)
                        Text("\(Int((store.ghostOpacity * 100).rounded())) %")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                SettingRow(
                    systemImage: "paintpalette",
                    title: tr(fr: "Couleur du souffle", en: "Whisper color"),
                    subtitle: tr(fr: "Le gris se lit comme « pas encore validé », un murmure. Le sang-de-bœuf affirme la voix de Souffleuse — au risque de ressembler à du texte déjà posé.", en: "Grey reads as “not yet accepted,” a murmur. Oxblood asserts Souffleuse’s voice — at the risk of looking like text already typed.")
                ) {
                    Picker("", selection: $store.ghostColorStyle) {
                        ForEach(GhostColorStyle.allCases, id: \.self) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            } header: {
                Text(tr(fr: "Le souffle", en: "The whisper")).font(.headline)
            } footer: {
                Text(tr(fr: "Pour voir l'effet : ouvrez un champ de texte, tapez quelques mots, et le souffle change en direct.", en: "To see the effect: open a text field, type a few words, and the whisper changes live."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
                Toggle(tr(fr: "Apprendre votre plume", en: "Learn your style"), isOn: $store.personalizationEnabled)
                    .onChange(of: store.personalizationEnabled) { _, on in
                        if on && !store.personalizationOnboardingShown {
                            showingOnboarding = true
                        }
                    }
                Text(tr(fr: "Gardé sous clé sur votre Mac. Rien ne part en ligne.", en: "Kept under lock on your Mac. Nothing goes online."))
                    .font(.callout).foregroundStyle(.secondary)
                Toggle(tr(fr: "Retenir aussi ce que vous écrivez sans accepter", en: "Also remember what you write without accepting"), isOn: $store.storeWithoutAccepted)
                    .disabled(!store.personalizationEnabled)
                Text(tr(fr: "Souffleuse apprend alors de tout ce que vous tapez, pas seulement des suggestions retenues — un meilleur reflet de votre style. À éviter si vous écrivez des choses sensibles.", en: "Souffleuse then learns from everything you type, not just the suggestions you keep — a better reflection of your style. Avoid this if you write sensitive things."))
                    .font(.callout).foregroundStyle(.secondary)
                Toggle(tr(fr: "Teinter les suggestions de vos mots et de votre ton", en: "Tint suggestions with your words and tone"), isOn: $store.personalizedSuggestionsEnabled)
                    .disabled(!store.personalizationEnabled)
                Text(tr(fr: "Le ghost reprend vos tournures récurrentes (un mot revenu dans plusieurs phrases est reproposé au bon endroit) et s'inspire de votre prose récente du même registre, application par application — le ton se règle dans l'onglet Ton.", en: "The whisper picks up your recurring phrasings (a word seen across several sentences is offered again in the right place) and draws on your recent prose in the same register, app by app — tone is set in the Tone tab."))
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text(tr(fr: "Apprendre de vous", en: "Learn from you")).font(.headline)
            }

            Section {
                VStack(alignment: .leading) {
                    Slider(
                        value: $store.personalizationStrength,
                        in: 0.0...2.0
                    ) {
                        Text(tr(fr: "Influence", en: "Influence"))
                    } minimumValueLabel: {
                        Text(tr(fr: "Off", en: "Off")).font(.callout).foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Text(tr(fr: "Max", en: "Max")).font(.callout).foregroundStyle(.secondary)
                    }
                    .disabled(!store.personalizationEnabled)
                    Text(String(format: tr(fr: "Valeur : %.2f", en: "Value: %.2f"), store.personalizationStrength))
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text(tr(fr: "Son influence", en: "Its influence")).font(.headline)
            } footer: {
                Text(tr(fr: "À zéro, Souffleuse observe sans rien changer. Au maximum, vos tournures familières reviennent fortement.", en: "At zero, Souffleuse observes without changing anything. At the maximum, your familiar phrasings come back strongly."))
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text(tr(fr: "Phrases retenues", en: "Phrases remembered"))
                    Spacer()
                    Text("\(entryCount)").font(.system(.body, design: .monospaced))
                }
                HStack {
                    Text(tr(fr: "Place occupée", en: "Space used"))
                    Spacer()
                    Text(formatBytes(sizeBytes)).font(.system(.body, design: .monospaced))
                }
                HStack {
                    Button(tr(fr: "Consulter…", en: "View…"), action: onOpenViewer)
                    Spacer()
                    Button(role: .destructive) {
                        showingClearConfirm = true
                    } label: {
                        Text(tr(fr: "Tout supprimer…", en: "Delete all…"))
                    }
                }
            } header: {
                Text(tr(fr: "Mes données", en: "My data")).font(.headline)
            }
        }
        .formStyle(.grouped)
        .task(id: store.personalizationEnabled) { await refresh() }
        .alert(tr(fr: "Apprendre votre plume ?", en: "Learn your style?"), isPresented: $showingOnboarding) {
            Button(tr(fr: "Annuler", en: "Cancel"), role: .cancel) {
                store.personalizationEnabled = false
            }
            Button(tr(fr: "Apprendre", en: "Learn")) {
                store.personalizationOnboardingShown = true
            }
        } message: {
            Text(tr(fr: "Souffleuse retiendra les phrases que vous acceptez, pour mieux vous souffler la suite. Tout est gardé sous clé sur votre Mac, jamais envoyé en ligne. Vous pouvez tout consulter ou tout effacer ici, à tout moment.", en: "Souffleuse will remember the phrases you accept, to better whisper what comes next. Everything is kept under lock on your Mac, never sent online. You can view or erase it all here, at any time."))
        }
        .confirmationDialog(
            tr(fr: "Effacer tout ce que Souffleuse a retenu ?", en: "Erase everything Souffleuse has remembered?"),
            isPresented: $showingClearConfirm,
            titleVisibility: .visible
        ) {
            Button(tr(fr: "Tout effacer", en: "Erase everything"), role: .destructive) {
                onClearAll()
                Task { await refresh() }
            }
            Button(tr(fr: "Annuler", en: "Cancel"), role: .cancel) {}
        } message: {
            Text(tr(fr: "Tout ce que Souffleuse a retenu disparaît pour de bon. Sans retour.", en: "Everything Souffleuse has remembered is gone for good. No way back."))
        }
    }

    private func refresh() async {
        entryCount = await store.history.count()
        sizeBytes = await store.history.sizeBytes()
    }

    private func formatBytes(_ b: Int) -> String {
        if b < 1024 { return "\(b)" + tr(fr: " o", en: " B") }
        let kb = Double(b) / 1024.0
        let sep = tr(fr: ",", en: ".")
        return String(format: "%.1f", kb).replacingOccurrences(of: ".", with: sep) + tr(fr: " Ko", en: " KB")
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
                Picker(tr(fr: "Longueur du souffle", en: "Whisper length"), selection: $store.completionLength) {
                    ForEach(CompletionLength.allCases, id: \.self) { l in
                        Text(l.label).tag(l)
                    }
                }
            } header: {
                Text(tr(fr: "La longueur", en: "Length")).font(.headline)
            } footer: {
                Text(tr(fr: "Plus c'est long, plus ça peut s'éloigner de votre intention. Tab accepte ; Esc écarte.", en: "The longer it is, the more it can drift from what you meant. Tab accepts; Esc dismisses."))
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                Toggle(tr(fr: "Souffler au milieu d'une ligne", en: "Whisper mid-line"), isOn: $store.midLineGhostEnabled)
                Text(tr(fr: "Quand le curseur est posé au milieu d'un texte, le souffle apparaît dans une petite bulle sous la ligne (au lieu de rester muet). Tab l'insère à l'endroit du curseur.", en: "When the cursor sits in the middle of some text, the whisper appears in a small bubble below the line (instead of staying silent). Tab inserts it at the cursor."))
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text(tr(fr: "Au milieu d'une ligne", en: "Mid-line")).font(.headline)
            }

            Section {
                Toggle(tr(fr: "Accepter mot à mot", en: "Accept word by word"), isOn: $store.partialAcceptEnabled)
                Text(tr(fr: "Tab pose un mot ; le reste attend en gris. Tab encore pour le suivant, Esc pour tout écarter.", en: "Tab places one word; the rest waits in grey. Tab again for the next, Esc to dismiss it all."))
                    .font(.callout).foregroundStyle(.secondary)
                Toggle(tr(fr: "Ajouter l'espace après le mot", en: "Add a space after the word"), isOn: $store.trailingSpaceOnPartial)
                    .disabled(!store.partialAcceptEnabled)
                Text(tr(fr: "Le curseur se place, prêt pour la suite. Désactivez pour gérer l'espace vous-même.", en: "The cursor lands ready for what comes next. Turn off to handle the space yourself."))
                    .font(.callout).foregroundStyle(.secondary)
                Picker(tr(fr: "Tout accepter avec", en: "Accept all with"), selection: $store.acceptAllKey) {
                    ForEach(AcceptAllKey.allCases, id: \.self) { key in
                        Text(key.label).tag(key)
                    }
                }
                Text(tr(fr: "Une touche qui pose toute la réplique d'un coup — active seulement quand un souffle s'affiche, donc elle ne gêne jamais votre frappe.", en: "A key that places the whole line at once — active only when a whisper is shown, so it never gets in the way of your typing."))
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text(tr(fr: "Accepter le souffle", en: "Accepting the whisper")).font(.headline)
            }

            Section {
                Toggle(tr(fr: "Corriger le texte avant de souffler", en: "Fix the text before whispering"), isOn: $store.prefixCorrectionEnabled)
                Text(tr(fr: "Souffleuse répare discrètement les coquilles de votre texte AVANT de prédire la suite — pour que le souffle parte du bon mot. Ne change rien à ce que vous avez tapé.", en: "Souffleuse quietly fixes typos in your text BEFORE predicting what comes next — so the whisper starts from the right word. Doesn't change what you typed."))
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text(tr(fr: "Avant de souffler", en: "Before whispering")).font(.headline)
            }
        }
        .formStyle(.grouped)
    }
}

/// Onglet AIDES À LA FRAPPE — coquilles · emoji · transformations « // ».
/// Extrait de Souffle (2026-06-17) : ces aides sont déclenchées par la FRAPPE
/// elle-même, indépendamment du souffle LLM ; les noyer dans Souffle allongeait
/// la page et mélangeait deux fonctions. Le bloc « // » a désormais un foyer
/// découvrable, cohérent avec la palette d'actions ouverte au clic sur le badge.
private struct TypingAidsTab: View {
    @Bindable var store: PreferencesStore

    var body: some View {
        Form {
            Section {
                Toggle(tr(fr: "Corriger les coquilles", en: "Fix typos"), isOn: $store.typoEnabled)
                Toggle(tr(fr: "Se taire quand une coquille est en cours", en: "Stay quiet while a typo is in progress"), isOn: $store.hideOnTypo)
                    .disabled(!store.typoEnabled)
            } header: {
                Text(tr(fr: "Coquilles", en: "Typos")).font(.headline)
            }

            Section {
                Toggle(tr(fr: "Emoji — panneau dès « \u{003A} » et expansion (\u{003A}smile\u{003A} → 😄)", en: "Emoji — panel on “\u{003A}” and expansion (\u{003A}smile\u{003A} → 😄)"), isOn: $store.emojiEnabled)
            } header: {
                Text(tr(fr: "Emoji", en: "Emoji")).font(.headline)
            }

            Section {
                Toggle(tr(fr: "Transformations « // » au clavier", en: "“//” keyboard transforms"), isOn: $store.slashTransformEnabled)
                    .disabled(!store.license.isPro)
                Text(tr(fr: "Tapez « // » après votre texte : corriger, raccourcir, reformuler, ton, traduire — ou une consigne libre validée par Entrée. En début de champ, « // » + quelques mots rédige le message complet. Le résultat s'affiche d'abord en aperçu ; Tab remplace, Esc annule. Les mêmes actions sont accessibles en cliquant l'icône de présence au curseur.", en: "Type “//” after your text: fix, shorten, rephrase, tone, translate — or a free instruction confirmed with Return. At the start of a field, “//” + a few words drafts the whole message. The result shows first as a preview; Tab replaces, Esc cancels. The same actions are available by clicking the presence icon at the cursor."))
                    .font(.callout).foregroundStyle(.secondary)
                Picker(tr(fr: "Rédiger en", en: "Draft in"), selection: $store.composeLanguage) {
                    ForEach(ComposeLanguage.allCases, id: \.self) { lang in
                        Text(lang.menuLabel).tag(lang)
                    }
                }
                .disabled(!store.slashTransformEnabled || !store.license.isPro)
                Text(tr(fr: "La langue par défaut quand vous rédigez depuis quelques mots — placée en ① du choix rapide au clavier ; les autres langues suivent (un chiffre change à la volée). « Suivre la conversation » met en tête la langue cible de traduction (ou celle du correspondant ; sinon la langue du système). Ne change pas corriger/reformuler, qui restent en français.", en: "The default language when you draft from a few words — placed at ① of the keyboard quick-pick; the other languages follow (a digit switches on the fly). “Follow the conversation” puts the translation target language at the top (or the correspondent's; otherwise the system language). Doesn't affect fix/rephrase, which stay in French."))
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                HStack {
                    Text(tr(fr: "Transformations « // »", en: "“//” transforms")).font(.headline)
                    if !store.license.isPro { StudioChip() }
                }
            } footer: {
                Text(tr(fr: "Mis en sommeil dans Xcode, VS Code, JetBrains et les terminaux. La correction ne change que ce que voit Souffleuse — votre texte reste tel que tapé.", en: "Put to sleep in Xcode, VS Code, JetBrains and terminals. Correction only changes what Souffleuse sees — your text stays exactly as typed."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Champ de recherche de la sidebar (idiome Réglages Système) : filtre les
/// sections par libellé OU mots-clés indexés. Un `TextField` stylé plutôt que
/// `.searchable` — ce dernier exige un conteneur `NavigationStack`, absent ici
/// (cf. la note de `PreferencesRoot` sur le choix `HStack`/`List`).
private struct PreferencesSearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField(tr(fr: "Rechercher", en: "Search"), text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(tr(fr: "Effacer", en: "Clear"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Verrou visuel d'un onglet Studio : bannière en tête + contenu désactivé/atténué
/// tant que `locked`. Appliqué au niveau de `detail()` → aucun onglet à modifier.
private struct StudioGate: ViewModifier {
    let locked: Bool
    let onUnlock: () -> Void

    func body(content: Content) -> some View {
        if locked {
            VStack(spacing: 0) {
                StudioLockBanner(onUnlock: onUnlock)
                content
                    .disabled(true)
                    .opacity(0.5)
            }
        } else {
            content
        }
    }
}

/// Petit badge « Studio » (cadenas) posé à côté d'un en-tête de section MIXTE
/// (ex. la sous-section « // » dans Aides, où coquilles/emoji restent gratuits).
private struct StudioChip: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "lock.fill")
            Text("Studio")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }
}

/// Bandeau « inclus dans Souffleuse Studio » + bouton de déblocage (navigue vers
/// la section Studio). N'apparaît que paywall armé ET licence inactive.
private struct StudioLockBanner: View {
    let onUnlock: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(tr(fr: "Inclus dans Souffleuse Studio", en: "Part of Souffleuse Studio"))
                    .font(.callout).fontWeight(.semibold)
                Text(tr(fr: "Débloqué par une licence unique, à vie.", en: "Unlocked by a one-time license, forever."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(tr(fr: "Débloquer…", en: "Unlock…"), action: onUnlock)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.4))
    }
}

/// Section LICENCE (Studio) — visible seulement quand le paywall est armé
/// (`LicenseGate.paywallEnabled`). Activée : statut + désactiver. Non activée :
/// coller-clé + activer + acheter. L'activation délègue au `LicenseStore` (un
/// appel réseau, puis cache Keychain ; au runtime, zéro réseau).
private struct LicenseTab: View {
    @Bindable var store: PreferencesStore
    @State private var keyInput = ""
    @State private var errorMessage: String?
    @State private var activating = false

    var body: some View {
        Form {
            if store.license.isActivated {
                Section {
                    Label(tr(fr: "Souffleuse Studio est actif", en: "Souffleuse Studio is active"), systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    if let key = store.license.activatedKey {
                        LabeledContent(tr(fr: "Licence", en: "License"), value: Self.masked(key))
                    }
                    Button(tr(fr: "Désactiver sur ce Mac", en: "Deactivate on this Mac"), role: .destructive) {
                        store.license.deactivate()
                        keyInput = ""
                        errorMessage = nil
                    }
                } header: {
                    Text(tr(fr: "Licence", en: "License")).font(.headline)
                } footer: {
                    Text(tr(fr: "La désactivation retire la licence de ce Mac uniquement.", en: "Deactivating removes the license from this Mac only."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Text(tr(fr: "Traduction, ton, transformations « // » et personnalisation — une licence unique, à vie, sur ce Mac.", en: "Translation, tone, “//” transforms and personalization — one license, forever, on this Mac."))
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        TextField(tr(fr: "Colle ta clé de licence", en: "Paste your license key"), text: $keyInput)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(activate)
                        Button(activating ? tr(fr: "Activation…", en: "Activating…") : tr(fr: "Activer", en: "Activate"), action: activate)
                            .disabled(activating || keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.callout).foregroundStyle(.red)
                    }
                } header: {
                    Text(tr(fr: "Débloquer Studio", en: "Unlock Studio")).font(.headline)
                }
                Section {
                    Button(tr(fr: "Acheter Souffleuse Studio…", en: "Buy Souffleuse Studio…")) {
                        NSWorkspace.shared.open(LicenseGate.purchaseURL)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func activate() {
        let key = keyInput
        guard !activating, !key.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        activating = true
        errorMessage = nil
        Task { @MainActor in
            let result = await store.license.activate(key: key)
            activating = false
            if case .failure(let e) = result { errorMessage = e.message }
        }
    }

    /// Masque la clé pour l'affichage (garde un repère sans tout exposer).
    private static func masked(_ key: String) -> String {
        guard key.count > 8 else { return "••••" }
        return key.prefix(5) + "•••••" + key.suffix(3)
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
                Picker(tr(fr: "Modèle de traduction", en: "Translation model"), selection: $store.translationModel) {
                    ForEach(InstructModel.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                Text(tr(fr: "Le moteur de traduction (le souffle français reste inchangé). Qwen 2.5 1.5B traduit mieux l'allemand/italien/japonais mais tient ~1 Go de RAM en plus pendant l'usage — libéré après inactivité. Le changement prend effet à la prochaine traduction.", en: "The translation engine (the French whisper is unchanged). Qwen 2.5 1.5B translates German/Italian/Japanese better but holds ~1 GB more RAM while in use — released after idle. The change takes effect on the next translation."))
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
                Text(tr(fr: "Le moteur", en: "The engine")).font(.headline)
            }

            Section {
                Picker(tr(fr: "Traduire à tout moment avec", en: "Translate anytime with"), selection: $store.translateHotKey) {
                    ForEach(TranslateHotKeyOption.allCases, id: \.self) { key in
                        Text(key.label).tag(key)
                    }
                }
                Text(tr(fr: "Raccourci global : traduit le champ en cours d'écriture, même sans souffle affiché. Une frappe, d'une main.", en: "Global shortcut: translates the field you’re writing in, even with no whisper shown. One keystroke, one hand."))
                    .font(.callout).foregroundStyle(.secondary)
                Picker(tr(fr: "Valider la traduction avec", en: "Commit the translation with"), selection: $store.commitKey) {
                    ForEach(CommitKey.allCases, id: \.self) { key in
                        Text(key.label).tag(key)
                    }
                }
                Text(tr(fr: "La touche qui envoie la réplique dans la langue cible — active quand un souffle ou le panneau de traduction est affiché.", en: "The key that sends the line in the target language — active when a whisper or the translation panel is shown."))
                    .font(.callout).foregroundStyle(.secondary)
                Picker(tr(fr: "Changer la langue cible avec", en: "Change the target language with"), selection: $store.targetCycleKey) {
                    ForEach(TargetCycleKey.allCases, id: \.self) { key in
                        Text(key.label).tag(key)
                    }
                }
                Text(tr(fr: "Fait défiler la langue cible (EN → ES → DE → IT → Auto) pour la conversation en cours — mémorisée par conversation. Auto suit la langue de votre interlocuteur quand la capture d'écran est active.", en: "Cycles the target language (EN → ES → DE → IT → Auto) for the current conversation — remembered per conversation. Auto follows your correspondent’s language when screen capture is on."))
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text(tr(fr: "Raccourcis", en: "Shortcuts")).font(.headline)
            } footer: {
                Text(tr(fr: "La traduction est en cours de construction.", en: "Translation is still being built."))
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
            Picker(tr(fr: "J'écris…", en: "I write in…"), selection: $store.primaryLanguage) {
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
                Text(tr(fr: "Ton Mac : \(ramGB) Go de mémoire", en: "Your Mac: \(ramGB) GB of memory"))
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
            Text(tr(fr: "Qui vous souffle", en: "Who whispers to you")).font(.headline)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr(fr: "Une seule voix souffle à la fois. Choisis « Conseillé » si tu hésites.", en: "Only one voice whispers at a time. Pick “Recommended” if you’re unsure."))
                Text(tr(fr: "Les voix « beaucoup de langues » sont meilleures hors français (allemand, italien, espagnol, chinois, japonais…).", en: "The “many languages” voices are better outside French (German, Italian, Spanish, Chinese, Japanese…)."))
                    .foregroundStyle(.secondary)
                Text(tr(fr: "Une voix absente se télécharge d'un clic ; tout reste sur ton Mac.", en: "A missing voice downloads in one click; everything stays on your Mac."))
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
            .accessibilityLabel(tr(fr: "Choisir \(model.displayName)", en: "Choose \(model.displayName)"))

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
                    chip(model.speedDisplay, systemImage: "speedometer", tint: speedTint)
                    chip(model.languagesLabel, systemImage: "globe", tint: .secondary)
                }
                // Mémoire + verdict pour ce Mac.
                HStack(spacing: 4) {
                    Image(systemName: "memorychip").font(.caption2).foregroundStyle(.secondary)
                    Text(tr(fr: "~\(formatGo(model.approxRAMMB)) en mémoire", en: "~\(formatGo(model.approxRAMMB)) in memory"))
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
                Label(tr(fr: "Voix active", en: "Active voice"), systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption).foregroundStyle(Color.sangDeBoeuf)
            } else {
                Button(tr(fr: "Choisir", en: "Choose"), action: onSelect).controlSize(.small)
            }
        }
    }

    // MARK: - Étiquettes

    private var recommendedChip: some View {
        Text(tr(fr: "Conseillé pour ton Mac", en: "Recommended for your Mac"))
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
        case .recommended: return tr(fr: "le meilleur choix ici", en: "the best choice here")
        case .comfortable: return tr(fr: "à l'aise sur ton Mac", en: "comfortable on your Mac")
        case .tight: return tr(fr: "ton Mac est un peu juste", en: "your Mac is a bit tight")
        case .tooHeavy: return tr(fr: "trop lourd pour ton Mac", en: "too heavy for your Mac")
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
        let sep = tr(fr: ",", en: ".")
        return String(format: "%.1f", go).replacingOccurrences(of: ".", with: sep) + tr(fr: " Go", en: " GB")
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
            Label(tr(fr: "Installé", en: "Installed"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
        case .downloading(let p):
            HStack(spacing: 6) {
                ProgressView(value: p).frame(width: 90)
                Text("\(Int(p * 100)) %").font(.caption).monospacedDigit()
            }
        case .absent:
            Button(tr(fr: "Télécharger (\(formatSize(model.approxSizeMB)))", en: "Download (\(formatSize(model.approxSizeMB)))")) { manager.download(model) }
                .controlSize(.small)
        case .failed:
            HStack(spacing: 6) {
                Text(tr(fr: "échec", en: "failed")).foregroundStyle(Color.sangDeBoeuf).font(.caption)
                Button(tr(fr: "Réessayer", en: "Retry")) { manager.download(model) }
                    .controlSize(.small)
            }
        }
    }

    /// Mo → libellé compact : « 811 Mo » sous 1 Go, « 2,4 Go » au-delà.
    private func formatSize(_ mb: Int) -> String {
        if mb < 1024 { return "\(mb)" + tr(fr: " Mo", en: " MB") }
        let go = Double(mb) / 1024.0
        let sep = tr(fr: ",", en: ".")
        return String(format: "%.1f", go).replacingOccurrences(of: ".", with: sep) + tr(fr: " Go", en: " GB")
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
                Picker(tr(fr: "Langue de l'interface", en: "Interface language"), selection: $store.uiLanguage) {
                    ForEach(UILanguage.allCases, id: \.self) { lang in
                        Text(lang.pickerLabel).tag(lang)
                    }
                }
                Text(tr(fr: "« Système » suit la langue de votre Mac. Les fenêtres déjà ouvertes adoptent la nouvelle langue à leur réouverture.", en: "“System” follows your Mac’s language. Windows already open adopt the new language when reopened."))
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text(tr(fr: "Langue", en: "Language")).font(.headline)
            }

            Section {
                Toggle(tr(fr: "Souffleuse à l'écoute", en: "Souffleuse listening"), isOn: $store.enabled)
                Text(tr(fr: "Entrer / sortir de scène : ⌃⌥⌘S", en: "Step on / off stage: ⌃⌥⌘S"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(tr(fr: "Couper le contexte d'un coup : ⌃⌥⌘E", en: "Cut context instantly: ⌃⌥⌘E"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text(tr(fr: "Activation", en: "Activation")).font(.headline)
            }

            Section {
                accessibilityBadge
            } header: {
                Text(tr(fr: "Autorisations", en: "Permissions")).font(.headline)
            } footer: {
                Text(tr(fr: "Sans cet accès, Souffleuse ne peut ni lire le champ où vous écrivez ni y poser le mot juste. Après une mise à jour, si Souffleuse apparaît cochée dans les Réglages mais se dit « absente », retirez l'entrée puis re-glissez l'app. L'accès à l'écran se règle dans l'onglet Contexte.", en: "Without this access, Souffleuse can neither read the field you’re writing in nor place the right word there. After an update, if Souffleuse shows as checked in Settings but reports itself “missing,” remove the entry and drag the app back in. Screen access is set in the Context tab."))
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                Toggle(tr(fr: "Lancer au démarrage du Mac", en: "Launch at Mac startup"), isOn: $launchAtLogin)
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
                Text(tr(fr: "Souffleuse démarre en sourdine dans la barre des menus à l'ouverture de session.", en: "Souffleuse starts quietly in the menu bar when you log in."))
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text(tr(fr: "Au démarrage", en: "At startup")).font(.headline)
            }

            Section {
                HStack {
                    Button(tr(fr: "Revoir les autorisations…", en: "Review permissions…"), action: onOpenOnboarding)
                    Button(tr(fr: "Ouvrir les Réglages système", en: "Open System Settings")) {
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
                     ? tr(fr: "Accès accordé — Souffleuse peut lire le champ et y souffler.", en: "Access granted — Souffleuse can read the field and whisper into it.")
                     : tr(fr: "Accès manquant. Souffleuse ne peut ni lire ni souffler tant que vous ne l'avez pas accordé.", en: "Access missing. Souffleuse can neither read nor whisper until you grant it."))
                    .font(.callout)
                    .foregroundStyle(hasAccessibility ? .secondary : .primary)
                if !hasAccessibility {
                    HStack(spacing: 8) {
                        Button(tr(fr: "Donner l'accès", en: "Grant access")) {
                            // Prompt=true shows the system alert AND opens
                            // Settings to the right pane if not yet trusted.
                            _ = AXClient.ensureTrusted(prompt: true)
                            hasAccessibility = AXClient.isTrusted
                        }
                        Button(tr(fr: "Ouvrir les Réglages", en: "Open Settings")) {
                            openAccessibilitySettings()
                        }
                        Button(tr(fr: "Vérifier", en: "Check")) {
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
                Toggle(tr(fr: "Tenir compte du contexte", en: "Take context into account"), isOn: $store.enrichmentEnabled)
                Toggle(tr(fr: "Lire ce qui est à l'écran", en: "Read what’s on screen"), isOn: Binding(
                    get: { store.captureEnabled },
                    set: { onCaptureToggle($0) }
                ))
                .disabled(!store.enrichmentEnabled)
                if store.captureEnabled, store.enrichmentEnabled {
                    permissionBadge
                }
            } header: {
                Text(tr(fr: "Autour de votre texte", en: "Around your text")).font(.headline)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr(fr: "Le presse-papiers et l'écran ne sont jamais conservés. Souffleuse ne se lit pas elle-même.", en: "The clipboard and the screen are never kept. Souffleuse doesn’t read itself."))
                    Text(tr(fr: "Lire l'écran aide dans les emails (sujet, destinataire) mais peut troubler les chats — Souffleuse mêle parfois ce qu'elle lit à votre réponse. Désactivez-la pour les conversations légères.", en: "Reading the screen helps in emails (subject, recipient) but can confuse chats — Souffleuse sometimes blends what it reads into your reply. Turn it off for casual conversations."))
                        .foregroundStyle(.orange)
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Toggle(tr(fr: "Français", en: "French"), isOn: $store.ocrLangFR)
                Toggle(tr(fr: "Anglais", en: "English"), isOn: $store.ocrLangEN)
                Toggle(tr(fr: "Espagnol", en: "Spanish"), isOn: $store.ocrLangES)
            } header: {
                Text(tr(fr: "Langues à l'écran", en: "On-screen languages")).font(.headline)
            } footer: {
                Text(tr(fr: "Au moins une langue. Si aucune n'est cochée, le français est utilisé par défaut.", en: "At least one language. If none is checked, French is used by default."))
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
                     ? tr(fr: "Lecture d'écran autorisée.", en: "Screen reading allowed.")
                     : tr(fr: "Lecture d'écran non autorisée. Souffleuse ne voit pas l'écran tant que vous ne l'avez pas accordé dans Réglages › Confidentialité.", en: "Screen reading not allowed. Souffleuse can’t see the screen until you grant it in Settings › Privacy."))
                    .font(.callout)
                    .foregroundStyle(hasScreenRecordingPermission ? .secondary : .primary)
                if !hasScreenRecordingPermission {
                    HStack(spacing: 8) {
                        Button(tr(fr: "Autoriser", en: "Allow")) {
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
                        Button(tr(fr: "Ouvrir les Réglages", en: "Open Settings")) {
                            openScreenRecordingSettings()
                        }
                        Button(tr(fr: "Vérifier", en: "Check")) {
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
                    .accessibilityLabel(tr(fr: "Ajouter une règle", en: "Add a rule"))
                Button(action: onRemove) { Image(systemName: "minus").frame(width: 24) }
                    .disabled(!hasSelection)
                    .accessibilityLabel(tr(fr: "Supprimer la règle sélectionnée", en: "Delete the selected rule"))
                Button(tr(fr: "Modifier…", en: "Edit…"), action: onEdit)
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
            Text(tr(fr: "Des règles, dans l'ordre : la première qui correspond (application + titre de fenêtre) l'emporte. Partout ailleurs, Souffleuse est active par défaut.", en: "Rules, in order: the first that matches (app + window title) wins. Everywhere else, Souffleuse is active by default."))
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
                    TableColumn(tr(fr: "Application", en: "App")) { rule in
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
                    TableColumn(tr(fr: "Titre (regex)", en: "Title (regex)")) { rule in
                        Text(rule.titleRegex.isEmpty ? "—" : rule.titleRegex)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(rule.titleRegex.isEmpty ? .secondary : .primary)
                    }
                    TableColumn(tr(fr: "Mode", en: "Mode")) { rule in
                        Text(rule.mode.label)
                    }
                }
                .frame(minHeight: 240)
            }
        }
        // Reprend le retrait qu'apportait l'ancien `.padding(20)` racine du
        // TabView : cet onglet est un VStack nu (pas un Form à insets propres).
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            TextField(tr(fr: "Rechercher une application…", en: "Search for an app…"), text: $filter)
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
                    Text(tr(fr: "Aucune application ne correspond — voir « Avancé ».", en: "No app matches — see “Advanced.”"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            DisclosureGroup(tr(fr: "Avancé — identifiant d'application", en: "Advanced — app identifier"), isExpanded: $showAdvanced) {
                TextField(tr(fr: "Bundle ID", en: "Bundle ID"), text: $rule.bundleID, prompt: Text("com.apple.mail"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            .font(.callout)

            TextField(tr(fr: "Titre (regex, optionnel)", en: "Title (regex, optional)"), text: $rule.titleRegex, prompt: Text("^Re: .*"))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(regexValid ? .primary : .red)
            Picker(tr(fr: "Mode", en: "Mode"), selection: $rule.mode) {
                ForEach(AllowlistMode.allCases, id: \.self) { m in
                    Text(m.label).tag(m)
                }
            }
            HStack {
                Spacer()
                Button(tr(fr: "Annuler", en: "Cancel"), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(tr(fr: "Enregistrer", en: "Save")) { onSave(rule) }
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

    /// Description du panneau, fidèle à ce que le ton gouverne RÉELLEMENT :
    /// la relecture toujours ; les suggestions seulement quand la préférence
    /// « Teinter les suggestions » (ou le flag dev) est active — mentir sur un
    /// comportement désactivé sèmerait le doute sur tout le panneau.
    private var panelDescription: String {
        var text = tr(fr: "Quand le correspondant écrit en français, ⌘↩ ne traduit pas : la souffleuse relit ton message. Choisis le registre — un défaut, et des exceptions par application.", en: "When your correspondent writes in French, ⌘↩ doesn’t translate: Souffleuse rephrases your message. Choose the register — a default, plus per-app exceptions.")
        if SuggestionPolicy.Tuning.stylePrimerEnabled || store.personalizedSuggestionsEnabled {
            text += tr(fr: " Ce registre teinte aussi les suggestions : dans chaque application, le ghost s'inspire de ta prose écrite sur le même ton.", en: " This register also tints suggestions: in each app, the whisper draws on your prose written in the same tone.")
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(panelDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker(tr(fr: "Ton par défaut", en: "Default tone"), selection: Binding(
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
                    TableColumn(tr(fr: "Application", en: "App")) { rule in
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
                    TableColumn(tr(fr: "Ton", en: "Tone")) { rule in
                        Text(rule.tone.displayName)
                    }
                }
                .frame(minHeight: 240)
            }
        }
        // Même retrait que l'onglet « Par application » : VStack nu, plus de
        // `.padding(20)` racine depuis le passage en sidebar.
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            TextField(tr(fr: "Rechercher une application…", en: "Search for an app…"), text: $filter)
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
                    Text(tr(fr: "Aucune application ne correspond — voir « Avancé ».", en: "No app matches — see “Advanced.”"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            DisclosureGroup(tr(fr: "Avancé — identifiant d'application", en: "Advanced — app identifier"), isExpanded: $showAdvanced) {
                TextField(tr(fr: "Bundle ID", en: "Bundle ID"), text: $rule.bundleID, prompt: Text("com.tinyspeck.slackmacgap"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            .font(.callout)

            Picker(tr(fr: "Ton", en: "Tone"), selection: $rule.tone) {
                ForEach(Tone.allCases, id: \.self) { t in
                    Text(t.displayName).tag(t)
                }
            }
            HStack {
                Spacer()
                Button(tr(fr: "Annuler", en: "Cancel"), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(tr(fr: "Enregistrer", en: "Save")) { onSave(rule) }
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
                Text(tr(fr: "Le mot juste, soufflé à voix basse.", en: "The right word, whispered."))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(tr(fr: "Tout reste sur votre Mac — rien ne passe en coulisses.", en: "Everything stays on your Mac — nothing happens behind the scenes."))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Text(tr(fr: "version \(version)", en: "version \(version)"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(tr(fr: "Le souffle apparaît en double ?", en: "Seeing the whisper twice?"))
                    .font(.headline)
                Text(tr(fr: "macOS glisse parfois ses propres suggestions par-dessus celles de Souffleuse. Désactivez-les pour n'en garder qu'une voix.", en: "macOS sometimes slips its own suggestions on top of Souffleuse’s. Turn them off to keep just one voice."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(tr(fr: "Ouvrir les réglages Clavier", en: "Open Keyboard settings")) {
                    let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
                    NSWorkspace.shared.open(url)
                }
                .padding(.top, 2)
            }
            Divider()
            Button(tr(fr: "Ouvrir le journal", en: "Open the log")) {
                let url = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Logs/Souffleuse.log")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Spacer()
            Text(tr(fr: "Aucune connexion, hormis le premier téléchargement de la voix. Aucun de vos mots n'est écrit dans les journaux.", en: "No connection, apart from the first download of the voice. None of your words are written to the logs."))
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
