import Testing
import Foundation
import SouffleuseCore
@testable import Souffleuse

/// Phase 4 plan 04-01 — pure-function tests on the Ghost Relevance Gate
/// fondation : `Score`, `SuggestionPolicy.score(...)`, `prefixFit`, `lengthFit`.
///
/// **Convention Pitfall 6 (D-13) :** aucun literal numérique de seuil n'apparaît
/// dans ce fichier — toujours référencer `SuggestionPolicy.Tuning.*`. Le grep
/// CI de Task 4 refuse tout literal hors `SuggestionPolicy+Tuning.swift`.
@Suite("Phase 4 — Relevance Gate scoring (D-06, D-07, D-13)")
struct RelevanceGateTests {

    // MARK: - Score value formula (D-06)

    @Test func scoreValueIsProductOfThreeFactors() {
        // Use explicit Float locals so the RHS multiplication has identical
        // precision to the Score.value getter (Float, not Double-then-cast).
        let a = Score(sourcePrior: 0.5, prefixFit: 1.0, lengthFit: 1.0)
        #expect(a.value == a.sourcePrior * a.prefixFit * a.lengthFit)

        let b = Score(sourcePrior: 0.5, prefixFit: 0.5, lengthFit: 0.5)
        #expect(b.value == b.sourcePrior * b.prefixFit * b.lengthFit)

        let c = Score(
            sourcePrior: SuggestionPolicy.Tuning.sourcePrior[.history] ?? 0,
            prefixFit: 1.0,
            lengthFit: SuggestionPolicy.Tuning.lengthFitByWordCount[6]
        )
        #expect(c.value == c.sourcePrior * c.prefixFit * c.lengthFit)
    }

    // MARK: - Gate floor (D-07)

    @Test func passesGateBlocksUnderFloor() {
        // 0.5 * 0.5 * 0.5 = 0.125, which is strictly below Tuning.gateFloor.
        let s = Score(sourcePrior: 0.5, prefixFit: 0.5, lengthFit: 0.5)
        #expect(s.value < SuggestionPolicy.Tuning.gateFloor)
        #expect(s.passesGate == false)
    }

    @Test func passesGateAcceptsAboveFloor() {
        // history prior (0.75 in D-06) × prefixFit 1 × lengthFit 1 ≥ gateFloor.
        let s = Score(
            sourcePrior: SuggestionPolicy.Tuning.sourcePrior[.history] ?? 0,
            prefixFit: 1.0,
            lengthFit: 1.0
        )
        #expect(s.value >= SuggestionPolicy.Tuning.gateFloor)
        #expect(s.passesGate == true)
    }

    // MARK: - Replacement bar (D-07)

    @Test func beatsReturnsFalseForEqualScores() {
        let a = Score(sourcePrior: 0.6, prefixFit: 1.0, lengthFit: 1.0)
        let b = a
        // Equal scores : a.value >= b.value * 1.15 ⇔ 0.6 >= 0.69 ⇒ false.
        #expect(a.beats(b) == false)
    }

    @Test func beatsReturnsTrueWhenAboveReplacementBar() {
        let lower = Score(sourcePrior: 0.6, prefixFit: 1.0, lengthFit: 1.0)
        // Use the history prior so the higher score exceeds lower × replacementBar.
        let higherPrior = SuggestionPolicy.Tuning.sourcePrior[.history] ?? 0
        let higher = Score(sourcePrior: higherPrior, prefixFit: 1.0, lengthFit: 1.0)
        #expect(higher.value >= lower.value * SuggestionPolicy.Tuning.replacementBar)
        #expect(higher.beats(lower))
    }

    @Test func beatsReturnsFalseJustBelowReplacementBar() {
        let lower = Score(sourcePrior: 0.6, prefixFit: 1.0, lengthFit: 1.0)
        let candidate = Score(sourcePrior: 0.65, prefixFit: 1.0, lengthFit: 1.0)
        // 0.65 < 0.6 * 1.15 = 0.69 ⇒ false.
        #expect(candidate.value < lower.value * SuggestionPolicy.Tuning.replacementBar)
        #expect(candidate.beats(lower) == false)
    }

    // MARK: - Source priors (D-06)

    @Test func sourcePriorOrderingMatchesD06() {
        let priors = SuggestionPolicy.Tuning.sourcePrior
        let history = priors[.history] ?? 0
        let undo = priors[.undoCache] ?? 0
        let cache = priors[.cache] ?? 0
        let llm = priors[.llm] ?? 0
        let word = priors[.wordComplete] ?? 0
        let none = priors[.none] ?? 0
        #expect(history > cache)
        #expect(cache > undo)
        #expect(undo > llm)
        #expect(llm > word)
        #expect(word > none)
        #expect(none == 0.0)
    }

    // MARK: - prefixFit (D-06)

    @Test func prefixFitMidWordMatchReturnsOne() {
        // userTail ends with letter ⇒ mid-word ; ghost starts with letter ⇒ 1.0
        let v = SuggestionPolicy.prefixFit(ghost: "r monde", userTail: "Bonjou")
        #expect(v == 1.0)
    }

    @Test func prefixFitMidWordDivergentReturnsZero() {
        // userTail ends with letter ⇒ mid-word ; ghost starts with non-letter ⇒ 0.0
        let v = SuggestionPolicy.prefixFit(ghost: " zyx", userTail: "Bonjou")
        #expect(v == 0.0)
    }

    @Test func prefixFitMidWordApostropheElisionReturnsOne() {
        // Regression: model completes "…corrigé. S" with "'il vous plaît" (S'il).
        // The apostrophe is an intra-word joiner → valid mid-word continuation.
        let v = SuggestionPolicy.prefixFit(ghost: "'il vous plaît", userTail: "…corrigé. S")
        #expect(v == 1.0)
    }

    @Test func prefixFitMidWordHyphenCompoundReturnsOne() {
        // "allez" + "-vous" → hyphen joiner → valid mid-word continuation.
        let v = SuggestionPolicy.prefixFit(ghost: "-vous", userTail: "…allez")
        #expect(v == 1.0)
    }

    @Test func prefixFitMidWordCurlyApostropheReturnsOne() {
        let v = SuggestionPolicy.prefixFit(ghost: "’hui", userTail: "aujourd")
        #expect(v == 1.0)
    }

    @Test func prefixFitMidWordBareSpaceAfterIncompleteWordReturnsZero() {
        // Re-expressed (was prefixFitMidWordBareSpaceStillReturnsZero): a leading
        // space mid-word after an INCOMPLETE / non-word partial ("Bonj") is 0.0 —
        // the model must not abandon a half-typed word. Inject false to pin the
        // "partial is NOT complete" branch deterministically (no spell checker).
        let v = SuggestionPolicy.prefixFit(
            ghost: " mot", userTail: "…Bonj", partialWordIsComplete: { _ in false }
        )
        #expect(v == 0.0)
    }

    @Test func prefixFitMidWordSpaceAfterCompleteWordReturnsOne() {
        // New behaviour: after a COMPLETE word the base model continues with a
        // SPACE-led next word ("…les frais" → " de port"). That is a legitimate
        // next-word completion ⇒ 1.0 when the partial word is valid.
        let v = SuggestionPolicy.prefixFit(
            ghost: " de port", userTail: "…les frais", partialWordIsComplete: { _ in true }
        )
        #expect(v == 1.0)
    }

    @Test func prefixFitMidWordPunctuationAfterCompleteWordReturnsOne() {
        // "…le chocolat" → ", mais il ne peut pas…" — comma-led next-word
        // continuation after a complete word ⇒ 1.0.
        let v = SuggestionPolicy.prefixFit(
            ghost: ", mais", userTail: "…le chocolat", partialWordIsComplete: { _ in true }
        )
        #expect(v == 1.0)
    }

    @Test func prefixFitMidWordSpaceAfterCompleteWordDefaultValidatorReturnsOne() {
        // End-to-end through the DEFAULT spell-checker validator: "frais" is a
        // real French word, so the space-led continuation is accepted.
        let v = SuggestionPolicy.prefixFit(ghost: " de port", userTail: "J'aime aussi les frais")
        #expect(v == 1.0)
    }

    @Test func prefixFitMidWordNewlineStillReturnsZero() {
        // Newline mid-word is rejected even after a complete word (must not break
        // the line). The validator never even gets consulted.
        let v = SuggestionPolicy.prefixFit(
            ghost: "\nmot", userTail: "…chocolat", partialWordIsComplete: { _ in true }
        )
        #expect(v == 0.0)
    }

    @Test func prefixFitMidWordMarkdownStillReturnsZero() {
        // Markdown token mid-word rejected even after a complete word.
        let v = SuggestionPolicy.prefixFit(
            ghost: "* liste", userTail: "…chocolat", partialWordIsComplete: { _ in true }
        )
        #expect(v == 0.0)
    }

    @Test func prefixFitAfterSpaceLetterReturnsOne() {
        let v = SuggestionPolicy.prefixFit(ghost: "monde", userTail: "Bonjour ")
        #expect(v == 1.0)
    }

    @Test func prefixFitAfterSpaceMarkdownReturnsZero() {
        // After space, ghost starts with `*` ⇒ markdown token, refuse.
        let v = SuggestionPolicy.prefixFit(ghost: "* liste", userTail: "Bonjour ")
        #expect(v == 0.0)
    }

    @Test func prefixFitEmptyTailReturnsOne() {
        // Empty user tail behaves like after-space ; letter start ⇒ 1.0.
        let v = SuggestionPolicy.prefixFit(ghost: "Bonjour", userTail: "")
        #expect(v == 1.0)
    }

    // MARK: - lengthFit bell curve (D-06)

    @Test func lengthFitBellCurveByWordCount() {
        // 0 mots
        #expect(SuggestionPolicy.lengthFit(ghost: "") == SuggestionPolicy.Tuning.lengthFitByWordCount[0])
        // 1 mot
        #expect(SuggestionPolicy.lengthFit(ghost: "salut") == SuggestionPolicy.Tuning.lengthFitByWordCount[1])
        // 3 mots — plateau central
        #expect(SuggestionPolicy.lengthFit(ghost: "bonjour le monde") == SuggestionPolicy.Tuning.lengthFitByWordCount[3])
        // 6 mots — bord
        #expect(SuggestionPolicy.lengthFit(ghost: "un deux trois quatre cinq six") == SuggestionPolicy.Tuning.lengthFitByWordCount[6])
        // 9 mots
        let nineWords = "un deux trois quatre cinq six sept huit neuf"
        #expect(SuggestionPolicy.lengthFit(ghost: nineWords) == SuggestionPolicy.Tuning.lengthFitByWordCount[9])
        // 15 mots ⇒ clamp à la dernière entrée
        let fifteenWords = "un deux trois quatre cinq six sept huit neuf dix onze douze treize quatorze quinze"
        let last = SuggestionPolicy.Tuning.lengthFitByWordCount.last ?? 0
        #expect(SuggestionPolicy.lengthFit(ghost: fifteenWords) == last)
    }

    // MARK: - End-to-end score (D-06 composite)

    @Test func scoreEndToEndHistoryAfterSpace() {
        let s = SuggestionPolicy.score(
            source: .history,
            ghost: "continue la phrase",
            userTail: "voici "
        )
        #expect(s.value > SuggestionPolicy.Tuning.gateFloor)
        #expect(s.value > SuggestionPolicy.Tuning.afterSpaceL1Bar)
        // history × afterSpace letter × 3-word plateau ⇒ exactly the product
        // of the same factors stored on the Score (Float precision faithful).
        #expect(s.value == s.sourcePrior * s.prefixFit * s.lengthFit)
        #expect(s.sourcePrior == SuggestionPolicy.Tuning.sourcePrior[.history])
        #expect(s.prefixFit == 1.0)
        #expect(s.lengthFit == SuggestionPolicy.Tuning.lengthFitByWordCount[3])
    }
}
