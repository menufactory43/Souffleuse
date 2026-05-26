import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import SouffleusePersonalization

// Souffleuse Enrichment A/B Bench (Phase 2.5.D)
//
// For each test case, generates two completions:
//   A) raw user prompt
//   B) enrichment prefix + [User text]: <user prompt>
//
// Emits JSONL on stdout with: case label, prompts, both outputs, latencies,
// token counts, and a character-level divergence score (Levenshtein normalized).
//
// Interpretation hint: the bench cannot decide if B is "better" than A — that
// requires human acceptance judgement on real typing sessions. The bench
// surfaces *whether* enrichment moves the model output at all, and at what
// latency cost. If the divergence is near 0 across cases, the enrichment
// adds latency for no behavioural change and should be reconsidered.

struct ABCase: Sendable {
    let label: String
    let app: String
    let windowTitle: String?
    let clipboard: String?
    let visible: String?
    let userText: String
}

let cases: [ABCase] = [
    ABCase(
        label: "mail-reply-fr",
        app: "com.apple.mail",
        windowTitle: "Re: Facture Q2 2026",
        clipboard: nil,
        visible: "De: Marie Dupont\nObjet: Facture Q2 2026\nBonjour, je n'ai pas reçu la facture du deuxième trimestre, peux-tu me la renvoyer ? Merci, Marie",
        userText: "Bonjour Marie,\n\nDésolé pour ce retard, je te"
    ),
    ABCase(
        label: "slack-thread-en",
        app: "com.tinyspeck.slackmacgap",
        windowTitle: "#deploy",
        clipboard: nil,
        visible: "alex: staging is down\nyou: looking now\nalex: ETA?\nyou: 5 min",
        userText: "alex it's back up, the root cause was"
    ),
    ABCase(
        label: "note-meeting-fr",
        app: "com.apple.Notes",
        windowTitle: "Réunion produit 21 mai",
        clipboard: nil,
        visible: "Réunion produit du 21 mai. Présents : Marc, Léa, Karim. Sujets abordés : onboarding, pricing, churn.",
        userText: "Action items : (1) Marc envoie le nouveau funnel onboarding avant vendredi, (2) Léa"
    ),
    ABCase(
        label: "code-comment-en",
        app: "com.microsoft.VSCode",
        windowTitle: "predictor.swift",
        clipboard: nil,
        visible: "func predict(prefix: String) async {\n    guard !prefix.isEmpty else { return }\n    let trimmed = String(prefix.suffix(2048))\n",
        userText: "    // Trim to the last 2048 characters because"
    ),
    ABCase(
        label: "clipboard-url-fr",
        app: "com.apple.Notes",
        windowTitle: "Inspirations",
        clipboard: "https://www.apple.com/fr/vision-pro/",
        visible: nil,
        userText: "À voir : Vision Pro pourrait être pertinent pour"
    ),
    ABCase(
        label: "calendar-fr",
        app: "com.apple.iCal",
        windowTitle: "Mai 2026",
        clipboard: nil,
        visible: "Lundi 19: Standup 10h\nMardi 20: 1:1 Marc 14h\nMercredi 21: Réunion produit 11h",
        userText: "Pour jeudi 22 je propose un créneau de"
    ),
    ABCase(
        label: "safari-article-fr",
        app: "com.apple.Safari",
        windowTitle: "Le Monde - Innovation",
        clipboard: nil,
        visible: "La startup parisienne Mistral AI annonce une nouvelle levée de fonds de 600M€, valorisant l'entreprise à plus de 6 milliards d'euros.",
        userText: "Cette levée confirme que l'écosystème IA français est"
    ),
    ABCase(
        label: "terminal-en",
        app: "com.mitchellh.ghostty",
        windowTitle: "zsh",
        clipboard: nil,
        visible: "$ git status\nOn branch jalon-2.5\nChanges not staged for commit:\n  modified: Sources/Souffleuse/PredictorViewModel.swift",
        userText: "git commit -m 'fix: trim suggestion at newline so"
    ),
    ABCase(
        label: "twitter-en",
        app: "com.atebits.Tweetie2",
        windowTitle: "Home",
        clipboard: nil,
        visible: "Just shipped: a local-first autocomplete engine for macOS that runs entirely on-device. No data leaves your machine.",
        userText: "love this, finally a privacy-respecting autocomplete that"
    ),
    ABCase(
        label: "obsidian-fr",
        app: "md.obsidian",
        windowTitle: "Réflexions Q2",
        clipboard: nil,
        visible: "## Hypothèse\nLe positionnement FR-first sur le marché clavier prédictif est sous-exploité.\n## Preuves\n- Cotypist en EN uniquement\n- Caret pas localisé",
        userText: "## Risques\nLe principal risque c'est"
    ),
    ABCase(
        label: "doc-spec-fr",
        app: "com.apple.iWork.Pages",
        windowTitle: "Spec ContextEnricher",
        clipboard: nil,
        visible: "Section 3.2 ContextEnricher. Rôle : ajouter des signaux contextuels au-delà du texte brut. Tout est opt-in, tout est local.",
        userText: "Cette section précise que les sources sont"
    ),
    ABCase(
        label: "reminders-fr",
        app: "com.apple.reminders",
        windowTitle: "Courses",
        clipboard: nil,
        visible: "✓ Pain\n✓ Lait\n☐ Tomates\n☐ Mozzarella",
        userText: "Ajouter aussi"
    ),
    ABCase(
        label: "messages-fr",
        app: "com.apple.MobileSMS",
        windowTitle: "Camille",
        clipboard: nil,
        visible: "Camille: On se voit ce soir ?\nMoi: oui avec plaisir, on dit où ?\nCamille: Le bar habituel ?",
        userText: "ok parfait je te rejoins vers"
    ),
    ABCase(
        label: "github-pr-en",
        app: "com.apple.Safari",
        windowTitle: "PR #42: Add ContextEnricher",
        clipboard: nil,
        visible: "This PR adds the ContextEnricher actor described in ARCHITECTURE.md §3.2. Three sources: app metadata, clipboard, screen OCR.",
        userText: "Looks good! Two questions: (1) what happens if"
    ),
    ABCase(
        label: "linkedin-en",
        app: "com.apple.Safari",
        windowTitle: "LinkedIn",
        clipboard: nil,
        visible: "Excited to announce I'm joining Apple as a Machine Learning Engineer on the on-device intelligence team.",
        userText: "Congrats! Curious to see what you'll be"
    ),
    ABCase(
        label: "notion-en",
        app: "notion.id",
        windowTitle: "Roadmap Q3",
        clipboard: nil,
        visible: "Q3 priorities: 1) Multi-language model selection 2) KV cache cross-keystroke 3) Electron app fallback via OCR",
        userText: "Adding a fourth priority: improving the"
    ),
    ABCase(
        label: "discord-fr",
        app: "com.hnc.Discord",
        windowTitle: "#dev-mlx",
        clipboard: nil,
        visible: "alice: quelqu'un a essayé Gemma 3 4B sur M1 base ?\nbob: oui c'est lent, 15 tok/s\nalice: ok je reste sur 1B alors",
        userText: "Yo, j'ai bench le 1B chez moi, j'ai eu"
    ),
    ABCase(
        label: "figma-en",
        app: "com.figma.Desktop",
        windowTitle: "Souffleuse onboarding",
        clipboard: nil,
        visible: "Onboarding step 2 of 3: Grant Accessibility permission. Souffleuse needs this to read text from the focused field.",
        userText: "Let's add a sub-line explaining that no text"
    ),
    ABCase(
        label: "blank-context-fr",
        app: "com.apple.TextEdit",
        windowTitle: nil,
        clipboard: nil,
        visible: nil,
        userText: "Bonjour Marie, je te confirme notre rendez-vous de demain 14h. Je"
    ),
    ABCase(
        label: "ambiguous-en",
        app: "com.apple.Notes",
        windowTitle: "Random",
        clipboard: nil,
        visible: nil,
        userText: "The thing about distributed systems is that"
    ),
]

func enrichmentPrefix(_ c: ABCase) -> String {
    var lines: [String] = []
    if let title = c.windowTitle, !title.isEmpty {
        lines.append("[App: \(c.app) | Window: \"\(title)\"]")
    } else {
        lines.append("[App: \(c.app)]")
    }
    if let clip = c.clipboard, !clip.isEmpty {
        lines.append("[Clipboard excerpt: \(clip)]")
    }
    if let vis = c.visible, !vis.isEmpty {
        let truncated = vis.count > 500 ? String(vis.prefix(500)) + "…" : vis
        lines.append("[Visible context: \(truncated))]")
    }
    return lines.joined(separator: "\n") + "\n[User text]: "
}

struct RunResult {
    let output: String
    let ttftMs: Int
    let totalMs: Int
    let tokens: Int
}

func runOne(prompt: String, on container: ModelContainer) async -> RunResult? {
    let start = Date()
    do {
        return try await container.perform { context -> RunResult in
            let input = try await context.processor.prepare(input: .init(prompt: .text(prompt)))
            let params = GenerateParameters(maxTokens: 16, temperature: 0.4, topP: 0.9)
            let stream = try MLXLMCommon.generate(input: input, parameters: params, context: context)
            var firstTokenAt: Date?
            var generated = ""
            var tokenCount = 0
            for await event in stream {
                if case .chunk(let text) = event {
                    if firstTokenAt == nil { firstTokenAt = Date() }
                    tokenCount += 1
                    generated += text
                }
            }
            let now = Date()
            let ttft = firstTokenAt.map { Int($0.timeIntervalSince(start) * 1000) } ?? -1
            let total = Int(now.timeIntervalSince(start) * 1000)
            // Production rule: ghost text is single-line, so truncate at \n.
            let oneLine = generated.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? generated
            return RunResult(output: oneLine, ttftMs: ttft, totalMs: total, tokens: tokenCount)
        }
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        return nil
    }
}

func divergence(_ a: String, _ b: String) -> Double {
    if a == b { return 0.0 }
    if a.isEmpty || b.isEmpty { return 1.0 }
    let aChars = Array(a)
    let bChars = Array(b)
    let m = aChars.count
    let n = bChars.count
    var prev = Array(0...n)
    var curr = Array(repeating: 0, count: n + 1)
    for i in 1...m {
        curr[0] = i
        for j in 1...n {
            let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
            curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
        }
        swap(&prev, &curr)
    }
    return Double(prev[n]) / Double(max(m, n))
}

@Sendable func writeLine(_ s: String) {
    FileHandle.standardOutput.write(Data((s + "\n").utf8))
}

setbuf(stdout, nil)
setbuf(stderr, nil)

let args = CommandLine.arguments
let personalizationMode = args.contains("--personalization-ab")

let modelId = "mlx-community/gemma-3-1b-pt-4bit"
let configuration = ModelConfiguration(id: modelId, defaultPrompt: "")
MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)

FileHandle.standardError.write(Data("[A/B bench] loading \(modelId)…\n".utf8))
let container: ModelContainer
do {
    container = try await LLMModelFactory.shared.loadContainer(configuration: configuration) { _ in }
} catch {
    FileHandle.standardError.write(Data("model load failed: \(error)\n".utf8))
    exit(1)
}
FileHandle.standardError.write(Data("[A/B bench] model ready, running \(cases.count) cases × 2…\n".utf8))

// MARK: - Personalization A/B
//
// `--personalization-ab` flag : alternative bench that compares stock generation
// vs generation biased by an n-gram model prepopulated with a synthetic FR
// corpus. The corpus is intentionally aligned with the bench cases so the
// bias has something to vote for (otherwise the n-gram model is empty and
// the bias is a no-op).

let synthFRCorpus: [String] = [
    "Bonjour Marie, désolé pour ce retard, je te confirme la réception du document.",
    "Bonjour Marie, je te confirme notre rendez-vous de demain 14h.",
    "Bonjour Marie, je te renvoie la facture dès que possible.",
    "Action items : Marc envoie le funnel, Léa relit le brief, Karim chiffre l'option B.",
    "À voir : Vision Pro pourrait être pertinent pour le prototype de prévisualisation.",
    "Pour jeudi 22 je propose un créneau de 14h à 15h dans mon agenda.",
    "Cette levée confirme que l'écosystème IA français est en accélération nette.",
    "ok parfait je te rejoins vers 19h30 au bar habituel.",
    "Le principal risque c'est de sous-estimer la complexité du portage Windows.",
    "Ajouter aussi : tomates cerises, basilic frais, mozzarella di bufala.",
    "Cette section précise que les sources sont strictement opt-in et locales.",
    "Yo, j'ai bench le 1B chez moi, j'ai eu environ 22 tokens par seconde sur M2.",
]

func runWithBias(prompt: String, bias: NgramLogitBias, on container: ModelContainer) async -> RunResult? {
    let start = Date()
    do {
        return try await container.perform { context -> RunResult in
            let input = try await context.processor.prepare(input: .init(prompt: .text(prompt)))
            let params = GenerateParameters(maxTokens: 16, temperature: 0.4, topP: 0.9)
            let iterator = try TokenIterator(
                input: input,
                model: context.model,
                processor: bias,
                sampler: params.sampler(),
                maxTokens: 16
            )
            let stream = MLXLMCommon.generate(input: input, context: context, iterator: iterator)
            var firstTokenAt: Date?
            var generated = ""
            var tokenCount = 0
            for await event in stream {
                if case .chunk(let text) = event {
                    if firstTokenAt == nil { firstTokenAt = Date() }
                    tokenCount += 1
                    generated += text
                }
            }
            let now = Date()
            let ttft = firstTokenAt.map { Int($0.timeIntervalSince(start) * 1000) } ?? -1
            let total = Int(now.timeIntervalSince(start) * 1000)
            let oneLine = generated.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? generated
            return RunResult(output: oneLine, ttftMs: ttft, totalMs: total, tokens: tokenCount)
        }
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        return nil
    }
}

if personalizationMode {
    FileHandle.standardError.write(Data("[A/B bench] personalization mode: priming n-gram with \(synthFRCorpus.count) synthetic FR sentences…\n".utf8))
    let model = NgramModel()
    await container.perform { context in
        await model.setTokenizerTag(modelId)
        for s in synthFRCorpus {
            let tokens = context.tokenizer.encode(text: s)
            await model.ingest(tokens: tokens)
        }
    }
    let snapshot = await model.snapshot()
    FileHandle.standardError.write(Data("[A/B bench] running \(cases.count) cases × 2 (without bias / with bias strength=1.5)…\n".utf8))

    var divergenceSum = 0.0
    var biasChanged = 0
    for (idx, c) in cases.enumerated() {
        let withoutPrompt = c.userText
        guard let a = await runOne(prompt: withoutPrompt, on: container) else { continue }
        let bias = NgramLogitBias(snapshot: snapshot, strength: 1.5)
        guard let b = await runWithBias(prompt: withoutPrompt, bias: bias, on: container) else { continue }
        let div = divergence(a.output, b.output)
        divergenceSum += div
        if div > 0.05 { biasChanged += 1 }
        let json: [String: Any] = [
            "label": c.label,
            "user_text": c.userText,
            "without_bias": [
                "output": a.output, "ttft_ms": a.ttftMs, "total_ms": a.totalMs, "tokens": a.tokens,
            ],
            "with_bias": [
                "output": b.output, "ttft_ms": b.ttftMs, "total_ms": b.totalMs, "tokens": b.tokens,
            ],
            "divergence": div,
            "latency_delta_ms": b.totalMs - a.totalMs,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: []),
           let line = String(data: data, encoding: .utf8) {
            writeLine(line)
        }
        FileHandle.standardError.write(Data(
            "  [\(idx + 1)/\(cases.count)] \(c.label): div=\(String(format: "%.2f", div)) Δlat=\(b.totalMs - a.totalMs)ms\n".utf8
        ))
    }

    let n = Double(cases.count)
    let pctChanged = Double(biasChanged) / n * 100
    let summary = """
    ──────── Personalization Summary ────────
    cases:                  \(cases.count)
    mean divergence:        \(String(format: "%.2f", divergenceSum / n))
    cases where bias moved: \(biasChanged) / \(cases.count) (\(String(format: "%.0f", pctChanged))%)

    Validation criterion (PLAN.md): ≥5pp delta acceptation.
    Proxy used here: % of cases where the biased output diverges by >5% chars.
    """
    FileHandle.standardError.write(Data((summary + "\n").utf8))
    exit(0)
}

var divergenceSum = 0.0
var latencyDeltaSum = 0
var emptyEnriched = 0

for (idx, c) in cases.enumerated() {
    let withoutPrompt = c.userText
    let withPrompt = enrichmentPrefix(c) + c.userText
    guard let a = await runOne(prompt: withoutPrompt, on: container) else { continue }
    guard let b = await runOne(prompt: withPrompt, on: container) else { continue }

    let div = divergence(a.output, b.output)
    let latencyDelta = b.totalMs - a.totalMs
    divergenceSum += div
    latencyDeltaSum += latencyDelta
    if b.output.isEmpty { emptyEnriched += 1 }

    let json: [String: Any] = [
        "label": c.label,
        "app": c.app,
        "user_text": c.userText,
        "without": [
            "output": a.output, "ttft_ms": a.ttftMs, "total_ms": a.totalMs, "tokens": a.tokens,
        ],
        "with": [
            "output": b.output, "ttft_ms": b.ttftMs, "total_ms": b.totalMs, "tokens": b.tokens,
            "prefix_chars": enrichmentPrefix(c).count,
        ],
        "divergence": div,
        "latency_delta_ms": latencyDelta,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: json, options: []),
       let line = String(data: data, encoding: .utf8) {
        writeLine(line)
    }
    FileHandle.standardError.write(Data(
        "  [\(idx + 1)/\(cases.count)] \(c.label): div=\(String(format: "%.2f", div)) Δlat=\(latencyDelta)ms\n".utf8
    ))
}

let n = Double(cases.count)
let summary = """
──────── Summary ────────
cases:               \(cases.count)
mean divergence:     \(String(format: "%.2f", divergenceSum / n)) (0=identical, 1=fully different)
mean Δlatency:       \(latencyDeltaSum / cases.count) ms (enriched − raw)
empty enriched:      \(emptyEnriched) / \(cases.count)

"""
FileHandle.standardError.write(Data(summary.utf8))
