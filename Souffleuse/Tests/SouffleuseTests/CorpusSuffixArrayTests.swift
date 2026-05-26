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
