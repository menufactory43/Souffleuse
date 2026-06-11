// Throwaway TTFT harness : mesure le vrai chemin ghost (llama.cpp Metal).
//
// Trois phases pour quantifier l'impact du container MLX que
// `ModelRuntime.loadModel` charge « pour le tokenizer n-gram » alors que plus
// aucun code ne le consomme (constat 11/06) :
//   A — llama seul (baseline)
//   B — générations PENDANT le chargement du container MLX (scénario réveil :
//       l'idle-unload a tout déchargé, le 1er predict part pendant le reload)
//   C — container MLX résident (steady-state : pression mémoire unifiée)
// `LlamaEngine.generate` renvoie déjà `ttftMillis` + `tokensPerSecond` ; chaque
// prompt est préfixé d'un tag de phase pour forcer un prefill réel (le KV reuse
// est prefix-based — un tag en tête invalide tout le préfixe).
// stderr pour les diagnostics, stdout pour le tableau.
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import SouffleuseLlama

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

/// Empreinte mémoire physique réelle du process (la métrique d'Activity
/// Monitor), en MB. −1 si la lecture mach échoue.
func physFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return -1 }
    return Double(info.phys_footprint) / 1_048_576
}

let modelPath = NSString(string: "~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf").expandingTildeInPath

let engine = LlamaEngine()
guard await engine.load(modelPath: modelPath, contextTokens: 2048) else {
    err("LOAD FAILED — \(modelPath)")
    exit(1)
}
err("LOADED · footprint \(Int(physFootprintMB())) MB")

// Prompts distincts façon « frappe quotidienne » — chacun force un prefill réel.
let prompts = [
    "Bonjour, je vous écris pour vous informer que",
    "Merci beaucoup pour votre retour rapide, je vais",
    "Comme convenu lors de notre dernier échange, nous allons",
    "Je reviens vers vous concernant le dossier que nous avons",
    "Pourriez-vous me confirmer la disponibilité du créneau de",
    "Suite à votre demande, j'ai le plaisir de vous",
    "N'hésitez pas à me recontacter si vous avez la moindre",
    "Je vous remercie par avance pour votre",
]

let sampling = LlamaSampling(temperature: 0, repeatPenalty: 1.1)

// Warm-up : premier prefill + init Metal pipeline, jamais compté.
_ = await engine.generate(prompt: prompts[0], maxTokens: 8, sampling: sampling) { _ in true }
err("WARMED")

struct PhaseResult {
    var ttfts: [Int] = []
    var tpss: [Double] = []
}

/// Une passe complète : `runs` × les 8 prompts, tag de phase EN TÊTE pour
/// invalider le préfixe KV (prefill réel à chaque génération).
func measure(tag: String, runs: Int = 3) async -> PhaseResult {
    var result = PhaseResult()
    for r in 0..<runs {
        for (i, p) in prompts.enumerated() {
            let prompt = "(\(tag)\(r)\(i)) \(p)"
            let m = await engine.generate(prompt: prompt, maxTokens: 24, sampling: sampling) { _ in true }
            if let t = m.ttftMillis { result.ttfts.append(t) }
            if let tps = m.tokensPerSecond { result.tpss.append(tps) }
        }
    }
    return result
}

func stats(_ xs: [Int]) -> (min: Int, med: Int, avg: Int, max: Int) {
    let s = xs.sorted()
    let avg = xs.reduce(0, +) / max(1, xs.count)
    return (s.first ?? 0, s[s.count / 2], avg, s.last ?? 0)
}

func tpsAvg(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }

// ── PHASE A — llama seul (baseline) ─────────────────────────────────────────
err("PHASE A — llama seul…")
let footBeforeMLX = physFootprintMB()
let phaseA = await measure(tag: "A")

// ── PHASE B — générations PENDANT le chargement MLX (réveil) ────────────────
// Reproduit ModelRuntime.loadModel : même cacheLimit, même modelId par défaut.
err("PHASE B — générations pendant le chargement MLX…")
MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
let mlxLoadStart = Date()
let mlxLoadTask = Task {
    let configuration = ModelConfiguration(id: "mlx-community/gemma-3-1b-pt-4bit", defaultPrompt: "")
    return try? await LLMModelFactory.shared.loadContainer(configuration: configuration) { _ in }
}
// 1 run (8 prompts) lancé immédiatement — la fenêtre du vrai premier ghost.
let phaseB = await measure(tag: "B", runs: 1)
let container = await mlxLoadTask.value
let mlxLoadSec = Date().timeIntervalSince(mlxLoadStart)
let footAfterMLX = physFootprintMB()
err("MLX chargé en \(String(format: "%.1f", mlxLoadSec)) s · container \(container == nil ? "NIL" : "ok")")

// ── PHASE C — container MLX résident (steady-state) ─────────────────────────
err("PHASE C — MLX résident…")
let phaseC = await measure(tag: "C")
// Le container doit rester vivant pendant toute la phase C.
withExtendedLifetime(container) {}

let config: String
#if DEBUG
config = "DEBUG (-Onone)"
#else
config = "RELEASE (-O)"
#endif

print("")
print("══════════════════════════════════════════════════════════")
print(" TTFT bench · \(config)")
print("══════════════════════════════════════════════════════════")
for (label, ph) in [("A llama seul     ", phaseA), ("B pendant load MLX", phaseB), ("C MLX résident   ", phaseC)] {
    let t = stats(ph.ttfts)
    print(" \(label) n=\(ph.ttfts.count)  TTFT min \(t.min) · med \(t.med) · avg \(t.avg) · max \(t.max) ms · \(String(format: "%.1f", tpsAvg(ph.tpss))) tok/s")
}
print(" ──")
print(" MLX load : \(String(format: "%.1f", mlxLoadSec)) s · footprint \(Int(footBeforeMLX)) → \(Int(footAfterMLX)) MB (Δ \(Int(footAfterMLX - footBeforeMLX)) MB)")
print("══════════════════════════════════════════════════════════")
