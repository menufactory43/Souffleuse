import Foundation

/// One accepted suggestion recorded with the prefix that preceded it.
/// `contextBefore` is the tail of the prefix at the moment of acceptance,
/// already trimmed to the last sentence and capped in length.
public struct TypingHistoryEntry: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let contextBefore: String
    public let accepted: String
    public let bundleID: String?

    public init(timestamp: Date, contextBefore: String, accepted: String, bundleID: String?) {
        self.timestamp = timestamp
        self.contextBefore = contextBefore
        self.accepted = accepted
        self.bundleID = bundleID
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
