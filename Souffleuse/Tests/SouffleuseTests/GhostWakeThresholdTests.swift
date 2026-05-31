import Testing
@testable import Souffleuse
import SouffleuseCore

// MARK: - GhostWakeThresholdTests

/// Garde le choix du seuil de réveil du moteur ghost endormi : 1ʳᵉ frappe quand
/// on reprend un brouillon réel (le champ contient déjà ≥ `ghostDraftResumeMinChars`
/// caractères au re-focus), sinon le plancher `ghostWarmupMinChars` pour ne pas
/// charger sur une barre de recherche courte. Pur, sans MainActor.
@Suite("Ghost wake threshold (reprise de brouillon vs champ court)")
struct GhostWakeThresholdTests {

    @Test("champ vide/court → plancher ghostWarmupMinChars (pas de charge inutile)")
    func shortFieldKeepsFloor() {
        let floor = SuggestionPolicy.Tuning.ghostWarmupMinChars
        #expect(SouffleuseAppDelegate.ghostWakeThreshold(draftBaselineChars: 0) == floor)
        #expect(SouffleuseAppDelegate.ghostWakeThreshold(draftBaselineChars: 5) == floor)
    }

    @Test("juste sous le seuil de reprise → encore le plancher")
    func belowResumeThresholdKeepsFloor() {
        let floor = SuggestionPolicy.Tuning.ghostWarmupMinChars
        let justBelow = SuggestionPolicy.Tuning.ghostDraftResumeMinChars - 1
        #expect(SouffleuseAppDelegate.ghostWakeThreshold(draftBaselineChars: justBelow) == floor)
    }

    @Test("brouillon réel (≥ ghostDraftResumeMinChars) → réveil dès la 1ʳᵉ frappe")
    func realDraftWakesOnFirstKeystroke() {
        let at = SuggestionPolicy.Tuning.ghostDraftResumeMinChars
        #expect(SouffleuseAppDelegate.ghostWakeThreshold(draftBaselineChars: at) == 1)
        #expect(SouffleuseAppDelegate.ghostWakeThreshold(draftBaselineChars: 200) == 1)
    }
}
