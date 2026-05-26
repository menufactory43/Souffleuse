import Foundation
import SouffleuseLlama

let modelPath = NSString(string: "~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf").expandingTildeInPath

let engine = LlamaEngine()

let ok = await engine.load(modelPath: modelPath, contextTokens: 2048)
guard ok else {
    FileHandle.standardError.write("LOAD FAILED\n".data(using: .utf8)!)
    exit(1)
}
FileHandle.standardError.write("LOADED\n".data(using: .utf8)!)

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
