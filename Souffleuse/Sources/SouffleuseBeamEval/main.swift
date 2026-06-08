import Foundation
import SouffleuseCore
import SouffleuseLlama
import SouffleuseLog

// ─────────────────────────────────────────────────────────────────────────────
// SouffleuseBeamEval — beam « façon Cotypist » vs greedy long-ghost actuel.
//
// SPIKE de recherche, gaté `SOUFFLEUSE_BEAM` (default OFF). Compare, sur un même
// GGUF (gemma-3-1b base/pt) et un même prompt (`LlamaPromptBuilder.buildLlamaPrompt`,
// beforeCursor = préfixe) :
//   (a) la passe greedy long-ghost ACTUELLE  (temp 0, repeatPenalty 1.3,
//       healPrefix = fragment mid-mot),
//   (b) le nouveau BeamGhostEngine            (K=9, déterministe, log-prob,
//       requiredPrefix mid-mot, pruning top-K).
//
// Pour chaque cas : les deux ghosts côte à côte + le top-3 du beam avec leur
// totalLogprob. Synthèse : où le beam diffère, et s'il corrige les modes
// d'échec connus (accord « fiscaux »→« fiscal », boucles d'écho, cohérence
// mid-mot). Latence beam vs greedy reportée par cas.
//
// Usage :
//   SOUFFLEUSE_BEAM=1 SOUFFLEUSE_GGUF=~/…/gemma-3-1b.i1-Q5_K_M.gguf \
//     swift run SouffleuseBeamEval
//   (knobs : SOUFFLEUSE_BEAM_EXP=<double> SOUFFLEUSE_BEAM_K=<int>)
// ─────────────────────────────────────────────────────────────────────────────

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// Flag-gate dur : sans SOUFFLEUSE_BEAM, l'éval ne lance PAS le beam (le moteur
// expérimental ne doit jamais tourner « par accident »).
let beamEnabled = (ProcessInfo.processInfo.environment["SOUFFLEUSE_BEAM"].map { !$0.isEmpty }) ?? false
if !beamEnabled {
    err("[beam] SOUFFLEUSE_BEAM absent → spike désactivé. Relance avec SOUFFLEUSE_BEAM=1.")
    exit(0)
}

// Corpus réaliste FR : après-espace, mid-mot, le piège d'accord et l'écho-prone.
struct Case { let label: String; let prefix: String }
let cases: [Case] = [
    // — après-espace (décodage libre) —
    .init(label: "après-espace", prefix: "Je peux vous envoyer "),
    .init(label: "après-espace", prefix: "La réunion aura lieu "),
    .init(label: "après-espace", prefix: "Merci beaucoup pour "),
    .init(label: "après-espace", prefix: "Je vous confirme que "),
    // — mid-mot (requiredPrefix) —
    .init(label: "mid-mot", prefix: "Pouvez-vous conf"),
    .init(label: "mid-mot", prefix: "Je reviendrai vers vous dès que poss"),
    .init(label: "mid-mot", prefix: "Nous avons bien reçu votre command"),
    .init(label: "mid-mot", prefix: "Le projet avance, on livre la prem"),
    .init(label: "mid-mot", prefix: "Je suis un fan de la technologie et des voitures électr"),
    .init(label: "mid-mot", prefix: "Bonjour, je vous remercie pour votre message. Je revie"),
    // — PIÈGE d'accord (le greedy dérive « fiscaux » au lieu de « fiscal ») —
    .init(label: "accord", prefix: "Je dois finaliser mon rapport fisca"),
    .init(label: "accord", prefix: "Voici le document fina"),
    .init(label: "accord", prefix: "C'est une décision import"),
    // — ÉCHO-prone (le greedy reboucle sur le tail) —
    .init(label: "écho", prefix: "je cherche à savoir si la radioactivité est un dan"),
    .init(label: "écho", prefix: "Le chat dort sur le canapé. Le chat dort sur le canapé pendant que le chat dor"),
    .init(label: "écho", prefix: "Il faut acheter du pain, du lait, des œufs, du beurre, du pain, du lait et du beu"),
    .init(label: "écho", prefix: "Merci pour votre patience. Nous vous remercions encore une fois pour votre pati"),
    // — narratif / technique (cohérence générale) —
    .init(label: "narratif", prefix: "Le soleil se couchait lentement derrière les collines tandis que les oiseaux reg"),
    .init(label: "technique", prefix: "Pour configurer le serveur, il faut d'abord installer les dépendances puis lan"),
    .init(label: "technique", prefix: "La fonction prend en entrée un tableau d'entiers et retourne la somme des élé"),
]

let ggufPath = (ProcessInfo.processInfo.environment["SOUFFLEUSE_GGUF"].flatMap { $0.isEmpty ? nil : $0 }
    ?? "~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf")
let resolved = (ggufPath as NSString).expandingTildeInPath

let beamConfig = BeamConfig.fromEnvironment()

// ── Boot des deux moteurs ────────────────────────────────────────────────────
let greedy = LlamaEngine()
err("[beam] loading GGUF (greedy): \(resolved)")
guard await greedy.load(modelPath: resolved, contextTokens: 4096) else { err("FATAL: GGUF load failed (greedy)"); exit(1) }
await greedy.setCorpus([])

let beam = BeamGhostEngine(config: beamConfig)
err("[beam] loading GGUF (beam, n_seq_max=\(beamConfig.maxSearchWidth + 1)): \(resolved)")
guard await beam.load(modelPath: resolved, contextTokens: 4096) else { err("FATAL: GGUF load failed (beam)"); exit(1) }

// Détecte le fragment de mot mid-mot (réutilise l'helper de prod).
func trailingPartial(_ prefix: String) -> String { OutputFilter.trailingPartialWord(prefix) }

// (a) Greedy long-ghost FIDÈLE à ModelRuntime.
func greedyGhost(prefix: String, partial: String) async -> (text: String, ms: Int) {
    final class Acc: @unchecked Sendable { var text = "" }
    let acc = Acc()
    let prompt = LlamaPromptBuilder.buildLlamaPrompt(
        system: "", customInstr: "", ctxPrefix: "", fieldContext: "",
        afterCursor: "", beforeCursor: prefix)
    let t0 = Date()
    _ = await greedy.generate(
        prompt: prompt, maxTokens: beamConfig.maxTokens,
        sampling: LlamaSampling(
            temperature: 0, repeatPenalty: 1.3, repeatLastN: 64, seed: 0,
            personalizationStrength: 0, banMarkup: true, banDigitsLeading: true,
            banEmoji: true, healPrefix: partial.isEmpty ? nil : partial)
    ) { piece in acc.text += piece; return true }
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    let line = acc.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? acc.text
    return (line, ms)
}

// (b) Beam : MÊME prompt, requiredPrefix = fragment mid-mot.
func beamGhost(prefix: String, partial: String) async -> BeamResult {
    let prompt = LlamaPromptBuilder.buildLlamaPrompt(
        system: "", customInstr: "", ctxPrefix: "", fieldContext: "",
        afterCursor: "", beforeCursor: prefix)
    return await beam.ghost(prompt: prompt, requiredPrefix: partial)
}

func f2(_ x: Double) -> String { String(format: "%.2f", x) }

print("")
print("════════════════════════════════════════════════════════════════════════")
print(" SouffleuseBeamEval — \(cases.count) cas · BEAM K=\(beamConfig.maxSearchWidth) exp=\(beamConfig.positionExponent) minP=\(beamConfig.minBranchProbability)")
print(" greedy = long-ghost actuel (temp0, rp1.3, heal)   |   beam = multi-seq Cotypist-style")
print("════════════════════════════════════════════════════════════════════════")

var greedyMsTotal = 0, beamMsTotal = 0
var diffs = 0

struct Logged { let label: String; let prefix: String; let greedy: String; let beam: String }
var logged: [Logged] = []

for c in cases {
    let partial = trailingPartial(c.prefix)
    let g = await greedyGhost(prefix: c.prefix, partial: partial)
    let b = await beamGhost(prefix: c.prefix, partial: partial)
    greedyMsTotal += g.ms
    beamMsTotal += b.elapsedMillis
    let bBest = b.best?.ghost ?? ""
    if bBest.trimmingCharacters(in: .whitespaces) != g.text.trimmingCharacters(in: .whitespaces) { diffs += 1 }
    logged.append(Logged(label: c.label, prefix: c.prefix, greedy: g.text, beam: bBest))

    print("")
    print("── [\(c.label)] \(c.prefix.debugDescription)")
    if !partial.isEmpty { print("   mid-mot, requiredPrefix = \(partial.debugDescription)") }
    print("   greedy : \(g.text.debugDescription)   (\(g.ms) ms)")
    print("   beam   : \(bBest.debugDescription)   (\(b.elapsedMillis) ms)")
    if b.candidates.isEmpty {
        print("   beam top-3 : (aucun candidat survivant)")
    } else {
        print("   beam top-3 :")
        for (i, cand) in b.candidates.prefix(3).enumerated() {
            print("     #\(i + 1)  totalLogprob=\(f2(cand.totalLogprob))  score=\(f2(cand.score))  tok=\(cand.tokenCount)  \(cand.ghost.debugDescription)")
        }
    }
}

print("")
print("────────────────────────────────────────────────────────────────────────")
print(" SYNTHÈSE")
print("────────────────────────────────────────────────────────────────────────")
print("  Cas testés ................ \(cases.count)")
print("  Beam ≠ greedy ............. \(diffs)  (\(Int(Double(diffs)/Double(cases.count)*100))%)")
print("  Latence moy. greedy ....... \(greedyMsTotal / max(1, cases.count)) ms/cas")
print("  Latence moy. beam ......... \(beamMsTotal / max(1, cases.count)) ms/cas")
print("  Surcoût beam .............. ×\(f2(Double(beamMsTotal) / Double(max(1, greedyMsTotal))))")
print("")
print("  PIÈGES CONNUS (lecture qualitative) :")
for l in logged where ["accord", "écho"].contains(l.label) {
    print("    [\(l.label)] …\(String(l.prefix.suffix(34)))")
    print("        greedy: \(l.greedy.debugDescription)")
    print("        beam  : \(l.beam.debugDescription)")
}
print("")

await greedy.unload()
await beam.unload()
