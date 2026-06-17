import AppKit
import Foundation
import NaturalLanguage

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
    /// `NSSpellChecker.shared` est process-wide et non-`Sendable` ; ce verrou
    /// sérialise les accès de cette instance, ce qui rend honnête le `@unchecked
    /// Sendable` (cf. conventions : autorisé seulement avec synchro interne). En
    /// pratique TypoDetector est piloté depuis MainActor, donc le verrou est non
    /// contendu (~20  ns) — il sécurise un éventuel appelant hors-MainActor sans
    /// coût mesurable sur le chemin chaud.
    private let checkerLock = NSLock()
    public static let maxLevenshtein = 2
    /// Don't flag very short typos (≤2 chars), too noisy.
    public static let minWordLength = 3

    public init() {
        // Multilingual by default — NSSpellChecker is otherwise stuck on the
        // system primary language, which means FR words get checked against the
        // EN dictionary on most installs (so "Bonjur" isn't flagged, etc.).
        checker.automaticallyIdentifiesLanguages = true
    }

    /// Exécute `body` sous le verrou du checker. Tout accès runtime à
    /// `NSSpellChecker.shared` passe par ici pour garantir la sérialisation.
    private func withChecker<T>(_ body: (NSSpellChecker) -> T) -> T {
        checkerLock.lock()
        defer { checkerLock.unlock() }
        return body(checker)
    }

    /// Check the word ending at `caretIndex` (or just before it, separated by
    /// whitespace/punctuation). Returns a suggestion if exactly one good
    /// candidate exists within Levenshtein-distance `maxLevenshtein`.
    public func checkLastWord(in text: String, caretIndex: Int) -> TypoSuggestion? {
        guard let (range, word) = Self.lastWord(in: text, before: caretIndex) else { return nil }
        guard word.count >= Self.minWordLength else { return nil }
        let contextLanguage = Self.contextLanguage(String(text.prefix(caretIndex)))
        guard let best = bestGuess(forWord: word, contextLanguage: contextLanguage),
              best != word else { return nil }
        return TypoSuggestion(original: word, suggestion: best, range: range)
    }

    /// Verdict d'UNE langue sur un mot — porte la distance du meilleur candidat
    /// même en cas d'abstention, pour que `bestGuess` puisse refuser d'adopter
    /// le candidat PLUS LOINTAIN d'une autre langue (« etait » → « eat »).
    enum LanguageVerdict: Equatable {
        /// La langue accepte le mot → pas une coquille pour elle.
        case accepted
        /// Rejeté, mais aucun guess exploitable (≤ maxLevenshtein).
        case flaggedNoCandidate
        /// Rejeté, top-2 équidistants non départagés → abstention à
        /// `bestDistance`, en gardant les ex æquo : un candidat IDENTIQUE
        /// venu d'une autre langue les départagera (accord inter-dicos).
        case flaggedAmbiguous(bestDistance: Double, tied: [String])
        case candidate(String, distance: Double)
    }

    /// La préséance de la langue du contexte vaut UNE UNITÉ d'édition pleine :
    /// un candidat étranger ne détrône le candidat (ou le plancher
    /// d'abstention) de la langue du contexte que s'il est meilleur d'au moins
    /// un edit entier. Sans cette marge, le rabais transposition (0.85) suffit
    /// à un mot anglais pour voler une correction française (« problme » →
    /// « problem » 0.85 contre « problème » 1.0).
    static let foreignWinMargin = 1.0

    /// Distance attribuée à une restitution d'accents pure (« deja » → « déjà »).
    /// Sous tout candidat réel (≥ transpositionCost) : la variante accentuée du
    /// mot tapé gagne dans sa langue ET face aux candidats des autres langues.
    static let accentRestorationDistance = 0.25

    /// Try FR then EN explicitly — `automaticallyIdentifiesLanguages` can't
    /// classify a single short word reliably and tends to default to the
    /// system primary language, missing typos in the other.
    ///
    /// Politique (revue 2026-06-11, mesurée par `SouffleuseSpellEngineEval`) :
    /// - Un mot accepté par AU MOINS une langue n'est pas corrigé (`viens` valide
    ///   FR ne doit pas devenir `views`) — SAUF l'exception diacritiques : en
    ///   contexte FRANÇAIS, si le candidat FR ne diffère du mot tapé que par ses
    ///   accents (« meme » → « même », « tres » → « très »), on corrige même si
    ///   l'anglais accepte le mot. Un mot français désaccentué n'est jamais
    ///   l'intention de l'utilisateur ; le gate contexte-français protège la
    ///   frappe anglaise (« the » ne devient pas « thé »).
    /// - La LANGUE DU CONTEXTE a préséance : son candidat gagne à distance
    ///   égale (l'ambiguïté « poubelle » de l'autre langue ne met pas de veto :
    ///   « mesage » → « message » même si l'anglais hésite) ; un candidat
    ///   étranger ne la détrône que s'il est STRICTEMENT plus proche.
    /// - Quand la langue du contexte rejette mais S'ABSTIENT (top-2
    ///   équidistants), elle pose un PLANCHER : le candidat d'une autre langue
    ///   ne gagne que s'il est STRICTEMENT plus proche. Avant, l'abstention du
    ///   français laissait l'anglais/l'allemand « corriger » du français :
    ///   « etait » → « eat », « apres » → « pares », « apelle » → « Kapelle ».
    /// - Contexte indéterminé → conservateur : tout plancher s'applique à tous.
    private func bestGuess(forWord word: String, contextLanguage: String? = nil) -> String? {
        let languages = ["fr", "en"]
        var candidates: [(cand: String, dist: Double, lang: String)] = []
        var acceptedSomewhere = false
        var floors: [String: (dist: Double, tied: [String])] = [:]
        for language in languages {
            switch verdict(forWord: word, language: language) {
            case .accepted:
                acceptedSomewhere = true
            case .flaggedNoCandidate:
                break
            case .flaggedAmbiguous(let d, let tied):
                floors[language] = (d, tied)
            case .candidate(let c, let d):
                candidates.append((c, d, language))
            }
        }
        if acceptedSomewhere {
            // Exception diacritiques (contexte français uniquement).
            guard contextLanguage == "fr",
                  let accentFix = candidates.first(where: {
                      $0.lang == "fr" && Self.isDiacriticOnlyVariant($0.cand, of: word)
                  })
            else { return nil }
            return accentFix.cand
        }
        // Toutes les langues rejettent.
        if let pref = contextLanguage {
            let own = candidates.filter { $0.lang == pref }.min { $0.dist < $1.dist }
            let foreign = candidates.filter { $0.lang != pref }.min { $0.dist < $1.dist }
            if let own {
                // Préséance du contexte : l'étranger doit gagner d'une unité
                // d'édition PLEINE — et jamais quand les deux candidats ne
                // diffèrent que par les accents (« reunion » ne bat pas
                // « réunion » en contexte français).
                if let foreign,
                   own.dist - foreign.dist >= Self.foreignWinMargin,
                   !Self.isDiacriticOnlyVariant(own.cand, of: foreign.cand) {
                    return foreign.cand
                }
                return own.cand
            }
            if let floor = floors[pref] {
                // La langue du contexte s'est abstenue sur des ex æquo. Trois
                // sorties, par ordre de confiance :
                // 1. ACCORD candidat-contre-tie : l'autre langue a un candidat
                //    CLAIR qui est l'un des ex æquo → les deux dicos votent lui.
                if let foreign,
                   let agreed = floor.tied.first(where: {
                       $0.caseInsensitiveCompare(foreign.cand) == .orderedSame
                   }) {
                    return agreed
                }
                // 2. ACCORD d'ambiguïtés : les DEUX langues hésitent, mais leurs
                //    listes d'ex æquo n'ont qu'UN candidat commun (« mesage » :
                //    fr {message, pesage, Lesage} ∩ en {message, menage,
                //    me-sage, me sage} = {message}). Capé à 4 ex æquo par
                //    langue : 5 = la totalité des guesses considérés, un tie
                //    aussi large n'a plus de signal (« wich » : with/wish/
                //    which/rich/wick tous équidistants → abstention).
                if floor.tied.count <= 4 {
                    for (lang, other) in floors where lang != pref && other.tied.count <= 4 {
                        let common = floor.tied.filter { t in
                            other.tied.contains { $0.caseInsensitiveCompare(t) == .orderedSame }
                        }
                        if common.count == 1 { return common[0] }
                    }
                }
                // 3. Sinon l'étranger doit battre le plancher d'une unité pleine.
                guard let foreign, floor.dist - foreign.dist >= Self.foreignWinMargin else { return nil }
                return foreign.cand
            }
            // La langue du contexte n'a rien proposé du tout : les candidats
            // étrangers se départagent entre eux (comportement historique).
            return Self.resolveTie(candidates)
        }
        // Contexte indéterminé : conservateur — le plancher le plus bas
        // s'applique à toutes les langues.
        let floor = floors.values.map(\.dist).min() ?? .infinity
        return Self.resolveTie(candidates.filter { $0.dist < floor })
    }

    /// Plus proche candidat ; égalité entre deux candidats DISTINCTS → nil
    /// (ambigu, on s'abstient). Extrait pour les deux branches de `bestGuess`.
    private static func resolveTie(_ candidates: [(cand: String, dist: Double, lang: String)]) -> String? {
        let scored = candidates.sorted { $0.dist < $1.dist }
        guard let first = scored.first else { return nil }
        if scored.count > 1, scored[1].dist == first.dist, scored[1].cand != first.cand {
            return nil
        }
        return first.cand
    }

    /// Verdict d'une langue : accepté / rejeté-sans-candidat / candidat clair /
    /// ambigu (avec distance). Les égalités top-2 sont d'abord départagées par
    /// la variante diacritique : si UN SEUL des ex æquo ne diffère du mot tapé
    /// que par ses accents, c'est lui (« etait » : « était » bat « étai » —
    /// l'utilisateur a tapé exactement ces lettres-là, accents en moins).
    private func verdict(forWord word: String, language: String) -> LanguageVerdict {
        let nsword = word as NSString
        let range = withChecker {
            $0.checkSpelling(
                of: word, startingAt: 0, language: language, wrap: false,
                inSpellDocumentWithTag: 0, wordCount: nil
            )
        }
        guard range.location != NSNotFound, range.length == nsword.length else {
            return .accepted  // not flagged → not a typo in this language
        }
        guard let guesses = withChecker({
            $0.guesses(
                forWordRange: NSRange(location: 0, length: nsword.length),
                in: word, language: language, inSpellDocumentWithTag: 0
            )
        }), !guesses.isEmpty else {
            return .flaggedNoCandidate
        }
        let close = guesses.prefix(5).filter { Self.levenshtein($0, word) <= Self.maxLevenshtein }
        // Restitution d'accents PRIORITAIRE : un candidat qui n'est que le mot
        // tapé avec ses accents (« deja » → « déjà ») bat tout candidat plus
        // « proche » en distance brute (« dej », d1) — chaque accent coûte
        // artificiellement 1 edit alors que taper sans accents est la norme
        // clavier. Plusieurs variantes (« apres » → après/âpres) : l'ordre des
        // guesses du checker est son prior de vraisemblance, le premier gagne.
        // Distance basse pour qu'un candidat d'une autre langue ne le détrône pas.
        if let accentFix = close.first(where: { Self.isDiacriticOnlyVariant($0, of: word) }) {
            return .candidate(accentFix, distance: Self.accentRestorationDistance)
        }
        // Rank by the typo-aware distance (transposition-preferring) rather than
        // the spell-checker's own order, so "sius" → "suis" beats "sous".
        let ranked = close.sorted { Self.typoDistance($0, word) < Self.typoDistance($1, word) }
        guard let best = ranked.first else { return .flaggedNoCandidate }
        let bestDistance = Self.typoDistance(best, word)
        // `close` (ordre des guesses NSSpell) et non `ranked` : les ex æquo
        // gardent l'ordre du checker pour l'accord inter-dictionnaires.
        let tied = close.filter { Self.typoDistance($0, word) == bestDistance }
        if Set(tied).count > 1 {
            return .flaggedAmbiguous(bestDistance: bestDistance, tied: Array(Set(tied)))
        }
        return .candidate(best, distance: bestDistance)
    }

    /// `candidate` n'est-il que `typed` avec ses accents restitués ? Comparaison
    /// insensible à la casse, pliage des diacritiques (é→e, ç→c, ô→o…).
    static func isDiacriticOnlyVariant(_ candidate: String, of typed: String) -> Bool {
        guard candidate.lowercased() != typed.lowercased() else { return false }
        let locale = Locale(identifier: "fr_FR")
        return candidate.lowercased().folding(options: .diacriticInsensitive, locale: locale)
            == typed.lowercased().folding(options: .diacriticInsensitive, locale: locale)
    }

    /// Langue dominante du contexte de frappe — `"fr"`, `"en"`, ou nil quand le
    /// texte est trop court / d'une autre langue pour être classé avec
    /// confiance (→ politique conservatrice, comportement historique). Fenêtre
    /// courte : 120 derniers chars, plancher 12 chars.
    static func contextLanguage(_ text: String) -> String? {
        let tail = String(text.suffix(120))
        guard tail.count >= 12 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(tail)
        switch recognizer.dominantLanguage {
        case .french: return "fr"
        case .english: return "en"
        default: return nil
        }
    }

    public func ignore(word: String) {
        withChecker { $0.ignoreWord(word, inSpellDocumentWithTag: 0) }
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
            let range = withChecker {
                $0.checkSpelling(
                    of: trimmed, startingAt: 0, language: language, wrap: false,
                    inSpellDocumentWithTag: 0, wordCount: nil
                )
            }
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
            let range = withChecker {
                $0.checkSpelling(
                    of: word, startingAt: 0, language: language, wrap: false,
                    inSpellDocumentWithTag: 0, wordCount: nil
                )
            }
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
