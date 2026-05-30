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

    @Test func wordCapPreservesLeadingSpace() {
        // The word-cap branch (no terminator) must KEEP the single leading
        // separator space of a next-word continuation after a complete word.
        // Caret right after "balances" (no trailing space → caretAfterSpace
        // false), model continues " négatives dans votre compte bancaire";
        // capped to 3 words this must stay " négatives dans votre" (NOT
        // "négatives dans votre", which renders/inserts glued as
        // "balancesnégatives"). Regression for the split()/joined() leading-
        // space loss — the screenshot bug.
        let r = ChunkFilter.filterChunk(
            accumulated: " négatives dans votre compte bancaire",
            userTail: "de réconcilier les balances", caretAfterSpace: false, maxWords: 3)
        #expect(r.verdict == .emit(" négatives dans votre"))
    }

    @Test func wordCapAfterSpaceAddsNoLeadingSpace() {
        // caretAfterSpace strips the model's leading space upstream, so the
        // word-cap restore must be a no-op — no spurious / double leading space.
        let r = ChunkFilter.filterChunk(
            accumulated: " négatives dans votre compte bancaire",
            userTail: "les balances ", caretAfterSpace: true, maxWords: 3)
        #expect(r.verdict == .emit("négatives dans votre"))
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

/// Dangling-élision trim — a settled ghost must never freeze on a trailing word
/// that ends in an intra-word joiner (`'` / `-`): "l'", "d'", "qu'", "peut-".
/// Such a word always demands a continuation, so it is stripped; if nothing
/// complete remains the chunk is dropped so decoding keeps going (→ "l'arbre").
@Suite("ChunkFilter — dangling élision trim")
struct ChunkFilterElisionTests {

    @Test func loneElisionIsDropped() {
        // "l'" alone has no complete word → drop and keep generating.
        let r = ChunkFilter.filterChunk(
            accumulated: "l'", userTail: "", caretAfterSpace: false, maxWords: 20)
        #expect(r.verdict == .dropKeepGenerating)
    }

    @Test func trailingElisionStripped() {
        // "manger l'" → strip the dangling "l'" (and its separating space).
        let r = ChunkFilter.filterChunk(
            accumulated: "manger l'", userTail: "", caretAfterSpace: false, maxWords: 20)
        #expect(r.verdict == .emit("manger"))
    }

    @Test func openCompoundStripped() {
        // Open compound ("peut-" wants "-être") is dangling too.
        let r = ChunkFilter.filterChunk(
            accumulated: "il peut-", userTail: "", caretAfterSpace: false, maxWords: 20)
        #expect(r.verdict == .emit("il"))
    }

    @Test func completeElisionWordKept() {
        // A COMPLETE elided word ("l'arbre", "aujourd'hui") must survive — the
        // joiner is internal, the word ends on a letter.
        let arbre = ChunkFilter.filterChunk(
            accumulated: "l'arbre", userTail: "", caretAfterSpace: false, maxWords: 20)
        #expect(arbre.verdict == .emit("l'arbre"))
        let hui = ChunkFilter.filterChunk(
            accumulated: "aujourd'hui", userTail: "", caretAfterSpace: false, maxWords: 20)
        #expect(hui.verdict == .emit("aujourd'hui"))
    }
}

/// Complete-word budget — `reachedWordCap` lets the generation caller stop at a
/// WORD boundary (not a raw token count). A trailing in-progress word, and
/// especially a dangling élision, must NOT count, so decoding continues until a
/// real word completes.
@Suite("ChunkFilter — reachedWordCap (complete-word budget)")
struct ChunkFilterWordCapTests {

    @Test func reachedAtBudget() {
        // maxWords = 2, "un deux trois": "un" and "deux" are complete (a word
        // follows each) → cap reached. Display caps to "un deux".
        let r = ChunkFilter.filterChunk(
            accumulated: "un deux trois", userTail: "", caretAfterSpace: false, maxWords: 2)
        #expect(r.reachedWordCap == true)
        #expect(r.verdict == .emit("un deux"))
    }

    @Test func notReachedBelowBudget() {
        // "un deux": only "un" is complete (trailing "deux" still in progress).
        let r = ChunkFilter.filterChunk(
            accumulated: "un deux", userTail: "", caretAfterSpace: false, maxWords: 3)
        #expect(r.reachedWordCap == false)
    }

    @Test func danglingElisionDoesNotCountTowardCap() {
        // "un l'" with maxWords = 2: the dangling "l'" must not count, so the cap
        // is NOT reached (keep decoding to complete "l'arbre"), and the residual
        // "l'" is stripped from the display.
        let r = ChunkFilter.filterChunk(
            accumulated: "un l'", userTail: "", caretAfterSpace: false, maxWords: 2)
        #expect(r.reachedWordCap == false)
        #expect(r.verdict == .emit("un"))
    }
}
