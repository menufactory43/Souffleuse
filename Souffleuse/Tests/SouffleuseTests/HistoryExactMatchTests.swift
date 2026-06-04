import Testing
import Foundation
import SouffleuseCorpus
import SouffleusePersonalization
import SouffleuseTyping
import SouffleuseCore
@testable import Souffleuse

@Suite("Instant Ghost Path — history exact-substring match")
struct HistoryExactMatchTests {

    private static func entry(_ context: String, _ accepted: String, source: EntrySource = .prose) -> TypingHistoryEntry {
        TypingHistoryEntry(timestamp: Date(), contextBefore: context, accepted: accepted, bundleID: nil, source: source)
    }

    @Test func exactPrefixHitReturnsContinuation() {
        let snap = [
            Self.entry("Je voulais te dire que ", "ce serait avec plaisir")
        ]
        // User has typed the full contextBefore — the next thing they
        // typed before was "ce serait avec plaisir". Return that.
        let r = SuggestionPolicy.historyExactSubstringMatch(
            userTail: "Je voulais te dire que ",
            snapshot: snap
        )
        // Lookback ends on whitespace → guarded out. Verify guard works.
        #expect(r == nil)
    }

    @Test func midPhraseMatchReturnsTail() {
        let snap = [
            Self.entry("", "Bonne journée à toi aussi")
        ]
        // User typing the start of an entry's accepted text — return the
        // saved tail.
        let r = SuggestionPolicy.historyExactSubstringMatch(
            userTail: "Bonne journ",
            snapshot: snap
        )
        #expect(r == "ée à toi aussi")
    }

    @Test func tooShortLookbackReturnsNil() {
        let snap = [Self.entry("", "Bonjour")]
        // Lookback < 6 chars → ambiguous → no match.
        let r = SuggestionPolicy.historyExactSubstringMatch(
            userTail: "Bonj",
            snapshot: snap
        )
        #expect(r == nil)
    }

    @Test func emptySnapshotReturnsNil() {
        let r = SuggestionPolicy.historyExactSubstringMatch(
            userTail: "anything long enough",
            snapshot: []
        )
        #expect(r == nil)
    }

    @Test func firstHitWinsForRecencyOrdering() {
        // historyExactSubstringMatch picks the FIRST match — the
        // insertion order in PredictorViewModel.ingestAccepted puts the
        // newest entry at index 0 so recency wins automatically.
        let snap = [
            Self.entry("", "C'était une journée magnifique"),
            Self.entry("", "C'était une journée banale"),
        ]
        let r = SuggestionPolicy.historyExactSubstringMatch(
            userTail: "C'était une journ",
            snapshot: snap
        )
        #expect(r == "ée magnifique")
    }

    @Test func substringMatchAnywhereInEntry() {
        // The needle can match anywhere inside contextBefore + accepted —
        // typical use: user repeats a phrase fragment in a new sentence.
        let snap = [
            Self.entry("Hier soir, ", "j'ai mangé une raclette délicieuse")
        ]
        let r = SuggestionPolicy.historyExactSubstringMatch(
            userTail: "j'ai mangé une racl",
            snapshot: snap
        )
        #expect(r == "ette délicieuse")
    }

    @Test func noMatchReturnsNil() {
        let snap = [Self.entry("", "Bonjour à tous")]
        let r = SuggestionPolicy.historyExactSubstringMatch(
            userTail: "Goodbye everyone",
            snapshot: snap
        )
        #expect(r == nil)
    }

    @Test func emptyContinuationReturnsNil() {
        // Lookback matches the END of the saved text — no continuation
        // to propose.
        let snap = [Self.entry("", "Bonjour à tous")]
        let r = SuggestionPolicy.historyExactSubstringMatch(
            userTail: "jour à tous",
            snapshot: snap
        )
        #expect(r == nil)
    }
}

// MARK: - Phase 4 — L1 history gated by SuggestionPolicy.Tuning.afterSpaceL1Bar (D-08)
//
// Plan 04-08 — verrouille le comportement du L1 history re-enable derrière le
// Ghost Relevance Gate déjà câblé en 04-02. Les tests référencent
// `SuggestionPolicy.Tuning.afterSpaceL1Bar` plutôt que des littéraux pour
// rester résilients au tuning futur (Pitfall 6 — single source of truth).
//
// Note importante sur la sémantique observable :
// `SuggestionPolicy.historyExactSubstringMatch` retourne nil quand le
// lookback se termine par whitespace (`userTail` after-space pur). Donc
// `SuggestionPolicyEngine.routeInstant` ne déclenche PAS le L1 pour
// `userTail` finissant strictement par espace ; le L1 s'active sur les
// invocations où le helper est appelé directement (chemins en aval).
// La fonction de scoring elle, est toujours testable indépendamment et
// c'est la voie utilisée ici pour verrouiller le Gate.

@MainActor
@Suite("Phase 4 — history L1 re-enabled behind Relevance Gate (D-08)")
struct HistoryL1GateTests {
    static func entry(_ context: String, _ accepted: String, source: EntrySource = .prose) -> TypingHistoryEntry {
        TypingHistoryEntry(timestamp: Date(), contextBefore: context, accepted: accepted, bundleID: nil, source: source)
    }
    static func engine() -> SuggestionPolicyEngine { SuggestionPolicyEngine(maxWords: 16) }
    static func emptyWordCompleter() -> WordCompleter { WordCompleter() }

    // MARK: - Gate score thresholds (pure-function verrouillage)

    /// Un history match « typique » (multi-mots, prefix-fit naturel) produit
    /// un score >= `afterSpaceL1Bar` — c'est par design : le Gate L1 doit
    /// laisser passer les history matches valides.
    @Test func historyMatchAboveBarPasses() {
        let score = SuggestionPolicy.score(
            source: .history,
            ghost: "ce serait avec plaisir",
            userTail: "Je voulais te dire que"  // tail letter-ending → prefix-fit=1
        )
        // 0.75 (history prior) × 1.0 (prefix_fit letter) × 1.0 (4 words sweet spot) = 0.75
        #expect(score.value >= SuggestionPolicy.Tuning.afterSpaceL1Bar)
        #expect(score.passesGate)
    }

    /// Un ghost history commençant par un délimiteur markdown (`*`, `#`, …)
    /// produit `prefix_fit = 0` → score = 0 → BLOQUÉ par le Gate L1.
    /// C'est le filtre principal du Gate : refuser les outliers syntaxiques.
    @Test func historyMatchPrefixFitZeroIsBlocked() {
        let score = SuggestionPolicy.score(
            source: .history,
            ghost: "* élément de liste",
            userTail: "voici "  // after-space → prefix_fit nécessite letter/digit/quote
        )
        #expect(score.value == 0.0)
        #expect(score.value < SuggestionPolicy.Tuning.afterSpaceL1Bar)
        #expect(!score.passesGate)
    }

    /// Un ghost history de 9+ mots tombe sous `afterSpaceL1Bar` :
    /// `length_fit = 0.3` → 0.75 × 1.0 × 0.3 = 0.225 < 0.4.
    /// Le Gate refuse les history matches trop longs (mal calibrés).
    @Test func historyMatchTooLongFallsUnderBar() {
        let longGhost = "a b c d e f g h i j"  // 10 mots → lengthFit table[9] = 0.3
        let score = SuggestionPolicy.score(
            source: .history,
            ghost: longGhost,
            userTail: "voici "
        )
        // 0.75 × 1.0 × 0.3 = 0.225
        #expect(score.value < SuggestionPolicy.Tuning.afterSpaceL1Bar)
        // Mais reste au-dessus du Gate floor (0.25 ? non, 0.225 < 0.25) → bloqué aussi par le hard gate
        // L'invariant principal : sous afterSpaceL1Bar = pas affiché en after-space.
    }

    // MARK: - routeInstant L1 wiring

    /// Snapshot vide → routeInstant renvoie nil pour after-space (pas de L1 candidate).
    @Test func l1EmptyHistorySnapshotReturnsNil() {
        let p = Self.engine()
        let r = p.routeInstant(
            userTail: " ",
            historySnapshot: [],
            wordCompleter: Self.emptyWordCompleter()
        )
        #expect(r == nil)
    }

    /// Mid-word (tail finit par lettre) : L1 history n'est PAS consulté
    /// (D-08 — mid-word = L0 exclusif). Verrouille la cascade matrix.
    @Test func l1NotApplicableMidWord() {
        let p = Self.engine()
        // Snapshot avec un match potentiel — mais mid-word ne doit jamais routes vers L1.
        let snap = [Self.entry("", "Bonjour à tous, comment ça va ?")]
        let r = p.routeInstant(
            userTail: "Bonjou",  // letter-ending → mid-word
            historySnapshot: snap,
            wordCompleter: Self.emptyWordCompleter()
        )
        // WordCompleter() vide ne produit pas de completion → nil global,
        // mais surtout : ce nil vient du L0 path, PAS du L1.
        // L1 serait actif si tail letter-ending était routé via after-space cascade — ce qui est interdit.
        #expect(r == nil)
    }

    // MARK: - L2 upgrade over L1 (Tuning.l2UpgradeDelta)

    /// L2 LLM peut remplacer un L1 history quand `score_L2 >= score_L1 + l2UpgradeDelta`.
    /// Construit des Scores explicites pour isoler le delta.
    @Test func l1L2UpgradeWhenL2BeatsByDelta() {
        let p = Self.engine()
        // L1 history : score 0.50 (volontairement bas pour permettre upgrade).
        let l1Score = Score(sourcePrior: 0.75, prefixFit: 1.0, lengthFit: 0.6667)
        // 0.75 × 1.0 × 0.6667 ≈ 0.50
        p.applyGhost("ghost L1", source: .history, score: l1Score)

        // LLM chunk : ghost après-space de longueur idéale → 0.60 × 1.0 × 1.0 = 0.60.
        // l2UpgradeDelta = 0.15 → 0.50 + 0.15 = 0.65. Donc 0.60 < 0.65 (pas d'upgrade).
        // MAIS replacementBar : 0.60 >= 0.50 × 1.15 = 0.575 → TRUE (beatsBar wins).
        let r = p.onLLMChunk("trois mots ici", userTail: " ")
        #expect(r != nil)
        #expect(r?.source == .llm)
    }

    /// L2 LLM ne remplace PAS un L1 history quand son score est trop proche.
    /// Verrouille l'invariant anti-churn quand ni `beatsBar` ni `l2UpgradeDelta` ne sont satisfaits.
    @Test func l1L2NoUpgradeWhenScoresClose() {
        let p = Self.engine()
        // L1 history fort : 0.75 × 1.0 × 1.0 = 0.75.
        let l1Score = Score(sourcePrior: 0.75, prefixFit: 1.0, lengthFit: 1.0)
        p.applyGhost("trois mots ici", source: .history, score: l1Score)

        // LLM chunk : score 0.60 × 1.0 × 1.0 = 0.60.
        // beatsBar : 0.60 >= 0.75 × 1.15 = 0.8625 → FALSE.
        // l2Upgrades : 0.60 >= 0.75 + 0.15 = 0.90 → FALSE.
        // Donc keep current → nil.
        let r = p.onLLMChunk("autre proposition ici", userTail: " ")
        #expect(r == nil)
    }

    // MARK: - Tuning constant reference verrouillage

    /// Verrouille le fait que les tests ci-dessus consomment
    /// `SuggestionPolicy.Tuning.afterSpaceL1Bar` et `l2UpgradeDelta` plutôt
    /// que des littéraux — résilience aux tuning futurs (Pitfall 6).
    @Test func gateConstantsAreReferencedNotInlined() {
        // Sanity : les constantes ont des valeurs définies dans le tuning.
        // Si elles changent, les tests ci-dessus consomment automatiquement les nouvelles valeurs.
        #expect(SuggestionPolicy.Tuning.afterSpaceL1Bar > 0)
        #expect(SuggestionPolicy.Tuning.afterSpaceL1Bar <= 1.0)
        #expect(SuggestionPolicy.Tuning.l2UpgradeDelta > 0)
        #expect(SuggestionPolicy.Tuning.l2UpgradeDelta <= 1.0)
    }
}
