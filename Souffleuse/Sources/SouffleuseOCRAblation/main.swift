import Foundation
import SouffleuseCore
import SouffleuseContext
import SouffleuseLlama
import SouffleuseLog
import SouffleusePersonalization

// Souffleuse OCR Ablation Bench
//
// Runs the EXACT production pipeline (llama.cpp + GGUF + LlamaPromptBuilder
// + EnrichedContext prose format) and compares three conditions per case:
//
//   A) raw:     user text only, no Context block
//   B) no-OCR:  app + windowTitle + clipboard (NO On screen: …)
//   C) with-OCR: full enrichment (A + visible OCR text)
//
// Emits JSONL on stdout per case + a final summary on stderr. The headline
// numbers are:
//   - mean divergence A→C  : does enrichment AT ALL move the model?
//   - mean divergence B→C  : does the OCR PART specifically move it?
//   - Δlatency raw vs each : cost of each layer
//
// If divergence B→C is near 0, the OCR slot adds latency for no behavioural
// change → we should drop it (or significantly raise the bar on what makes it
// past the cleaners). If it's > ~0.2, OCR is doing real work.
//
// Usage:
//   SOUFFLEUSE_GGUF=~/Library/Application\ Support/Souffleuse/Models/gemma-3-1b.i1-Q5_K_M.gguf \
//     swift run SouffleuseOCRAblation > out.jsonl

struct ABCase: Sendable {
    let label: String
    let app: String?
    let windowTitle: String?
    let clipboard: String?
    let visible: String?
    let userText: String
}

let cases: [ABCase] = [
    // Intercom-style support, French. The OCR matches what we actually
    // captured during the 2026-05-28 triage.
    ABCase(
        label: "intercom-fiscalite-fr",
        app: "Intercom (support client)",
        windowTitle: "antonindubois@free.fr | Boîte de réception Intercom Inbox | Waltio | Intercom",
        clipboard: nil,
        visible: "Le calcul de la plus-value prend en compte votre investissement en euros depuis vos débuts (prix total d'acquisition), le montant de la cession imposable en euros et la valeur globale de votre portefeuille au moment de la cession. La formule de calcul des plus-values de cession est donc la suivante: prix de cession - [prix total d'acquisition x (prix de cession / valeur globale)]",
        userText: "Bonjour Antonin, merci pour votre message. Effectivement,"
    ),
    ABCase(
        label: "intercom-trade-eth-fr",
        app: "Intercom (support client)",
        windowTitle: "cin32ls@proton.me | Boîte de réception Intercom Inbox | Waltio | Intercom",
        clipboard: nil,
        visible: "Donc si j'ai bien compris, ici par exemple pour la journée du 16 novembre, vu que j'ai vendu et racheté de l'ETH plusieurs fois dans la même journée, j'ai engendré plusieurs centaines euros de plus value alors que concrètement j'ai perdu de l'argent sur les trades ? merci pour votre",
        userText: "Bonjour, c'est tout à fait normal. En effet,"
    ),
    ABCase(
        label: "mail-reply-fr",
        app: "Mail",
        windowTitle: "Re: Facture Q2 2026",
        clipboard: nil,
        visible: "De: Marie Dupont. Objet: Facture Q2 2026. Bonjour, je n'ai pas reçu la facture du deuxième trimestre, peux-tu me la renvoyer ? Merci, Marie",
        userText: "Bonjour Marie, désolé pour ce retard, je te"
    ),
    ABCase(
        label: "slack-deploy-en",
        app: "Slack",
        windowTitle: "#deploy",
        clipboard: nil,
        visible: "alex: staging is down. you: looking now. alex: ETA? you: 5 min",
        userText: "it's back up, the root cause was"
    ),
    ABCase(
        label: "note-meeting-fr",
        app: "Notes",
        windowTitle: "Réunion produit 21 mai",
        clipboard: nil,
        visible: "Réunion produit du 21 mai. Présents : Marc, Léa, Karim. Sujets abordés : onboarding, pricing, churn.",
        userText: "Action items : Marc envoie le nouveau funnel onboarding avant vendredi, Léa"
    ),
    ABCase(
        label: "github-pr-en",
        app: "Safari",
        windowTitle: "PR #42: Add ContextEnricher",
        clipboard: nil,
        visible: "This PR adds the ContextEnricher actor described in ARCHITECTURE.md §3.2. Three sources: app metadata, clipboard, screen OCR.",
        userText: "Looks good. Two questions: first, what happens if"
    ),
    ABCase(
        label: "calendar-fr",
        app: "Calendar",
        windowTitle: "Mai 2026",
        clipboard: nil,
        visible: "Lundi 19: Standup 10h. Mardi 20: 1:1 Marc 14h. Mercredi 21: Réunion produit 11h.",
        userText: "Pour jeudi 22 je propose un créneau de"
    ),
    ABCase(
        label: "messages-fr",
        app: "Messages",
        windowTitle: "Camille",
        clipboard: nil,
        visible: "Camille: On se voit ce soir ? Moi: oui avec plaisir, on dit où ? Camille: Le bar habituel ?",
        userText: "ok parfait je te rejoins vers"
    ),
    ABCase(
        label: "twitter-en",
        app: "Safari",
        windowTitle: "Home / X",
        clipboard: nil,
        visible: "Just shipped: a local-first autocomplete engine for macOS that runs entirely on-device. No data leaves your machine.",
        userText: "love this, finally a privacy-respecting autocomplete that"
    ),
    ABCase(
        label: "blank-context-fr",
        app: nil,
        windowTitle: nil,
        clipboard: nil,
        visible: nil,
        userText: "Bonjour Marie, je te confirme notre rendez-vous de demain 14h. Je"
    ),
]

func enrich(app: String?, title: String?, clipboard: String?, visible: String?) -> String {
    EnrichedContext(
        app: app, windowTitle: title, clipboard: clipboard, visible: visible
    ).prefix
}

let customInstr = "My name is Gabriel. I usually write in French. Write in a friendly, professional and empathetic voice. Keep your sentences short, concise and readable."

func buildPrompt(case c: ABCase, condition: String) -> String {
    let ctxPrefix: String
    switch condition {
    case "raw":     ctxPrefix = ""
    case "no-ocr":  ctxPrefix = enrich(app: c.app, title: c.windowTitle, clipboard: c.clipboard, visible: nil)
    case "with-ocr": ctxPrefix = enrich(app: c.app, title: c.windowTitle, clipboard: c.clipboard, visible: c.visible)
    default: ctxPrefix = ""
    }
    return LlamaPromptBuilder.buildLlamaPrompt(
        system: "",
        customInstr: customInstr,
        ctxPrefix: ctxPrefix.trimmingCharacters(in: .whitespacesAndNewlines),
        fieldContext: "",
        afterCursor: "",
        beforeCursor: c.userText
    )
}

struct Run: Sendable {
    let output: String
    let ttftMs: Int
    let totalMs: Int
    let tokens: Int
}

func run(prompt: String, engine: LlamaEngine, personalizationStrength: Float = 0) async -> Run {
    let start = Date()
    final class Acc: @unchecked Sendable {
        var text = ""
        var firstAt: Date?
        var tokens = 0
    }
    let acc = Acc()
    // Production gain scale: the user-facing slider (default 1.0) is multiplied
    // by `personalizationGainScale` (6.0) inside production. We mirror that so
    // strength=1.0 here matches what a default-preference user gets in prod.
    let effectiveStrength = personalizationStrength * LlamaSampling.personalizationGainScale
    _ = await engine.generate(
        prompt: prompt,
        maxTokens: 16,
        sampling: LlamaSampling(
            temperature: 0,
            repeatPenalty: 1.3,
            repeatLastN: 64,
            personalizationStrength: effectiveStrength,
            banMarkup: true,
            banDigitsLeading: true,
            banEmoji: true
        )
    ) { token in
        if acc.firstAt == nil { acc.firstAt = Date() }
        acc.tokens += 1
        acc.text += token
        return true
    }
    let now = Date()
    let ttft = acc.firstAt.map { Int($0.timeIntervalSince(start) * 1000) } ?? -1
    let total = Int(now.timeIntervalSince(start) * 1000)
    let oneLine = acc.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? acc.text
    return Run(output: oneLine, ttftMs: ttft, totalMs: total, tokens: acc.tokens)
}

func divergence(_ a: String, _ b: String) -> Double {
    if a == b { return 0 }
    if a.isEmpty || b.isEmpty { return 1 }
    let A = Array(a), B = Array(b)
    var prev = Array(0...B.count)
    var curr = Array(repeating: 0, count: B.count + 1)
    for i in 1...A.count {
        curr[0] = i
        for j in 1...B.count {
            let cost = A[i-1] == B[j-1] ? 0 : 1
            curr[j] = min(prev[j] + 1, curr[j-1] + 1, prev[j-1] + cost)
        }
        swap(&prev, &curr)
    }
    return Double(prev[B.count]) / Double(max(A.count, B.count))
}

@Sendable func emit(_ s: String) {
    FileHandle.standardOutput.write(Data((s + "\n").utf8))
}
@Sendable func err(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

setbuf(stdout, nil); setbuf(stderr, nil)

let env = ProcessInfo.processInfo.environment
let ggufPath: String = {
    if let p = env["SOUFFLEUSE_GGUF"], !p.isEmpty {
        return (p as NSString).expandingTildeInPath
    }
    let fm = FileManager.default
    let candidates = [
        "~/Library/Application Support/Souffleuse/Models/gemma-3-1b.i1-Q5_K_M.gguf",
        "~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf",
    ]
    for c in candidates {
        let expanded = (c as NSString).expandingTildeInPath
        if fm.fileExists(atPath: expanded) { return expanded }
    }
    return ""
}()

guard !ggufPath.isEmpty, FileManager.default.fileExists(atPath: ggufPath) else {
    err("GGUF not found. Set SOUFFLEUSE_GGUF=/path/to/gemma-3-1b.i1-Q5_K_M.gguf")
    exit(1)
}

err("[ocr-ablation] GGUF: \(ggufPath)")
let engine = LlamaEngine()
guard await engine.load(modelPath: ggufPath, contextTokens: 4096) else {
    err("load failed"); exit(1)
}

// Load typing history corpus for the personalization condition. Same path
// SouffleuseReplay uses: TypingHistoryStore is the only sanctioned reader of
// history.db (privacy invariant per audit.sh).
let store = TypingHistoryStore()
let historyEntries = await store.allEntries()
if historyEntries.isEmpty {
    err("[ocr-ablation] WARN: typing history empty — perso condition D will be a no-op clone of C.")
} else {
    err("[ocr-ablation] loading \(historyEntries.count) history entries into engine corpus…")
    await engine.setCorpus(historyEntries.map { e in
        e.contextBefore.isEmpty ? e.accepted : e.contextBefore + " " + e.accepted
    })
    err("[ocr-ablation] corpus ready.")
}

let personalizationStrength: Float = {
    if let v = env["SOUFFLEUSE_PERSO"].flatMap({ Float($0) }) { return v }
    return 1.0  // production default per PreferencesStore
}()

err("[ocr-ablation] model loaded. \(cases.count) cases × 4 conditions = \(cases.count * 4) runs (shared engine; KV reuse handled by LlamaEngine's LCP logic). perso slider=\(personalizationStrength).")


var divACSum = 0.0   // raw → with-ocr (full enrichment effect)
var divBCSum = 0.0   // no-ocr → with-ocr (OCR-isolated effect)
var divABSum = 0.0   // raw → no-ocr (app+title+clipboard effect)
var divCDSum = 0.0   // with-ocr → with-ocr+perso (perso-isolated effect)
var divBDSum = 0.0   // no-ocr → with-ocr+perso (OCR+perso combined)
var latRawSum = 0
var latNoOCRSum = 0
var latWithOCRSum = 0
var latWithPersoSum = 0

for (idx, c) in cases.enumerated() {
    err("  → [\(idx + 1)/\(cases.count)] \(c.label) raw…")
    let rawPrompt    = buildPrompt(case: c, condition: "raw")
    let A = await run(prompt: rawPrompt, engine: engine)
    err("    no-ocr…")
    let noOCRPrompt  = buildPrompt(case: c, condition: "no-ocr")
    let B = await run(prompt: noOCRPrompt, engine: engine)
    err("    with-ocr…")
    let withOCRPrompt = buildPrompt(case: c, condition: "with-ocr")
    let C = await run(prompt: withOCRPrompt, engine: engine)
    err("    with-ocr+perso…")
    let D = await run(prompt: withOCRPrompt, engine: engine, personalizationStrength: personalizationStrength)

    let dAC = divergence(A.output, C.output)
    let dBC = divergence(B.output, C.output)
    let dAB = divergence(A.output, B.output)
    let dCD = divergence(C.output, D.output)
    let dBD = divergence(B.output, D.output)

    divACSum += dAC; divBCSum += dBC; divABSum += dAB
    divCDSum += dCD; divBDSum += dBD
    latRawSum += A.totalMs; latNoOCRSum += B.totalMs
    latWithOCRSum += C.totalMs; latWithPersoSum += D.totalMs

    let json: [String: Any] = [
        "label": c.label,
        "user_text": c.userText,
        "raw":            ["output": A.output, "ttft_ms": A.ttftMs, "total_ms": A.totalMs, "prompt_chars": rawPrompt.count],
        "no_ocr":         ["output": B.output, "ttft_ms": B.ttftMs, "total_ms": B.totalMs, "prompt_chars": noOCRPrompt.count],
        "with_ocr":       ["output": C.output, "ttft_ms": C.ttftMs, "total_ms": C.totalMs, "prompt_chars": withOCRPrompt.count],
        "with_ocr_perso": ["output": D.output, "ttft_ms": D.ttftMs, "total_ms": D.totalMs, "prompt_chars": withOCRPrompt.count],
        "div_raw_to_withocr":      dAC,
        "div_noocr_to_withocr":    dBC,
        "div_raw_to_noocr":        dAB,
        "div_withocr_to_withperso": dCD,
        "div_noocr_to_withperso":  dBD,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: json, options: []),
       let s = String(data: data, encoding: .utf8) {
        emit(s)
    }
    let dACs = String(format: "%.2f", dAC)
    let dBCs = String(format: "%.2f", dBC)
    let dCDs = String(format: "%.2f", dCD)
    err("  [\(idx + 1)/\(cases.count)] \(c.label)  d(A→C)=\(dACs) d(B→C)=\(dBCs) d(C→D)=\(dCDs)  ms[A/B/C/D]=\(A.totalMs)/\(B.totalMs)/\(C.totalMs)/\(D.totalMs)")
}

let n = Double(cases.count)
let summary = """
─────────── OCR + Perso Ablation Summary ───────────
cases:                                          \(cases.count)
corpus entries loaded:                          \(historyEntries.count)
perso slider (effective gain = ×6.0):           \(personalizationStrength)

mean divergence raw     → no-ocr:                \(String(format: "%.2f", divABSum / n))   (app+title+clipboard)
mean divergence no-ocr  → with-ocr:              \(String(format: "%.2f", divBCSum / n))   (OCR isolated ⭐)
mean divergence raw     → with-ocr:              \(String(format: "%.2f", divACSum / n))   (full enrichment)
mean divergence with-ocr → with-ocr+perso:       \(String(format: "%.2f", divCDSum / n))   (perso isolated ⭐)
mean divergence no-ocr  → with-ocr+perso:        \(String(format: "%.2f", divBDSum / n))   (OCR + perso combined)

mean total ms  raw:           \(latRawSum / cases.count)
mean total ms  no-ocr:        \(latNoOCRSum / cases.count)
mean total ms  with-ocr:      \(latWithOCRSum / cases.count)
mean total ms  with-perso:    \(latWithPersoSum / cases.count)

Reading:
  d(B→C) near 0   →  OCR adds latency without changing output → drop OCR.
  d(C→D) near 0   →  Personalization doesn't move things either → corpus
                     too small / noisy / wrong language match.
  d(C→D) > d(B→C) →  Personalization dominates OCR in your real use case.
"""
err(summary)
