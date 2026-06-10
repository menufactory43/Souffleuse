import AppKit
import Foundation
import SouffleuseTyping

// ════════════════════════════════════════════════════════════════════════════
// SPELL ENGINE EVAL — NSSpellChecker (chemin actuel) vs SymSpell (fréquences).
//
// Question : remplacer/compléter NSSpellChecker par un moteur SymSpell
// améliorerait-il la correction de coquilles ? On compare, sur un corpus de
// coquilles main (FR/EN réalistes) + synthétiques (corruptions AZERTY-aware
// de mots fréquents, vérité terrain = le mot source) :
//
//   1. TypoDetector (politique ACTUELLE complète : accord FR+EN, bail ambiguïté)
//   2. NSSpellChecker « brut » (sans la politique : corrige dès qu'UNE langue
//      rejette) — isole moteur vs politique
//   3. SymSpell brut (top candidat distance puis fréquence)
//   4. SymSpell conservateur (bail analogue au nôtre : top-2 à même distance
//      et fréquences proches → abstention)
//
// Métriques : exactitude totale (abstention = raté), précision quand le moteur
// tire, taux d'abstention, latence par lookup. Ventilation par type d'erreur.
// ════════════════════════════════════════════════════════════════════════════

// MARK: - Corpus

struct EvalCase {
    let typo: String
    let expected: String
    let origin: String   // "main-fr" | "main-en" | nom de l'op synthétique
    let french: Bool

    /// Phrase porteuse réaliste : la politique actuelle lit la LANGUE DU
    /// CONTEXTE (exception diacritiques) — tester le mot nu la priverait du
    /// signal qu'elle a en prod, où le préfixe complet du champ est passé.
    var carrierText: String {
        (french ? "je crois que c'est vraiment " : "i think that it is really ") + typo + " "
    }
}

/// Coquilles RÉALISTES main — fautes de frappe et d'accent typiques.
/// L'attendu doit être non-ambigu hors contexte (pas d'« achete » →
/// achète/acheté). Tout en minuscules, pas de composés ni d'apostrophes
/// (hors périmètre des 4 moteurs comparés).
let handFR: [(String, String)] = [
    ("sius", "suis"), ("bonjoir", "bonjour"), ("bonjuor", "bonjour"),
    ("mesage", "message"), ("messsage", "message"), ("travial", "travail"),
    ("journee", "journée"), ("jorunée", "journée"), ("apelle", "appelle"),
    ("demian", "demain"), ("tojours", "toujours"), ("beacoup", "beaucoup"),
    ("beaucop", "beaucoup"), ("pouquoi", "pourquoi"), ("pourqoi", "pourquoi"),
    ("qaund", "quand"), ("qunad", "quand"), ("commetn", "comment"),
    ("commnet", "comment"), ("ecole", "école"), ("etait", "était"),
    ("etre", "être"), ("meme", "même"), ("tres", "très"),
    ("apres", "après"), ("francais", "français"), ("plutot", "plutôt"),
    ("bientot", "bientôt"), ("vraimen", "vraiment"), ("vraimnet", "vraiment"),
    ("mainteant", "maintenant"), ("maintenat", "maintenant"),
    ("probleme", "problème"), ("problme", "problème"), ("reponse", "réponse"),
    ("repondre", "répondre"), ("telephone", "téléphone"),
    ("interessant", "intéressant"), ("dificile", "difficile"),
    ("necessaire", "nécessaire"), ("derniere", "dernière"),
    ("premiere", "première"), ("fenetre", "fenêtre"), ("hopital", "hôpital"),
    ("hotel", "hôtel"), ("tete", "tête"), ("recu", "reçu"),
    ("francaise", "française"), ("garcon", "garçon"), ("lecon", "leçon"),
    ("ecrire", "écrire"), ("repondu", "répondu"), ("evidemment", "évidemment"),
    ("absolumen", "absolument"), ("oragniser", "organiser"),
    ("organsier", "organiser"), ("reunion", "réunion"), ("reunoin", "réunion"),
    ("semaien", "semaine"), ("posible", "possible"), ("possibel", "possible"),
    ("imposible", "impossible"), ("egalement", "également"),
    ("deja", "déjà"), ("voila", "voilà"),
]

let handEN: [(String, String)] = [
    ("wnat", "want"), ("teh", "the"), ("recieve", "receive"),
    ("seperate", "separate"), ("definately", "definitely"),
    ("occured", "occurred"), ("untill", "until"), ("wich", "which"),
    ("becuase", "because"), ("beleive", "believe"), ("freind", "friend"),
    ("thier", "their"), ("adress", "address"), ("tommorow", "tomorrow"),
    ("wierd", "weird"), ("accomodate", "accommodate"),
    ("embarass", "embarrass"), ("existance", "existence"),
    ("enviroment", "environment"), ("goverment", "government"),
    ("calender", "calendar"), ("collegue", "colleague"),
    ("immediatly", "immediately"), ("neccessary", "necessary"),
    ("occassion", "occasion"), ("recomend", "recommend"),
    ("succesful", "successful"),
]

// MARK: - Générateur synthétique (seedé, reproductible)

/// SplitMix64 — RNG déterministe pour que deux runs comparent le même corpus.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

/// Voisin horizontal AZERTY — la substitution de frappe la plus réaliste sur
/// nos claviers (doigt qui rate d'une touche).
let azertyRows = ["azertyuiop", "qsdfghjklm", "wxcvbn"]
func azertyNeighbor(of c: Character, rng: inout SplitMix64) -> Character? {
    for row in azertyRows {
        let chars = Array(row)
        guard let i = chars.firstIndex(of: c) else { continue }
        var options: [Character] = []
        if i > 0 { options.append(chars[i - 1]) }
        if i < chars.count - 1 { options.append(chars[i + 1]) }
        return options.randomElement(using: &rng)
    }
    return nil
}

let accentMap: [Character: Character] = [
    "é": "e", "è": "e", "ê": "e", "ë": "e", "à": "a", "â": "a",
    "ù": "u", "û": "u", "ô": "o", "î": "i", "ï": "i", "ç": "c",
]

enum CorruptionOp: String, CaseIterable {
    case transpose, delete, double, azerty, accent
}

/// Applique UNE corruption (distance 1) à `word`. Nil si l'op ne s'applique pas.
func corrupt(_ word: String, op: CorruptionOp, rng: inout SplitMix64) -> String? {
    var chars = Array(word)
    switch op {
    case .transpose:
        let positions = (0..<chars.count - 1).filter { chars[$0] != chars[$0 + 1] }
        guard let i = positions.randomElement(using: &rng) else { return nil }
        chars.swapAt(i, i + 1)
    case .delete:
        guard chars.count >= 4 else { return nil }
        chars.remove(at: Int.random(in: 0..<chars.count, using: &rng))
    case .double:
        let i = Int.random(in: 0..<chars.count, using: &rng)
        chars.insert(chars[i], at: i)
    case .azerty:
        let positions = (0..<chars.count).filter { azertyNeighbor(of: chars[$0], rng: &rng) != nil }
        guard let i = positions.randomElement(using: &rng),
              let sub = azertyNeighbor(of: chars[i], rng: &rng) else { return nil }
        chars[i] = sub
    case .accent:
        let positions = (0..<chars.count).filter { accentMap[chars[$0]] != nil }
        guard let i = positions.randomElement(using: &rng) else { return nil }
        chars[i] = accentMap[chars[i]]!
    }
    let out = String(chars)
    return out == word ? nil : out
}

// MARK: - Chargement des dictionnaires de fréquences

let freqDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()        // SouffleuseSpellEngineEval
    .deletingLastPathComponent()        // Sources
    .deletingLastPathComponent()        // Souffleuse
    .appendingPathComponent("vendor/freq")

func loadFrequencies(_ name: String) -> [(word: String, count: Int)] {
    guard let text = try? String(contentsOf: freqDir.appendingPathComponent(name), encoding: .utf8) else {
        FileHandle.standardError.write("DICTIONNAIRE MANQUANT: \(name) dans \(freqDir.path)\n".data(using: .utf8)!)
        exit(1)
    }
    return text.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: " ")
        guard parts.count == 2, let c = Int(parts[1]) else { return nil }
        return (String(parts[0]), c)
    }
}

let frFreq = loadFrequencies("fr_50k.txt")
let enFreq = loadFrequencies("en_50k.txt")

// ── Nettoyage du dico FR ────────────────────────────────────────────────────
// OpenSubtitles est SALE : les formes désaccentuées (« etre », « ecole »,
// « journee ») y figurent comme mots — bruit de sous-titrage. Un SymSpell
// naïf les voit alors à distance 0 et refuse de corriger l'erreur d'accent,
// LA classe de coquilles n°1 en français. Règle : un mot SANS accent dont la
// forme accentuée existe avec une fréquence SUPÉRIEURE est du bruit → retiré.
// Longueur ≥ 4 pour protéger les vrais homographes courts (a/à, ou/où, la/là) ;
// le sens de la fréquence protège les vrais homographes longs (mais ≫ maïs).
func stripAccents(_ s: String) -> String {
    String(s.map { accentMap[$0] ?? $0 })
}

func cleanedFrenchTable(_ freq: [(word: String, count: Int)]) -> [String: Int] {
    var table = Dictionary(freq.map { ($0.word, $0.count) }, uniquingKeysWith: max)
    for (word, count) in table where word.contains(where: { accentMap[$0] != nil }) {
        let stripped = stripAccents(word)
        guard stripped.count >= 4, stripped != word,
              let strippedCount = table[stripped], strippedCount < count else { continue }
        table[stripped] = nil
    }
    return table
}

let frClean = cleanedFrenchTable(frFreq)
let enTable = Dictionary(enFreq.map { ($0.word, $0.count) }, uniquingKeysWith: max)
// Le filtre real-word du corpus synthétique utilise le dico NETTOYÉ : une
// forme désaccentuée n'est pas un vrai mot, elle doit rester dans le corpus.
let knownWords: Set<String> = Set(frClean.keys).union(enTable.keys)

// MARK: - Construction du corpus

var rng = SplitMix64(seed: 42)
var cases: [EvalCase] = handFR.map { EvalCase(typo: $0.0, expected: $0.1, origin: "main-fr", french: true) }
    + handEN.map { EvalCase(typo: $0.0, expected: $0.1, origin: "main-en", french: false) }

/// Mots sources synthétiques : fréquents, ≥ 5 lettres, purement alphabétiques.
/// ≥ 5 (et pas 4) parce qu'à 4 lettres une corruption d1 a souvent PLUSIEURS
/// corrections valides à d1 — la « vérité terrain » n'en serait pas une.
func syntheticPool(_ freq: [(word: String, count: Int)], top: Int) -> [String] {
    Array(freq.prefix(top).map(\.word).filter { w in
        w.count >= 5 && w.allSatisfy(\.isLetter)
    })
}

let frPool = syntheticPool(frFreq, top: 4000)
let enPool = syntheticPool(enFreq, top: 3000)

func generateSynthetic(pool: [String], count: Int, french: Bool, rng: inout SplitMix64) -> [EvalCase] {
    var out: [EvalCase] = []
    var seen = Set<String>()
    var attempts = 0
    while out.count < count && attempts < count * 30 {
        attempts += 1
        guard let word = pool.randomElement(using: &rng) else { break }
        guard let op = CorruptionOp.allCases.randomElement(using: &rng),
              let typo = corrupt(word, op: op, rng: &rng) else { continue }
        // Une corruption qui EST un mot connu = erreur real-word, indétectable
        // par les 4 moteurs (hors périmètre). Dédup sur la paire typo/attendu.
        guard !knownWords.contains(typo), typo.count >= 3, seen.insert(typo + "→" + word).inserted else { continue }
        out.append(EvalCase(typo: typo, expected: word, origin: op.rawValue, french: french))
    }
    return out
}

cases += generateSynthetic(pool: frPool, count: 600, french: true, rng: &rng)
cases += generateSynthetic(pool: enPool, count: 200, french: false, rng: &rng)

print("Corpus : \(cases.count) coquilles (\(handFR.count) main-fr, \(handEN.count) main-en, \(cases.count - handFR.count - handEN.count) synthétiques)")

// MARK: - Moteurs comparés

protocol SpellEngine {
    var name: String { get }
    /// Nil = abstention (le moteur ne corrige pas).
    func correct(_ c: EvalCase) -> String?
}

/// 1. Le chemin de PROD actuel : TypoDetector, politique complète (accord
/// FR+EN avec exception diacritiques, plancher d'abstention inter-langues,
/// bail sur ambiguïté). Testé avec la phrase porteuse — comme en prod.
struct CurrentPolicyEngine: SpellEngine {
    let name = "TypoDetector (politique actuelle)"
    let detector = TypoDetector()
    func correct(_ c: EvalCase) -> String? {
        let text = c.carrierText
        return detector.checkLastWord(in: text, caretIndex: text.count)?.suggestion
    }
}

/// 2. NSSpellChecker SANS notre politique : dès qu'UNE langue rejette le mot,
/// on prend les guesses des langues qui rejettent et on garde le plus proche
/// (OSA). Isole « le moteur rate » de « la politique s'abstient ».
struct RawNSSpellEngine: SpellEngine {
    let name = "NSSpellChecker brut (sans politique)"
    let checker = NSSpellChecker.shared
    func correct(_ c: EvalCase) -> String? {
        let typo = c.typo
        let nsword = typo as NSString
        var candidates: [String] = []
        for lang in ["fr", "en"] {
            let range = checker.checkSpelling(
                of: typo, startingAt: 0, language: lang, wrap: false,
                inSpellDocumentWithTag: 0, wordCount: nil)
            guard range.location != NSNotFound, range.length == nsword.length else { continue }
            candidates += checker.guesses(
                forWordRange: NSRange(location: 0, length: nsword.length),
                in: typo, language: lang, inSpellDocumentWithTag: 0) ?? []
        }
        let typoChars = Array(typo)
        return candidates
            .map { ($0, MiniSymSpell.damerauOSA(typoChars, Array($0.lowercased()), cap: 2)) }
            .filter { $0.1 <= 2 }
            .min { $0.1 < $1.1 }?.0
    }
}

/// 3. SymSpell brut : top candidat (distance puis fréquence). Distance 0 en
/// tête = le mot existe → pas une coquille → abstention.
struct SymSpellRawEngine: SpellEngine {
    let name = "SymSpell brut (dist puis fréq)"
    let sym: MiniSymSpell
    func correct(_ c: EvalCase) -> String? {
        let hits = sym.lookup(c.typo)
        guard let top = hits.first, top.distance > 0 else { return nil }
        return top.term
    }
}

/// 4. SymSpell conservateur : même lookup, mais abstention quand les deux
/// premiers candidats sont à la MÊME distance avec des fréquences proches
/// (< 2×) — l'analogue de notre bail d'ambiguïté actuel.
struct SymSpellConservativeEngine: SpellEngine {
    let name = "SymSpell conservateur (bail ambigu)"
    let sym: MiniSymSpell
    func correct(_ c: EvalCase) -> String? {
        let hits = sym.lookup(c.typo)
        guard let top = hits.first, top.distance > 0 else { return nil }
        if hits.count > 1, hits[1].distance == top.distance,
           top.frequency < hits[1].frequency * 2 {
            return nil
        }
        return top.term
    }
}

FileHandle.standardError.write("Indexation SymSpell (FR+EN, 100k mots)…\n".data(using: .utf8)!)
let sym = MiniSymSpell()
try sym.load(dictionaryAt: freqDir.appendingPathComponent("fr_50k.txt"))
try sym.load(dictionaryAt: freqDir.appendingPathComponent("en_50k.txt"))
let buildTime = ContinuousClock().measure { sym.build() }
FileHandle.standardError.write("Index brut construit en \(buildTime)\n".data(using: .utf8)!)

// 5ᵉ moteur : même algo, dico FR nettoyé — mesure ce que vaudrait SymSpell
// avec un lexique de QUALITÉ (l'investissement réel d'une adoption).
let symClean = MiniSymSpell()
symClean.load(frequencyTable: frClean)
symClean.load(frequencyTable: enTable)
let cleanBuildTime = ContinuousClock().measure { symClean.build() }
FileHandle.standardError.write("Index nettoyé construit en \(cleanBuildTime)\n".data(using: .utf8)!)

struct SymSpellCleanEngine: SpellEngine {
    let name = "SymSpell dico FR nettoyé"
    let sym: MiniSymSpell
    func correct(_ c: EvalCase) -> String? {
        let hits = sym.lookup(c.typo)
        guard let top = hits.first, top.distance > 0 else { return nil }
        return top.term
    }
}

let engines: [any SpellEngine] = [
    CurrentPolicyEngine(),
    RawNSSpellEngine(),
    SymSpellRawEngine(sym: sym),
    SymSpellConservativeEngine(sym: sym),
    SymSpellCleanEngine(sym: symClean),
]

// MARK: - Run + métriques

struct EngineStats {
    var fires = 0
    var correct = 0
    var totalNanos: Int64 = 0
    var missExamples: [(typo: String, expected: String, got: String?)] = []
    var byOrigin: [String: (correct: Int, total: Int)] = [:]
}

let clock = ContinuousClock()
var allStats: [(name: String, stats: EngineStats)] = []

for engine in engines {
    var stats = EngineStats()
    for c in cases {
        var got: String?
        let dt = clock.measure { got = engine.correct(c) }
        stats.totalNanos += Int64(dt.components.attoseconds / 1_000_000_000)
        if got != nil { stats.fires += 1 }
        let ok = got?.lowercased() == c.expected.lowercased()
        if ok { stats.correct += 1 }
        var bucket = stats.byOrigin[c.origin] ?? (0, 0)
        bucket.total += 1
        if ok { bucket.correct += 1 }
        stats.byOrigin[c.origin] = bucket
        if !ok && stats.missExamples.count < 12 && c.origin.hasPrefix("main") {
            stats.missExamples.append((c.typo, c.expected, got))
        }
    }
    allStats.append((engine.name, stats))
}

// MARK: - Rapport

/// `String(format: "%s")` segfaulte avec des String Swift — padding manuel.
func pad(_ s: String, _ width: Int, right: Bool = false) -> String {
    let fill = String(repeating: " ", count: max(0, width - s.count))
    return right ? fill + s : s + fill
}

let total = cases.count
print("\n" + String(repeating: "═", count: 100))
print("RÉSULTATS — \(total) coquilles")
print(String(repeating: "═", count: 100))
print(pad("MOTEUR", 38) + pad("tire", 7, right: true) + pad("correct", 9, right: true)
    + pad("acc%", 8, right: true) + pad("préc%", 8, right: true)
    + pad("abstient", 10, right: true) + pad("µs/lookup", 11, right: true))
for (name, s) in allStats {
    let acc = 100.0 * Double(s.correct) / Double(total)
    let prec = s.fires > 0 ? 100.0 * Double(s.correct) / Double(s.fires) : 0
    let abstain = total - s.fires
    let micros = Double(s.totalNanos) / Double(total) / 1000.0
    print(pad(name, 38) + pad("\(s.fires)", 7, right: true) + pad("\(s.correct)", 9, right: true)
        + pad(String(format: "%.1f%%", acc), 8, right: true)
        + pad(String(format: "%.1f%%", prec), 8, right: true)
        + pad("\(abstain)", 10, right: true)
        + pad(String(format: "%.1f", micros), 11, right: true))
}

print("\n" + String(repeating: "─", count: 100))
print("VENTILATION exactitude par type d'erreur (correct/total)")
print(String(repeating: "─", count: 100))
let origins = ["main-fr", "main-en", "transpose", "delete", "double", "azerty", "accent"]
print(pad("MOTEUR", 38) + origins.map { pad($0, 10, right: true) }.joined())
for (name, s) in allStats {
    var row = pad(name, 38)
    for o in origins {
        let b = s.byOrigin[o] ?? (0, 0)
        row += pad(b.total > 0 ? "\(b.correct)/\(b.total)" : "—", 10, right: true)
    }
    print(row)
}

print("\n" + String(repeating: "─", count: 100))
print("EXEMPLES de ratés sur le corpus MAIN (12 max par moteur)")
print(String(repeating: "─", count: 100))
for (name, s) in allStats {
    guard !s.missExamples.isEmpty else { continue }
    print("\n\(name) :")
    for m in s.missExamples {
        print("   \(m.typo) → attendu « \(m.expected) », obtenu \(m.got.map { "« \($0) »" } ?? "(abstention)")")
    }
}
print("\n" + String(repeating: "═", count: 100))
