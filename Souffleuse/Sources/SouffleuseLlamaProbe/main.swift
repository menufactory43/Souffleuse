import Foundation
import SouffleuseLlama
import SouffleuseTyping

let modelPath = NSString(string: "~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf").expandingTildeInPath

let engine = LlamaEngine()

let ok = await engine.load(modelPath: modelPath, contextTokens: 2048)
guard ok else {
    FileHandle.standardError.write("LOAD FAILED\n".data(using: .utf8)!)
    exit(1)
}
FileHandle.standardError.write("LOADED\n".data(using: .utf8)!)

// ═════════════════════════════════════════════════════════════════════════
// EXPERIMENTS — sampling × markup-ban × prompt-shape sweep.
//
// GOAL : ghosts whose words are coherent with what was typed before. We hold
// the prompt shape = LIVE raw continuation (ctxPrefix + beforeCursor) and sweep
// sampling/anti-junk levers, then a second pass sweeps PROMPT SHAPE. Greedy
// baseline (config A) = exactly what ships today. Everything is compared on the
// same context-coherence sentences. Deterministic (fixed seed for temp>0).
// ═════════════════════════════════════════════════════════════════════════
do {
    final class S: @unchecked Sendable { var s = "" }

    func gen(prompt: String, _ smp: LlamaSampling, maxTokens: Int = 18) async -> String {
        let sink = S()
        _ = await engine.generate(prompt: prompt, maxTokens: maxTokens, sampling: smp) { t in
            sink.s += t; return true
        }
        // First line only + collapse for readability (mirrors app one-line cut).
        let oneLine = sink.s.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? sink.s
        return oneLine
    }

    // Context-coherence probes : the NEXT word(s) should fit the prior text.
    let sentences: [(tag: String, text: String, want: String)] = [
        ("food-list",  "J'ai faim, j'ai envie de manger des ",                 "fruits/légumes/viande"),
        ("food-mid",   "Coucou, j'ai faim J'ai envie de manger. Des ",         "un aliment (merguez…)"),
        ("formal-fee", "Je vous écris pour vous informer que les frais ",      "de port/dossier"),
        ("email-open", "Bonjour Madame, je me permets de vous ",               "contacter/écrire"),
        ("tech-bug",   "Le code ne compile pas, il y a une ",                  "erreur"),
        ("thanks",     "Merci beaucoup pour votre ",                           "réponse/message/aide"),
        ("casual-q",   "Tu préfères quoi comme fraises toi ? Ou d'",           "autres (fruits ?)"),
    ]

    // Sampling configs. A = shipped greedy baseline (control).
    let configs: [(name: String, smp: LlamaSampling)] = [
        ("A greedy baseline       ", LlamaSampling(temperature: 0,   repeatPenalty: 1.1)),
        ("B greedy +banMarkup      ", LlamaSampling(temperature: 0,   repeatPenalty: 1.1, banMarkup: true)),
        ("C greedy rep1.3 +ban     ", LlamaSampling(temperature: 0,   repeatPenalty: 1.3, banMarkup: true)),
        ("D greedy rep1.5 +ban     ", LlamaSampling(temperature: 0,   repeatPenalty: 1.5, banMarkup: true)),
        ("E t0.3 minP.05 rep1.2 ban", LlamaSampling(temperature: 0.3, repeatPenalty: 1.2, seed: 42, minP: 0.05, banMarkup: true)),
        ("F t0.5 minP.1 k40 r1.2 ban", LlamaSampling(temperature: 0.5, repeatPenalty: 1.2, seed: 42, topK: 40, minP: 0.1, banMarkup: true)),
        ("G t0.2 minP.1 rep1.3 ban ", LlamaSampling(temperature: 0.2, repeatPenalty: 1.3, seed: 42, minP: 0.1, banMarkup: true)),
    ]

    await engine.setCorpus([])  // isolate from personalization for the sweep

    print("\n╔══ EXPERIMENT 1 : SAMPLING × MARKUP-BAN (raw continuation) ══╗")
    for s in sentences {
        print("\n▼ [\(s.tag)] \(s.text.debugDescription)   want≈ \(s.want)")
        for c in configs {
            let g = await gen(prompt: s.text, c.smp)
            print("   \(c.name) │\(g)")
        }
    }

    // ── EXPERIMENT 2 : PROMPT SHAPE (fixed sampling = best-junk profile C). ──
    // Same user text, different leading context, to see if our live
    // ctxPrefix/fieldContext annotations help or pollute the continuation.
    let smpFixed = LlamaSampling(temperature: 0, repeatPenalty: 1.3, banMarkup: true)
    func shaped(_ kind: String, user: String) -> String {
        switch kind {
        case "bare":     return user
        case "field":    return "Champ : zone de texte.\n\n" + user           // current fieldContext style
        case "context":  return "Contexte : conversation amicale sur la nourriture.\n\n" + user
        case "prime":    return "Voici une conversation naturelle en français.\n" + user  // clean prose primer
        default:         return user
        }
    }
    let shapeUser = "Coucou, j'ai faim J'ai envie de manger. Des "
    print("\n╔══ EXPERIMENT 2 : PROMPT SHAPE (sampling fixed = C) ══╗")
    print("user = \(shapeUser.debugDescription)")
    for kind in ["bare", "field", "context", "prime"] {
        let g = await gen(prompt: shaped(kind, user: shapeUser), smpFixed)
        print("   \(kind.padding(toLength: 8, withPad: " ", startingAt: 0)) │\(g)")
    }

    // ── EXPERIMENT 3 : markup-ban sanity — show the ban list size + a case
    // that previously emitted <strong>. ──
    print("\n╔══ EXPERIMENT 3 : MARKUP-BAN EFFECT (same prompt, ban off→on) ══╗")
    let htmlCase = "J'aime les fraises, j'ai envie de "
    let off = await gen(prompt: htmlCase, LlamaSampling(temperature: 0, repeatPenalty: 1.1))
    let on  = await gen(prompt: htmlCase, LlamaSampling(temperature: 0, repeatPenalty: 1.1, banMarkup: true))
    print("   ban OFF │\(off)")
    print("   ban ON  │\(on)")

    // ── EXPERIMENT 4 : kill the NUMBER prior (banDigits) + context primer. ──
    // The "20 ans / 2019" web prior is the dominant enemy once markup is gone.
    print("\n╔══ EXPERIMENT 4 : BAN DIGITS + CONTEXT PRIMER ══╗")
    let exp4 = sentences
    let noNum = LlamaSampling(temperature: 0, repeatPenalty: 1.3, banMarkup: true, banDigits: true)
    let noNumWarm = LlamaSampling(temperature: 0.4, repeatPenalty: 1.3, seed: 42, minP: 0.08, banMarkup: true, banDigits: true)
    for s in exp4 {
        print("\n▼ [\(s.tag)] want≈ \(s.want)")
        let g1 = await gen(prompt: s.text, noNum)
        let g2 = await gen(prompt: s.text, noNumWarm)
        print("   greedy +ban +noDigit │\(g1)")
        print("   t0.4 minP +ban +noDig │\(g2)")
    }

    // ── EXPERIMENT 5 : mid-word constraint (the real "merguez" case). ──
    print("\n╔══ EXPERIMENT 5 : MID-WORD 'Des me' (merguez case) ══╗")
    for (label, smp) in [
        ("greedy baseline      ", LlamaSampling(temperature: 0, repeatPenalty: 1.1)),
        ("greedy +ban +noDigit ", noNum),
        ("t0.4 minP +ban +noDig", noNumWarm),
    ] {
        let g = await gen(prompt: "Coucou, j'ai faim J'ai envie de manger. Des me", smp, maxTokens: 8)
        print("   \(label) │\(g)")
    }

    // ── EXPERIMENT 6 : best combo + context primer on the food cases. ──
    print("\n╔══ EXPERIMENT 6 : CONTEXT PRIMER × best anti-junk ══╗")
    let primerFood = "Conversation amicale à propos de nourriture.\n"
    for s in [exp4[0], exp4[1]] {
        let plain = await gen(prompt: s.text, noNum)
        let primed = await gen(prompt: primerFood + s.text, noNum)
        print("\n▼ [\(s.tag)]")
        print("   sans amorce │\(plain)")
        print("   avec amorce │\(primed)")
    }

    // ── EXPERIMENT 7 : leading-digit-only ban (shipping-safe candidate). ──
    print("\n╔══ EXPERIMENT 7 : LEADING-DIGIT-ONLY BAN (ship candidate) ══╗")
    let shipCand = LlamaSampling(temperature: 0, repeatPenalty: 1.3, banMarkup: true, banDigitsLeading: true)
    for s in sentences {
        let g = await gen(prompt: s.text, shipCand)
        print("   [\(s.tag.padding(toLength: 10, withPad: " ", startingAt: 0))] │\(g)   (want≈ \(s.want))")
    }

    print("\n═══ END EXPERIMENTS ═══")
    exit(0)
}

// Mirror the in-app system prompt + prompt-building shape so the probe
// reflects what PredictorViewModel actually feeds the engine.
let system = "Tu es un moteur d'autocomplétion inline. Continue le texte de l'utilisateur exactement là où il s'arrête, dans la MÊME langue. Réponds UNIQUEMENT par la suite (quelques mots, une courte phrase au plus), sans répéter le texte, sans salutations, sans guillemets, sans formatage."

func buildPrompt(system: String, afterCursor: String, beforeCursor: String) -> String {
    var userBlock = system
    if !afterCursor.isEmpty { userBlock += "\n\n\(afterCursor)" }
    userBlock += "\n\nVoici le texte à continuer :"
    return "<start_of_turn>user\n\(userBlock)<end_of_turn>\n<start_of_turn>model\n\(beforeCursor)"
}

final class Sink: @unchecked Sendable { var s = "" }

// ─────────────────────────────────────────────────────────────────────────
// VOLET 0 — RAW CONTINUATION repro (mirrors the LIVE app prompt shape:
// buildLlamaPrompt = ctxPrefix + fieldContext + beforeCursor, no chat template,
// base/pt model). Prints the UNFILTERED model output so we see what the model
// truly produces at the caret for the reported screenshots.
print("=== VOLET 0: RAW CONTINUATION (live prompt shape) ===")
func rawGhost(before: String, ctxPrefix: String = "", maxTokens: Int = 16) async -> String {
    var prompt = ""
    if !ctxPrefix.isEmpty { prompt += ctxPrefix + "\n\n" }
    prompt += before
    let sink = Sink()
    _ = await engine.generate(prompt: prompt, maxTokens: maxTokens,
                              sampling: LlamaSampling(temperature: 0, repeatPenalty: 1.1, repeatLastN: 64)) { tok in
        sink.s += tok; return true
    }
    return sink.s
}
let v0cases: [(String, String)] = [
    ("Coucou, j'ai faim J'ai envie de manger. Des me", ""),
    ("Coucou, j'ai faim J'ai envie de manger. Des ", ""),
    ("J'ai faim, j'ai envie de manger des ", ""),
    ("J'aime les fraises, j'ai envie de", ""),
    ("J'aime les fraises, j'ai envie de ", ""),
    ("J'ai faim, on mange quoi ? J'ai envie", ""),
    ("J'ai faim, on mangue quoi ? J'ai envie", ""),
    ("J'ai envie", ""),
    ("Merci beaucoup pour votre", ""),
    ("Je vous écris pour vous informer que les frais", ""),
]
for (before, ctx) in v0cases {
    let raw = await rawGhost(before: before, ctxPrefix: ctx)
    print("BEFORE: \(before.debugDescription)")
    print("RAW   : \(raw.debugDescription)")
    print("---")
}

// ─────────────────────────────────────────────────────────────────────────
// VOLET 1 — silent prefix correction proof. For each typo'd sentence we run
// the ghost on the RAW prefix and on the CORRECTED prefix (PrefixCorrector,
// model-input only) and print both. The corrected one should land more
// coherently. The in-progress last token is appended verbatim by the
// corrector, so the displayed/user path is unaffected (userTail untouched).
print("=== VOLET 1: RAW vs CORRECTED PREFIX GHOST ===")
let corrector = PrefixCorrector()

func ghost(forBeforeCursor before: String, maxTokens: Int = 16) async -> String {
    let prompt = buildPromptV1(system: system, beforeCursor: before)
    let sink = Sink()
    _ = await engine.generate(prompt: prompt, maxTokens: maxTokens,
                              sampling: LlamaSampling(temperature: 0, repeatPenalty: 1.1)) { tok in
        sink.s += tok; return true
    }
    return sink.s.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? sink.s
}

func buildPromptV1(system: String, beforeCursor: String) -> String {
    "<start_of_turn>user\n\(system)\n\nVoici le texte à continuer :<end_of_turn>\n<start_of_turn>model\n\(beforeCursor)"
}

struct TypoCase { let label: String; let prefix: String; let lang: String }
let v1cases = [
    TypoCase(label: "FR completed typos", prefix: "Je vous écirs pour vous infromer que ", lang: "French"),
    TypoCase(label: "FR typo + in-progress tail", prefix: "Bonjur Madame, je vous écirs au ", lang: "French"),
    TypoCase(label: "EN completed typos", prefix: "I am writting to infrom you that ", lang: "English"),
]
for c in v1cases {
    let corrected = corrector.correctedPrefix(c.prefix, detectedLanguage: c.lang)
    print("[\(c.label)]")
    print("RAW   prefix : \(c.prefix.debugDescription)")
    print("CORR  prefix : \(corrected.debugDescription)  (changed=\(corrected != c.prefix))")
    let gRaw = await ghost(forBeforeCursor: c.prefix)
    let gCor = await ghost(forBeforeCursor: corrected)
    print("GHOST(raw)   :\(gRaw)")
    print("GHOST(corr)  :\(gCor)")
    print("---")
}


// ─────────────────────────────────────────────────────────────────────────
// VOLET 1.bis — MID-WORD COHERENCE GUARD repro. Feeds a mid-word prefix
// through the SAME prompt + first-line/filter shape the app uses, then applies
// the mid-word coherence guard (partialWord + ghostHead must be a real word,
// validated by NSSpellChecker via TypoDetector — the same helper wired into
// ModelRuntime.generateLlama). Proves "…procéd" is now suppressed (incoherent
// splice "procédblème") while "…problè" still yields "me…" ("problème").
//
// The guard logic below MIRRORS ModelRuntime.OutputFilter.{trailingPartialWord,
// leadingWordRun,midWordCandidate} + TypoDetector.isValidWord. The probe can't
// link the Souffleuse executable target, so the pure helpers are inlined here;
// the SPELL validation uses the real shared TypoDetector.
print("\n=== VOLET 1.bis: MID-WORD COHERENCE GUARD ===")
let spell = TypoDetector()

func isWordChar(_ c: Character) -> Bool {
    c.isLetter || c.isNumber || c == "'" || c == "’" || c == "-"
}
func trailingPartialWord(_ s: String) -> String {
    var end = s.endIndex
    while end > s.startIndex {
        let prev = s.index(before: end)
        if isWordChar(s[prev]) { end = prev } else { break }
    }
    return String(s[end...])
}
func leadingWordRun(_ s: String) -> String {
    var out = ""
    for c in s { if isWordChar(c) { out.append(c) } else { break } }
    return out
}
/// Returns (ghostShown, dropped). dropped=true ⇒ incoherent mid-word splice.
func applyMidWordGuard(userTail: String, rawGhost: String, language: String) -> (shown: String, dropped: Bool) {
    let partial = trailingPartialWord(userTail)
    guard !partial.isEmpty,
          !partial.contains(where: { $0 == "-" || $0 == "'" || $0 == "’" }),  // hyphen/apostrophe compound → skip
          let first = rawGhost.first, isWordChar(first) else {
        return (rawGhost, false)  // not mid-word / compound / ghost starts a new word → keep
    }
    let candidate = partial + leadingWordRun(rawGhost)
    if spell.isValidWord(candidate, language: language) {
        return (rawGhost, false)  // coherent → keep
    }
    return ("", true)            // incoherent splice → suppress
}

struct MidWordCase { let label: String; let prefix: String; let lang: String }
let midWordCases = [
    MidWordCase(label: "BUG repro (mid-word, incoherent)", prefix: "Coucou, petit test de procéd", lang: "French"),
    MidWordCase(label: "Coherent mid-word (problè→me)", prefix: "Il y a un gros problè", lang: "French"),
    MidWordCase(label: "Hyphen compound (allez-→vous)", prefix: "Bonjour, comment allez-", lang: "French"),
    MidWordCase(label: "Elision (j'→ai)", prefix: "Je pense que j'", lang: "French"),
]
for c in midWordCases {
    let raw = await ghost(forBeforeCursor: c.prefix)
    let partial = trailingPartialWord(c.prefix)
    let candidate = partial + leadingWordRun(raw)
    let (shown, dropped) = applyMidWordGuard(userTail: c.prefix, rawGhost: raw, language: c.lang)
    print("[\(c.label)]")
    print("PREFIX        : \(c.prefix.debugDescription)")
    print("partialWord   : \(partial.debugDescription)")
    print("RAW ghost     : \(raw.debugDescription)")
    print("candidateWord : \(candidate.debugDescription)  valid=\(spell.isValidWord(candidate, language: c.lang))")
    print("GHOST shown   : \(shown.debugDescription)  dropped=\(dropped)")
    print("---")
}

struct Case { let pre: String; let after: String }
let cases = [
    Case(pre: "Bonjour, je voulais vous écrire pour vous", after: ""),
    Case(pre: "Merci beaucoup pour votre", after: ""),
    Case(pre: "Je suis désolé pour le retard, je", after: "Cordialement,"),
    Case(pre: "The quick brown fox jumps over the", after: ""),
]

for c in cases {
    let prompt = buildPrompt(system: system, afterCursor: c.after.isEmpty ? "" : "Suite du texte (à ne pas répéter) : « \(c.after) ».", beforeCursor: c.pre)
    let sink = Sink()
    let metrics = await engine.generate(prompt: prompt, maxTokens: 16) { tok in
        sink.s += tok
        return true
    }
    // First line only (mirrors OutputFilter one-line truncation).
    let oneLine = sink.s.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? sink.s
    FileHandle.standardError.write("[ttft=\(metrics.ttftMillis ?? -1)ms]\n".data(using: .utf8)!)
    print("PRE: \(c.pre)")
    print("GHOST:\(oneLine)")
    print("---")
}

// ─────────────────────────────────────────────────────────────────────────
// VOLET 2 — FIM prompt A/B. Baseline = current `buildLlamaPrompt` shape
// (afterCursor folded into the instruction, "Voici le texte à continuer :").
// Candidate = explicit "(contexte, ne pas répéter)" framing. We compare on
// cases WITH an afterCursor (the only place the framing matters). Decision:
// keep v1 unless candidate is clearly better AND never echoes a label.
print("\n=== VOLET 2: FIM PROMPT A/B (afterCursor present) ===")

func promptBaseline(system: String, after: String, before: String) -> String {
    var u = system
    if !after.isEmpty { u += "\n\nSuite du texte (à ne pas répéter) : « \(after) »." }
    u += "\n\nVoici le texte à continuer :"
    return "<start_of_turn>user\n\(u)<end_of_turn>\n<start_of_turn>model\n\(before)"
}
func promptCandidate(system: String, after: String, before: String) -> String {
    var u = system
    if !after.isEmpty {
        u += "\n\nCONTEXTE (déjà présent dans le champ, ne JAMAIS le répéter) : « \(after) »"
    }
    u += "\n\nTEXTE À CONTINUER (poursuis exactement à partir d'ici, sans le réécrire) :"
    return "<start_of_turn>user\n\(u)<end_of_turn>\n<start_of_turn>model\n\(before)"
}
func ghostFrom(_ prompt: String) async -> String {
    let sink = Sink()
    _ = await engine.generate(prompt: prompt, maxTokens: 16,
                              sampling: LlamaSampling(temperature: 0, repeatPenalty: 1.1)) { tok in
        sink.s += tok; return true
    }
    return sink.s.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? sink.s
}
struct FIMCase { let before: String; let after: String }
let fimCases = [
    FIMCase(before: "Je vous remercie pour ", after: "Cordialement, Gabriel"),
    FIMCase(before: "La réunion aura lieu ", after: "merci de confirmer votre présence."),
    FIMCase(before: "Je pense que ce projet ", after: "et c'est pourquoi je vous écris."),
]
for c in fimCases {
    let gB = await ghostFrom(promptBaseline(system: system, after: c.after, before: c.before))
    let gC = await ghostFrom(promptCandidate(system: system, after: c.after, before: c.before))
    print("BEFORE: \(c.before.debugDescription)  AFTER: \(c.after.debugDescription)")
    print("  baseline :\(gB)")
    print("  candidate:\(gC)")
    print("---")
}

// ─────────────────────────────────────────────────────────────────────────
// Phase 1 personalization proof : feed a tiny fake corpus containing a
// distinctive continuation, then show that strength>0 steers the completion
// toward the corpus continuation while strength==0 does not.
print("\n=== PERSONALIZATION CORPUS BIAS PROOF ===")

let corpus = [
    "Cordialement, Gabriel Waltio",
    "Cordialement, Gabriel Waltio",
    "Cordialement, Gabriel Waltio",
    "Bien cordialement, Gabriel Waltio fondateur de Cocotypist",
]
await engine.setCorpus(corpus)
let hasCorpus = await engine.hasCorpus
print("corpus loaded: \(hasCorpus)")

let proofPrompt = buildPrompt(system: system, afterCursor: "", beforeCursor: "Cordialement,")

func run(strength: Float) async -> String {
    let sink = Sink()
    _ = await engine.generate(
        prompt: proofPrompt,
        maxTokens: 16,
        sampling: LlamaSampling(temperature: 0, repeatPenalty: 1.1, repeatLastN: 64,
                                personalizationStrength: strength)
    ) { tok in sink.s += tok; return true }
    return sink.s.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? sink.s
}

let off = await run(strength: 0)
let on = await run(strength: 8.0)
print("PRE: Cordialement,")
print("GHOST[strength=0]   :\(off)")
print("GHOST[strength=8.0] :\(on)")
print("---")

// ─────────────────────────────────────────────────────────────────────────
// Phase 3 (a) — suffix array variable-length-context match drives a
// >2-token continuation MORE sharply than a bare bigram. We feed a corpus
// with a distinctive multi-token phrase, then show the longest-match lookup
// returns a sharp continuation for a >2-token context window.
print("\n=== PHASE 3 (a): SUFFIX ARRAY LONGEST-MATCH PROOF ===")

let saCorpus = [
    "Le rendez-vous est fixé à quatorze heures précises mardi prochain",
    "Le rendez-vous est fixé à quatorze heures précises mardi prochain",
    "merci de confirmer votre présence au rendez-vous est fixé ailleurs",
]
await engine.setCorpus(saCorpus)

// Build a >2-token context window IN TOKEN SPACE and query the suffix array.
let ctxText = "Le rendez-vous est fixé à quatorze heures"
let ctxIds = await engine.tokenizeForCorpus(ctxText)
let (cands, matchLen) = await engine.suffixArrayCandidates(after: ctxIds)
print("context tokens: \(ctxIds.count)  matchLength=\(matchLen)")
let topCand = cands.max(by: { $0.value < $1.value })
if let top = topCand {
    let piece = await engine.tokenizeForCorpus("précises").first
    print("top corpus continuation id=\(top.key) count=\(top.value)  (expect to lead toward 'précises' id≈\(piece.map(String.init) ?? "?"))")
}
print("candidates=\(cands.count)  (variable-length match used \(matchLen) tokens of context — bigram would use 1)")

// Now drive the actual decoder: a multi-token primed context should
// continue the corpus phrase sharply under the suffix-array bias.
let saPrompt = buildPrompt(system: system, afterCursor: "", beforeCursor: "Le rendez-vous est fixé à quatorze heures")
func runSA(strength: Float) async -> String {
    let sink = Sink()
    _ = await engine.generate(
        prompt: saPrompt, maxTokens: 12,
        sampling: LlamaSampling(temperature: 0, repeatPenalty: 1.1, repeatLastN: 64,
                                personalizationStrength: strength)
    ) { tok in sink.s += tok; return true }
    return sink.s.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? sink.s
}
let saOff = await runSA(strength: 0)
let saOn = await runSA(strength: 6.0)  // default-preference effective base gain
print("PRE: Le rendez-vous est fixé à quatorze heures")
print("GHOST[strength=0] :\(saOff)")
print("GHOST[strength=6] :\(saOn)")
print("---")

// ─────────────────────────────────────────────────────────────────────────
// KV / PROMPT CACHE REUSE — cold vs warm TTFT proof.
//
// Realistic long-ish prompt. We force a COLD cache (reload the model to drop
// the KV), measure TTFT. Then an incremental prompt = previous + a few typed
// words runs WARM (long common prefix reused, only the suffix decoded) and we
// measure TTFT again. The warm incremental TTFT must be dramatically lower.
print("\n=== KV CACHE REUSE: COLD vs WARM TTFT ===")
await engine.setCorpus([])  // clear corpus so bias never perturbs the proof

let longBefore = """
Bonjour Madame, je me permets de vous écrire au sujet du dossier que nous \
avons évoqué la semaine dernière lors de notre réunion de coordination. Comme \
convenu lors de nos échanges précédents, je vous transmets ci-joint l'ensemble \
des éléments complémentaires relatifs au calendrier prévisionnel, au budget \
détaillé poste par poste, ainsi qu'à la répartition des responsabilités entre \
les différentes équipes impliquées dans ce projet. J'ai également pris soin de \
préciser les jalons intermédiaires et les livrables attendus à chaque étape, de \
manière à ce que chacun dispose d'une vision claire et partagée des objectifs. \
Je reste naturellement à votre entière disposition pour
"""
let coldPrompt = buildPrompt(system: system, afterCursor: "", beforeCursor: longBefore)
// Incremental: the user typed three more words. Shares the entire long prefix.
let warmPrompt = buildPrompt(system: system, afterCursor: "", beforeCursor: longBefore + " toute information")

func genOnce(_ prompt: String) async -> (ttft: Int, out: String, cached: Int) {
    let sink = Sink()
    let m = await engine.generate(prompt: prompt, maxTokens: 16,
                                  sampling: LlamaSampling(temperature: 0, repeatPenalty: 1.0)) { tok in
        sink.s += tok; return true
    }
    let cached = await engine.cachedTokenCount
    let oneLine = sink.s.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? sink.s
    return (m.ttftMillis ?? -1, oneLine, cached)
}

// COLD: reload model to guarantee an empty KV.
_ = await engine.load(modelPath: modelPath, contextTokens: 2048)
let coldA = await genOnce(coldPrompt)
print("COLD prompt (\(coldA.cached) tok resident) TTFT = \(coldA.ttft)ms")
print("  ghost: \(coldA.out)")

// WARM: the incremental prompt reuses the long common prefix from the cold run.
let warmB = await genOnce(warmPrompt)
print("WARM incremental (\(warmB.cached) tok resident) TTFT = \(warmB.ttft)ms")
print("  ghost: \(warmB.out)")

if coldA.ttft > 0 && warmB.ttft >= 0 {
    let speedup = Double(coldA.ttft) / Double(max(1, warmB.ttft))
    print(String(format: "SPEEDUP (cold/warm TTFT) = %.1fx", speedup))
}

// CORRECTNESS: the SAME incremental prompt, run cold on a freshly reloaded
// model, must yield the same first-line ghost as the warm run above.
_ = await engine.load(modelPath: modelPath, contextTokens: 2048)
let warmAsCold = await genOnce(warmPrompt)
print("EQUIVALENCE warm.ghost == cold(sameprompt).ghost : \(warmB.out == warmAsCold.out)")
print("  cold-recompute of incremental TTFT = \(warmAsCold.ttft)ms (sanity: ≈ cold magnitude)")
print("---")
