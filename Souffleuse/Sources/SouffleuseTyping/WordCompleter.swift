import AppKit
import Foundation

/// Fast-path word completion via NSSpellChecker.completions — returns the
/// suffix to append to the partial word at the caret. Designed to populate
/// the ghost INSTANTLY (sub-ms, system API) before the LLM has even started
/// generating, mirroring Cotypist's "ghost on first keystroke" behaviour.
///
/// The LLM remains responsible for next-word predictions once the partial
/// word is complete (or whenever no completion is found).
public final class WordCompleter: @unchecked Sendable {
    private let checker = NSSpellChecker.shared
    /// 2026-05-25: raised from 2 to 3 after empirical evidence that 2-char
    /// triggers produced jumpy ghost behaviour — the spell-checker's
    /// most-likely completion changes between adjacent keystrokes when
    /// the partial word is only 2 chars (too many candidates, almost any
    /// next letter pivots to a different word). 3-char triggers give a
    /// much more stable best-match and match the typical inline-completion
    /// product threshold.
    public static let minPartialLength = 3

    public init() {
        // Multilingual so FR/EN words are both considered without having
        // to switch system language. Same flag we set on TypoDetector.
        checker.automaticallyIdentifiesLanguages = true
    }

    /// Returns the suffix to append to the partial word the prefix ends with.
    /// Nil if the caret is at a word boundary, the word is too short, or
    /// the spell-checker has no completion that actually extends the user's
    /// typed prefix.
    public func completion(for prefix: String) -> String? {
        guard let word = Self.trailingPartialWord(prefix) else { return nil }
        guard word.count >= Self.minPartialLength else { return nil }

        for lang in ["fr", "en"] {
            let nsRange = NSRange(location: 0, length: (word as NSString).length)
            guard let completions = checker.completions(
                forPartialWordRange: nsRange,
                in: word,
                language: lang,
                inSpellDocumentWithTag: 0
            ), !completions.isEmpty else { continue }

            // Keep only completions that actually extend the user's word
            // (case-insensitive). The system API sometimes returns close
            // alternatives that don't share the user's prefix — we skip
            // those because they'd require backspacing, which the ghost
            // pipeline isn't designed to handle.
            let lowered = word.lowercased()
            let extending = completions.filter {
                $0.count > word.count && $0.lowercased().hasPrefix(lowered)
            }
            guard let best = extending.first else { continue }
            return String(best.dropFirst(word.count))
        }
        return nil
    }

    /// Returns the partial word the prefix ends with, or nil when the
    /// caret is at a boundary (after whitespace/punctuation).
    private static func trailingPartialWord(_ s: String) -> String? {
        guard let last = s.last, isWordChar(last) else { return nil }
        var start = s.endIndex
        while start > s.startIndex {
            let prev = s.index(before: start)
            if !isWordChar(s[prev]) { break }
            start = prev
        }
        let word = String(s[start..<s.endIndex])
        return word.isEmpty ? nil : word
    }

    private static func isWordChar(_ c: Character) -> Bool {
        if c.isLetter || c.isNumber { return true }
        if c == "'" || c == "’" || c == "-" { return true }
        return false
    }
}
