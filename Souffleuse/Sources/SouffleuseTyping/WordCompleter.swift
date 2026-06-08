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

    /// Comme `completion(for:)` mais **orientée par un indice** `hint` — le mot que
    /// le LLM penchait à produire (le greedy lead). `NSSpellChecker` est
    /// context-blind : pour « mange » il renvoie « manger » (infinitif, le plus
    /// fréquent) même après « nous ». Si `hint` prolonge le MÊME mot
    /// (« mangeons »), on choisit le candidat qui partage le PLUS LONG préfixe avec
    /// `hint` — donc la bonne conjugaison/forme — au lieu du 1ᵉʳ candidat aveugle.
    ///
    /// L'indice n'est retenu que s'il désambiguïse AU-DELÀ de ce qui est déjà tapé
    /// (`commun(candidat, hint) > |mot tapé|`). Si `hint` est vide, ne prolonge pas
    /// le mot (greedy parti en vrille), ou n'apporte rien, on retombe EXACTEMENT sur
    /// `completion(for:)` (1ᵉʳ candidat). Donc : jamais pire que la version aveugle,
    /// souvent juste. Renvoie le suffixe à ajouter, ou nil.
    public func completion(for prefix: String, preferring hint: String) -> String? {
        guard let word = Self.trailingPartialWord(prefix) else { return nil }
        guard word.count >= Self.minPartialLength else { return nil }
        let lowered = word.lowercased()
        for lang in ["fr", "en"] {
            let nsRange = NSRange(location: 0, length: (word as NSString).length)
            guard let completions = checker.completions(
                forPartialWordRange: nsRange,
                in: word,
                language: lang,
                inSpellDocumentWithTag: 0
            ), !completions.isEmpty else { continue }
            let extending = completions.filter {
                $0.count > word.count && $0.lowercased().hasPrefix(lowered)
            }
            guard let first = extending.first else { continue }
            // L'indice n'est exploitable que s'il prolonge le même mot que l'on tape.
            if hint.count > word.count, hint.lowercased().hasPrefix(lowered) {
                let best = extending.max {
                    Self.longestCommonPrefix([$0, hint]).count
                        < Self.longestCommonPrefix([$1, hint]).count
                }
                if let best, Self.longestCommonPrefix([best, hint]).count > word.count {
                    return String(best.dropFirst(word.count))
                }
            }
            return String(first.dropFirst(word.count))
        }
        return nil
    }

    /// **F3 — complétion dico « confiante ».** Au lieu du 1ᵉʳ candidat (aveugle
    /// au contexte, source du bug historique « inv→invite »), on renvoie le plus
    /// long préfixe COMMUN aux suffixes de TOUTES les complétions qui prolongent
    /// le mot. Un mot quasi-déterminé donne un commun long et fiable ; un fragment
    /// ambigu donne un commun minuscule (les candidats divergent tôt) que le
    /// caller jette via `minCompletion`. Sûr par construction.
    ///
    ///   « pingou »  → [« pingouin »]                 → « in »   (montré)
    ///   « cacah »   → [« cacahuète », « cacahuètes »] → « uète » (commun → montré)
    ///   « aspira »  → [« aspirateur », « aspiration »] → « t »    (divergent → jeté)
    ///
    /// Nil si le mot est trop court (`minLen`) ou si aucune complétion ne prolonge.
    public func commonCompletion(for prefix: String, minLen: Int) -> String? {
        guard let word = Self.trailingPartialWord(prefix), word.count >= minLen else { return nil }
        let lowered = word.lowercased()
        for lang in ["fr", "en"] {
            let nsRange = NSRange(location: 0, length: (word as NSString).length)
            guard let completions = checker.completions(
                forPartialWordRange: nsRange,
                in: word,
                language: lang,
                inSpellDocumentWithTag: 0
            ), !completions.isEmpty else { continue }
            let suffixes = completions
                .filter { $0.count > word.count && $0.lowercased().hasPrefix(lowered) }
                .map { String($0.dropFirst(word.count)) }
            guard !suffixes.isEmpty else { continue }
            let common = Self.longestCommonPrefix(suffixes)
            if !common.isEmpty { return common }
        }
        return nil
    }

    /// Plus long préfixe commun (insensible à la casse) d'un ensemble de chaînes.
    /// La casse retournée est celle de la PREMIÈRE chaîne. Pur, testable.
    public static func longestCommonPrefix(_ strings: [String]) -> String {
        guard let first = strings.first else { return "" }
        var length = first.count
        for s in strings.dropFirst() {
            var n = 0
            var i = first.startIndex
            var j = s.startIndex
            while n < length, i < first.endIndex, j < s.endIndex,
                  first[i].lowercased() == s[j].lowercased() {
                first.formIndex(after: &i)
                s.formIndex(after: &j)
                n += 1
            }
            length = n
            if length == 0 { break }
        }
        return String(first.prefix(length))
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

    private static func isWordChar(_ c: Character) -> Bool { WordBoundary.isWordChar(c) }
}
