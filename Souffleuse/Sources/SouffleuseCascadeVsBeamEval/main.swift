import Foundation
import SouffleuseCore
import SouffleuseLlama
import SouffleuseLog
import SouffleuseTyping

// ─────────────────────────────────────────────────────────────────────────────
// SouffleuseCascadeVsBeamEval — la VRAIE cascade de prod vs le beam Cotypist.
//
// Les évals beam antérieures (`SouffleuseBeamEval`) comparaient le beam à une
// passe GREEDY BRUTE. Ce n'est PAS le comportement de prod. La prod fait tourner
// la CASCADE complète de `ModelRuntime.midWordLongGhost` :
//   greedy healed → gradient d'engagement (PLEIN/PRUDENT/ZÉRO, branches votées)
//   → plancher dico (NSSpellChecker) → garde écho positionnel.
// C'est CETTE cascade que cette éval reproduit (chemin A), face au beam (chemin B),
// sur un GROS corpus FR diversifié.
//
// Chemin A = MIROIR FIDÈLE de `ModelRuntime.midWordLongGhost` (+ `midWordEngagementResult`
// + `dicoFloorResult`) avec les MÊMES flags que l'utilisateur lance :
//   MW_ENGAGEMENT=1 MW_ENG_PRUDENT=0 MW_ENG_PLEIN=0.8  (dico floor ON, MW_ECHO_RUN=4)
// On RÉUTILISE les fonctions de lib réelles que ModelRuntime appelle (jamais de
// ré-implémentation) ; seule l'ORCHESTRATION est mirroir (ModelRuntime vit dans le
// target app `Souffleuse`, non importable).
//
// HORS PÉRIMÈTRE explicite : `routeInstant` (recall instantané L1/L0) et la
// personnalisation n-gram. Corpus OFF des deux côtés (`setCorpus([])`) → apples-
// to-apples. Cette éval mesure la COUCHE DE GÉNÉRATION LLM — la partie qui
// CONCOURT contre le beam —, pas la couche de recall instantané.
//
// Usage :
//   SOUFFLEUSE_BEAM=1 MW_ENGAGEMENT=1 MW_ENG_PRUDENT=0 MW_ENG_PLEIN=0.8 \
//     SOUFFLEUSE_GGUF=~/…/gemma-3-1b.i1-Q5_K_M.gguf \
//     swift run SouffleuseCascadeVsBeamEval
// ─────────────────────────────────────────────────────────────────────────────

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let env = ProcessInfo.processInfo.environment
let beamEnabled = (env["SOUFFLEUSE_BEAM"].map { !$0.isEmpty }) ?? false
if !beamEnabled {
    err("[cascade-vs-beam] SOUFFLEUSE_BEAM absent → éval désactivée. Relance avec SOUFFLEUSE_BEAM=1.")
    exit(0)
}

// Annonce des flags effectifs côté cascade (lus par les `Tuning.*` runtime).
err("[cascade-vs-beam] flags cascade : MW_ENGAGEMENT=\(env["MW_ENGAGEMENT"] ?? "(absent)") " +
    "MW_ENG_PRUDENT=\(env["MW_ENG_PRUDENT"] ?? "(défaut 0.5)") " +
    "MW_ENG_PLEIN=\(env["MW_ENG_PLEIN"] ?? "(défaut 0.8)") " +
    "DICO_FLOOR=\(SuggestionPolicy.Tuning.midWordDicoFloorEnabled ? "ON" : "OFF") " +
    "ECHO_RUN=\(SuggestionPolicy.Tuning.echoMinVerbatimRunWords)")

// MARK: - Corpus

/// Un cas de test. `expectAgreement` (optionnel) = la SURFACE attendue
/// grammaticalement correcte pour un piège d'accord (« fiscal », « importante »…),
/// servant le flag automatique AGREEMENT-OK.
struct Case {
    let label: String
    let prefix: String
    /// Pour les pièges d'accord : la forme correcte attendue (annotée à la main).
    /// Le flag AGREEMENT-OK vérifie que le mot complété par le chemin == cette forme.
    var expectAgreement: String? = nil
}

let cases: [Case] = [
    // ── (a) PIÈGES D'ACCORD genre/nombre — la forme correcte est annotée. ──────
    .init(label: "accord", prefix: "Je dois finaliser mon rapport fisca", expectAgreement: "fiscal"),
    .init(label: "accord", prefix: "C'est une décision import", expectAgreement: "importante"),
    .init(label: "accord", prefix: "Nous avons reçu des données person", expectAgreement: "personnelles"),
    .init(label: "accord", prefix: "Voici la première vers", expectAgreement: "version"),
    .init(label: "accord", prefix: "Les nouveaux model", expectAgreement: "modèles"),
    .init(label: "accord", prefix: "Voici le document fina", expectAgreement: "final"),
    .init(label: "accord", prefix: "Une réponse rapide et appropri", expectAgreement: "appropriée"),
    .init(label: "accord", prefix: "Des résultats encourage", expectAgreement: "encourageants"),
    .init(label: "accord", prefix: "La nouvelle politique commercial", expectAgreement: "commerciale"),
    .init(label: "accord", prefix: "Ce sont des informations confidenti", expectAgreement: "confidentielles"),

    // ── (b) ÉCHO / boucles — phrases auto-similaires, structures répétées. ──────
    .init(label: "écho", prefix: "je cherche à savoir si la radioactivité est un dan"),
    .init(label: "écho", prefix: "Le chat dort sur le canapé. Le chat dort sur le canapé pendant que le chat dor"),
    .init(label: "écho", prefix: "Il faut acheter du pain, du lait, des œufs, du beurre, du pain, du lait et du beu"),
    .init(label: "écho", prefix: "Merci pour votre patience. Nous vous remercions encore une fois pour votre pati"),
    .init(label: "écho", prefix: "Je suis développeur. Je suis passionné. Je suis curieux. Je suis dévelo"),
    .init(label: "écho", prefix: "Plus j'apprends, plus je réalise à quel point j'ai encore beaucoup à appr"),
    .init(label: "écho", prefix: "On répète toujours les mêmes erreurs, encore et encore et enc"),

    // ── (c) MID-MOT à profondeurs variées (3,4,5,6 chars de fragment). ─────────
    .init(label: "mid3", prefix: "Pouvez-vous con"),
    .init(label: "mid3", prefix: "Je vais bien et toi com"),
    .init(label: "mid4", prefix: "Pouvez-vous conf"),
    .init(label: "mid4", prefix: "Nous avons bien reçu votre comm"),
    .init(label: "mid5", prefix: "Je reviendrai vers vous dès que possi"),
    .init(label: "mid5", prefix: "Le projet avance, on livre la premi"),
    .init(label: "mid6", prefix: "Je suis un fan de la technologie et des voitures électr"),
    .init(label: "mid6", prefix: "Bonjour, je vous remercie pour votre message. Je revie"),
    .init(label: "mid6", prefix: "J'aimerais beaucoup discuter de cette opportu"),

    // ── (d) APRÈS-ESPACE / mot suivant (décodage libre). ───────────────────────
    .init(label: "espace", prefix: "Je peux vous envoyer "),
    .init(label: "espace", prefix: "La réunion aura lieu "),
    .init(label: "espace", prefix: "Merci beaucoup pour "),
    .init(label: "espace", prefix: "Je vous confirme que "),
    .init(label: "espace", prefix: "N'hésitez pas à me "),
    .init(label: "espace", prefix: "Je reste à votre "),
    .init(label: "espace", prefix: "Pourriez-vous me dire si "),
    .init(label: "espace", prefix: "Nous serions ravis de "),

    // ── (e) PRÈS de fin de phrase (frontière de clause imminente). ─────────────
    .init(label: "find-phrase", prefix: "Le rapport est prêt et je vous le transmets dès aujourd'h"),
    .init(label: "fin-phrase", prefix: "Tout est en ordre, nous pouvons donc avan"),
    .init(label: "fin-phrase", prefix: "C'était un plaisir de vous rencontrer aujourd"),
    .init(label: "fin-phrase", prefix: "Je vous souhaite une excellente journ"),

    // ── Emails professionnels. ─────────────────────────────────────────────────
    .init(label: "email-pro", prefix: "Bonjour Madame, suite à notre échange téléphonique, je me permets de vous reli"),
    .init(label: "email-pro", prefix: "Je me permets de revenir vers vous concernant ma candida"),
    .init(label: "email-pro", prefix: "Veuillez trouver ci-joint le devis correspondant à votre dem"),
    .init(label: "email-pro", prefix: "Suite à votre demande, je vous confirme la disponibi"),
    .init(label: "email-pro", prefix: "Je reste bien entendu à votre disposition pour tout complé"),

    // ── Chat / SMS (registre familier, phrases courtes). ───────────────────────
    .init(label: "chat", prefix: "ok pas de souci, on se voit dem"),
    .init(label: "chat", prefix: "trop bien ! j'arrive dans cinq min"),
    .init(label: "chat", prefix: "tu peux me rappeler quand tu as un mom"),
    .init(label: "chat", prefix: "désolé pour le retard, je suis coincé dans les embou"),
    .init(label: "chat", prefix: "merci pour hier soir, c'était vraiment sym"),

    // ── Bios (structures répétées, risque d'écho). ─────────────────────────────
    .init(label: "bio", prefix: "Développeur passionné, j'aime créer des produits qui ont du sens et résoudre des problè"),
    .init(label: "bio", prefix: "Photographe basé à Paris, je capture des instants de vie et des paysages extraordin"),
    .init(label: "bio", prefix: "Entrepreneur dans la tech, je construis des outils pour aider les équipes à mieux collab"),

    // ── Narratif. ──────────────────────────────────────────────────────────────
    .init(label: "narratif", prefix: "Le soleil se couchait lentement derrière les collines tandis que les oiseaux reg"),
    .init(label: "narratif", prefix: "Elle ouvrit la porte avec précaution, le cœur battant, sans savoir ce qui l'att"),
    .init(label: "narratif", prefix: "La vieille horloge sonna minuit et la maison entière sembla retenir son souf"),

    // ── Écriture technique. ────────────────────────────────────────────────────
    .init(label: "technique", prefix: "Pour configurer le serveur, il faut d'abord installer les dépendances puis lan"),
    .init(label: "technique", prefix: "La fonction prend en entrée un tableau d'entiers et retourne la somme des élé"),
    .init(label: "technique", prefix: "En cas d'erreur, le système écrit un message dans le fichier de journalisa"),
    .init(label: "technique", prefix: "Cette API expose un point de terminaison REST qui accepte des requêtes au format"),
]

// MARK: - Boot des deux moteurs

let ggufPath = (env["SOUFFLEUSE_GGUF"].flatMap { $0.isEmpty ? nil : $0 }
    ?? "~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf")
let resolved = (ggufPath as NSString).expandingTildeInPath

let beamConfig = BeamConfig.fromEnvironment()

let engine = LlamaEngine()
err("[cascade-vs-beam] loading GGUF (cascade): \(resolved)")
guard await engine.load(modelPath: resolved, contextTokens: 4096) else {
    err("FATAL: GGUF load failed (cascade)"); exit(1)
}
await engine.setCorpus([])   // corpus OFF — apples-to-apples avec le beam.

let beam = BeamGhostEngine(config: beamConfig)
err("[cascade-vs-beam] loading GGUF (beam, n_seq_max=\(beamConfig.maxSearchWidth + 1)): \(resolved)")
guard await beam.load(modelPath: resolved, contextTokens: 4096) else {
    err("FATAL: GGUF load failed (beam)"); exit(1)
}

// Le WordCompleter réel utilisé par le plancher dico de prod (`dicoFloorResult`).
let dicoFloor = WordCompleter()

// MARK: - Chemin A : MIROIR de la cascade de prod (`ModelRuntime.midWordLongGhost`)

/// Métriques détaillées d'un souffle cascade (pour observabilité d'éval).
struct CascadeResult {
    let ghost: String           // le ghost que la prod PEINDRAIT.
    let reason: String          // raison granulaire (longghost / engage:plein / floor-dico / …).
    let ms: Int
    let engagement: String      // plein / prudent / zero / n-a.
}

/// Constantes de prod, lues une fois (mêmes seuils que ModelRuntime).
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

/// Une passe d'escalade (greedy ou branche) — MIROIR de `ModelRuntime.runEscalationPass`.
/// Renvoie le mot de tête défragmenté + la confiance top-1 (si demandée) + la ligne complète.
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

/// MIROIR de `ModelRuntime.firstWholeWord(of:)`.
func firstWholeWord(of ghost: String) -> String {
    let hadLeadingSpace = ghost.first == " "
    let words = ghost.split(whereSeparator: { $0.isWhitespace })
    guard let first = words.first else { return ghost }
    let one = String(first)
    return hadLeadingSpace ? " " + one : one
}

/// MIROIR de `ModelRuntime.dicoFloorResult` — plancher dico via le WordCompleter réel.
/// Renvoie (suffixe, raison) ou nil si pas de candidat / flag coupé.
func dicoFloorResult(partial: String, greedyLead: String, why: String) -> (word: String, reason: String)? {
    guard SuggestionPolicy.Tuning.midWordDicoFloorEnabled else { return nil }
    guard let suffix = dicoFloor.completion(for: partial, preferring: greedyLead),
          !suffix.isEmpty else { return nil }
    return (suffix, "floor-dico(\(why))")
}

/// MIROIR de `ModelRuntime.midWordEngagementResult` — décide PLEIN/PRUDENT/ZÉRO en
/// réutilisant les branches d'escalade + `midWordEngagementLevel`, avec plancher dico.
func midWordEngagementResult(
    prompt: String, partial: String, maxTokens: Int,
    greedyFullLine: String, greedyP1: Double?, fullContinuation: String, why: String
) async -> (ghost: String, reason: String, engagement: String) {
    let greedyLead = SuggestionPolicy.midWordLeadWordDefrag(
        OutputFilter.singleLine(greedyFullLine), partial: partial)

    // Dégénéré STRUCTUREL ⇒ plancher dico, sinon ZÉRO.
    guard SuggestionPolicy.midWordExtendsStructurally(partial: partial, modal: greedyLead) else {
        if let floor = dicoFloorResult(partial: partial, greedyLead: greedyLead, why: "structdegen") {
            return (floor.word, "engage:" + floor.reason, "prudent")
        }
        return ("", "engage:zero(\(why))", "zero")
    }

    // Fast-accept ⇒ PLEIN sans brancher.
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

/// MIROIR FIDÈLE de `ModelRuntime.midWordLongGhost` — le chemin de génération de prod.
/// Reproduit ligne-pour-ligne : greedy healed (1 passe), splice de continuation,
/// séparateur d'espace, dédup, garde écho positionnelle, coupe de clause, word-cap,
/// puis gradient d'engagement (mid-mot collé seulement).
func cascadeGhost(prefix: String) async -> CascadeResult {
    let t0 = Date()
    let userTail = prefix
    let llmTail = prefix    // pas de correction typo dans l'éval → llmTail == userTail.
    let partial = OutputFilter.trailingPartialWord(userTail)
    let isBoundary = partial.isEmpty || SuggestionPolicy.defaultPartialWordIsComplete(userTail)

    let prompt = LlamaPromptBuilder.buildLlamaPrompt(
        system: "", customInstr: "", ctxPrefix: "", fieldContext: "",
        afterCursor: "", beforeCursor: llmTail)

    // Budget = défaut de prod (request.maxTokens 14 / maxWords 4 — cf. long-ghost).
    let cap = SuggestionPolicy.Tuning.midWordLongGhostMaxTokens
    let ghostMaxWords = SuggestionPolicy.Tuning.midWordLongGhostMaxWords

    // ── UNE passe greedy healed (profil prod). minFirstTokenProb = epsilon sous
    //    engagement (capte P1 sans aborter), 0 sinon — comme ModelRuntime.
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

    // Splice : retire le partiel de la ligne greedy (sauf frontière).
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

    // Garde ÉCHO POSITIONNELLE (echoScore ≥ 0.5 ET run verbatim ≥ MW_ECHO_RUN).
    if !result.isEmpty {
        let echoVal = OutputFilter.echoScore(ghost: result, tail: userTail)
        if echoVal >= echoThreshold {
            let run = OutputFilter.longestVerbatimRunWords(ghost: result, tail: userTail)
            if run >= echoMinRun {
                why = "echo(s=\(String(format: "%.2f", echoVal)) run=\(run))"
                result = ""
            }
        }
    }
    // Garde langue OFF par défaut (MW_LG_LANGGUARD absent) → on ne l'applique pas.

    // Coupe à la 1ʳᵉ frontière de clause.
    if let idx = result.firstIndex(where: { "\n.!?;:".contains($0) }) {
        result = String(result[...idx])
    }
    // Cap à N mots entiers (espace de tête préservé).
    let words = result.split(whereSeparator: { $0.isWhitespace })
    if words.count > ghostMaxWords {
        let hadLeadingSpace = result.first == " "
        result = words.prefix(ghostMaxWords).joined(separator: " ")
        if hadLeadingSpace, result.first != " ", !result.isEmpty { result = " " + result }
    }
    result = OutputFilter.singleLine(result)
    if result.isEmpty, why == "ok" { why = "trim" }

    // ── Gradient d'engagement (mid-mot collé seulement, comme ModelRuntime).
    if engagementOn, !isBoundary, result.first != " " {
        let r = await midWordEngagementResult(
            prompt: prompt, partial: partial, maxTokens: cap,
            greedyFullLine: acc.text, greedyP1: greedyMetrics.firstTokenProb,
            fullContinuation: result, why: why)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        return CascadeResult(ghost: r.ghost, reason: "longghost-" + r.reason, ms: ms,
                             engagement: r.engagement)
    }

    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    return CascadeResult(ghost: result, reason: result.isEmpty ? "longghost-\(why)" : "longghost",
                         ms: ms, engagement: "n-a")
}

// MARK: - Chemin B : le beam

func beamGhost(prefix: String, partial: String) async -> BeamResult {
    let prompt = LlamaPromptBuilder.buildLlamaPrompt(
        system: "", customInstr: "", ctxPrefix: "", fieldContext: "",
        afterCursor: "", beforeCursor: prefix)
    return await beam.ghost(prompt: prompt, requiredPrefix: partial)
}

// MARK: - Flags automatiques

func f2(_ x: Double) -> String { String(format: "%.2f", x) }

/// Le mot complété par un ghost mid-mot = partiel + (le ghost jusqu'au 1ᵉʳ
/// non-alphanumérique). Sert le flag AGREEMENT-OK. Le ghost de prod est le
/// SUFFIXE (« l » pour « fiscal » sur « fisca »), donc on recolle.
func completedWord(partial: String, ghost: String) -> String {
    let g = ghost.drop(while: { $0 == " " || $0 == "\t" })
    let run = g.prefix(while: { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" })
    return (partial + run).lowercased()
}

/// AGREEMENT-OK : le mot complété correspond-il à la forme attendue ? On compare
/// sur le PRÉFIXE attendu (le ghost peut s'arrêter avant la fin du mot, ex. « fisca »
/// + « l » = « fiscal » exact, mais « importante » peut sortir « importa… »).
func agreementOK(expect: String, partial: String, ghost: String) -> Bool {
    let got = completedWord(partial: partial, ghost: ghost)
    let want = expect.lowercased()
    guard got.count > partial.count else { return false }
    // Correct si le mot obtenu est un préfixe de la forme attendue (et la dépasse
    // le partiel), OU l'égale. Un mot qui DÉVIE (« fiscaux ») n'est pas un préfixe.
    return want.hasPrefix(got) || got == want
}

/// ECHO-RUN : run verbatim ≥ MW_ECHO_RUN recopié du tail (mesuré par la lib réelle).
func echoRunWords(ghost: String, tail: String) -> Int {
    guard !ghost.trimmingCharacters(in: .whitespaces).isEmpty else { return 0 }
    return OutputFilter.longestVerbatimRunWords(ghost: ghost, tail: tail)
}

// MARK: - Run

print("")
print("════════════════════════════════════════════════════════════════════════")
print(" SouffleuseCascadeVsBeamEval — \(cases.count) cas")
print(" A = CASCADE de prod (greedy + engagement + dico floor + garde écho)")
print(" B = beam Cotypist (K=\(beamConfig.maxSearchWidth), exp=\(beamConfig.positionExponent), minP=\(beamConfig.minBranchProbability))")
print(" corpus OFF des deux côtés · routeInstant/perso HORS périmètre")
print("════════════════════════════════════════════════════════════════════════")

struct Row {
    let label: String
    let prefix: String
    let partial: String
    let cascade: String
    let cascadeReason: String
    let cascadeEng: String
    let cascadeMs: Int
    let beamBest: String
    let beamAlts: [String]
    let beamMs: Int
    let expectAgreement: String?
}
var rows: [Row] = []

var cascadeMsTotal = 0, beamMsTotal = 0
var cascadeMsList: [Int] = [], beamMsList: [Int] = []

for c in cases {
    let partial = OutputFilter.trailingPartialWord(c.prefix)
    let a = await cascadeGhost(prefix: c.prefix)
    let b = await beamGhost(prefix: c.prefix, partial: partial)
    cascadeMsTotal += a.ms; beamMsTotal += b.elapsedMillis
    cascadeMsList.append(a.ms); beamMsList.append(b.elapsedMillis)
    let bBest = b.best?.ghost ?? ""
    let bAlts = Array(b.candidates.dropFirst().prefix(2).map { $0.ghost })

    rows.append(Row(label: c.label, prefix: c.prefix, partial: partial,
                    cascade: a.ghost, cascadeReason: a.reason, cascadeEng: a.engagement,
                    cascadeMs: a.ms, beamBest: bBest, beamAlts: bAlts, beamMs: b.elapsedMillis,
                    expectAgreement: c.expectAgreement))

    // ── Impression par cas ──
    print("")
    print("── [\(c.label)] \(c.prefix.debugDescription)")
    if !partial.isEmpty { print("   mid-mot, fragment = \(partial.debugDescription)") }
    else { print("   après-espace / frontière") }
    var aFlags: [String] = []
    if a.ghost.trimmingCharacters(in: .whitespaces).isEmpty { aFlags.append("EMPTY") }
    if let exp = c.expectAgreement {
        aFlags.append(agreementOK(expect: exp, partial: partial, ghost: a.ghost) ? "AGREE-OK" : "AGREE-BAD")
    }
    let aRun = echoRunWords(ghost: a.ghost, tail: c.prefix)
    if aRun >= echoMinRun { aFlags.append("ECHO-RUN=\(aRun)") }
    print("   (A) cascade : \(a.ghost.debugDescription)   [\(a.reason)]   (\(a.ms) ms)\(aFlags.isEmpty ? "" : "   ⚑ " + aFlags.joined(separator: " "))")

    var bFlags: [String] = []
    if bBest.trimmingCharacters(in: .whitespaces).isEmpty { bFlags.append("EMPTY") }
    if let exp = c.expectAgreement {
        bFlags.append(agreementOK(expect: exp, partial: partial, ghost: bBest) ? "AGREE-OK" : "AGREE-BAD")
    }
    let bRun = echoRunWords(ghost: bBest, tail: c.prefix)
    if bRun >= echoMinRun { bFlags.append("ECHO-RUN=\(bRun)") }
    print("   (B) beam    : \(bBest.debugDescription)   (\(b.elapsedMillis) ms)\(bFlags.isEmpty ? "" : "   ⚑ " + bFlags.joined(separator: " "))")
    if !bAlts.isEmpty {
        print("       beam alts : " + bAlts.map { $0.debugDescription }.joined(separator: "  ·  "))
    }
}

// MARK: - Synthèse agrégée

func mean(_ xs: [Int]) -> Int { xs.isEmpty ? 0 : xs.reduce(0, +) / xs.count }
func median(_ xs: [Int]) -> Int {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted(); let n = s.count
    return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
}

func isEmpty(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }

// EMPTY croisé.
let cascadeEmptyBeamNot = rows.filter { isEmpty($0.cascade) && !isEmpty($0.beamBest) }
let beamEmptyCascadeNot = rows.filter { isEmpty($0.beamBest) && !isEmpty($0.cascade) }
let bothEmpty = rows.filter { isEmpty($0.cascade) && isEmpty($0.beamBest) }

// Accord.
let agreementRows = rows.filter { $0.expectAgreement != nil }
var cascadeAgreeOK = 0, beamAgreeOK = 0
for r in agreementRows {
    if agreementOK(expect: r.expectAgreement!, partial: r.partial, ghost: r.cascade) { cascadeAgreeOK += 1 }
    if agreementOK(expect: r.expectAgreement!, partial: r.partial, ghost: r.beamBest) { beamAgreeOK += 1 }
}

// Écho (run ≥ seuil) qui a FUITÉ à l'écran.
let cascadeEchoLeak = rows.filter { echoRunWords(ghost: $0.cascade, tail: $0.prefix) >= echoMinRun }
let beamEchoLeak = rows.filter { echoRunWords(ghost: $0.beamBest, tail: $0.prefix) >= echoMinRun }

print("")
print("────────────────────────────────────────────────────────────────────────")
print(" SYNTHÈSE AGRÉGÉE")
print("────────────────────────────────────────────────────────────────────────")
print("  Cas testés ........................ \(cases.count)")
print("")
print("  VIDE (EMPTY) :")
print("    cascade VIDE & beam non-vide ..... \(cascadeEmptyBeamNot.count)")
print("    beam VIDE & cascade non-vide ..... \(beamEmptyCascadeNot.count)")
print("    les DEUX vides ................... \(bothEmpty.count)")
if !cascadeEmptyBeamNot.isEmpty {
    print("    → cascade s'abstient là où le beam parle :")
    for r in cascadeEmptyBeamNot { print("        [\(r.label)] …\(String(r.prefix.suffix(30)))  beam=\(r.beamBest.debugDescription)  [\(r.cascadeReason)]") }
}
if !beamEmptyCascadeNot.isEmpty {
    print("    → beam s'abstient là où la cascade parle :")
    for r in beamEmptyCascadeNot { print("        [\(r.label)] …\(String(r.prefix.suffix(30)))  cascade=\(r.cascade.debugDescription)") }
}
print("")
print("  PIÈGES D'ACCORD (\(agreementRows.count) cas annotés) :")
print("    cascade CORRECT .................. \(cascadeAgreeOK) / \(agreementRows.count)")
print("    beam CORRECT ..................... \(beamAgreeOK) / \(agreementRows.count)")
for r in agreementRows {
    let cOK = agreementOK(expect: r.expectAgreement!, partial: r.partial, ghost: r.cascade)
    let bOK = agreementOK(expect: r.expectAgreement!, partial: r.partial, ghost: r.beamBest)
    print("    \(r.prefix.debugDescription)  attendu=\(r.expectAgreement!.debugDescription)")
    print("        cascade \(cOK ? "✓" : "✗") =\(completedWord(partial: r.partial, ghost: r.cascade).debugDescription)   |   beam \(bOK ? "✓" : "✗") =\(completedWord(partial: r.partial, ghost: r.beamBest).debugDescription)")
}
print("")
print("  ÉCHO (run verbatim ≥ \(echoMinRun) mots qui a FUITÉ à l'écran) :")
print("    cascade .......................... \(cascadeEchoLeak.count)  (la garde écho positionnelle aurait dû les tuer)")
print("    beam ............................. \(beamEchoLeak.count)")
print("")
print("  LATENCE (génération à froid, sans amorti) :")
print("    cascade moy / médiane ............ \(mean(cascadeMsList)) / \(median(cascadeMsList)) ms")
print("    beam (froid) moy / médiane ....... \(mean(beamMsList)) / \(median(beamMsList)) ms")
print("    surcoût beam vs cascade .......... ×\(f2(Double(beamMsTotal) / Double(max(1, cascadeMsTotal))))")
print("    NOTE amorti : la cascade engagement lance jusqu'à K=\(escBranchK) branches")
print("       sur les cas incertains (mid-mot), d'où sa latence à froid. Le beam,")
print("       lui, s'AMORTIT à la frappe via la réserve KV (HIT ≈ 0 ms, cf.")
print("       SouffleuseBeamAmortizedEval) ; la cascade ne dispose pas de cet")
print("       équivalent (chaque frappe relance greedy + branches). En USAGE VIVANT")
print("       l'écart de latence se creuse en faveur du beam au-delà du froid.")

// MARK: - Buckets BEAM BETTER / TIE / CASCADE BETTER (jugement par cas)

enum Verdict { case beam, tie, cascade }
func bucket(_ r: Row) -> (Verdict, String) {
    let cEmpty = isEmpty(r.cascade), bEmpty = isEmpty(r.beamBest)
    // 1) L'un parle, l'autre se tait.
    if cEmpty && !bEmpty { return (.beam, "cascade vide, beam propose") }
    if bEmpty && !cEmpty { return (.cascade, "beam vide, cascade propose") }
    if cEmpty && bEmpty { return (.tie, "les deux vides") }
    // 2) Pièges d'accord : la justesse grammaticale tranche.
    if let exp = r.expectAgreement {
        let cOK = agreementOK(expect: exp, partial: r.partial, ghost: r.cascade)
        let bOK = agreementOK(expect: exp, partial: r.partial, ghost: r.beamBest)
        if cOK && !bOK { return (.cascade, "accord correct côté cascade") }
        if bOK && !cOK { return (.beam, "accord correct côté beam") }
        if cOK && bOK { return (.tie, "accord correct des deux") }
        return (.tie, "accord raté des deux") // les deux faux → neutre.
    }
    // 3) Écho fuité : pénalise celui qui recrache une boucle.
    let cRun = echoRunWords(ghost: r.cascade, tail: r.prefix)
    let bRun = echoRunWords(ghost: r.beamBest, tail: r.prefix)
    if cRun >= echoMinRun && bRun < echoMinRun { return (.beam, "cascade fuit une boucle d'écho") }
    if bRun >= echoMinRun && cRun < echoMinRun { return (.cascade, "beam fuit une boucle d'écho") }
    // 4) Sinon : non décidable automatiquement (qualité subjective).
    return (.tie, "non décidable auto (qualité subjective)")
}

var beamBetter: [(Row, String)] = []
var tie: [(Row, String)] = []
var cascadeBetter: [(Row, String)] = []
for r in rows {
    let (v, reason) = bucket(r)
    switch v {
    case .beam: beamBetter.append((r, reason))
    case .tie: tie.append((r, reason))
    case .cascade: cascadeBetter.append((r, reason))
    }
}

print("")
print("  BUCKETS (jugement automatique décidable ; les TIE incluent le subjectif) :")
print("    BEAM BETTER ...................... \(beamBetter.count)")
for (r, reason) in beamBetter { print("        [\(r.label)] …\(String(r.prefix.suffix(28)))  → \(reason)") }
print("    CASCADE BETTER ................... \(cascadeBetter.count)")
for (r, reason) in cascadeBetter { print("        [\(r.label)] …\(String(r.prefix.suffix(28)))  → \(reason)") }
print("    TIE / non décidable .............. \(tie.count)")

print("")
print("────────────────────────────────────────────────────────────────────────")
print(" Note : les buckets TIE 'non décidable auto' demandent une lecture humaine")
print(" (cf. table par cas ci-dessus). Le verdict global est dans le rapport.")
print("────────────────────────────────────────────────────────────────────────")

await engine.unload()
await beam.unload()
