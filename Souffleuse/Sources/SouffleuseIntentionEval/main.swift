import Foundation
import NaturalLanguage
import SouffleuseCore
import SouffleuseLlama
import SouffleuseLog
import SouffleuseTyping

// ─────────────────────────────────────────────────────────────────────────────
// SouffleuseIntentionEval — l'axe INTENTION : cascade de prod vs beam Cotypist.
//
// Métrique : on coupe une VRAIE phrase FR en un point ; le suffixe vrai est le
// GOLD (ce que l'utilisateur VOULAIT taper). On génère le ghost sur le préfixe et
// on juge s'il prédit la continuation INTENTIONNÉE. C'est ORTHOGONAL à l'accord
// grammatical : un ghost peut être bien accordé mais d'INTENTION fausse
// (« fisca » → « fiscal » = bon accord, MAIS si l'utilisateur visait
// « fiscalité » l'intention est ratée). On veut le taux de hit HONNÊTE.
//
// Deux moteurs comparés sur la MÊME couche LLM (corpus OFF / perso OFF des deux
// côtés — apples-to-apples) :
//   A = CASCADE de prod — MIROIR FIDÈLE de `ModelRuntime.midWordLongGhost`
//       (greedy healed + garde écho positionnelle + gradient d'engagement K=3 +
//       plancher dico). Réutilise les fonctions de lib réelles ; seule
//       l'orchestration est mirroir. Flags : MW_ENGAGEMENT/MW_ENG_PRUDENT=0/
//       MW_ECHO_RUN=4. Le ghost = la sortie PEINTE.
//   B = BEAM — `BeamGhostEngine.ghost(prompt:requiredPrefix:)`. On capture le
//       MEILLEUR ghost ET les top-K alternatives classées (`candidates`).
//
// Le contexte distant / la personnalisation est le levier CONNU de l'intention →
// les taux ABSOLUS sont modestes par construction. La COMPARAISON est le point.
//
// Le juge primaire est `mwExactWordHit` (copié de SouffleuseMidwordEval) : un HIT
// si la tête du ghost (espaces retirés, accent-fold) commence par les lettres
// manquantes du vrai mot (« fi » → « chier »). C'est l'intention mid-mot honnête.
// Juge secondaire (soft) : similarité d'embedding NLEmbedding — clairement séparé.
//
// Usage :
//   SOUFFLEUSE_BEAM=1 MW_ENGAGEMENT=1 MW_ENG_PRUDENT=0 \
//     SOUFFLEUSE_GGUF=~/…/gemma-3-1b.i1-Q5_K_M.gguf \
//     swift run SouffleuseIntentionEval
// ─────────────────────────────────────────────────────────────────────────────

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let env = ProcessInfo.processInfo.environment

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Juges portés depuis SouffleuseMidwordEval (fonctions PURES, recopiées).
// ─────────────────────────────────────────────────────────────────────────────

/// NORMALIZE = lowercase + accent-fold (FR). Copié verbatim de SouffleuseMidwordEval.
func mwFold(_ s: String) -> String {
    s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR")).lowercased()
}

/// Les lettres MANQUANTES du mot courant : le préfixe word-char de `trueRemainder`
/// (« chier » pour partial « fi », trueRemainder « chier de transactions »).
/// Copié verbatim de SouffleuseMidwordEval.
func mwTrueWordRest(_ trueRemainder: String) -> String {
    func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "’" || c == "-" }
    return String(trueRemainder.prefix(while: isWordChar))
}

/// HIT EXACT : le ghost complète correctement le mot en cours — sa tête (espaces
/// retirés, accent-fold) commence par les lettres manquantes du vrai mot. Le ghost
/// peut continuer au-delà (« chier de transactions »), c'est toujours un hit. C'est
/// le critère `fi`→`chier`. Indépendant de la langue (un match est juste par
/// construction). Copié verbatim de SouffleuseMidwordEval.
func mwExactWordHit(ghost: String, trueRemainder: String) -> Bool {
    let rest = mwTrueWordRest(trueRemainder)
    guard rest.count >= 2 else { return false }   // frontière / stub 1-char → pas un test mid-mot
    let gLead = mwFold(String(ghost.drop { $0 == " " || $0 == "\t" }))
    guard !gLead.isEmpty else { return false }
    return gLead.hasPrefix(mwFold(rest))
}

/// LONGUEUR DU PRÉFIXE UTILE : combien de caractères CORRECTS du mot en cours le
/// ghost fournit avant de diverger du gold (préfixe commun le plus long de la tête
/// du ghost vs le vrai reste de mot). C'est l'économie de frappe réelle quand il y
/// a hit. Accent-fold des deux côtés pour rester cohérent avec mwExactWordHit.
func mwUsefulPrefixLen(ghost: String, trueRemainder: String) -> Int {
    let rest = mwFold(mwTrueWordRest(trueRemainder))
    guard !rest.isEmpty else { return 0 }
    let gLead = mwFold(String(ghost.drop { $0 == " " || $0 == "\t" }))
    guard !gLead.isEmpty else { return 0 }
    var n = 0
    var gi = gLead.startIndex, ri = rest.startIndex
    while gi < gLead.endIndex && ri < rest.endIndex && gLead[gi] == rest[ri] {
        n += 1; gi = gLead.index(after: gi); ri = rest.index(after: ri)
    }
    return n
}

/// DÉRIVE ÉTRANGÈRE : le ghost est confidemment détecté dans une langue ≠ FR
/// (le base 1B part parfois en anglais/indonésien). Sur cette branche le helper
/// `OutputFilter.detectedLanguageCode` n'existe pas → on réutilise
/// `LlamaPromptBuilder.detectLanguage` (même reconnaisseur NL, fail-open sur
/// fragment court < 8 chars → non-foreign). nil = pas assez de signal → non-foreign.
func mwGhostForeign(_ ghost: String) -> Bool {
    guard let name = LlamaPromptBuilder.detectLanguage(in: ghost) else { return false }
    return name != "French"
}

// ── Juge sémantique SECONDAIRE (soft-hit, NLEmbedding) — porté de SouffleuseMidwordEval.
// Cosinus entre la continuation RECOLLÉE (partiel + ghost) et le VRAI reste de la
// cible. Permet de créditer un recadrage sémantiquement proche que le juge exact
// raterait. CLAIREMENT séparé du juge primaire (rapporté à part).
final class MWSemEmbedding: @unchecked Sendable {
    let sentence: NLEmbedding?
    let word: NLEmbedding?
    let path: String
    init() {
        if let s = NLEmbedding.sentenceEmbedding(for: .french) {
            sentence = s; word = nil; path = "sentence"
        } else if let w = NLEmbedding.wordEmbedding(for: .french) {
            sentence = nil; word = w; path = "word"
        } else {
            sentence = nil; word = nil; path = "none"
        }
    }
    static let shared = MWSemEmbedding()
}

let mwFrStop: Set<String> = ["le", "la", "les", "de", "des", "du", "un", "une", "et", "a", "à",
                             "au", "aux", "en", "je", "tu", "il", "elle", "on", "nous", "vous",
                             "ce", "cette", "ces", "que", "qui", "pas", "ne", "se", "sa", "son",
                             "ses", "mes", "mon", "ma", "pour", "plus", "dans", "est", "sont",
                             "avec", "mais", "ou", "si", "tout", "tous"]
func mwContentWords(_ s: String) -> [String] {
    mwFold(s).split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 && !mwFrStop.contains($0) }
}
func mwSentenceVector(_ s: String, _ emb: MWSemEmbedding) -> [Double]? {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let sentence = emb.sentence {
        let v = sentence.vector(for: trimmed)
        return (v?.isEmpty == false) ? v : nil
    }
    guard let word = emb.word else { return nil }
    let words = mwContentWords(trimmed)
    guard !words.isEmpty else { return nil }
    var sum: [Double] = []; var n = 0
    for w in words {
        guard let v = word.vector(for: w), !v.isEmpty else { continue }
        if sum.isEmpty { sum = v } else { for i in 0..<min(sum.count, v.count) { sum[i] += v[i] } }
        n += 1
    }
    guard n > 0, !sum.isEmpty else { return nil }
    return sum.map { $0 / Double(n) }
}
func mwCosine(_ a: [Double], _ b: [Double]) -> Double? {
    let n = min(a.count, b.count)
    guard n > 0 else { return nil }
    var dot = 0.0, na = 0.0, nb = 0.0
    for i in 0..<n { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
    guard na > 0, nb > 0 else { return nil }
    return dot / (na.squareRoot() * nb.squareRoot())
}
/// Soft-hit sémantique : cosinus(continuation recollée, vrai reste) ≥ seuil.
/// nil = embeddings indispo → soft-hit non comptabilisé pour ce cas.
func mwSemSoftHit(gluedGhost: String, trueRemainder: String, thresh: Double) -> Bool? {
    let emb = MWSemEmbedding.shared
    guard emb.sentence != nil || emb.word != nil else { return nil }
    guard let g = mwSentenceVector(gluedGhost, emb),
          let t = mwSentenceVector(trueRemainder, emb) else { return nil }
    guard let cos = mwCosine(g, t) else { return nil }
    return cos >= thresh
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Corpus GOLD (~40 phrases FR, domaines variés).
// ─────────────────────────────────────────────────────────────────────────────
// Seed depuis fallbackPhrases() de SouffleuseMidwordEval (fruits/course-parc/…)
// ÉTENDU avec emails pro, chat, narratif, technique, support fiscalité.

let goldSentences: [String] = [
    // ── Seed (fallbackPhrases de SouffleuseMidwordEval) ──
    "J'aime les pommes, les fraises et surtout les cerises",
    "Ce week-end je vais courir au parc avec mon chien",
    "Pour le dîner je pense préparer des pâtes à la tomate",
    "Demain matin je dois envoyer le rapport à mon collègue",
    "Je préfère le café le matin et le thé le soir",
    "Il faudrait acheter du pain, du lait et quelques légumes",
    // ── Emails professionnels ──
    "Bonjour Madame, suite à notre échange téléphonique je me permets de revenir vers vous",
    "Je vous confirme la disponibilité du produit pour la livraison de mardi prochain",
    "Veuillez trouver ci-joint le devis correspondant à votre demande de prestation",
    "Je reste à votre entière disposition pour tout complément d'information",
    "Nous avons bien reçu votre commande et procédons actuellement à son traitement",
    "Suite à votre candidature, nous souhaiterions vous proposer un entretien la semaine prochaine",
    "Merci de bien vouloir nous transmettre les documents justificatifs avant la fin du mois",
    "Je me permets de vous relancer concernant ma demande de remboursement restée sans réponse",
    // ── Chat / SMS familier ──
    "ok pas de souci, on se voit demain devant le cinéma",
    "trop bien ton message, j'arrive dans cinq minutes maximum",
    "désolé pour le retard je suis coincé dans les embouteillages",
    "tu peux me rappeler quand tu as un moment cet après-midi",
    "merci beaucoup pour hier soir, c'était vraiment sympathique",
    "je pense qu'on devrait reporter la réunion à jeudi finalement",
    // ── Narratif ──
    "Le soleil se couchait lentement derrière les collines tandis que les oiseaux regagnaient leurs nids",
    "Elle ouvrit la porte avec précaution sans savoir ce qui l'attendait dans la pénombre",
    "La vieille horloge sonna minuit et la maison entière sembla retenir son souffle",
    "Le train traversait la campagne enneigée pendant que les voyageurs sommeillaient paisiblement",
    "Au marché du village les commerçants vantaient leurs produits frais et colorés",
    // ── Technique ──
    "Pour configurer le serveur il faut installer les dépendances puis lancer la migration",
    "La fonction prend en entrée un tableau d'entiers et retourne la somme des éléments positifs",
    "En cas d'erreur le système écrit un message détaillé dans le fichier de journalisation",
    "Cette interface expose un point de terminaison qui accepte des requêtes au format structuré",
    "Le déploiement nécessite une connexion sécurisée et des identifiants valides pour authentifier",
    // ── Support fiscalité (registre Waltio/Cotypist) ──
    "Le calcul de la plus-value tient compte de votre prix total d'acquisition",
    "Nous protégeons vos informations personnelles conformément à la réglementation européenne",
    "Vous trouverez votre rapport fiscal complet dans votre espace personnel sécurisé",
    "La fraction imposable de votre portefeuille dépend du montant de la cession réalisée",
    "Pensez à déclarer vos transactions avant la date limite indiquée sur le formulaire",
    // ── Divers prose ──
    "Cette année nous partons en vacances dans une région montagneuse du sud de la France",
    "Le médecin recommande une alimentation équilibrée et une activité physique régulière",
    "La bibliothèque municipale propose désormais un service de prêt numérique gratuit",
    "Les enfants construisaient un château de sable près du rivage en riant aux éclats",
    "Notre association organise chaque printemps une grande collecte de vêtements pour les démunis",
]

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Schéma de coupe : mid-word depth 2/3/4 + after-space.
// ─────────────────────────────────────────────────────────────────────────────

enum Bucket: String { case mid2, mid3, mid4, afterSpace }

struct TestItem {
    let prefix: String           // beforeCursor (finit mid-mot, ou sur un espace).
    let trueRemainder: String    // le GOLD : ce que l'utilisateur voulait.
    let bucket: Bucket
}

func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "’" || c == "-" }

let frStopForCut: Set<String> = mwFrStop

/// Génère les items de test pour une phrase :
///  - mid-mot à depth 2/3/4 sur des mots de CONTENU (≥6 chars, hors stopwords) ;
///  - after-space : préfixe finissant sur un espace, gold = le mot suivant.
func makeItems(_ sentence: String) -> [TestItem] {
    let chars = Array(sentence)
    var items: [TestItem] = []
    var i = 0
    var midWordsTaken = 0
    var spaceCutsTaken = 0
    while i < chars.count {
        // Avance jusqu'au début d'un mot.
        guard isWordChar(chars[i]) else { i += 1; continue }
        let wordStart = i
        var j = i
        while j < chars.count && isWordChar(chars[j]) { j += 1 }
        let word = String(chars[wordStart..<j])
        let wordLen = j - wordStart
        let wordFolded = mwFold(word)

        // ── Coupes mid-mot depth 2/3/4 ── (mots de contenu uniquement, assez longs).
        if wordLen >= 6 && !frStopForCut.contains(wordFolded) && midWordsTaken < 8 {
            for depth in [2, 3, 4] where depth < wordLen {
                let cutAt = wordStart + depth
                let before = String(chars[0..<cutAt])
                let remainder = String(chars[cutAt..<chars.count])
                // Le reste de mot doit avoir ≥2 lettres (sinon ce n'est pas un vrai test mid-mot).
                guard mwTrueWordRest(remainder).count >= 2 else { continue }
                let bucket: Bucket = depth == 2 ? .mid2 : (depth == 3 ? .mid3 : .mid4)
                items.append(TestItem(prefix: before, trueRemainder: remainder, bucket: bucket))
            }
            midWordsTaken += 1
        }

        // ── Coupe after-space : préfixe = …mot suivi d'UN espace, gold = mot suivant.
        // On la pose à la frontière APRÈS ce mot, si le mot suivant est de contenu.
        if j < chars.count && chars[j] == " " && spaceCutsTaken < 4 {
            // Identifie le mot suivant.
            var k = j + 1
            while k < chars.count && chars[k] == " " { k += 1 }
            if k < chars.count && isWordChar(chars[k]) {
                var m = k
                while m < chars.count && isWordChar(chars[m]) { m += 1 }
                let nextWord = String(chars[k..<m])
                let nextFolded = mwFold(nextWord)
                if nextWord.count >= 4 && !frStopForCut.contains(nextFolded) {
                    let before = String(chars[0...j])           // inclut l'espace
                    let remainder = String(chars[k..<chars.count])  // commence au mot suivant
                    items.append(TestItem(prefix: before, trueRemainder: remainder, bucket: .afterSpace))
                    spaceCutsTaken += 1
                }
            }
        }
        i = j
    }
    return items
}

var allItems: [TestItem] = []
for s in goldSentences { allItems.append(contentsOf: makeItems(s)) }

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Boot des deux moteurs (corpus OFF des deux côtés).
// ─────────────────────────────────────────────────────────────────────────────

let ggufPath = (env["SOUFFLEUSE_GGUF"].flatMap { $0.isEmpty ? nil : $0 }
    ?? "~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf")
let resolved = (ggufPath as NSString).expandingTildeInPath

let beamConfig = BeamConfig.fromEnvironment()

let engine = LlamaEngine()
err("[intention] loading GGUF (cascade): \(resolved)")
guard await engine.load(modelPath: resolved, contextTokens: 4096) else {
    err("FATAL: GGUF load failed (cascade)"); exit(1)
}
await engine.setCorpus([])   // corpus OFF — apples-to-apples.

let beam = BeamGhostEngine(config: beamConfig)
err("[intention] loading GGUF (beam, n_seq_max=\(beamConfig.maxSearchWidth + 1)): \(resolved)")
guard await beam.load(modelPath: resolved, contextTokens: 4096) else {
    err("FATAL: GGUF load failed (beam)"); exit(1)
}

let dicoFloor = WordCompleter()

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Chemin A : MIROIR de la cascade de prod (ModelRuntime.midWordLongGhost).
// Copié de SouffleuseCascadeVsBeamEval (mêmes fonctions de lib réelles).
// ─────────────────────────────────────────────────────────────────────────────

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

struct CascadeResult { let ghost: String; let ms: Int }

func runEscalationPass(
    prompt: String, partial: String, cap: Int,
    temperature: Float, seed: UInt32, captureP1: Bool
) async -> (lead: String, p1: Double?, fullLine: String) {
    final class Acc: @unchecked Sendable { var text = "" }
    let acc = Acc()
    let metrics = await engine.generate(
        prompt: prompt, maxTokens: cap,
        sampling: LlamaSampling(
            temperature: temperature, repeatPenalty: 1.3, repeatLastN: 64, seed: seed,
            personalizationStrength: 0, topP: temperature > 0 ? 0.9 : 0,
            banMarkup: true, banDigitsLeading: true, banEmoji: true,
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
) async -> String {
    let greedyLead = SuggestionPolicy.midWordLeadWordDefrag(
        OutputFilter.singleLine(greedyFullLine), partial: partial)
    guard SuggestionPolicy.midWordExtendsStructurally(partial: partial, modal: greedyLead) else {
        if let floor = dicoFloorResult(partial: partial, greedyLead: greedyLead, why: "structdegen") {
            return floor.word
        }
        return ""
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
    switch level {
    case .zero:
        if let floor = dicoFloorResult(partial: partial, greedyLead: greedyLead, why: "agree") {
            return floor.word
        }
        return ""
    case .prudent:
        return firstWholeWord(of: fullContinuation)
    case .plein:
        return fullContinuation
    }
}

func cascadeGhost(prefix: String) async -> CascadeResult {
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
            temperature: 0, repeatPenalty: 1.3, repeatLastN: 64, seed: 0,
            personalizationStrength: 0, banMarkup: true, banDigitsLeading: true, banEmoji: true,
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
            if run >= echoMinRun { why = "echo"; result = "" }
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

    if engagementOn, !isBoundary, result.first != " " {
        let g = await midWordEngagementResult(
            prompt: prompt, partial: partial, maxTokens: cap,
            greedyFullLine: acc.text, greedyP1: greedyMetrics.firstTokenProb,
            fullContinuation: result, why: why)
        return CascadeResult(ghost: g, ms: Int(Date().timeIntervalSince(t0) * 1000))
    }
    return CascadeResult(ghost: result, ms: Int(Date().timeIntervalSince(t0) * 1000))
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Chemin B : le beam (best + top-K candidates).
// ─────────────────────────────────────────────────────────────────────────────

func beamGhost(prefix: String, partial: String) async -> BeamResult {
    let prompt = LlamaPromptBuilder.buildLlamaPrompt(
        system: "", customInstr: "", ctxPrefix: "", fieldContext: "",
        afterCursor: "", beforeCursor: prefix)
    return await beam.ghost(prompt: prompt, requiredPrefix: partial)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Run.
// ─────────────────────────────────────────────────────────────────────────────

let topK = max(1, Int(env["INTENT_TOPK"] ?? "3") ?? 3)
let semThresh = Double(env["MW_SEM_THRESH"] ?? "0.45") ?? 0.45

print("")
print("════════════════════════════════════════════════════════════════════════")
print(" SouffleuseIntentionEval — axe INTENTION (cascade vs beam)")
print(" corpus GOLD : \(goldSentences.count) phrases · \(allItems.count) items de coupe")
print(" A = CASCADE de prod  ·  B = beam (K=\(beamConfig.maxSearchWidth), exp=\(beamConfig.positionExponent), minP=\(beamConfig.minBranchProbability))")
print(" hit@topK = top-\(topK) candidats beam · corpus OFF / perso OFF des deux côtés")
print(" emb sémantique (soft-hit secondaire) : \(MWSemEmbedding.shared.path) · seuil \(semThresh)")
print("════════════════════════════════════════════════════════════════════════")

struct Row {
    let bucket: Bucket
    let prefix: String
    let partial: String
    let trueRemainder: String
    let cascadeGhost: String
    let cascadeHit: Bool
    let cascadeUseful: Int
    let beamBest: String
    let beamHit: Bool
    let beamUseful: Int
    let beamTopKHit: Bool
    let beamTopKUseful: Int       // useful-prefix du MEILLEUR candidat top-K qui hit.
    let cascadeSoft: Bool?
    let beamSoftBest: Bool?
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Agrégats + synthèse (calculés INCRÉMENTALEMENT dans la boucle).
// La lib llama/beam vendorée peut segfaulter (SIGSEGV) sur un input pathologique
// précis sous -c release — un crash NON rattrapable en Swift. Pour qu'un tel
// crash en toute fin de corpus ne fasse PAS perdre tout le run, on accumule au
// fil de l'eau ET on réécrit la synthèse dans un fichier (INTENT_SYNTH_PATH,
// défaut /tmp/intention_synth.txt) APRÈS CHAQUE item. La dernière synthèse pré-
// crash reste donc sur disque, exhaustive à 1 item près (divulgué).
// ─────────────────────────────────────────────────────────────────────────────

func pct(_ n: Int, _ d: Int) -> String { d == 0 ? "n/a" : "\(n * 100 / d)%" }
func meanD(_ xs: [Int]) -> String { xs.isEmpty ? "—" : String(format: "%.1f", Double(xs.reduce(0, +)) / Double(xs.count)) }
func padR(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
func padL(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: " ", count: n - s.count) + s }
func signed(_ x: Int) -> String { x >= 0 ? "+\(x)" : "\(x)" }

struct BucketAgg {
    var n = 0
    var cascadeHit = 0
    var beamHit = 0
    var beamTopKHit = 0
    var cascadeUseful: [Int] = []     // useful-prefix sur les hits cascade.
    var beamUseful: [Int] = []
    var beamTopKUseful: [Int] = []
    var cascadeSoft = 0, beamSoft = 0, softDenom = 0
}

func accumulate(_ agg: inout BucketAgg, _ r: Row) {
    agg.n += 1
    if r.cascadeHit { agg.cascadeHit += 1; agg.cascadeUseful.append(r.cascadeUseful) }
    if r.beamHit { agg.beamHit += 1; agg.beamUseful.append(r.beamUseful) }
    if r.beamTopKHit { agg.beamTopKHit += 1; agg.beamTopKUseful.append(r.beamTopKUseful) }
    if r.cascadeSoft != nil || r.beamSoftBest != nil {
        agg.softDenom += 1
        if r.cascadeSoft == true { agg.cascadeSoft += 1 }
        if r.beamSoftBest == true { agg.beamSoft += 1 }
    }
}

func bucketLine(_ name: String, _ a: BucketAgg) -> String {
    let c = "\(a.cascadeHit)/\(a.n) \(pct(a.cascadeHit, a.n))"
    let b = "\(a.beamHit)/\(a.n) \(pct(a.beamHit, a.n))"
    let k = "\(a.beamTopKHit)/\(a.n) \(pct(a.beamTopKHit, a.n))"
    let useful = "\(meanD(a.cascadeUseful)) / \(meanD(a.beamUseful)) / \(meanD(a.beamTopKUseful))"
    return "  " + padR(name, 12) + padL("\(a.n)", 4) + " | "
        + padR(c, 13) + " | " + padR(b, 13) + " | " + padR(k, 14) + " | " + useful
}

let order: [Bucket] = [.mid2, .mid3, .mid4, .afterSpace]

/// Bâtit le bloc synthèse complet (table par bucket + global + soft + lecture).
func renderSynthesis(_ byBucket: [Bucket: BucketAgg], _ ov: BucketAgg, done: Int, total: Int) -> String {
    var out = ""
    out += "\n────────────────────────────────────────────────────────────────────────\n"
    out += " RÉSULTATS — hit@1 (juge EXACT primaire), par bucket   [\(done)/\(total) items traités]\n"
    out += "────────────────────────────────────────────────────────────────────────\n"
    out += "  " + padR("bucket", 12) + padL("n", 4) + " | "
        + padR("cascade hit@1", 13) + " | " + padR("beam hit@1", 13) + " | "
        + padR("beam hit@top\(topK)", 14) + " | useful-prefix (c/b/bK)\n"
    for bkt in order {
        guard let a = byBucket[bkt] else { continue }
        out += bucketLine(bkt.rawValue, a) + "\n"
    }
    out += "  " + String(repeating: "─", count: 70) + "\n"
    out += bucketLine("GLOBAL", ov) + "\n"
    out += "\n SOFT-HIT sémantique (SECONDAIRE, NLEmbedding cos ≥ \(semThresh), emb=\(MWSemEmbedding.shared.path)) :\n"
    if MWSemEmbedding.shared.path == "none" {
        out += "   embeddings FR indisponibles sur cet OS → soft-hit non calculé.\n"
    } else {
        out += "   cascade soft : \(ov.cascadeSoft)/\(ov.softDenom) = \(pct(ov.cascadeSoft, ov.softDenom))"
            + "   |   beam soft : \(ov.beamSoft)/\(ov.softDenom) = \(pct(ov.beamSoft, ov.softDenom))"
            + "   (denom = items avec embedding FR)\n"
    }
    out += "\n LECTURE (global) :\n"
    out += "   beam@1 − cascade@1     = \(signed(ov.beamHit - ov.cascadeHit)) items  (le beam prédit-il l'intention plus souvent en best ?)\n"
    out += "   beam@top\(topK) − beam@1     = \(signed(ov.beamTopKHit - ov.beamHit)) items  (les alternatives classées relèvent-elles le plafond ?)\n"
    out += "   beam@top\(topK) − cascade@1  = \(signed(ov.beamTopKHit - ov.cascadeHit)) items  (plafond beam-UI vs ce que la cascade peint)\n"
    return out
}

let synthPath = env["INTENT_SYNTH_PATH"] ?? "/tmp/intention_synth.txt"
let maxItems = env["INTENT_MAX_ITEMS"].flatMap { Int($0) } ?? allItems.count

var byBucket: [Bucket: BucketAgg] = [:]
var overall = BucketAgg()

for (idx, item) in allItems.enumerated() {
    if idx >= maxItems { break }
    let partial = OutputFilter.trailingPartialWord(item.prefix)
    let a = await cascadeGhost(prefix: item.prefix)
    let b = await beamGhost(prefix: item.prefix, partial: partial)
    let bBest = b.best?.ghost ?? ""
    let bCands = Array(b.candidates.prefix(topK).map { $0.ghost })

    // ── Juge primaire : exact word-hit.
    let cHit = mwExactWordHit(ghost: a.ghost, trueRemainder: item.trueRemainder)
    let bHit = mwExactWordHit(ghost: bBest, trueRemainder: item.trueRemainder)
    let cUseful = cHit ? mwUsefulPrefixLen(ghost: a.ghost, trueRemainder: item.trueRemainder) : 0
    let bUseful = bHit ? mwUsefulPrefixLen(ghost: bBest, trueRemainder: item.trueRemainder) : 0

    // ── hit@topK : N'IMPORTE quel candidat top-K passe.
    var topKHit = false
    var topKUseful = 0
    for cand in bCands where mwExactWordHit(ghost: cand, trueRemainder: item.trueRemainder) {
        topKHit = true
        topKUseful = max(topKUseful, mwUsefulPrefixLen(ghost: cand, trueRemainder: item.trueRemainder))
    }

    // ── Juge sémantique secondaire (soft-hit) sur la continuation recollée.
    let cSoft = mwSemSoftHit(gluedGhost: partial + a.ghost, trueRemainder: item.trueRemainder, thresh: semThresh)
    let bSoft = mwSemSoftHit(gluedGhost: partial + bBest, trueRemainder: item.trueRemainder, thresh: semThresh)

    let row = Row(
        bucket: item.bucket, prefix: item.prefix, partial: partial, trueRemainder: item.trueRemainder,
        cascadeGhost: a.ghost, cascadeHit: cHit, cascadeUseful: cUseful,
        beamBest: bBest, beamHit: bHit, beamUseful: bUseful,
        beamTopKHit: topKHit, beamTopKUseful: topKUseful,
        cascadeSoft: cSoft, beamSoftBest: bSoft)

    // Agrégation INCRÉMENTALE (par bucket + global).
    var agg = byBucket[item.bucket] ?? BucketAgg()
    accumulate(&agg, row); byBucket[item.bucket] = agg
    accumulate(&overall, row)

    // Impression par item (verbeuse ; bench hors audit).
    let trueWord = mwTrueWordRest(item.trueRemainder)
    let cMark = cHit ? "✅" : "❌"
    let bMark = bHit ? "✅" : "❌"
    let kMark = topKHit ? "✅" : "❌"
    let altStr = bCands.dropFirst().map { $0.debugDescription }.joined(separator: " · ")
    print("")
    print("#\(idx) [\(item.bucket.rawValue)] …\(String(item.prefix.suffix(26)).debugDescription)  gold-mot=\(trueWord.debugDescription)")
    print("   A cascade : \(a.ghost.debugDescription)  \(cMark) hit · useful=\(cUseful)")
    print("   B beam@1  : \(bBest.debugDescription)  \(bMark) hit · useful=\(bUseful)")
    print("   B beam@K  : \(kMark) hit  alts=[\(altStr)]")

    // ── RÉSILIENCE : réécrit la synthèse courante sur disque après CHAQUE item,
    //    pour qu'un SIGSEGV vendoré tardif ne fasse pas perdre le run entier.
    let synth = renderSynthesis(byBucket, overall, done: idx + 1, total: min(maxItems, allItems.count))
    try? synth.write(toFile: synthPath, atomically: true, encoding: .utf8)
}

// Synthèse finale sur stdout (le run a survécu jusqu'au bout).
print(renderSynthesis(byBucket, overall, done: overall.n, total: min(maxItems, allItems.count)))
print(" (synthèse aussi écrite dans \(synthPath))")
print("")
print("FIN.")
