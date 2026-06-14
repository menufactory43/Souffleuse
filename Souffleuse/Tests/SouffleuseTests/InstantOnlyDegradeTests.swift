import Testing
@testable import Souffleuse

/// Verrouille la dégradation INSTANT-ONLY qui remplace l'ancien greedy fallback.
/// Quand le beam n'est pas disponible (`useBeamCore == false`), `predict()` ne
/// doit lancer AUCUNE génération LLM — la couche instant reste seule, et un ghost
/// LLM périmé doit être nettoyé. Régression la plus insidieuse possible (invisible
/// en dev/CI où le beam charge toujours), donc testée en pur.
@MainActor
@Suite("Dégradation instant-only (retrait du greedy fallback)")
struct InstantOnlyDegradeTests {

    @Test("beam indisponible → dégrade vers instant-only")
    func degradesWhenBeamUnavailable() {
        #expect(PredictorViewModel.shouldDegradeToInstantOnly(useBeamCore: false) == true)
    }

    @Test("beam disponible → pas de dégradation (chemin LLM normal)")
    func noDegradeWhenBeamReady() {
        #expect(PredictorViewModel.shouldDegradeToInstantOnly(useBeamCore: true) == false)
    }

    @Test("dégradation : un ghost instant valide est PRÉSERVÉ")
    func instantGhostPreservedOnDegrade() {
        // Un recall L0/L1 affiché ne doit jamais être effacé par la bascule.
        #expect(PredictorViewModel.shouldClearStaleGhost(
            emittedGhost: false,
            instantGhost: "binance",          // instant présent
            displayedSuggestion: "binance"
        ) == false)
    }

    @Test("dégradation : un ghost LLM périmé est NETTOYÉ")
    func staleLLMGhostClearedOnDegrade() {
        // Aucun instant, mais un ghost LLM d'une frappe précédente traîne → clear.
        #expect(PredictorViewModel.shouldClearStaleGhost(
            emittedGhost: false,
            instantGhost: "",                 // rien d'instant
            displayedSuggestion: "je reviens vers vous"
        ) == true)
    }
}
