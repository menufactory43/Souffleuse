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

/// Context-preamble echo guard — the base PT model, with little/nothing to
/// continue, regurgitates the injected app/window/clipboard/OCR framing as the
/// ghost ("App Signal, window …"). That is generic meta-text AND a clipboard/OCR
/// LEAK on screen. `OutputFilter.echoesContextPreamble` drops it. The two
/// branches (frame-head echo / empty-field dump) are tuned against the live
/// overlay traces (2026-05-31): every measured displayed echo (≈1153 events,
/// 9–17 normalised chars) must drop, while every legitimate context-grounded
/// completion — including one that reuses a clipboard/OCR word mid-text — must
/// survive (the "le contexte quand j'en ai besoin" guarantee, zero false
/// positives across the adversarial stress set).
@Suite("OutputFilter — context-preamble echo guard")
struct ContextEchoTests {
    // Realistic injected preamble (ctxPrefix + "\n" + fieldContextSlot), per the
    // measured model-input structure (ContextEnricher prose + the PVM field block).
    let signal = """
    App Signal, window "Signal". Clipboard: Tu peux me rappeler l'adresse du resto de samedi ?
    Champ : zone de texte.
    Placeholder : « Message ».
    """
    let signalOCR = """
    App Signal, window "Signal". On screen: Marie: on se voit demain à 19h alors ? Hâte de te voir !
    Champ : zone de texte.
    Placeholder : « Message ».
    """
    let brave = """
    App Brave, window "X".
    Champ : champ texte.
    """

    // ── Recall: the real measured echoes must drop ──

    @Test func frameHeadEchoesDropped() {
        // 911× displayed — non-empty (placeholder) tail. 'app signal window' = 17
        // normalised chars, which a generic length floor (20) would have MISSED.
        #expect(OutputFilter.echoesContextPreamble(
            ghost: "App Signal, window", contextPreamble: signal, userTail: "Saisissez un message"))
        // 232× — unrelated non-empty tail. 'app signal' = 10 chars.
        #expect(OutputFilter.echoesContextPreamble(
            ghost: "App Signal", contextPreamble: signal, userTail: "Voici le site pour aller voir"))
        // 8× Brave. 'app brave' = 9 chars (shortest measured echo).
        #expect(OutputFilter.echoesContextPreamble(
            ghost: "App Brave", contextPreamble: brave, userTail: "¡Cheque !"))
        // Lowercase variant on a mid-word tail.
        #expect(OutputFilter.echoesContextPreamble(
            ghost: "app Signal", contextPreamble: signal, userTail: "L'"))
        // Full frame with window title, empty field.
        #expect(OutputFilter.echoesContextPreamble(
            ghost: "App Signal, window \"Signal\".", contextPreamble: signal, userTail: ""))
    }

    @Test func nonEmptyFieldFrameEchoStillDropped() {
        // Branch A is field-state-independent: reproducing the frame head is an
        // echo even behind a long, legit-looking tail.
        #expect(OutputFilter.echoesContextPreamble(
            ghost: "App Signal, window \"Signal\"",
            contextPreamble: signal,
            userTail: "J'ai bien reçu ton message hier soir merci"))
    }

    @Test func emptyFieldClipboardDumpDropped() {
        // Clipboard payload recrache verbatim into an empty field (privacy leak).
        #expect(OutputFilter.echoesContextPreamble(
            ghost: "Tu peux me rappeler l'adresse du resto", contextPreamble: signal, userTail: ""))
    }

    @Test func quasiEmptyFieldOCRDumpDropped() {
        // 1-char tail + long OCR span reproduced → Branch B.
        #expect(OutputFilter.echoesContextPreamble(
            ghost: "Marie: on se voit demain à 19h", contextPreamble: signalOCR, userTail: "a"))
    }

    // ── Precision: legitimate context-grounded completions must NEVER drop ──

    @Test func legitMidFieldOCRReuseKept() {
        // Reuses "demain" from the OCR context as a genuine continuation — the
        // feature working, not an echo. Mid-field (non-empty tail).
        #expect(!OutputFilter.echoesContextPreamble(
            ghost: "demain à 19h ça me va",
            contextPreamble: signalOCR,
            userTail: "Oui parfait, on se voit "))
    }

    @Test func legitMidFieldClipboardReuseKept() {
        // Cites a clipboard segment mid-completion in a NON-empty field — Branch
        // B is empty-field-only, so this is structurally exempt even though the
        // segment appears in the clipboard span of the preamble.
        #expect(!OutputFilter.echoesContextPreamble(
            ghost: "l'adresse du resto, c'est noté",
            contextPreamble: signal,
            userTail: "Oui je t'envoie "))
    }

    @Test func legitSharesAppWordButNotHeaderKept() {
        // A real ghost merely starting with "App " diverges from the live
        // app-name header ("App Store" ≠ "App Signal") before the floor → kept.
        #expect(!OutputFilter.echoesContextPreamble(
            ghost: "App Store est plus rapide depuis la mise à jour",
            contextPreamble: signal,
            userTail: "Je trouve que l'"))
    }

    @Test func legitShortEmptyFieldReuseKept() {
        // Slack cold-start: empty field, reuses a speaker name "Marie" — too
        // short to be a dump, not a frame-head prefix → kept.
        #expect(!OutputFilter.echoesContextPreamble(
            ghost: " Marie: « Ok",
            contextPreamble: "App Slack, window \"general\". On screen: Marie: on a une demande urgente de Carrefour.",
            userTail: ""))
    }

    @Test func emptyPreambleIsNoOp() {
        // Thin context / callers that pass nothing → guard never fires.
        #expect(!OutputFilter.echoesContextPreamble(
            ghost: "App Signal, window", contextPreamble: "", userTail: ""))
    }
}

/// Context-echo wired through `ChunkFilter.filterChunk` — verifies the verdict
/// and the `.contextEcho` drop reason the caller maps to `ghost_dropped_context_echo`.
@Suite("ChunkFilter — context-preamble echo drop")
struct ChunkFilterContextEchoTests {
    let signal = """
    App Signal, window "Signal". Clipboard: Tu peux me rappeler l'adresse du resto de samedi ?
    Champ : zone de texte.
    Placeholder : « Message ».
    """

    @Test func frameHeadEchoDropsViaChunkFilter() {
        let r = ChunkFilter.filterChunk(
            accumulated: "App Signal, window",
            userTail: "Saisissez un message",
            caretAfterSpace: false,
            maxWords: 20,
            contextPreamble: signal)
        #expect(r.verdict == .dropKeepGenerating)
        #expect(r.dropReason == .contextEcho)
    }

    @Test func legitContextReuseEmitsViaChunkFilter() {
        // Mid-field completion reusing a clipboard word — NOT a context echo.
        let r = ChunkFilter.filterChunk(
            accumulated: " l'adresse du resto, c'est noté",
            userTail: "Oui je t'envoie",
            caretAfterSpace: false,
            maxWords: 20,
            contextPreamble: signal)
        guard case .emit = r.verdict else {
            Issue.record("expected .emit, got \(r.verdict)")
            return
        }
        #expect(r.dropReason != .contextEcho)
    }

    @Test func noPreambleArgIsNoOp() {
        // Default contextPreamble "" — a frame-looking ghost is NOT dropped as a
        // context echo, so existing callers (incl. SouffleuseReplay) are unaffected.
        let r = ChunkFilter.filterChunk(
            accumulated: "App Signal, window",
            userTail: "Saisissez un message",
            caretAfterSpace: false,
            maxWords: 20)
        #expect(r.dropReason != .contextEcho)
    }
}
