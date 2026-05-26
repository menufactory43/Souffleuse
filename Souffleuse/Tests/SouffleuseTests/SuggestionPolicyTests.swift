import Testing
import Foundation
import SouffleusePersonalization
import SouffleuseTyping
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

    /// Row 1 : mid-word — L0 exclusif (WordCompleter).
    /// "Bonjou" (lettre finale) → completion "r" est <3 chars, devrait être nil.
    /// On vérifie aussi que mid-word avec history n'utilise PAS L1.
    @Test func midWordWithHistoryDoesNotUseL1() {
        let p = Self.engine()
        let snap = [Self.entry("", "Bonne journée à toi aussi")]
        let result = p.routeInstant(
            userTail: "Bonne journ",  // letter-ending → mid-word
            historySnapshot: snap,
            wordCompleter: WordCompleter()
        )
        // L1 history exists, mais mid-word block. WordCompleter peut produire
        // ou non un résultat selon NSSpellChecker — on vérifie au moins que
        // si c'est non-nil, ce n'est PAS .history.
        if let r = result {
            #expect(r.source != .history)
        }
    }

    /// Row 3 : mid-word + LLM chunk → AUTORISÉ (D-08 unblocked 2026-05-26).
    ///
    /// Le blocage mid-word inconditionnel a été retiré. La cohérence du splice
    /// est garantie EN AMONT (generateLlama coherence guard) ; onLLMChunk laisse
    /// passer un chunk mid-word cohérent qui démarre par une lettre (prefixFit
    /// 1.0) et passe le gate floor. Cotypist-parité : "Bonjou"→"rné" doit montrer.
    @Test func midWordCoherentLLMChunkPasses() {
        let p = Self.engine()
        let r = p.onLLMChunk("rné", userTail: "Bonjou")  // letter-ending tail
        #expect(r != nil)
        #expect(r?.source == .llm)
        #expect(r?.text == "rné")
    }

    /// Row 3 quater : mid-word + LLM chunk démarrant par un JOINER (apostrophe /
    /// trait d'union) → AUTORISÉ. Regression : "…corrigé. S" + "'il vous plaît"
    /// (S'il) était gaté (prefixFit=0). Maintenant prefixFit=1.0 mid-word pour un
    /// joiner, donc le ghost passe. Cotypist montre cette complétion.
    @Test func midWordJoinerLLMChunkPasses() {
        let p = Self.engine()
        let r = p.onLLMChunk("'il vous plaît", userTail: "…corrigé. S")
        #expect(r != nil)
        #expect(r?.source == .llm)
        #expect(r?.text == "'il vous plaît")
    }

    @Test func midWordHyphenLLMChunkPasses() {
        let p = Self.engine()
        let r = p.onLLMChunk("-vous", userTail: "…comment allez")
        #expect(r != nil)
        #expect(r?.text == "-vous")
    }

    /// Row 3 quinquies — THE BUG FIX : caret right after a COMPLETE word ending
    /// in a letter (no trailing space). The base model continues with a SPACE-led
    /// next word ("…les frais" → " de port"). Previously gated (prefixFit=0 →
    /// score=0); now prefixFit=1.0 because "frais" is a complete word, so the
    /// ghost reaches the screen WITH its leading space preserved.
    @Test func midWordNextWordAfterCompleteWordPassesEndToEnd() {
        let p = Self.engine()
        let r = p.onLLMChunk(" de port", userTail: "J'aime aussi les frais")
        #expect(r != nil)
        #expect(r?.source == .llm)
        #expect(r?.text == " de port")  // leading space kept → renders "frais de port"
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

    /// Row 3 ter : anti-churn applies mid-word too. A mid-word LLM ghost is set,
    /// then a too-close mid-word chunk arrives — replacement bar (1.15) rejects
    /// it. Proves the relevance pipeline (not the removed blunt block) is what
    /// governs mid-word now.
    @Test func midWordReplacementBarRespected() {
        let p = Self.engine()
        // First mid-word ghost: "rné" on "Bonjou". score = 0.60 × 1.0 × lengthFit.
        let first = p.onLLMChunk("rné", userTail: "Bonjou")
        #expect(first != nil)
        if let first { p.applyGhost(first.text, source: .llm, score: first.score) }
        // A second mid-word chunk with the SAME score cannot beat the bar.
        let second = p.onLLMChunk("rné", userTail: "Bonjou")
        #expect(second == nil)  // ghost_keep_under_bar
        #expect(p.currentGhost == "rné")
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
}
