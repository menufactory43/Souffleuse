import Foundation
import NaturalLanguage
import SouffleuseCore
import SouffleuseLlama
import SouffleuseLog
import SouffleuseCorpus
import SouffleusePersonalization
import SouffleuseTyping

// Souffleuse Mid-word Eval Bench
//
// The OCR ablation only exercises after-space / sentence-start completions.
// But the live `overlay_shown` log says ~80% of real ghosts fire MID-WORD
// (caret sits inside a word). That path does NOT go through the free LLM in
// production: `SuggestionPolicy.routeInstant` routes mid-word to L1 (corpus
// recall) first, then L0 (NSSpellChecker word completion); the L2 LLM is
// largely blocked there. So the relevance the user FEELS day-to-day is mostly
// decided by L0/L1 — never measured until now.
//
// For each mid-word prefix this bench prints, side by side:
//   L0  — WordCompleter.completion(for:)            (finish the partial word)
//   L1  — SuggestionPolicy.strongCorpusMatch(...)   (recall from real history)
//   L2  — LlamaEngine.generate(healPrefix:)         (healed whole-word LLM)
//   PICK — SuggestionPolicy.routeInstant(...)        (what prod ACTUALLY shows)
//
// `expected` is the correct continuation, so correctness is eyeball-able.
//
// Usage:
//   SOUFFLEUSE_GGUF=~/Library/Application\ Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf \
//     swift run SouffleuseMidwordEval

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

struct MWCase: Sendable {
    let label: String
    /// Prefix whose LAST char is a letter → caret sits mid-word.
    let prefix: String
    /// The continuation a perfect completer would emit (suffix of the word,
    /// possibly followed by next words). For judging only.
    let expected: String
}

let cases: [MWCase] = [
    // ── Killers from the codebase's own comments ──────────────────────────
    .init(label: "informations-pe", prefix: "Nous protégeons vos informations pe", expected: "rsonnelles"),
    .init(label: "rapport-fis",      prefix: "Vous trouverez votre rapport fis",   expected: "cal"),
    // ── Waltio / fiscalité support domain (matches OCR ablation register) ──
    .init(label: "plus-value",       prefix: "Le calcul de la plus-v",             expected: "alue"),
    .init(label: "investissement",   prefix: "qui prend en compte votre inv",      expected: "estissement"),
    .init(label: "cession",          prefix: "le montant de la cess",              expected: "ion"),
    .init(label: "portefeuille",     prefix: "la valeur globale de votre portef",  expected: "euille"),
    .init(label: "acquisition",      prefix: "votre prix total d'acqui",           expected: "sition"),
    .init(label: "imposable",        prefix: "la fraction imposa",                 expected: "ble"),
    // ── Generic FR support register ───────────────────────────────────────
    .init(label: "effectivement",    prefix: "merci pour votre message. Effectiv", expected: "ement"),
    .init(label: "normal",           prefix: "Bonjour, c'est tout à fait nor",     expected: "mal"),
    .init(label: "patience",         prefix: "je vous remercie de votre pati",     expected: "ence"),
    .init(label: "delais",           prefix: "nous reviendrons vers vous dans les meilleurs dél", expected: "ais"),
    .init(label: "disposition",      prefix: "Je reste à votre dispos",            expected: "ition"),
    // ── Short / ambiguous (where the 1B guesses the wrong word) ───────────
    .init(label: "co-short",         prefix: "Bonjour, co",                        expected: "mment (ambigu)"),
    .init(label: "po-short",         prefix: "Po",                                 expected: "ur (ambigu)"),
    // ── Mots imprévisibles par le contexte (phrase loufoque) : vrais mots du
    //    dico mais que rien dans la phrase ne laisse deviner. On veut voir si le
    //    modèle CONVERGE quand même une fois assez de lettres tapées. ──────────
    .init(label: "pingouin",         prefix: "Hier au zoo j'ai vu un pingou",      expected: "in"),
    .init(label: "aspirateur",       prefix: "je viens d'acheter un aspira",       expected: "teur"),
    .init(label: "sandwich",         prefix: "il a mangé tout mon sandwi",         expected: "ch"),
    .init(label: "cacahuete",        prefix: "une tartine au beurre de cacahu",    expected: "ète"),
    .init(label: "salsa",            prefix: "ce soir nous dansons la sal",        expected: "sa"),
    // ── Nom propre : génuinement indevinable → on ATTEND une divergence/suppr.
    .init(label: "gerard-propre",    prefix: "un aspirateur nommé Gér",            expected: "ard (ambigu)"),
    // ── Fragments courts réellement multi-continuations ────────────────────
    .init(label: "il-fa",            prefix: "je pense qu'il fa",                  expected: "ut/it (ambigu)"),
    .init(label: "je-tr",            prefix: "désolé, je tr",                      expected: "ouve/availle (ambigu)"),
]

// ── L2 sampling: mirror production `generateLlama` exactly. ───────────────
// `minFirstTokenProb` à un epsilon (0.0001) force le calcul du softmax top-1
// (sinon nil — « zéro overhead »). En greedy le token choisi EST l'argmax, donc
// `firstTokenProb` = la vraie confiance top-1 du modèle = le signal Cotypist
// `minBranchProbability`. Seuil si bas qu'il n'aborte jamais → sortie inchangée.
func runLLM(prefix: String, engine: LlamaEngine) async -> (out: String, ms: Int, p1: Double?) {
    let heal = OutputFilter.trailingPartialWord(prefix)
    let prompt = LlamaPromptBuilder.buildLlamaPrompt(
        system: "", customInstr: "", ctxPrefix: "", fieldContext: "",
        afterCursor: "", beforeCursor: prefix
    )
    let start = Date()
    final class Acc: @unchecked Sendable { var text = "" }
    let acc = Acc()
    let metrics = await engine.generate(
        prompt: prompt,
        maxTokens: 12,
        sampling: LlamaSampling(
            temperature: 0,
            repeatPenalty: 1.3,
            repeatLastN: 64,
            personalizationStrength: 0,
            banMarkup: true,
            banDigitsLeading: true,
            banEmoji: true,
            minFirstTokenProb: 0.0001,
            healPrefix: heal.isEmpty ? nil : heal
        )
    ) { tok in acc.text += tok; return true }
    let ms = Int(Date().timeIntervalSince(start) * 1000)
    let oneLine = acc.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? acc.text
    return (oneLine, ms, metrics.firstTokenProb)
}

// ── Branch-divergence mode (spike) ────────────────────────────────────────
// Hypothèse : le LLM peut redevenir pertinent mid-mot si on le CADRE par des
// branches. Une branche = un appel `generate` avec temperature>0 + seed
// distinct ; le RESTE du profil prod est IDENTIQUE (repeatPenalty 1.3, bans,
// healPrefix). `llama_sampler_init_dist(seed)` rend chaque branche stochastique
// ET reproductible. On mesure (a) l'ACCORD inter-branches sur le mot complété
// et (b) la confiance `firstTokenProb` par branche (parité Cotypist
// minBranchProbability). Le KV cache réutilise le prefill (prompt identique
// entre branches) → coût ≈ 1 prefill + k décodes courts.
/// Run de tête « mot » : lettres/chiffres + joints intra-mot (' ’ -), espaces
/// de tête ignorés. Vide ⇒ la branche a sauté au mot suivant (espace/ponct).
func leadWord(_ s: String) -> String {
    var t = Substring(s)
    while t.first == " " { t = t.dropFirst() }
    var out = ""
    for ch in t {
        if ch.isLetter || ch.isNumber || ch == "'" || ch == "’" || ch == "-" { out.append(ch) }
        else { break }
    }
    return out
}

/// K branches stochastiques (même prompt healed, seeds distincts). Retourne le
/// run de tête « mot » de chaque branche — c'est lui qu'on compare entre elles.
func runLLMBranches(prefix: String, engine: LlamaEngine, k: Int, temp: Float) async -> [String] {
    let heal = OutputFilter.trailingPartialWord(prefix)
    let prompt = LlamaPromptBuilder.buildLlamaPrompt(
        system: "", customInstr: "", ctxPrefix: "", fieldContext: "",
        afterCursor: "", beforeCursor: prefix
    )
    var leads: [String] = []
    for i in 0..<k {
        final class Acc: @unchecked Sendable { var text = "" }
        let acc = Acc()
        _ = await engine.generate(
            prompt: prompt,
            maxTokens: 12,
            sampling: LlamaSampling(
                temperature: temp,
                repeatPenalty: 1.3,
                repeatLastN: 64,
                seed: UInt32(i + 1),
                personalizationStrength: 0,
                topP: 0.9,
                banMarkup: true,
                banDigitsLeading: true,
                banEmoji: true,
                healPrefix: heal.isEmpty ? nil : heal
            )
        ) { tok in acc.text += tok; return true }
        let oneLine = acc.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? acc.text
        leads.append(leadWord(oneLine))
    }
    return leads
}

/// Accord inter-branches : mot modal (casse d'origine), son compte, l'accord [0,1].
func agreementStats(_ leads: [String]) -> (modal: String, modalCount: Int, agreement: Double) {
    guard !leads.isEmpty else { return ("", 0, 0) }
    var counts: [String: Int] = [:]
    for l in leads { counts[l.lowercased(), default: 0] += 1 }
    let top = counts.max { a, b in a.value < b.value }
    let modalKey = top?.key ?? ""
    let modalCount = top?.value ?? 0
    let modalDisplay = leads.first { $0.lowercased() == modalKey } ?? ""
    return (modalDisplay, modalCount, Double(modalCount) / Double(leads.count))
}

/// Verdict de correction : le mot modal reconstitue-t-il le mot VISÉ
/// (`partiel tapé + expected`) ? Tolère l'élision de tête (« d'acquisition ») et
/// le pluriel de queue. nil = cas marqué ambigu (exclu du calcul). Le modal est
/// le mot ENTIER re-dérivé par le healing, pas le suffixe — d'où la reconstruction.
func judgeBranch(prefix: String, expected: String, modal: String) -> Bool? {
    if expected.contains("(ambigu)") { return nil }
    func core(_ s: String) -> String { s.lowercased().filter { $0.isLetter } }
    let partial = OutputFilter.trailingPartialWord(prefix)
    let intended = core(partial + expected)
    let m = core(modal)
    guard m.count >= 3, !intended.isEmpty else { return false }
    return m == intended || m.contains(intended)
        || (intended.contains(m) && m.count >= 4 && m.count >= intended.count - 2)
}

struct CaseBranchStat { let label: String; let agreement: Double; let p1: Double?; let modal: String; let correct: Bool? }

// ── Escalation prototype (Frame C, forme shippable) ───────────────────────
// Étage 1 (greedy, 1 passe) : REJETTE vite les échecs de healing (mot fusionné
// invalide : « pingo », « a », « s », « i ») et ACCEPTE vite les complétions
// confiantes (P1 haut + fragment assez long pour être peu ambigu : « cacahuète »).
// Étage 2 (branches k≤3, courtes, early-exit) UNIQUEMENT pour la zone incertaine
// (mot valide mais P1 bas, ou fragment court : « fis », « co », « Po »). But :
// ne payer les branches QUE quand c'est nécessaire.

/// Validité dico synchrone : `defaultPartialWordIsComplete(w)` calcule
/// `trailingPartialWord(w)` (= w pour un mot nu) puis NSSpellChecker.
func isValidWordSync(_ w: String) -> Bool {
    guard !w.isEmpty else { return false }
    return SuggestionPolicy.defaultPartialWordIsComplete(w)
}

/// Le mot `modal` prolonge-t-il le partiel tapé ET est-il un vrai mot ? Attrape
/// les échecs de healing (« a » ne prolonge pas « aspira », « pingo » ≠ « pingou »).
func validExtends(partial: String, modal: String) -> Bool {
    guard modal.lowercased().hasPrefix(partial.lowercased()) else { return false }
    return isValidWordSync(modal)
}

/// Une branche COURTE (maxTokens 4 — on ne veut que le mot courant) → run de tête.
func oneBranchLead(prompt: String, heal: String?, seed: UInt32, temp: Float, engine: LlamaEngine) async -> String {
    final class Acc: @unchecked Sendable { var text = "" }
    let acc = Acc()
    _ = await engine.generate(
        prompt: prompt, maxTokens: 4,
        sampling: LlamaSampling(
            temperature: temp, repeatPenalty: 1.3, repeatLastN: 64, seed: seed,
            personalizationStrength: 0, topP: 0.9,
            banMarkup: true, banDigitsLeading: true, banEmoji: true,
            healPrefix: heal
        )
    ) { tok in acc.text += tok; return true }
    let oneLine = acc.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? acc.text
    return leadWord(oneLine)
}

struct EscResult {
    let stage: String        // FAST-ACCEPT / FAST-REJECT / BRANCHED
    let shown: Bool
    let word: String
    let agreement: Double    // 1.0 pour les voies rapides (pas de branches)
    let branches: Int
    let ms: Double
    let correct: Bool?
}

func escalate(c: MWCase, engine: LlamaEngine,
              fastP1: Double, minFastLen: Int, k: Int, temp: Float, agreeThresh: Double) async -> EscResult {
    let t0 = Date()
    let partial = OutputFilter.trailingPartialWord(c.prefix)
    let (gout, _, p1) = await runLLM(prefix: c.prefix, engine: engine)
    let gmodal = leadWord(gout)

    // Étage 1a — rejet rapide des échecs de healing (0 branche).
    if !validExtends(partial: partial, modal: gmodal) {
        return EscResult(stage: "FAST-REJECT", shown: false, word: gmodal, agreement: 1.0,
                         branches: 0, ms: Date().timeIntervalSince(t0) * 1000,
                         correct: judgeBranch(prefix: c.prefix, expected: c.expected, modal: gmodal))
    }
    // Étage 1b — accept rapide : confiant ET fragment assez long pour être peu
    // ambigu. (Un fragment court « Po » à P1 haut reste suspect → on branche.)
    if (p1 ?? 0) >= fastP1 && partial.count >= minFastLen {
        return EscResult(stage: "FAST-ACCEPT", shown: true, word: gmodal, agreement: 1.0,
                         branches: 0, ms: Date().timeIntervalSince(t0) * 1000,
                         correct: judgeBranch(prefix: c.prefix, expected: c.expected, modal: gmodal))
    }

    // Étage 2 — branches (le greedy compte comme 1 vote), early-exit dès qu'un
    // mot atteint la majorité requise.
    let heal = partial.isEmpty ? nil : partial
    let prompt = LlamaPromptBuilder.buildLlamaPrompt(
        system: "", customInstr: "", ctxPrefix: "", fieldContext: "", afterCursor: "", beforeCursor: c.prefix)
    var counts: [String: Int] = [gmodal.lowercased(): 1]
    var displays: [String: String] = [gmodal.lowercased(): gmodal]
    var votes = 1
    let needed = Int((agreeThresh * Double(k + 1)).rounded(.up))
    var used = 0
    for i in 0..<k {
        let lead = await oneBranchLead(prompt: prompt, heal: heal, seed: UInt32(i + 1), temp: temp, engine: engine)
        used += 1; votes += 1
        counts[lead.lowercased(), default: 0] += 1
        if displays[lead.lowercased()] == nil { displays[lead.lowercased()] = lead }
        if let top = counts.values.max(), top >= needed { break }   // early-exit
    }
    let top = counts.max { a, b in a.value < b.value }
    let modal = displays[top?.key ?? ""] ?? ""
    let agreement = Double(top?.value ?? 0) / Double(votes)
    let shown = agreement >= agreeThresh && validExtends(partial: partial, modal: modal)
    return EscResult(stage: "BRANCHED", shown: shown, word: modal, agreement: agreement,
                     branches: used, ms: Date().timeIntervalSince(t0) * 1000,
                     correct: judgeBranch(prefix: c.prefix, expected: c.expected, modal: modal))
}

// ── Shared text helpers for the INTENTION modes (MW_INTENT / MW_INTENT_REAL) ─
// Factored out of the MW_INTENT block so the REAL-history variant reuses the
// EXACT same scoring (fold / contentWords / targetVocab / stemMatch / hitTopic)
// and the same mid-word cut logic (Cut / midWordCuts). Pure, file-scope.

// NORMALIZE = lowercase + accent-fold + lettres seulement.
func mwFold(_ s: String) -> String {
    s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR")).lowercased()
}
let mwFrStop: Set<String> = ["le", "la", "les", "de", "des", "du", "un", "une", "et", "a", "à",
                             "au", "aux", "en", "je", "tu", "il", "elle", "on", "nous", "vous",
                             "ce", "cette", "ces", "que", "qui", "pas", "ne", "se", "sa", "son",
                             "ses", "mes", "mon", "ma", "pour", "plus", "dans", "est", "sont",
                             "avec", "mais", "ou", "si", "tout", "tous"]
// Mots de contenu NORMALISÉS : fold → garder lettres → drop stoplist + <3 chars.
func mwContentWords(_ s: String) -> [String] {
    mwFold(s)
        .split { !$0.isLetter }
        .map(String.init)
        .filter { $0.count >= 3 && !mwFrStop.contains($0) }
}
// Vocabulaire-cible normalisé : target ENTIER + steer_tokens (si présents).
func mwTargetVocab(target: String, steerTokens: [String]) -> [String] {
    var words = mwContentWords(target)
    for tok in steerTokens { words.append(contentsOf: mwContentWords(tok)) }
    var seen = Set<String>(); return words.filter { seen.insert($0).inserted }
}
// STEM-MATCH : préfixe commun ≥4 chars (« fraise »/« fraises »/« fraisier »).
func mwStemMatch(_ a: String, _ b: String) -> Bool {
    if a == b { return true }
    let n = min(a.count, b.count)
    guard n >= 4 else { return false }
    return a.hasPrefix(String(b.prefix(n))) || b.hasPrefix(String(a.prefix(n)))
}
// hit_topic : un ghostWord stem-matche un mot du targetVocab. Retourne le mot
// de vocabulaire-cible qui a matché (nil = aucun → STEP-FAIL).
func mwHitTopic(ghost: String, vocab: [String]) -> String? {
    let g = mwContentWords(ghost)
    for gw in g {
        for vw in vocab where mwStemMatch(gw, vw) { return vw }
    }
    return nil
}

// ── JUGE SÉMANTIQUE (embedding NaturalLanguage) ───────────────────────────
// Le juge lexical SOUS-compte sur données réelles : il ne peut pas créditer un
// « recadrage » sémantiquement correct (ghost « des fruits et légumes » après
// « manger » alors que l'utilisateur a tapé « pommes de terre »). On ajoute donc
// un juge embedding : cosinus entre la CONTINUATION RECOLLÉE (partiel + ghost) et
// le VRAI RESTE de la cible. OR'd avec le juge lexical → STEP-PASS si l'un OU
// l'autre tire.
//
// Stratégie de disponibilité (vérifiée À L'EXÉCUTION, pas de crash possible) :
//   1. on ESSAIE d'abord `NLEmbedding.sentenceEmbedding(for: .french)` — vecteur
//      de phrase natif, la voie idéale (capte l'ordre / la composition).
//   2. fallback : `NLEmbedding.wordEmbedding(for: .french)` — on moyenne les
//      vecteurs des mots de contenu (OOV ignorés) pour fabriquer un vecteur de
//      phrase « sac de mots ».
//   3. si LES DEUX sont nil sur cet OS : score sémantique = nil (NaN), un
//      avertissement clair imprimé UNE fois, le juge retombe sur le lexical seul.
//
// NLEmbedding est synchrone et thread-safe pour la lecture (vector(for:) ne mute
// rien), mais la classe n'est PAS marquée `Sendable` par le SDK. On l'isole donc
// dans une boîte `@unchecked Sendable` : le bench est mono-thread sur ces appels
// (lecture pure), la garantie est respectée.
final class MWSemEmbedding: @unchecked Sendable {
    let sentence: NLEmbedding?
    let word: NLEmbedding?
    /// Voie réellement empruntée, pour le rapport : "sentence" / "word" / "none".
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

/// Indicateur « avertissement déjà imprimé » (une seule fois) — référence-classe
/// pour rester mutable depuis une fonction non-mutating sans capture inout.
final class MWSemWarned: @unchecked Sendable { var done = false }
let mwSemWarned = MWSemWarned()

/// Vecteur de phrase pour `s`, selon la voie disponible :
///  - sentence embedding natif si présent ;
///  - sinon moyenne des vecteurs des MOTS DE CONTENU (OOV sautés) ;
///  - nil si aucune voie / aucun mot connu / chaîne vide.
func mwSentenceVector(_ s: String, _ emb: MWSemEmbedding) -> [Double]? {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let sentence = emb.sentence {
        let v = sentence.vector(for: trimmed)
        return (v?.isEmpty == false) ? v : nil
    }
    guard let word = emb.word else { return nil }
    // Sac-de-mots : moyenne des vecteurs des mots de contenu connus du modèle.
    let words = mwContentWords(trimmed)
    guard !words.isEmpty else { return nil }
    var sum: [Double] = []
    var n = 0
    for w in words {
        guard let v = word.vector(for: w), !v.isEmpty else { continue }   // OOV → sauté
        if sum.isEmpty { sum = v } else { for i in 0..<min(sum.count, v.count) { sum[i] += v[i] } }
        n += 1
    }
    guard n > 0, !sum.isEmpty else { return nil }
    return sum.map { $0 / Double(n) }
}

/// Cosinus entre deux vecteurs (1 = identiques, 0 = orthogonaux). nil si l'un est
/// vide ou de norme nulle.
func mwCosine(_ a: [Double], _ b: [Double]) -> Double? {
    let n = min(a.count, b.count)
    guard n > 0 else { return nil }
    var dot = 0.0, na = 0.0, nb = 0.0
    for i in 0..<n { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
    guard na > 0, nb > 0 else { return nil }
    return dot / (na.squareRoot() * nb.squareRoot())
}

/// Similarité cosinus sémantique entre la continuation RECOLLÉE et le vrai reste.
/// nil = embeddings indisponibles / vecteur introuvable (chaîne vide, tout OOV).
func mwSemCos(gluedGhost: String, trueRemainder: String) -> Double? {
    let emb = MWSemEmbedding.shared
    guard emb.sentence != nil || emb.word != nil else {
        if !mwSemWarned.done {
            mwSemWarned.done = true
            print("[mw-sem] ⚠️  AUCUN embedding FR (ni sentence ni word) sur cet OS → juge sémantique DÉSACTIVÉ (sem=-, via=topic seulement).")
        }
        return nil
    }
    guard let g = mwSentenceVector(gluedGhost, emb),
          let t = mwSentenceVector(trueRemainder, emb) else { return nil }
    return mwCosine(g, t)
}

/// JUGE PARTAGÉ (MW_INTENT + MW_INTENT_REAL). Un pas passe ssi le juge lexical OU
/// le juge sémantique tire. Retourne :
///  - pass     : `hit_topic || hit_sem`
///  - topicWord: le mot de vocabulaire-cible qui a stem-matché (nil sinon)
///  - semCos   : la similarité cosinus (nil = embedding indispo / introuvable)
///  - via      : quel juge a tiré — "topic" | "sem" | "both" | "-"
func mwJudgeStep(ghost: String, gluedGhost: String, vocab: [String],
                 trueRemainder: String, semThresh: Double)
    -> (pass: Bool, topicWord: String?, semCos: Double?, via: String) {
    // Ghost vide → jamais de pas (cohérent avec le comportement existant).
    guard !ghost.isEmpty else { return (false, nil, nil, "-") }
    let topicWord = mwHitTopic(ghost: gluedGhost, vocab: vocab)
    let hitTopic = topicWord != nil
    let semCos = mwSemCos(gluedGhost: gluedGhost, trueRemainder: trueRemainder)
    let hitSem = (semCos != nil) && (semCos! >= semThresh)
    let via: String
    switch (hitTopic, hitSem) {
    case (true, true):  via = "both"
    case (true, false): via = "topic"
    case (false, true): via = "sem"
    case (false, false): via = "-"
    }
    return (hitTopic || hitSem, topicWord, semCos, via)
}

// ── Points de coupe mid-mot dans les ~6 premiers mots ──
struct MWCut { let beforeCursor: String; let trueRemainder: String }
func mwMidWordCuts(_ target: String) -> [MWCut] {
    let chars = Array(target)
    func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "’" || c == "-" }
    var cuts: [MWCut] = []
    var i = 0
    var wordsSeen = 0
    while i < chars.count && wordsSeen < 6 {
        guard isWordChar(chars[i]) else { i += 1; continue }
        let wordStart = i
        var j = i
        while j < chars.count && isWordChar(chars[j]) { j += 1 }
        let wordLen = j - wordStart
        if wordLen >= 2 {
            let cutAt = wordStart + min(3, wordLen - 1)   // mid-mot, jamais frontière ni stub 1-char
            let before = String(chars[0..<cutAt])
            let remainder = String(chars[cutAt..<chars.count])
            cuts.append(MWCut(beforeCursor: before, trueRemainder: remainder))
            wordsSeen += 1
        }
        i = j
    }
    return cuts
}

// Génération du ghost LONG (approche évaluée) — partagée par les deux modes
// INTENTION. Greedy healed, cap tokens/mots, stop sur frontière de proposition,
// écho du partiel tapé retiré. Identique à l'ancien `longGhost` nested.
func mwLongGhost(beforeCursor: String, maxTokens: Int, maxWords: Int, stopSet: Set<Character>, nbest: Int = 1) async -> String {
    let partial = OutputFilter.trailingPartialWord(beforeCursor)
    let prompt = LlamaPromptBuilder.buildLlamaPrompt(
        system: "", customInstr: "", ctxPrefix: "", fieldContext: "",
        afterCursor: "", beforeCursor: beforeCursor
    )
    // Une passe = un `generate`. `temp == 0` (seed ignoré) = greedy ; `temp > 0`
    // + seed distinct = branche stochastique reproductible (cf. runEscalationPass
    // dans ModelRuntime.swift : seed 0 greedy, seed i+1 par branche, câblé sur
    // `llama_sampler_init_dist(seed)` dans LlamaEngine). Le seed PAR APPEL existe
    // donc bien → le N-best peut diversifier honnêtement.
    func pass(temp: Float, seed: UInt32) async -> String {
        final class Acc: @unchecked Sendable { var text = "" }
        let acc = Acc()
        _ = await engine.generate(
            prompt: prompt,
            maxTokens: maxTokens,
            sampling: LlamaSampling(
                temperature: temp,
                repeatPenalty: 1.3,
                repeatLastN: 64,
                seed: seed,
                personalizationStrength: 0,
                topP: temp > 0 ? 0.9 : 0,
                banMarkup: true,
                banDigitsLeading: true,
                banEmoji: true,
                minFirstTokenProb: 0,       // ne JAMAIS aborter sur 1er token peu confiant
                healPrefix: partial.isEmpty ? nil : partial
            )
        ) { tok in acc.text += tok; return true }
        return acc.text
    }
    // Post-traitement identique à l'ancien comportement : 1 ligne, écho du partiel
    // retiré, stop sur frontière de proposition, cap mots.
    func postProcess(_ raw: String) -> String {
        var line = raw.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? raw
        if !partial.isEmpty {
            let trimmed = line.drop { $0 == " " }
            let lf = mwFold(String(trimmed)), pf = mwFold(partial)
            if lf.hasPrefix(pf) {
                line = String(trimmed.dropFirst(partial.count))
            } else {
                line = String(trimmed)
            }
        }
        if let idx = line.firstIndex(where: { stopSet.contains($0) }) {
            line = String(line[line.startIndex..<idx])
        }
        let words = line.split(separator: " ").prefix(maxWords)
        return words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    // Candidat greedy (temp 0) — comportement par défaut (NBEST == 1).
    let greedy = postProcess(await pass(temp: 0, seed: 0))
    guard nbest > 1 else { return greedy }

    // SYNTHÈSE — fallback #1 : N-best re-rangé par logprob/token contre le VRAI
    // contexte gauche français. Au-delà du greedy, on tire (NBEST−1) branches à
    // basse température (0.3) avec des seeds distincts ; on re-classe TOUS les
    // candidats par `sequenceLogProb(context: beforeCursor, continuation:).
    // sumLogProb / tokenCount` (per-token, donc indépendant de la longueur ; cela
    // démote aussi le charabia en langue étrangère). On garde le meilleur.
    var candidates: [String] = [greedy]
    for i in 1..<nbest {
        let c = postProcess(await pass(temp: 0.3, seed: UInt32(i)))
        if !c.isEmpty { candidates.append(c) }
    }
    // Dé-doublonnage (les branches convergent souvent vers la même continuation).
    var seen = Set<String>()
    let unique = candidates.filter { seen.insert($0).inserted }
    guard unique.count > 1 else { return greedy }

    var best = greedy
    var bestScore = -Double.infinity
    for cand in unique {
        guard !cand.isEmpty,
              let lp = await engine.sequenceLogProb(context: beforeCursor, continuation: cand),
              lp.tokenCount > 0 else { continue }
        let perToken = lp.sumLogProb / Double(lp.tokenCount)
        if perToken > bestScore { bestScore = perToken; best = cand }
    }
    return best
}

// ── Boot the engine on the same GGUF as production / the OCR ablation. ────
let ggufPath: String = {
    if let p = ProcessInfo.processInfo.environment["SOUFFLEUSE_GGUF"], !p.isEmpty {
        return (p as NSString).expandingTildeInPath
    }
    return (("~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf") as NSString)
        .expandingTildeInPath
}()

let engine = LlamaEngine()
err("[midword] loading GGUF: \(ggufPath)")
guard await engine.load(modelPath: ggufPath, contextTokens: 4096) else {
    err("[midword] FATAL: could not load GGUF")
    exit(1)
}

// Real typing history → L1 corpus recall + engine n-gram (matches production).
// MW_NO_HISTORY=1 → skip the encrypted-store load entirely (no Keychain prompt,
// no SQLCipher lock contention with a concurrent run). L1/corpus then stays
// empty — fine for the L0-dico vs L2-longghost comparison, which needs neither.
let history: [TypingHistoryEntry]
if ProcessInfo.processInfo.environment["MW_NO_HISTORY"] != nil {
    history = []
    err("[midword] MW_NO_HISTORY: store load skipped (L1/corpus disabled)")
} else {
    let store = TypingHistoryStore()
    history = await store.allEntries()
    err("[midword] history entries: \(history.count)")
    if !history.isEmpty {
        await engine.setCorpus(history.map { e in
            e.contextBefore.isEmpty ? e.accepted : e.contextBefore + " " + e.accepted
        })
    }
}

let wordCompleter = WordCompleter()
let policy = await MainActor.run { SuggestionPolicyEngine(maxWords: 8) }

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
}
func show(_ s: String?) -> String { (s?.isEmpty == false) ? s! : "∅" }

let branchK = max(1, Int(ProcessInfo.processInfo.environment["MW_BRANCHES"] ?? "5") ?? 5)
let branchTemp = Float(ProcessInfo.processInfo.environment["MW_BRANCH_TEMP"] ?? "0.7") ?? 0.7
err("[midword] branch mode: k=\(branchK) temp=\(branchTemp)")
let escalateMode = ProcessInfo.processInfo.environment["MW_ESCALATE"] != nil

// ── Mode MESURE (MW_MEASURE=1) : chiffre latence + K minimal + tokens/branche ─
// Utilise les VRAIES fonctions de prod (midWordLeadWordDefrag / midWordFastDecision
// / midWordBranchDecision) sur les 24 cas. Early-exit → n'affecte aucun autre mode.
if ProcessInfo.processInfo.environment["MW_MEASURE"] != nil {
    let kmax = max(1, Int(ProcessInfo.processInfo.environment["MW_KMAX"] ?? "6") ?? 6)
    let mtemp = Float(ProcessInfo.processInfo.environment["MW_MTEMP"] ?? "0.4") ?? 0.4
    err("\n──────────── MESURE (kmax=\(kmax) temp=\(mtemp) agree=\(SuggestionPolicy.Tuning.escAgreeThresh)) ────────────")

    func timedBranch(prompt: String, heal: String?, seed: UInt32, maxTokens: Int) async -> (lead: String, ms: Double) {
        final class Acc: @unchecked Sendable { var text = "" }
        let acc = Acc()
        let t0 = Date()
        _ = await engine.generate(
            prompt: prompt, maxTokens: maxTokens,
            sampling: LlamaSampling(temperature: mtemp, repeatPenalty: 1.3, repeatLastN: 64,
                seed: seed, personalizationStrength: 0, topP: 0.9,
                banMarkup: true, banDigitsLeading: true, banEmoji: true, healPrefix: heal))
        { tok in acc.text += tok; return true }
        let ms = Date().timeIntervalSince(t0) * 1000
        let oneLine = acc.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? acc.text
        return (SuggestionPolicy.midWordLeadWordDefrag(oneLine, partial: heal ?? ""), ms)
    }
    // Décision « juste » : cas ambigu ⇒ doit CACHER ; déterminable ⇒ doit MONTRER le bon mot.
    func decisionCorrect(_ c: MWCase, show: Bool, word: String) -> Bool {
        if c.expected.contains("(ambigu)") { return !show }
        return show && (judgeBranch(prefix: c.prefix, expected: c.expected, modal: word) == true)
    }

    // Pré-calcul greedy (déterministe) : lead + P1 + ms + prompt, une fois.
    struct G { let partial: String; let lead: String; let p1: Double?; let prompt: String; let ms: Int }
    var G_: [G] = []
    for c in cases {
        let partial = OutputFilter.trailingPartialWord(c.prefix)
        let (gout, gms, p1) = await runLLM(prefix: c.prefix, engine: engine)
        let prompt = LlamaPromptBuilder.buildLlamaPrompt(
            system: "", customInstr: "", ctxPrefix: "", fieldContext: "", afterCursor: "", beforeCursor: c.prefix)
        G_.append(G(partial: partial, lead: SuggestionPolicy.midWordLeadWordDefrag(gout, partial: partial),
                    p1: p1, prompt: prompt, ms: gms))
    }
    let determinable = cases.filter { !$0.expected.contains("(ambigu)") }.count
    let greedyMsAvg = G_.reduce(0) { $0 + $1.ms } / max(1, G_.count)

    // ── Phase A : sweep K (branches BTOK=4), + latence/branche ──
    var branchMsSum = 0.0, branchMsN = 0
    var greedyCorrect = 0
    var correctAtK = [Int](repeating: 0, count: kmax + 1)
    for (idx, c) in cases.enumerated() {
        let g = G_[idx]
        switch SuggestionPolicy.midWordFastDecision(partial: g.partial, greedyModal: g.lead, firstTokenProb: g.p1) {
        case .fastAccept(let w): if decisionCorrect(c, show: true, word: w) { greedyCorrect += 1 }
        default:                 if decisionCorrect(c, show: false, word: "") { greedyCorrect += 1 }
        }
        let heal = g.partial.isEmpty ? nil : g.partial
        var leads: [String] = []
        for i in 0..<kmax {
            let (lead, bms) = await timedBranch(prompt: g.prompt, heal: heal, seed: UInt32(i + 1), maxTokens: 4)
            branchMsSum += bms; branchMsN += 1
            leads.append(lead)
            let d = SuggestionPolicy.midWordBranchDecision(partial: g.partial, greedyModal: g.lead, branchLeads: leads)
            if decisionCorrect(c, show: d.show, word: d.word) { correctAtK[i + 1] += 1 }
        }
    }
    err("\nLATENCE  : greedy ~\(greedyMsAvg) ms/passe · branche ~\(Int(branchMsSum / Double(max(1, branchMsN)))) ms/passe")
    err("JUSTESSE (\(cases.count) cas dont \(determinable) déterminables) — Q2 : K minimal pour battre le greedy")
    err("  greedy seul           : \(greedyCorrect)/\(cases.count)")
    for k in 1...kmax {
        let delta = correctAtK[k] - greedyCorrect
        err("  greedy + \(k) branche(s)  : \(correctAtK[k])/\(cases.count)   (\(delta >= 0 ? "+" : "")\(delta) vs greedy)")
    }

    // ── Phase B : sweep tokens/branche (K=kmax fixe) — Q3 ──
    err("\nTOKENS/BRANCHE (K=\(kmax) fixe) — Q3 : justesse ET latence par token-count (incl. 8 = prod)")
    for btok in [2, 3, 4, 6, 8] {
        var corr = 0
        var msSum = 0.0, msN = 0
        for (idx, c) in cases.enumerated() {
            let g = G_[idx]
            let heal = g.partial.isEmpty ? nil : g.partial
            var leads: [String] = []
            for i in 0..<kmax {
                let (lead, bms) = await timedBranch(prompt: g.prompt, heal: heal, seed: UInt32(i + 1), maxTokens: btok)
                msSum += bms; msN += 1
                leads.append(lead)
            }
            let d = SuggestionPolicy.midWordBranchDecision(partial: g.partial, greedyModal: g.lead, branchLeads: leads)
            if decisionCorrect(c, show: d.show, word: d.word) { corr += 1 }
        }
        err("  \(btok) tokens/branche : \(corr)/\(cases.count) corrects · ~\(Int(msSum / Double(max(1, msN)))) ms/branche")
    }

    // ── Phase C : sweep cap GREEDY — justesse du mot de tête + latence ──
    err("\nGREEDY CAP — justesse du mot de tête (\(determinable) déterminables) + latence")
    for gcap in [3, 4, 6, 8] {
        var leadCorrect = 0
        var msSum = 0.0
        var detail: [String] = []
        for c in cases where !c.expected.contains("(ambigu)") {
            let partial = OutputFilter.trailingPartialWord(c.prefix)
            let prompt = LlamaPromptBuilder.buildLlamaPrompt(
                system: "", customInstr: "", ctxPrefix: "", fieldContext: "", afterCursor: "", beforeCursor: c.prefix)
            final class Acc: @unchecked Sendable { var text = "" }
            let acc = Acc()
            let t0 = Date()
            _ = await engine.generate(
                prompt: prompt, maxTokens: gcap,
                sampling: LlamaSampling(temperature: 0, repeatPenalty: 1.3, repeatLastN: 64,
                    personalizationStrength: 0, banMarkup: true, banDigitsLeading: true, banEmoji: true,
                    minFirstTokenProb: 0.0001, healPrefix: partial.isEmpty ? nil : partial))
            { tok in acc.text += tok; return true }
            msSum += Date().timeIntervalSince(t0) * 1000
            let oneLine = acc.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? acc.text
            let lead = SuggestionPolicy.midWordLeadWordDefrag(oneLine, partial: partial)
            let ok = judgeBranch(prefix: c.prefix, expected: c.expected, modal: lead) == true
            if ok { leadCorrect += 1 }
            // Détail seulement au cap prod (8) pour montrer mot visé vs trouvé.
            if gcap == 8 {
                let intended = partial + c.expected
                detail.append("    \(ok ? "✅" : "❌") \(pad(c.label, 16)) visé=\(pad(intended, 16)) greedy=\(lead.isEmpty ? "∅" : lead)")
            }
        }
        err("  cap \(gcap) : \(leadCorrect)/\(determinable) mots corrects · ~\(Int(msSum / Double(cases.count))) ms/passe")
        if !detail.isEmpty {
            err("  ── détail @cap8 (mot visé vs greedy) ──")
            for d in detail { err(d) }
        }
    }
    exit(0)
}

// ── Mode INTENTION (MW_INTENT=1) : un ghost mid-mot LONG porte-t-il la bonne
// INTENTION sur des phrases FR génériques ? Approche SIMPLE évaluée : un seul
// `generate` greedy healed (maxTokens MW_LG_MAXTOKENS), post-traité en
// complétion-du-mot-courant + mots suivants (cap MW_LG_MAXWORDS, stop sur
// frontière de proposition). On coupe MID-MOT dans les ~6 premiers mots de
// chaque phrase, on génère le ghost, et on juge l'intention hors-ligne :
//   hit_lex   = ≥1 mot de contenu partagé avec le vrai reste (accent-fold, stem ≥4)
//   hit_steer = gNorm ≥ tNorm − marge (le ghost est aussi plausible que le vrai
//               reste, donc un recadrage type « les pommes » pour « les fraises »
//               passe même s'il diffère lexicalement).
// Barre : ≥3 coupes bonnes/phrase ; harness PASS si ≥50% des phrases passent.
// Bench hors `audit.sh` → print() autorisé. exit(0) en fin de bloc.
if ProcessInfo.processInfo.environment["MW_INTENT"] != nil {
    // ── Knobs ──
    let lgMaxTokens = max(1, Int(ProcessInfo.processInfo.environment["MW_LG_MAXTOKENS"] ?? "14") ?? 14)
    let lgMaxWords  = max(1, Int(ProcessInfo.processInfo.environment["MW_LG_MAXWORDS"] ?? "4") ?? 4)
    let lgNBest     = max(1, Int(ProcessInfo.processInfo.environment["MW_LG_NBEST"] ?? "1") ?? 1)
    let semThresh   = Double(ProcessInfo.processInfo.environment["MW_SEM_THRESH"] ?? "0.45") ?? 0.45
    let intentMargin = Double(ProcessInfo.processInfo.environment["MW_INTENT_MARGIN"] ?? "1.0") ?? 1.0
    // Stop set : MW_LG_STOP (chars collés ou séparés par virgule) + newline toujours.
    let stopSet: Set<Character> = {
        let raw = ProcessInfo.processInfo.environment["MW_LG_STOP"] ?? ".!?;:"
        var s = Set(raw.split(separator: ",").joined())   // tolère "." ou ".,!,?"
        s.formUnion(Set(raw.filter { $0 != "," }))         // ou collés ".!?;:"
        s.insert("\n")
        return s
    }()
    let phrasesPath = (ProcessInfo.processInfo.environment["MW_INTENT_PHRASES"]
        ?? "\(FileManager.default.currentDirectoryPath)/../.midword-eval/phrases.json")

    // ── Dataset ──
    struct IntentPhrase: Sendable { let id: String; let target: String; let intendedIdea: String; let steerTokens: [String] }
    func fallbackPhrases() -> [IntentPhrase] {
        [
            .init(id: "fruits", target: "J'aime les pommes, les fraises et surtout les cerises", intendedIdea: "fruits", steerTokens: ["pommes", "fraises", "cerises"]),
            .init(id: "course-parc", target: "Ce week-end je vais courir au parc avec mon chien", intendedIdea: "sport", steerTokens: ["courir", "parc", "chien"]),
            .init(id: "diner-pates", target: "Pour le dîner je pense préparer des pâtes à la tomate", intendedIdea: "repas", steerTokens: ["dîner", "pâtes", "tomate"]),
            .init(id: "rapport", target: "Demain matin je dois envoyer le rapport à mon collègue", intendedIdea: "travail", steerTokens: ["envoyer", "rapport", "collègue"]),
            .init(id: "cafe-the", target: "Je préfère le café le matin et le thé le soir", intendedIdea: "boissons", steerTokens: ["café", "thé", "soir"]),
            .init(id: "courses", target: "Il faudrait acheter du pain, du lait et quelques légumes", intendedIdea: "courses", steerTokens: ["acheter", "pain", "lait"]),
        ]
    }
    func loadPhrases() -> [IntentPhrase] {
        guard let data = FileManager.default.contents(atPath: phrasesPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = root["phrases"] as? [[String: Any]] else {
            err("[mw-intent] phrases.json introuvable/illisible (\(phrasesPath)) → fallback intégré")
            return fallbackPhrases()
        }
        let parsed: [IntentPhrase] = arr.compactMap { o in
            guard let id = o["id"] as? String, let target = o["target"] as? String else { return nil }
            return IntentPhrase(
                id: id, target: target,
                intendedIdea: (o["intended_idea"] as? String) ?? "",
                steerTokens: (o["steer_tokens"] as? [String]) ?? []
            )
        }
        return parsed.isEmpty ? fallbackPhrases() : parsed
    }
    let phrases = loadPhrases()
    err("[mw-intent] phrases: \(phrases.count) (source: \(phrasesPath))")

    // ── Helpers texte / cut / ghost : partagés au file-scope (mw*). ──
    // (Voir mwFold / mwContentWords / mwTargetVocab / mwStemMatch / mwHitTopic /
    //  mwMidWordCuts / mwLongGhost plus haut — réutilisés à l'identique ici.)

    err("\n──────────── Mode INTENTION (mid-word long ghost) ────────────")
    var passingPhrases = 0
    for ph in phrases {
        let cuts = mwMidWordCuts(ph.target)
        // Vocabulaire-cible topic-aware : mots de contenu du target ENTIER + steer_tokens.
        let vocab = mwTargetVocab(target: ph.target, steerTokens: ph.steerTokens)
        var intentionSteps = 0
        var ghosts: [String] = []
        for (ci, cut) in cuts.enumerated() {
            let ghost = await mwLongGhost(beforeCursor: cut.beforeCursor, maxTokens: lgMaxTokens, maxWords: lgMaxWords, stopSet: stopSet, nbest: lgNBest)
            ghosts.append(ghost)

            // Le ghost mid-mot est un FRAGMENT-SUFFIXE qui complète le mot en cours.
            // On juge la CONTINUATION RECOLLÉE (partiel tapé + ghost) pour que le mot
            // complété (« fra » + « ises… » = « fraises ») soit vu par contentWords —
            // sinon le suffixe brut (« ises ») ne matche jamais le vocabulaire-cible.
            let partial = OutputFilter.trailingPartialWord(cut.beforeCursor)
            let gluedGhost = partial + ghost

            // STEP-PASS honnête : lexical (topic) OR sémantique (embedding).
            let j = mwJudgeStep(ghost: ghost, gluedGhost: gluedGhost, vocab: vocab,
                                trueRemainder: cut.trueRemainder, semThresh: semThresh)
            if j.pass { intentionSteps += 1 }

            // INFORMATIONNEL UNIQUEMENT (plus dans la décision) : gNorm/tNorm.
            var gNorm: Double? = nil, tNorm: Double? = nil
            if !ghost.isEmpty,
               let g = await engine.sequenceLogProb(context: cut.beforeCursor, continuation: ghost), g.tokenCount > 0 {
                gNorm = g.sumLogProb / Double(g.tokenCount)
            }
            if !cut.trueRemainder.isEmpty,
               let t = await engine.sequenceLogProb(context: cut.beforeCursor, continuation: cut.trueRemainder), t.tokenCount > 0 {
                tNorm = t.sumLogProb / Double(t.tokenCount)
            }

            let tail = cut.beforeCursor.count > 20 ? String(cut.beforeCursor.suffix(20)) : cut.beforeCursor
            let gStr = gNorm.map { String(format: "%.2f", $0) } ?? "?"
            let tStr = tNorm.map { String(format: "%.2f", $0) } ?? "?"
            let semStr = j.semCos.map { String(format: "%.2f", $0) } ?? "-"
            print("\(pad(ph.id, 14)) cut\(ci)  …\(tail) | ghost=\"\(ghost)\" → \"\(gluedGhost)\" | topic=\(j.topicWord ?? "-") sem=\(semStr) via=\(j.via) g/t=\(gStr)/\(tStr) | \(j.pass ? "STEP-PASS" : "STEP-FAIL")")
        }
        let phrasePass = intentionSteps >= 3
        if phrasePass { passingPhrases += 1 }
        let ghostList = ghosts.map { $0.isEmpty ? "∅" : $0 }.joined(separator: " | ")
        print("\(ph.id): intentionSteps \(intentionSteps)/\(cuts.count) → PHRASE \(phrasePass ? "PASS" : "FAIL")  (ghosts: [\(ghostList)])")
    }

    let total = phrases.count
    let pct = total == 0 ? 0 : passingPhrases * 100 / total
    let harnessPass = total > 0 && Double(passingPhrases) / Double(total) >= 0.50
    let stopDisplay = String(stopSet.subtracting(["\n"]).sorted()) + "\\n"
    print("\nKNOBS: MW_LG_MAXTOKENS=\(lgMaxTokens) MW_LG_MAXWORDS=\(lgMaxWords) MW_LG_NBEST=\(lgNBest) MW_SEM_THRESH=\(semThresh) (emb=\(MWSemEmbedding.shared.path)) stop=[\(stopDisplay)] MW_INTENT_MARGIN=\(intentMargin)")
    print("passing \(passingPhrases)/\(total) = \(pct)% vs 50% bar → HARNESS \(harnessPass ? "PASS" : "FAIL")")
    exit(0)
}

// ── Mode INTENTION RÉELLE (MW_INTENT_REAL=1) : MÊME pipeline ghost-long + MÊME
// juge collé que MW_INTENT, mais sur des phrases ÉCHANTILLONNÉES DANS LE VRAI
// HISTORIQUE DE FRAPPE de l'utilisateur (les ~1489 entrées déjà chargées au boot
// → « history entries: N »). Pour chaque entrée, on RECONSTITUE sa prose avec le
// MÊME join que le corpus n-gram (contextBefore + accepted), on filtre à de la
// prose naturelle (≥6 mots, ≥20 chars, majorité de tokens alphabétiques — drop
// code/URLs/ponctuation), puis on prend jusqu'à MW_REAL_N phrases de façon
// DÉTERMINISTE (un pas régulier pour balayer tout l'historique, AUCUN aléa).
//
// Pas de steer_tokens ici → le vocabulaire-cible = les mots de contenu de la
// phrase réelle elle-même : on teste « le ghost converge-t-il vers ce que
// l'utilisateur a RÉELLEMENT tapé ? ».
//
// PRIVACY : bench dev local, hors `SHIPPING_DIRS` d'`audit.sh` → afficher les
// phrases de l'utilisateur sur stdout est toléré ICI, derrière un en-tête clair.
// On n'écrit JAMAIS ces phrases dans un fichier (rien de commité).
if ProcessInfo.processInfo.environment["MW_INTENT_REAL"] != nil {
    // ── Knobs (mêmes défauts que MW_INTENT) ──
    let lgMaxTokens = max(1, Int(ProcessInfo.processInfo.environment["MW_LG_MAXTOKENS"] ?? "14") ?? 14)
    let lgMaxWords  = max(1, Int(ProcessInfo.processInfo.environment["MW_LG_MAXWORDS"] ?? "4") ?? 4)
    let lgNBest     = max(1, Int(ProcessInfo.processInfo.environment["MW_LG_NBEST"] ?? "1") ?? 1)
    let semThresh   = Double(ProcessInfo.processInfo.environment["MW_SEM_THRESH"] ?? "0.45") ?? 0.45
    let realN       = max(1, Int(ProcessInfo.processInfo.environment["MW_REAL_N"] ?? "15") ?? 15)
    let stopSet: Set<Character> = {
        let raw = ProcessInfo.processInfo.environment["MW_LG_STOP"] ?? ".!?;:"
        var s = Set(raw.split(separator: ",").joined())
        s.formUnion(Set(raw.filter { $0 != "," }))
        s.insert("\n")
        return s
    }()

    // ── Source des phrases : le VRAI historique déjà chargé (`history`). ──
    // Reconstruction = MÊME join que le corpus (cf. engine.setCorpus au boot).
    func reconstruct(_ e: TypingHistoryEntry) -> String {
        e.contextBefore.isEmpty ? e.accepted : e.contextBefore + " " + e.accepted
    }
    // Prose naturelle : ≥20 chars, ≥6 mots, et MAJORITÉ de tokens alphabétiques
    // (drop entrées surtout code/URLs/ponctuation/chiffres).
    //
    // RESSERRAGE : l'historique réel est pollué par les fragments de tests
    // « torture typo » de l'utilisateur — espaces intra-mot et tokens cassés
    // (« conj ugaison », « v ous », « p eux », « choc ol », « personnal isés »).
    // Ces entrées dégénérées font dérailler le token-healing et ne représentent
    // PAS la frappe normale. On veut juger sur de la PROSE PROPRE représentative.
    // On rejette donc EN PLUS toute entrée présentant un artefact d'espace
    // intra-mot ou une majorité de tokens-fragments. Les vraies phrases (« Binance,
    // est une plateforme de trading en », « Il faut que l'image soit intégrable
    // donc transparente ») continuent de passer.
    func looksLikeProse(_ s: String) -> Bool {
        guard s.count >= 20 else { return false }
        let tokens = s.split { $0 == " " || $0 == "\n" || $0 == "\t" }.map(String.init)
        guard tokens.count >= 6 else { return false }
        let alpha = tokens.filter { tok in
            let letters = tok.filter { $0.isLetter }.count
            return letters >= 2 && letters * 2 >= tok.count   // majorité alphabétique, ≥2 lettres
        }.count
        guard alpha * 2 > tokens.count else { return false }

        // (4) Lit comme une phrase : commence par une lettre.
        guard let first = s.first(where: { !$0.isWhitespace }), first.isLetter else { return false }

        // Seuls vrais mots français d'UNE lettre (accent-folded : « à » → « a »).
        // Tout autre token d'une seule lettre entouré d'espaces = artefact de
        // découpe mid-mot (« v ous » → token « v », « p eux » → « p »).
        func isLegit1Letter(_ tok: String) -> Bool {
            let f = tok.folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR")).lowercased()
            return f == "a" || f == "y"
        }
        // Tokens purement alphabétiques d'UNE lettre (hors a/y/à).
        let stray1 = tokens.filter { tok in
            let letters = tok.filter { $0.isLetter }
            return letters.count == 1 && letters.count == tok.count && !isLegit1Letter(tok)
        }
        // (1) Un token isolé d'une lettre non-{a,y,à} = artefact mid-mot → rejet.
        // (2) De même ≥2 tokens d'une lettre (hors a/y/à), ou une consonne isolée.
        if !stray1.isEmpty { return false }

        // (3) ≥70% des tokens alphabétiques doivent faire ≥3 chars : sous ce seuil
        // l'entrée est faite de fragments/charabia (« choc ol » → « choc », « ol »).
        let alphaTokens = tokens.filter { tok in
            let letters = tok.filter { $0.isLetter }.count
            return letters >= 2 && letters * 2 >= tok.count
        }
        guard !alphaTokens.isEmpty else { return false }
        let long = alphaTokens.filter { tok in
            tok.filter { $0.isLetter }.count >= 3
        }.count
        guard Double(long) >= 0.70 * Double(alphaTokens.count) else { return false }

        // (4) ≥6 mots alphabétiques (vrais mots, pas juste 6 tokens).
        guard alphaTokens.count >= 6 else { return false }

        return true
    }

    let candidates: [String] = history.map(reconstruct).filter(looksLikeProse)
    // Sélection DÉTERMINISTE : un pas régulier pour balayer tout l'historique
    // (pas d'aléa — Date/random indisponibles). Si moins de candidats que N,
    // on prend tout dans l'ordre.
    let phrases: [String]
    if candidates.count <= realN {
        phrases = candidates
    } else {
        let step = candidates.count / realN
        var picked: [String] = []
        var idx = 0
        while picked.count < realN && idx < candidates.count {
            picked.append(candidates[idx]); idx += step
        }
        phrases = picked
    }

    print("\n──────────── Mode INTENTION RÉELLE (mid-word long ghost sur HISTORIQUE) ────────────")
    print("⚠️  PRIVACY : les phrases ci-dessous sont la PROSE RÉELLE de l'utilisateur (historique local).")
    print("history entries: \(history.count) · candidats prose: \(candidates.count) · échantillon: \(phrases.count) (MW_REAL_N=\(realN))\n")

    var passingPhrases = 0
    for (pi, target) in phrases.enumerated() {
        let id = "real\(pi)"
        let cuts = mwMidWordCuts(target)
        // Pas de steer_tokens : le vocabulaire-cible = mots de contenu de la phrase réelle.
        let vocab = mwTargetVocab(target: target, steerTokens: [])
        var intentionSteps = 0
        var ghosts: [String] = []
        let preview = target.count > 60 ? String(target.prefix(60)) + "…" : target
        print("\(id): «\(preview)»")
        for (ci, cut) in cuts.enumerated() {
            let ghost = await mwLongGhost(beforeCursor: cut.beforeCursor, maxTokens: lgMaxTokens, maxWords: lgMaxWords, stopSet: stopSet, nbest: lgNBest)
            ghosts.append(ghost)

            // MÊME juge partagé que MW_INTENT : lexical (topic) OR sémantique.
            let partial = OutputFilter.trailingPartialWord(cut.beforeCursor)
            let gluedGhost = partial + ghost
            let j = mwJudgeStep(ghost: ghost, gluedGhost: gluedGhost, vocab: vocab,
                                trueRemainder: cut.trueRemainder, semThresh: semThresh)
            if j.pass { intentionSteps += 1 }

            let tail = cut.beforeCursor.count > 20 ? String(cut.beforeCursor.suffix(20)) : cut.beforeCursor
            let semStr = j.semCos.map { String(format: "%.2f", $0) } ?? "-"
            print("\(pad(id, 14)) cut\(ci)  …\(tail) | ghost=\"\(ghost)\" → \"\(gluedGhost)\" | topic=\(j.topicWord ?? "-") sem=\(semStr) via=\(j.via) | \(j.pass ? "STEP-PASS" : "STEP-FAIL")")
        }
        let phrasePass = intentionSteps >= 3
        if phrasePass { passingPhrases += 1 }
        let ghostList = ghosts.map { $0.isEmpty ? "∅" : $0 }.joined(separator: " | ")
        print("\(id): intentionSteps \(intentionSteps)/\(cuts.count) → PHRASE \(phrasePass ? "PASS" : "FAIL")  (ghosts: [\(ghostList)])")
    }

    let total = phrases.count
    let pct = total == 0 ? 0 : passingPhrases * 100 / total
    let harnessPass = total > 0 && Double(passingPhrases) / Double(total) >= 0.50
    let stopDisplay = String(stopSet.subtracting(["\n"]).sorted()) + "\\n"
    print("\nKNOBS: MW_LG_MAXTOKENS=\(lgMaxTokens) MW_LG_MAXWORDS=\(lgMaxWords) MW_LG_NBEST=\(lgNBest) MW_SEM_THRESH=\(semThresh) (emb=\(MWSemEmbedding.shared.path)) MW_REAL_N=\(realN) stop=[\(stopDisplay)]")
    print("passing \(passingPhrases)/\(total) = \(pct)% vs 50% bar → HARNESS \(harnessPass ? "PASS" : "FAIL")")
    exit(0)
}

if !escalateMode {
err("\n──────────── Mid-word layer eval (\(cases.count) cases) ────────────")
var l0Hits = 0, l1Hits = 0, pickL0 = 0, pickL1 = 0, pickNone = 0
var branchStats: [CaseBranchStat] = []

for c in cases {
    let l0 = wordCompleter.completion(for: c.prefix)
    let l1 = SuggestionPolicy.strongCorpusMatch(userTail: c.prefix, snapshot: history)?.continuation
    let (l2, l2ms, l2p1) = await runLLM(prefix: c.prefix, engine: engine)
    let prefix = c.prefix
    let pick: (source: String, text: String)? = await MainActor.run {
        guard let g = policy.routeInstant(
            userTail: prefix, historySnapshot: history, wordCompleter: wordCompleter
        ) else { return nil }
        let src: String
        switch g.source {
        case .wordComplete: src = "L0"
        case .history:      src = "L1"
        default:            src = "\(g.source)"
        }
        return (src, g.text)
    }

    if l0 != nil { l0Hits += 1 }
    if l1 != nil { l1Hits += 1 }
    switch pick?.source {
    case .some("L0"): pickL0 += 1
    case .some("L1"): pickL1 += 1
    default: pickNone += 1
    }

    let pickStr: String
    switch pick?.source {
    case .some(let s): pickStr = "\(s):\(show(pick?.text))"
    case .none:        pickStr = "∅ (→ L2 LLM fills)"
    }

    print("""

    ### \(c.label)  —  "\(c.prefix)"   (attendu: \(c.expected))
      L0 word-complete : \(show(l0))
      L1 corpus-recall : \(show(l1))
      L2 LLM healed    : \(show(l2))   [\(l2ms)ms]
      → PROD MONTRE    : \(pickStr)
    """)

    // Branches : k tirages stochastiques (même prompt healed, seeds distincts).
    let leads = await runLLMBranches(prefix: c.prefix, engine: engine, k: branchK, temp: branchTemp)
    let (modal, modalCount, agreement) = agreementStats(leads)
    let correct = judgeBranch(prefix: c.prefix, expected: c.expected, modal: modal)
    branchStats.append(CaseBranchStat(label: c.label, agreement: agreement, p1: l2p1, modal: modal, correct: correct))
    let leadList = leads.map { $0.isEmpty ? "∅" : $0 }.joined(separator: " · ")
    let p1Str = l2p1.map { String(format: "%.2f", $0) } ?? "?"
    let verdict = correct == nil ? "➖ ambigu" : (correct! ? "✅ accord = bon mot" : "❌ accord ≠ attendu")
    print("""
      branches (k=\(branchK), T=\(branchTemp)): \(leadList)
      → modal "\(modal.isEmpty ? "∅" : modal)" ×\(modalCount)/\(branchK)   agreement=\(String(format: "%.2f", agreement))   P1(greedy top-1)=\(p1Str)   \(verdict)
    """)
}

err("""

──────────── Summary ────────────
cases:                 \(cases.count)
L0 produced a result:  \(l0Hits)/\(cases.count)
L1 produced a result:  \(l1Hits)/\(cases.count)
PROD pick = L0:        \(pickL0)
PROD pick = L1:        \(pickL1)
PROD pick = none(→L2): \(pickNone)

Reading:
  PROD pick column is what the user actually SEES mid-word. If most picks are
  L0 and L0 is wrong/jumpy, that — not the LLM, not OCR — is the felt "generic".
  If most picks are 'none(→L2)', the mid-word LLM healed quality (L2 column)
  is what matters and should be judged against `expected`.
""")

// ── Branch divergence : pouvoir discriminant (le résultat du spike) ────────
let judged = branchStats.filter { $0.correct != nil }
let hi = judged.filter { $0.agreement >= 0.6 }
let lo = judged.filter { $0.agreement < 0.6 }
let hiC = hi.filter { $0.correct == true }.count
let loC = lo.filter { $0.correct == true }.count
func meanD(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
let p1ok = meanD(judged.filter { $0.correct == true }.compactMap { $0.p1 })
let p1ko = meanD(judged.filter { $0.correct == false }.compactMap { $0.p1 })

var table = "\n──────────── Branch divergence : pouvoir discriminant ────────────\n"
table += "\(pad("case", 20))  agree   P1    modal\n"
for s in branchStats {
    let mark = s.correct == nil ? "➖" : (s.correct! ? "✅" : "❌")
    let p1s = s.p1.map { String(format: "%.2f", $0) } ?? " ?  "
    table += "\(pad(s.label, 20))  \(String(format: "%.2f", s.agreement))  \(p1s)   \(mark) \(s.modal.isEmpty ? "∅" : s.modal)\n"
}
table += """

Discrimination (cas non-ambigus : \(judged.count)) :
  agreement ≥ 0.60 : \(hi.count) cas, \(hiC) bons (\(hi.isEmpty ? 0 : hiC * 100 / hi.count)%)
  agreement < 0.60 : \(lo.count) cas, \(loC) bons (\(lo.isEmpty ? 0 : loC * 100 / lo.count)%)
  P1(bons)         = \(String(format: "%.2f", p1ok))
  P1(mauvais)      = \(String(format: "%.2f", p1ko))

Lecture :
  Si « agreement ≥ 0.60 » est très majoritairement bon ET « < 0.60 » majoritairement
  mauvais → la DIVERGENCE inter-branches discrimine (l'hypothèse Frame C tient).
  Si P1(bons) ≫ P1(mauvais) → la confiance top-1 greedy discrimine aussi (gate moins cher).
  Le meilleur des deux — ou les deux combinés — devient le score du gate mid-mot.
"""
err(table)
}  // if !escalateMode

// ── Escalation prototype : greedy+dico → branches seulement si incertain ──
if escalateMode {
    let fastP1 = Double(ProcessInfo.processInfo.environment["MW_FAST_P1"] ?? "0.85") ?? 0.85
    let minFastLen = Int(ProcessInfo.processInfo.environment["MW_FAST_LEN"] ?? "4") ?? 4
    let escK = max(1, Int(ProcessInfo.processInfo.environment["MW_ESC_K"] ?? "3") ?? 3)
    let escTemp = Float(ProcessInfo.processInfo.environment["MW_ESC_TEMP"] ?? "0.7") ?? 0.7
    let agreeThresh = Double(ProcessInfo.processInfo.environment["MW_AGREE"] ?? "0.6") ?? 0.6
    err("\n──────────── Escalation prototype (fastP1=\(fastP1) minLen=\(minFastLen) k≤\(escK) agree≥\(agreeThresh)) ────────────")

    var results: [(MWCase, EscResult)] = []
    for c in cases {
        let r = await escalate(c: c, engine: engine, fastP1: fastP1, minFastLen: minFastLen,
                               k: escK, temp: escTemp, agreeThresh: agreeThresh)
        results.append((c, r))
    }

    var tbl = "\n\(pad("case", 16)) \(pad("stage", 12)) show  br  ms     verdict word\n"
    var totBranches = 0
    var totMs = 0.0
    var fastA = 0, fastR = 0, branched = 0
    for (c, r) in results {
        totBranches += r.branches; totMs += r.ms
        switch r.stage {
        case "FAST-ACCEPT": fastA += 1
        case "FAST-REJECT": fastR += 1
        default: branched += 1
        }
        let mark = r.correct == nil ? "➖" : (r.correct! ? "✅" : "❌")
        tbl += "\(pad(c.label, 16)) \(pad(r.stage, 12)) \(pad(r.shown ? "SHOW" : "hide", 4))  \(r.branches)   \(pad(String(format: "%.0f", r.ms), 5))  \(mark)      \(r.word.isEmpty ? "∅" : r.word)\n"
    }
    err(tbl)

    let n = results.count
    let shows = results.filter { $0.1.shown }
    let goodShow = shows.filter { $0.1.correct == true }.count
    let badShow = shows.filter { $0.1.correct == false }.count
    // Un « hide » est CORRECT s'il cache un garbage (correct==false) ou un ambigu/
    // nom propre (correct==nil) — c.-à-d. tout sauf un bon qu'on aurait raté.
    let hides = results.filter { !$0.1.shown }
    let missedGood = hides.filter { $0.1.correct == true }.count
    let allBranchCost = n * escK
    let saved = allBranchCost == 0 ? 0 : (100 - totBranches * 100 / allBranchCost)
    err("""
    ── Coût & qualité ──
    cases:                 \(n)
    FAST-ACCEPT (0 br)  :  \(fastA)
    FAST-REJECT (0 br)  :  \(fastR)
    BRANCHED            :  \(branched)
    appels-branche tot. :  \(totBranches)   (vs \(allBranchCost) si on branchait tout → −\(saved)%)
    temps total         :  \(String(format: "%.0f", totMs)) ms   (moy \(String(format: "%.0f", totMs / Double(n))) ms/cas)
    ── décisions ──
    montrés             :  \(shows.count)   dont \(goodShow) bons, \(badShow) garbage
    cachés              :  \(hides.count)   dont \(missedGood) bons ratés (idéalement → fallback L0 dico)

    Lecture : un bon gate maximise « bons montrés », garde « garbage montré » à 0,
    et minimise les branches (coût). Les « bons ratés » sont les mots que le LLM
    fumble (pingouin/aspirateur…) → c'est le fallback WordCompleter L0 qui les couvre.
    """)
}
