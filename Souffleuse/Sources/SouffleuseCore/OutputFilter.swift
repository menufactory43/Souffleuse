import Foundation

// MARK: - OutputFilter (pure-function namespace)

/// Pure-function helpers qui filtrent / normalisent le ghost text avant
/// affichage.
///
/// **Phase 5 (SouffleuseCore extraction)** : déplacé VERBATIM depuis
/// `ModelRuntime.OutputFilter` (target `Souffleuse`) vers la lib pure
/// `SouffleuseCore` pour que le pipeline ghost soit exerçable offline
/// (SouffleuseReplay) sans dépendre de MLX/llama. `ModelRuntime` conserve un
/// `typealias OutputFilter = SouffleuseCore.OutputFilter` afin que tous les
/// call-sites `ModelRuntime.OutputFilter.*` (app + tests) compilent inchangés.
///
/// Toutes les fonctions sont `nonisolated static` → appelables depuis
/// n'importe quel actor sans `await`, facilement testables.
public enum OutputFilter {

    /// Finds the largest suffix of `prefix` that is also a leading
    /// substring of `ghost`, and strips it. Recovers the actually-new
    /// chunk when the PT model decides to re-emit what the user just
    /// typed before continuing.
    public nonisolated static func stripPrefixOverlap(_ snapshot: String, prefix: String) -> String {
        let maxLen = min(prefix.count, snapshot.count)
        if maxLen == 0 { return snapshot }
        var len = maxLen
        while len >= 2 {
            let suffix = prefix.suffix(len)
            if snapshot.hasPrefix(suffix) {
                return String(snapshot.dropFirst(len))
            }
            len -= 1
        }
        return snapshot
    }

    /// Returns true when the START of the ghost matches the END of the
    /// prefix — i.e. the model is restating what the user just typed
    /// before (maybe) continuing.
    public nonisolated static func ghostIsRepeatingPrefix(_ ghost: String, prefix: String) -> Bool {
        let g = normalizeForRepeatCheck(String(ghost.prefix(60)))
        guard g.count >= 5 else { return false }
        let trimmed = stripTrailingPartialWord(prefix)
        let p = normalizeForRepeatCheck(String(trimmed.suffix(120)))
        var k = min(g.count, 60)
        while k >= 5 {
            let candidate = String(g.prefix(k))
            if p.hasSuffix(candidate) { return true }
            k -= 1
        }
        return false
    }

    /// True when the caret sits just after a COMPLETED sentence and the ghost
    /// merely RESTATES the opening of a recently-typed sentence — the pt base
    /// model's classic "open a new sentence by repeating the last one" echo
    /// ("Vous avez cliqué sur mon lien ? " → ghost "Vous avez"; "Capture d'écran
    /// s'il vous plait." → ghost "Capture d").
    ///
    /// Distinct from `ghostIsRepeatingPrefix`, which only catches repetition
    /// ADJACENT to the caret (a suffix of the prefix); this catches a jump BACK
    /// to a sentence start. Kept deliberately TIGHT to avoid dropping a genuine
    /// new sentence that merely shares an opener ("Je vous écris…" → "Je vous
    /// remercie…"): the ghost must be ENTIRELY a prefix of a recent sentence
    /// (pure restatement), not just share the first few words. Only fires when
    /// the caret is at a sentence boundary — mid-sentence continuations are never
    /// touched here.
    public nonisolated static func ghostEchoesRecentSentenceStart(_ ghost: String, prefix: String) -> Bool {
        // Caret must sit right after terminal punctuation (+ optional spaces):
        // only there is the model "starting a new sentence" and able to echo one.
        let trimmedPrefix = String(prefix.reversed().drop(while: { $0.isWhitespace }).reversed())
        guard let term = trimmedPrefix.last,
              term == "." || term == "?" || term == "!" || term == "…" else { return false }
        let g = normalizeForRepeatCheck(String(ghost.prefix(60)))
        guard g.count >= 5 else { return false }
        // Inspect the last few completed sentences in a bounded window.
        let window = String(trimmedPrefix.suffix(240))
        let sentences = window.split(whereSeparator: { $0 == "." || $0 == "?" || $0 == "!" || $0 == "…" })
        for seg in sentences.suffix(3) {
            let s = normalizeForRepeatCheck(String(seg))
            // Pure restatement: the entire ghost opening is a prefix of the
            // sentence (the model is re-typing that sentence, not diverging).
            if s.count >= g.count, s.hasPrefix(g) { return true }
        }
        return false
    }

    /// True once `s` contains at least one word→separator transition.
    public nonisolated static func hasCompletedFirstWord(_ s: String) -> Bool {
        var sawWord = false
        for c in s {
            if c.isLetter || c.isNumber || c == "'" || c == "’" || c == "-" {
                sawWord = true
            } else if sawWord {
                return true
            }
        }
        return false
    }

    /// Drops the trailing word characters from `s`.
    public nonisolated static func stripTrailingPartialWord(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            let c = s[prev]
            if c.isLetter || c.isNumber || c == "'" || c == "’" || c == "-" {
                end = prev
            } else {
                break
            }
        }
        return String(s[..<end])
    }

    /// Lowercases, keeps only letters/digits/space, collapses runs of
    /// non-word chars to a single space.
    public nonisolated static func normalizeForRepeatCheck(_ s: String) -> String {
        let lowered = s.lowercased()
        var out = ""
        var lastWasSpace = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Truncates `text` to at most `max` whole words, respecting the
    /// same natural break points as the LLM-stream truncation
    /// (sentence terminators, then a soft comma break, then word cap).
    public nonisolated static func capToWords(_ text: String, max: Int) -> String {
        var s = text
        if s.count > 3 {
            let hadLeadingSpace = s.first == " "
            for terminator in [". ", "? ", "! ", "… "] {
                if let r = s.range(of: terminator) {
                    var cut = String(s[..<r.upperBound]).trimmingCharacters(in: .whitespaces)
                    if hadLeadingSpace { cut = " " + cut }
                    s = cut
                    break
                }
            }
        }
        // Punctuation is KEPT inside the ghost (Cotypist parity: the user
        // wants natural, complete ghosts — "de manger, je crois", "vie de
        // manger.", "rguez ?"). We deliberately do NOT cut at the first
        // comma anymore; the sentence-terminator cut above and the word cap
        // below bound the length to one natural clause/sentence.
        let words = s.split(whereSeparator: { $0.isWhitespace })
        if words.count > max {
            // `split` drops the leading empty subsequence, so re-joining the
            // capped words loses a single LEADING space — the next-word
            // separator after a complete word ("…les balances" → " négatives …").
            // Restore it, guarded so it never double-spaces and stays inert
            // mid-word / after a space (caretAfterSpace already stripped it).
            let hadLeadingSpace = s.first == " "
            s = words.prefix(max).joined(separator: " ")
            if hadLeadingSpace, s.first != " ", !s.isEmpty { s = " " + s }
        }
        return s
    }

    /// French typography: insert a space before the double punctuation marks
    /// « ? ! ; : » when it is missing INSIDE the ghost ("…produit:" →
    /// "…produit :"). The app is French-first, so a space-less "produit:" reads
    /// wrong. Idempotent (a mark already preceded by a space is left alone).
    ///
    /// Scope is deliberately conservative — we only touch a mark whose PREVIOUS
    /// character is a LETTER (a word just ended), which by construction never
    /// fires on a ghost that *starts* with bare punctuation (no preceding char):
    /// that boundary case ("vous" + "?") depends on the upstream user text and
    /// is handled elsewhere, not here. Two further guards avoid false positives:
    /// we skip when the previous char is a digit and when the mark is
    /// immediately followed by a digit, "/", or another mark — so times
    /// ("14:30"), ratios, and URLs ("http://") are left intact.
    public nonisolated static func normalizeFrenchTypography(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let marks: Set<Character> = ["?", "!", ";", ":"]
        let chars = Array(text)
        var result = String()
        result.reserveCapacity(chars.count + 4)
        for (i, ch) in chars.enumerated() {
            if marks.contains(ch) {
                let prev = i > 0 ? chars[i - 1] : nil
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                let prevIsLetter = prev?.isLetter ?? false
                let nextBlocks = next.map { $0.isNumber || $0 == "/" || marks.contains($0) } ?? false
                if prevIsLetter && !nextBlocks {
                    result.append(" ")
                }
            }
            result.append(ch)
        }
        return result
    }

    /// Collapse a ghost suggestion to a single inline line.
    ///
    /// The corpus / `.history` fast-path can surface entries captured from
    /// prose, which carry a trailing (or embedded) newline — e.g.
    /// "achète du Bitcoin.\n". The LLM path is already one-lined in
    /// `ModelRuntime`; the instant path is not. A newline in the ghost both
    /// (1) renders the overlay one line ABOVE the caret — the panel is
    /// bottom-anchored to the caret rect, so a trailing "\n" adds a phantom
    /// line — and (2) gets injected verbatim on Tab-accept, inserting a line
    /// break (or sending the message) in chat hosts. We keep only the first
    /// non-empty physical line; leading/trailing spaces inside it are
    /// preserved (" manger" is a legitimate continuation after a word).
    public nonisolated static func singleLine(_ text: String) -> String {
        // `Character.isNewline` (not `== "\n"`) on purpose: in Swift "\r\n" is a
        // SINGLE grapheme cluster, so an explicit "\n"/"\r" comparison misses
        // CRLF endings (common in imported/web prose). `isNewline` also covers
        // U+0085, U+2028 and U+2029.
        for line in text.split(omittingEmptySubsequences: false,
                               whereSeparator: { $0.isNewline }) {
            if !line.isEmpty { return String(line) }
        }
        return ""
    }

    /// True when the filtered ghost is a *bare* enumerator / number /
    /// list-marker with no real word behind it — e.g. "1", "1.", "12)",
    /// "1er", "100%", "1/2", "-", "•", or pure punctuation.
    ///
    /// Why: in thin or list-like contexts ("Voici les étapes :\n", "- ",
    /// after a period) the instruct 1B starts a numbered list — "1. …" —
    /// and the sentence-terminator truncation chops it to "1." (and the
    /// streaming path even emits the lone "1" first token). Showing a
    /// bare ordinal as a ghost is noise, so we drop it. Crucially this
    /// only fires when nothing useful follows: "1er janvier" / "1/2 tasse
    /// de farine" carry a word and are NOT degenerate (good completions).
    public nonisolated static func isDegenerateGhost(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        // Fragmented garbage: a multi-token ghost with a lone single CONSONANT
        // token (" f i", "F or", " A p", "ferme r"). The pt base model emits
        // these when the context derails; real prose never isolates a consonant.
        if isFragmentedGhost(t) { return true }
        // Any letter present ⇒ there is a real word ⇒ not degenerate.
        if t.contains(where: { $0.isLetter }) {
            // …except a lone ordinal like "1er" / "2nd" / "3ème" / "4e".
            if t.range(of: "^\\d{1,4}(er|ère|ere|e|ème|eme|nd|nde|th|st|rd)$",
                       options: [.regularExpression, .caseInsensitive]) != nil {
                return true
            }
            return false
        }
        // No letters: lone number (opt. trailing .)°%), fraction, bullet,
        // or pure punctuation/symbols are all degenerate.
        if t.range(of: "^\\d{1,4}\\s*[.)°%]?$", options: .regularExpression) != nil { return true }
        if t.range(of: "^\\d{1,4}/\\d{1,4}$", options: .regularExpression) != nil { return true }
        if t.range(of: "^[-*•·–—]$", options: .regularExpression) != nil { return true }
        // Only punctuation / symbols / digits, no letters at all.
        if t.allSatisfy({ !$0.isLetter }) { return true }
        return false
    }

    /// True when the ghost is fragmented garbage: ≥2 whitespace tokens where at
    /// least one token is a lone single CONSONANT letter (" f i", "F or",
    /// " A p", "ferme r"). The pt base model occasionally derails into isolated
    /// single letters; a real continuation never isolates a consonant. Vowels
    /// (a/à/â/e/é/i/o/ô/u/y + accents) are NOT flagged — they can be standalone
    /// words ("a", "à", "y", "o") or a next word's first emitted char, so only
    /// consonants trip this, and only when ≥2 tokens make the isolation
    /// unambiguous (a lone single token is a normal mid-word build).
    public nonisolated static func isFragmentedGhost(_ s: String) -> Bool {
        let tokens = s.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count >= 2 else { return false }
        let vowels: Set<Character> = [
            "a", "à", "â", "ä", "e", "é", "è", "ê", "ë",
            "i", "î", "ï", "o", "ô", "ö", "u", "ù", "û", "ü", "y",
        ]
        for tok in tokens where tok.count == 1 {
            guard let ch = tok.lowercased().first, ch.isLetter else { continue }
            if !vowels.contains(ch) { return true }
        }
        return false
    }

    /// A character is a "word character" for coherence purposes when it can
    /// participate in a single word — letters, digits, and the intra-word
    /// joiners apostrophe / curly-apostrophe / hyphen. Mirrors
    /// `stripTrailingPartialWord`'s notion so the two stay consistent.
    public nonisolated static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "'" || c == "’" || c == "-"
    }

    /// Returns the in-progress partial word at the END of `userTail`: the
    /// trailing run of word-characters. Empty when the caret sits right
    /// after a space / punctuation (i.e. NOT mid-word).
    ///
    /// This is exactly the slice `stripTrailingPartialWord` removes — we
    /// expose it directly so the coherence guard can reuse the same rule.
    public nonisolated static func trailingPartialWord(_ userTail: String) -> String {
        String(userTail.dropFirst(stripTrailingPartialWord(userTail).count))
    }

    /// Leading run of word-characters of `ghost` (the part that would splice
    /// onto a mid-word partial). Empty when the ghost starts with a space /
    /// punctuation — meaning it does NOT continue the same word.
    public nonisolated static func leadingWordRun(_ ghost: String) -> String {
        var out = ""
        for c in ghost {
            if isWordChar(c) { out.append(c) } else { break }
        }
        return out
    }

    /// Leading run of LETTERS/DIGITS ONLY of `ghost` — stops at the first
    /// apostrophe, hyphen, space or punctuation. Unlike `leadingWordRun`
    /// this does NOT cross an intra-word joiner, so the spliced candidate is
    /// always a single plain word that NSSpellChecker can validate (we must
    /// not spell-check "S'il" or "aujourd'hui" across the elision boundary).
    public nonisolated static func leadingPlainRun(_ ghost: String) -> String {
        var out = ""
        for c in ghost {
            if c.isLetter || c.isNumber { out.append(c) } else { break }
        }
        return out
    }

    /// Builds the candidate word formed by splicing the mid-word ghost onto
    /// the in-progress partial word, OR nil when there is nothing to check
    /// (caret not mid-word, or ghost doesn't continue the same word).
    ///
    /// `nil` ⇒ guard does not apply (leave the ghost alone). Returned nil
    /// when: caret not mid-word, partial already contains a joiner, OR the
    /// ghost starts with a joiner (apostrophe/hyphen = new sub-word after an
    /// elision/compound boundary, "S"+"'il" → skip). A non-nil value ⇒ the
    /// caller must spell-validate it; an invalid candidate means the splice
    /// is incoherent and the ghost must be dropped.
    public nonisolated static func midWordCandidate(userTail: String, ghost: String) -> String? {
        let partial = trailingPartialWord(userTail)
        guard !partial.isEmpty else { return nil }       // caret after space/punct → not mid-word
        // Skip hyphen/apostrophe compounds & elisions — the joiner starts a
        // NEW word ("allez-vous", "j'ai", "est-ce", "aujourd'hui",
        // "rendez-vous"), so the splice is never a single dictionary word
        // and NSSpellChecker would wrongly reject a perfectly good ghost.
        // The guard targets only plain alphabetic mid-word typos ("procéd").
        guard !partial.contains(where: { $0 == "-" || $0 == "'" || $0 == "’" }) else { return nil }
        // Only validate when the ghost is a SAME-WORD continuation, i.e. it
        // starts with a letter or digit. If it starts with a joiner
        // (apostrophe / hyphen) the ghost begins a NEW sub-word after an
        // elision/compound boundary ("S"+"'il vous…", "aujourd"+"'hui") —
        // spell-checking "S'il" across that boundary would wrongly drop a
        // perfectly good ghost. Skip the guard; prefixFit already allows it.
        guard let first = ghost.first, first.isLetter || first.isNumber else { return nil }
        // Candidate uses the leading plain (letters/digits) run only, so the
        // validated word stops at any joiner the ghost might contain later.
        return partial + leadingPlainRun(ghost)
    }

    /// Instruction-text fragments the instruct 1B sometimes echoes verbatim
    /// in degenerate cases (it restates the prompt framing instead of
    /// continuing the user). A ghost containing any of these is meta-text,
    /// never a real completion → drop it. Cheap substring check, lowered.
    public nonisolated static let instructionEchoMarkers: [String] = [
        "voici le texte à continuer",
        "voici le texte a continuer",
        "texte à continuer",
        "suite du texte",
        "you are an inline autocomplete",
        "continue the user",
    ]

    /// True when the ghost echoes the prompt instruction text instead of
    /// continuing the user. Substring match, case- and accent-insensitive
    /// enough for the markers above (we lowercase only; the markers cover
    /// both accented and unaccented spellings).
    public nonisolated static func echoesInstruction(_ ghost: String) -> Bool {
        let g = ghost.lowercased()
        return instructionEchoMarkers.contains { g.contains($0) }
    }
}
