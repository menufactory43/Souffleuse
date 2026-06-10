import Foundation
import SouffleuseCore
import SouffleuseLlama
import SouffleuseLog

// ─────────────────────────────────────────────────────────────────────────────
// SouffleuseBeamAmortizedEval — coût AMORTI par frappe du beam « façon Cotypist »
// AVEC réutilisation de branche KV (le maillon manquant de SouffleuseBeamEval).
//
// SPIKE de recherche, gaté `SOUFFLEUSE_BEAM` (default OFF). L'éval froide
// (SouffleuseBeamEval) mesurait le beam RELANCÉ de zéro à chaque cas (~7.6 s/cas,
// ×16 le greedy). Mais Cotypist NE relance PAS le beam à chaque touche : il garde
// les K séquences candidates EN RÉSERVE (KV déjà décodé en profondeur) et, à la
// frappe suivante, RECYCLE la branche qui matche — avance dans du KV déjà calculé
// à coût ≈ nul. Le beam ne re-tourne en plein que sur un MISS (le char tapé
// diverge de tous les survivants).
//
// Ici on SIMULE une vraie session de frappe : on tape le préfixe, on lance le
// beam UNE fois (cold first-paint), puis on « tape » le reste du mot/phrase visé
// UN CHAR À LA FOIS via `advance(typedChar:)`. Par frappe on classe :
//   HIT    (réutilise une branche pré-calculée, ~0 decode)
//   REFILL (top-up incrémental de quelques tokens sur les survivants)
//   MISS   (re-beam complet)
// et on reporte la latence. Synthèse : cold first-paint, latence steady-state
// par frappe (médiane/p90 des hits), ratio hit/refill/miss, coût AMORTI effectif
// (temps total / nb frappes), vs le ~474 ms/frappe du greedy.
//
// Usage :
//   SOUFFLEUSE_BEAM=1 SOUFFLEUSE_GGUF=~/…/gemma-3-1b.i1-Q5_K_M.gguf \
//     swift run SouffleuseBeamAmortizedEval
// ─────────────────────────────────────────────────────────────────────────────

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let beamEnabled = (ProcessInfo.processInfo.environment["SOUFFLEUSE_BEAM"].map { !$0.isEmpty }) ?? false
if !beamEnabled {
    err("[beam-amort] SOUFFLEUSE_BEAM absent → spike désactivé. Relance avec SOUFFLEUSE_BEAM=1.")
    exit(0)
}

// Corpus : un PRÉFIXE déjà tapé (point de départ du ghost) + l'INTENTION (le
// texte que l'utilisateur compte taper ensuite, char par char). On simule la
// frappe de `intended` après `prefix`. Phrases FR réalistes, after-space + mid-mot.
struct Case { let label: String; let prefix: String; let intended: String }
let cases: [Case] = [
    .init(label: "after-space",  prefix: "Je peux vous envoyer ",           intended: "le document demain matin"),
    .init(label: "after-space",  prefix: "La réunion aura lieu ",           intended: "demain à quatorze heures"),
    .init(label: "after-space",  prefix: "Merci beaucoup pour ",            intended: "votre retour rapide"),
    .init(label: "after-space",  prefix: "Je vous confirme que ",           intended: "le rendez-vous est maintenu"),
    .init(label: "after-space",  prefix: "Bonjour, je voulais ",            intended: "savoir si vous étiez disponible"),
    .init(label: "mid-mot",      prefix: "Pouvez-vous conf",                intended: "irmer le rendez-vous"),
    .init(label: "mid-mot",      prefix: "Nous avons bien reçu votre comm", intended: "ande et la traitons"),
    .init(label: "mid-mot",      prefix: "Je reviendrai vers vous dès que poss", intended: "ible cette semaine"),
    .init(label: "mid-mot",      prefix: "Le projet avance, on livre la prem", intended: "ière version vendredi"),
    .init(label: "accord",       prefix: "Je dois finaliser mon rapport fisc", intended: "al avant la fin du mois"),
    .init(label: "accord",       prefix: "Voici le document fin",            intended: "al pour relecture"),
    .init(label: "narratif",     prefix: "Le soleil se couchait lentement derrière les coll", intended: "ines au loin"),
    .init(label: "technique",    prefix: "Pour configurer le serveur, il faut d'abord install", intended: "er les dépendances"),
    .init(label: "courrier",     prefix: "Je vous prie d'agréer, Madame, Monsieur, mes salut", intended: "ations distinguées"),
    .init(label: "quotidien",    prefix: "N'oublie pas d'acheter du pain et du ",  intended: "lait ce soir"),
]

let ggufPath = (ProcessInfo.processInfo.environment["SOUFFLEUSE_GGUF"].flatMap { $0.isEmpty ? nil : $0 }
    ?? "~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf")
let resolved = (ggufPath as NSString).expandingTildeInPath

let beamConfig = BeamConfig.fromEnvironment()

// ── Boot : beam (réutilisation) + greedy (référence par frappe) ──────────────
let beam = BeamGhostEngine(config: beamConfig)
err("[beam-amort] loading GGUF (beam, n_seq_max=\(beamConfig.maxSearchWidth + 1)): \(resolved)")
guard await beam.load(modelPath: resolved, contextTokens: 4096) else { err("FATAL: GGUF load failed (beam)"); exit(1) }

let greedy = LlamaEngine()
err("[beam-amort] loading GGUF (greedy ref): \(resolved)")
guard await greedy.load(modelPath: resolved, contextTokens: 4096) else { err("FATAL: GGUF load failed (greedy)"); exit(1) }
await greedy.setCorpus([])

func trailingPartial(_ prefix: String) -> String { OutputFilter.trailingPartialWord(prefix) }

func buildPrompt(_ prefix: String) -> String {
    LlamaPromptBuilder.buildLlamaPrompt(
        system: "", customInstr: "", ctxPrefix: "", fieldContext: "",
        afterCursor: "", beforeCursor: prefix)
}

// Une passe greedy long-ghost (≈ ce que fait le pipeline shippé À CHAQUE frappe).
func greedyGhostMs(prefix: String) async -> Int {
    final class Acc: @unchecked Sendable { var text = "" }
    let acc = Acc()
    let partial = trailingPartial(prefix)
    let t0 = Date()
    _ = await greedy.generate(
        prompt: buildPrompt(prefix), maxTokens: beamConfig.maxTokens,
        sampling: LlamaSampling(
            temperature: 0, repeatPenalty: 1.3, repeatLastN: 64, seed: 0,
            personalizationStrength: 0, banMarkup: true, banDigitsLeading: true,
            banEmoji: true, healPrefix: partial.isEmpty ? nil : partial)
    ) { piece in acc.text += piece; return true }
    return Int(Date().timeIntervalSince(t0) * 1000)
}

func f2(_ x: Double) -> String { String(format: "%.2f", x) }
func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "0%" : "\(Int(Double(a) / Double(b) * 100))%" }
func median(_ xs: [Int]) -> Int { xs.isEmpty ? 0 : xs.sorted()[xs.count / 2] }
func percentile(_ xs: [Int], _ p: Double) -> Int {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted(); let i = min(s.count - 1, Int(Double(s.count - 1) * p)); return s[i]
}

print("")
print("════════════════════════════════════════════════════════════════════════")
print(" SouffleuseBeamAmortizedEval — \(cases.count) sessions de frappe simulées")
print(" beam K=\(beamConfig.maxSearchWidth)  ·  KV branch reuse (HIT / REFILL / MISS)")
print("════════════════════════════════════════════════════════════════════════")

// Agrégats globaux.
var coldMs: [Int] = []          // latence du beam froid (1 par session + 1 par MISS)
var hitMs: [Int] = []           // latence des frappes HIT (steady-state)
var refillMs: [Int] = []
var missMs: [Int] = []
var sessionTotalMs: [Int] = []  // temps total beam d'une session
var sessionKeystrokes: [Int] = []
var nHit = 0, nRefill = 0, nMiss = 0
var greedyPerKeyMs: [Int] = []  // référence : 1 passe greedy par frappe

for c in cases {
    // ── Cold first-paint : tape le préfixe, lance le beam AVEC réserve ───────
    let partial = trailingPartial(c.prefix)
    let t0 = Date()
    let cold = await beam.ghostWithReserve(prompt: buildPrompt(c.prefix), requiredPrefix: partial)
    let coldThis = Int(Date().timeIntervalSince(t0) * 1000)
    coldMs.append(coldThis)

    var sessMs = coldThis
    var keys = 0
    var typed = c.prefix
    var lineHits = 0, lineRefill = 0, lineMiss = 0

    // ── Frappe char par char de l'intention ──────────────────────────────────
    for ch in c.intended {
        keys += 1
        // Le requiredPrefix d'un MISS = fragment de mot en cours APRÈS ce char.
        let nextTyped = typed + String(ch)
        let missPartial = trailingPartial(nextTyped)
        let a = await beam.advance(typedChar: ch, requiredPrefixForMiss: missPartial)
        sessMs += a.elapsedMillis
        switch a.kind {
        case .hit:    nHit += 1;    lineHits += 1;  hitMs.append(a.elapsedMillis)
        case .refill: nRefill += 1; lineRefill += 1; refillMs.append(a.elapsedMillis)
        case .miss:   nMiss += 1;   lineMiss += 1;  missMs.append(a.elapsedMillis); coldMs.append(a.elapsedMillis)
        }
        typed = nextTyped

        // Référence greedy : ce qu'aurait coûté UNE passe greedy à cette frappe.
        let gm = await greedyGhostMs(prefix: typed)
        greedyPerKeyMs.append(gm)
    }
    await beam.clearReserve()

    sessionTotalMs.append(sessMs)
    sessionKeystrokes.append(keys)
    let amort = keys > 0 ? sessMs / keys : sessMs

    print("")
    print("── [\(c.label)] \(c.prefix.debugDescription) + \(c.intended.debugDescription)")
    if !partial.isEmpty { print("   mid-mot, requiredPrefix = \(partial.debugDescription)") }
    print("   cold first-paint ... \(coldThis) ms   ·   ghost: \((cold.best?.ghost ?? "").debugDescription)")
    print("   frappes ............ \(keys)   HIT=\(lineHits) REFILL=\(lineRefill) MISS=\(lineMiss)")
    print("   session beam total . \(sessMs) ms   →   AMORTI \(amort) ms/frappe")
}

// ── Synthèse ─────────────────────────────────────────────────────────────────
let totalKeys = sessionKeystrokes.reduce(0, +)
let totalSessMs = sessionTotalMs.reduce(0, +)
let amortGlobal = totalKeys > 0 ? Double(totalSessMs) / Double(totalKeys) : 0
let greedyMedian = median(greedyPerKeyMs)
let greedyMean = greedyPerKeyMs.isEmpty ? 0 : greedyPerKeyMs.reduce(0, +) / greedyPerKeyMs.count

print("")
print("────────────────────────────────────────────────────────────────────────")
print(" SYNTHÈSE AMORTIE")
print("────────────────────────────────────────────────────────────────────────")
print("  Sessions ......................... \(cases.count)")
print("  Frappes totales .................. \(totalKeys)")
print("")
print("  COLD first-paint (médiane) ....... \(median(coldMs)) ms   (p90 \(percentile(coldMs, 0.9)) ms)")
print("  COLD first-paint (moyenne) ....... \(coldMs.isEmpty ? 0 : coldMs.reduce(0,+)/coldMs.count) ms")
print("")
print("  Steady-state HIT (médiane) ....... \(median(hitMs)) ms   (p90 \(percentile(hitMs, 0.9)) ms)")
print("  REFILL (médiane) ................. \(median(refillMs)) ms   (p90 \(percentile(refillMs, 0.9)) ms)")
print("  MISS / re-beam (médiane) ......... \(median(missMs)) ms   (p90 \(percentile(missMs, 0.9)) ms)")
print("")
let nSteps = nHit + nRefill + nMiss
print("  HIT    : \(nHit)  (\(pct(nHit, nSteps)))")
print("  REFILL : \(nRefill)  (\(pct(nRefill, nSteps)))")
print("  MISS   : \(nMiss)  (\(pct(nMiss, nSteps)))")
print("")
print("  ► COÛT AMORTI EFFECTIF ........... \(f2(amortGlobal)) ms/frappe")
print("    (= temps beam total \(totalSessMs) ms / \(totalKeys) frappes)")
print("")
print("  Référence GREEDY (1 passe/frappe) :")
print("    médiane .......................... \(greedyMedian) ms/frappe")
print("    moyenne .......................... \(greedyMean) ms/frappe")
print("")
let ratio = greedyMean > 0 ? amortGlobal / Double(greedyMean) : 0
if ratio > 0 {
    if ratio < 1 {
        print("  ► VERDICT : beam amorti = ×\(f2(ratio)) le greedy → \(f2((1 - ratio) * 100))% PLUS RAPIDE par frappe.")
    } else {
        print("  ► VERDICT : beam amorti = ×\(f2(ratio)) le greedy → PLUS LENT par frappe.")
    }
}
print("")

await beam.unload()
await greedy.unload()
