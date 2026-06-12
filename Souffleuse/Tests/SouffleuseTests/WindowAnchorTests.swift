import Testing
@testable import Souffleuse

// Garde l'ancrage de la fenêtre de contexte LLM (12/06) : la tête du
// `beforeCursor` doit rester STABLE entre les frappes (prefix-cache KV chaud)
// et ne sauter que par crans. Sans ancre, un suffix(1024) recalculé par frappe
// glissait d'un caractère à chaque frappe sur les champs longs — re-prefill
// ~300 tokens par génération, 3× moins de ghosts peints (run C, trace 12/06).
@Suite("PVM.anchoredWindowStart")
struct WindowAnchorTests {
    private let window = 1024
    private let slack = 256

    @Test("champ court : ancre à 0, stable")
    func shortFieldAnchorsAtZero() {
        #expect(PredictorViewModel.anchoredWindowStart(
            textCount: 500, window: window, slack: slack, previousStart: nil) == 0)
        #expect(PredictorViewModel.anchoredWindowStart(
            textCount: 600, window: window, slack: slack, previousStart: 0) == 0)
    }

    @Test("première frappe d'un champ long : ancre à len - window")
    func firstAnchorOnLongField() {
        #expect(PredictorViewModel.anchoredWindowStart(
            textCount: 2000, window: window, slack: slack, previousStart: nil) == 976)
    }

    @Test("frappe continue : l'ancre TIENT tant que le contenu tient sous window+slack")
    func anchorHoldsWithinSlack() {
        // Ancré à 976 (len 2000). L'utilisateur tape 200 chars de plus :
        // contenu = 2200 - 976 = 1224 ≤ 1280 → ancre inchangée.
        #expect(PredictorViewModel.anchoredWindowStart(
            textCount: 2200, window: window, slack: slack, previousStart: 976) == 976)
    }

    @Test("débordement : ré-ancrage d'un cran à len - window")
    func reanchorsBeyondSlack() {
        // Contenu = 2300 - 976 = 1324 > 1280 → ré-ancre à 2300 - 1024 = 1276.
        #expect(PredictorViewModel.anchoredWindowStart(
            textCount: 2300, window: window, slack: slack, previousStart: 976) == 1276)
    }

    @Test("champ raccourci sous l'ancre : ré-ancrage")
    func reanchorsWhenTextShrinksBelowAnchor() {
        #expect(PredictorViewModel.anchoredWindowStart(
            textCount: 800, window: window, slack: slack, previousStart: 976) == 0)
    }

    @Test("suppression DANS la fenêtre : l'ancre tient (tête stable)")
    func anchorHoldsOnInWindowDeletion() {
        // len 1900, ancre 976 : contenu 924 ≤ 1280 et ancre ≤ len → tient.
        #expect(PredictorViewModel.anchoredWindowStart(
            textCount: 1900, window: window, slack: slack, previousStart: 976) == 976)
    }
}
