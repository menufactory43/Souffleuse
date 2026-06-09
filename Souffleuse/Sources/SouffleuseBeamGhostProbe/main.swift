import Foundation
import SouffleuseCore
import SouffleuseLlama
import SouffleuseTyping

// ─────────────────────────────────────────────────────────────────────────────
// SouffleuseBeamGhostProbe — la « génération fraîche glissante » du cœur beam.
//
// À CHAQUE frappe (préfixe croissant) on REGÉNÈRE une fenêtre de quelques mots
// DEPUIS tout le texte tapé, qui glisse en avant. Pas de réserve/reuse : c'est le
// comportement exact de `ModelRuntime.generateGhostBeam` reproduit ICI via le
// shaper PARTAGÉ `BeamGhostShaper` (SouffleuseCore), le SEUL chemin de mise en
// forme. Le pipeline par préfixe :
//   G2 (sentenceArmed) → beamConfigChoice (requiredPrefix + largeur)
//   → BeamGhostShaper.buildPrompt → beam.ghost → beamPostFilter.
//
// SANS corpus, SANS Keychain, SANS perso : on n'instancie NI `TypingHistoryStore`
// NI rien de SouffleusePersonalization ; le beam tourne sur le GGUF seul
// (personalizationStrength implicite 0). Le contexte (customInstr/ctxPrefix) est
// vide ici — on isole la qualité LLM pure de la fenêtre glissante.
//
// Usage :
//   swift run -c release SouffleuseBeamGhostProbe
//   SOUFFLEUSE_BEAM_EXP=0.7 PROBE_MAXWORDS=4 swift run -c release SouffleuseBeamGhostProbe
//   PROBE_SWEEP=1 swift run -c release SouffleuseBeamGhostProbe   # balayage exp × maxWords
//
// Env :
//   SOUFFLEUSE_GGUF       chemin GGUF (sinon résolu : Souffleuse dir → Cotypist dir).
//   SOUFFLEUSE_BEAM_EXP   positionExponent (length-norm) — lu par BeamConfig.ghostCore().
//   SOUFFLEUSE_BEAM_K     largeur K — lu par BeamConfig.ghostCore().
//   PROBE_MAXWORDS        cap mots du ghost (défaut 4, = beam maxWords prod).
//   PROBE_MIN_LETTERS     seuil G2 (défaut BeamGhostShaper.beamMinSentenceLetters=3).
//   PROBE_STEP            pas de frappe en chars (défaut 1 = chaque caractère).
//   PROBE_BOUNDARY_WIDTH  DIAGNOSTIC : largeur beam aux frontières/après-espace
//                         (défaut 1 = prod ≡ greedy ; 2/3 pour tester la robustesse).
//   PROBE_SWEEP=1         balaye exp∈{0.5,0.7,1.0} × maxWords∈{3,4,5} sur 4 phrases.
//   PROBE_VERBOSE=0       n'imprime que le résumé (sinon trace par préfixe).
// ─────────────────────────────────────────────────────────────────────────────

let env = ProcessInfo.processInfo.environment
func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// ── Résolution du GGUF (mirroir de GGUFModelOption.resolvePath, hors target app) ──
func resolveGGUF() -> String? {
    let fileName = "gemma-3-1b.i1-Q5_K_M.gguf"
    if let ov = env["SOUFFLEUSE_GGUF"], !ov.isEmpty {
        return (ov as NSString).expandingTildeInPath
    }
    let fm = FileManager.default
    let souffleuseDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        .map { $0.appendingPathComponent("Souffleuse/Models").path }
    if let dir = souffleuseDir {
        let local = (dir as NSString).appendingPathComponent(fileName)
        if fm.fileExists(atPath: local) { return local }
    }
    let cotypist = (("~/Library/Application Support/app.cotypist.Cotypist/Models") as NSString)
        .expandingTildeInPath
    let fallback = (cotypist as NSString).appendingPathComponent(fileName)
    if fm.fileExists(atPath: fallback) { return fallback }
    return nil
}

// ── Scénarios de frappe FR réalistes (mid-mot, après-espace, multi-phrases) ──
// Choisis pour exercer : complétions mid-mot longues, frontières après-espace,
// ENCHAÎNEMENTS de phrases (G2 après un point), et glissement sur 2-3 phrases.
let scenarios: [String] = [
    "Je vous confirme la disponibilité du produit pour la livraison de mardi prochain.",
    "Bonjour Madame, suite à notre échange je me permets de revenir vers vous.",
    "Merci beaucoup pour hier soir. C'était vraiment une super soirée.",
    "Le calcul de la plus-value tient compte de votre prix total d'acquisition.",
    "Pensez à déclarer vos transactions avant la date limite. Le formulaire est en ligne.",
    "On se voit demain devant le cinéma. N'oublie pas les billets.",
]
// Les 4 phrases « représentatives » pour le balayage (couvrent les 4 registres).
let sweepScenarios = Array(scenarios.prefix(4))

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Un pas de pipeline (génération fraîche glissante pour UN préfixe).
// ─────────────────────────────────────────────────────────────────────────────

struct StepResult {
    let prefix: String
    let ghost: String
    let ms: Int
    let gatedNewSentence: Bool   // G2 a fait taire (juste après un point).
    let midSentence: Bool        // la phrase en cours a ≥ minLetters lettres (zone « ne doit pas être vide »).
}

/// Reproduit EXACTEMENT `ModelRuntime.generateGhostBeam` pour un préfixe via le
/// shaper partagé. customInstr/ctxPrefix vides (LLM pur, sans contexte).
func stepGhost(_ beam: BeamGhostEngine, userTail: String, beamWidth: Int,
               maxWords: Int, minLetters: Int, boundaryWidth: Int = 1) async -> StepResult {
    let t0 = Date()
    // G2 — reprise après le point.
    let armed = BeamGhostShaper.sentenceArmed(userTail: userTail, minLetters: minLetters)
    let midSentence = BeamGhostShaper.currentSentenceLetterCount(userTail) >= minLetters
    if !armed {
        return StepResult(prefix: userTail, ghost: "", ms: 0,
                          gatedNewSentence: true, midSentence: false)
    }
    let choice = BeamGhostShaper.beamConfigChoice(userTail: userTail, beamWidth: beamWidth)
    let prompt = BeamGhostShaper.buildPrompt(customInstr: "", ctxPrefix: "", llmTail: userTail)
    // Frontière → largeur DIAGNOSTIC `boundaryWidth` (prod = 1 ≡ greedy ; on peut
    // tester 2/3 pour mesurer si la robustesse des après-espace s'améliore).
    let width = choice.isBoundary ? boundaryWidth : choice.width
    let result = await beam.ghost(prompt: prompt, requiredPrefix: choice.requiredPrefix, maxWidth: width)
    let caretAfterSpace = userTail.last == " " || userTail.last == "\t"
    let ghost = BeamGhostShaper.beamPostFilter(
        rawGhost: result.best?.ghost ?? "", isBoundary: choice.isBoundary,
        caretAfterSpace: caretAfterSpace, userTail: userTail, maxWords: maxWords)
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    return StepResult(prefix: userTail, ghost: ghost, ms: ms,
                      gatedNewSentence: false, midSentence: midSentence)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Rejoue une phrase char-par-char ; renvoie les pas + agrégats.
// ─────────────────────────────────────────────────────────────────────────────

struct SentenceRun {
    let sentence: String
    let steps: [StepResult]
}

func replaySentence(_ beam: BeamGhostEngine, _ sentence: String, beamWidth: Int,
                    maxWords: Int, minLetters: Int, step: Int, boundaryWidth: Int) async -> SentenceRun {
    let chars = Array(sentence)
    var steps: [StepResult] = []
    var i = step
    while i <= chars.count {
        let prefix = String(chars.prefix(i))
        if prefix.isEmpty { i += step; continue }
        let r = await stepGhost(beam, userTail: prefix, beamWidth: beamWidth,
                                maxWords: maxWords, minLetters: minLetters, boundaryWidth: boundaryWidth)
        steps.append(r)
        i += step
    }
    return SentenceRun(sentence: sentence, steps: steps)
}

// ── Détection des régressions sur un run ──
struct Regression { let kind: String; let prefix: String; let ghost: String }

/// Repère les régressions : ghost VIDE en plein milieu de phrase (mauvais), ghost
/// qui dépasse une fin de phrase (le ghost contient . ! ? non terminal), ghost qui
/// ne glisse pas (identique au précédent malgré une frappe — heuristique souple).
func findRegressions(_ run: SentenceRun) -> [Regression] {
    var out: [Regression] = []
    for s in run.steps {
        // Vide en plein milieu de phrase (hors fin de phrase / hors G2-silence).
        if s.midSentence && !s.gatedNewSentence && s.ghost.isEmpty {
            // Tolère le vide quand le caret est À une fin de phrase (le suffixe tapé
            // se termine par . ! ?) — là, vide = correct (on ne propose pas la suite).
            let atEnd = s.prefix.last.map { ".!?".contains($0) } ?? false
            if !atEnd {
                out.append(Regression(kind: "vide-mid-phrase", prefix: s.prefix, ghost: ""))
            }
        }
        // Ghost qui franchit une fin de phrase au MILIEU (un . ! ? suivi de texte).
        let trimmed = s.ghost.trimmingCharacters(in: .whitespaces)
        if let idx = trimmed.firstIndex(where: { ".!?".contains($0) }),
           idx < trimmed.index(before: trimmed.endIndex) {
            out.append(Regression(kind: "depasse-fin-phrase", prefix: s.prefix, ghost: s.ghost))
        }
    }
    return out
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Boot du beam (corpus OFF, perso OFF, pas de Keychain).
// ─────────────────────────────────────────────────────────────────────────────

guard let gguf = resolveGGUF() else {
    err("FATAL: GGUF introuvable. Pose SOUFFLEUSE_GGUF=<chemin> ou place gemma-3-1b.i1-Q5_K_M.gguf.")
    exit(1)
}

let baseConfig = BeamConfig.ghostCore()   // lit SOUFFLEUSE_BEAM_EXP / _K
let beamWidth = baseConfig.maxSearchWidth
let maxWords = Int(env["PROBE_MAXWORDS"] ?? "") ?? baseConfig.maxWords
let minLetters = Int(env["PROBE_MIN_LETTERS"] ?? "") ?? BeamGhostShaper.beamMinSentenceLetters
let stepChars = max(1, Int(env["PROBE_STEP"] ?? "") ?? 1)
let boundaryWidth = max(1, Int(env["PROBE_BOUNDARY_WIDTH"] ?? "") ?? 1)
let verbose = (env["PROBE_VERBOSE"] ?? "1") != "0"
let sweep = (env["PROBE_SWEEP"] ?? "0") == "1"

err("[probe] GGUF: \(gguf)")
err("[probe] BeamConfig: K=\(beamWidth) exp=\(baseConfig.positionExponent) maxWords=\(maxWords) minLetters=\(minLetters) step=\(stepChars)")

let beam = BeamGhostEngine(config: baseConfig)
guard await beam.load(modelPath: gguf, contextTokens: 4096) else {
    err("FATAL: chargement GGUF dans le beam échoué."); exit(1)
}

func padR(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Mode BALAYAGE des knobs (exp × maxWords) sur 4 phrases.
// ─────────────────────────────────────────────────────────────────────────────

if sweep {
    print("")
    print("════════════════════════════════════════════════════════════════════════")
    print(" BALAYAGE knobs — positionExponent × maxWords (4 phrases représentatives)")
    print(" K=\(beamWidth) · pas=\(stepChars) char · minLetters=\(minLetters)")
    print("════════════════════════════════════════════════════════════════════════")
    let exps: [Double] = [0.5, 0.7, 1.0]
    let maxWordsSet: [Int] = [3, 4, 5]
    // Exemples lisibles : on échantillonne quelques préfixes par phrase (mid-mot + après-espace).
    for exp in exps {
        for mw in maxWordsSet {
            // Reconstruit un beam à cet exposant (config immuable au load — on
            // recharge le contexte ; le modèle est rechargé mais c'est un bench).
            let cfg = BeamConfig(maxSearchWidth: beamWidth, maxResultWidth: beamWidth,
                                 minBranchProbability: baseConfig.minBranchProbability,
                                 relativeCutoff: baseConfig.relativeCutoff,
                                 positionExponent: exp, maxTokens: baseConfig.maxTokens, maxWords: mw)
            let b = BeamGhostEngine(config: cfg)
            guard await b.load(modelPath: gguf, contextTokens: 4096) else { continue }
            print("")
            print("── exp=\(exp) · maxWords=\(mw) ─────────────────────────────────────")
            var nonEmpty = 0, total = 0, regs = 0
            var wordCounts: [Int] = []
            var lats: [Int] = []
            for s in sweepScenarios {
                let run = await replaySentence(b, s, beamWidth: beamWidth, maxWords: mw,
                                               minLetters: minLetters, step: stepChars,
                                               boundaryWidth: boundaryWidth)
                regs += findRegressions(run).count
                for st in run.steps {
                    total += 1; lats.append(st.ms)
                    if !st.ghost.isEmpty { nonEmpty += 1; wordCounts.append(st.ghost.split(whereSeparator: { $0.isWhitespace }).count) }
                }
                // 3 exemples par phrase : un mid-mot tôt, un après-espace, un tard.
                let samples = run.steps.filter { !$0.ghost.isEmpty }
                let picks = [samples.first, samples.dropFirst(samples.count / 2).first, samples.last].compactMap { $0 }
                for p in picks {
                    print("   \(padR(p.prefix.suffix(34).debugDescription, 38)) → \(p.ghost.debugDescription)")
                }
            }
            let avgW = wordCounts.isEmpty ? 0 : Double(wordCounts.reduce(0, +)) / Double(wordCounts.count)
            let avgMs = lats.isEmpty ? 0 : lats.reduce(0, +) / lats.count
            let maxMs = lats.max() ?? 0
            print("   → non-vide \(nonEmpty)/\(total) (\(total == 0 ? 0 : nonEmpty * 100 / total)%) · mots/ghost \(String(format: "%.1f", avgW)) · lat \(avgMs)/\(maxMs) ms · régressions \(regs)")
            await b.unload()
        }
    }
    print("")
    print("FIN balayage.")
    exit(0)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Mode NORMAL : rejoue tous les scénarios, trace + résumé.
// ─────────────────────────────────────────────────────────────────────────────

print("")
print("════════════════════════════════════════════════════════════════════════")
print(" SouffleuseBeamGhostProbe — génération fraîche glissante (beam core)")
print(" K=\(beamWidth) · exp=\(baseConfig.positionExponent) · maxWords=\(maxWords) · minLetters=\(minLetters) · pas=\(stepChars) · boundaryW=\(boundaryWidth)")
print(" \(scenarios.count) scénarios · perso OFF · corpus OFF · contexte vide")
print("════════════════════════════════════════════════════════════════════════")

var totalSteps = 0, totalNonEmpty = 0, totalGated = 0
var allWordCounts: [Int] = []
var allLats: [Int] = []
var allRegs: [Regression] = []

for (si, sentence) in scenarios.enumerated() {
    let run = await replaySentence(beam, sentence, beamWidth: beamWidth, maxWords: maxWords,
                                   minLetters: minLetters, step: stepChars,
                                   boundaryWidth: boundaryWidth)
    let regs = findRegressions(run)
    allRegs.append(contentsOf: regs)
    print("")
    print("#\(si) « \(sentence) »")
    for s in run.steps {
        totalSteps += 1
        allLats.append(s.ms)
        if s.gatedNewSentence { totalGated += 1 }
        if !s.ghost.isEmpty { totalNonEmpty += 1; allWordCounts.append(s.ghost.split(whereSeparator: { $0.isWhitespace }).count) }
        if verbose {
            let tag = s.gatedNewSentence ? "·G2·" : (s.ghost.isEmpty ? "·∅·" : "    ")
            print("   \(tag) \(padR(s.prefix.suffix(40).debugDescription, 44)) → \(padR(s.ghost.debugDescription, 30)) \(s.ms)ms")
        }
    }
    if !regs.isEmpty {
        print("   ⚠️ régressions :")
        for r in regs { print("      [\(r.kind)] …\(r.prefix.suffix(30).debugDescription) → \(r.ghost.debugDescription)") }
    }
}

let avgW = allWordCounts.isEmpty ? 0 : Double(allWordCounts.reduce(0, +)) / Double(allWordCounts.count)
let avgMs = allLats.isEmpty ? 0 : allLats.reduce(0, +) / allLats.count
let maxMs = allLats.max() ?? 0
let pctNonEmpty = totalSteps == 0 ? 0 : totalNonEmpty * 100 / totalSteps

print("")
print("────────────────────────────────────────────────────────────────────────")
print(" RÉSUMÉ")
print("────────────────────────────────────────────────────────────────────────")
print("   préfixes traités        : \(totalSteps)")
print("   ghost non vide          : \(totalNonEmpty)/\(totalSteps) (\(pctNonEmpty)%)  [dont \(totalGated) silences G2 après un point]")
print("   longueur moy. (mots)    : \(String(format: "%.2f", avgW))")
print("   latence moy/max (ms)    : \(avgMs) / \(maxMs)")
print("   régressions détectées   : \(allRegs.count)")
let bad = allRegs.filter { $0.kind == "vide-mid-phrase" }.count
let over = allRegs.filter { $0.kind == "depasse-fin-phrase" }.count
print("      vide-mid-phrase      : \(bad)   (CRITIQUE : ne doit jamais arriver hors fin de phrase)")
print("      dépasse-fin-phrase   : \(over)  (le ghost franchit un . ! ? au milieu)")
print("")
print("FIN.")
