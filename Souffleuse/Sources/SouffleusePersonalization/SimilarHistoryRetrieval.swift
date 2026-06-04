import Foundation
import SouffleuseCorpus

/// Few-shot dynamique : retrouve les entrées d'historique les plus similaires
/// au texte que l'utilisateur est en train de taper, pour les injecter comme
/// exemples in-context dans le prompt du modèle.
///
/// V1 algorithme : Jaccard sur tokens (mots minuscules), avec filtrage des
/// stop-words FR/EN courts et longueur minimale de token (2 chars). Pas
/// d'embedding model — on cible <5ms sur 200 entrées × ~20 mots.
///
/// Privacy : la fonction n'effectue aucun I/O réseau et ne logue jamais le
/// texte des entrées. Toute trace (`Log.info`) doit être un compteur, pas
/// un échantillon de texte (cf. `audit.sh` checks 4 et 6).
public enum SimilarHistoryRetrieval {

    /// Stop-words FR/EN courts. Filtrés des deux côtés (userTail et entries)
    /// AVANT le calcul Jaccard, sinon tout matche tout sur « de », « le »,
    /// « the », etc.
    public static let stopWords: Set<String> = [
        "de", "la", "le", "les", "un", "une", "des", "et", "à", "a",
        "en", "du", "au", "aux", "ce", "ces", "ça", "se", "sa", "son",
        "ses", "ne", "pas", "que", "qui", "où", "ou", "si", "y", "d",
        "the", "is", "and", "of", "to", "in", "for", "on", "at", "by",
        "be", "as", "it", "this", "that", "with", "are", "was", "were",
    ]

    /// Cap total des exemples concaténés (chars). Au-delà, on drop depuis le
    /// bas (les moins similaires). Garde le prompt sous contrôle face au
    /// userTail qui peut déjà faire 2048 chars.
    public static let maxConcatenatedExamplesChars: Int = 400

    /// Nombre par défaut d'exemples retrieved par appel à predict().
    public static let defaultK: Int = 3

    /// Découpe `text` en tokens minuscules. Les apostrophes sont traitées
    /// comme des séparateurs (« j'ai » → « j » + « ai ») parce qu'en français
    /// les contractions (l', d', qu', s', n'…) sont quasi toujours des
    /// articles/pronoms d'une lettre qui seront filtrés par la longueur
    /// minimale. Le tiret intra-mot est gardé (« aujourd'hui » reste
    /// fragmenté en aujourd/hui, mais « peut-être » resterait collé — on
    /// préfère garder le sens composé). Tokens < 2 chars et stop-words sont
    /// filtrés AVANT le calcul Jaccard.
    public static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            let ch = Character(scalar)
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if ch == "-" {
                // Tiret intra-mot : on garde seulement si on est déjà au
                // milieu d'un mot — sinon c'est de la ponctuation.
                if !current.isEmpty {
                    current.append(ch)
                }
            } else {
                // Tout le reste (apostrophes incluses, espaces, ponctuation)
                // sépare les tokens.
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens.filter { token in
            let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            guard trimmed.count >= 2 else { return false }
            return !stopWords.contains(trimmed)
        }
    }

    /// Score Jaccard entre deux ensembles de tokens. 0 si l'un des deux est vide.
    public static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        let intersection = a.intersection(b)
        if intersection.isEmpty { return 0 }
        let union = a.union(b)
        return Double(intersection.count) / Double(union.count)
    }

    /// Minimum Jaccard score for an entry to be considered relevant. Below
    /// this threshold, a single common non-stopword token (e.g. "merci" in
    /// otherwise unrelated sentences) would qualify — and on PT models this
    /// injects noise that biases generation toward the disconnected example
    /// instead of the current typing context.
    ///
    /// Calibrated 2026-05-25: user observed fortune-cookie suggestions
    /// despite few-shot firing 168 times in a session. The previous
    /// `score > 0` filter let through too many low-relevance examples.
    /// 0.1 = at least ~10% token overlap (e.g. 1 common token over a
    /// combined vocabulary of ~10). Strict enough to drop noise, loose
    /// enough to keep useful matches in short tails.
    public static let minRelevanceScore: Double = 0.1

    /// Renvoie les `limit` entrées les plus similaires à `userTail`, classées
    /// par score Jaccard décroissant. Les entrées dont le score est sous
    /// `minRelevanceScore` sont exclues — un overlap minuscule (1 token
    /// commun sur des sujets disjoints) injecte plus de bruit que de signal.
    public static func rank(
        entries: [TypingHistoryEntry],
        userTail: String,
        limit: Int
    ) -> [TypingHistoryEntry] {
        let tailTokens = Set(tokenize(userTail))
        guard !tailTokens.isEmpty, limit > 0 else { return [] }

        var scored: [(score: Double, entry: TypingHistoryEntry)] = []
        scored.reserveCapacity(entries.count)
        for entry in entries {
            let joined: String
            if entry.contextBefore.isEmpty {
                joined = entry.accepted
            } else {
                joined = entry.contextBefore + " " + entry.accepted
            }
            let entryTokens = Set(tokenize(joined))
            let score = jaccard(tailTokens, entryTokens)
            if score >= minRelevanceScore {
                scored.append((score, entry))
            }
        }
        scored.sort { $0.score > $1.score }
        return scored.prefix(limit).map { $0.entry }
    }

    /// Construit le bloc d'exemples few-shot prêt à coller dans le prompt,
    /// avec un cap dur sur la longueur totale (drop des moins similaires
    /// si dépassement). Chaque exemple sur sa propre ligne, format brut
    /// « {contextBefore} {accepted} » — pas de label « Examples: » car le
    /// modèle PT base ne suit pas les instructions.
    ///
    /// Renvoie une chaîne vide si aucun exemple ne tient.
    public static func buildExamplesBlock(
        from entries: [TypingHistoryEntry],
        maxChars: Int = maxConcatenatedExamplesChars
    ) -> String {
        var lines: [String] = []
        var total = 0
        for entry in entries {
            let line: String
            if entry.contextBefore.isEmpty {
                line = entry.accepted
            } else {
                line = entry.contextBefore + " " + entry.accepted
            }
            // +1 pour le « \n » qui séparera la ligne. La dernière ligne
            // n'aura pas de \n trailing mais on est plus prudent côté cap.
            let lineCost = line.count + 1
            if total + lineCost > maxChars {
                break
            }
            lines.append(line)
            total += lineCost
        }
        return lines.joined(separator: "\n")
    }
}

extension TypingHistoryStore {
    /// Variante actor-isolated du retrieval. À appeler depuis `predict()` via
    /// `await store.similarEntries(...)`. Renvoie au plus `limit` entrées
    /// triées par similarité décroissante, ou `[]` si l'historique est vide
    /// ou si aucune entrée n'a d'overlap > 0.
    public func similarEntries(to userTail: String, limit: Int) -> [TypingHistoryEntry] {
        // `allEntries()` triggers `load()` internally — no need to duplicate.
        return SimilarHistoryRetrieval.rank(
            entries: allEntries(),
            userTail: userTail,
            limit: limit
        )
    }
}
