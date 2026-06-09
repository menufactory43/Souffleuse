import Foundation
import NaturalLanguage
import SouffleuseCore
import SouffleuseLlama
import SouffleuseLog
import SouffleuseTyping

// ─────────────────────────────────────────────────────────────────────────────
// SouffleuseAfterSpaceEval — le beam « façon Cotypist » bat-il la CASCADE de prod
// quand le caret est PILE APRÈS UN ESPACE (aucune lettre du mot suivant tapée,
// donc AUCUNE contrainte requiredPrefix) ?
//
// POURQUOI cette position précise : c'est la SEULE où l'avantage mid-mot du beam
// (élagage par requiredPrefix) NE JOUE PAS. À une frontière, `partial == ""`,
// `healPrefix == nil`, et la cascade NE déclenche PAS ses branches d'engagement
// mid-mot → elle se réduit à « greedy chaud + garde écho + coupe clause/mot ».
// Le beam, lui, décode librement K branches sans contrainte de préfixe. C'est donc
// le test le plus pur de « est-ce que le multi-branche, à lui seul, vaut son coût
// après-espace ? ».
//
// PRIOR (SouffleuseIntentionEval) : le hit EXACT du mot suivant après-espace était
// un MATCH NUL (beam@1 14% · cascade 15% · beam@top3 19%) — les deux médiocres,
// car sans contexte distant on ne devine pas « pommes » vs « fraises ». D'où ici
// des métriques PLUS RICHES : overlap multi-mots de la continuation (combien de
// mots/chars de la VRAIE suite le ghost garde justes), cohérence sémantique
// (NLEmbedding), et un mini-sweep K ∈ {1,2,3}.
//
// SWEEP : K ∈ {1, 2, 3} UNIQUEMENT. Le sweep mid-mot a déjà prouvé que hit@1
// plafonne dès K=3 ; K=9 est du calcul gaspillé. Mais après-espace il n'y a AUCUN
// requiredPrefix pour élaguer → la compétition de candidats POURRAIT compter
// davantage : on quantifie si elle compte VRAIMENT dans K≤3.
//
// CADRE apples-to-apples : corpus OFF / perso OFF des deux côtés. On ne mesure que
// la COUCHE DE GÉNÉRATION LLM. ⚠ HORS PÉRIMÈTRE — donc NON crédité ici : en prod
// réelle la cascade dispose AUSSI, après-espace, du recall-instantané (L1/L0) et
// du n-gram perso, qui sont précisément SA force à la frontière. Cette éval
// SOUS-ESTIME donc volontairement la cascade de prod (voir limites du rapport).
//
// Réutilisations :
//   - corpus GOLD ~40 phrases + le SCHÉMA DE COUPE after-space (cut à PLUSIEURS
//     frontières d'espace, gold = le RESTE de la phrase) : portés de
//     SouffleuseIntentionEval, gold étendu en continuation MULTI-MOTS.
//   - juges : mwFold, le juge mot-suivant EXACT (mwExactWordHit), le soft-hit
//     sémantique NLEmbedding (mwSemSoftHit) : portés de SouffleuseIntentionEval.
//   - cascade APRÈS-ESPACE (chemin frontière) : miroir de
//     SouffleuseCascadeVsBeamEval, branche `isBoundary == true` (les branches
//     d'engagement mid-mot ne tirent pas).
//   - knob K : `BeamConfig.cotypistDefault` + override EXPLICITE de
//     maxSearchWidth/maxResultWidth par K (comme SouffleuseBeamWidthSweepEval ;
//     n_seq_max = K+1 fixé au load → un load par K). L'env `SOUFFLEUSE_BEAM_K`
//     existe sur fromEnvironment() mais ne balaie pas dans un seul process.
//
// Résilience : le beam vendoré peut SIGSEGV sous charge soutenue. On écrit la
// synthèse sur disque DÈS QU'UN K est complet (AFTERSPACE_PATH, défaut
// /tmp/afterspace_eval.txt) → un crash sur un K tardif garde les K déjà mesurés.
// Caps d'env : AFTERSPACE_KS (sous-ensemble de K), AFTERSPACE_MAX_ITEMS (cap items).
//
// Usage :
//   SOUFFLEUSE_GGUF=~/…/gemma-3-1b.i1-Q5_K_M.gguf \
//     swift run -c release --product SouffleuseAfterSpaceEval
// ─────────────────────────────────────────────────────────────────────────────

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let env = ProcessInfo.processInfo.environment

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Juges PURS, portés de SouffleuseIntentionEval.
// ─────────────────────────────────────────────────────────────────────────────

/// NORMALIZE = lowercase + accent-fold (FR).
func mwFold(_ s: String) -> String {
    s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR")).lowercased()
}

func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "’" || c == "-" }

/// Le PREMIER mot (préfixe word-char) de `s`, accent-fold.
func mwFirstWord(_ s: String) -> String {
    let trimmed = s.drop { $0 == " " || $0 == "\t" }
    return mwFold(String(trimmed.prefix(while: isWordChar)))
}

/// HIT EXACT mot-suivant : le premier mot du ghost (espaces de tête retirés,
/// accent-fold) == le premier mot de la vraie continuation. Après-espace il n'y a
/// pas de fragment partiel — on compare le mot complet, pas un préfixe.
func mwExactWordHit(ghost: String, trueRemainder: String) -> Bool {
    let g = mwFirstWord(ghost)
    let t = mwFirstWord(trueRemainder)
    guard !g.isEmpty, !t.isEmpty else { return false }
    return g == t
}

// ── Soft-hit sémantique (NLEmbedding), porté de SouffleuseIntentionEval. ──
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
/// Soft-hit sémantique : cosinus(ghost, vraie continuation) ≥ seuil. Après-espace
/// le ghost EST déjà la continuation (pas de partiel à recoller). nil = embeddings
/// indispo → non comptabilisé.
func mwSemSoftHit(ghost: String, trueRemainder: String, thresh: Double) -> Bool? {
    let emb = MWSemEmbedding.shared
    guard emb.sentence != nil || emb.word != nil else { return nil }
    guard let g = mwSentenceVector(ghost, emb),
          let t = mwSentenceVector(trueRemainder, emb) else { return nil }
    guard let cos = mwCosine(g, t) else { return nil }
    return cos >= thresh
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Overlap MULTI-MOTS (métrique PRINCIPALE).
// ─────────────────────────────────────────────────────────────────────────────
// « Jusqu'où dans la phrase voulue le ghost reste-t-il juste ? » = frappes
// épargnées sur une lancée. On mesure le plus long préfixe commun entre le ghost
// et la vraie continuation, en (a) MOTS corrects et (b) CHARS corrects, avant la
// première divergence. Normalisation : accent-fold + espaces collapsés.

/// Tokenise en mots accent-fold (séparateurs = non-word-char), espaces ignorés.
func foldedWords(_ s: String) -> [String] {
    s.split(whereSeparator: { !isWordChar($0) }).map { mwFold(String($0)) }
}

/// Nombre de MOTS du préfixe commun (mots entiers identiques en tête, accent-fold).
func correctWords(ghost: String, trueRemainder: String) -> Int {
    let g = foldedWords(ghost)
    let t = foldedWords(trueRemainder)
    var n = 0
    while n < g.count && n < t.count && g[n] == t[n] { n += 1 }
    return n
}

/// Forme canonique pour la comparaison char-à-char : accent-fold + runs d'espaces
/// collapsés en un seul espace, trim. Compte les chars utiles sur une « lancée ».
func canonChars(_ s: String) -> String {
    let folded = mwFold(s)
    var out = ""
    var lastSpace = false
    for c in folded {
        if c == " " || c == "\t" || c == "\n" {
            if !lastSpace && !out.isEmpty { out.append(" ") }
            lastSpace = true
        } else {
            out.append(c); lastSpace = false
        }
    }
    if out.hasSuffix(" ") { out.removeLast() }
    return out
}

/// Nombre de CHARS du préfixe commun (avant divergence, forme canonique).
func correctChars(ghost: String, trueRemainder: String) -> Int {
    let g = Array(canonChars(ghost))
    let t = Array(canonChars(trueRemainder))
    var n = 0
    while n < g.count && n < t.count && g[n] == t[n] { n += 1 }
    return n
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Corpus GOLD (~40 phrases FR multi-domaines), porté de IntentionEval.
// ─────────────────────────────────────────────────────────────────────────────

let goldSentences: [String] = [
    // ── Seed (fruits / course-parc / dîner …) ──
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
    // ── Listes / énumérations (registre liste explicite) ──
    "Pour la recette il faut de la farine, des œufs, du sucre et une pincée de sel",
    "L'ordre du jour comprend la validation du budget, le point sur les recrutements et les questions diverses",
    "Les livrables attendus sont la maquette, le cahier des charges et le planning prévisionnel",
]

// Étiquette de domaine par phrase (pour le breakdown by-domain).
func domainOf(_ index: Int) -> String {
    switch index {
    case 0..<6: return "quotidien"
    case 6..<14: return "email-pro"
    case 14..<20: return "chat"
    case 20..<25: return "narratif"
    case 25..<30: return "technique"
    case 30..<35: return "fiscalité"
    case 35..<40: return "prose"
    default: return "listes"
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Schéma de coupe AFTER-SPACE multi-mots.
// ─────────────────────────────────────────────────────────────────────────────
// On coupe à PLUSIEURS frontières d'espace par phrase (après un mot COMPLET, caret
// juste avant le mot suivant). Le préfixe inclut l'espace de fin ; le gold = le
// RESTE COMPLET de la phrase (continuation MULTI-MOTS). Contraintes :
//   - le mot suivant est de contenu (≥4 chars, hors stopword) → un mot-suivant
//     « devinable » au sens faible (pas un « le »/« de »).
//   - on évite les frontières trop précoces (préfixe trop court → pas de contexte)
//     et garde au moins 2 mots de gold (continuation, pas juste 1 mot).

struct AfterSpaceItem {
    let prefix: String           // beforeCursor, finit sur UN espace.
    let goldContinuation: String // le RESTE complet de la phrase (multi-mots).
    let domain: String
}

func makeAfterSpaceItems(_ sentence: String, domain: String, maxCuts: Int) -> [AfterSpaceItem] {
    let chars = Array(sentence)
    var items: [AfterSpaceItem] = []
    var i = 0
    var cuts = 0
    var wordIndex = 0
    while i < chars.count {
        guard isWordChar(chars[i]) else { i += 1; continue }
        var j = i
        while j < chars.count && isWordChar(chars[j]) { j += 1 }
        wordIndex += 1

        // Frontière après ce mot : chars[j] == ' '.
        if j < chars.count && chars[j] == " " && cuts < maxCuts {
            // Le mot suivant.
            var k = j + 1
            while k < chars.count && chars[k] == " " { k += 1 }
            if k < chars.count && isWordChar(chars[k]) {
                var m = k
                while m < chars.count && isWordChar(chars[m]) { m += 1 }
                let nextWord = String(chars[k..<m])
                let nextFolded = mwFold(nextWord)
                // Reste après le mot suivant (pour exiger une continuation ≥2 mots).
                let goldWordCount = foldedWords(String(chars[k...])).count
                // wordIndex >= 2 : au moins 2 mots de contexte avant la coupe.
                if nextWord.count >= 4 && !mwFrStop.contains(nextFolded)
                    && goldWordCount >= 2 && wordIndex >= 2 {
                    let before = String(chars[0...j])              // inclut l'espace
                    let gold = String(chars[k..<chars.count])      // reste complet
                    items.append(AfterSpaceItem(prefix: before, goldContinuation: gold, domain: domain))
                    cuts += 1
                }
            }
        }
        i = j
    }
    return items
}

let maxCutsPerSentence = Int(env["AFTERSPACE_CUTS"] ?? "6") ?? 6
var allItems: [AfterSpaceItem] = []
for (idx, s) in goldSentences.enumerated() {
    allItems.append(contentsOf: makeAfterSpaceItems(s, domain: domainOf(idx), maxCuts: maxCutsPerSentence))
}
// Cap d'items optionnel (résilience / itération rapide).
if let cap = env["AFTERSPACE_MAX_ITEMS"].flatMap({ Int($0) }), cap > 0, cap < allItems.count {
    allItems = Array(allItems.prefix(cap))
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - GGUF + setup.
// ─────────────────────────────────────────────────────────────────────────────

let ggufPath = (env["SOUFFLEUSE_GGUF"].flatMap { $0.isEmpty ? nil : $0 }
    ?? "~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf")
let resolved = (ggufPath as NSString).expandingTildeInPath
guard FileManager.default.fileExists(atPath: resolved) else {
    err("FATAL: GGUF introuvable : \(resolved)  (override SOUFFLEUSE_GGUF)"); exit(1)
}

let semThresh = Double(env["AFTERSPACE_SEM_THRESH"] ?? "0.45") ?? 0.45
let topKWanted = max(1, Int(env["AFTERSPACE_TOPK"] ?? "3") ?? 3)

// K à balayer : DÉFAUT {1,2,3} (cf. consigne — pas de K=9). Override AFTERSPACE_KS.
let sweepKs: [Int] = (env["AFTERSPACE_KS"].map { $0.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) } })
    ?? [1, 2, 3]

let outPath = env["AFTERSPACE_PATH"] ?? "/tmp/afterspace_eval.txt"

func beamPrompt(prefix: String) -> String {
    LlamaPromptBuilder.buildLlamaPrompt(
        system: "", customInstr: "", ctxPrefix: "", fieldContext: "",
        afterCursor: "", beforeCursor: prefix)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - CASCADE après-espace (chemin FRONTIÈRE), miroir de
//         SouffleuseCascadeVsBeamEval (branche isBoundary == true).
// ─────────────────────────────────────────────────────────────────────────────
// À une frontière : partial == "", isBoundary == true, healPrefix == nil. Les
// branches d'engagement mid-mot NE tirent PAS (`!isBoundary` faux). La cascade se
// réduit à : greedy chaud (1 passe, profil prod) → splice frontière → dédup →
// garde écho positionnelle → coupe clause → cap N mots. C'est EXACTEMENT le ghost
// que la prod peindrait après-espace (au recall-instantané/perso près, hors
// périmètre).

let engine = LlamaEngine()
err("[afterspace] loading GGUF (cascade): \(resolved)")
guard await engine.load(modelPath: resolved, contextTokens: 4096) else {
    err("FATAL: GGUF load failed (cascade)"); exit(1)
}
await engine.setCorpus([])   // corpus OFF — apples-to-apples.

let escEpsilon = Float(SuggestionPolicy.Tuning.escFirstTokenProbEpsilon)
let echoThreshold = OutputFilter.continuationEchoThreshold
let echoMinRun = SuggestionPolicy.Tuning.echoMinVerbatimRunWords
let engagementOn = SuggestionPolicy.Tuning.midWordEngagementEnabled

struct CascadeOut { let ghost: String; let ms: Int }

/// MIROIR de la branche FRONTIÈRE de `ModelRuntime.midWordLongGhost`.
func cascadeAfterSpace(prefix: String) async -> CascadeOut {
    let t0 = Date()
    let userTail = prefix
    let llmTail = prefix
    let partial = OutputFilter.trailingPartialWord(userTail)   // "" après-espace.
    let isBoundary = partial.isEmpty || SuggestionPolicy.defaultPartialWordIsComplete(userTail)

    let prompt = LlamaPromptBuilder.buildLlamaPrompt(
        system: "", customInstr: "", ctxPrefix: "", fieldContext: "",
        afterCursor: "", beforeCursor: llmTail)

    let cap = SuggestionPolicy.Tuning.midWordLongGhostMaxTokens
    let ghostMaxWords = SuggestionPolicy.Tuning.midWordLongGhostMaxWords

    final class Acc: @unchecked Sendable { var text = "" }
    let acc = Acc()
    _ = await engine.generate(
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

    // Splice frontière (partial == "" → stripPrefixOverlap avec prefix "").
    let fullLine = OutputFilter.singleLine(acc.text)
    var stripped = OutputFilter.singleLine(
        OutputFilter.stripPrefixOverlap(fullLine, prefix: isBoundary ? "" : partial))
    if isBoundary, !stripped.isEmpty {
        let body = String(stripped.drop(while: { $0 == " " || $0 == "\t" }))
        let tailEndsWithSpace = userTail.last.map(\.isWhitespace) ?? true
        let modelGlued = fullLine.first.map { !$0.isWhitespace } ?? false
        if body.isEmpty { stripped = "" }
        else if tailEndsWithSpace { stripped = body }           // notre cas : tail finit par espace.
        else if partial.isEmpty { stripped = " " + body }
        else { stripped = modelGlued ? body : " " + body }
    }
    var result = SuggestionPolicy.dedupLeadingRepeat(ghost: stripped, userTail: userTail)
    var why = result.isEmpty ? "emptygen" : "ok"

    // Garde écho positionnelle.
    if !result.isEmpty {
        let echoVal = OutputFilter.echoScore(ghost: result, tail: userTail)
        if echoVal >= echoThreshold {
            let run = OutputFilter.longestVerbatimRunWords(ghost: result, tail: userTail)
            if run >= echoMinRun { why = "echo"; result = "" }
        }
    }
    // Coupe à la 1ʳᵉ frontière de clause.
    if let idx = result.firstIndex(where: { "\n.!?;:".contains($0) }) {
        result = String(result[...idx])
    }
    // Cap à N mots entiers.
    let words = result.split(whereSeparator: { $0.isWhitespace })
    if words.count > ghostMaxWords {
        let hadLeadingSpace = result.first == " "
        result = words.prefix(ghostMaxWords).joined(separator: " ")
        if hadLeadingSpace, result.first != " ", !result.isEmpty { result = " " + result }
    }
    result = OutputFilter.singleLine(result)
    _ = why

    // À une frontière, `engagementOn && !isBoundary` est FAUX → pas de gradient.
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    return CascadeOut(ghost: result, ms: ms)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Agrégats par engine / par K.
// ─────────────────────────────────────────────────────────────────────────────

struct Agg {
    var n = 0
    var hit1 = 0
    var hitTopK = 0
    var correctWords: [Int] = []
    var correctChars: [Int] = []
    var softHit = 0
    var softDenom = 0
    var latencies: [Int] = []
}

func mean(_ xs: [Int]) -> Double { xs.isEmpty ? 0 : Double(xs.reduce(0, +)) / Double(xs.count) }
func meanD(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
func median(_ xs: [Int]) -> Double {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted(); let n = s.count
    return n % 2 == 1 ? Double(s[n / 2]) : Double(s[n / 2 - 1] + s[n / 2]) / 2.0
}
func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "n/a" : String(format: "%.0f%%", Double(a) * 100 / Double(b)) }
func padR(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
func padL(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: " ", count: n - s.count) + s }

/// Une ligne de résultat = (engine, K). Cascade ne dépend pas de K (mesurée une
/// fois, dupliquée par K dans la table pour la lisibilité), mais on la garde par K
/// pour rendre la table self-contained.
struct EngineK {
    let engine: String   // "cascade" | "beam"
    let k: Int
    var agg = Agg()
    var byDomain: [String: Agg] = [:]
    var crashed = false
}

func accumulate(into ek: inout EngineK, item: AfterSpaceItem,
                ghost: String, topCands: [String], ms: Int) {
    func acc(_ a: inout Agg) {
        a.n += 1
        a.latencies.append(ms)
        if mwExactWordHit(ghost: ghost, trueRemainder: item.goldContinuation) { a.hit1 += 1 }
        var topHit = false
        for c in topCands where mwExactWordHit(ghost: c, trueRemainder: item.goldContinuation) { topHit = true; break }
        if topHit { a.hitTopK += 1 }
        a.correctWords.append(correctWords(ghost: ghost, trueRemainder: item.goldContinuation))
        a.correctChars.append(correctChars(ghost: ghost, trueRemainder: item.goldContinuation))
        if let soft = mwSemSoftHit(ghost: ghost, trueRemainder: item.goldContinuation, thresh: semThresh) {
            a.softDenom += 1
            if soft { a.softHit += 1 }
        }
    }
    acc(&ek.agg)
    var dom = ek.byDomain[item.domain] ?? Agg()
    acc(&dom)
    ek.byDomain[item.domain] = dom
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Rendu de la synthèse (table + by-domain + K-answer + verdict-data).
// ─────────────────────────────────────────────────────────────────────────────

func renderRow(_ name: String, _ a: Agg, topK: Int) -> String {
    let h1 = pct(a.hit1, a.n)
    let hk = pct(a.hitTopK, a.n)
    let cw = String(format: "%.2f", mean(a.correctWords))
    let cc = String(format: "%.1f", mean(a.correctChars))
    let soft = a.softDenom == 0 ? "n/a" : "\(pct(a.softHit, a.softDenom))"
    let lat = String(format: "%.0f/%.0f", mean(a.latencies), median(a.latencies))
    return " " + padR(name, 12) + " | " + padR(h1, 8) + " | " + padR(hk, 9) + " | "
        + padR(cw, 11) + " | " + padR(cc, 11) + " | " + padR(soft, 8) + " | " + padL(lat, 11) + "\n"
}

func renderReport(rows: [EngineK], note: String,
                  sentences: Int, items: Int, topK: Int, ks: [Int]) -> String {
    var out = ""
    out += "════════════════════════════════════════════════════════════════════════\n"
    out += " SouffleuseAfterSpaceEval — caret APRÈS-ESPACE (pas de requiredPrefix)\n"
    out += " gold : \(sentences) phrases · \(items) items after-space (continuation multi-mots)\n"
    out += " corpus OFF / perso OFF — couche LLM seule. K ∈ \(ks). seuil sém cos ≥ \(semThresh)\n"
    out += " ⚠ recall-instantané + n-gram perso HORS PÉRIMÈTRE (force after-space de la cascade NON créditée)\n"
    out += " \(note)\n"
    out += "════════════════════════════════════════════════════════════════════════\n\n"

    // Table principale.
    out += " engine/K     | hit@1    | hit@top\(topK) | corr-words  | corr-chars  | cohér.   | lat moy/méd\n"
    out += " ─────────────+──────────+───────────+─────────────+─────────────+──────────+────────────\n"
    for r in rows {
        let label = "\(r.engine) K=\(r.k)" + (r.crashed ? " ⚠" : "")
        out += renderRow(label, r.agg, topK: topK)
    }

    // By-domain (corr-words, la métrique principale, + hit@1).
    out += "\n OVERLAP MULTI-MOTS par domaine (mean corr-words / hit@1) :\n"
    let domains = ["quotidien", "email-pro", "chat", "narratif", "technique", "fiscalité", "prose", "listes"]
    out += " " + padR("domaine", 12) + " | "
    for r in rows { out += padR("\(r.engine)K\(r.k)", 12) + " | " }
    out += "\n"
    for d in domains {
        out += " " + padR(d, 12) + " | "
        for r in rows {
            if let a = r.byDomain[d], a.n > 0 {
                out += padR(String(format: "%.2fw/%@", mean(a.correctWords), pct(a.hit1, a.n)), 12) + " | "
            } else {
                out += padR("—", 12) + " | "
            }
        }
        out += "\n"
    }

    // ── K-answer : deltas K=1 → K=2 → K=3 (beam only ; la cascade est K-invariante). ──
    out += "\n────────────────────────────────────────────────────────────────────────\n"
    out += " EST-CE QUE K COMPTE APRÈS-ESPACE ? (beam : deltas K vs K=1)\n"
    out += "────────────────────────────────────────────────────────────────────────\n"
    let beamRows = rows.filter { $0.engine == "beam" }.sorted { $0.k < $1.k }
    if let k1 = beamRows.first(where: { $0.k == 1 }) {
        func h1f(_ r: EngineK) -> Double { r.agg.n == 0 ? 0 : Double(r.agg.hit1) / Double(r.agg.n) }
        func hkf(_ r: EngineK) -> Double { r.agg.n == 0 ? 0 : Double(r.agg.hitTopK) / Double(r.agg.n) }
        let baseH1 = h1f(k1), baseCW = mean(k1.agg.correctWords), baseLat = median(k1.agg.latencies)
        out += "   K=1 (greedy LIBRE, aucun fan-out) : hit@1 \(pct(k1.agg.hit1, k1.agg.n))"
            + " · hit@top\(topK) \(pct(k1.agg.hitTopK, k1.agg.n))"
            + " · corr-words \(String(format: "%.2f", baseCW)) · lat méd \(String(format: "%.0f", baseLat)) ms\n"
        for r in beamRows where r.k > 1 {
            let dH1 = (h1f(r) - baseH1) * 100
            let dHk = (hkf(r) - hkf(k1)) * 100
            let dCW = mean(r.agg.correctWords) - baseCW
            let latX = median(r.agg.latencies) / max(1, baseLat)
            out += "   K=\(r.k) vs K=1 : hit@1 \(dH1 >= 0 ? "+" : "")\(String(format: "%.1f", dH1)) pts"
                + " · hit@top\(topK) \(dHk >= 0 ? "+" : "")\(String(format: "%.1f", dHk)) pts"
                + " · corr-words \(dCW >= 0 ? "+" : "")\(String(format: "%.2f", dCW))"
                + " · lat ×\(String(format: "%.2f", latX))\n"
        }
    } else {
        out += "   (K=1 non mesuré dans ce run)\n"
    }

    // ── Verdict-data : beam(meilleur K) vs cascade, sur les 4 axes. ──
    out += "\n────────────────────────────────────────────────────────────────────────\n"
    out += " BEAM (meilleur K) vs CASCADE — données pour le verdict\n"
    out += "────────────────────────────────────────────────────────────────────────\n"
    if let casc = rows.first(where: { $0.engine == "cascade" }) {
        // Meilleur K du beam = max corr-words (métrique principale).
        let bestBeam = rows.filter { $0.engine == "beam" }
            .max { mean($0.agg.correctWords) < mean($1.agg.correctWords) }
        if let bb = bestBeam {
            let bk = "\(bb.k)"
            func line(_ axis: String, _ c: String, _ b: String, _ winner: String) {
                var s = "   "
                s += padR(axis, 22)
                s += " cascade "
                s += padR(c, 10)
                s += " | beam(K=" + bk + ") "
                s += padR(b, 10)
                s += " → "
                s += winner
                s += "\n"
                out += s
            }
            let cH1 = Double(casc.agg.hit1) / Double(max(1, casc.agg.n))
            let bH1 = Double(bb.agg.hit1) / Double(max(1, bb.agg.n))
            line("(a) next-word hit@1", pct(casc.agg.hit1, casc.agg.n), pct(bb.agg.hit1, bb.agg.n),
                 abs(cH1 - bH1) < 0.02 ? "TIE" : (bH1 > cH1 ? "BEAM" : "CASCADE"))
            let cCW = mean(casc.agg.correctWords), bCW = mean(bb.agg.correctWords)
            line("(b) corr-words (MAIN)", String(format: "%.2f", cCW), String(format: "%.2f", bCW),
                 abs(cCW - bCW) < 0.10 ? "TIE" : (bCW > cCW ? "BEAM" : "CASCADE"))
            let cSoft = casc.agg.softDenom == 0 ? 0 : Double(casc.agg.softHit) / Double(casc.agg.softDenom)
            let bSoft = bb.agg.softDenom == 0 ? 0 : Double(bb.agg.softHit) / Double(bb.agg.softDenom)
            line("(c) cohérence soft", pct(casc.agg.softHit, casc.agg.softDenom), pct(bb.agg.softHit, bb.agg.softDenom),
                 abs(cSoft - bSoft) < 0.02 ? "TIE" : (bSoft > cSoft ? "BEAM" : "CASCADE"))
            let cLat = median(casc.agg.latencies), bLat = median(bb.agg.latencies)
            line("(d) cold-latency méd", String(format: "%.0fms", cLat), String(format: "%.0fms", bLat),
                 cLat < bLat ? "CASCADE" : (bLat < cLat ? "BEAM" : "TIE"))
        }
    }
    out += "\n NB : corr-words = nb de mots de la VRAIE suite gardés justes en tête (frappes\n"
    out += "      épargnées sur une lancée). corr-chars = idem en caractères. cohér. = part\n"
    out += "      des ghosts à cos(ghost, suite) ≥ \(semThresh). lat = génération à FROID.\n"
    return out
}

// Snapshots des comptes du corpus (capturés AVANT la boucle pour le flush nonisolated-safe).
let sentenceCount = goldSentences.count
let itemCount = allItems.count

var allRows: [EngineK] = []

func flush(_ rows: [EngineK], _ note: String) {
    let s = renderReport(rows: rows, note: note,
                         sentences: sentenceCount, items: itemCount, topK: topKWanted, ks: sweepKs)
    try? s.write(toFile: outPath, atomically: true, encoding: .utf8)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Run.
// ─────────────────────────────────────────────────────────────────────────────

print("")
print("════════════════════════════════════════════════════════════════════════")
print(" SouffleuseAfterSpaceEval — \(itemCount) items after-space · \(sentenceCount) phrases")
print(" K ∈ \(sweepKs) · GGUF : \(resolved)")
print(" emb sémantique : \(MWSemEmbedding.shared.path) · seuil cos ≥ \(semThresh)")
print(" synthèse incrémentale → \(outPath)")
print("════════════════════════════════════════════════════════════════════════")

// ── 1) CASCADE (K-invariante : une passe, mais on l'inscrit comme ligne dédiée). ──
var cascadeRow = EngineK(engine: "cascade", k: 0)
err("[afterspace] cascade : \(itemCount) items…")
for (n, item) in allItems.enumerated() {
    let c = await cascadeAfterSpace(prefix: item.prefix)
    accumulate(into: &cascadeRow, item: item, ghost: c.ghost, topCands: [c.ghost], ms: c.ms)
    if (n + 1) % 25 == 0 { err("[afterspace]   cascade \(n + 1)/\(itemCount)") }
}
await engine.unload()
allRows.append(cascadeRow)
print("  cascade : hit@1 \(pct(cascadeRow.agg.hit1, cascadeRow.agg.n)) · corr-words \(String(format: "%.2f", mean(cascadeRow.agg.correctWords))) · lat méd \(String(format: "%.0f", median(cascadeRow.agg.latencies))) ms")
flush(allRows, "cascade complétée ; beam en cours")

// ── 2) BEAM sweep K ∈ {1,2,3} : un LOAD par K (n_seq_max = K+1 fixé au load). ──
for k in sweepKs {
    var cfg = BeamConfig.cotypistDefault
    cfg.maxSearchWidth = k
    cfg.maxResultWidth = k
    let beam = BeamGhostEngine(config: cfg)
    err("[afterspace] beam K=\(k) — load (n_seq_max=\(k + 1))")
    guard await beam.load(modelPath: resolved, contextTokens: 4096) else {
        err("[afterspace] beam K=\(k) — LOAD FAILED, on saute"); continue
    }
    var beamRow = EngineK(engine: "beam", k: k)
    for (n, item) in allItems.enumerated() {
        // Après-espace : requiredPrefix = "" (aucune lettre du mot suivant tapée).
        let res = await beam.ghost(prompt: beamPrompt(prefix: item.prefix), requiredPrefix: "")
        let best = res.best?.ghost ?? ""
        let topCands = Array(res.candidates.prefix(min(topKWanted, k)).map { $0.ghost })
        accumulate(into: &beamRow, item: item, ghost: best, topCands: topCands, ms: res.elapsedMillis)
        if (n + 1) % 25 == 0 { err("[afterspace]   beam K=\(k) \(n + 1)/\(itemCount)") }
    }
    await beam.unload()
    allRows.append(beamRow)
    print("  beam K=\(k) : hit@1 \(pct(beamRow.agg.hit1, beamRow.agg.n)) · hit@top\(topKWanted) \(pct(beamRow.agg.hitTopK, beamRow.agg.n)) · corr-words \(String(format: "%.2f", mean(beamRow.agg.correctWords))) · lat méd \(String(format: "%.0f", median(beamRow.agg.latencies))) ms")
    // Résilience : flush DÈS QU'UN K est complet (crash tardif → K déjà mesurés sauvés).
    flush(allRows, "beam K=\(k) complété (sweep en cours)")
}

// ── Synthèse finale. ──
let body = renderReport(rows: allRows, note: "run COMPLET",
                        sentences: sentenceCount, items: itemCount, topK: topKWanted, ks: sweepKs)
print("")
print(body)
try? body.write(toFile: outPath, atomically: true, encoding: .utf8)
print(" (synthèse complète aussi écrite dans \(outPath))")
print("")
print("FIN.")
