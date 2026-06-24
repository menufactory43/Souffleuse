import Foundation
import SouffleuseLlama
import SouffleuseCore

// SouffleuseLoadProfile <policy>  (policy ∈ baseline | governed)
//
// Mesure EMPIRIQUE du coût de génération du ghost sur une frappe réaliste,
// à travers le vrai moteur llama.cpp (Gemma 3 1B Metal). On rejoue la SAISIE
// d'un paragraphe : à chaque mot, si le ghost affiché prédit correctement le
// mot que l'utilisateur s'apprête à taper (divergence RÉELLE du modèle, pas un
// masque), il est consommé sans générer ; sinon on re-seed. La fenêtre de
// look-ahead est rechargée selon la politique.
//
//   baseline : look-ahead long (8 mots), recharge fréquente — comportement par
//              défaut. Beaucoup de tokens générés D'AVANCE → beaucoup jetés à
//              chaque divergence.
//   governed : look-ahead court (3 mots), recharge paresseuse — moins de
//              spéculation jetée, MAIS le ghost reste affiché (fenêtre ≥ 1
//              presque tout le temps).
//
// Émet un JSON (entre <<<JSON>>> … <<<END>>>). À lancer sous `/usr/bin/time -l`
// pour capturer RSS (mémoire) + temps CPU process. Le JSON porte le coût GPU
// (somme du wall-time des generate()) + #générations + tokens générés/consommés.

// Niveau de charge à profiler. On utilise les VRAIES valeurs du gouverneur
// (LoadGovernor.lookaheadWords) → ce qu'on mesure est exactement ce qui ship.
let policyName = CommandLine.arguments.dropFirst().first ?? "nominal"
let level: LoadLevel = LoadGovernor.forcedLevel(from: policyName) ?? .nominal
struct Policy { let target: Int; let floor: Int; let step: Int }
let baseLookahead = 8   // longGhost par défaut
let policy: Policy = {
    let target = LoadGovernor.lookaheadWords(base: baseLookahead, for: level)
    return Policy(target: target, floor: max(1, target / 2), step: max(2, target / 2))
}()

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let modelPath = NSString(string: "~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf").expandingTildeInPath
let engine = LlamaEngine()
guard await engine.load(modelPath: modelPath, contextTokens: 2048) else { err("[fatal] load"); exit(1) }
await engine.setCorpus([])
let sampling = LlamaSampling(temperature: 0, repeatPenalty: 1.3, banMarkup: true, banDigitsLeading: true, banEmoji: true)

final class Sink: @unchecked Sendable { var s = "" }
func gen(_ prompt: String, words: Int) async -> (words: [String], ms: Double) {
    let sink = Sink()
    let start = Date()
    _ = await engine.generate(prompt: prompt, maxTokens: max(8, words * 5), sampling: sampling) { t in
        sink.s += t; return true
    }
    let ms = Date().timeIntervalSince(start) * 1000
    let ws = sink.s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
    return (Array(ws.prefix(words)), ms)
}

func norm(_ w: String) -> String {
    w.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
}

// Paragraphe réaliste (réponse support FR) — la "frappe" cible.
let intendedText = """
Bonjour et merci pour votre message. Nous avons bien pris en compte votre demande \
et reviendrons vers vous dans les plus brefs délais. N'hésitez pas à nous recontacter \
si vous avez la moindre question complémentaire. Je reste à votre entière disposition \
et vous souhaite une excellente journée.
"""
let seedContext = "Bonjour et "
let intended = intendedText.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
// on commence après "Bonjour et " (déjà tapé)
let startIndex = 2

var ghostQueue: [String] = []
var typedSoFar = seedContext
var genCount = 0
var wordsGenerated = 0
var wordsConsumedFromGhost = 0   // mots acceptés depuis le ghost (prédiction correcte)
var wordsDiverged = 0            // mots où le ghost s'est trompé → re-seed
var genWallMs = 0.0
var stepsWithGhostShown = 0
var totalSteps = 0

var i = startIndex
while i < intended.count {
    totalSteps += 1
    // Recharge si la fenêtre passe au/ sous le plancher.
    if ghostQueue.count <= policy.floor {
        let prompt = typedSoFar + ghostQueue.joined(separator: " ") + (ghostQueue.isEmpty ? "" : " ")
        let want = policy.target - ghostQueue.count
        let (newWords, ms) = await gen(prompt, words: max(policy.step, want))
        ghostQueue.append(contentsOf: newWords)
        genCount += 1
        wordsGenerated += newWords.count
        genWallMs += ms
    }
    if !ghostQueue.isEmpty { stepsWithGhostShown += 1 }
    let want = intended[i]
    if let head = ghostQueue.first, norm(head) == norm(want), !norm(want).isEmpty {
        // Ghost correct → l'utilisateur tape ce mot, on le consomme SANS générer.
        ghostQueue.removeFirst()
        typedSoFar += want + " "
        wordsConsumedFromGhost += 1
    } else {
        // Divergence réelle : l'utilisateur tape son propre mot, le ghost restant
        // est invalidé (on l'a généré pour rien) → re-seed à la prochaine boucle.
        typedSoFar += want + " "
        wordsDiverged += 1
        let wasted = ghostQueue.count
        wordsGenerated += 0  // déjà comptés à la génération
        _ = wasted
        ghostQueue = []
    }
    i += 1
}

let wordsTyped = intended.count - startIndex
let wasteRatio = wordsGenerated > 0 ? Double(wordsGenerated - wordsConsumedFromGhost) / Double(wordsGenerated) : 0
let ghostShownPct = totalSteps > 0 ? Double(stepsWithGhostShown) / Double(totalSteps) * 100 : 0

err("[\(policyName)] gens=\(genCount) wordsGen=\(wordsGenerated) consumed=\(wordsConsumedFromGhost) diverged=\(wordsDiverged) gpuMs=\(Int(genWallMs)) ghostShown=\(Int(ghostShownPct))%")

struct Out: Codable {
    let policy: String
    let target: Int; let floor: Int; let step: Int
    let wordsTyped: Int
    let generations: Int
    let wordsGenerated: Int
    let wordsConsumedFromGhost: Int
    let wordsDiverged: Int
    let wastedWords: Int
    let wasteRatioPct: Double
    let gpuDecodeMs: Int
    let ghostShownPct: Double
}
let out = Out(policy: policyName, target: policy.target, floor: policy.floor, step: policy.step,
              wordsTyped: wordsTyped, generations: genCount, wordsGenerated: wordsGenerated,
              wordsConsumedFromGhost: wordsConsumedFromGhost, wordsDiverged: wordsDiverged,
              wastedWords: wordsGenerated - wordsConsumedFromGhost, wasteRatioPct: wasteRatio * 100,
              gpuDecodeMs: Int(genWallMs), ghostShownPct: ghostShownPct)
let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
print("<<<JSON>>>"); print(String(data: try enc.encode(out), encoding: .utf8)!); print("<<<END>>>")
