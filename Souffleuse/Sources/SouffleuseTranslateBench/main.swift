// SouffleuseTranslateBench — Phase-0 gate for the translation HUD feature.
//
// Goal: decide, BEFORE building any UI, whether gemma-3-1b-it translates
// real Waltio support sentences (FR → EN/DE/ES/IT/JA) well enough, and what
// it costs in memory to run the instruct engine alongside the base ghost
// engine on this 8 GB machine (swap already saturated).
//
// Dev-only bench: print() is fine here (outside audit.sh SHIPPING_DIRS).
//
// Run:  swift run SouffleuseTranslateBench
// Env:  SOUFFLEUSE_IT_GGUF / SOUFFLEUSE_GGUF to override model paths.

import Foundation
import Darwin
import SouffleuseLlama
import SouffleuseCore

// ── Resident-footprint probe (phys_footprint = what the OS actually charges us)
func physFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)
    let kr = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576.0 : -1
}
func mem(_ label: String) {
    print(String(format: "  [MÉMOIRE] %-34s phys_footprint = %7.1f Mo", (label as NSString).utf8String!, physFootprintMB()))
}

final class Sink: @unchecked Sendable { var s = "" }

func expand(_ p: String) -> String { NSString(string: p).expandingTildeInPath }

let instructPath = ProcessInfo.processInfo.environment["SOUFFLEUSE_IT_GGUF"]
    .map(expand) ?? expand("~/Library/Application Support/Souffleuse/Models/gemma-3-1b-it-Q4_K_M.gguf")
let basePath = ProcessInfo.processInfo.environment["SOUFFLEUSE_GGUF"]
    .map(expand) ?? expand("~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf")

// Le prompt chat-template + la normalisation de sortie sont DOGFOODÉS depuis
// `SouffleuseCore.GemmaChatPrompt` (source unique : ce que mesure ce bench EST
// ce que `TranslationRuntime` enverra en prod).

// ── Real Waltio support sentences (numbers / names / domain terms on purpose).
let phrases: [String] = [
    "Bonjour, je comprends votre souci. Pouvez-vous vérifier que votre wallet est bien connecté avant de lancer l'export ?",
    "Vos transactions Binance manquantes apparaîtront après la synchronisation, généralement sous 24 heures.",
    "Le montant de 1 250,50 € correspond à vos plus-values imposables pour l'année 2024.",
    "Allez dans Réglages puis Export, et choisissez le format de votre administration fiscale.",
    "Le staking et les récompenses sont imposés au moment de leur réception, pas à la vente.",
    "Votre abonnement PLN100 inclut jusqu'à 100 000 transactions par déclaration.",
    "Les frais de réseau (gas) sont déductibles s'ils sont liés à une transaction imposable.",
    "Pouvez-vous m'envoyer une capture d'écran de l'erreur affichée lors de l'export PDF ?",
    "La déclaration doit être transmise avant le 31 mai, pensez à vérifier vos NFT.",
    "Je vous confirme que vos données restent stockées localement et chiffrées.",
]

let targets = TranslationTarget.allCases   // en, de, es, it, ja

// Modèle instruct DOGFOODÉ : par défaut gemma1b, override via SOUFFLEUSE_IT_MODEL
// (« qwen1_5b ») pour tester l'AUTRE template (ChatML) avec le bon GGUF — sinon
// le bench ne testait que le chemin Gemma alors que la prod tourne sur Qwen.
let instructModel = ProcessInfo.processInfo.environment["SOUFFLEUSE_IT_MODEL"]
    .flatMap(InstructModel.init(rawValue:)) ?? .gemma1b

let sampling = LlamaSampling(temperature: 0, repeatPenalty: 1.1, repeatLastN: 64)

print("════════════════════════════════════════════════════════════════════")
print(" SOUFFLEUSE — PHASE 0 GATE : qualité traduction + coût mémoire 2 modèles")
print("════════════════════════════════════════════════════════════════════")
print("  instruct : \(instructPath)")
print("  base     : \(basePath)")
mem("baseline (avant tout chargement)")

// ── 1. Charge le moteur INSTRUCT (traduction) ────────────────────────────
let action = LlamaEngine()
print("\n── Chargement du moteur instruct… ──")
guard await action.load(modelPath: instructPath, contextTokens: 1024) else {
    print("❌ LOAD INSTRUCT FAILED — vérifie le chemin / le téléchargement.")
    exit(1)
}
mem("instruct chargé (1 modèle)")

// ── 2. Traduction + qualité + TTFT/débit ─────────────────────────────────
print("\n════════════════ TRADUCTIONS (jugement humain) ════════════════")
var ttfts: [Int] = []
var toksPerSec: [Double] = []
for (i, fr) in phrases.enumerated() {
    print("\n#\(i + 1)  FR  \(fr)")
    for t in targets {
        let sink = Sink()
        let m = await action.generate(prompt: GemmaChatPrompt.translation(of: fr, into: t, model: instructModel),
                                       maxTokens: 120, sampling: sampling) { tok in
            sink.s += tok; return true
        }
        if let v = m.ttftMillis { ttfts.append(v) }
        if let v = m.tokensPerSecond { toksPerSec.append(v) }
        let ttft = m.ttftMillis.map { "\($0)ms" } ?? "—"
        let tps = m.tokensPerSecond.map { String(format: "%.0f tok/s", $0) } ?? "—"
        let v1 = t.isV1 ? "" : " (hors V1)"
        print(String(format: "    %@%@  %@   [ttft %@, %@]", t.code, v1, GemmaChatPrompt.cleanCompletion(sink.s), ttft, tps))
    }
}

func median(_ xs: [Double]) -> Double {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted(); let n = s.count
    return n % 2 == 1 ? s[n/2] : (s[n/2 - 1] + s[n/2]) / 2
}
print("\n── Perf instruct : TTFT médian \(Int(median(ttfts.map(Double.init))))ms · débit médian \(String(format: "%.0f", median(toksPerSec))) tok/s ──")

// ── 3. COEXISTENCE : charge le moteur BASE en plus (le ghost FR) ──────────
print("\n════════════════ COEXISTENCE MÉMOIRE ════════════════")
let ghost = LlamaEngine()
print("── Chargement du moteur base (ghost FR) EN PLUS de l'instruct… ──")
let baseOK = await ghost.load(modelPath: basePath, contextTokens: 1024)
if baseOK {
    mem("base + instruct chargés (2 modèles)")
    // Sanity : le ghost FR génère-t-il encore pendant que l'instruct est résident ?
    let sink = Sink()
    _ = await ghost.generate(prompt: "Merci beaucoup pour votre",
                             maxTokens: 8, sampling: LlamaSampling(temperature: 0, repeatPenalty: 1.1)) { tok in
        sink.s += tok; return true
    }
    print("  [SANITY ghost base] 'Merci beaucoup pour votre' → \(GemmaChatPrompt.cleanCompletion(sink.s).debugDescription)")
    mem("après une génération ghost (2 modèles)")
} else {
    print("❌ LOAD BASE FAILED (manque de mémoire ?) — c'est en soi un résultat du gate.")
    mem("échec chargement base (instruct seul résident)")
}

// ── 4. Décharge l'instruct → mesure le bénéfice du plan 'moteur unique' ───
print("\n════════════════ DÉCHARGEMENT INSTRUCT ════════════════")
await action.unload()
mem("instruct déchargé (base seul résident)")

print("\n════════════════════════════════════════════════════════════════════")
print(" FIN DU GATE — juge la qualité ci-dessus + compare les footprints :")
print("   • coexistence 2 modèles vs • moteur unique (swap de modelPath)")
print("════════════════════════════════════════════════════════════════════")
exit(0)
