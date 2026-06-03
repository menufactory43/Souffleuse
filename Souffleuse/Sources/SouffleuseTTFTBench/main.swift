// Throwaway TTFT harness : mesure le vrai chemin ghost (llama.cpp Metal) pour
// comparer Debug vs Release. `LlamaEngine.generate` renvoie déjà `ttftMillis` +
// `tokensPerSecond` ; on charge le modèle, on warm-up, puis on génère sur une
// série de prompts DISTINCTS (= requêtes predict réalistes, pas de réutilisation
// KV triviale) et on agrège. stderr pour les diagnostics, stdout pour le tableau.
import Foundation
import SouffleuseLlama

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let modelPath = NSString(string: "~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf").expandingTildeInPath

let engine = LlamaEngine()
guard await engine.load(modelPath: modelPath, contextTokens: 2048) else {
    err("LOAD FAILED — \(modelPath)")
    exit(1)
}
err("LOADED")

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
final class Sink: @unchecked Sendable { var n = 0 }
_ = await engine.generate(prompt: prompts[0], maxTokens: 8, sampling: sampling) { _ in true }
err("WARMED")

var ttfts: [Int] = []
var tpss: [Double] = []
let runs = 3  // chaque prompt généré `runs` fois → moyenne stable

for r in 0..<runs {
    for p in prompts {
        // Préfixe unique par run pour éviter une réutilisation KV qui fausserait
        // le TTFT (on veut le coût d'un prefill, pas d'un cache hit parfait).
        let prompt = r == 0 ? p : "\(p) (\(r))"
        let m = await engine.generate(prompt: prompt, maxTokens: 12, sampling: sampling) { _ in true }
        if let t = m.ttftMillis { ttfts.append(t) }
        if let tps = m.tokensPerSecond { tpss.append(tps) }
    }
}

func stats(_ xs: [Int]) -> (min: Int, med: Int, avg: Int, max: Int) {
    let s = xs.sorted()
    let avg = xs.reduce(0, +) / max(1, xs.count)
    return (s.first ?? 0, s[s.count / 2], avg, s.last ?? 0)
}

let config: String
#if DEBUG
config = "DEBUG (-Onone)"
#else
config = "RELEASE (-O)"
#endif

let t = stats(ttfts)
let avgTps = tpss.isEmpty ? 0 : tpss.reduce(0, +) / Double(tpss.count)

print("")
print("════════════════════════════════════════════")
print(" TTFT bench · \(config) · n=\(ttfts.count)")
print("════════════════════════════════════════════")
print(" TTFT   min \(t.min) · med \(t.med) · avg \(t.avg) · max \(t.max)  ms")
print(String(format: " tok/s  avg %.1f", avgTps))
print("════════════════════════════════════════════")
