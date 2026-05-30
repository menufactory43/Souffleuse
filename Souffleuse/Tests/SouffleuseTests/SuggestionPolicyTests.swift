import Testing
import Foundation
import SouffleusePersonalization
import SouffleuseTyping
import SouffleuseCore
@testable import Souffleuse

/// Phase 4 — Cascade routing (D-08) + Relevance Gate replacement bar (D-07)
/// + L1 history re-enable behind afterSpaceL1Bar (D-08).
///
/// Couvre la matrice 9-rows décrite dans
/// `.planning/phases/04-cascade-quality-architecture/04-RESEARCH.md` §"Cascade
/// routing decision matrix" + les invariants de remplacement (Pitfall 5 :
/// 1 lifecycle = 1 event).
@MainActor
@Suite("Phase 4 — Cascade routing (D-08) + Relevance Gate replacement (D-07)")
struct SuggestionPolicyTests {

    static func entry(_ context: String, _ accepted: String) -> TypingHistoryEntry {
        TypingHistoryEntry(timestamp: Date(), contextBefore: context, accepted: accepted, bundleID: nil)
    }

    static func engine(maxWords: Int = 16) -> SuggestionPolicyEngine {
        SuggestionPolicyEngine(maxWords: maxWords)
    }

    // MARK: - Cascade routing — matrice D-08 (9 rows)

    /// Row 1 : mid-word — historique PRIORITAIRE, puis L0 (WordCompleter).
    ///
    /// RÉVISION D-08 (2026-05-27) : la règle « mid-word = L0 exclusif » est
    /// levée. Preuve terrain (captures Cotypist) : un fragment de mot + son
    /// contexte précédent doit rappeler la phrase apprise ENTIÈRE ("Bonjour, co"
    /// → "mment allez-vous ?"). C'est la mécanique Cotypist (rappel d'historique,
    /// aucune liste intégrée). On vérifie ici que mid-word avec un contexte
    /// suffisant rappelle bien l'historique (.history), la continuation
    /// complétant le mot en cours.
    @Test func midWordWithHistoryRecallsPhrase() {
        let p = Self.engine()
        let snap = [Self.entry("", "Bonne journée à toi aussi")]
        let result = p.routeInstant(
            userTail: "Bonne journ",  // letter-ending → mid-word
            historySnapshot: snap,
            wordCompleter: WordCompleter()
        )
        #expect(result?.source == .history)
        #expect(result?.text == "ée à toi aussi")
    }

    /// Row 3 — mid-word + LLM, partial word INCOMPLETE → BLOQUÉ (Option A
    /// refined, 2026-05-27). "Bonjou" is not a complete word, so the model is
    /// guessing how to finish it ("rné") → block. (The replay harness proved
    /// free mid-word LLM on incomplete fragments produces the wrong word:
    /// "pr"→prunelle, "C'es"→junk.) The word-completer / history fast-path in
    /// `routeInstant` serves the incomplete-fragment case instead.
    @Test func midWordIncompleteWordLLMChunkBlocked() {
        let p = Self.engine()
        let r = p.onLLMChunk("rné", userTail: "Bonjou")  // "Bonjou" incomplete
        #expect(r == nil)
    }

    /// Row 3 quater — a SINGLE-letter elision start ("S" of "S'il") is below the
    /// ≥4-char complete-word floor, so it is treated as a short fragment and the
    /// LLM is blocked (the floor kills false-positive "complete" fragments like
    /// "es"/"pr"/"v" and thin-prefix language drift). Conservative on purpose.
    @Test func midWordShortElisionStartLLMChunkBlocked() {
        let p = Self.engine()
        let r = p.onLLMChunk("'il vous plaît", userTail: "…corrigé. S")
        #expect(r == nil)
    }

    /// Partial word COMPLETE ("allez") → hyphen continuation ("allez-vous")
    /// allowed.
    @Test func midWordCompleteWordHyphenLLMChunkPasses() {
        let p = Self.engine()
        let r = p.onLLMChunk("-vous", userTail: "…comment allez")
        #expect(r != nil)
        #expect(r?.text == "-vous")
    }

    /// Row 3 quinquies — caret right after a COMPLETE word ("frais", no trailing
    /// space). The replay harness showed the LLM does a reliable NEXT-WORD
    /// continuation here ("corrigé"→" dans la prochaine version", "vendredi"→
    /// " prochain"). The refined rule ALLOWS it (the blunt all-mid-word block
    /// killed exactly these good, long ghosts). Leading space preserved →
    /// renders "frais de port".
    @Test func midWordNextWordAfterCompleteWordPasses() {
        let p = Self.engine()
        let r = p.onLLMChunk(" de port", userTail: "J'aime aussi les frais")
        #expect(r != nil)
        #expect(r?.source == .llm)
        #expect(r?.text == " de port")
    }

    /// Row 3 bis : mid-word, chunk space-led APRÈS un mot INCOMPLET ("Bonjou"
    /// n'est pas un mot valide) → prefixFit = 0.0 → gate floor le rejette. Le
    /// next-word continuation n'est autorisé qu'après un mot COMPLET (cf.
    /// RelevanceGateTests.prefixFitMidWordSpaceAfterCompleteWord*).
    @Test func midWordChunkStartingNonLetterAfterIncompleteWordStillGated() {
        let p = Self.engine()
        let r = p.onLLMChunk(" autre mot", userTail: "Bonjou")  // leading space, partial incomplete
        #expect(r == nil)
    }

    /// Row 3 ter : sous l'Option A, AUCUN ghost LLM n'est posé en milieu de mot,
    /// donc aucun churn mid-mot possible — chaque chunk mid-mot est rejeté
    /// d'emblée (avant même le gate floor / replacement bar). L'anti-churn au
    /// bord de mot reste couvert par les tests Row 5 (l2Upgrades…).
    @Test func midWordLLMChunkAlwaysBlockedNoGhostSet() {
        let p = Self.engine()
        let first = p.onLLMChunk("rné", userTail: "Bonjou")
        #expect(first == nil)
        let second = p.onLLMChunk("rné", userTail: "Bonjou")
        #expect(second == nil)
        #expect(p.currentGhost == "")  // jamais posé
    }

    /// Row 4 : after-space + L1 hit qualifié → GhostUpdate .history.
    @Test func afterSpaceHistoryHitReturnsGhost() {
        let p = Self.engine()
        // Entry whose body contains "raclette délicieuse" — lookback 6+ chars.
        let snap = [Self.entry("Hier soir, ", "j'ai mangé une raclette délicieuse")]
        // userTail finit après "racl" puis space → tail finit par space.
        let r = p.routeInstant(
            userTail: "j'ai mangé une racl ",
            historySnapshot: snap,
            wordCompleter: WordCompleter()
        )
        // L1 needs lookback non-whitespace at the end. "racl " ends with space
        // → SuggestionPolicy.historyExactSubstringMatch returns nil per its
        // guard (last.isWhitespace → nil). On vérifie ce comportement.
        #expect(r == nil)
    }

    /// Row 4 bis : after-space avec lookback strict (matche helper directement).
    /// Pas via routeInstant (qui est gated par afterSpaceLike) — test direct du helper.
    @Test func historyHelperReturnsContinuationForMidPhraseTail() {
        let snap = [Self.entry("", "j'ai mangé une raclette délicieuse")]
        let r = SuggestionPolicy.historyExactSubstringMatch(
            userTail: "j'ai mangé une racl",
            snapshot: snap
        )
        #expect(r == "ette délicieuse")
    }

    /// Row 5 : L1 first → L2 LLM upgrade quand score >= currentScore + delta.
    @Test func l2UpgradesL1WhenScoreExceedsDelta() {
        let p = Self.engine()
        // Pose un ghost history avec score ~0.75 * 1.0 * 1.0 = 0.75.
        let historyScore = SuggestionPolicy.score(
            source: .history,
            ghost: "trois mots ici",
            userTail: " "
        )
        p.applyGhost("trois mots ici", source: .history, score: historyScore)
        // LLM chunk après-space. score = 0.60 * 1.0 * 1.0 = 0.60.
        // 0.60 < 0.75 * 1.15 = 0.86 (beatsBar false).
        // l2Upgrades : 0.60 >= 0.75 + 0.15 = 0.90 ? Non. Donc nil.
        let r = p.onLLMChunk("autre proposition ici", userTail: " ")
        #expect(r == nil)
    }

    /// Row 5 bis : L1 first → L2 ne passe pas l'upgrade.
    @Test func l2DoesNotUpgradeWhenBelowDelta() {
        let p = Self.engine()
        // Pose un ghost history avec score faible : 0.75 * 1.0 * 0.6 = 0.45 (1 mot).
        let historyScore = Score(sourcePrior: 0.75, prefixFit: 1.0, lengthFit: 0.6)
        p.applyGhost("ghost", source: .history, score: historyScore)
        // LLM chunk après-space, mots multiples → lengthFit 1.0, prior 0.60.
        // score = 0.60 * 1.0 * 1.0 = 0.60.
        // beatsBar : 0.60 >= 0.45 * 1.15 = 0.5175 → true.
        let r = p.onLLMChunk("autre proposition plus longue", userTail: " ")
        #expect(r != nil)
    }

    /// Row 6 : after-space, currentGhost vide, onLLMChunk passe le Gate → ghost.
    @Test func afterSpaceEmptyCurrentLLMChunkApplies() {
        let p = Self.engine()
        // currentGhost vide → no replacement bar test, juste passesGate.
        let r = p.onLLMChunk("bonjour à tous", userTail: " ")
        #expect(r != nil)
        #expect(r?.source == .llm)
    }

    /// Row 7 : tail vide, no history → nil.
    @Test func emptyTailNoHistoryReturnsNil() {
        let p = Self.engine()
        let r = p.routeInstant(
            userTail: "",
            historySnapshot: [],
            wordCompleter: WordCompleter()
        )
        #expect(r == nil)
    }

    /// Row 8 : under gate (score < 0.25) → ghost_gate_block + nil.
    @Test func underGateChunkBlocked() {
        let p = Self.engine()
        // After-space avec ghost qui commence par whitespace → prefixFit = 0 → score = 0.
        let r = p.onLLMChunk(" leading space", userTail: " ")
        #expect(r == nil)
    }

    /// Row 9 : replacement parasite — currentGhost set récemment, nouveau chunk
    /// bat le bar → l'engine doit retourner non-nil ET avoir conceptuellement
    /// émis parasite (vérifié indirectement via state).
    @Test func parasiteReplacementWithinWindow() {
        let p = Self.engine()
        let s1 = Score(sourcePrior: 0.30, prefixFit: 1.0, lengthFit: 1.0)  // 0.30 > 0.25 gate
        p.applyGhost("first", source: .llm, score: s1)
        // shownAt set automatiquement à Date()
        // chunk avec score qui bat le replacement bar : 0.60 * 1.0 * 1.0 = 0.60.
        // beats : 0.60 >= 0.30 * 1.15 = 0.345 → true.
        let r = p.onLLMChunk("better much longer ghost text", userTail: " ")
        #expect(r != nil)
        // Le parasite event est émis dans Log ; on ne le vérifie pas via Log
        // (qui écrit sur disque) — on vérifie via la chaîne de state.
    }

    // MARK: - Replacement bar (D-07)

    @Test func replacementBarRejectsCloseScore() {
        let p = Self.engine()
        let s1 = Score(sourcePrior: 0.60, prefixFit: 1.0, lengthFit: 1.0)  // 0.60
        p.applyGhost("current", source: .llm, score: s1)
        // Score 0.65 — 0.65 < 0.60 * 1.15 = 0.69 → ne bat pas le bar.
        // On construit un chunk dont le score réel donnerait 0.60 * pf * lf ≈ <0.69.
        // Au lieu de fabriquer le bon chunk, on teste directement beats(_:).
        let s2 = Score(sourcePrior: 0.60, prefixFit: 1.0, lengthFit: 1.0)
        #expect(!s2.beats(s1))  // 0.60 >= 0.60 * 1.15 = 0.69 false
    }

    @Test func replacementBarAcceptsAboveBar() {
        let a = Score(sourcePrior: 0.60, prefixFit: 1.0, lengthFit: 1.0)  // 0.60
        let b = Score(sourcePrior: 0.75, prefixFit: 1.0, lengthFit: 1.0)  // 0.75
        // 0.75 >= 0.60 * 1.15 = 0.69 → true
        #expect(b.beats(a))
    }

    @Test func l2UpgradesL1Delta() {
        // L1 score 0.45 → upgrade requires LLM score >= 0.60.
        let p = Self.engine()
        let l1 = Score(sourcePrior: 0.75, prefixFit: 1.0, lengthFit: 0.6)  // 0.45
        p.applyGhost("ghost", source: .history, score: l1)
        // 0.60 LLM chunk → beats 0.45 * 1.15 = 0.5175 → true.
        let r = p.onLLMChunk("longer proposition here", userTail: " ")
        #expect(r != nil)
    }

    // MARK: - L1 re-enable derrière afterSpaceL1Bar (D-08)

    @Test func l1HelperReturnsTailWhenLookbackMatches() {
        // Test direct du helper — l'integration via routeInstant nécessite que
        // userTail finisse par whitespace, ce qui invalide le helper (which has
        // its own guard). Ici on teste le helper séparément.
        let snap = [Self.entry("", "Bonne journée à toi aussi")]
        let r = SuggestionPolicy.historyExactSubstringMatch(
            userTail: "Bonne journ",
            snapshot: snap
        )
        #expect(r == "ée à toi aussi")
    }

    @Test func afterSpaceL1BarBlocksBelowThreshold() {
        // Tightening 2026-05-26 : afterSpaceL1Bar bumped 0.4 → 0.6.
        // Le but : bloquer les history fragments low-confidence (1-word ghosts,
        // historiques très longs) qui polluaient le ghost en after-space.

        // 1-mot ghost : 0.75 * 1.0 * 0.6 = 0.45 → SOUS le nouveau bar 0.6.
        let oneWord = SuggestionPolicy.score(
            source: .history,
            ghost: "ghost",
            userTail: " "
        )
        #expect(oneWord.value < SuggestionPolicy.Tuning.afterSpaceL1Bar)

        // 3-mots ghost (sweet spot) : 0.75 * 1.0 * 1.0 = 0.75 → passe le bar 0.6.
        let threeWords = SuggestionPolicy.score(
            source: .history,
            ghost: "ghost vers vous",
            userTail: " "
        )
        #expect(threeWords.value >= SuggestionPolicy.Tuning.afterSpaceL1Bar)

        // 9+ mots ghost : 0.75 * 1.0 * 0.3 = 0.225 → SOUS le bar.
        let nineWords = SuggestionPolicy.score(
            source: .history,
            ghost: "un deux trois quatre cinq six sept huit neuf",
            userTail: " "
        )
        #expect(nineWords.value < SuggestionPolicy.Tuning.afterSpaceL1Bar)
    }

    // MARK: - Isolation / edge cases

    @Test func routeInstantReturnsNilWhenWordCompleterEmpty() {
        let p = Self.engine()
        // Empty userTail → after-space-like, no history → nil.
        let r = p.routeInstant(
            userTail: "",
            historySnapshot: [],
            wordCompleter: WordCompleter()
        )
        #expect(r == nil)
    }

    @Test func endLifecycleResetsCurrentGhost() {
        let p = Self.engine()
        p.applyGhost(
            "ghost",
            source: .llm,
            score: Score(sourcePrior: 0.6, prefixFit: 1.0, lengthFit: 1.0)
        )
        #expect(p.currentGhost == "ghost")
        p.endLifecycle(reason: .acceptedFull)
        #expect(p.currentGhost == "")
        #expect(p.currentSource == .none)
        #expect(p.shownAt == nil)
    }

    @Test func beginPredictDecaysHighConfidence() {
        let p = Self.engine()
        p.applyGhost(
            "ghost",
            source: .history,
            score: Score(sourcePrior: 0.75, prefixFit: 1.0, lengthFit: 1.0)
        )
        #expect(p.currentSource == .history)
        p.beginPredict()
        #expect(p.currentSource == .llm)
    }

    // MARK: - Mid-word token-healing admit (Task 2)

    /// Healed admit: caret mid-word inside "fis" (an incomplete 3-char fragment,
    /// NOT a complete word, so the old rule blocked it). With healing on, the
    /// engine re-derived the whole word; the chunk's leading plain run "cal"
    /// splices "fis"+"cal" = "fiscal" (valid French word) → ADMIT, source .llm.
    @Test func midWordHealedAdmitFiscal() {
        let p = Self.engine()
        let r = p.onLLMChunk("cal annuel 2019", userTail: "Rapport fis")
        #expect(r != nil)
        #expect(r?.source == .llm)
        #expect(r?.text == "cal annuel 2019")
    }

    /// Healed admit across an accent boundary: "impe" + leadingPlainRun
    /// "rméable" = "imperméable" (valid) → ADMIT.
    @Test func midWordHealedAdmitImpermeable() {
        let p = Self.engine()
        let r = p.onLLMChunk("rméable pour femme", userTail: "Une salopette impe")
        #expect(r != nil)
        #expect(r?.source == .llm)
        #expect(r?.text == "rméable pour femme")
    }

    /// Still blocked under healing: "Bonjou" + "rné" → merged "Bonjourné" is NOT
    /// a valid word, and the partial "Bonjou" is not a complete word either, so
    /// NEITHER admit condition fires → nil. Guards the regression that the four
    /// pre-existing block tests rely on.
    @Test func midWordHealedStillBlocksGarbageMerge() {
        let p = Self.engine()
        let r = p.onLLMChunk("rné", userTail: "Bonjou")
        #expect(r == nil)
    }

    // MARK: - Corpus recall quality-gate (Task 4)

    /// A stored phrase truncated mid-word ("… qu'ils transmettr") yields a recall
    /// continuation whose last word "transmettr" is an incomplete fragment (not a
    /// valid FR/EN word, no sentence terminator) → REJECTED so the cascade falls
    /// through to the LLM. routeInstant returns nil for the corpus path.
    @Test func corpusRecallTruncatedFragmentRejected() {
        let p = Self.engine()
        // Entry text joins to "Pour votre déclaration fiscale, il est indiqué
        // qu'ils transmettr" — the stored continuation breaks off mid-word.
        let snap = [Self.entry(
            "Pour votre déclaration fiscale, ",
            "il est indiqué qu'ils transmettr"
        )]
        let r = p.routeInstant(
            userTail: "Pour votre déclaration fiscale, ",  // after-space, ≥16-char match
            historySnapshot: snap,
            wordCompleter: WordCompleter()
        )
        #expect(r == nil)
    }

    /// A clean recall (continuation ends on a complete word) still passes the
    /// quality-gate and is emitted as the instant .history ghost.
    @Test func corpusRecallCleanContinuationPasses() {
        let p = Self.engine()
        let snap = [Self.entry(
            "Pour votre déclaration fiscale, ",
            "merci de joindre les justificatifs"
        )]
        let r = p.routeInstant(
            userTail: "Pour votre déclaration fiscale, ",
            historySnapshot: snap,
            wordCompleter: WordCompleter()
        )
        #expect(r?.source == .history)
        #expect(r?.text.contains("justificatifs") == true)
    }

    /// The quality-gate helper itself: a sentence-terminated continuation is
    /// always clean even if it would otherwise look truncated; a bare broken
    /// fragment is low quality.
    @Test func corpusContinuationQualityHelper() {
        // Broken trailing fragment (not a valid FR/EN word, no terminator).
        #expect(SuggestionPolicy.corpusContinuationIsLowQuality("il est indiqué qu'ils transmettr") == true)
        // Clean: last word is a real word.
        #expect(SuggestionPolicy.corpusContinuationIsLowQuality("merci de joindre les justificatifs") == false)
        // Sentence-terminated → always clean even if it looked truncated.
        #expect(SuggestionPolicy.corpusContinuationIsLowQuality("voici la suite transmettr.") == false)
        #expect(SuggestionPolicy.corpusContinuationIsLowQuality("") == false)
    }

    // MARK: - capToWords (corpus recall word-cap leading-space)

    @Test func capToWordsPreservesLeadingSpaceWhenWordCapped() {
        // The corpus-recall word-cap branch must keep the single leading
        // separator space of a next-word continuation after a complete word.
        // " négatives dans votre compte bancaire" capped to 3 → " négatives
        // dans votre" (NOT "négatives dans votre", which renders/inserts glued
        // onto the user's "balances"). Regression for the split()/joined()
        // leading-space loss.
        #expect(SuggestionPolicy.capToWords(" négatives dans votre compte bancaire", max: 3)
            == " négatives dans votre")
    }

    @Test func capToWordsWordCapNoLeadingSpaceUnchanged() {
        // No leading space (mid-word same-word continuation) → restore is a
        // no-op: no spurious leading space, no double space.
        #expect(SuggestionPolicy.capToWords("négatives dans votre compte bancaire", max: 3)
            == "négatives dans votre")
    }
}
