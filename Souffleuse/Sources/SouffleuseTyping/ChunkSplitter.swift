import Foundation

/// Splits a ghost suggestion into "next chunk" pieces, à la Cotypist.
///
/// A chunk is the next word in the suggestion (letters + digits + apostrophes
/// + hyphens), plus any trailing punctuation (`.,;:!?…)]}»`), and optionally
/// the single trailing whitespace so the caret lands ready for the next word.
///
/// Pure function — no IO, no state. Safe to call from any thread.
public enum ChunkSplitter {
    /// Returns the prefix of `s` representing the next chunk. Empty if `s`
    /// is empty or contains only whitespace.
    ///
    /// Examples (with `trailingSpace: true`):
    ///   "Je m'appelle Gabriel, "  →  "Je "
    ///   "m'appelle Gabriel, "     →  "m'appelle "
    ///   "Gabriel, "               →  "Gabriel, "
    ///   "."                       →  "."
    ///
    /// With `trailingSpace: false`, the trailing single space is omitted:
    ///   "Je m'appelle Gabriel, "  →  "Je"
    public static func nextChunk(_ s: String, trailingSpace: Bool) -> String {
        var i = s.startIndex
        // Skip leading whitespace — but keep it in the returned prefix so the
        // caret advances past it. (" hello" → " hello" if the model emits a
        // leading space; matches natural typing flow.)
        let leadingStart = i
        while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
        let contentStart = i
        // Consume word chars (letters, digits, apostrophe, hyphen).
        while i < s.endIndex, isWordChar(s[i]) { i = s.index(after: i) }
        // Consume trailing punctuation.
        while i < s.endIndex, isTrailingPunct(s[i]) { i = s.index(after: i) }
        // If we didn't consume any word/punctuation, the suggestion is only
        // whitespace — return empty so the caller can fall back to a safe
        // behaviour instead of injecting bare spaces.
        guard i > contentStart else { return "" }
        // Optionally include one trailing whitespace.
        if trailingSpace, i < s.endIndex, s[i].isWhitespace {
            i = s.index(after: i)
        }
        return String(s[leadingStart..<i])
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "'" || c == "\u{2019}" || c == "-"
    }

    private static func isTrailingPunct(_ c: Character) -> Bool {
        ".,;:!?\u{2026})]}»".contains(c)
    }
}
