import Testing
import SouffleuseLlama

/// Phase 3 (a) — suffix array over corpus token-id sequences.
///
/// Tests `LlamaCorpusSuffixArray` directly with synthetic token-id arrays so
/// no model load is required (the structure is pure integer work). Proves
/// variable-length longest-match: a longer matched context yields a sharper
/// (more specific) continuation distribution than a bare last-token match.
@Suite("Phase 3 — corpus suffix array longest-match candidates")
struct CorpusSuffixArrayTests {

    @Test func emptyArrayReturnsNoMatch() {
        let sa = LlamaCorpusSuffixArray()
        let m = sa.longestMatch(after: [1, 2, 3][...])
        #expect(m.candidates.isEmpty)
        #expect(m.matchLength == 0)
    }

    @Test func longestMatchPrefersLongerContext() {
        // Two entries share the bigram (10, 20) but diverge after a longer
        // shared context. A last-token-only model (bigram on 20) would see
        // BOTH 30 and 40 as candidates; the suffix array, matching the full
        // (10,20) context, must disambiguate based on what precedes.
        var sa = LlamaCorpusSuffixArray()
        sa.build(entries: [
            [5, 10, 20, 30],   // ... 10,20 → 30
            [5, 10, 20, 30],   // again → 30 (count 2)
            [7, 10, 20, 40],   // different prefix: ...10,20 → 40
        ])
        #expect(!sa.isEmpty)

        // Context ending in (5,10,20): longest match should pin 30 only.
        let m = sa.longestMatch(after: [5, 10, 20][...])
        #expect(m.matchLength == 3)             // matched all 3 context tokens
        #expect(m.candidates[30] == 2)          // both 30 occurrences
        #expect(m.candidates[40] == nil)        // 40 excluded — different prefix
    }

    @Test func backsOffWhenLongContextHasNoMatch() {
        var sa = LlamaCorpusSuffixArray()
        sa.build(entries: [[1, 2, 3, 99]])
        // Context (777, 2, 3): the full window never occurs, but the suffix
        // (2,3) does → backs off and still finds 99.
        let m = sa.longestMatch(after: [777, 2, 3][...])
        #expect(m.candidates[99] == 1)
        #expect(m.matchLength == 2)             // backed off to (2,3)
    }

    @Test func noMatchAcrossEntryBoundary() {
        var sa = LlamaCorpusSuffixArray()
        // Two separate entries; the last token of entry 1 must NOT predict the
        // first token of entry 2 (sentinel separates them).
        sa.build(entries: [[1, 2], [3, 4]])
        let m = sa.longestMatch(after: [1, 2][...])
        // After 2 comes a sentinel (end of entry) → no continuation.
        #expect(m.candidates.isEmpty)
    }

    @Test func collectsDistributionAtMatchedContext() {
        var sa = LlamaCorpusSuffixArray()
        sa.build(entries: [
            [8, 9, 100],
            [8, 9, 100],
            [8, 9, 200],
        ])
        let m = sa.longestMatch(after: [8, 9][...])
        #expect(m.matchLength == 2)
        #expect(m.candidates[100] == 2)
        #expect(m.candidates[200] == 1)
    }
}

/// Repli COMPTÉ (`longestMatch(after:minCount:)`) — le fix prod du bias beam.
/// Le corpus prod est dédupliqué (`deleteDuplicate`) : le match le plus long
/// est typiquement spécifique à UNE entrée (count 1). Le repli doit reculer
/// jusqu'au plus long contexte dont le meilleur candidat atteint `minCount`,
/// là où la collocation récurrente agrège ses occurrences.
@Suite("Suffix array — repli compté (corpus dédupliqué)")
struct CorpusSuffixArrayCountedBackoffTests {

    /// Trois phrases DISTINCTES partageant la collocation (2,3,4) → 9.
    /// Préfixes différents (1 / 5 / 6) = la forme d'un corpus dédupliqué.
    private func dedupedCorpus() -> LlamaCorpusSuffixArray {
        var sa = LlamaCorpusSuffixArray()
        sa.build(entries: [
            [1, 2, 3, 4, 9, 11],
            [5, 2, 3, 4, 9, 12],
            [6, 7, 2, 3, 4, 9, 13],
        ])
        return sa
    }

    @Test func repliJusquAuContexteAtteste() {
        let sa = dedupedCorpus()
        // Contexte = la sonde : préfixe inédit (8) + collocation (2,3,4).
        // Longest brut = (8,2,3,4) absent → (2,3,4) présent dans LES TROIS
        // entrées → count 3 ≥ minCount 2 : le repli s'arrête là.
        let m = sa.longestMatch(after: [8, 2, 3, 4][...], minCount: 2)
        #expect(m.matchLength == 3)
        #expect(m.candidates[9] == 3)
    }

    @Test func sansRepliLeMatchLongRestaitCount1() {
        let sa = dedupedCorpus()
        // La même sonde mais avec le préfixe d'UNE entrée (1,2,3,4) : le
        // longest-match CLASSIQUE matche 4 tokens → count 1 — la preuve du
        // trou que le repli compté corrige.
        let classic = sa.longestMatch(after: [1, 2, 3, 4][...])
        #expect(classic.matchLength == 4)
        #expect(classic.candidates[9] == 1)
        // Le repli compté recule d'un cran et agrège : count 3.
        let counted = sa.longestMatch(after: [1, 2, 3, 4][...], minCount: 2)
        #expect(counted.matchLength == 3)
        #expect(counted.candidates[9] == 3)
    }

    @Test func rienNAtteintMinCountRendLePlusLongNonVide() {
        var sa = LlamaCorpusSuffixArray()
        sa.build(entries: [[1, 2, 3, 9, 4], [5, 6, 7, 8, 4]])   // aucun candidat ×2
        let m = sa.longestMatch(after: [2, 3, 9][...], minCount: 2)
        // Comportement longestMatch : le plus long non vide, count 1 — les
        // gardes de l'appelant (minBiasCount) trancheront.
        #expect(m.matchLength == 3)
        #expect(m.candidates[4] == 1)
    }

    @Test func corpusVideRendVide() {
        let sa = LlamaCorpusSuffixArray()
        let m = sa.longestMatch(after: [1, 2][...], minCount: 2)
        #expect(m.candidates.isEmpty)
        #expect(m.matchLength == 0)
    }
}
