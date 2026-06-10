import Foundation
import NaturalLanguage
import SouffleuseTyping

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

    /// True quand le ghost, splicé après le préfixe, (quasi-)DUPLIQUE le ou les
    /// mots adjacents au caret — l'écho que `ghostIsRepeatingPrefix` (qui strippe
    /// le mot partiel) et `dedupLeadingRepeat` (égalité exacte) laissent passer :
    ///   « …les fraise » + « , les fraises » → « les fraise, les fraises » (écho phrase)
    ///   « …les fraises » + « fraise »        → « les fraises fraise »       (écho mot, pluriel)
    ///
    /// Précis par construction : les N derniers mots du préfixe et les N premiers
    /// du ghost doivent être QUASI-ÉGAUX (égaux, ou l'un préfixe de l'autre à ≤2
    /// chars près = le pluriel). Pour N=1 on n'attrape QUE le cas pluriel (préfixe
    /// strict, mot ≥4 chars) — l'égalité exacte d'un seul mot est soit déjà gérée
    /// par `dedupLeadingRepeat`, soit un doublon grammatical légitime (« vous vous
    /// souvenez », « nous nous »). Pour N≥2 l'écho est sans ambiguïté.
    public nonisolated static func ghostEchoesAdjacent(prefix: String, ghost: String) -> Bool {
        let pWords = normalizeForRepeatCheck(String(prefix.suffix(80)))
            .split(separator: " ").map(String.init)
        let gWords = normalizeForRepeatCheck(String(ghost.prefix(60)))
            .split(separator: " ").map(String.init)
        guard !pWords.isEmpty, !gWords.isEmpty else { return false }
        var n = min(3, pWords.count, gWords.count)
        while n >= 1 {
            let pTail = Array(pWords.suffix(n))
            let gHead = Array(gWords.prefix(n))
            if zip(pTail, gHead).allSatisfy({ Self.nearEqualWord($0, $1) }) {
                if n >= 2 { return true }
                let p = pTail[0], g = gHead[0]
                if p != g, max(p.count, g.count) >= 4 { return true }
            }
            n -= 1
        }
        return false
    }

    /// Deux mots « quasi-égaux » : identiques, ou l'un préfixe strict de l'autre
    /// à ≤2 caractères près (variation de pluriel « fraise »/« fraises »).
    private nonisolated static func nearEqualWord(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        return long.hasPrefix(short) && long.count - short.count <= 2
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
            if WordBoundary.isWordChar(s[prev]) {
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
    /// joiners apostrophe / curly-apostrophe / hyphen. Délègue à la primitive
    /// unique `WordBoundary.isWordChar` (source de vérité partagée).
    public nonisolated static func isWordChar(_ c: Character) -> Bool {
        WordBoundary.isWordChar(c)
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

    /// Number of leading `Character`s shared by `a` and `b` (both expected to be
    /// already `normalizeForRepeatCheck`-normalised). Used by the context-echo
    /// frame-head branch.
    private nonisolated static func commonPrefixCount(_ a: String, _ b: String) -> Int {
        var ia = a.startIndex
        var ib = b.startIndex
        var n = 0
        while ia < a.endIndex, ib < b.endIndex, a[ia] == b[ib] {
            ia = a.index(after: ia)
            ib = b.index(after: ib)
            n += 1
        }
        return n
    }

    /// True when the ghost reproduces the injected CONTEXT PREAMBLE — the
    /// app / window / clipboard / OCR framing prepended to the model prompt —
    /// instead of continuing the user. The PT base model does this when it has
    /// little or nothing to continue, most visibly on an empty field, where it
    /// regurgitates the opening frame ("App Signal, window …") or dumps the
    /// clipboard / OCR text. That both (1) shows generic meta-text AND (2) LEAKS
    /// clipboard / OCR content on screen, so such a ghost must be dropped.
    ///
    /// `contextPreamble` is the ACTUAL injected context block (ctxPrefix +
    /// fieldContext). It must NOT include the user's own text (customInstr /
    /// few-shot examples / beforeCursor) — only the app-supplied framing whose
    /// reproduction is meaningless and/or a leak.
    ///
    /// Two branches, both deliberately tight so a legitimate completion that
    /// merely REUSES a clipboard / OCR word mid-text is NEVER dropped (validated
    /// against the live overlay traces, 2026-05-31 — zero false positives):
    ///
    /// - **(A) Frame-head echo** (any field state): the ghost's normalised head
    ///   shares ≥ `frameHeadMinChars` leading chars with the preamble's head —
    ///   it reproduces the fixed opening frame. Self-anchored on the LIVE app
    ///   name / role label, so a real continuation that only shares a word
    ///   ("App Store est lent" → "app store…") diverges from the real header
    ///   ("app signal…") before the floor and survives. This is the dominant
    ///   production bug ("App Signal, window" shown 911×, "App Signal" 232×,
    ///   "App Brave" 8× — all 9–17 normalised chars, which a generic length
    ///   floor would miss entirely).
    /// - **(B) Empty-field dump**: ONLY when the field is (essentially) empty
    ///   (`userTail` trimmed < `emptyTailMaxChars`), the ghost's head reproduces
    ///   a ≥ `dumpMinChars` run found ANYWHERE in the preamble — the clipboard /
    ///   OCR leak. Gated on emptiness so a non-empty-field completion reusing a
    ///   context span is structurally exempt; the high floor stops a short
    ///   incidental word inside a 200-char clipboard blob from killing a legit
    ///   empty-field ghost.
    ///
    /// Thresholds default to `SuggestionPolicy.Tuning.*` (single source of truth,
    /// Pitfall 6) but are injectable so each branch is testable in isolation.
    public nonisolated static func echoesContextPreamble(
        ghost: String,
        contextPreamble: String,
        userTail: String,
        frameHeadMinChars: Int = SuggestionPolicy.Tuning.contextEchoFrameHeadMinChars,
        emptyTailMaxChars: Int = SuggestionPolicy.Tuning.contextEchoEmptyTailMaxChars,
        dumpMinChars: Int = SuggestionPolicy.Tuning.contextEchoDumpMinChars
    ) -> Bool {
        guard !ghost.isEmpty, !contextPreamble.isEmpty else { return false }
        let g = normalizeForRepeatCheck(ghost)
        let p = normalizeForRepeatCheck(contextPreamble)
        guard !g.isEmpty, !p.isEmpty else { return false }

        // (A) Frame-head echo — the ghost reproduces the opening of the context
        // block. `p` always starts with the fixed frame ("app <name> window …"
        // / "champ <role> …"), so a leading-prefix match is self-anchored on the
        // live app name and cannot collide with generic prose.
        if commonPrefixCount(g, p) >= frameHeadMinChars { return true }

        // (B) Empty-field preamble dump (clipboard / OCR leak). Containment of a
        // ghost prefix in `p` is monotonic in length, so checking the shortest
        // required prefix (`dumpMinChars`) suffices.
        let trimmedTail = userTail.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTail.count < emptyTailMaxChars, g.count >= dumpMinChars {
            let needle = String(g.prefix(dumpMinChars))
            if p.contains(needle) { return true }
        }
        return false
    }

    // MARK: - Continuation exit guards (mid-word C1)
    //
    // Gardes LOCALES appliquées à la CONTINUATION mid-mot (le segment APRÈS le
    // mot confirmé par le vote d'agreement), JAMAIS au mot lui-même. Si une garde
    // échoue, l'appelant retombe sur le mot seul (C0) — on ne perd jamais le mot.
    // Helpers purs `nonisolated static`, indépendants du chemin streaming.

    /// Seuil de recouvrement écho au-dessus duquel la continuation est jugée
    /// comme un ÉCHO de ce qui vient d'être tapé (le base model recopie la
    /// dernière phrase au lieu de continuer). Coverage des mots du ghost trouvés
    /// dans la dernière phrase du tail.
    public nonisolated static let continuationEchoThreshold: Double = 0.5

    /// Confiance min de `NLLanguageRecognizer` pour qu'un verdict de langue soit
    /// pris en compte (sinon fail-open). Aligné sur `detectLanguage` (0.5).
    public nonisolated static let languageGuardMinConfidence: Double = 0.5

    /// Longueur min (chars utiles) sous laquelle la détection de langue est trop
    /// peu fiable → fail-open (pas de mismatch). Aligné sur le périmètre V1.
    public nonisolated static let languageGuardMinChars: Int = 4

    /// Recouvrement [0,1] entre le `ghost` (la continuation) et la DERNIÈRE phrase
    /// du `tail` : fraction des mots distincts du ghost qui apparaissent déjà dans
    /// cette phrase (coverage). 1.0 = le ghost recopie intégralement ce qui vient
    /// d'être tapé ; 0.0 = aucun mot commun. Normalisation partagée avec les autres
    /// gardes d'écho (`normalizeForRepeatCheck`). Renvoie 0 si l'un des deux est vide.
    public nonisolated static func echoScore(ghost: String, tail: String) -> Double {
        let gWords = Set(normalizeForRepeatCheck(ghost).split(separator: " ").map(String.init))
        guard !gWords.isEmpty else { return 0 }
        // Dernière phrase du tail : on coupe sur la ponctuation terminale.
        let lastSentence = tail.split(whereSeparator: { $0 == "." || $0 == "?" || $0 == "!" || $0 == "…" })
            .last.map(String.init) ?? tail
        let tWords = Set(normalizeForRepeatCheck(lastSentence).split(separator: " ").map(String.init))
        guard !tWords.isEmpty else { return 0 }
        let overlap = gWords.intersection(tWords).count
        return Double(overlap) / Double(gWords.count)
    }

    /// **De-écho (couture).** Retire du `ghost` le plus long préfixe-mot qui
    /// DUPLIQUE la fin de la dernière phrase du `tail` — la zone où le modèle a
    /// recraché ce que tu venais de taper avant de (peut-être) continuer. Renvoie
    /// ce qui RESTE : vide ⇒ écho pur ; non-vide ⇒ continuation que le sac-de-mots
    /// `echoScore` condamne en bloc. Word-aware, insensible à la casse. Pur.
    public nonisolated static func deEchoRemainder(ghost: String, tail: String) -> String {
        let lastSentence = tail.split(whereSeparator: { ".?!…".contains($0) }).last.map(String.init) ?? tail
        let tailWords = lastSentence.split(separator: " ").map(String.init)
        let ghostWords = ghost.split(separator: " ").map(String.init)
        guard !ghostWords.isEmpty, !tailWords.isEmpty else { return ghost }
        var bestK = 0
        for k in 1...min(ghostWords.count, tailWords.count) {
            if ghostWords.prefix(k).map({ $0.lowercased() }) == tailWords.suffix(k).map({ $0.lowercased() }) {
                bestK = k
            }
        }
        guard bestK > 0 else { return ghost }
        return ghostWords.dropFirst(bestK).joined(separator: " ")
    }

    /// **Discriminateur d'écho POSITIONNEL.** Longueur (en mots) du plus long
    /// segment CONTIGU du `ghost` qui apparaît VERBATIM dans le `tail`. Distingue
    /// une vraie boucle (le modèle recrache un long bout de phrase tel quel →
    /// run long) d'une simple réutilisation de vocabulaire (« le serveur » réutilisé
    /// dans une suite neuve → run court). Là où `echoScore` (sac de mots) confond
    /// les deux, ce run sépare : un seuil (~4 mots) ne gate que les vraies
    /// répétitions verbatim. Insensible à la casse. Pur/testable.
    public nonisolated static func longestVerbatimRunWords(ghost: String, tail: String) -> Int {
        let g = ghost.split(separator: " ").map { $0.lowercased() }
        let t = tail.split(separator: " ").map { $0.lowercased() }
        guard !g.isEmpty, !t.isEmpty else { return 0 }
        var best = 0
        for i in 0..<g.count {
            for j in 0..<t.count where t[j] == g[i] {
                var run = 0
                while i + run < g.count, j + run < t.count, g[i + run] == t[j + run] { run += 1 }
                if run > best { best = run }
            }
        }
        return best
    }

    /// **De-écho « malin ».** Comme `deEchoRemainder`, mais coupe AUSSI le reste à
    /// la première frontière de clause (`. ? ! ; :` ou retour ligne) — pour ne
    /// garder que la VRAIE suite avant que le modèle ne reboucle sur ta phrase
    /// (« et de la science. Je suis un fan… » → « et de la science »). Si le reste
    /// n'a pas de frontière, il est renvoyé tel quel. Pur.
    public nonisolated static func smartDeEcho(ghost: String, tail: String) -> String {
        let rem = deEchoRemainder(ghost: ghost, tail: tail)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rem.isEmpty else { return rem }
        if let idx = rem.firstIndex(where: { ".?!;:\n".contains($0) }) {
            return String(rem[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return rem
    }

    /// True quand la langue détectée du `ghost` DIFFÈRE de `expected` (le base
    /// model a dérapé dans une autre langue). Fail-open (false) si le ghost est
    /// trop court (`< languageGuardMinChars`), si la confiance est sous le seuil,
    /// ou si `expected` est vide/inconnu — on ne bloque que sur un mismatch CLAIR.
    /// `expected` est un code `NaturalLanguage` (`"fr"`, `"en"`, …). Pur, on-device.
    public nonisolated static func languageMismatch(ghost: String, expected: String?) -> Bool {
        guard let expected, !expected.isEmpty else { return false }
        let trimmed = ghost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= languageGuardMinChars else { return false }   // fail-open
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let lang = recognizer.dominantLanguage else { return false }
        if let confidence = recognizer.languageHypotheses(withMaximum: 1)[lang],
           confidence < languageGuardMinConfidence {
            return false   // pas assez sûr → fail-open
        }
        return lang.rawValue != expected
    }
}
