import AppKit
import Foundation

public struct TypoSuggestion: Sendable, Equatable {
    /// The misspelled word, copied verbatim from the user's text.
    public let original: String
    /// The single best correction NSSpellChecker proposed.
    public let suggestion: String
    /// Position of `original` in the source text (character indices).
    public let range: Range<String.Index>

    public init(original: String, suggestion: String, range: Range<String.Index>) {
        self.original = original
        self.suggestion = suggestion
        self.range = range
    }
}

/// Spell-check via NSSpellChecker — multilingual via system preferences,
/// learns user words globally (NSSpellChecker is process-wide), zero embedded
/// dictionary. We refuse to log the user's actual word; only event names
/// flow through Log.
public final class TypoDetector: @unchecked Sendable {
    private let checker = NSSpellChecker.shared
    public static let maxLevenshtein = 2
    /// Don't flag very short typos (≤2 chars), too noisy.
    public static let minWordLength = 3

    public init() {
        // Multilingual by default — NSSpellChecker is otherwise stuck on the
        // system primary language, which means FR words get checked against the
        // EN dictionary on most installs (so "Bonjur" isn't flagged, etc.).
        checker.automaticallyIdentifiesLanguages = true
    }

    /// Check the word ending at `caretIndex` (or just before it, separated by
    /// whitespace/punctuation). Returns a suggestion if exactly one good
    /// candidate exists within Levenshtein-distance `maxLevenshtein`.
    public func checkLastWord(in text: String, caretIndex: Int) -> TypoSuggestion? {
        guard let (range, word) = Self.lastWord(in: text, before: caretIndex) else { return nil }
        guard word.count >= Self.minWordLength else { return nil }
        guard let best = bestGuess(forWord: word), best != word else { return nil }
        return TypoSuggestion(original: word, suggestion: best, range: range)
    }

    /// Try FR then EN explicitly — `automaticallyIdentifiesLanguages` can't
    /// classify a single short word reliably and tends to default to the
    /// system primary language, missing typos in the other.
    ///
    /// A word is treated as a typo only when EVERY checked language flags it.
    /// If any language accepts it (e.g. `viens` is valid French), we bail out
    /// — otherwise FR-valid words would get "corrected" into EN look-alikes
    /// (`viens` → `views`) the moment one dictionary doesn't recognise them.
    /// This mirrors `currentWordLooksSuspect`'s rule.
    private func bestGuess(forWord word: String) -> String? {
        let languages = ["fr", "en"]
        var candidates: [String] = []
        for language in languages {
            switch candidateGuesses(forWord: word, language: language) {
            case .none:
                // Word accepted by this language → not a typo.
                return nil
            case .some(.none):
                // Flagged but no single best candidate from this language.
                continue
            case .some(.some(let candidate)):
                candidates.append(candidate)
            }
        }
        // All languages flagged. Pick the closest candidate by Levenshtein.
        // Tie between distinct candidates → ambiguous, skip.
        let scored = candidates.map { ($0, Self.levenshtein($0, word)) }
            .sorted { $0.1 < $1.1 }
        guard let first = scored.first else { return nil }
        if scored.count > 1, scored[1].1 == first.1, scored[1].0 != first.0 {
            return nil
        }
        return first.0
    }

    /// Returns: nil if the language doesn't flag the word at all (so we
    /// shouldn't penalize it via Levenshtein on noise), Optional(nil) if
    /// flagged but no clear single suggestion, Optional(.some(s)) for a
    /// clear correction.
    private func candidateGuesses(forWord word: String, language: String) -> String?? {
        let nsword = word as NSString
        let range = checker.checkSpelling(
            of: word, startingAt: 0, language: language, wrap: false,
            inSpellDocumentWithTag: 0, wordCount: nil
        )
        guard range.location != NSNotFound, range.length == nsword.length else {
            return nil  // not flagged → not a typo in this language
        }
        guard let guesses = checker.guesses(
            forWordRange: NSRange(location: 0, length: nsword.length),
            in: word, language: language, inSpellDocumentWithTag: 0
        ), !guesses.isEmpty else {
            return .some(nil)
        }
        let close = guesses.prefix(5).filter { Self.levenshtein($0, word) <= Self.maxLevenshtein }
        guard let best = close.first else { return .some(nil) }
        // Ambiguous (multiple candidates with identical distance) → skip.
        if close.count > 1,
           Self.levenshtein(close[0], word) == Self.levenshtein(close[1], word)
        {
            return .some(nil)
        }
        return .some(best)
    }

    public func ignore(word: String) {
        checker.ignoreWord(word, inSpellDocumentWithTag: 0)
    }

    /// Returns true if the word the caret is INSIDE (mid-word case) looks
    /// misspelled. Used by the "hide completions on suspected typo" path so
    /// the LLM ghost doesn't extend a misspelled word with more wrong text.
    /// Returns false at word boundaries — the boundary case is handled by
    /// `checkLastWord` which produces an actual suggestion.
    public func currentWordLooksSuspect(in text: String, caretIndex: Int) -> Bool {
        guard let word = Self.wordContainingCaret(in: text, caretIndex: caretIndex),
              word.count >= Self.minWordLength
        else { return false }
        let nsword = word as NSString
        // Suspect only if BOTH FR and EN flag it — single-language flags get
        // false positives on proper nouns / loanwords ("Bonjour" flagged in EN).
        for language in ["fr", "en"] {
            let range = checker.checkSpelling(
                of: word, startingAt: 0, language: language, wrap: false,
                inSpellDocumentWithTag: 0, wordCount: nil
            )
            if range.location == NSNotFound || range.length != nsword.length {
                return false  // at least one language accepts it → not suspect
            }
        }
        return true
    }

    /// Returns the word the caret is mid-way through, or nil if the caret is
    /// at a boundary (which is `lastWord`'s case instead).
    static func wordContainingCaret(in text: String, caretIndex: Int) -> String? {
        guard caretIndex > 0, caretIndex <= text.count else { return nil }
        let endIdx = text.index(text.startIndex, offsetBy: caretIndex)
        // The previous char must be a word char (otherwise we're at a boundary).
        let prev = text.index(before: endIdx)
        guard isWordChar(text[prev]) else { return nil }
        var start = endIdx
        while start > text.startIndex {
            let p = text.index(before: start)
            if !isWordChar(text[p]) { break }
            start = p
        }
        // Also extend forward — if the caret is inside (not just after) the word.
        var end = endIdx
        while end < text.endIndex && isWordChar(text[end]) {
            end = text.index(after: end)
        }
        let word = String(text[start..<end])
        return word.isEmpty ? nil : word
    }

    /// Return the last "word" character range strictly before `caretIndex`,
    /// where a word is `[\p{L}\p{N}'’-]+`. Whitespace, punctuation, etc.
    /// terminate the word. Nil if the caret is mid-word (we wait until the
    /// user moves on so we don't flag every keystroke).
    static func lastWord(in text: String, before caretIndex: Int) -> (range: Range<String.Index>, word: String)? {
        guard caretIndex >= 0, caretIndex <= text.count else { return nil }
        let endIdx = text.index(text.startIndex, offsetBy: caretIndex)
        // Caret must be at a boundary: either end-of-string or on a non-word char.
        if endIdx < text.endIndex {
            let c = text[endIdx]
            if isWordChar(c) { return nil }
        }
        var wordEnd = endIdx
        // Skip any trailing whitespace/punctuation to find the end of the previous word.
        while wordEnd > text.startIndex {
            let prev = text.index(before: wordEnd)
            if isWordChar(text[prev]) { break }
            wordEnd = prev
        }
        guard wordEnd > text.startIndex else { return nil }
        var wordStart = wordEnd
        while wordStart > text.startIndex {
            let prev = text.index(before: wordStart)
            if !isWordChar(text[prev]) { break }
            wordStart = prev
        }
        let word = String(text[wordStart..<wordEnd])
        guard !word.isEmpty else { return nil }
        return (wordStart..<wordEnd, word)
    }

    private static func isWordChar(_ c: Character) -> Bool {
        if c.isLetter || c.isNumber { return true }
        if c == "'" || c == "’" || c == "-" { return true }
        return false
    }

    /// Iterative two-row Levenshtein. Fine for the ≤30-char words we feed it.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let ac = Array(a), bc = Array(b)
        if ac.isEmpty { return bc.count }
        if bc.isEmpty { return ac.count }
        var prev = Array(0...bc.count)
        var curr = Array(repeating: 0, count: bc.count + 1)
        for i in 1...ac.count {
            curr[0] = i
            for j in 1...bc.count {
                let cost = ac[i - 1] == bc[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,
                    curr[j - 1] + 1,
                    prev[j - 1] + cost
                )
            }
            swap(&prev, &curr)
        }
        return prev[bc.count]
    }
}
