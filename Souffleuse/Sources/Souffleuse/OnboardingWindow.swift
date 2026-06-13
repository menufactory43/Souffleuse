import AppKit
import Foundation
import IOKit.hid
import Observation
import ServiceManagement
import SouffleuseAX
import SouffleuseContext
import SouffleuseCore
import SwiftUI

// MARK: - Step enum

/// Séquence de l'onboarding wizard. Les étapes « terminales » (welcome/done)
/// n'ont ni pips de progression ni pied Retour/Continuer.
enum OnboardingStep: Int, CaseIterable {
    case welcome
    case permissions
    case language
    case voice
    case howItWorks
    case commands
    case done

    // MARK: Progression

    /// Index 1-basé dans l'indicateur de progression (nil pour les terminales).
    var intermediateIndex: Int? {
        switch self {
        case .welcome, .done: return nil
        case .permissions: return 1
        case .language: return 2
        case .voice: return 3
        case .howItWorks: return 4
        case .commands: return 5
        }
    }

    /// Nombre total d'étapes intermédiaires (permissions → commandes).
    static let intermediateCount = 5

    // MARK: Taille de fenêtre préférée

    /// Taille cible de la fenêtre pour cette étape. L'AppKit owner anime le
    /// resize, recentre et clampe au visibleFrame ; le ScrollView absorbe le
    /// débordement.
    var preferredSize: CGSize {
        switch self {
        case .welcome:     return CGSize(width: 480, height: 360)
        case .permissions: return CGSize(width: 560, height: 640)
        case .language:    return CGSize(width: 480, height: 420)
        case .voice:       return CGSize(width: 520, height: 480)
        case .howItWorks:  return CGSize(width: 500, height: 460)
        case .commands:    return CGSize(width: 540, height: 600)
        case .done:        return CGSize(width: 480, height: 400)
        }
    }

    // MARK: Voisinage

    var previous: OnboardingStep? {
        OnboardingStep(rawValue: rawValue - 1)
    }

    var next: OnboardingStep? {
        OnboardingStep(rawValue: rawValue + 1)
    }
}

// MARK: - Flow decision (pure, testable)

/// Mode du wizard. `full` = intro complète (premier lancement ou reprise) ;
/// `permissionsOnly` = revisit où SEULES des permissions manquent → une étape,
/// pas de réintro (inspiré de Cap : ne pas refaire tout le wizard pour un trou
/// de TCC après une MAJ macOS).
enum OnboardingMode: Equatable {
    case full
    case permissionsOnly
}

/// Décision pure « quel mode, quelle étape de départ ». Extraite de
/// `makeOnboardingWindow` pour être testable sans AppKit ni permissions réelles.
struct OnboardingPlan: Equatable {
    let mode: OnboardingMode
    let initialStep: OnboardingStep

    /// - `isFresh` : override dev `SOUFFLEUSE_ONBOARDING=fresh`.
    /// - `alreadyOnboarded` : complétion versionnée déjà écrite.
    /// - `ghostReady` : le GGUF du souffle est sur le disque.
    /// - `savedStep` : étape persistée pour la reprise (clé `onboardingProgressStep2`).
    static func resolve(
        isFresh: Bool,
        alreadyOnboarded: Bool,
        axGranted: Bool,
        inputMonitoringGranted: Bool,
        ghostReady: Bool,
        savedStep: Int
    ) -> OnboardingPlan {
        // Fresh : on repart de zéro, intro complète.
        if isFresh {
            return OnboardingPlan(mode: .full, initialStep: .welcome)
        }
        let missingRequiredPermission = !axGranted || !inputMonitoringGranted
        // Revisit où seules des permissions manquent ET le souffle est déjà là :
        // mode permissions-only, on n'a rien d'autre à (re)faire.
        if alreadyOnboarded, missingRequiredPermission, ghostReady {
            return OnboardingPlan(mode: .permissionsOnly, initialStep: .permissions)
        }
        // Revisit où une permission requise manque MAIS le souffle aussi (quitté
        // avant la fin du téléchargement) : wizard complet, mais on saute droit
        // aux permissions plutôt que de refaire l'intro.
        if alreadyOnboarded, missingRequiredPermission {
            return OnboardingPlan(mode: .full, initialStep: .permissions)
        }
        // Reprise normale à l'étape persistée (clampée à une étape valide).
        let step = OnboardingStep(rawValue: savedStep) ?? .welcome
        return OnboardingPlan(mode: .full, initialStep: step)
    }
}

// MARK: - Color extension (local)

private extension Color {
    /// Sang-de-bœuf (#8c2b21) — action primaire et cue « à accorder ».
    /// Éclairci en dark mode pour rester lisible (≥ 4,5:1).
    static var sangDeBoeuf: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return dark
                ? NSColor(srgbRed: 0xd0 / 255, green: 0x6a / 255, blue: 0x5d / 255, alpha: 1)
                : NSColor(srgbRed: 0x8c / 255, green: 0x2b / 255, blue: 0x21 / 255, alpha: 1)
        })
    }
}

// MARK: - Observable model

/// État partagé du wizard entre la fenêtre AppKit et les vues SwiftUI.
@MainActor
@Observable
final class OnboardingModel {
    var currentStep: OnboardingStep
    /// Mode permissions-only : le wizard se réduit à la seule étape permissions
    /// (revisit où il ne manque que des autorisations). Fixé à l'init, immuable.
    let permissionsOnly: Bool
    // Permission states — rafraîchis par poll 1 s depuis show()
    var axGranted: Bool = false
    var imGranted: Bool = false
    var screenGranted: Bool = false
    // Langue sélectionnée
    var selectedLanguage: PrimaryLanguage

    init(initialStep: OnboardingStep, initialLanguage: PrimaryLanguage, permissionsOnly: Bool = false) {
        self.currentStep = initialStep
        self.selectedLanguage = initialLanguage
        self.permissionsOnly = permissionsOnly
    }

    func refreshPermissions() {
        axGranted = AXClient.isTrusted
        imGranted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        screenGranted = ScreenCapturer.hasPermission()
    }
}

// MARK: - Root SwiftUI view

/// Vue racine du wizard. Dispatche vers la sous-vue de l'étape et gère les deux
/// layouts (terminal vs intermédiaire avec pied fixe).
@MainActor
private struct OnboardingRootView: View {
    @Bindable var model: OnboardingModel
    let manager: ModelDownloadManager
    let ghostProvider: () -> DownloadableModel?
    let ghostReady: () -> Bool
    let canTryGhost: () -> Bool
    let translation: DownloadableModel?
    let onLanguageChange: @MainActor (PrimaryLanguage) -> Void
    let onFinished: @MainActor () -> Void
    let onProgress: @MainActor (Int) -> Void
    let onGhostInstalled: (@MainActor () -> Void)?
    let close: @MainActor () -> Void

    var body: some View {
        // Le whisper sanctionné de cette surface (même choix que Préférences) :
        // l'accent sang-de-bœuf remplace le bleu système sur les contrôles.
        content.tint(Color.sangDeBoeuf)
    }

    @ViewBuilder
    private var content: some View {
        // Revisit « permissions-only » : on court-circuite tout le wizard et on
        // ne montre que l'étape permissions avec un pied dédié.
        if model.permissionsOnly {
            permissionsOnlyLayout
        } else {
            switch model.currentStep {
            case .welcome:
                terminalLayout { WelcomeStepView(onStart: advance) }
            case .done:
                terminalLayout {
                    DoneStepView(
                        manager: manager,
                        ghostProvider: ghostProvider,
                        ghostReady: ghostReady,
                        axGranted: model.axGranted,
                        imGranted: model.imGranted,
                        onFinished: {
                            onFinished()
                            close()
                        }
                    )
                }
            default:
                scrollLayout
            }
        }
    }

    // MARK: Permissions-only layout (revisit)

    /// Revisit où seules des permissions manquent : une seule étape, ni pips ni
    /// Retour. Le pied est un unique bouton « Continuer vers Souffleuse » qui
    /// termine le wizard dès qu'Accessibilité + Surveillance des entrées sont là.
    private var permissionsOnlyLayout: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Pourquoi l'utilisateur revoit cet écran : rassurer, pas culpabiliser.
                    Text("macOS a peut-être désactivé une autorisation après une mise à jour. Réactivez-la et Souffleuse reprend là où elle en était.")
                        .font(.system(size: 13, design: .serif))
                        .italic()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 30)

                    PermissionsStepView(
                        axGranted: model.axGranted,
                        imGranted: model.imGranted,
                        screenGranted: model.screenGranted
                    )
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Spacer(minLength: 0)
                Button("Continuer vers Souffleuse") {
                    onFinished()
                    close()
                }
                .buttonStyle(SangDeBoeufButtonStyle())
                .controlSize(.large)
                .disabled(!corePermissionsGranted)
                .help(corePermissionsGranted ? "" : "Accordez Accessibilité et Surveillance des entrées pour continuer.")
            }
            .padding(.horizontal, 36)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Les deux permissions requises sont accordées (gate « peut continuer/finir »).
    private var corePermissionsGranted: Bool {
        model.axGranted && model.imGranted
    }

    // MARK: Terminal layout

    private func terminalLayout<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            content()
            Spacer(minLength: 0)
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Scroll layout (étapes intermédiaires)

    private var scrollLayout: some View {
        VStack(spacing: 0) {
            // En-tête pips — hors du scroll
            if let idx = model.currentStep.intermediateIndex {
                // 30 pt en haut : le contenu passe sous la barre transparente
                // (.fullSizeContentView), les pips doivent dégager les feux.
                OnboardingProgressHeader(current: idx, total: OnboardingStep.intermediateCount)
                    .padding(.horizontal, 36)
                    .padding(.top, 30)
                    .padding(.bottom, 8)
            }

            // Contenu défilant
            ScrollView {
                stepContent
                    .padding(.horizontal, 36)
                    .padding(.top, 16)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            // Pied FIXE — toujours visible, JAMAIS dans le ScrollView
            stepFooter
                .padding(.horizontal, 36)
                .padding(.top, 12)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Contenu par étape

    @ViewBuilder
    private var stepContent: some View {
        switch model.currentStep {
        case .permissions:
            PermissionsStepView(
                axGranted: model.axGranted,
                imGranted: model.imGranted,
                screenGranted: model.screenGranted
            )
        case .language:
            LanguageStepView(
                selectedLanguage: $model.selectedLanguage,
                onLanguageChange: onLanguageChange
            )
        case .voice:
            VoiceStepView(
                manager: manager,
                ghostProvider: ghostProvider,
                ghostReady: ghostReady,
                translation: translation,
                onGhostInstalled: onGhostInstalled
            )
        case .howItWorks:
            HowItWorksStepView(canTryGhost: canTryGhost)
        case .commands:
            CommandsStepView()
        case .welcome, .done:
            EmptyView()
        }
    }

    // MARK: Pied de page par étape

    @ViewBuilder
    private var stepFooter: some View {
        switch model.currentStep {
        case .permissions:
            // Pas de « Passer » ici : l'étape EST de débloquer les permissions.
            OnboardingFooter(
                canContinue: corePermissionsGranted,
                continueHint: "Accordez Accessibilité et Surveillance des entrées pour continuer.",
                onBack: retreat,
                onContinue: advance
            )
        case .language:
            OnboardingFooter(
                canContinue: true,
                onSkip: skipAction,
                onBack: retreat,
                onContinue: advance
            )
        case .voice:
            OnboardingFooter(
                canContinue: voiceCanContinue,
                continueHint: "Téléchargez la voix (ou laissez-la se télécharger) pour continuer.",
                onSkip: skipAction,
                onBack: retreat,
                onContinue: advance
            )
        case .howItWorks:
            OnboardingFooter(
                canContinue: true,
                onSkip: skipAction,
                onBack: retreat,
                onContinue: advance
            )
        case .commands:
            OnboardingFooter(
                canContinue: true,
                onSkip: skipAction,
                onBack: retreat,
                onContinue: advance
            )
        case .welcome, .done:
            EmptyView()
        }
    }

    // MARK: Passer l'intro

    /// Échappatoire pour les revenants : dès que les permissions requises sont
    /// là, on peut sauter le reste de l'intro et filer à l'étape finale (qui
    /// porte encore « Lancer au login » + le CTA). `nil` tant que les permissions
    /// manquent — on ne propose pas de passer un wizard encore inutilisable.
    private var skipAction: (() -> Void)? {
        corePermissionsGranted ? { skipToDone() } : nil
    }

    private func skipToDone() {
        model.currentStep = .done
        onProgress(OnboardingStep.done.rawValue)
    }

    // MARK: Gate voix

    private var voiceCanContinue: Bool {
        if ghostReady() { return true }
        guard let ghost = ghostProvider() else { return true }
        switch manager.status(for: ghost) {
        case .ready: return true
        case .downloading: return true  // finit en arrière-plan
        case .absent, .failed: return false
        }
    }

    // MARK: Navigation

    private func advance() {
        guard let next = model.currentStep.next else { return }
        model.currentStep = next
        onProgress(next.rawValue)
    }

    private func retreat() {
        guard let prev = model.currentStep.previous else { return }
        model.currentStep = prev
        onProgress(prev.rawValue)
    }
}

// MARK: - Progress header

private struct OnboardingProgressHeader: View {
    let current: Int
    let total: Int

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(1...total, id: \.self) { i in
                    Capsule()
                        .fill(i <= current ? Color.sangDeBoeuf : Color.secondary.opacity(0.25))
                        .frame(width: i == current ? 22 : 14, height: 5)
                        .animation(.easeInOut(duration: 0.2), value: current)
                }
            }
            Text("Étape \(current) sur \(total)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Étape \(current) sur \(total)")
    }
}

// MARK: - Footer (Retour / Continuer)

private struct OnboardingFooter: View {
    var canContinue: Bool = true
    var continueHint: String = ""
    /// Présent → affiche un « Passer l'intro » discret au centre (revenants).
    var onSkip: (() -> Void)? = nil
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        HStack {
            Button("Retour") { onBack() }
                .controlSize(.large)
            Spacer(minLength: 0)
            if let onSkip {
                // Échappatoire discrète : gris, sans cadre, pour ne pas concurrencer
                // l'action primaire « Continuer ».
                Button("Passer l'intro") { onSkip() }
                    .buttonStyle(.plain)
                    .controlSize(.large)
                    .foregroundStyle(.secondary)
                    .help("Vous connaissez déjà Souffleuse — filez à la fin.")
                Spacer(minLength: 0)
            }
            Button("Continuer") { onContinue() }
                .buttonStyle(SangDeBoeufButtonStyle())
                .controlSize(.large)
                .disabled(!canContinue)
                .help(canContinue ? "" : continueHint)
        }
    }
}

// MARK: - Button styles

private struct SangDeBoeufButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color.sangDeBoeuf.opacity(configuration.isPressed ? 0.8 : 1))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .font(.system(size: 14, weight: .medium))
    }
}

// MARK: - Step: Welcome

private struct WelcomeStepView: View {
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 18) {
                // Logo de l'app, coins arrondis façon icône macOS. NSApp.applicationIconImage
                // est la source fiable (suit Resources/AppIcon.icns sans dépendre de son layout interne).
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(spacing: 10) {
                    Text("Bienvenue dans Souffleuse")
                        .font(.system(size: 22, weight: .semibold, design: .serif))
                        .multilineTextAlignment(.center)

                    Text("Souffleuse vit dans votre barre de menus et souffle le mot juste là où vous écrivez. Quelques réglages, puis elle s'efface.")
                        .font(.system(size: 13, design: .serif))
                        .italic()
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            Button("Commencer") { onStart() }
                .buttonStyle(SangDeBoeufButtonStyle())
                .controlSize(.large)
        }
        .frame(maxWidth: 380)
    }
}

// MARK: - Step: Permissions

private struct PermissionsStepView: View {
    let axGranted: Bool
    let imGranted: Bool
    let screenGranted: Bool

    @State private var helpExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Ce qu'il faut autoriser")
                .font(.system(size: 22, weight: .semibold, design: .serif))

            // Carte Accessibilité (requise)
            PermissionCard(
                symbol: "accessibility",
                title: "Accessibilité",
                subtitle: "Lit le champ de saisie où vous êtes, et y écrit la suggestion que vous acceptez.",
                isGranted: axGranted,
                isOptional: false,
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!,
                onAuthorize: { AXClient.ensureTrusted(prompt: true) }
            )

            // Carte Surveillance des entrées (requise)
            PermissionCard(
                symbol: "keyboard",
                title: "Surveillance des entrées",
                subtitle: "Capte Tab et Esc, et seulement eux, quand une suggestion est à l'écran.",
                isGranted: imGranted,
                isOptional: false,
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!,
                onAuthorize: { IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
            )

            // Carte Enregistrement de l'écran (optionnelle)
            PermissionCard(
                symbol: "rectangle.on.rectangle",
                title: "Enregistrement de l'écran",
                subtitle: "Laissez Souffleuse lire ce qui est à l'écran pour des suggestions plus justes. Reste éteint tant que vous ne l'accordez pas.",
                isGranted: screenGranted,
                isOptional: true,
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!,
                onAuthorize: { Task { await ScreenCapturer.forcePermissionPrompt() } }
            )

            // Réassurance factuelle : le gate isSecureField (tick l.1378) + la blocklist
            // secureBundles écartent champs de mot de passe et apps bancaires en amont.
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Les champs de mot de passe ne sont jamais lus, ni les apps bancaires.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)

            // Encart d'aide repliable
            DisclosureGroup(isExpanded: $helpExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    HelpBullet("Souffleuse n'apparaît pas dans la liste ? Cliquez « Autoriser » ci-dessus : elle s'ajoutera toute seule, puis activez l'interrupteur en face de son nom dans Réglages.")
                    HelpBullet("macOS vous demande de relancer Souffleuse ? C'est normal après avoir autorisé. Relancez : vous reprendrez ici même, vos réglages sont gardés.")
                    HelpBullet("Le bouton reste « à accorder » ? Vérifiez que l'interrupteur est bien ALLUMÉ (bleu) dans Réglages, pas juste coché.")
                }
                .padding(.top, 8)
            } label: {
                Text("Un souci pour autoriser ?")
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.top, 4)
        }
    }
}

private struct HelpBullet: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Permission card

private struct PermissionCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    let isGranted: Bool
    let isOptional: Bool
    let settingsURL: URL
    let onAuthorize: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                // Badge icône
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                        if isOptional {
                            Text("Optionnel")
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        // Badge état live — jamais de ✗ rouge
                        statusBadge
                    }

                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Boutons d'action
            if !isGranted {
                HStack(spacing: 8) {
                    Button("Autoriser") { onAuthorize() }
                        .controlSize(.small)
                    Button("Ouvrir Réglages") {
                        NSWorkspace.shared.open(settingsURL)
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 48)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        )
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isGranted {
            Text("✓ accordée")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        } else if isOptional {
            Text("optionnel")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        } else {
            // Cue sang-de-bœuf pour l'action requise — jamais de ✗ rouge
            Text("à accorder")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.sangDeBoeuf)
        }
    }
}

// MARK: - Step: Language

private struct LanguageStepView: View {
    @Binding var selectedLanguage: PrimaryLanguage
    let onLanguageChange: @MainActor (PrimaryLanguage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Votre langue")
                    .font(.system(size: 22, weight: .semibold, design: .serif))

                Text("Sert à vous conseiller la bonne voix : en français, une petite voix rapide suffit ; pour plusieurs langues, une voix multilingue. Modifiable à tout moment.")
                    .font(.system(size: 13, design: .serif))
                    .italic()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("", selection: $selectedLanguage) {
                ForEach(PrimaryLanguage.allCases, id: \.self) { lang in
                    Text(lang.label).tag(lang)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedLanguage) { _, newLang in
                onLanguageChange(newLang)
            }
        }
    }
}

// MARK: - Step: Voice

@MainActor
private struct VoiceStepView: View {
    let manager: ModelDownloadManager
    let ghostProvider: () -> DownloadableModel?
    let ghostReady: () -> Bool
    let translation: DownloadableModel?
    let onGhostInstalled: (@MainActor () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("La voix")
                .font(.system(size: 22, weight: .semibold, design: .serif))

            // Carte voix du souffle (requise) — « voix », pas « modèle » : la
            // cible n'est pas geek, le mot technique n'apporte rien ici.
            if let ghost = ghostProvider() {
                ModelCard(
                    title: "La voix du souffle",
                    subtitle: "Ce qui souffle vos suggestions. Une minute environ, 100 % sur votre Mac, rien ne sort.",
                    model: ghost,
                    manager: manager,
                    isOptional: false,
                    isReadyExternally: ghostReady
                )
            }

            // Carte traduction (optionnelle)
            if let translationModel = translation {
                ModelCard(
                    title: "La traduction",
                    subtitle: "Pour la traduction et la relecture par ton. Téléchargé tout seul au premier usage si vous passez.",
                    model: translationModel,
                    manager: manager,
                    isOptional: true,
                    isReadyExternally: { false }
                )
            }
        }
        // Note : la transition absent→installé du souffle est détectée par le
        // Timer 1 s de OnboardingWindow.show() — pas besoin d'onChange ici.
    }
}

// MARK: - Model card

private struct ModelCard: View {
    let title: String
    let subtitle: String
    let model: DownloadableModel
    let manager: ModelDownloadManager
    let isOptional: Bool
    let isReadyExternally: () -> Bool

    private var effectiveStatus: ModelDownloadManager.Status {
        if isReadyExternally() { return .ready }
        return manager.status(for: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                        if isOptional {
                            Text("Optionnel")
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        modelStatusBadge
                    }

                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            modelControls
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        )
    }

    @ViewBuilder
    private var modelStatusBadge: some View {
        switch effectiveStatus {
        case .ready:
            Text("✓ installé")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        case .downloading(let p):
            Text("\(Int(p * 100)) %")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        case .absent:
            if isOptional {
                Text("optionnel")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else {
                Text("à télécharger")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.sangDeBoeuf)
            }
        case .failed:
            Text("échec")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.sangDeBoeuf)
        }
    }

    @ViewBuilder
    private var modelControls: some View {
        switch effectiveStatus {
        case .ready:
            EmptyView()
        case .downloading(let p):
            ProgressView(value: p)
                .progressViewStyle(.linear)
                .frame(maxWidth: 200)
        case .absent:
            Button("Télécharger (\(model.approxSizeMB) Mo)") {
                manager.download(model)
            }
            .controlSize(.small)
        case .failed:
            Button("Réessayer") {
                manager.download(model)
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Ghost try field (NSTextField AppKit)

/// Champ texte AppKit pour l'étape « Comment ça marche » : un vrai champ où le
/// pipeline normal (tick → AX → predictor → overlay → Tab) souffle pour de vrai.
/// On passe par AppKit et NON par un TextField SwiftUI car l'AX d'un TextField
/// SwiftUI n'expose pas toujours caret/bounds de façon fiable pour AXClient.
private struct GhostTryField: NSViewRepresentable {
    let placeholderSeed: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: placeholderSeed)
        field.font = .systemFont(ofSize: 15)
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.lineBreakMode = .byTruncatingTail
        // Auto-focus + caret en fin de seed pour que la frappe continue la phrase.
        DispatchQueue.main.async {
            guard let win = field.window else { return }
            win.makeFirstResponder(field)
            field.currentEditor()?.selectedRange = NSRange(location: placeholderSeed.count, length: 0)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {}
}

// MARK: - Step: How it works

private struct HowItWorksStepView: View {
    let canTryGhost: () -> Bool

    private let seed = "Bonjour, je voulais vous dire que "

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Comment ça marche")
                .font(.system(size: 22, weight: .semibold, design: .serif))

            if canTryGhost() {
                // Essai RÉEL : un vrai champ où le souffle apparaît au caret.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Essayez : écrivez quelques mots. Quand le mot gris apparaît, appuyez sur Tab pour l'accepter.")
                        .font(.system(size: 13, design: .serif))
                        .italic()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    GhostTryField(placeholderSeed: seed)
                        .frame(height: 30)
                }
            } else {
                // Repli : la voix n'est pas encore prête → maquette statique
                // (le souffle ne viendrait pas, autant ne pas frustrer).
                HStack(spacing: 0) {
                    Text("Bonjour, je vous ")
                        .font(.system(size: 15))
                    + Text("écris ce mot")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
                )
            }

            VStack(alignment: .leading, spacing: 12) {
                HowBullet("Le mot juste apparaît en gris : appuyez sur **Tab** pour l'accepter.")
                HowBullet("Il ne vous va pas ? **Esc**, ou continuez d'écrire : il s'efface.")
                HowBullet("Souffleuse reste dans la barre de menus, en haut à droite.")
            }
        }
    }
}

private struct HowBullet: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(.secondary)
                .font(.system(size: 14))
            Text(text)
                .font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Step: Commands (pour aller plus loin)

/// Étape de découverte des commandes texte : le picker `//`, les emojis `:` et
/// la traduction au raccourci. Purement informative (pas d'essai live ici) —
/// les déclencheurs exacts sont calqués sur SlashTransformDetector / EmojiExpander
/// / TranslationHotKey pour ne jamais mentir sur la syntaxe.
private struct CommandsStepView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pour aller plus loin")
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                Text("Au-delà du souffle, Souffleuse corrige, reformule, traduit et glisse des emojis — sans quitter votre clavier.")
                    .font(.system(size: 13, design: .serif))
                    .italic()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Le couteau suisse texte : // au début d'un mot.
            CommandCard(
                trigger: "//",
                title: "Corriger, reformuler, traduire",
                subtitle: "Tapez // au début d'un mot, puis un chiffre — ou décrivez ce que vous voulez."
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    SlashIntent(number: "1", label: "Corriger", detail: "orthographe et grammaire")
                    SlashIntent(number: "2", label: "Raccourcir", detail: "plus court, même sens")
                    SlashIntent(number: "3", label: "Reformuler", detail: "autrement, plus clair")
                    SlashIntent(number: "4", label: "Changer le ton", detail: "selon l'app où vous écrivez")
                    SlashIntent(number: "5", label: "Traduire", detail: "vers la langue de la conversation")
                }
                .padding(.top, 2)
            }

            // Emojis : deux-points + nom.
            CommandCard(
                trigger: ":",
                title: "Glisser un emoji",
                subtitle: "Tapez : puis un nom — :sourire: — ou commencez (:sou) et choisissez d'un chiffre."
            )

            // Traduction au vol : raccourci global.
            CommandCard(
                trigger: "⌥⌘T",
                title: "Traduire le champ",
                subtitle: "Traduit tout le champ d'un raccourci. ⌘⇧→ change la langue cible, ⌘↩ applique."
            )

            Text("Tout est rappelé dans les Préférences — rien à mémoriser maintenant.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
    }
}

/// Carte « commande » : une pastille mono pour le déclencheur, un titre, un
/// sous-titre, et un contenu détaillé optionnel (la liste des intentions de `//`).
private struct CommandCard<Extra: View>: View {
    let trigger: String
    let title: String
    let subtitle: String
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Text(trigger)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.sangDeBoeuf.opacity(0.12))
                    )
                    .foregroundStyle(Color.sangDeBoeuf)
                    .fixedSize()

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            extra()
                .padding(.leading, 4)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        )
    }
}

/// Carte sans contenu détaillé (emoji, traduction) — overload `EmptyView`.
extension CommandCard where Extra == EmptyView {
    init(trigger: String, title: String, subtitle: String) {
        self.init(trigger: trigger, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Une ligne d'intention du picker `//` : chiffre + libellé + précision.
private struct SlashIntent: View {
    let number: String
    let label: String
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Text(number)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.secondary.opacity(0.15)))
                .foregroundStyle(.secondary)
            Text(label)
                .font(.system(size: 13, weight: .medium))
            Text("· \(detail)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Step: Done

@MainActor
private struct DoneStepView: View {
    let manager: ModelDownloadManager
    let ghostProvider: () -> DownloadableModel?
    let ghostReady: () -> Bool
    let axGranted: Bool
    let imGranted: Bool
    let onFinished: () -> Void

    /// L'état de l'item de login EST sa source de vérité (pas de pref stockée) :
    /// on lit SMAppService.mainApp.status. Décoché par défaut — on ne pré-active
    /// jamais sans consentement explicite.
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    private var canFinish: Bool { axGranted && imGranted }

    private var ghostStatus: ModelDownloadManager.Status? {
        guard !ghostReady(), let ghost = ghostProvider() else { return nil }
        return manager.status(for: ghost)
    }

    private var isDownloading: Bool {
        if case .downloading = ghostStatus { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 24) {
            // Checkmark sang-de-bœuf
            ZStack {
                Circle()
                    .fill(Color.sangDeBoeuf.opacity(0.12))
                    .shadow(color: Color.sangDeBoeuf.opacity(0.08), radius: 8, y: 2)
                Text("✓")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.sangDeBoeuf)
            }
            .frame(width: 64, height: 64)

            VStack(spacing: 8) {
                Text("C'est prêt")
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                Text("Tab pour accepter, Esc pour ignorer.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            // Rappel si téléchargement encore en cours
            if isDownloading {
                Text("La voix finit de se télécharger en arrière-plan — vous pourrez écrire dès qu'elle est prête.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 4) {
                Toggle("Lancer Souffleuse à l'ouverture du Mac", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            // Échec d'enregistrement (build dev hors /Applications) →
                            // resync silencieux, fidèle au house-style « fallback silencieux ».
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                    .toggleStyle(.checkbox)
                Text("Conseillé : la souffleuse ne souffle que si elle est ouverte.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 300)

            Button("Commencer à écrire") { onFinished() }
                .buttonStyle(SangDeBoeufButtonStyle())
                .controlSize(.large)
                .disabled(!canFinish)
                .help(canFinish ? "" : "Accordez Accessibilité et Surveillance des entrées pour commencer.")
        }
        .frame(maxWidth: 340)
    }
}

// MARK: - NSWindow host

/// Wizard d'onboarding multi-étapes hébergé dans un `NSWindow`.
///
/// Remplace l'ancienne version AppKit mono-page. Même signature `init` (+ 3 paramètres
/// nouveaux : `onFinished`, `initialStep`, `onProgress`). `show()`/`close()` inchangés.
@MainActor
final class OnboardingWindow {
    private let window: NSWindow
    private let model: OnboardingModel
    private let host: NSHostingController<OnboardingRootView>
    private var refreshTimer: Timer?

    /// Appelé quand le ghost passe de absent → installé pendant la session.
    private let onGhostInstalled: (@MainActor () -> Void)?
    /// Dernier état ghost-prêt — pour détecter la transition.
    private var lastGhostReady: Bool?
    /// Ghost provider, gardé pour le refresh de transition.
    private let ghostReady: () -> Bool

    /// Vrai quand l'essai réel du souffle est en scène : fenêtre key ET étape
    /// « Comment ça marche ». C'est la SEULE situation où le tick de
    /// l'AppDelegate laisse le pipeline tourner alors que Souffleuse est l'app
    /// active (exception au gate R1) — le seul champ focusable de cette étape
    /// est le champ d'essai AppKit, dont l'AX est fiable.
    var isTryGhostStepActive: Bool {
        window.isKeyWindow && model.currentStep == .howItWorks
    }

    // MARK: Init

    init(
        modelDownloads: ModelDownloadManager,
        ghostProvider: @escaping () -> DownloadableModel?,
        ghostReady: @escaping () -> Bool,
        canTryGhost: @escaping () -> Bool,
        translation: DownloadableModel?,
        initialLanguage: PrimaryLanguage,
        onLanguageChange: @escaping @MainActor (PrimaryLanguage) -> Void,
        onGhostInstalled: (@MainActor () -> Void)? = nil,
        onFinished: @escaping @MainActor () -> Void,
        initialStep: Int = 0,
        permissionsOnly: Bool = false,
        onProgress: @escaping @MainActor (Int) -> Void
    ) {
        self.onGhostInstalled = onGhostInstalled
        self.ghostReady = ghostReady

        let step = OnboardingStep(rawValue: initialStep) ?? .welcome
        let mdl = OnboardingModel(initialStep: step, initialLanguage: initialLanguage, permissionsOnly: permissionsOnly)
        self.model = mdl

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Int(step.preferredSize.width), height: Int(step.preferredSize.height)),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Titre gardé pour Mission Control/VoiceOver, mais barre masquée : chaque
        // étape porte déjà son titre serif — la barre ne ferait que le doubler.
        window.title = "Bienvenue dans Souffleuse"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window

        // Closure de fermeture capturant faiblement la fenêtre (évite une ref cyclique)
        let closeAction: @MainActor () -> Void = { [weak window] in
            window?.orderOut(nil)
        }

        let rootView = OnboardingRootView(
            model: mdl,
            manager: modelDownloads,
            ghostProvider: ghostProvider,
            ghostReady: ghostReady,
            canTryGhost: canTryGhost,
            translation: translation,
            onLanguageChange: onLanguageChange,
            onFinished: onFinished,
            onProgress: onProgress,
            onGhostInstalled: onGhostInstalled,
            close: closeAction
        )
        let host = NSHostingController(rootView: rootView)
        self.host = host
        window.contentViewController = host

        // Anime le resize à chaque changement d'étape (withAnimation assuré par SwiftUI)
        // Le resize AppKit est piloté depuis une observation du modèle via onChange dans show().
    }

    // MARK: Public API

    func show() {
        // Rafraîchit les permissions au premier affichage
        model.refreshPermissions()

        // Animate vers la taille de l'étape courante, recentre sur l'écran
        resizeWindow(to: model.currentStep.preferredSize, animated: false)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Poll 1 s pour les permissions (non observables via @Observable)
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.refreshPermissions()
                // Transition absent → installé : notifie l'AppDelegate
                let nowReady = self.ghostReady()
                if self.lastGhostReady == false, nowReady {
                    self.onGhostInstalled?()
                }
                self.lastGhostReady = nowReady
                // Anime le resize si l'étape a changé entre deux ticks
                self.resizeWindow(to: self.model.currentStep.preferredSize, animated: true)
            }
        }
        // Seed lastGhostReady pour ne pas déclencher onGhostInstalled sur un modèle déjà là
        lastGhostReady = ghostReady()
    }

    func close() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        window.orderOut(nil)
    }

    // MARK: Resize

    private func resizeWindow(to size: CGSize, animated: Bool) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let w = min(size.width, visible.width)
        let h = min(size.height, visible.height)
        // Centre dans le visibleFrame
        let x = visible.minX + (visible.width - w) / 2
        let y = visible.minY + (visible.height - h) / 2
        let frame = NSRect(x: x, y: y, width: w, height: h)
        window.setFrame(frame, display: true, animate: animated)
        host.view.frame = window.contentView?.bounds ?? CGRect(origin: .zero, size: size)
    }
}
