import Foundation
import Testing
@testable import Souffleuse

// MARK: - OnboardingFlowTests

/// Verrouille la logique pure du wizard d'onboarding — séquence des étapes,
/// progression, et surtout la décision `OnboardingPlan.resolve` (mode + étape de
/// départ : premier lancement, reprise, et le revisit « permissions-only » ajouté
/// pour ne pas refaire toute l'intro quand seule une TCC a sauté). Aucun AppKit ni
/// permission réelle ici : tout est dérivé d'entrées explicites.
@Suite("Onboarding flow (steps + plan)")
struct OnboardingFlowTests {

    // MARK: - Séquence des étapes

    @Test("l'ordre des étapes est welcome → … → commandes → done")
    func stepOrder() {
        #expect(OnboardingStep.allCases == [
            .welcome, .permissions, .language, .voice, .howItWorks, .commands, .done,
        ])
    }

    @Test("permissions garde rawValue 1 (le saut direct au revisit en dépend)")
    func permissionsRawValueStable() {
        #expect(OnboardingStep.permissions.rawValue == 1)
    }

    @Test("next/previous chaînent toute la séquence et butent aux extrémités")
    func neighbourChaining() {
        #expect(OnboardingStep.welcome.previous == nil)
        #expect(OnboardingStep.welcome.next == .permissions)
        #expect(OnboardingStep.howItWorks.next == .commands)
        #expect(OnboardingStep.commands.next == .done)
        #expect(OnboardingStep.commands.previous == .howItWorks)
        #expect(OnboardingStep.done.next == nil)
    }

    // MARK: - Progression (pips)

    @Test("5 étapes intermédiaires, indexées 1…5 ; les terminales sont hors barre")
    func intermediateIndexing() {
        #expect(OnboardingStep.intermediateCount == 5)
        #expect(OnboardingStep.welcome.intermediateIndex == nil)
        #expect(OnboardingStep.done.intermediateIndex == nil)
        #expect(OnboardingStep.permissions.intermediateIndex == 1)
        #expect(OnboardingStep.language.intermediateIndex == 2)
        #expect(OnboardingStep.voice.intermediateIndex == 3)
        #expect(OnboardingStep.howItWorks.intermediateIndex == 4)
        #expect(OnboardingStep.commands.intermediateIndex == 5)
    }

    @Test("toutes les étapes ont une taille préférée non dégénérée")
    func preferredSizesValid() {
        for step in OnboardingStep.allCases {
            #expect(step.preferredSize.width > 0)
            #expect(step.preferredSize.height > 0)
        }
    }

    // MARK: - Plan : premier lancement / fresh

    @Test("fresh → wizard complet depuis welcome, quelles que soient les permissions")
    func freshAlwaysFullFromWelcome() {
        let plan = OnboardingPlan.resolve(
            isFresh: true,
            alreadyOnboarded: true,            // ignoré quand fresh
            axGranted: true,
            inputMonitoringGranted: true,
            ghostReady: true,
            savedStep: 4
        )
        #expect(plan == OnboardingPlan(mode: .full, initialStep: .welcome))
    }

    @Test("jamais onboardé → wizard complet, reprise à l'étape persistée")
    func neverOnboardedResumesSavedStep() {
        let plan = OnboardingPlan.resolve(
            isFresh: false,
            alreadyOnboarded: false,
            axGranted: false,
            inputMonitoringGranted: false,
            ghostReady: false,
            savedStep: OnboardingStep.voice.rawValue
        )
        #expect(plan == OnboardingPlan(mode: .full, initialStep: .voice))
    }

    @Test("savedStep hors bornes → repli sur welcome (clamp)")
    func savedStepClamped() {
        let plan = OnboardingPlan.resolve(
            isFresh: false,
            alreadyOnboarded: false,
            axGranted: true,
            inputMonitoringGranted: true,
            ghostReady: true,
            savedStep: 999
        )
        #expect(plan == OnboardingPlan(mode: .full, initialStep: .welcome))
    }

    // MARK: - Plan : revisit permissions-only

    @Test("revisit, souffle prêt, AX manquante → permissions-only sur l'étape permissions")
    func revisitMissingAXIsPermissionsOnly() {
        let plan = OnboardingPlan.resolve(
            isFresh: false,
            alreadyOnboarded: true,
            axGranted: false,
            inputMonitoringGranted: true,
            ghostReady: true,
            savedStep: 0
        )
        #expect(plan == OnboardingPlan(mode: .permissionsOnly, initialStep: .permissions))
    }

    @Test("revisit, souffle prêt, Input Monitoring manquant → permissions-only")
    func revisitMissingInputMonitoringIsPermissionsOnly() {
        let plan = OnboardingPlan.resolve(
            isFresh: false,
            alreadyOnboarded: true,
            axGranted: true,
            inputMonitoringGranted: false,
            ghostReady: true,
            savedStep: 0
        )
        #expect(plan == OnboardingPlan(mode: .permissionsOnly, initialStep: .permissions))
    }

    @Test("revisit où le souffle manque AUSSI → wizard complet (pas permissions-only), saut aux permissions")
    func revisitMissingGhostFallsBackToFullWizard() {
        let plan = OnboardingPlan.resolve(
            isFresh: false,
            alreadyOnboarded: true,
            axGranted: false,
            inputMonitoringGranted: true,
            ghostReady: false,            // le souffle n'est pas sur disque → il faut l'étape voix
            savedStep: 0
        )
        #expect(plan == OnboardingPlan(mode: .full, initialStep: .permissions))
    }

    @Test("revisit complet (tout accordé) → reprise normale, jamais permissions-only")
    func revisitAllGrantedResumesSaved() {
        let plan = OnboardingPlan.resolve(
            isFresh: false,
            alreadyOnboarded: true,
            axGranted: true,
            inputMonitoringGranted: true,
            ghostReady: true,
            savedStep: OnboardingStep.commands.rawValue
        )
        #expect(plan.mode == .full)
        #expect(plan.initialStep == .commands)
    }
}
