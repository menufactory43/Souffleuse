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

    // MARK: - Mid-word phrase recall (Cotypist "Bonjour, co" → "…allez-vous ?")

    /// The exact Cotypist-parity repro: caret INSIDE "co", the in-progress
    /// fragment plus its leading context ("Bonjour, co") prefix a learned phrase
    /// → recall the whole phrase. With the mid-word threshold the 11-char needle
    /// clears the bar that the 16-char after-space threshold would have missed.
    @Test func strongMatchRecallsPhraseMidWordWithLowerThreshold() {
        let snap = [Self.entry("Bonjour,", "comment allez-vous ?")]
        let m = SuggestionPolicy.strongCorpusMatch(
            userTail: "Bonjour, co",
            snapshot: snap,
            minChars: SuggestionPolicy.Tuning.midWordCorpusMatchMinChars
        )
        #expect(m?.continuation == "mment allez-vous ?")
        // The same call at the stricter after-space threshold would NOT fire
        // (11-char needle < 16) — that's why mid-word needs its own bar.
        #expect(SuggestionPolicy.strongCorpusMatch(userTail: "Bonjour, co", snapshot: snap) == nil)
    }

    /// routeInstant on a mid-word tail recalls the learned phrase DIRECTLY as a
    /// .history ghost (no LLM), beating the system word completer.
    @Test func routeInstantRecallsPhraseMidWord() {
        let p = Self.engine()
        let snap = [Self.entry("Bonjour,", "comment allez-vous ?")]
        let r = p.routeInstant(
            userTail: "Bonjour, co",
            historySnapshot: snap,
            wordCompleter: WordCompleter()
        )
        #expect(r?.source == .history)
        #expect(r?.text == "mment allez-vous ?")
    }

    /// A bare in-progress fragment with NO preceding context must NOT recall a
    /// phrase — the needle ("co", 2 chars) is below the mid-word threshold, so
    /// we don't hallucinate "comment allez-vous ?" from two letters.
    @Test func bareFragmentDoesNotRecallPhrase() {
        let snap = [Self.entry("Bonjour,", "comment allez-vous ?")]
        let m = SuggestionPolicy.strongCorpusMatch(
            userTail: "co",
            snapshot: snap,
            minChars: SuggestionPolicy.Tuning.midWordCorpusMatchMinChars
        )
        #expect(m == nil)
    }

    /// The continuation must COMPLETE the current word (start with a letter). A
    /// match whose continuation begins on a separator would be a word-boundary
    /// jump, not a mid-word completion — routeInstant's mid-word branch rejects
    /// it and falls through (here the only entry yields a letter-led
    /// continuation, so the guard's positive case is what's exercised).
    @Test func midWordRecallContinuationStartsWithLetter() {
        let snap = [Self.entry("Je vous remercie", "beaucoup pour votre retour")]
        let r = Self.engine().routeInstant(
            userTail: "Je vous remercie bea",
            historySnapshot: snap,
            wordCompleter: WordCompleter()
        )
        #expect(r?.source == .history)
        #expect(r?.text.first?.isLetter == true)
        #expect(r?.text == "ucoup pour votre retour")
    }
}
