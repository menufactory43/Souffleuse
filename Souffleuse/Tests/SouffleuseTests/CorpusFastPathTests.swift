import Testing
import Foundation
import SouffleusePersonalization
import SouffleuseTyping
import SouffleuseCore
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

    /// A letter-led continuation COMPLETES the current word and is always
    /// accepted mid-word (the partial here, "bea", is an incomplete fragment).
    /// Acceptance of a separator-led (next-word) continuation only applies when
    /// the partial word is already complete — see
    /// `midWordCompleteWordTakesNextWordHistoryNotExtension`.
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

    /// Regression — the "vais" → "vaisselle" hijack. When the mid-word partial
    /// is itself a COMPLETE word ("vais"), the caret is at an effective word
    /// boundary: a next-word (space-led) corpus continuation is legitimate and
    /// must win. Before the fix, routeInstant's hard `isLetter` guard rejected
    /// " vous" and handed "vais" to the system completer, which extended it into
    /// the rarer "vaisselle" (ghost "selle"). Now the next-word history
    /// continuation is served instead.
    @Test func midWordCompleteWordTakesNextWordHistoryNotExtension() {
        let snap = [Self.entry("", "Bonjour, je vais vous montrer le dossier")]
        let r = Self.engine().routeInstant(
            userTail: "Bonjour, je vais",
            historySnapshot: snap,
            wordCompleter: WordCompleter()
        )
        #expect(r?.source == .history)
        #expect(r?.text.hasPrefix(" vous") == true)
        #expect(r?.source != .wordComplete)
    }

    /// A complete mid-word with NO corpus match must NOT be extended by the
    /// system completer (the same "vais" → "vaisselle" hijack, sans history).
    /// routeInstant returns nil so the next-word LLM path owns the continuation.
    /// Deterministic: the complete-word short-circuit returns before
    /// `WordCompleter` is consulted, so it does not depend on NSSpellChecker.
    @Test func midWordCompleteWordWithoutHistoryDoesNotExtend() {
        let r = Self.engine().routeInstant(
            userTail: "Je mange du pain",
            historySnapshot: [],
            wordCompleter: WordCompleter()
        )
        #expect(r == nil)
    }

    // MARK: - Micro-completion override ("Rapport fis" → "c" live fix)

    /// The micro-completion is still shown INSTANTLY at the strong prior
    /// (immediate feedback, Cotypist parity): "…Rapport fisc" recalled at
    /// "Rapport fis" yields "c" with source .history.
    @Test func microCorpusGhostShownInstantly() {
        let p = Self.engine()
        let snap = [Self.entry("", "Rapport fisc")]
        let r = p.routeInstant(
            userTail: "Rapport fis",
            historySnapshot: snap,
            wordCompleter: WordCompleter()
        )
        #expect(r?.source == .history)
        #expect(r?.text == "c")
    }

    /// THE live fix, with the REALISTIC streaming snapshot. The model heals
    /// "fis" → "fiscal" and the first cumulative one-line chunk is the SINGLE
    /// word "cal". A 1-word .llm chunk (score 0.36) can NEVER out-score a 1-word
    /// .history micro (0.55) through the lengthFit-based bar — so the override
    /// MUST come from the micro-completion replacement rule, not the score.
    /// Before this rule, feeding "cal" left "c" pinned (the bug the adversarial
    /// review surfaced — the old test masked it by feeding 3 words).
    @Test func oneWordHealedLLMOverridesMicroGhost() {
        let p = Self.engine()
        let snap = [Self.entry("", "Rapport fisc")]
        let inst = p.routeInstant(
            userTail: "Rapport fis",
            historySnapshot: snap,
            wordCompleter: WordCompleter()
        )
        #expect(inst?.text == "c")
        p.applyGhost(inst!.text, source: inst!.source, score: inst!.score)
        // ONE word — the realistic first streaming snapshot, not "cal annuel 2019".
        let r = p.onLLMChunk("cal", userTail: "Rapport fis")
        #expect(r != nil)
        #expect(r?.source == .llm)
        #expect(r?.text == "cal")
    }

    /// Regression guard (adversarial review v3, lens a): a LEARNED short
    /// completion the LLM heals to a DIFFERENT word must NOT be clobbered.
    /// "Bonne journ" recalls learned "ée" (journée); the model heals "journ" →
    /// "journal" (chunk "al"). "al" does NOT extend "ée", so the micro-override
    /// must NOT fire — the user's learned "ée" is kept.
    @Test func divergentHealDoesNotClobberLearnedMicro() {
        let p = Self.engine()
        let micro = Score(
            sourcePrior: SuggestionPolicy.Tuning.strongCorpusSourcePrior,
            prefixFit: 1.0,
            lengthFit: SuggestionPolicy.lengthFit(ghost: "ée")
        )
        p.applyGhost("ée", source: .history, score: micro)
        let r = p.onLLMChunk("al", userTail: "Bonne journ")  // → "journal", diverges from "ée"
        #expect(r == nil)   // learned "ée" kept; "al" does not extend "ée"
    }

    /// Conversely, a heal that EXTENDS the micro DOES override: "Bonne journ"
    /// micro "ée" + model chunk "ée chargée" (extends "ée") → richer suggestion.
    @Test func extendingHealOverridesMicro() {
        let p = Self.engine()
        let micro = Score(
            sourcePrior: SuggestionPolicy.Tuning.strongCorpusSourcePrior,
            prefixFit: 1.0,
            lengthFit: SuggestionPolicy.lengthFit(ghost: "ée")
        )
        p.applyGhost("ée", source: .history, score: micro)
        let r = p.onLLMChunk("ée chargée", userTail: "Bonne journ")  // extends "ée"
        #expect(r?.source == .llm)
        #expect(r?.text == "ée chargée")
    }

    /// Regression guard (adversarial review, lens b): an AFTER-SPACE recall
    /// whose continuation is a short word ("…lu mon " → "CV") is HIGH-confidence
    /// (long matched context) and must NOT be treated as a micro-completion — a
    /// generic LLM phrase must not clobber it. The micro rule is mid-word only.
    @Test func afterSpaceShortRecallNotClobbered() {
        let p = Self.engine()
        let snap = [Self.entry("", "Merci d'avoir lu mon CV")]
        let inst = p.routeInstant(
            userTail: "Merci d'avoir lu mon ",
            historySnapshot: snap,
            wordCompleter: WordCompleter()
        )
        #expect(inst?.text == "CV")
        #expect(inst?.score.sourcePrior == SuggestionPolicy.Tuning.strongCorpusSourcePrior)
        p.applyGhost(inst!.text, source: inst!.source, score: inst!.score)
        let r = p.onLLMChunk("rapport en pièce jointe", userTail: "Merci d'avoir lu mon ")
        #expect(r == nil)   // confident short recall stays — not a micro-completion
    }

    /// Classification unit test for the micro-completion predicate, incl. the
    /// boundaries that protect option-1 behaviour (fiscalité kept; after-space
    /// short recall protected; next-word continuation unaffected).
    @Test func isMicroCorpusCompletionClassification() {
        // Mid-word, 1–2 committed letters/digits → micro (overridable).
        #expect(SuggestionPolicy.isMicroCorpusCompletion(ghost: "c", userTail: "Rapport fis"))
        #expect(SuggestionPolicy.isMicroCorpusCompletion(ghost: "9", userTail: "Le total 2024"))
        #expect(SuggestionPolicy.isMicroCorpusCompletion(ghost: "'a", userTail: "je pense qu"))
        // ≥3 committed letters → NOT micro: substantial learned completion kept.
        #expect(!SuggestionPolicy.isMicroCorpusCompletion(ghost: "mment allez-vous ?", userTail: "Bonjour, co"))
        #expect(!SuggestionPolicy.isMicroCorpusCompletion(ghost: "lité", userTail: "Rapport fisca"))  // fiscalité stays
        // After-space tail → NOT micro: high-confidence short recall protected.
        #expect(!SuggestionPolicy.isMicroCorpusCompletion(ghost: "CV", userTail: "Merci d'avoir lu mon "))
        // Next-word (space-led) continuation → empty leading run → NOT micro.
        #expect(!SuggestionPolicy.isMicroCorpusCompletion(ghost: " vous montrer", userTail: "Bonjour, je vais"))
    }

    /// A SUBSTANTIAL mid-word completion (≥3 committed letters) keeps the
    /// unbeatable strong prior — learned phrases like "comment allez-vous ?"
    /// (and "fiscalité") stay pinned; the micro rule does not touch them.
    @Test func longCompletionKeepsStrongPrior() {
        let p = Self.engine()
        let snap = [Self.entry("Bonjour,", "comment allez-vous ?")]
        let r = p.routeInstant(
            userTail: "Bonjour, co",
            historySnapshot: snap,
            wordCompleter: WordCompleter()
        )
        #expect(r?.source == .history)
        #expect(r?.text == "mment allez-vous ?")
        #expect(r?.score.sourcePrior == SuggestionPolicy.Tuning.strongCorpusSourcePrior)
    }

    /// A NEXT-WORD continuation (space-led, after a complete word) keeps the
    /// strong prior — confident recall, not a micro-completion.
    @Test func nextWordCompletionKeepsStrongPrior() {
        let p = Self.engine()
        let snap = [Self.entry("", "Bonjour, je vais vous montrer le dossier")]
        let r = p.routeInstant(
            userTail: "Bonjour, je vais",
            historySnapshot: snap,
            wordCompleter: WordCompleter()
        )
        #expect(r?.source == .history)
        #expect(r?.text.hasPrefix(" vous") == true)
        #expect(r?.score.sourcePrior == SuggestionPolicy.Tuning.strongCorpusSourcePrior)
    }
}
