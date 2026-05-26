import Testing
import Foundation
import SouffleusePersonalization
import SouffleuseTyping
@testable import Souffleuse

/// Phase 3 (b) — Cotypist "short" fast-path: a strong corpus match yields the
/// saved continuation DIRECTLY as the ghost (zero LLM inference), and a weak /
/// absent match falls back to the cascade (nil → LLM).
@MainActor
@Suite("Phase 3 — corpus fast-path routing (strong match vs LLM fallback)")
struct CorpusFastPathTests {

    static func entry(_ context: String, _ accepted: String) -> TypingHistoryEntry {
        TypingHistoryEntry(timestamp: Date(), contextBefore: context, accepted: accepted, bundleID: nil)
    }
    static func engine() -> SuggestionPolicyEngine { SuggestionPolicyEngine(maxWords: 16) }

    // MARK: - strongCorpusMatch pure helper

    @Test func strongMatchFindsLongOverlapContinuation() {
        let snap = [
            Self.entry("", "Cordialement, Gabriel Waltio fondateur de Cocotypist")
        ]
        // User re-typed a long known prefix → strong match returns the tail.
        let m = SuggestionPolicy.strongCorpusMatch(
            userTail: "Cordialement, Gabriel ",
            snapshot: snap
        )
        #expect(m != nil)
        #expect(m?.continuation == "Waltio fondateur de Cocotypist")
        #expect((m?.matchedChars ?? 0) >= SuggestionPolicy.Tuning.strongCorpusMatchMinChars)
    }

    @Test func weakShortOverlapReturnsNil() {
        let snap = [Self.entry("", "Bonjour à tous")]
        // Only "Bonj" overlaps — far below strongCorpusMatchMinChars.
        let m = SuggestionPolicy.strongCorpusMatch(
            userTail: "Bonj",
            snapshot: snap
        )
        #expect(m == nil)
    }

    @Test func noOverlapReturnsNil() {
        let snap = [Self.entry("", "Le rendez-vous est fixé à quatorze heures")]
        let m = SuggestionPolicy.strongCorpusMatch(
            userTail: "completely unrelated typed text here",
            snapshot: snap
        )
        #expect(m == nil)
    }

    @Test func longestOverlapWins() {
        let snap = [
            Self.entry("", "Merci beaucoup pour votre aide précieuse"),
            Self.entry("", "Merci beaucoup pour votre temps aujourd'hui"),
        ]
        // Both share "Merci beaucoup pour votre " — newest-first ordering and
        // equal overlap → first (newest) wins.
        let m = SuggestionPolicy.strongCorpusMatch(
            userTail: "Merci beaucoup pour votre ",
            snapshot: snap
        )
        #expect(m != nil)
        #expect(m?.continuation == "aide précieuse")
    }

    // MARK: - routeInstant wiring

    /// Strong match → fast-path ghost emitted with source .history and a HIGH
    /// score (strongCorpusSourcePrior) so the LLM can only extend it.
    @Test func routeInstantFiresFastPathOnStrongMatch() {
        let p = Self.engine()
        let snap = [Self.entry("", "Le rendez-vous est fixé à quatorze heures précises mardi")]
        let r = p.routeInstant(
            userTail: "Le rendez-vous est fixé à ",
            historySnapshot: snap,
            wordCompleter: WordCompleter()
        )
        #expect(r != nil)
        #expect(r?.source == .history)
        #expect(r?.text.contains("quatorze") == true)
        // High prior → LLM replacement bar is unreachable from [0,1].
        #expect((r?.score.sourcePrior ?? 0) == SuggestionPolicy.Tuning.strongCorpusSourcePrior)
    }

    /// A strong fast-path ghost cannot be clobbered by a divergent LLM chunk —
    /// the LLM may only extend (replacement bar unreachable).
    @Test func llmCannotClobberStrongFastPathGhost() {
        let p = Self.engine()
        let strongScore = Score(
            sourcePrior: SuggestionPolicy.Tuning.strongCorpusSourcePrior,
            prefixFit: 1.0,
            lengthFit: 1.0
        )
        p.applyGhost("quatorze heures précises", source: .history, score: strongScore)
        // Divergent LLM chunk with a normal .llm score (0.60 max).
        let r = p.onLLMChunk("autre chose complètement", userTail: "à ")
        #expect(r == nil)  // blocked — strong ghost wins
    }

    /// No strong match + no L1 hit → routeInstant returns nil so the LLM
    /// fallback runs (the cascade's L2).
    @Test func routeInstantFallsBackToLLMWhenNoStrongMatch() {
        let p = Self.engine()
        let snap = [Self.entry("", "Bonjour à tous")]
        let r = p.routeInstant(
            userTail: "Texte sans rapport aucun avec ",
            historySnapshot: snap,
            wordCompleter: WordCompleter()
        )
        #expect(r == nil)  // → caller proceeds to LLM
    }

    /// Empty corpus → always nil (LLM fallback), never a crash.
    @Test func routeInstantEmptyCorpusFallsBack() {
        let p = Self.engine()
        let r = p.routeInstant(
            userTail: "anything reasonably long here ",
            historySnapshot: [],
            wordCompleter: WordCompleter()
        )
        #expect(r == nil)
    }
}
