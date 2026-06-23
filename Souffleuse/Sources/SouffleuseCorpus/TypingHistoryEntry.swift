import Foundation

/// Origin of a corpus entry — separates the user's own prose from accepted
/// ghost fragments. Entries tagged `.prose` are real sentences captured on
/// focus change; `.accept` entries are ghost suggestions the user accepted
/// (full or partial Tab run). Legacy entries without this key decode as
/// `.accept` so existing corpus files stay valid unchanged.
public enum EntrySource: String, Codable, Sendable {
    case prose
    case accept
}

/// One corpus entry: either an accepted ghost suggestion or a prose chunk
/// captured directly from a text field.
///
/// `contextBefore` is the tail of the prefix at the moment of capture,
/// already trimmed to the last sentence and capped in length.
///
/// `midWordContinuation` records whether this was a mid-word accept (true),
/// a next-word accept (false), or unknown/legacy (nil). When non-nil,
/// `SuggestionPolicy.joinHistory` uses the flag directly instead of guessing
/// with the dictionary — eliminating the "vér ifi" corruption.
public struct TypingHistoryEntry: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let contextBefore: String
    public let accepted: String
    public let bundleID: String?
    /// Whether the accept was mid-word (glue) or next-word (space). nil means
    /// legacy — no information; `joinHistory` falls back to the dictionary
    /// heuristic when nil.
    public let midWordContinuation: Bool?
    /// Origin of this entry. Legacy entries without the key decode as `.accept`.
    public let source: EntrySource

    public init(
        timestamp: Date,
        contextBefore: String,
        accepted: String,
        bundleID: String?,
        midWordContinuation: Bool? = nil,
        source: EntrySource = .accept
    ) {
        self.timestamp = timestamp
        self.contextBefore = contextBefore
        self.accepted = accepted
        self.bundleID = bundleID
        self.midWordContinuation = midWordContinuation
        self.source = source
    }

    // MARK: - Codable (backward-compatible)

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case contextBefore
        case accepted
        case bundleID
        case midWordContinuation
        case source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        contextBefore = try c.decode(String.self, forKey: .contextBefore)
        accepted = try c.decode(String.self, forKey: .accepted)
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
        // Old JSON without these keys decodes as nil / .accept — backward-compatible.
        midWordContinuation = try c.decodeIfPresent(Bool.self, forKey: .midWordContinuation)
        source = try c.decodeIfPresent(EntrySource.self, forKey: .source) ?? .accept
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(contextBefore, forKey: .contextBefore)
        try c.encode(accepted, forKey: .accepted)
        try c.encodeIfPresent(bundleID, forKey: .bundleID)
        try c.encodeIfPresent(midWordContinuation, forKey: .midWordContinuation)
        try c.encode(source, forKey: .source)
    }
}

/// Heuristic filter for password-like or token-like strings. Returns `true`
/// when the suggestion looks like a secret and should not be recorded.
public enum SecretHeuristic {
    public static func looksLikeSecret(_ s: String) -> Bool {
        if s.count >= 16 {
            // Long run with no whitespace and mixed alnum → likely a token.
            let hasNoSpace = !s.contains(where: { $0.isWhitespace })
            let alnumRun = s.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "."
            }
            if hasNoSpace && alnumRun { return true }
        }
        // Any single token of >=16 alnum chars
        for word in s.split(whereSeparator: { $0.isWhitespace }) where word.count >= 16 {
            let isAlnum = word.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
            if isAlnum { return true }
        }
        return false
    }

    /// Placeholder substituted for an embedded secret. Chosen so re-redacting is
    /// a no-op : it carries no credential separator (`=`/`:`) and no ≥16 alnum
    /// run, so neither `redact` pass matches it a second time (idempotence —
    /// `redact(redact(x)) == redact(x)`), and it never re-triggers `.secretLike`
    /// nor `.artifact` admission (the guillemets keep letter-density high).
    public static let redactionPlaceholder = "«caviardé»"

    /// Caviarde les secrets EMBARQUÉS dans un texte par ailleurs admissible, AVANT
    /// qu'il ne soit persisté (store chiffré) ou plié au corpus de session
    /// (`historySnapshot`/n-gram). Complète — ne remplace pas — le drop
    /// `.secretLike` de `admissionRejection` : ce dernier rejette une entrée qui
    /// EST un seul gros token ; `redact` masque une clé API / mot de passe noyé
    /// dans de la prose multi-mots (un `.env` collé, `export API_KEY=sk-…`) que
    /// l'admission laisse passer. Pur, on-device, langue-agnostique.
    ///
    /// Invariant d'ordre (figé) : `admissionRejection` (qui peut DROP) tourne
    /// EN PREMIER ; `redact` ne s'applique qu'aux entrées déjà admises. Identité
    /// sur de la prose normale (aucune clé sensible, aucun token long/préfixé).
    public static func redact(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        return redactSecretTokens(redactCredentialPairs(s))
    }

    /// Noms de clé « sensibles » dont la VALEUR (`clé=valeur` / `clé: valeur`) est
    /// caviardée. `bearer`/`authorization` en sont exclus (leur secret est un token
    /// séparé, capté par `redactSecretTokens` via son préfixe/longueur — sinon on
    /// caviarderait le littéral « Bearer »).
    /// La valeur est captée comme : une chaîne ENTRE GUILLEMETS (`"…"`, espaces
    /// internes compris → un mot de passe « entre guillemets » est masqué en entier)
    /// OU, à défaut, un run NON-BLANC unique (`[^\s]+`, guillemet interne compris →
    /// `ab"cd` masqué d'un bloc). Limite assumée : une valeur NUE multi-mots
    /// (`password: correct horse`) n'est masquée qu'au premier mot — rare dans un
    /// champ texte surveillé, et le gate d'admission `.secretLike` couvre déjà les
    /// secrets mono-token ; `redactSecretTokens` rattrape les tokens à préfixe/longs.
    private static let credentialKeyPattern =
        #"(?i)((?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|secret[_-]?key|client[_-]?secret|api[_-]?secret|private[_-]?key)\s*[:=]\s*)"#
        + #"("[^"]*"[^\s]*|[^\s]+)"#

    private static let credentialRegex = try? NSRegularExpression(pattern: credentialKeyPattern)

    /// Remplace la valeur d'une paire credential par le placeholder, en gardant la
    /// clé et le séparateur (`api_key=«caviardé»`). Groupe 1 = clé+séparateur (gardé),
    /// groupe 2 = valeur (jetée). Idempotent : `clé=«caviardé»` re-match → re-remplace
    /// par le même placeholder.
    private static func redactCredentialPairs(_ s: String) -> String {
        guard let regex = credentialRegex else { return s }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return regex.stringByReplacingMatches(
            in: s, range: range, withTemplate: "$1" + redactionPlaceholder)
    }

    /// Préfixes de tokens secrets reconnus (clés de fournisseurs / JWT) — un token
    /// qui en commence un est caviardé même s'il est court (< 16 car). Les préfixes
    /// Slack incluent le TIRET réel des tokens (`xoxb-`, jamais « xoxo ») pour ne pas
    /// caviarder un sign-off d'affection (« xoxo », fréquent en messagerie).
    private static let secretTokenPrefixes = [
        "sk-", "pk-", "rk_", "ghp_", "gho_", "ghu_", "ghs_", "github_pat_",
        "xoxb-", "xoxp-", "xoxa-", "xoxr-", "xoxs-", "AKIA", "ASIA", "AIza", "ya29.", "eyJ",
    ]

    /// Caviarde chaque TOKEN (run non-blanc) qui ressemble à un secret isolé :
    /// préfixe fournisseur connu, ou run ≥16 caractères alphanumériques (même
    /// seuil que `looksLikeSecret`). Énumère les matches en ordre INVERSE pour que
    /// le remplacement ne décale pas les ranges suivants ; ne touche que les runs
    /// non-blancs → l'espacement exact est préservé.
    private static func redactSecretTokens(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\S+"#) else { return s }
        var out = s
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        let matches = regex.matches(in: s, range: range)
        for m in matches.reversed() {
            guard let r = Range(m.range, in: out) else { continue }
            let token = String(out[r])
            if tokenIsSecret(token) {
                out.replaceSubrange(r, with: redactionPlaceholder)
            }
        }
        return out
    }

    /// True quand un token isolé est secret-like : commence par un préfixe connu,
    /// OU contient un run ≥16 caractères alphanumériques qui MÊLE lettres ET chiffres
    /// (UUID sans tirets, SHA, clé opaque). L'exigence « lettres + chiffres » évite
    /// de détruire un mot purement alphabétique très long (« anticonstitutionnellement »,
    /// un composé allemand) — de la vraie prose que la personnalisation doit garder ;
    /// un secret structuré, lui, mêle quasi toujours les deux. Les ponctuations/
    /// guillemets de bord sont ignorés pour le test de préfixe.
    private static func tokenIsSecret(_ token: String) -> Bool {
        let core = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`(){}[]<>,;"))
        guard core.count >= 3 else { return false }
        if secretTokenPrefixes.contains(where: { core.hasPrefix($0) }) { return true }
        // Plus long run alphanumérique mêlant lettres ET chiffres : un secret opaque
        // dépasse 16 et n'est jamais purement alphabétique (contrairement à un mot).
        var runLength = 0
        var runHasLetter = false
        var runHasDigit = false
        for scalar in core.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                runLength += 1
                if CharacterSet.decimalDigits.contains(scalar) { runHasDigit = true }
                else if CharacterSet.letters.contains(scalar) { runHasLetter = true }
                if runLength >= 16, runHasLetter, runHasDigit { return true }
            } else {
                runLength = 0
                runHasLetter = false
                runHasDigit = false
            }
        }
        return false
    }

    /// Trims the prefix to the tail of the last sentence and caps to `maxChars`.
    public static func contextTail(prefix: String, maxChars: Int = 80) -> String {
        let terminators: Set<Character> = [".", "!", "?", "\n"]
        // Find last terminator and keep what follows.
        if let lastTerm = prefix.lastIndex(where: { terminators.contains($0) }) {
            let tail = prefix[prefix.index(after: lastTerm)...]
            let trimmed = tail.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                return String(prefix.suffix(maxChars))
            }
            return String(trimmed.suffix(maxChars))
        }
        return String(prefix.suffix(maxChars))
    }
}
