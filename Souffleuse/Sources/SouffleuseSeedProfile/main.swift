import Foundation
import SouffleuseLlama

// SouffleuseSeedProfile — décompose le coût du SEED FROID (1er souffle d'un champ).
// 4 scénarios timés (ttft = prefill→1er token ; total = wall complet) pour
// isoler : (a) warmup Metal (compilation des kernels au 1er decode), (b) prefill
// du contexte à KV froid, (c) réutilisation KV chaude.

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
let modelPath = NSString(string: "~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf").expandingTildeInPath
let engine = LlamaEngine()
guard await engine.load(modelPath: modelPath, contextTokens: 4096) else { err("[fatal] load"); exit(1) }
await engine.setCorpus([])
let smp = LlamaSampling(temperature: 0, repeatPenalty: 1.3, banMarkup: true, banDigitsLeading: true, banEmoji: true)

final class Sink: @unchecked Sendable { var s = "" }
func run(_ prompt: String, _ label: String) async -> (ttft: Int, total: Int) {
    let sink = Sink()
    let start = Date()
    let m = await engine.generate(prompt: prompt, maxTokens: 16, sampling: smp) { t in sink.s += t; return true }
    let total = Int(Date().timeIntervalSince(start) * 1000)
    let ttft = m.ttftMillis ?? -1
    err("[\(label)] ttft=\(ttft)ms total=\(total)ms  «\(sink.s.prefix(36))»")
    return (ttft, total)
}

// Contexte réaliste ~1000 chars (beforeCursor d'un champ déjà rempli).
let ctxA = String(repeating: "Le client nous a contacté au sujet d'un remboursement non reçu sur sa commande. ", count: 12)
let ctxB = String(repeating: "Nous organisons un atelier de formation sur la fiscalité des cryptomonnaies. ", count: 12)
let tailA = "Je vous confirme que "
let tailB = "Pour préparer cette session, "

// 1) Tout froid : KV vide + Metal jamais sollicité (compilation des kernels incluse).
let r1 = await run(String(ctxA.prefix(1000)) + tailA, "1 COLD KV + COLD Metal (1er souffle absolu)")
// 2) Même prompt : KV chaud (réutilisé) + Metal chaud.
let r2 = await run(String(ctxA.prefix(1000)) + tailA, "2 WARM KV + WARM Metal (frappe soutenue)")
// 3) Contexte DIFFÉRENT : KV froid (re-prefill ~300 tokens) mais Metal chaud.
let r3 = await run(String(ctxB.prefix(1000)) + tailB, "3 COLD KV + WARM Metal (nouveau champ, moteur déjà chaud)")
// 4) Extension du prompt 3 : KV partiellement réutilisé (LCP).
let r4 = await run(String(ctxB.prefix(1000)) + tailB + "nous vous proposons ", "4 LCP reuse + WARM Metal")

let metalWarmup = max(0, r1.total - r3.total)   // 1 et 3 sont tous deux KV-froid ; l'écart ≈ warmup Metal
err("")
err("=== SYNTHÈSE ===")
err("warmup Metal (1er souffle) ≈ \(metalWarmup) ms   [r1.total \(r1.total) − r3.total \(r3.total)]")
err("prefill contexte froid (Metal chaud) ≈ \(r3.ttft) ms (ttft de r3)")
err("réutilisation KV chaude ≈ \(r2.ttft) ms (ttft de r2)")

struct Out: Codable { let coldColdTotal: Int; let warmTotal: Int; let coldKvWarmMetalTtft: Int; let warmKvTtft: Int; let lcpTtft: Int; let metalWarmupMs: Int }
let out = Out(coldColdTotal: r1.total, warmTotal: r2.total, coldKvWarmMetalTtft: r3.ttft, warmKvTtft: r2.ttft, lcpTtft: r4.ttft, metalWarmupMs: metalWarmup)
let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
print("<<<JSON>>>"); print(String(data: try enc.encode(out), encoding: .utf8)!); print("<<<END>>>")
