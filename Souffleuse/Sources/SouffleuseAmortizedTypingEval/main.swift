import Foundation
import SouffleuseCore
import SouffleuseLlama
import SouffleuseLog
import SouffleuseTyping

// ─────────────────────────────────────────────────────────────────────────────
// SouffleuseAmortizedTypingEval — coût AMORTI par frappe des DEUX moteurs ghost
// pendant une frappe CONTINUE (char par char), mesuré sur les MÊMES sessions.
//
// POURQUOI. Les chiffres antérieurs étaient À FROID, chaque cas isolé : la
// cascade ~263 ms, le beam ~666 ms. Mais en frappe réelle, les deux moteurs
// RÉUTILISENT du calcul entre frappes — et pas de la même façon :
//
//   • CASCADE : on garde UNE SEULE instance `LlamaEngine` par session. Son
//     `generate` réutilise le KV via plus-long-préfixe-commun
//     (`llama_memory_seq_rm(mem, 0, lcp, -1)`) : nourrir des prompts CROISSANTS
//     au même moteur réchauffe le préfill automatiquement. MAIS la cascade
//     RELANCE quand même un greedy frais + (sur mid-mot incertain) K=3 branches
//     d'engagement À CHAQUE frappe → elle paie un coût de génération CHAUD par
//     frappe, PAS zéro.
//
//   • BEAM : il consomme sa réserve de branches pré-calculée → HIT ≈ 0 ms, et ne
//     re-beam en plein que sur un MISS. C'est l'autre mécanisme d'amorti.
//
// Cette éval SIMULE la frappe de ~20 phrases FR char par char. À CHAQUE frappe
// elle lance les DEUX moteurs sur le préfixe courant et enregistre la latence
// par frappe + la CLASSE de chemin (cascade : branches K=3 vs chemin chaud
// pas cher ; beam : HIT/REFILL/MISS). Apples-to-apples : mêmes sessions tapées.
//
// HORS PÉRIMÈTRE : `routeInstant` (recall instantané L1/L0), `CompletionCache`,
// perso n-gram. Corpus OFF des deux côtés (`setCorpus([])`). On mesure la COUCHE
// DE GÉNÉRATION LLM — la partie qui concourt entre cascade et beam.
//
// Usage :
//   SOUFFLEUSE_BEAM=1 MW_ENGAGEMENT=1 MW_ENG_PRUDENT=0 MW_ECHO_RUN=4 \
//     SOUFFLEUSE_GGUF=~/…/gemma-3-1b.i1-Q5_K_M.gguf \
//     swift run SouffleuseAmortizedTypingEval
// ─────────────────────────────────────────────────────────────────────────────

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let env = ProcessInfo.processInfo.environment
let beamEnabled = (env["SOUFFLEUSE_BEAM"].map { !$0.isEmpty }) ?? false
if !beamEnabled {
    err("[amort-typing] SOUFFLEUSE_BEAM absent → éval désactivée. Relance avec SOUFFLEUSE_BEAM=1.")
    exit(0)
}

err("[amort-typing] flags cascade : MW_ENGAGEMENT=\(env["MW_ENGAGEMENT"] ?? "(absent)") " +
    "MW_ENG_PRUDENT=\(env["MW_ENG_PRUDENT"] ?? "(défaut 0.5)") " +
    "MW_ENG_PLEIN=\(env["MW_ENG_PLEIN"] ?? "(défaut 0.8)") " +
    "DICO_FLOOR=\(SuggestionPolicy.Tuning.midWordDicoFloorEnabled ? "ON" : "OFF") " +
    "ECHO_RUN=\(SuggestionPolicy.Tuning.echoMinVerbatimRunWords)")

// MARK: - Corpus de sessions de frappe

/// Une session : un `prefix` déjà présent au caret (point de départ), puis
/// `intended` que l'utilisateur tape CHAR PAR CHAR. À chaque frappe on relance
/// les deux moteurs sur le préfixe courant (= prefix + chars tapés jusqu'ici).
struct Session { let label: String; let prefix: String; let intended: String }

let sessions: [Session] = [
    .init(label: "after-space", prefix: "Je peux vous envoyer ",          intended: "le document demain matin"),
    .init(label: "after-space", prefix: "La réunion aura lieu ",          intended: "demain à quatorze heures"),
    .init(label: "after-space", prefix: "Merci beaucoup pour ",           intended: "votre retour rapide"),
    .init(label: "after-space", prefix: "Je vous confirme que ",          intended: "le rendez-vous est maintenu"),
    .init(label: "after-space", prefix: "Bonjour, je voulais ",           intended: "savoir si vous étiez disponible"),
    .init(label: "mid-mot",     prefix: "Pouvez-vous conf",               intended: "irmer le rendez-vous"),
    .init(label: "mid-mot",     prefix: "Nous avons bien reçu votre comm", intended: "ande et la traitons"),
    .init(label: "mid-mot",     prefix: "Je reviendrai vers vous dès que poss", intended: "ible cette semaine"),
    .init(label: "mid-mot",     prefix: "Le projet avance, on livre la prem", intended: "ière version vendredi"),
    .init(label: "accord",      prefix: "Je dois finaliser mon rapport fisc", intended: "al avant la fin du mois"),
    .init(label: "accord",      prefix: "Voici le document fin",          intended: "al pour relecture"),
    .init(label: "accord",      prefix: "C'est une décision import",       intended: "ante pour l'entreprise"),
    .init(label: "narratif",    prefix: "Le soleil se couchait lentement derrière les coll", intended: "ines au loin"),
    .init(label: "narratif",    prefix: "Elle ouvrit la porte avec précaution, le cœur batt", intended: "ant sans un bruit"),
    .init(label: "technique",   prefix: "Pour configurer le serveur, il faut d'abord install", intended: "er les dépendances"),
    .init(label: "technique",   prefix: "La fonction prend en entrée un tableau d'ent",  intended: "iers et retourne la somme"),
    .init(label: "courrier",    prefix: "Je vous prie d'agréer, Madame, Monsieur, mes salut", intended: "ations distinguées"),
    .init(label: "email-pro",   prefix: "Je me permets de revenir vers vous concernant ma candida", intended: "ture spontanée"),
    .init(label: "chat",        prefix: "ok pas de souci, on se voit dem",  intended: "ain matin"),
    .init(label: "quotidien",   prefix: "N'oublie pas d'acheter du pain et du ", intended: "lait ce soir"),
]

// MARK: - Boot des deux moteurs

let ggufPath = (env["SOUFFLEUSE_GGUF"].flatMap { $0.isEmpty ? nil : $0 }
    ?? "~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf")
let resolved = (ggufPath as NSString).expandingTildeInPath

let beamConfig = BeamConfig.fromEnvironment()

// CASCADE : UNE instance réutilisée. Son KV se réchauffe tout seul entre frappes
// (LCP warm-reuse) tant qu'on ne la recrée pas ni ne reset le KV.
let engine = LlamaEngine()
err("[amort-typing] loading GGUF (cascade): \(resolved)")
guard await engine.load(modelPath: resolved, contextTokens: 4096) else {
    err("FATAL: GGUF load failed (cascade)"); exit(1)
}
await engine.setCorpus([])

let beam = BeamGhostEngine(config: beamConfig)
err("[amort-typing] loading GGUF (beam, n_seq_max=\(beamConfig.maxSearchWidth + 1)): \(resolved)")
guard await beam.load(modelPath: resolved, contextTokens: 4096) else {
    err("FATAL: GGUF load failed (beam)"); exit(1)
}

let dicoFloor = WordCompleter()

// MARK: - Constantes de prod (mêmes seuils que ModelRuntime)

let escFastP1 = SuggestionPolicy.Tuning.escFastP1
let escMinFastLen = SuggestionPolicy.Tuning.escMinFastLen
let escBranchK = SuggestionPolicy.Tuning.escBranchKRuntime
let escBranchMaxTokens = SuggestionPolicy.Tuning.escBranchMaxTokens
let escBranchTemp = SuggestionPolicy.Tuning.escBranchTempRuntime
let escAgreeThresh = SuggestionPolicy.Tuning.escAgreeThreshRuntime
let escEpsilon = Float(SuggestionPolicy.Tuning.escFirstTokenProbEpsilon)
let echoThreshold = OutputFilter.continuationEchoThreshold
let echoMinRun = SuggestionPolicy.Tuning.echoMinVerbatimRunWords
let engagementOn = SuggestionPolicy.Tuning.midWordEngagementEnabled

// MARK: - Chemin CASCADE (MIROIR fidèle de ModelRuntime.midWordLongGhost)

/// Classe de chemin parcouru par la cascade à une frappe (ce qui DRIVE le coût).
enum CascadePath: String {
    case branches   // a lancé les K=3 branches d'engagement (chemin cher).
    case fastAccept // greedy P1 ≥ seuil → PLEIN sans brancher (chemin chaud pas cher).
    case structural // dégénéré structurel → plancher dico / zéro (pas de branches).
    case boundary   // after-space / frontière → pas d'engagement mid-mot du tout.
}

struct CascadeStep {
    let ghost: String
    let ms: Int
    let path: CascadePath
}

func runEscalationPass(
    prompt: String, partial: String, cap: Int,
    temperature: Float, seed: UInt32, captureP1: Bool
) async -> (lead: String, p1: Double?, fullLine: String) {
    final class Acc: @unchecked Sendable { var text = "" }
    let acc = Acc()
    let metrics = await engine.generate(
        prompt: prompt, maxTokens: cap,
        sampling: LlamaSampling(
            temperature: temperature,
            repeatPenalty: 1.3,
            repeatLastN: 64,
            seed: seed,
            personalizationStrength: 0,
            topP: temperature > 0 ? 0.9 : 0,
            banMarkup: true,
            banDigitsLeading: true,
            banEmoji: true,
            minFirstTokenProb: captureP1 ? escEpsilon : 0,
            healPrefix: partial.isEmpty ? nil : partial)
    ) { piece in acc.text += piece; return true }
    let oneLine = acc.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? acc.text
    return (SuggestionPolicy.midWordLeadWordDefrag(oneLine, partial: partial),
            metrics.firstTokenProb, oneLine)
}

func firstWholeWord(of ghost: String) -> String {
    let hadLeadingSpace = ghost.first == " "
    let words = ghost.split(whereSeparator: { $0.isWhitespace })
    guard let first = words.first else { return ghost }
    let one = String(first)
    return hadLeadingSpace ? " " + one : one
}

func dicoFloorResult(partial: String, greedyLead: String, why: String) -> (word: String, reason: String)? {
    guard SuggestionPolicy.Tuning.midWordDicoFloorEnabled else { return nil }
    guard let suffix = dicoFloor.completion(for: partial, preferring: greedyLead),
          !suffix.isEmpty else { return nil }
    return (suffix, "floor-dico(\(why))")
}

/// MIROIR de `ModelRuntime.midWordEngagementResult`. Renvoie aussi le chemin parcouru
/// (branches vs fast-accept vs structurel) pour la classification de coût.
func midWordEngagementResult(
    prompt: String, partial: String, maxTokens: Int,
    greedyFullLine: String, greedyP1: Double?, fullContinuation: String
) async -> (ghost: String, path: CascadePath) {
    let greedyLead = SuggestionPolicy.midWordLeadWordDefrag(
        OutputFilter.singleLine(greedyFullLine), partial: partial)

    // Dégénéré STRUCTUREL ⇒ plancher dico / zéro — PAS de branches.
    guard SuggestionPolicy.midWordExtendsStructurally(partial: partial, modal: greedyLead) else {
        if let floor = dicoFloorResult(partial: partial, greedyLead: greedyLead, why: "structdegen") {
            return (floor.word, .structural)
        }
        return ("", .structural)
    }

    // Fast-accept ⇒ PLEIN sans brancher (chemin chaud pas cher).
    let isFastAccept = (greedyP1 ?? 0) >= escFastP1 && partial.count >= escMinFastLen
    if isFastAccept {
        return (fullContinuation, .fastAccept)
    }

    // Sinon : on LANCE les K=3 branches (chemin cher).
    var agreement = 0.0
    if escBranchK > 0 {
        let branchCap = min(maxTokens, escBranchMaxTokens)
        var leads = [greedyLead]
        let needed = Int((escAgreeThresh * Double(escBranchK + 1)).rounded(.up))
        for i in 0..<escBranchK {
            let b = await runEscalationPass(prompt: prompt, partial: partial, cap: branchCap,
                                            temperature: escBranchTemp, seed: UInt32(i + 1),
                                            captureP1: false)
            leads.append(b.lead)
            let counts = Dictionary(leads.map { ($0.lowercased(), 1) }, uniquingKeysWith: +)
            if let top = counts.values.max(), top >= needed { break }
        }
        agreement = SuggestionPolicy.midWordBranchDecision(
            partial: partial, greedyModal: greedyLead,
            branchLeads: Array(leads.dropFirst())).agreement
    }

    let level = SuggestionPolicy.midWordEngagementLevel(
        partial: partial, greedyLeadWord: greedyLead,
        firstTokenProb: greedyP1, agreement: agreement)

    switch level {
    case .zero:
        if let floor = dicoFloorResult(partial: partial, greedyLead: greedyLead, why: "agree") {
            return (floor.word, .branches)
        }
        return ("", .branches)
    case .prudent:
        return (firstWholeWord(of: fullContinuation), .branches)
    case .plein:
        return (fullContinuation, .branches)
    }
}

/// MIROIR FIDÈLE de `ModelRuntime.midWordLongGhost`. Utilise l'instance `engine`
/// RÉUTILISÉE (KV warm-reuse via préfixes croissants).
func cascadeStep(prefix: String) async -> CascadeStep {
    let t0 = Date()
    let userTail = prefix
    let llmTail = prefix
    let partial = OutputFilter.trailingPartialWord(userTail)
    let isBoundary = partial.isEmpty || SuggestionPolicy.defaultPartialWordIsComplete(userTail)

    let prompt = LlamaPromptBuilder.buildLlamaPrompt(
        system: "", customInstr: "", ctxPrefix: "", fieldContext: "",
        afterCursor: "", beforeCursor: llmTail)

    let cap = SuggestionPolicy.Tuning.midWordLongGhostMaxTokens
    let ghostMaxWords = SuggestionPolicy.Tuning.midWordLongGhostMaxWords

    final class Acc: @unchecked Sendable { var text = "" }
    let acc = Acc()
    let greedyMetrics = await engine.generate(
        prompt: prompt, maxTokens: cap,
        sampling: LlamaSampling(
            temperature: 0,
            repeatPenalty: 1.3,
            repeatLastN: 64,
            seed: 0,
            personalizationStrength: 0,
            banMarkup: true,
            banDigitsLeading: true,
            banEmoji: true,
            minFirstTokenProb: engagementOn ? escEpsilon : 0,
            healPrefix: isBoundary ? nil : (partial.isEmpty ? nil : partial))
    ) { piece in acc.text += piece; return true }

    let fullLine = OutputFilter.singleLine(acc.text)
    var stripped = OutputFilter.singleLine(
        OutputFilter.stripPrefixOverlap(fullLine, prefix: isBoundary ? "" : partial))
    if isBoundary, !stripped.isEmpty {
        let body = String(stripped.drop(while: { $0 == " " || $0 == "\t" }))
        let tailEndsWithSpace = userTail.last.map(\.isWhitespace) ?? true
        let modelGlued = fullLine.first.map { !$0.isWhitespace } ?? false
        if body.isEmpty { stripped = "" }
        else if tailEndsWithSpace { stripped = body }
        else if partial.isEmpty { stripped = " " + body }
        else { stripped = modelGlued ? body : " " + body }
    }
    var result = SuggestionPolicy.dedupLeadingRepeat(ghost: stripped, userTail: userTail)
    if !isBoundary, !partial.isEmpty, let f = result.first, f == " " || f == "\t" {
        let body = result.drop(while: { $0 == " " || $0 == "\t" })
        let firstWord = body.prefix(while: { $0.isLetter || $0.isNumber })
        if firstWord.count > partial.count,
           firstWord.lowercased().hasPrefix(partial.lowercased()) {
            result = String(body.dropFirst(partial.count))
        }
    }
    if !result.isEmpty {
        let echoVal = OutputFilter.echoScore(ghost: result, tail: userTail)
        if echoVal >= echoThreshold {
            let run = OutputFilter.longestVerbatimRunWords(ghost: result, tail: userTail)
            if run >= echoMinRun { result = "" }
        }
    }

    if let idx = result.firstIndex(where: { "\n.!?;:".contains($0) }) {
        result = String(result[...idx])
    }
    let words = result.split(whereSeparator: { $0.isWhitespace })
    if words.count > ghostMaxWords {
        let hadLeadingSpace = result.first == " "
        result = words.prefix(ghostMaxWords).joined(separator: " ")
        if hadLeadingSpace, result.first != " ", !result.isEmpty { result = " " + result }
    }
    result = OutputFilter.singleLine(result)

    // Gradient d'engagement (mid-mot collé seulement, comme ModelRuntime).
    if engagementOn, !isBoundary, result.first != " " {
        let r = await midWordEngagementResult(
            prompt: prompt, partial: partial, maxTokens: cap,
            greedyFullLine: acc.text, greedyP1: greedyMetrics.firstTokenProb,
            fullContinuation: result)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        return CascadeStep(ghost: r.ghost, ms: ms, path: r.path)
    }

    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    // Pas d'engagement : either frontière, either greedy collé sans mid-mot.
    return CascadeStep(ghost: result, ms: ms, path: .boundary)
}

func buildPrompt(_ prefix: String) -> String {
    LlamaPromptBuilder.buildLlamaPrompt(
        system: "", customInstr: "", ctxPrefix: "", fieldContext: "",
        afterCursor: "", beforeCursor: prefix)
}

// MARK: - Helpers stats

func f1(_ x: Double) -> String { String(format: "%.1f", x) }
func f2(_ x: Double) -> String { String(format: "%.2f", x) }
func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "0%" : "\(Int((Double(a) / Double(b) * 100).rounded()))%" }
func meanD(_ xs: [Int]) -> Double { xs.isEmpty ? 0 : Double(xs.reduce(0, +)) / Double(xs.count) }
func median(_ xs: [Int]) -> Int { xs.isEmpty ? 0 : xs.sorted()[xs.count / 2] }
func percentile(_ xs: [Int], _ p: Double) -> Int {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted(); let i = min(s.count - 1, Int(Double(s.count - 1) * p)); return s[i]
}
func rpad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

// MARK: - Run

print("")
print("════════════════════════════════════════════════════════════════════════")
print(" SouffleuseAmortizedTypingEval — \(sessions.count) sessions de frappe CONTINUE")
print(" cascade (1 LlamaEngine réutilisé, KV warm-reuse) vs beam (réserve KV)")
print(" beam K=\(beamConfig.maxSearchWidth)  ·  corpus OFF  ·  routeInstant/cache/perso HORS périmètre")
print("════════════════════════════════════════════════════════════════════════")

// Agrégats CASCADE.
var casColdMs: [Int] = []       // 1ʳᵉ frappe de chaque session.
var casSteadyMs: [Int] = []     // frappes ≥ 2.
var casSessionMs: [Int] = []
var casPathCount: [CascadePath: Int] = [:]

// Agrégats BEAM.
var beamFirstPaintMs: [Int] = [] // strictement le 1ᵉʳ paint/session (comparable au cold cascade).
var beamSteadyMs: [Int] = []    // toutes les frappes advance (≥ 2ᵉ paint).
var beamMissMs: [Int] = []      // latence des MISS (re-beam).
var beamSessionMs: [Int] = []
var nHit = 0, nRefill = 0, nMiss = 0

var totalKeys = 0

for s in sessions {
    // Le 1ᵉʳ « paint » correspond au préfixe déjà présent (avant de taper `intended`).
    let partial0 = OutputFilter.trailingPartialWord(s.prefix)

    // ── CASCADE : cold first-paint sur le préfixe, puis frappe char par char. ──
    let cCold = await cascadeStep(prefix: s.prefix)
    casColdMs.append(cCold.ms)
    casPathCount[cCold.path, default: 0] += 1
    var cSessMs = cCold.ms

    // ── BEAM : cold first-paint AVEC réserve, sur le même préfixe. ────────────
    let t0 = Date()
    _ = await beam.ghostWithReserve(prompt: buildPrompt(s.prefix), requiredPrefix: partial0)
    let bColdMs = Int(Date().timeIntervalSince(t0) * 1000)
    beamFirstPaintMs.append(bColdMs)
    var bSessMs = bColdMs

    var typed = s.prefix
    var keys = 1   // le cold first-paint compte comme la 1ʳᵉ peinture.
    var cBranchKeys = 0, cFastKeys = 0, cStructKeys = 0, cBoundaryKeys = 0
    if cCold.path == .branches { cBranchKeys += 1 }
    else if cCold.path == .fastAccept { cFastKeys += 1 }
    else if cCold.path == .structural { cStructKeys += 1 }
    else { cBoundaryKeys += 1 }
    var lineHit = 0, lineRefill = 0, lineMiss = 0

    for ch in s.intended {
        keys += 1
        let nextTyped = typed + String(ch)
        let nextPartial = OutputFilter.trailingPartialWord(nextTyped)

        // CASCADE sur le préfixe CROISSANT (même engine → KV LCP warm-reuse).
        let cStep = await cascadeStep(prefix: nextTyped)
        cSessMs += cStep.ms
        casSteadyMs.append(cStep.ms)
        casPathCount[cStep.path, default: 0] += 1
        switch cStep.path {
        case .branches:   cBranchKeys += 1
        case .fastAccept: cFastKeys += 1
        case .structural: cStructKeys += 1
        case .boundary:   cBoundaryKeys += 1
        }

        // BEAM advance sur le même char.
        let a = await beam.advance(typedChar: ch, requiredPrefixForMiss: nextPartial)
        bSessMs += a.elapsedMillis
        beamSteadyMs.append(a.elapsedMillis)
        switch a.kind {
        case .hit:    nHit += 1;    lineHit += 1
        case .refill: nRefill += 1; lineRefill += 1
        case .miss:   nMiss += 1;   lineMiss += 1;   beamMissMs.append(a.elapsedMillis)
        }

        typed = nextTyped
    }
    await beam.clearReserve()

    casSessionMs.append(cSessMs)
    beamSessionMs.append(bSessMs)
    totalKeys += keys

    let cAmort = Double(cSessMs) / Double(keys)
    let bAmort = Double(bSessMs) / Double(keys)

    print("")
    print("── [\(s.label)] \(s.prefix.debugDescription) + \(s.intended.debugDescription)")
    if !partial0.isEmpty { print("   départ mid-mot, fragment = \(partial0.debugDescription)") }
    print("   frappes ........... \(keys)")
    print("   CASCADE  cold \(cCold.ms) ms · session \(cSessMs) ms → AMORTI \(f1(cAmort)) ms/frappe   " +
          "[branches=\(cBranchKeys) fast=\(cFastKeys) struct=\(cStructKeys) bound=\(cBoundaryKeys)]")
    print("   BEAM     cold \(bColdMs) ms · session \(bSessMs) ms → AMORTI \(f1(bAmort)) ms/frappe   " +
          "[HIT=\(lineHit) REFILL=\(lineRefill) MISS=\(lineMiss)]")
}

// MARK: - Synthèse

let casColdMean = meanD(casColdMs)
let casSteadyMean = meanD(casSteadyMs)
let casAmort = Double(casSessionMs.reduce(0, +)) / Double(totalKeys)

let beamColdMean = meanD(beamFirstPaintMs)
let beamSteadyMean = meanD(beamSteadyMs)
let beamAmort = Double(beamSessionMs.reduce(0, +)) / Double(totalKeys)

let nSteps = nHit + nRefill + nMiss
let casBranch = casPathCount[.branches] ?? 0
let casFast = casPathCount[.fastAccept] ?? 0
let casStruct = casPathCount[.structural] ?? 0
let casBound = casPathCount[.boundary] ?? 0
let casTotalSteps = casBranch + casFast + casStruct + casBound

print("")
print("────────────────────────────────────────────────────────────────────────")
print(" SYNTHÈSE AMORTIE (frappe continue, mêmes sessions des deux côtés)")
print("────────────────────────────────────────────────────────────────────────")
print("  Sessions ......................... \(sessions.count)")
print("  Frappes totales .................. \(totalKeys)")
print("")
print("  ── COLD first-paint (1ʳᵉ frappe de chaque session) ──")
print("    cascade  moy/méd/p90 ........... \(f1(casColdMean)) / \(median(casColdMs)) / \(percentile(casColdMs, 0.9)) ms")
print("    beam     moy/méd/p90 ........... \(f1(beamColdMean)) / \(median(beamFirstPaintMs)) / \(percentile(beamFirstPaintMs, 0.9)) ms")
print("")
print("  ── STEADY-STATE par frappe (hors 1ᵉʳ paint) ──")
print("    cascade  moy/méd/p90 ........... \(f1(casSteadyMean)) / \(median(casSteadyMs)) / \(percentile(casSteadyMs, 0.9)) ms")
print("    beam     moy/méd/p90 ........... \(f1(beamSteadyMean)) / \(median(beamSteadyMs)) / \(percentile(beamSteadyMs, 0.9)) ms")
print("")
print("  ── CASCADE : ce qui DRIVE le coût (chemin par frappe) ──")
print("    branches K=\(escBranchK) (cher) ......... \(casBranch)  (\(pct(casBranch, casTotalSteps)))")
print("    fast-accept (chaud, pas cher) .. \(casFast)  (\(pct(casFast, casTotalSteps)))")
print("    structurel (dico/zéro) ......... \(casStruct)  (\(pct(casStruct, casTotalSteps)))")
print("    frontière (after-space) ........ \(casBound)  (\(pct(casBound, casTotalSteps)))")
print("")
print("  ── BEAM : HIT / REFILL / MISS ──")
print("    HIT    (réserve, ≈0) ........... \(nHit)  (\(pct(nHit, nSteps)))")
print("    REFILL (top-up incrémental) .... \(nRefill)  (\(pct(nRefill, nSteps)))")
print("    MISS   (re-beam complet) ....... \(nMiss)  (\(pct(nMiss, nSteps)))")
print("")
print("  ────────────────────────────────────────────────────────────────────")
print("  HEAD-TO-HEAD (coût que l'utilisateur RESSENT)")
print("  ────────────────────────────────────────────────────────────────────")
print("                          cascade        beam")
print("    cold first-paint ...  \(rpad(f1(casColdMean) + " ms", 12))  \(f1(beamColdMean)) ms")
print("    steady/frappe ......  \(rpad(f1(casSteadyMean) + " ms", 12))  \(f1(beamSteadyMean)) ms")
print("    AMORTI/frappe ......  \(rpad(f1(casAmort) + " ms", 12))  \(f1(beamAmort)) ms")
print("")

// MARK: - Verdict honnête

let amortRatio = beamAmort > 0 ? casAmort / beamAmort : 0
print("  ── VERDICT (frappe continue) ──")
if casAmort < beamAmort {
    print("  La CASCADE est MOINS CHÈRE par frappe amortie : \(f1(casAmort)) vs \(f1(beamAmort)) ms")
    print("  → la cascade = ×\(f2(amortRatio)) le beam (\(f1((1 - amortRatio) * 100))% plus rapide).")
} else if beamAmort < casAmort {
    print("  Le BEAM est MOINS CHER par frappe amortie : \(f1(beamAmort)) vs \(f1(casAmort)) ms")
    print("  → la cascade = ×\(f2(amortRatio)) le beam (\(f1((amortRatio - 1) * 100))% plus lent).")
} else {
    print("  ÉGALITÉ amortie : \(f1(casAmort)) ms/frappe des deux côtés.")
}
print("")
print("  Où chacun paie son coût :")
print("    • CASCADE : une génération CHAUDE à CHAQUE frappe. Le greedy warm coûte")
print("      ~\(f1(meanD(casSteadyMs.isEmpty ? [0] : casSteadyMs)))ms ; les frappes qui déclenchent les K=\(escBranchK) branches")
print("      (\(pct(casBranch, casTotalSteps)) des frappes) coûtent le plus cher. Coût ÉTALÉ, jamais nul.")
print("    • BEAM : \(pct(nHit, nSteps)) de HIT ≈ 0 ms (gratuits), mais paie cher sur les")
print("      \(nMiss) MISS (re-beam, méd \(median(beamMissMs)) ms). Coût CONCENTRÉ sur les misses.")
print("")
print("  → \(casAmort < beamAmort ? "Malgré ses branches, la cascade gagne l'amorti car son greedy chaud est court." : "Le beam gagne l'amorti grâce à ses HIT gratuits, malgré des MISS coûteux.")")
print("────────────────────────────────────────────────────────────────────────")

await engine.unload()
await beam.unload()
