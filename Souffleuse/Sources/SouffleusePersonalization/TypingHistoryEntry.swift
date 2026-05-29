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
