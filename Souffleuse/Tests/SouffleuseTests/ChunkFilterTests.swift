import Testing
import SouffleuseCore

/// Gen-time stop-at-sentence — the `sentenceComplete` flag that
/// `ChunkFilter.filterChunk` returns and `ModelRuntime` / `SouffleuseReplay`
/// use to STOP decoding once the ghost has been truncated at a sentence
/// terminator.
///
/// This is a LATENCY optimization, NOT a relevance change: the displayed ghost
/// is already cut at the terminator by the SAME truncation, so stopping only
/// avoids decoding tokens that would be discarded. `sentenceComplete` is `true`
/// exactly when the `. `/`? `/`! `/`… ` cut fired. Clause boundaries (commas)
/// must NEVER set it, so a wanted second clause keeps generating.
@Suite("ChunkFilter — sentenceComplete (gen-time stop-at-sentence)")
struct ChunkFilterTests {

    @Test func sentenceCompleteOnTerminatorCut() {
        // "Bonjour. Comment …" → cut to "Bonjour." with discarded content after
        // a completed sentence → stop.
        let r = ChunkFilter.filterChunk(
            accumulated: "Bonjour. Comment ça va aujourd'hui",
            userTail: "", caretAfterSpace: false, maxWords: 20)
        #expect(r.verdict == .emit("Bonjour."))
        #expect(r.sentenceComplete == true)
    }

    @Test func sentenceCompletePreservesLeadingSpace() {
        // Next-word continuation after a complete word keeps its leading space
        // ("frais de port." not "fraisde port.") AND still flags the terminator.
        let r = ChunkFilter.filterChunk(
            accumulated: " de port. Mais il",
            userTail: "", caretAfterSpace: false, maxWords: 20)
        #expect(r.verdict == .emit(" de port."))
        #expect(r.sentenceComplete == true)
    }

    @Test func commaClauseDoesNotComplete() {
        // A comma is a CLAUSE boundary, not a sentence end → keep generating so a
        // wanted 2nd clause survives. This is the "2nd clause not cut" guarantee.
        let r = ChunkFilter.filterChunk(
            accumulated: "Bonjour cher ami, comment ça va",
            userTail: "", caretAfterSpace: false, maxWords: 20)
        guard case .emit = r.verdict else { Issue.record("expected .emit"); return }
        #expect(r.sentenceComplete == false)
    }

    @Test func noTerminatorDoesNotComplete() {
        let r = ChunkFilter.filterChunk(
            accumulated: "Bonjour cher ami comment",
            userTail: "", caretAfterSpace: false, maxWords: 20)
        #expect(r.sentenceComplete == false)
    }

    @Test func midWordFragmentDoesNotComplete() {
        // Mid-word recall fragment, no terminator yet → never stops early.
        let r = ChunkFilter.filterChunk(
            accumulated: "cal annuel 2019",
            userTail: "Rapport fis", caretAfterSpace: false, maxWords: 20)
        #expect(r.sentenceComplete == false)
    }
}

/// Fragmented-garbage detection — the pt base model derails into isolated
/// single letters (" f i", "F or", " A p", "ferme r"). These reached the
/// overlay (live trace 2026-05-29); `isFragmentedGhost` (via `isDegenerateGhost`)
/// drops them. Vowel-led tokens and normal prose must survive.
@Suite("OutputFilter — fragmented garbage (isolated single consonants)")
struct FragmentedGhostTests {

    @Test func flagsLiveGarbageFragments() {
        // Exact cases observed at the caret.
        #expect(OutputFilter.isFragmentedGhost(" f i"))
        #expect(OutputFilter.isFragmentedGhost("F or"))
        #expect(OutputFilter.isFragmentedGhost(" A p"))
        #expect(OutputFilter.isFragmentedGhost("ferme r"))
        // …and therefore degenerate (dropped, keep generating).
        #expect(OutputFilter.isDegenerateGhost(" f i"))
        #expect(OutputFilter.isDegenerateGhost("F or"))
    }

    @Test func keepsLegitProse() {
        // Real continuations must NOT be flagged.
        #expect(!OutputFilter.isFragmentedGhost(" de la"))
        #expect(!OutputFilter.isFragmentedGhost("à toi aussi"))
        #expect(!OutputFilter.isFragmentedGhost(" de port."))
        #expect(!OutputFilter.isFragmentedGhost("tu seras le roi"))
        // Vowel singletons are legit standalone words / next-word starts.
        #expect(!OutputFilter.isFragmentedGhost("il y a"))
        #expect(!OutputFilter.isFragmentedGhost("c'est à dire"))
        // English "I" pronoun must survive.
        #expect(!OutputFilter.isFragmentedGhost("I have"))
        #expect(!OutputFilter.isDegenerateGhost("I have"))
    }

    @Test func singleTokenNotFlagged() {
        // A lone single token is a normal mid-word build, never fragmented.
        #expect(!OutputFilter.isFragmentedGhost("r"))
        #expect(!OutputFilter.isFragmentedGhost("cal"))
    }
}
