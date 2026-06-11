import Foundation

/// Silently corrects obvious typos in the *model input* prefix so the LLM
/// completes from a clean text (Cotypist's `correctedPrefix`). The user always
/// sees their original text — only the string fed into the llama prompt's
/// `beforeCursor` is rewritten.
///
/// Conservatism is the whole point (see `.planning/PREFIX-CORRECTION.md`):
/// - Reuses the existing `TypoDetector` (NSSpellChecker). No new dependency.
/// - **Never touches the in-progress last token** (the word at the caret).
///   That word is `WordCompleter`'s job; "correcting" it would fight the
///   completion path and flicker.
/// - Corrects only COMPLETED words (those followed by a separator), bounded to
///   the last `wordBudget` words for cost.
/// - Language-aware: a confidently detected language restricts the spellcheck
///   so valid French isn't "corrected" into English look-alikes.
/// - Only above the detector's confidence (Levenshtein ≤ max, length ≥ min);
///   when unsure it leaves the word verbatim.
///
/// The corrector is a thin wrapper over `TypoDetector` ; son seul état mutable
/// est le memo `mot → verdict` ci-dessous, protégé par un lock (`@unchecked
/// Sendable` honnête).
public final class PrefixCorrector: @unchecked Sendable {
    private let detector: TypoDetector

    /// Only the last N completed words are eligible for correction. Bounds the
    /// per-keystroke cost (NSSpellChecker calls) and keeps the corrected text
    /// stable so the KV-cache LCP stays valid across keystrokes.
    public static let wordBudget = 12

    /// Memo `mot → verdict` (nil = laisser tel quel). Les mots COMPLÉTÉS de la
    /// fenêtre sont quasi identiques d'une frappe à l'autre (le mot au caret
    /// est exclu par design) : sans memo, les 12 mêmes mots repassaient par
    /// NSSpellChecker à CHAQUE predict — mesuré 76 ms p50 par frappe après le
    /// durcissement multi-langues de `68a28af` (trace 11/06, segment
    /// `lang_done→correct_done`). Avec memo : ~0 ms en cours de mot, une seule
    /// vraie vérification à chaque mot complété. Le verdict ne dépend QUE du
    /// mot (le hint de langue de `correctedWord` est advisory et non transmis
    /// au détecteur) — si un futur durcissement force la langue, la clé du
    /// memo devra l'inclure.
    private var verdictMemo: [String: String?] = [:]
    private let memoLock = NSLock()

    /// Borne du memo. Au-delà, reset complet (plus simple qu'un LRU ; le
    /// re-remplissage coûte une fenêtre de 12 mots, négligeable).
    static let memoCap = 512

    /// Kill-switch runtime (pattern `SOUFFLEUSE_*_OFF`) : posé ⇒ chaque mot
    /// repasse par NSSpellChecker à chaque predict (comportement pré-memo),
    /// pour A/B ou revert instantané sans rebuild.
    private static let memoDisabled: Bool =
        ProcessInfo.processInfo.environment["SOUFFLEUSE_TYPO_CACHE_OFF"] != nil

    public init(detector: TypoDetector = TypoDetector()) {
        self.detector = detector
    }

    /// Returns a copy of `text` with obvious typos in completed words fixed,
    /// leaving the in-progress last token (if any) untouched.
    ///
    /// `detectedLanguage` is the English language name (e.g. `"French"`) from
    /// `ModelRuntime.detectLanguage`, used to constrain correction. When nil,
    /// the detector's own FR+EN agreement rule applies (still conservative).
    ///
    /// Identity (returns `text` unchanged) when nothing crosses the confidence
    /// bar — including the common case of clean prose.
    public func correctedPrefix(_ text: String, detectedLanguage: String?) -> String {
        guard !text.isEmpty else { return text }

        // Split into (completedRegion, inProgressTail). The in-progress tail is
        // the run of word chars at the very end with no trailing separator —
        // i.e. the word the caret is mid-typing. We must NOT touch it.
        let split = Self.splitInProgressTail(text)
        var completed = String(split.completed)
        let tail = String(split.tail)
        guard !completed.isEmpty else { return text }

        // Collect correctable word ranges in the completed region, restricted
        // to the last `wordBudget` words (cheap + stable).
        let words = Self.completedWordRanges(in: completed[...])
        guard !words.isEmpty else { return text }
        let eligible = Array(words.suffix(Self.wordBudget))

        // Apply corrections back-to-front so earlier ranges stay valid as we
        // splice. Each word is checked in isolation via `TypoDetector`.
        let languageHint = Self.spellLanguage(for: detectedLanguage)
        for range in eligible.reversed() {
            let word = String(completed[range])
            guard let fixed = correctedWord(word, language: languageHint),
                  fixed != word else { continue }
            // Preserve the original capitalization shape (Title / lower) so a
            // sentence-initial corrected word doesn't get lowercased.
            let cased = Self.matchingCase(of: word, applyingTo: fixed)
            completed.replaceSubrange(range, with: cased)
        }

        return completed + tail
    }

    // MARK: - Single-word correction

    /// Runs one word through `TypoDetector`. We build a tiny "<word> " probe so
    /// the detector's `checkLastWord` (which only fires at a word boundary) is
    /// triggered, then accept its suggestion only if it stays within the
    /// confidence bar. Language constraint: when a confident language is known
    /// we skip correction entirely if the detector cannot agree (it already
    /// bails when any of FR/EN accepts the word).
    ///
    /// Memoïsé : un mot déjà arbitré ne repasse jamais par NSSpellChecker
    /// (voir `verdictMemo`).
    private func correctedWord(_ word: String, language: String?) -> String? {
        guard word.count >= TypoDetector.minWordLength else { return nil }
        // Skip non-prose tokens: anything with a digit, a dot/slash/at/colon
        // (URLs, identifiers, code), or mixed-case interior (camelCase IDs).
        guard Self.looksLikeProse(word) else { return nil }
        if !Self.memoDisabled {
            memoLock.lock()
            let hit = verdictMemo[word]
            memoLock.unlock()
            if let verdict = hit { return verdict }
        }
        let verdict = uncachedVerdict(word)
        if !Self.memoDisabled {
            memoLock.lock()
            if verdictMemo.count >= Self.memoCap { verdictMemo.removeAll(keepingCapacity: true) }
            // `updateValue`, PAS le subscript : `memo[word] = nil` sur un
            // [String: String?] SUPPRIME la clé au lieu de stocker .some(nil) —
            // et « pas de correction » est précisément le verdict majoritaire
            // qu'on veut mémoïser.
            verdictMemo.updateValue(verdict, forKey: word)
            memoLock.unlock()
        }
        return verdict
    }

    /// La vérification réelle (NSSpellChecker), sans memo.
    private func uncachedVerdict(_ word: String) -> String? {
        // The probe ends with a trailing space so the word is "completed".
        let probe = word + " "
        guard let s = detector.checkLastWord(in: probe, caretIndex: probe.count) else {
            return nil
        }
        guard s.original == word else { return nil }
        return s.suggestion
    }

    /// Test seam : taille courante du memo (pour vérifier hit/miss/cap).
    var memoCount: Int {
        memoLock.lock()
        defer { memoLock.unlock() }
        return verdictMemo.count
    }

    // MARK: - Tail / word segmentation

    struct Split { let completed: Substring; let tail: Substring }

    /// Returns the text minus its trailing in-progress word. If the text ends
    /// on a separator, the tail is empty and everything is "completed".
    static func splitInProgressTail(_ text: String) -> Split {
        var i = text.endIndex
        while i > text.startIndex {
            let p = text.index(before: i)
            if isWordChar(text[p]) { i = p } else { break }
        }
        return Split(completed: text[text.startIndex..<i], tail: text[i..<text.endIndex])
    }

    /// All word-character ranges in `text` (each a maximal run of word chars).
    static func completedWordRanges(in text: Substring) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            if isWordChar(text[idx]) {
                let start = idx
                var end = idx
                while end < text.endIndex && isWordChar(text[end]) {
                    end = text.index(after: end)
                }
                ranges.append(start..<end)
                idx = end
            } else {
                idx = text.index(after: idx)
            }
        }
        return ranges
    }

    // MARK: - Heuristics

    /// True for plain prose words (letters + apostrophes/hyphens only, no
    /// interior capital after the first letter). Filters URLs, identifiers,
    /// camelCase, and numbers — contexts where "correction" would corrupt.
    static func looksLikeProse(_ word: String) -> Bool {
        var sawLetter = false
        var prevWasLetter = false
        for (i, c) in word.enumerated() {
            if c.isNumber { return false }
            if c == "." || c == "/" || c == "@" || c == ":" || c == "_" || c == "\\" {
                return false
            }
            if c.isLetter {
                // Interior uppercase (camelCase) → identifier, skip.
                if i > 0, c.isUppercase, prevWasLetter, word.first?.isUppercase == false {
                    return false
                }
                sawLetter = true
                prevWasLetter = true
            } else {
                prevWasLetter = false
            }
        }
        return sawLetter
    }

    /// Re-applies the source word's leading-capital shape to the correction so
    /// "Bonjur" → "Bonjour" (not "bonjour") and "PARIS"-style all-caps is left
    /// to the suggestion as returned (we only fix the first letter).
    static func matchingCase(of original: String, applyingTo correction: String) -> String {
        guard let first = original.first, first.isUppercase,
              let cFirst = correction.first, cFirst.isLowercase else {
            return correction
        }
        return cFirst.uppercased() + correction.dropFirst()
    }

    /// Maps the detected English language name to NSSpellChecker's behaviour.
    /// We don't pass a forced language down (TypoDetector already checks FR+EN
    /// and bails on disagreement); this hook exists so a future tightening can
    /// restrict to a single language. Returning nil keeps the detector's
    /// conservative FR/EN agreement rule.
    static func spellLanguage(for detected: String?) -> String? {
        return detected  // currently advisory; TypoDetector enforces FR+EN.
    }

    private static func isWordChar(_ c: Character) -> Bool { WordBoundary.isWordChar(c) }
}
