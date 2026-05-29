import Foundation
import SouffleuseCore
import SouffleuseLlama
import SouffleuseLog
import SouffleusePersonalization
import SouffleuseTyping

// Souffleuse Mid-word Eval Bench
//
// The OCR ablation only exercises after-space / sentence-start completions.
// But the live `overlay_shown` log says ~80% of real ghosts fire MID-WORD
// (caret sits inside a word). That path does NOT go through the free LLM in
// production: `SuggestionPolicy.routeInstant` routes mid-word to L1 (corpus
// recall) first, then L0 (NSSpellChecker word completion); the L2 LLM is
// largely blocked there. So the relevance the user FEELS day-to-day is mostly
// decided by L0/L1 — never measured until now.
//
// For each mid-word prefix this bench prints, side by side:
//   L0  — WordCompleter.completion(for:)            (finish the partial word)
//   L1  — SuggestionPolicy.strongCorpusMatch(...)   (recall from real history)
//   L2  — LlamaEngine.generate(healPrefix:)         (healed whole-word LLM)
//   PICK — SuggestionPolicy.routeInstant(...)        (what prod ACTUALLY shows)
//
// `expected` is the correct continuation, so correctness is eyeball-able.
//
// Usage:
//   SOUFFLEUSE_GGUF=~/Library/Application\ Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf \
//     swift run SouffleuseMidwordEval

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

struct MWCase: Sendable {
    let label: String
    /// Prefix whose LAST char is a letter → caret sits mid-word.
    let prefix: String
    /// The continuation a perfect completer would emit (suffix of the word,
    /// possibly followed by next words). For judging only.
    let expected: String
}

let cases: [MWCase] = [
    // ── Killers from the codebase's own comments ──────────────────────────
    .init(label: "informations-pe", prefix: "Nous protégeons vos informations pe", expected: "rsonnelles"),
    .init(label: "rapport-fis",      prefix: "Vous trouverez votre rapport fis",   expected: "cal"),
    // ── Waltio / fiscalité support domain (matches OCR ablation register) ──
    .init(label: "plus-value",       prefix: "Le calcul de la plus-v",             expected: "alue"),
    .init(label: "investissement",   prefix: "qui prend en compte votre inv",      expected: "estissement"),
    .init(label: "cession",          prefix: "le montant de la cess",              expected: "ion"),
    .init(label: "portefeuille",     prefix: "la valeur globale de votre portef",  expected: "euille"),
    .init(label: "acquisition",      prefix: "votre prix total d'acqui",           expected: "sition"),
    .init(label: "imposable",        prefix: "la fraction imposa",                 expected: "ble"),
    // ── Generic FR support register ───────────────────────────────────────
    .init(label: "effectivement",    prefix: "merci pour votre message. Effectiv", expected: "ement"),
    .init(label: "normal",           prefix: "Bonjour, c'est tout à fait nor",     expected: "mal"),
    .init(label: "patience",         prefix: "je vous remercie de votre pati",     expected: "ence"),
    .init(label: "delais",           prefix: "nous reviendrons vers vous dans les meilleurs dél", expected: "ais"),
    .init(label: "disposition",      prefix: "Je reste à votre dispos",            expected: "ition"),
    // ── Short / ambiguous (where the 1B guesses the wrong word) ───────────
    .init(label: "co-short",         prefix: "Bonjour, co",                        expected: "mment (ambigu)"),
    .init(label: "po-short",         prefix: "Po",                                 expected: "ur (ambigu)"),
]

// ── L2 sampling: mirror production `generateLlama` exactly. ───────────────
func runLLM(prefix: String, engine: LlamaEngine) async -> (out: String, ms: Int) {
    let heal = OutputFilter.trailingPartialWord(prefix)
    let prompt = LlamaPromptBuilder.buildLlamaPrompt(
        system: "", customInstr: "", ctxPrefix: "", fieldContext: "",
        afterCursor: "", beforeCursor: prefix
    )
    let start = Date()
    final class Acc: @unchecked Sendable { var text = "" }
    let acc = Acc()
    _ = await engine.generate(
        prompt: prompt,
        maxTokens: 12,
        sampling: LlamaSampling(
            temperature: 0,
            repeatPenalty: 1.3,
            repeatLastN: 64,
            personalizationStrength: 0,
            banMarkup: true,
            banDigitsLeading: true,
            banEmoji: true,
            healPrefix: heal.isEmpty ? nil : heal
        )
    ) { tok in acc.text += tok; return true }
    let ms = Int(Date().timeIntervalSince(start) * 1000)
    let oneLine = acc.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? acc.text
    return (oneLine, ms)
}

// ── Boot the engine on the same GGUF as production / the OCR ablation. ────
let ggufPath: String = {
    if let p = ProcessInfo.processInfo.environment["SOUFFLEUSE_GGUF"], !p.isEmpty {
        return (p as NSString).expandingTildeInPath
    }
    return (("~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf") as NSString)
        .expandingTildeInPath
}()

let engine = LlamaEngine()
err("[midword] loading GGUF: \(ggufPath)")
guard await engine.load(modelPath: ggufPath, contextTokens: 4096) else {
    err("[midword] FATAL: could not load GGUF")
    exit(1)
}

// Real typing history → L1 corpus recall + engine n-gram (matches production).
let store = TypingHistoryStore()
let history = await store.allEntries()
err("[midword] history entries: \(history.count)")
if !history.isEmpty {
    await engine.setCorpus(history.map { e in
        e.contextBefore.isEmpty ? e.accepted : e.contextBefore + " " + e.accepted
    })
}

let wordCompleter = WordCompleter()
let policy = await MainActor.run { SuggestionPolicyEngine(maxWords: 8) }

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
}
func show(_ s: String?) -> String { (s?.isEmpty == false) ? s! : "∅" }

err("\n──────────── Mid-word layer eval (\(cases.count) cases) ────────────")
var l0Hits = 0, l1Hits = 0, pickL0 = 0, pickL1 = 0, pickNone = 0

for c in cases {
    let l0 = wordCompleter.completion(for: c.prefix)
    let l1 = SuggestionPolicy.strongCorpusMatch(userTail: c.prefix, snapshot: history)?.continuation
    let (l2, l2ms) = await runLLM(prefix: c.prefix, engine: engine)
    let prefix = c.prefix
    let pick: (source: String, text: String)? = await MainActor.run {
        guard let g = policy.routeInstant(
            userTail: prefix, historySnapshot: history, wordCompleter: wordCompleter
        ) else { return nil }
        let src: String
        switch g.source {
        case .wordComplete: src = "L0"
        case .history:      src = "L1"
        default:            src = "\(g.source)"
        }
        return (src, g.text)
    }

    if l0 != nil { l0Hits += 1 }
    if l1 != nil { l1Hits += 1 }
    switch pick?.source {
    case .some("L0"): pickL0 += 1
    case .some("L1"): pickL1 += 1
    default: pickNone += 1
    }

    let pickStr: String
    switch pick?.source {
    case .some(let s): pickStr = "\(s):\(show(pick?.text))"
    case .none:        pickStr = "∅ (→ L2 LLM fills)"
    }

    print("""

    ### \(c.label)  —  "\(c.prefix)"   (attendu: \(c.expected))
      L0 word-complete : \(show(l0))
      L1 corpus-recall : \(show(l1))
      L2 LLM healed    : \(show(l2))   [\(l2ms)ms]
      → PROD MONTRE    : \(pickStr)
    """)
}

err("""

──────────── Summary ────────────
cases:                 \(cases.count)
L0 produced a result:  \(l0Hits)/\(cases.count)
L1 produced a result:  \(l1Hits)/\(cases.count)
PROD pick = L0:        \(pickL0)
PROD pick = L1:        \(pickL1)
PROD pick = none(→L2): \(pickNone)

Reading:
  PROD pick column is what the user actually SEES mid-word. If most picks are
  L0 and L0 is wrong/jumpy, that — not the LLM, not OCR — is the felt "generic".
  If most picks are 'none(→L2)', the mid-word LLM healed quality (L2 column)
  is what matters and should be judged against `expected`.
""")
