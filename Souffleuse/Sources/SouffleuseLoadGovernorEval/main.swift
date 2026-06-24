import Foundation
import SouffleuseLlama
import SouffleuseCore

// SouffleuseLoadGovernorEval — capture des données RÉELLES pour le rapport de
// vérification du gouverneur de charge + de la frappe continue.
//
// Émet un unique blob JSON entre les marqueurs <<<JSON>>> … <<<END>>> sur
// stdout, consommé par le générateur HTML. Tout vient de générations llama.cpp
// réelles (mêmes réglages de sampling que la production : greedy temp=0,
// repeatPenalty 1.3, bans markup/digits/emoji) — sauf le tableau de coalescence
// qui est déterministe (fonction pure du LoadGovernor, identique au test).

struct GhostSample: Codable { let prefix: String; let ghost: String; let ttftMs: Int }
struct ContinuityStep: Codable {
    let step: Int
    let typed: String          // ce que l'utilisateur a tapé/consommé cumulé
    let window: String         // le ghost affiché DEVANT le caret à cette étape
    let windowWords: Int
    let refillWords: Int       // mots regénérés à droite à cette étape (0 = seed)
}
struct CoalesceRow: Codable {
    let level: String
    let multiplier: Double
    let effectiveDebounceMs: Double
    let generationsStarted: Int
    let wastedAvoided: Int
    let workReductionPct: Double
    let lookaheadWords: Int
    let allowsWarmSkip: Bool
}
struct TTFT: Codable { let coldMs: Int; let warmMs: Int; let speedup: Double }
struct Report: Codable {
    let ghosts: [GhostSample]
    let continuity: [ContinuityStep]
    let coalescing: [CoalesceRow]
    let ttft: TTFT
    let burstKeystrokes: Int
    let interKeyMs: Double
    let baseDebounceMs: Double
}

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let modelPath = NSString(string: "~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf").expandingTildeInPath
let engine = LlamaEngine()
err("[load] \(modelPath)")
guard await engine.load(modelPath: modelPath, contextTokens: 2048) else {
    err("[fatal] model load failed"); exit(1)
}
await engine.setCorpus([])
let sampling = LlamaSampling(temperature: 0, repeatPenalty: 1.3, banMarkup: true, banDigitsLeading: true, banEmoji: true)

final class Sink: @unchecked Sendable { var s = "" }
func gen(_ prompt: String, maxTokens: Int) async -> (String, Int) {
    let sink = Sink()
    let m = await engine.generate(prompt: prompt, maxTokens: maxTokens, sampling: sampling) { t in
        sink.s += t; return true
    }
    return (sink.s, m.ttftMillis ?? -1)
}

func firstWords(_ s: String, _ n: Int) -> String {
    let parts = s.split(separator: " ", omittingEmptySubsequences: true)
    return parts.prefix(n).joined(separator: " ")
}
func wordCount(_ s: String) -> Int {
    s.split(separator: " ", omittingEmptySubsequences: true).count
}

// ── 1. Échantillons de ghost réels (qualité préservée) ───────────────────────
// Le gouverneur ne touche JAMAIS le contenu généré (timing/quantité seulement) :
// ces ghosts sont produits par le chemin de génération inchangé → ce que voit
// l'utilisateur AVANT et APRÈS le gouverneur est byte-identique. On les capture
// pour prouver l'absence de régression de qualité.
let prefixes = [
    "Bonjour, je vous remercie pour votre message et je reviens vers vous ",
    "Suite à notre échange téléphonique de ce matin, je vous confirme ",
    "N'hésitez pas à me recontacter si vous avez la moindre ",
    "Je reste à votre disposition pour ",
    "Merci beaucoup pour votre patience, nous avons bien pris en compte votre ",
]
var ghosts: [GhostSample] = []
for p in prefixes {
    let (g, ttft) = await gen(p, maxTokens: 18)
    let clean = g.trimmingCharacters(in: .whitespacesAndNewlines)
    ghosts.append(GhostSample(prefix: p, ghost: clean, ttftMs: ttft))
    err("[ghost] \(ttft)ms  \(clean.prefix(60))")
}

// ── 2. Séquence de FRAPPE CONTINUE (living ghost réel) ────────────────────────
// Seed puis 3 recharges : on consomme des mots à GAUCHE (l'utilisateur tape le
// long du ghost) et on regénère à DROITE (refill beam) pour garder la fenêtre
// pleine — la « frappe continue » : le ghost ne se vide jamais.
let TARGET_WINDOW = 8
let CONSUME_PER_STEP = 3
let base = "Je vous remercie de votre message et "
var typed = base
var (seedGhost, _) = await gen(base, maxTokens: 22)
seedGhost = seedGhost.trimmingCharacters(in: .whitespacesAndNewlines)
var window = firstWords(seedGhost, TARGET_WINDOW)
var continuity: [ContinuityStep] = []
continuity.append(ContinuityStep(step: 0, typed: typed, window: window,
                                 windowWords: wordCount(window), refillWords: 0))
err("[continuity 0] window=\(window.debugDescription)")
for step in 1...3 {
    // L'utilisateur tape (consomme) les premiers mots du ghost.
    let consumed = firstWords(window, CONSUME_PER_STEP)
    typed += consumed + " "
    var remainder = window
    // retire les mots consommés du début de la fenêtre
    let remWords = remainder.split(separator: " ").dropFirst(CONSUME_PER_STEP).joined(separator: " ")
    remainder = remWords
    // Refill : regénère depuis le texte visible complet pour recharger la fenêtre.
    let want = TARGET_WINDOW - wordCount(remainder)
    var (ext, _) = await gen(typed + remainder, maxTokens: max(6, want * 4))
    ext = ext.trimmingCharacters(in: .whitespacesAndNewlines)
    let extFirst = firstWords(ext, max(1, want))
    window = (remainder.isEmpty ? extFirst : remainder + " " + extFirst)
    continuity.append(ContinuityStep(step: step, typed: typed, window: window,
                                     windowWords: wordCount(window), refillWords: wordCount(extFirst)))
    err("[continuity \(step)] typed+=\(consumed.debugDescription) window=\(window.debugDescription)")
}

// ── 3. TTFT froid vs chaud (réutilisation KV — fondation perf) ────────────────
let longPrompt = String(repeating: "Le client a contacté le support concernant un remboursement. ", count: 6)
    + "Nous allons "
let (_, cold) = await gen(longPrompt, maxTokens: 12)   // KV froid (prefill complet)
let (_, warm) = await gen(longPrompt, maxTokens: 12)   // même prompt → KV réutilisé
let speedup = warm > 0 ? Double(cold) / Double(warm) : 0
err("[ttft] cold=\(cold)ms warm=\(warm)ms speedup=\(speedup)x")

// ── 4. Coalescence sous charge (déterministe — LoadGovernor pur) ──────────────
// Même modèle que LoadGovernorTests.generationsStarted : sur une rafale de
// frappe, combien de générations llama DÉMARRENT réellement à chaque palier.
let BURST = 20
let INTERKEY = 30.0
let BASE_DEBOUNCE = 15.0
func generationsStarted(level: LoadLevel) -> Int {
    let eff = BASE_DEBOUNCE * LoadGovernor.debounceMultiplier(for: level)
    var started = 0
    for i in 0..<BURST {
        let isLast = (i == BURST - 1)
        if isLast || INTERKEY >= eff { started += 1 }
    }
    return started
}
let nominalStarted = generationsStarted(level: .nominal)
var coalescing: [CoalesceRow] = []
for level in LoadLevel.allCases {
    let started = generationsStarted(level: level)
    let avoided = nominalStarted - started
    let reduction = nominalStarted > 0 ? Double(avoided) / Double(nominalStarted) * 100 : 0
    coalescing.append(CoalesceRow(
        level: String(describing: level),
        multiplier: LoadGovernor.debounceMultiplier(for: level),
        effectiveDebounceMs: BASE_DEBOUNCE * LoadGovernor.debounceMultiplier(for: level),
        generationsStarted: started,
        wastedAvoided: avoided,
        workReductionPct: reduction,
        lookaheadWords: LoadGovernor.lookaheadWords(base: 8, for: level),
        allowsWarmSkip: LoadGovernor.allowsWarmDebounceSkip(for: level)
    ))
}

let report = Report(
    ghosts: ghosts, continuity: continuity, coalescing: coalescing,
    ttft: TTFT(coldMs: cold, warmMs: warm, speedup: speedup),
    burstKeystrokes: BURST, interKeyMs: INTERKEY, baseDebounceMs: BASE_DEBOUNCE
)
let enc = JSONEncoder()
enc.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try enc.encode(report)
print("<<<JSON>>>")
print(String(data: data, encoding: .utf8)!)
print("<<<END>>>")
