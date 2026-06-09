import Foundation
import SouffleuseCore
import SouffleuseLlama
import SouffleuseTyping

// ─────────────────────────────────────────────────────────────────────────────
// SouffleuseParityEval — « le mot juste avec le moins de lettres tapées ».
//
// Rejoue un corpus FR char-par-char (la phrase complète = vérité terrain de ce
// que l'utilisateur VEUT taper) et mesure, pour CHAQUE moteur :
//
//   QUALITÉ
//   1. KTC (keystrokes-to-correct) : pour chaque mot, à combien de lettres
//      tapées le ghost propose la suite EXACTE du mot (hit@1/2/3 lettres, jamais).
//      → LA métrique de parité Cotypist (mot juste, moins de lettres possible).
//   2. Frappes économisées : simulation d'un utilisateur parfait qui accepte
//      (Tab, coût 1 frappe) dès que le ghost colle à la vérité terrain —
//      deux variantes : full-accept (tout le ghost juste) et word-accept
//      (le plus long préfixe de mots entiers justes).
//   3. Stabilité k→k+1 : un ghost juste mid-mot le RESTE-t-il à la lettre
//      suivante (anti-flicker) ?
//   4. Cohérence de glissement : quand la lettre tapée == 1ʳᵉ lettre du ghost,
//      le nouveau ghost prolonge-t-il l'ancien (ghost qui « glisse ») ?
//
//   LATENCE : moy / p50 / p95 / max par frappe, mid-mot vs frontière.
//
// Moteurs comparés (mêmes conditions : corpus OFF, perso OFF, contexte vide) :
//   A = CASCADE de prod (miroir fidèle de `ModelRuntime.midWordLongGhost`,
//       repris VERBATIM de SouffleuseCascadeVsBeamEval — greedy healed +
//       gradient d'engagement + plancher dico + garde écho). Flag OFF.
//   B = BEAM-CORE (pipeline exact de `ModelRuntime.generateGhostBeam` via le
//       shaper partagé `BeamGhostShaper`, comme SouffleuseBeamGhostProbe).
//       Flag `SOUFFLEUSE_BEAM_CORE` ON.
//
// Usage (flags cascade = ceux que l'utilisateur lance en prod) :
//   MW_ENGAGEMENT=1 MW_ENG_PRUDENT=0 MW_ENG_PLEIN=0.8 \
//     swift run -c release SouffleuseParityEval
//
// Env :
//   SOUFFLEUSE_GGUF      chemin GGUF (sinon résolu Souffleuse dir → Cotypist dir).
//   PARITY_ENGINE        both | beam | cascade (défaut both).
//   PARITY_STEP          pas de frappe en chars (défaut 1).
//   PARITY_SENTENCES     nombre de phrases (défaut toutes).
//   PARITY_VERBOSE=1     trace par préfixe (défaut résumé seul).
//   PARITY_JSONL         chemin de dump JSONL par step (optionnel).
//   PARITY_BEAM_MIDWORD=force  DIAGNOSTIC (éval seulement, pas prod) : tout
//                        partiel non vide → requiredPrefix + K plein, même si
//                        `defaultPartialWordIsComplete` le juge « mot complet ».
//                        Mesure le plafond de gain d'un fix du routage mid-mot.
//   PARITY_LONGCTX=1     DIAGNOSTIC : injecte un ctxPrefix réaliste (~150 mots,
//                        type contexte app/OCR/persona de prod) dans le prompt
//                        beam — mesure le poids du re-prefill par frappe.
//   PARITY_RESERVE=1     mode RÉSERVE (miroir de SOUFFLEUSE_BEAM_RESERVE) :
//                        seed ghostWithReserve puis advance(typedChar:) par
//                        frappe — HIT ~0 ms, MISS re-beam. Mesure la qualité
//                        des ghosts réellement AFFICHÉS sous la réserve et la
//                        latence amortie sur le corpus vérité-terrain.
// ─────────────────────────────────────────────────────────────────────────────

let env = ProcessInfo.processInfo.environment
func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// ── Résolution du GGUF (miroir de GGUFModelOption.resolvePath, hors target app) ──
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

// ── Corpus : la phrase complète EST la vérité terrain (intention de frappe). ──
let allScenarios: [String] = [
    "Je vous confirme la disponibilité du produit pour la livraison de mardi prochain.",
    "Bonjour Madame, suite à notre échange je me permets de revenir vers vous.",
    "Merci beaucoup pour hier soir. C'était vraiment une super soirée.",
    "Le calcul de la plus-value tient compte de votre prix total d'acquisition.",
    "Pensez à déclarer vos transactions avant la date limite. Le formulaire est en ligne.",
    "On se voit demain devant le cinéma. N'oublie pas les billets.",
    "Le ghost s'est présenté comme un technicien de l'entreprise.",
    "Je reste à votre disposition pour toute information complémentaire.",
    "Nous avons bien reçu votre dossier et nous reviendrons vers vous rapidement.",
    "désolé pour le retard, je suis coincé dans les embouteillages depuis vingt minutes",
    "tu peux me rappeler quand tu as un moment dans la journée",
    "La fonction prend en entrée un tableau d'entiers et retourne la somme des éléments.",
    "Pour configurer le serveur, il faut d'abord installer les dépendances nécessaires.",
    "Elle ouvrit la porte avec précaution, le cœur battant, sans savoir ce qui l'attendait.",
    "Votre rapport fiscal annuel est disponible dans votre espace personnel.",
]

let sentenceCap = Int(env["PARITY_SENTENCES"] ?? "") ?? allScenarios.count
let scenarios = Array(allScenarios.prefix(max(1, sentenceCap)))
let stepChars = max(1, Int(env["PARITY_STEP"] ?? "") ?? 1)
let verbose = (env["PARITY_VERBOSE"] ?? "0") == "1"
let engineChoice = (env["PARITY_ENGINE"] ?? "both").lowercased()
let runCascade = engineChoice == "both" || engineChoice == "cascade"
let runBeam = engineChoice == "both" || engineChoice == "beam"

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Vérité terrain : mots, juges, helpers.
// ─────────────────────────────────────────────────────────────────────────────

func isWordChar(_ c: Character) -> Bool {
    c.isLetter || c.isNumber || c == "'" || c == "’" || c == "-"
}

/// Plages (start, len) des mots de la phrase, en indices de Character.
func wordRanges(_ chars: [Character]) -> [(start: Int, len: Int)] {
    var out: [(Int, Int)] = []
    var i = 0
    while i < chars.count {
        if isWordChar(chars[i]) {
            let s = i
            while i < chars.count, isWordChar(chars[i]) { i += 1 }
            out.append((s, i - s))
        } else { i += 1 }
    }
    return out
}

func commonPrefixLen(_ a: [Character], _ b: [Character]) -> Int {
    var n = 0
    while n < a.count, n < b.count, a[n] == b[n] { n += 1 }
    return n
}

/// Le mot démarre-t-il une phrase (début de scénario ou après . ! ?) ?
/// Ces mots sont G2-handicapés côté beam (silence < 3 lettres) — bucket à part.
func isSentenceInitial(_ chars: [Character], wordStart: Int) -> Bool {
    var i = wordStart - 1
    while i >= 0, chars[i] == " " || chars[i] == "\t" { i -= 1 }
    return i < 0 || ".!?".contains(chars[i])
}

func percentile(_ xs: [Int], _ p: Double) -> Int {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted()
    let idx = min(s.count - 1, Int(Double(s.count) * p))
    return s[idx]
}

func mean(_ xs: [Int]) -> Int { xs.isEmpty ? 0 : xs.reduce(0, +) / xs.count }
func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "–" : String(format: "%.0f%%", 100.0 * Double(a) / Double(b)) }
func f1(_ x: Double) -> String { String(format: "%.1f", x) }

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Steps : un ghost par préfixe, par moteur.
// ─────────────────────────────────────────────────────────────────────────────

struct Step: Sendable {
    let i: Int             // longueur du préfixe tapé (en chars).
    let ghost: String      // ghost tel qu'il serait PEINT (insérable verbatim au caret).
    let ms: Int
    let g2: Bool           // silence G2 (beam seulement).
    let boundary: Bool     // frontière / après-espace (pas de fragment mid-mot).
    var kind: String = ""  // mode réserve : seed / hit / refill / miss.
}

struct SentenceRun: Sendable {
    let sentence: String
    let chars: [Character]
    let steps: [Int: Step]   // keyé par i (longueur de préfixe), i ∈ 1...N-1.
}

/// Rejoue une phrase : ghost à chaque préfixe i ∈ 1...N-1 (truth jamais vide).
func replay(_ sentence: String, step: (String) async -> Step) async -> SentenceRun {
    let chars = Array(sentence)
    var steps: [Int: Step] = [:]
    var i = stepChars
    while i < chars.count {
        let prefix = String(chars.prefix(i))
        steps[i] = await step(prefix)
        i += stepChars
    }
    return SentenceRun(sentence: sentence, chars: chars, steps: steps)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Scorecard : toutes les métriques d'un moteur sur le corpus.
// ─────────────────────────────────────────────────────────────────────────────

struct Scorecard {
    var name = ""
    // KTC — mots non-initiaux de phrase, len ≥ 3.
    var ktcWords = 0
    var ktcHitAt = [1: 0, 2: 0, 3: 0, 4: 0]    // hit CUMULÉ à ≤k lettres tapées.
    var ktcNever = 0
    var ktcLettersNeeded: [Int] = []           // k du premier hit (mots touchés).
    var hitAt0Words = 0                        // après-espace : mot entier deviné à 0 lettre.
    var hitAt0Total = 0
    // Économies (utilisateur parfait, Tab = 1 frappe).
    var totalChars = 0
    var savedFull = 0
    var acceptsFull = 0
    var savedWord = 0
    var acceptsWord = 0
    // Stabilité / cohérence.
    var holdPairs = 0
    var holdKept = 0
    var slidePairs = 0
    var slideCoherent = 0
    // Couverture + latence.
    var stepsTotal = 0
    var stepsNonEmpty = 0
    var stepsG2 = 0
    var latAll: [Int] = []
    var latMid: [Int] = []
    var latBoundary: [Int] = []
    var latByKind: [String: [Int]] = [:]   // mode réserve : seed/hit/refill/miss.
}

func score(_ runs: [SentenceRun], name: String) -> Scorecard {
    var sc = Scorecard()
    sc.name = name
    for run in runs {
        let chars = run.chars
        let n = chars.count
        sc.totalChars += n

        // ── Couverture + latence par step. ──
        for i in 1..<n {
            guard let st = run.steps[i] else { continue }
            sc.stepsTotal += 1
            if st.g2 { sc.stepsG2 += 1 }
            if !st.ghost.isEmpty { sc.stepsNonEmpty += 1 }
            sc.latAll.append(st.ms)
            if st.boundary { sc.latBoundary.append(st.ms) } else { sc.latMid.append(st.ms) }
            if !st.kind.isEmpty { sc.latByKind[st.kind, default: []].append(st.ms) }
        }

        // ── KTC + stabilité par mot. ──
        for w in wordRanges(chars) {
            let initial = isSentenceInitial(chars, wordStart: w.start)
            // hit@0 : juste après l'espace, le mot ENTIER est-il deviné ?
            if !initial, w.start > 0, chars[w.start - 1] == " ", w.len >= 3,
               let st = run.steps[w.start] {
                sc.hitAt0Total += 1
                let truth = Array(chars[w.start...])
                if commonPrefixLen(Array(st.ghost), truth) >= w.len { sc.hitAt0Words += 1 }
            }
            guard w.len >= 3, !initial else { continue }
            sc.ktcWords += 1
            var firstHit: Int? = nil
            var correctAt: [Int: Bool] = [:]
            for k in 1..<w.len {
                let i = w.start + k
                guard i < n, let st = run.steps[i] else { continue }
                let truth = Array(chars[i...])
                let ok = !st.ghost.isEmpty
                    && commonPrefixLen(Array(st.ghost), truth) >= (w.len - k)
                correctAt[k] = ok
                if ok, firstHit == nil { firstHit = k }
            }
            if let k = firstHit {
                sc.ktcLettersNeeded.append(k)
                for bucket in [1, 2, 3, 4] where k <= bucket { sc.ktcHitAt[bucket]! += 1 }
            } else {
                sc.ktcNever += 1
            }
            // Stabilité : juste à k → encore juste à k+1 ?
            for k in 1..<(w.len - 1) {
                if correctAt[k] == true, correctAt[k + 1] != nil {
                    sc.holdPairs += 1
                    if correctAt[k + 1] == true { sc.holdKept += 1 }
                }
            }
        }

        // ── Cohérence de glissement (frappe == tête du ghost → le ghost glisse). ──
        for i in 1..<(n - 1) {
            guard let a = run.steps[i], let b = run.steps[i + 1], !a.ghost.isEmpty else { continue }
            let typed = chars[i]
            guard a.ghost.first == typed else { continue }
            let expected = String(a.ghost.dropFirst())
            guard !expected.isEmpty else { continue }
            sc.slidePairs += 1
            if b.ghost.hasPrefix(expected) || expected.hasPrefix(b.ghost), !b.ghost.isEmpty {
                sc.slideCoherent += 1
            }
        }

        // ── Économies : utilisateur parfait (full-accept et word-accept). ──
        for mode in ["full", "word"] {
            var i = 1                     // le 1ᵉʳ char est toujours tapé.
            var saved = 0, accepts = 0
            while i < n {
                guard let st = run.steps[i], !st.ghost.isEmpty else { i += 1; continue }
                let ghost = Array(st.ghost)
                let truth = Array(chars[i...])
                let match = commonPrefixLen(ghost, truth)
                var acceptLen = 0
                if mode == "full" {
                    if match == ghost.count { acceptLen = match }
                } else {
                    // Plus long préfixe du ghost juste ET fini sur un mot entier.
                    var j = match
                    while j > 0 {
                        if j == ghost.count || ghost[j] == " " { break }
                        j -= 1
                    }
                    acceptLen = j
                }
                if acceptLen >= 2 {       // Tab coûte 1 frappe → gain dès 2 chars.
                    saved += acceptLen - 1
                    accepts += 1
                    i += acceptLen
                } else {
                    i += 1
                }
            }
            if mode == "full" { sc.savedFull += saved; sc.acceptsFull += accepts }
            else { sc.savedWord += saved; sc.acceptsWord += accepts }
        }
    }
    return sc
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Moteur B : BEAM-CORE (pipeline exact de ModelRuntime.generateGhostBeam).
// ─────────────────────────────────────────────────────────────────────────────

guard let gguf = resolveGGUF() else {
    err("FATAL: GGUF introuvable. Pose SOUFFLEUSE_GGUF=<chemin>.")
    exit(1)
}

let forceMidword = (env["PARITY_BEAM_MIDWORD"] ?? "").lowercased() == "force"
// ctxPrefix réaliste de prod (persona + contexte app + OCR) pour mesurer le
// poids du re-prefill du prompt à chaque frappe (DIAGNOSTIC prefix-caching KV).
let longCtx: String = (env["PARITY_LONGCTX"] ?? "") == "1" ? """
L'utilisateur écrit depuis l'application Mail sur macOS. La fenêtre active est \
une réponse à un fil de discussion professionnel concernant le suivi d'un dossier \
client. Le ton employé est courtois et professionnel. À l'écran on peut lire le \
message précédent du correspondant : il remercie pour l'envoi du devis, demande \
une confirmation de disponibilité du produit pour une livraison la semaine \
prochaine, et signale qu'il sera joignable au bureau jusqu'à vendredi soir. \
La signature du correspondant indique qu'il est responsable des achats dans une \
entreprise de distribution basée à Lyon. L'utilisateur a l'habitude de répondre \
de manière concise, en confirmant les points demandés un par un, et termine \
généralement ses messages par une formule de politesse brève. Le presse-papiers \
contient la référence du dossier ainsi que le numéro de commande mentionnés plus \
tôt dans la conversation. La langue de la conversation est le français.
""" : ""
let beamConfig = BeamConfig.ghostCore()
let beamWidth = beamConfig.maxSearchWidth
let beamMaxWords = beamConfig.maxWords
let minLetters = BeamGhostShaper.beamMinSentenceLetters

let reserveMode = (env["PARITY_RESERVE"] ?? "") == "1"

func runBeamEngine() async -> [SentenceRun] {
    let beam = BeamGhostEngine(config: beamConfig)
    err("[parity] loading GGUF (beam-core, K=\(beamWidth)\(reserveMode ? ", RESERVE" : "")): \(gguf)")
    guard await beam.load(modelPath: gguf, contextTokens: 4096) else {
        err("FATAL: GGUF load failed (beam)"); exit(1)
    }
    var runs: [SentenceRun] = []
    for (si, s) in scenarios.enumerated() {
        // Session réserve : continuité de tail entre frappes (miroir de
        // `ModelRuntime.beamSessionTail`). Reset entre scénarios.
        var sessionTail: String?
        await beam.dropReserve()
        let run = await replay(s) { userTail in
            let t0 = Date()
            let armed = BeamGhostShaper.sentenceArmed(userTail: userTail, minLetters: minLetters)
            let partial = OutputFilter.trailingPartialWord(userTail)
            if !armed {
                sessionTail = nil
                return Step(i: userTail.count, ghost: "", ms: 0, g2: true, boundary: partial.isEmpty)
            }
            var choice = BeamGhostShaper.beamConfigChoice(userTail: userTail, beamWidth: beamWidth)
            // DIAGNOSTIC : ne jamais céder la contrainte mid-mot au juge « mot
            // complet » — quantifie le plafond du fix de routage (~41% des frappes
            // mid-mot partent en décode libre K=1 + espace forcé en prod).
            if forceMidword, !partial.isEmpty {
                choice = (requiredPrefix: partial, width: beamWidth, isBoundary: false)
            }
            let prompt = BeamGhostShaper.buildPrompt(customInstr: "", ctxPrefix: longCtx, llmTail: userTail)
            var raw = ""
            var kind = ""
            if reserveMode {
                // Miroir de ModelRuntime.generateGhostBeam sous SOUFFLEUSE_BEAM_RESERVE.
                if let prev = sessionTail, userTail.count == prev.count + 1,
                   userTail.hasPrefix(prev), await beam.hasReserve {
                    let a = await beam.advance(typedChar: userTail.last!,
                                               requiredPrefixForMiss: choice.requiredPrefix,
                                               missWidth: choice.width)
                    raw = a.ghost
                    switch a.kind {
                    case .hit: kind = "hit"
                    case .refill: kind = "refill"
                    case .miss: kind = "miss"
                    }
                } else {
                    let r = await beam.ghostWithReserve(prompt: prompt,
                                                        requiredPrefix: choice.requiredPrefix,
                                                        maxWidth: choice.width)
                    raw = r.best?.ghost ?? ""
                    kind = "seed"
                }
                sessionTail = userTail
            } else {
                let result = await beam.ghost(prompt: prompt, requiredPrefix: choice.requiredPrefix,
                                              maxWidth: choice.width)
                raw = result.best?.ghost ?? ""
            }
            let caretAfterSpace = userTail.last == " " || userTail.last == "\t"
            let ghost = BeamGhostShaper.beamPostFilter(
                rawGhost: raw, isBoundary: choice.isBoundary,
                caretAfterSpace: caretAfterSpace, userTail: userTail, maxWords: beamMaxWords)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            return Step(i: userTail.count, ghost: ghost, ms: ms, g2: false,
                        boundary: choice.isBoundary, kind: kind)
        }
        runs.append(run)
        err("[parity] beam \(si + 1)/\(scenarios.count)")
    }
    await beam.unload()
    return runs
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Moteur A : CASCADE de prod (miroir VERBATIM de SouffleuseCascadeVsBeamEval,
// lui-même miroir ligne-pour-ligne de `ModelRuntime.midWordLongGhost`).
// ─────────────────────────────────────────────────────────────────────────────

let cascadeEngine = LlamaEngine()
let dicoFloor = WordCompleter()

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

func runEscalationPass(
    prompt: String, partial: String, cap: Int,
    temperature: Float, seed: UInt32, captureP1: Bool
) async -> (lead: String, p1: Double?, fullLine: String) {
    final class Acc: @unchecked Sendable { var text = "" }
    let acc = Acc()
    let metrics = await cascadeEngine.generate(
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

func midWordEngagementResult(
    prompt: String, partial: String, maxTokens: Int,
    greedyFullLine: String, greedyP1: Double?, fullContinuation: String, why: String
) async -> (ghost: String, reason: String, engagement: String) {
    let greedyLead = SuggestionPolicy.midWordLeadWordDefrag(
        OutputFilter.singleLine(greedyFullLine), partial: partial)

    guard SuggestionPolicy.midWordExtendsStructurally(partial: partial, modal: greedyLead) else {
        if let floor = dicoFloorResult(partial: partial, greedyLead: greedyLead, why: "structdegen") {
            return (floor.word, "engage:" + floor.reason, "prudent")
        }
        return ("", "engage:zero(\(why))", "zero")
    }

    let isFastAccept = (greedyP1 ?? 0) >= escFastP1 && partial.count >= escMinFastLen
    var agreement = 1.0
    if !isFastAccept {
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
        } else {
            agreement = 0
        }
    }

    let level = SuggestionPolicy.midWordEngagementLevel(
        partial: partial, greedyLeadWord: greedyLead,
        firstTokenProb: greedyP1, agreement: agreement)
    let agreeStr = String(format: "%.2f", agreement)

    switch level {
    case .zero:
        if let floor = dicoFloorResult(partial: partial, greedyLead: greedyLead, why: "agree=\(agreeStr)") {
            return (floor.word, "engage:" + floor.reason, "prudent")
        }
        return ("", "engage:zero(agree=\(agreeStr))", "zero")
    case .prudent:
        let prudent = firstWholeWord(of: fullContinuation)
        return (prudent, "engage:prudent(agree=\(agreeStr))", "prudent")
    case .plein:
        return (fullContinuation, "engage:plein(agree=\(agreeStr))", "plein")
    }
}

func cascadeGhost(prefix: String) async -> (ghost: String, ms: Int, boundary: Bool) {
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
    let greedyMetrics = await cascadeEngine.generate(
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
    var why = result.isEmpty ? "emptygen" : "ok"

    if !result.isEmpty {
        let echoVal = OutputFilter.echoScore(ghost: result, tail: userTail)
        if echoVal >= echoThreshold {
            let run = OutputFilter.longestVerbatimRunWords(ghost: result, tail: userTail)
            if run >= echoMinRun {
                why = "echo"
                result = ""
            }
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
    if result.isEmpty, why == "ok" { why = "trim" }

    if engagementOn, !isBoundary, result.first != " " {
        let r = await midWordEngagementResult(
            prompt: prompt, partial: partial, maxTokens: cap,
            greedyFullLine: acc.text, greedyP1: greedyMetrics.firstTokenProb,
            fullContinuation: result, why: why)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        return (r.ghost, ms, isBoundary)
    }

    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    return (result, ms, isBoundary)
}

func runCascadeEngine() async -> [SentenceRun] {
    err("[parity] loading GGUF (cascade, engagement=\(engagementOn ? "ON" : "OFF")): \(gguf)")
    guard await cascadeEngine.load(modelPath: gguf, contextTokens: 4096) else {
        err("FATAL: GGUF load failed (cascade)"); exit(1)
    }
    await cascadeEngine.setCorpus([])
    var runs: [SentenceRun] = []
    for (si, s) in scenarios.enumerated() {
        let run = await replay(s) { prefix in
            let r = await cascadeGhost(prefix: prefix)
            return Step(i: prefix.count, ghost: r.ghost, ms: r.ms, g2: false, boundary: r.boundary)
        }
        runs.append(run)
        err("[parity] cascade \(si + 1)/\(scenarios.count)")
    }
    await cascadeEngine.unload()
    return runs
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Run + dump.
// ─────────────────────────────────────────────────────────────────────────────

var cards: [Scorecard] = []
var allRuns: [(String, [SentenceRun])] = []

if runCascade {
    let runs = await runCascadeEngine()
    cards.append(score(runs, name: "cascade"))
    allRuns.append(("cascade", runs))
}
if runBeam {
    let runs = await runBeamEngine()
    cards.append(score(runs, name: "beam-core"))
    allRuns.append(("beam-core", runs))
}

// Dump JSONL optionnel (un step par ligne) pour analyse hors-bande.
if let path = env["PARITY_JSONL"], !path.isEmpty {
    struct Line: Codable {
        let engine: String
        let sentence: Int
        let i: Int
        let ghost: String
        let ms: Int
        let g2: Bool
        let boundary: Bool
    }
    var out = ""
    let enc = JSONEncoder()
    for (name, runs) in allRuns {
        for (si, run) in runs.enumerated() {
            for i in run.steps.keys.sorted() {
                let st = run.steps[i]!
                let line = Line(engine: name, sentence: si, i: i, ghost: st.ghost,
                                ms: st.ms, g2: st.g2, boundary: st.boundary)
                if let d = try? enc.encode(line), let s = String(data: d, encoding: .utf8) {
                    out += s + "\n"
                }
            }
        }
    }
    try? out.write(toFile: (path as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
    err("[parity] JSONL → \(path)")
}

if verbose {
    for (name, runs) in allRuns {
        print("")
        print("════════ TRACE \(name) ════════")
        for run in runs {
            print("« \(run.sentence) »")
            for i in run.steps.keys.sorted() {
                let st = run.steps[i]!
                let tag = st.g2 ? "·G2·" : (st.ghost.isEmpty ? "·∅·" : "    ")
                print("  \(tag) \(String(run.chars.prefix(i)).suffix(36).debugDescription) → \(st.ghost.debugDescription) \(st.ms)ms")
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Scorecard comparatif.
// ─────────────────────────────────────────────────────────────────────────────

func padR(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

print("")
print("════════════════════════════════════════════════════════════════════════")
print(" SouffleuseParityEval — \(scenarios.count) phrases · pas=\(stepChars) char · corpus OFF · perso OFF")
print(" KTC = lettres tapées avant que le ghost donne la suite EXACTE du mot")
print(" (mots ≥3 lettres, hors 1ᵉʳ mot de phrase — G2 silencie <3 lettres côté beam)")
print("════════════════════════════════════════════════════════════════════════")

let labels = cards.map { $0.name }
func row(_ label: String, _ values: [String]) {
    print("  " + padR(label, 42) + values.map { padR($0, 16) }.joined())
}

print("")
row("", labels)
print("  " + String(repeating: "─", count: 42 + 16 * cards.count))

row("QUALITÉ — mot juste (KTC, \(cards.first?.ktcWords ?? 0) mots)", cards.map { _ in "" })
for k in [1, 2, 3, 4] {
    row("  ghost juste à ≤\(k) lettre\(k > 1 ? "s" : "")", cards.map { pct($0.ktcHitAt[k]!, $0.ktcWords) })
}
row("  jamais juste sur ce mot", cards.map { pct($0.ktcNever, $0.ktcWords) })
row("  lettres nécessaires (médiane)", cards.map { c in
    c.ktcLettersNeeded.isEmpty ? "–" : "\(percentile(c.ktcLettersNeeded, 0.5))"
})
row("  mot entier deviné à 0 lettre (après-espace)", cards.map { pct($0.hitAt0Words, $0.hitAt0Total) })

print("")
row("ÉCONOMIES (utilisateur parfait, Tab=1 frappe)", cards.map { _ in "" })
row("  frappes économisées (full-accept)", cards.map { pct($0.savedFull, $0.totalChars) })
row("  frappes économisées (word-accept)", cards.map { pct($0.savedWord, $0.totalChars) })
row("  accepts (full / word)", cards.map { "\($0.acceptsFull) / \($0.acceptsWord)" })

print("")
row("STABILITÉ / COHÉRENCE", cards.map { _ in "" })
row("  ghost juste qui le RESTE à k+1", cards.map { pct($0.holdKept, $0.holdPairs) })
row("  glissement cohérent (frappe==tête ghost)", cards.map { pct($0.slideCoherent, $0.slidePairs) })
row("  ghost non vide (couverture)", cards.map { pct($0.stepsNonEmpty, $0.stepsTotal) })
row("  silences G2 (après un point)", cards.map { "\($0.stepsG2)" })

print("")
row("LATENCE par frappe (ms)", cards.map { _ in "" })
row("  moyenne / p50", cards.map { "\(mean($0.latAll)) / \(percentile($0.latAll, 0.5))" })
row("  p95 / max", cards.map { "\(percentile($0.latAll, 0.95)) / \($0.latAll.max() ?? 0)" })
row("  mid-mot p50", cards.map { "\(percentile($0.latMid, 0.5))" })
row("  frontière/après-espace p50", cards.map { "\(percentile($0.latBoundary, 0.5))" })
if cards.contains(where: { !$0.latByKind.isEmpty }) {
    print("")
    row("RÉSERVE par type de frappe (n · p50 ms)", cards.map { _ in "" })
    for kind in ["hit", "refill", "miss", "seed"] {
        row("  \(kind)", cards.map { c in
            guard let xs = c.latByKind[kind], !xs.isEmpty else { return "–" }
            let share = c.stepsTotal == 0 ? 0 : xs.count * 100 / c.stepsTotal
            return "\(xs.count) (\(share)%) · \(percentile(xs, 0.5))"
        })
    }
}

print("")
print("  steps jugés : " + cards.map { "\($0.name)=\($0.stepsTotal)" }.joined(separator: " · "))
print("FIN.")
