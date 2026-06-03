import Foundation

/// Lexique personnel des termes **distinctifs** que l'utilisateur a tapés —
/// noms propres, marques, jargon (« Binance », « Fiscalio », un nom de client)
/// que le base model ignore et que le dictionnaire système ne connaît pas.
///
/// C'est le pendant on-device du « lexique personnel » des claviers (SwiftKey
/// fait tourner un moteur n-gram personnalisé EN PARALLÈLE du neuronal ; Gboard
/// augmente son LM par des n-gram d'historique). Le LLM gère la fluidité ; ce
/// lexique gère « tes mots » — mesuré sur l'historique réel : « Bin » → Binance,
/// 90 % de précision (préfixe capitalisé + freq≥2 + dominance≥0.5).
///
/// **Distinctif** = mot MAJORITAIREMENT capitalisé en MILIEU de phrase (≥50 %
/// des occurrences) → écarte les mots courants (capitalisés seulement en tête de
/// phrase, « Bonjour », « Merci ») sans dépendre d'un dictionnaire externe
/// (NSSpellChecker bloque en CLI ; ce signal est autonome). Construit hors du
/// thread principal sur un snapshot d'historique, puis interrogé en lecture
/// seule (immuable → `Sendable` sans synchro).
public struct LearnedLexicon: Sendable {
    /// `clé minuscule → (forme canonique affichée, fréquence)` pour les seuls
    /// mots distinctifs. Petit (quelques dizaines d'entrées sur un historique
    /// réel), scan linéaire par préfixe — pas d'index nécessaire.
    private let entries: [String: (canonical: String, freq: Int)]

    public init() { self.entries = [:] }
    private init(entries: [String: (canonical: String, freq: Int)]) { self.entries = entries }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    /// Termes appris (forme canonique + fréquence), du plus fréquent au moins —
    /// pour l'inspection / les evals. Ne traverse aucune frontière sensible.
    public var terms: [(term: String, freq: Int)] {
        entries.values.map { ($0.canonical, $0.freq) }.sorted { $0.freq > $1.freq }
    }

    // MARK: - Seuils (calibrés sur l'historique réel, variante « +Majuscule »)

    /// Fréquence minimale pour qu'un terme soit proposable (un one-shot est du
    /// bruit). `2` → 90 % de précision mesurée ; `1` → 81 % (plus réactif).
    public static let defaultMinFreq = 2
    /// Part minimale du terme parmi les candidats distinctifs partageant le
    /// préfixe (dominance) — évite d'imposer un terme quand le préfixe est
    /// ambigu entre plusieurs mots appris.
    public static let defaultMinShare: Float = 0.5
    /// Longueur de préfixe minimale avant de proposer (« Bin », pas « B »).
    public static let minPrefixLength = 3

    /// Mots courants à NE PAS apprendre même s'ils sont capitalisés en milieu de
    /// phrase (titres, salutations, jours/mois, labels UI fréquents). Ils
    /// produisent des faux positifs gênants car leur préfixe entre en collision
    /// avec une frappe minuscule légitime (« Mon » → « sieur », « Bon » → « jour »).
    /// On n'y met JAMAIS de noms propres/marques. C'est un filtre CLI-friendly ;
    /// dans l'app, on l'augmentera par le dictionnaire système (NSSpellChecker,
    /// qui ne bloque qu'en CLI) pour couvrir l'ensemble des mots connus.
    public static let defaultStopwords: Set<String> = [
        // Titres / civilités
        "monsieur", "madame", "mademoiselle", "messieurs", "mesdames", "mme", "mlle",
        // Salutations / formules
        "bonjour", "bonsoir", "bonne", "bonnes", "salut", "coucou", "merci",
        "cordialement", "bienvenue", "félicitations", "bravo", "cher", "chère",
        "chers", "chères", "voici", "voilà", "ouais",
        // Jours
        "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche",
        // Mois
        "janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août",
        "septembre", "octobre", "novembre", "décembre",
        // Labels UI / langues / touches fréquemment capitalisés
        "historique", "entrée", "tabulation", "paramètres", "préférences",
        "accueil", "anglais", "français", "english", "internet",
    ]

    // MARK: - Construction

    /// Reconstruit le lexique depuis un snapshot d'historique. Tokenise le texte
    /// de chaque entrée (`contextBefore` + `accepted`), classe chaque mot selon
    /// sa capitalisation EN MILIEU de phrase, et ne retient que les distinctifs.
    public static func build(
        from history: [TypingHistoryEntry],
        stopwords: Set<String> = LearnedLexicon.defaultStopwords
    ) -> LearnedLexicon {
        var freq: [String: Int] = [:]
        var capMid: [String: Int] = [:]
        var caseCount: [String: [String: Int]] = [:]
        for e in history {
            let text = e.contextBefore.isEmpty ? e.accepted : e.contextBefore + " " + e.accepted
            for (word, midCap) in Self.tokensWithCase(text) {
                let key = word.lowercased()
                freq[key, default: 0] += 1
                caseCount[key, default: [:]][word, default: 0] += 1
                if midCap { capMid[key, default: 0] += 1 }
            }
        }
        var out: [String: (String, Int)] = [:]
        for (key, total) in freq {
            // Mot courant explicitement écarté (titre, salutation, label…).
            if stopwords.contains(key) { continue }
            // Distinctif : capitalisé en milieu de phrase ≥ 50 % du temps.
            guard Float(capMid[key] ?? 0) >= 0.5 * Float(total) else { continue }
            let canonical = caseCount[key]?.max { $0.value < $1.value }?.key ?? key
            out[key] = (canonical, total)
        }
        return LearnedLexicon(entries: out)
    }

    // MARK: - Requête

    /// Renvoie le suffixe (en casse canonique) à coller pour compléter le mot
    /// partiel en cours, ou `nil` si aucun terme appris ne s'applique.
    ///
    /// Gates (la config 90 %) : le partiel doit commencer par une **majuscule**
    /// (signal nom propre — c'est ce qui écarte les mots courants minuscules et
    /// fait grimper la précision), faire au moins `minPrefixLength` lettres, et
    /// matcher un terme distinctif `freq ≥ minFreq` qui **domine** son groupe de
    /// préfixe (`≥ minShare`).
    public func completion(
        for partial: String,
        minFreq: Int = LearnedLexicon.defaultMinFreq,
        minShare: Float = LearnedLexicon.defaultMinShare,
        minPrefix: Int = LearnedLexicon.minPrefixLength
    ) -> String? {
        guard !entries.isEmpty else { return nil }
        guard partial.count >= minPrefix else { return nil }
        // Majuscule initiale = le garde-fou anti-faux-positif (les mots courants
        // en milieu de phrase sont minuscules → on ne les touche pas).
        guard partial.first?.isUppercase == true else { return nil }
        let p = partial.lowercased()

        var best: (canonical: String, freq: Int)?
        var groupTotal = 0
        for (key, value) in entries where key.count > p.count && key.hasPrefix(p) {
            groupTotal += value.freq
            if best == nil || value.freq > best!.freq { best = value }
        }
        guard let win = best, win.freq >= minFreq else { return nil }
        guard Float(win.freq) >= minShare * Float(max(1, groupTotal)) else { return nil }
        // Suffixe à coller : la queue de la forme canonique après le préfixe tapé
        // (longueur en caractères, pas en octets).
        return String(win.canonical.dropFirst(partial.count))
    }

    // MARK: - Tokenisation (mot + « capitalisé en milieu de phrase »)

    /// Découpe `text` en mots (lettres uniquement ; l'apostrophe sépare comme
    /// dans les autres tokeniseurs FR du projet) et marque, pour chacun, s'il est
    /// capitalisé ALORS qu'il n'est PAS en début de phrase.
    public static func tokensWithCase(_ text: String) -> [(word: String, capMid: Bool)] {
        var out: [(String, Bool)] = []
        var cur = ""
        var sentenceStart = true
        var pendingTerminator = false
        func flush() {
            if cur.count >= 2 {
                let cap = cur.first?.isUppercase == true
                out.append((cur, cap && !sentenceStart))
                sentenceStart = false
            }
            cur = ""
            if pendingTerminator { sentenceStart = true; pendingTerminator = false }
        }
        for ch in text {
            if ch.isLetter { cur.append(ch) }
            else {
                flush()
                if ch == "." || ch == "!" || ch == "?" || ch == ":" || ch == "\n" {
                    pendingTerminator = true
                }
            }
        }
        flush()
        return out
    }
}
