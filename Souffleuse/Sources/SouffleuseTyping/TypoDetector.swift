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
        // All languages flagged. Pick the closest candidate by the typo-aware
        // distance (transposition-preferring). Tie between distinct candidates →
        // ambiguous, skip.
        let scored = candidates.map { ($0, Self.typoDistance($0, word)) }
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
        // Rank by the typo-aware distance (transposition-preferring) rather than
        // the spell-checker's own order, so "sius" → "suis" beats "sous".
        let ranked = close.sorted { Self.typoDistance($0, word) < Self.typoDistance($1, word) }
        guard let best = ranked.first else { return .some(nil) }
        // Ambiguous (top two candidates equidistant) → skip.
        if ranked.count > 1,
           Self.typoDistance(ranked[0], word) == Self.typoDistance(ranked[1], word),
           ranked[0] != ranked[1]
        {
            return .some(nil)
        }
        return .some(best)
    }

    public func ignore(word: String) {
        checker.ignoreWord(word, inSpellDocumentWithTag: 0)
    }

    /// True when `word` is a valid word in at least one of the checked
    /// languages. Used by the mid-word coherence guard in the ghost pipeline:
    /// the candidate "partialWord + ghostHead" is only KEPT when it forms a
    /// real word, so an incoherent splice ("procéd" + "blème" → "procédblème")
    /// is rejected while a legitimate completion ("problè" + "me" → "problème")
    /// passes.
    ///
    /// A word counts as valid as soon as ONE language accepts it — the opposite
    /// rule of `bestGuess`/`currentWordLooksSuspect` (which require ALL to
    /// flag). Here we want to be permissive: any dictionary recognising the
    /// candidate means the splice is coherent and must not be dropped.
    ///
    /// `language` (when provided) is tried first as a hint; we always also
    /// fall back to FR + EN so single-language installs don't reject the other
    /// tongue. We refuse to log the actual word — only event names flow to Log.
    public func isValidWord(_ word: String, language: String? = nil) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        var languages = ["fr", "en"]
        if let hint = Self.spellLanguageCode(for: language), !languages.contains(hint) {
            languages.insert(hint, at: 0)
        }
        let nsword = trimmed as NSString
        for language in languages {
            let range = checker.checkSpelling(
                of: trimmed, startingAt: 0, language: language, wrap: false,
                inSpellDocumentWithTag: 0, wordCount: nil
            )
            // Not flagged (or flagged on a sub-range only) → valid in this lang.
            if range.location == NSNotFound || range.length != nsword.length {
                return true
            }
        }
        return false
    }

    /// Maps an English language name (as produced by `detectLanguage`) to the
    /// ISO code NSSpellChecker expects. Nil when unknown.
    static func spellLanguageCode(for language: String?) -> String? {
        guard let language else { return nil }
        switch language.lowercased() {
        case "french": return "fr"
        case "english": return "en"
        case "spanish": return "es"
        case "german": return "de"
        case "italian": return "it"
        case "portuguese": return "pt"
        case "dutch": return "nl"
        default: return nil
        }
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

    private static func isWordChar(_ c: Character) -> Bool { WordBoundary.isWordChar(c) }

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

    /// Cost of an adjacent transposition relative to an insert/delete/substitute
    /// (all 1.0). Below 1 so a transposition-fix is preferred over a same-plain-
    /// distance substitution: real typing errors are dominated by adjacent swaps,
    /// so for "sius" the model should rank "suis" (one transposition) above "sous"
    /// (one substitution). Context-blind by design — it always prefers the
    /// transposition, which is the more-common-correct default ("je suis" ≫ "dort
    /// sous"); true context disambiguation needs the (deferred) LM scorer.
    static let transpositionCost = 0.85

    /// Damerau–Levenshtein (Optimal String Alignment) with a weighted adjacent
    /// transposition. Used to RANK spell-checker candidates (the ≤`maxLevenshtein`
    /// filter still uses plain `levenshtein`). Fine for the ≤30-char words here.
    static func typoDistance(_ a: String, _ b: String) -> Double {
        let s = Array(a), t = Array(b)
        let n = s.count, m = t.count
        if n == 0 { return Double(m) }
        if m == 0 { return Double(n) }
        var d = Array(repeating: Array(repeating: 0.0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = Double(i) }
        for j in 0...m { d[0][j] = Double(j) }
        for i in 1...n {
            for j in 1...m {
                let cost = s[i - 1] == t[j - 1] ? 0.0 : 1.0
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, s[i - 1] == t[j - 2], s[i - 2] == t[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + transpositionCost)
                }
            }
        }
        return d[n][m]
    }
}
