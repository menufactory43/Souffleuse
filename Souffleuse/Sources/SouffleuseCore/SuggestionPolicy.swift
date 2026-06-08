import Foundation
import SouffleuseLog
import SouffleuseCorpus
import SouffleuseTyping

/// Phase 4 — Cascade Quality + Architecture.
///
/// Ce fichier est la cible des décisions D-03 (frontière de module) et
/// D-05..D-13 (Ghost Relevance Gate + scoring de confiance + classification
/// grid). Le plan 04-01 introduit ICI la fondation pure-function du Gate :
///
/// 1. `enum SuggestionSource` — migration verbatim depuis
///    `PredictorViewModel.SuggestionSource` (D-02). Le nom devient global ;
///    tous les call-sites PVM continuent de compiler via inférence.
/// 2. `struct Score` — scalar [0,1] = `sourcePrior * prefixFit * lengthFit`
///    (D-06). `passesGate` / `beats(_:)` consomment les constantes vivant
///    dans `SuggestionPolicy+Tuning.swift` (D-13).
/// 3. `enum SuggestionPolicy` namespace — abrite les pure-function helpers
///    `score(source:ghost:userTail:)`, `prefixFit(...)`, `lengthFit(...)`.
///
/// Le plan 04-02 introduira un `@MainActor final class SuggestionPolicyEngine`
/// séparé (state-bearing). Le namespace `enum SuggestionPolicy` reste ici
/// dédié aux pure-function helpers : aucun état, aucun `@MainActor`, aucun
/// `Log.*` call. Cela permet de tester chaque facteur du score sans toucher
/// au runtime MLX ni à AppKit.
///
/// **Privacy invariant (audit.sh §6) :** ce fichier n'émet aucun log et
/// n'accède à aucune source de contexte user (typing history, clipboard,
/// AX) — surface privacy nulle.

// MARK: - SuggestionSource (Phase 4 D-03 — moved from PredictorViewModel)

/// Provenance de la suggestion ghost courante. Drives :
/// - l'anti-churn rule du LLM `onChunk` (PVM legacy)
/// - les `sourcePrior` du Ghost Relevance Gate (D-06)
/// - le routing mid-word vs after-space (D-08)
///
/// Le nom est canonique cross-module. Migration verbatim depuis
/// `PredictorViewModel.SuggestionSource` (PVM L101-108 pre-Phase-4).
public enum SuggestionSource: Sendable {
    case none           // suggestion is "" or stale
    case wordComplete   // Layer 0 — NSSpellChecker
    case learnedWord    // Layer 0 — LearnedLexicon (user's distinctive terms)
    case history        // Layer 1 — TypingHistoryStore match
    case cache          // predictCache hit (previous LLM result)
    case undoCache      // undo-as-ghost restoration
    case llm            // currently streaming from the active LLM Task
}

// MARK: - Score

/// Scalar [0,1] qui résume la pertinence d'un ghost candidat (D-06).
///
/// Formule : `value = sourcePrior * prefixFit * lengthFit`.
/// - `sourcePrior` ∈ [0,1] — confiance de la source (history > LLM > word-complete).
/// - `prefixFit`   ∈ {0, 1} — le ghost s'enchaîne-t-il proprement avec ce que le user tape ?
/// - `lengthFit`   ∈ [0,1] — bell curve centrée 2-5 mots ; pénalise extrêmes.
///
/// Le triplet est conservé pour pouvoir logger les composants séparément
/// (audit-safe : juste des `count: Int` scaled).
public struct Score: Sendable, Equatable, CustomStringConvertible {
    public let sourcePrior: Float
    public let prefixFit: Float
    public let lengthFit: Float

    public init(sourcePrior: Float, prefixFit: Float, lengthFit: Float) {
        self.sourcePrior = sourcePrior
        self.prefixFit = prefixFit
        self.lengthFit = lengthFit
    }

    /// Produit des trois facteurs. Toujours dans [0,1] tant que les facteurs y sont.
    public var value: Float { sourcePrior * prefixFit * lengthFit }

    /// D-07 hard floor : sous ce seuil le ghost est rejeté sans affichage.
    public var passesGate: Bool { value >= SuggestionPolicy.Tuning.gateFloor }

    /// D-07 replacement bar : un nouveau ghost doit battre le score courant
    /// d'un facteur `Tuning.replacementBar` pour le supplanter. Évite le
    /// churn (régression de la session 2026-05-25, commits 2b6b6be..7316a8c).
    /// L'égalité stricte est volontairement insuffisante : `a.beats(a) == false`
    /// quand `value == 0` ; sinon `value >= value * 1.15` est false.
    public func beats(_ other: Score) -> Bool {
        value >= other.value * SuggestionPolicy.Tuning.replacementBar
    }

    public var description: String {
        "Score(src=\(sourcePrior) pref=\(prefixFit) len=\(lengthFit) → \(value))"
    }
}

// MARK: - SuggestionPolicy namespace (pure-function helpers)

/// Namespace pour les pure-function helpers du Ghost Relevance Gate.
/// Tous les seuils consommés ici vivent dans `SuggestionPolicy+Tuning.swift`
/// (Pitfall 6 — aucun littéral autorisé ailleurs).
public enum SuggestionPolicy {

    /// Calcule le `Score` complet pour un ghost candidat (D-06).
    ///
    /// Pure function : `(source, ghost, userTail) → Score`. Aucun effet de bord.
    /// Le caller (PVM ou le futur `SuggestionPolicyEngine`) compose `passesGate`
    /// et `beats(_:)` au-dessus pour décider d'afficher/replacer.
    public static func score(source: SuggestionSource, ghost: String, userTail: String) -> Score {
        Score(
            sourcePrior: Tuning.sourcePrior[source] ?? 0.0,
            prefixFit: Self.prefixFit(ghost: ghost, userTail: userTail),
            lengthFit: Self.lengthFit(ghost: ghost)
        )
    }

    /// `TypoDetector` partagé (process-wide) servant à valider le mot partiel
    /// en cours quand on doit décider si une continuation next-word (espace/
    /// ponctuation après une lettre) est légitime. `NSSpellChecker` est
    /// thread-safe pour la lecture et `TypoDetector` est `@unchecked Sendable`.
    /// On l'instancie une fois pour éviter de reconstruire le checker à chaque
    /// scoring (le scoring tourne sur le `@MainActor` onChunk / routeInstant).
    private static let sharedTypoDetector = TypoDetector()

    /// Reconstructs the continuous text of a history entry from its stored
    /// `contextBefore` + `accepted`, optionally honouring a persisted
    /// `midWordContinuation` flag.
    ///
    /// When `midWordContinuation` is non-nil the boundary intent is known and
    /// the flag is used directly — no dictionary guessing:
    ///   - `true`  → glue verbatim (contextBefore + accepted)
    ///   - `false` → insert a space (contextBefore + " " + accepted)
    ///
    /// When `midWordContinuation` is nil the original heuristic applies (see
    /// the 2-arg overload). Existing-separator fast-paths still apply for both
    /// flagged and nil cases so a separator can never be doubled.
    ///
    /// The 2-arg overload delegates to `midWordContinuation: nil` and keeps
    /// every existing HistoryJoinTests case passing unchanged.
    public nonisolated static func joinHistory(
        _ contextBefore: String,
        _ accepted: String,
        midWordContinuation: Bool?
    ) -> String {
        guard !contextBefore.isEmpty else { return accepted }
        guard let cb = contextBefore.last, let af = accepted.first else {
            return contextBefore + accepted
        }
        // Boundary already carries a separator → concat verbatim regardless of flag.
        // This guards against double spaces ("les frais " + "de port", flag=false).
        if cb.isWhitespace || af.isWhitespace { return contextBefore + accepted }

        // Non-nil flag: use it directly.
        if let flag = midWordContinuation {
            return flag ? contextBefore + accepted : contextBefore + " " + accepted
        }

        // nil → original dictionary heuristic (unchanged).
        // An uppercase start is a new word / proper noun, never a mid-word
        // continuation ("Bonjour" + "Madame", not "BonjourMadame") → space.
        if af.isUppercase { return contextBefore + " " + accepted }
        // Letter/number on both sides: ambiguous (mid-word vs next-word). Decide
        // with the dictionary on the merged boundary word.
        if (cb.isLetter || cb.isNumber) && (af.isLetter || af.isNumber) {
            let lastWord = OutputFilter.trailingPartialWord(contextBefore)
            let headWord = OutputFilter.leadingWordRun(accepted)
            let merged = lastWord + headWord
            if !merged.isEmpty, sharedTypoDetector.isValidWord(merged, language: nil) {
                return contextBefore + accepted          // mid-word → glue
            }
            return contextBefore + " " + accepted        // next-word → space
        }
        // Punctuation boundary (".", "?", …) before a new word → space reads
        // naturally ("corrigé." + "Bonjour" → "corrigé. Bonjour").
        return contextBefore + " " + accepted
    }

    /// 2-arg overload: delegates to the flag overload with `midWordContinuation: nil`
    /// (dictionary heuristic). All existing call sites continue to work unchanged.
    public nonisolated static func joinHistory(_ contextBefore: String, _ accepted: String) -> String {
        joinHistory(contextBefore, accepted, midWordContinuation: nil)
    }

    /// Le mot partiel en fin de `userTail` est-il un mot COMPLET/valide ?
    /// Réutilise `ModelRuntime.OutputFilter.trailingPartialWord` (même notion
    /// que le coherence guard mid-word) puis `TypoDetector.isValidWord`.
    /// Permissif FR+EN. Vide ⇒ pas mid-word ⇒ false (caller ne l'appelle pas).
    public nonisolated static func defaultPartialWordIsComplete(_ userTail: String) -> Bool {
        let partial = OutputFilter.trailingPartialWord(userTail)
        guard !partial.isEmpty else { return false }
        return sharedTypoDetector.isValidWord(partial, language: nil)
    }

    /// Token-healing admit predicate (Task 2). When the caret is mid-word inside
    /// `partial` and the engine's healed chunk's leading plain run COMPLETES that
    /// word, `partial + leadingPlainRun(chunk)` forms a single candidate word —
    /// e.g. "fis"+"cal" = "fiscal", "impe"+"rméable" = "imperméable". Returns
    /// true iff that merged word is a valid FR/EN dictionary word AND the chunk
    /// is letter/digit-led (it genuinely continues the same word, not a next-word
    /// space/punct jump or an apostrophe/hyphen sub-word boundary). Wraps the
    /// `private` shared `TypoDetector` so `SuggestionPolicyEngine` can reuse it.
    public nonisolated static func healingMidWordAdmits(partial: String, chunk: String) -> Bool {
        guard let first = chunk.first, first.isLetter || first.isNumber else { return false }
        let merged = partial + OutputFilter.leadingPlainRun(chunk)
        guard !merged.isEmpty else { return false }
        return sharedTypoDetector.isValidWord(merged, language: nil)
    }

    /// D-06 prefix_fit : le ghost s'enchaîne-t-il avec `userTail` ?
    ///
    /// - **Mid-word** (`userTail.last?.isLetter == true`) :
    ///   - 1.0 si `ghost` commence par une lettre (complète le mot courant) OU
    ///     par un joiner intra-mot — apostrophe `'`, apostrophe courbe `’`, ou
    ///     trait d'union `-` (élision/composé : "S'il", "j'ai", "aujourd'hui",
    ///     "est-ce", "allez-vous").
    ///   - 1.0 si `ghost` commence par une espace (non-newline) ou une
    ///     ponctuation (`,` `.` `!` `?` `;` `:`) — c'est une continuation
    ///     NEXT-WORD légitime — MAIS seulement si le mot partiel en cours
    ///     ("frais", "chocolat") est lui-même un mot COMPLET/valide
    ///     (`partialWordIsComplete`). Sinon ("Bonj") on refuse : le modèle ne
    ///     doit pas abandonner un mot à moitié tapé. Le caractère réel de
    ///     continuation (après l'espace de tête) doit rester naturel — newline
    ///     et markdown (`#`, `*`, `_`, `~`) restent rejetés.
    ///   - 0.0 sinon.
    /// - **After-space ou empty tail** : 1.0 si `ghost.first` est letter, digit,
    ///   `'` ou `"` (natural continuation) ; 0.0 si commence par whitespace,
    ///   newline, ou un délimiteur markdown (`#`, `*`, `_`, `~`) — le LLM ne
    ///   doit pas insérer de syntaxe.
    /// - Tout autre cas (userTail termine sur ponctuation non-whitespace) : 0.0.
    ///
    /// `partialWordIsComplete` est injecté pour garder la fonction testable sans
    /// `NSSpellChecker` ; par défaut il délègue à `defaultPartialWordIsComplete`.
    public nonisolated static func prefixFit(
        ghost: String,
        userTail: String,
        partialWordIsComplete: ((String) -> Bool)? = nil
    ) -> Float {
        guard let g = ghost.first else { return 0.0 }
        if let tail = userTail.last {
            if tail.isLetter {
                // Mid-word : on attend la suite du mot. Le ghost est une
                // continuation valide s'il commence par une lettre OU par un
                // joiner intra-mot (apostrophe droite/courbe, trait d'union) :
                // "S"→"'il vous plaît", "allez"→"-vous", "aujourd"→"'hui".
                if g.isLetter { return 1.0 }
                if g == "'" || g == "’" || g == "-" { return 1.0 }
                // Espace/ponctuation mid-word ⇒ NEXT-WORD continuation. Légitime
                // UNIQUEMENT si le mot partiel courant est déjà un mot complet
                // ("frais"→" de port", "chocolat"→", mais"). On rejette si le mot
                // est incomplet ("Bonj"→" mot") pour ne pas abandonner un mot
                // à moitié tapé. Newline & markdown toujours rejetés.
                if Self.isNextWordContinuationStart(g) {
                    let validator = partialWordIsComplete ?? Self.defaultPartialWordIsComplete
                    return validator(userTail) ? 1.0 : 0.0
                }
                return 0.0
            }
            if tail.isWhitespace {
                // After-space : on attend un mot nouveau ⇒ pas de whitespace/markdown.
                return Self.isNaturalContinuationStart(g) ? 1.0 : 0.0
            }
            // Tail = chiffre OU ponctuation NON-whitespace (`.`, `,`, `!`, `(`, `%`…).
            // Frontière CHIFFRE / PONCTUATION NON-TERMINALE ("…1933"→", il écrit",
            // "…4500"→" euros", "…(2086)"→" merci") : le base model enchaîne
            // naturellement par une espace ou une ponctuation de clause. On élargit
            // donc la tolérance à `isNextWordContinuationStart` (espace + `, . ! ? ; :`),
            // en plus du natural-start letter/digit/quote. Purement additif : ne peut
            // que laisser passer PLUS à ces frontières, jamais bloquer davantage.
            //
            // EXCEPTION — terminateur de phrase (`.`, `!`, `?`, `…`) : on garde le
            // comportement STRICT (natural-start seul). C'est une frontière de phrase
            // délibérément reportée (débat veto/tailOnly) ; on ne l'ouvre pas ici.
            if Self.sentenceTerminators.contains(tail) {
                return Self.isNaturalContinuationStart(g) ? 1.0 : 0.0
            }
            return (Self.isNaturalContinuationStart(g) || Self.isNextWordContinuationStart(g)) ? 1.0 : 0.0
        }
        // userTail vide ⇒ comme after-space.
        return Self.isNaturalContinuationStart(g) ? 1.0 : 0.0
    }

    /// D-06 length_fit : bell curve sur le nombre de mots du ghost.
    /// Table `Tuning.lengthFitByWordCount` ; clamp à la dernière entrée pour ≥10.
    public nonisolated static func lengthFit(ghost: String) -> Float {
        let wordCount = ghost.split(whereSeparator: { $0.isWhitespace }).count
        let table = Tuning.lengthFitByWordCount
        guard !table.isEmpty else { return 0.0 }
        let index = min(wordCount, table.count - 1)
        return table[index]
    }

    // MARK: - Private helpers

    /// Terminateurs de phrase : à ces frontières (`.`, `!`, `?`, `…`) `prefixFit`
    /// reste STRICT (natural-start letter/digit/quote seul) — la tolérance next-word
    /// (espace + ponctuation de clause) n'y est PAS ouverte. Front frontière-de-phrase
    /// délibérément reporté ; toute autre frontière chiffre/ponctuation l'obtient.
    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "…"]

    /// Un caractère est-il un démarrage "naturel" de continuation après espace ?
    /// Letter / digit / quote. Pas de whitespace, pas de markdown (`# * _ ~`),
    /// pas de newline (déjà couvert par isWhitespace mais explicité).
    private static func isNaturalContinuationStart(_ c: Character) -> Bool {
        if c.isWhitespace || c.isNewline { return false }
        // Markdown syntax tokens — refuser pour ne pas pousser un format inattendu.
        if c == "#" || c == "*" || c == "_" || c == "~" { return false }
        if c.isLetter || c.isNumber { return true }
        if c == "'" || c == "\"" { return true }
        return false
    }

    /// Démarrage valide d'une continuation NEXT-WORD après un mot COMPLET tapé
    /// (le user vient de finir un mot, sans espace de fin encore). Le modèle base
    /// continue typiquement par " mot suivant" (espace de tête) ou par une
    /// ponctuation (", mais…", ". Mais…"). On accepte :
    /// - une espace ORDINAIRE de tête (tab/space, PAS un newline) — un nouveau
    ///   mot va suivre ; un éventuel markdown derrière reste improbable et sera
    ///   de toute façon coupé en aval ;
    /// - une ponctuation de clause courante (`,` `.` `!` `?` `;` `:`).
    /// On refuse explicitement : newline (le ghost ne doit pas casser la ligne)
    /// et les tokens markdown (`#`, `*`, `_`, `~`).
    private static func isNextWordContinuationStart(_ c: Character) -> Bool {
        if c.isNewline { return false }
        if c == "#" || c == "*" || c == "_" || c == "~" { return false }
        if c.isWhitespace { return true }
        if c == "," || c == "." || c == "!" || c == "?" || c == ";" || c == ":" {
            return true
        }
        return false
    }

    // MARK: - Static helpers migrated verbatim from PVM (Plan 04-02)

    /// Instant Ghost Path Layer 1 — exact-substring match against typing
    /// history. Migration verbatim depuis PVM:1520-1545 (pre-Phase-4).
    ///
    /// Returns the saved continuation when the user's recent tail matches
    /// an entry's body. Nil when the lookback is too short (<6 chars) or
    /// ends on whitespace (next-word predicate too wide for exact-match).
    public nonisolated static func historyExactSubstringMatch(
        userTail: String,
        snapshot: [TypingHistoryEntry]
    ) -> String? {
        let lookback = String(userTail.suffix(40))
        guard lookback.count >= 6 else { return nil }
        if lookback.last?.isWhitespace == true { return nil }
        for entry in snapshot {
            let full = joinHistory(entry.contextBefore, entry.accepted,
                                   midWordContinuation: entry.midWordContinuation)
            if let r = full.range(of: lookback) {
                let after = full[r.upperBound...]
                let trimmed = String(after)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    /// Phase 3 (b) — Cotypist "short" fast-path : a STRONG corpus match.
    ///
    /// Upgrades the linear exact-substring scan (`historyExactSubstringMatch`)
    /// into a confidence-bearing match. Returns the saved continuation AND the
    /// length of the matched context (in characters) when the user's recent
    /// tail matches a corpus entry by at least `strongCorpusMatchMinChars`
    /// characters — long enough that we trust it as a direct ghost without any
    /// LLM inference. Picks the match with the LONGEST overlap (most specific),
    /// freshness breaking ties (snapshot is newest-first).
    ///
    /// Nil when no entry overlaps by the threshold. Unlike
    /// `historyExactSubstringMatch` this does NOT bail on whitespace-terminated
    /// tails — an after-space context is exactly where Cotypist's instant
    /// completion fires. The match must still be word-aligned (the overlap ends
    /// at the user's caret, and the continuation is the entry's remainder).
    public nonisolated static func strongCorpusMatch(
        userTail: String,
        snapshot: [TypingHistoryEntry],
        minChars: Int = Tuning.strongCorpusMatchMinCharsRuntime
    ) -> (continuation: String, matchedChars: Int)? {
        // Look back over a generous window; the longest suffix of userTail that
        // is also a substring of some entry (ending the entry's recorded text
        // BEFORE its tail) wins.
        let lookbackFull = String(userTail.suffix(120))
        guard lookbackFull.count >= minChars else { return nil }

        var best: (continuation: String, matchedChars: Int)?
        for entry in snapshot {
            let full = joinHistory(entry.contextBefore, entry.accepted,
                                   midWordContinuation: entry.midWordContinuation)
            // Find the longest suffix of the user tail that occurs in `full`
            // and leaves a non-empty continuation after it.
            var len = min(lookbackFull.count, full.count)
            while len >= minChars {
                let needle = String(lookbackFull.suffix(len))
                if let r = full.range(of: needle) {
                    let after = String(full[r.upperBound...])
                    if !after.isEmpty {
                        if best == nil || len > best!.matchedChars {
                            best = (after, len)
                        }
                        break  // longest for THIS entry found
                    }
                }
                len -= 1
            }
        }
        return best
    }

    /// Truncates `text` to at most `max` whole words, respecting natural
    /// break points (sentence terminators, soft comma break, word cap).
    /// Migration verbatim depuis PVM:411-429 (pre-Phase-4).
    public nonisolated static func capToWords(_ text: String, max: Int) -> String {
        var s = text
        if s.count > 3 {
            // Preserve a single leading space so a next-word continuation keeps
            // its separator ("…frais" → " de port" renders "frais de port").
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
        if s.count > 12, let r = s.range(of: ", ") {
            s = String(s[..<r.lowerBound])
        }
        let words = s.split(whereSeparator: { $0.isWhitespace })
        if words.count > max {
            // `split` drops the leading empty subsequence, so re-joining the
            // capped words loses a single LEADING space — the next-word
            // separator a corpus recall after a complete word carries
            // ("…les balances" → " négatives …"). Restore it, guarded so it
            // never double-spaces and stays inert mid-word / after a space.
            let hadLeadingSpace = s.first == " "
            s = words.prefix(max).joined(separator: " ")
            if hadLeadingSpace, s.first != " ", !s.isEmpty { s = " " + s }
        }
        return s
    }

    /// Recall quality-gate (Task 4). True when a corpus continuation (already
    /// `capToWords`-trimmed) is CLEARLY broken: its final word is an incomplete
    /// fragment AND the continuation is not sentence-terminated. This catches a
    /// stored phrase that was itself truncated mid-word ("… il est indiqué s'ils
    /// report") so the unbeatable `strongCorpusSourcePrior` cannot pin a bad
    /// recall in place and pre-empt a better LLM generation.
    ///
    /// Conservative on purpose — only reject when the LAST token is a non-trivial
    /// letter-led fragment that NSSpellChecker does not recognise. We keep clean
    /// recalls (last word is a real word, or the continuation ends in sentence
    /// punctuation) so the corpus fast-path speed win is preserved.
    public nonisolated static func corpusContinuationIsLowQuality(_ continuation: String) -> Bool {
        let trimmed = continuation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Sentence-terminated / clause-closed continuations are deliberate stops,
        // never truncation artefacts.
        if let last = trimmed.last,
           last == "." || last == "?" || last == "!" || last == "…"
            || last == "," || last == ";" || last == ":" || last == ")"
            || last == "»" || last == "\"" {
            return false
        }
        // Inspect the trailing word (mirrors `trailingPartialWord`'s notion).
        let lastWord = OutputFilter.trailingPartialWord(trimmed)
        guard !lastWord.isEmpty else { return false }
        // Apostrophe/hyphen compounds ("s'ils", "rendez-vous") would be wrongly
        // rejected by a single-word spell check — leave them alone (conservative).
        if lastWord.contains(where: { $0 == "'" || $0 == "’" || $0 == "-" }) {
            return false
        }
        // Pure-digit / very short tails are not the truncation case we target.
        guard lastWord.count >= 3, lastWord.contains(where: { $0.isLetter }) else {
            return false
        }
        // Broken iff the trailing word is not a valid dictionary word.
        return !sharedTypoDetector.isValidWord(lastWord, language: nil)
    }

    /// True when the current ghost is a corpus MICRO-completion: a MID-WORD
    /// (letter/digit tail) recall whose leading word-run commits only 1–2
    /// letters/digits of the word the user is still typing ("c" completing
    /// "fis", "9" completing "2024", "'a" completing "qu"). The corpus cannot
    /// know WHICH longer word the user means, so this is a low-confidence
    /// instant placeholder that must YIELD to a coherent, gate-passing LLM
    /// completion of the whole word — see `onLLMChunk`. It is restricted to the
    /// mid-word case on purpose: an AFTER-SPACE short recall ("…lu mon " → "CV")
    /// can be HIGH-confidence (many chars of re-entered context matched), so it
    /// keeps the unbeatable strong prior and the anti-churn replacement bar.
    public nonisolated static func isMicroCorpusCompletion(ghost: String, userTail: String) -> Bool {
        guard let last = userTail.last, last.isLetter || last.isNumber else { return false }
        let committed = OutputFilter.leadingWordRun(ghost)
            .filter { $0.isLetter || $0.isNumber }.count
        return committed >= 1 && committed < Tuning.corpusMicroCompletionMaxChars
    }

    // MARK: - Mid-word escalation (Frame C — décision pure, étage 1)
    //
    // Pure-functions du gate mid-mot incomplet (le cas qui fait aujourd'hui
    // `midword_block`). Aucun effet de bord, aucun MLX : le caller (ModelRuntime
    // en F1) fournit le mot greedy déjà extrait + sa confiance top-1, on rend la
    // décision. Validé hors-ligne via `SouffleuseMidwordEval`.

    /// Mot complet en tête d'une sortie greedy/healed : on dépose un éventuel
    /// espace de tête (la sortie healed démarre souvent par " mot") puis on prend
    /// le run de mot. Vide ⇒ la sortie saute au mot suivant (espace/ponctuation),
    /// ce n'est donc pas une complétion du mot courant.
    public nonisolated static func midWordLeadWord(_ rawGhost: String) -> String {
        let trimmed = rawGhost.drop(while: { $0 == " " })
        return OutputFilter.leadingWordRun(String(trimmed))
    }

    /// Le mot `modal` prolonge-t-il le partiel tapé ET est-il un vrai mot du dico ?
    /// Attrape les échecs de healing : "a" ne prolonge pas "aspira", "pingo" ≠
    /// "pingou", "i" ≠ "imposa" — tous rejetés avant affichage.
    public nonisolated static func midWordValidExtends(partial: String, modal: String) -> Bool {
        guard !modal.isEmpty, modal.lowercased().hasPrefix(partial.lowercased()) else { return false }
        return defaultPartialWordIsComplete(modal)
    }

    /// Garde STRUCTURELLE (sans dico) : le mot de tête prolonge-t-il *réellement* le
    /// partiel ? `hasPrefix(partial)` + strictement plus long. Attrape les échecs de
    /// healing — "i"/"pingo"/"a"/"s" ne commencent pas par le partiel — SANS rejeter
    /// les OOV légitimes (marques "Waltio"/"Binance", noms propres, anglais, jargon)
    /// que le verdict dico de `midWordValidExtends` recalerait à tort. Le code
    /// avertit déjà qu'on ne peut PAS se fier au dico ici (ModelRuntime, splice).
    /// Les devinettes valides-mais-fausses ("peinardes") restent gérées par l'accord
    /// des branches (PLEIN vs PRUDENT), pas par cette garde.
    public nonisolated static func midWordExtendsStructurally(partial: String, modal: String) -> Bool {
        guard !modal.isEmpty, modal.count > partial.count else { return false }
        return modal.lowercased().hasPrefix(partial.lowercased())
    }

    /// Mot de tête **dé-fragmenté**. Le 1B éclate parfois un mot par des espaces
    /// (« caca huète », « pingo u is »). `midWordLeadWord` s'arrêterait au 1ᵉʳ
    /// espace (« caca »), ratant le mot réel. Ici, si le run de tête simple ne
    /// prolonge pas déjà le partiel, on collapse les morceaux-mots contigus
    /// séparés par UN seul espace et on retient le PLUS PETIT collapse qui forme
    /// un vrai mot du dico prolongeant le partiel.
    ///
    /// **Sûr par construction** : la garde dico empêche de fusionner deux mots
    /// distincts — « je vais » → « jevais » invalide → on retombe sur le run
    /// simple (rejeté en aval) ; « caca huète » → « cacahuète » valide → accepté ;
    /// « pingo u is » → « pingou »/« pingouis » invalides → rejeté.
    public nonisolated static func midWordLeadWordDefrag(_ rawGhost: String, partial: String) -> String {
        let trimmed = rawGhost.drop(while: { $0 == " " })
        let plain = OutputFilter.leadingWordRun(String(trimmed))
        // Run simple suffisant (sortie non fragmentée) ⇒ rien à faire.
        if midWordValidExtends(partial: partial, modal: plain) { return plain }
        // Collecte des morceaux-mots contigus séparés par un seul espace (cap à 4).
        var pieces: [String] = []
        var rest = trimmed
        while pieces.count < 4 {
            let run = OutputFilter.leadingWordRun(String(rest))
            guard !run.isEmpty else { break }
            pieces.append(run)
            rest = rest.dropFirst(run.count)
            guard rest.first == " " else { break }
            rest = rest.dropFirst()
            guard rest.first?.isLetter == true else { break }
        }
        guard pieces.count >= 2 else { return plain }
        for n in 2...pieces.count {
            let merged = pieces[0..<n].joined()
            if midWordValidExtends(partial: partial, modal: merged) { return merged }
        }
        return plain
    }

    /// Verdict de l'étage 1 (greedy + dico), sans branche.
    /// - `.fastReject`  : mot fusionné invalide / ne prolonge pas → cacher (échec healing).
    /// - `.fastAccept`  : valide + prolonge + confiant + fragment assez long → montrer le greedy.
    /// - `.uncertain`   : valide mais peu confiant / fragment court → zone à brancher (F2).
    ///   En F1, `.uncertain` retombe sur « rien » (= comportement `midword_block` actuel).
    public enum MidWordFastDecision: Sendable, Equatable {
        case fastAccept(word: String)
        case fastReject
        case uncertain
    }

    public nonisolated static func midWordFastDecision(
        partial: String, greedyModal: String, firstTokenProb: Double?
    ) -> MidWordFastDecision {
        if !midWordValidExtends(partial: partial, modal: greedyModal) { return .fastReject }
        if (firstTokenProb ?? 0) >= Tuning.escFastP1, partial.count >= Tuning.escMinFastLen {
            return .fastAccept(word: greedyModal)
        }
        return .uncertain
    }

    /// **F2 — décision sur l'accord inter-branches.** Tranche la zone `.uncertain`
    /// (mot valide mais P1 bas, ou fragment court) que l'étage 1 cache. Le
    /// `greedyModal` compte comme 1 vote ; on y ajoute les runs de tête des
    /// branches stochastiques. On rend le mot le plus voté, son accord [0,1], et
    /// s'il faut le MONTRER : accord ≥ `escAgreeThresh` ET le mot prolonge le
    /// partiel + est un vrai mot.
    ///
    /// Les DEUX axes de panne restent couverts (mesure `SouffleuseMidwordEval`) :
    ///  - AMBIGUÏTÉ (`co`/`Po`) → branches divergent → accord bas → caché.
    ///  - ÉCHEC DE HEALING (`pingo`) → branches CONVERGENT sur le garbage (accord
    ///    haut) MAIS `midWordValidExtends` le rejette → caché quand même.
    /// L'accord seul ne suffit pas ; la garde dico est indispensable — d'où la
    /// re-vérification ici, indépendante du seuil d'accord.
    public nonisolated static func midWordBranchDecision(
        partial: String, greedyModal: String, branchLeads: [String]
    ) -> (show: Bool, word: String, agreement: Double) {
        var votes = branchLeads
        votes.append(greedyModal)
        guard !votes.isEmpty else { return (false, greedyModal, 0) }
        var counts: [String: Int] = [:]
        for v in votes { counts[v.lowercased(), default: 0] += 1 }
        let top = counts.max { a, b in a.value < b.value }
        let modalKey = top?.key ?? ""
        let modal = votes.first { $0.lowercased() == modalKey } ?? greedyModal
        let agreement = Double(top?.value ?? 0) / Double(votes.count)
        let show = agreement >= Tuning.escAgreeThreshRuntime
            && midWordValidExtends(partial: partial, modal: modal)
        return (show, modal, agreement)
    }

    // MARK: - Gradient d'engagement mi-mot (flag MW_ENGAGEMENT)

    /// Niveau d'engagement du souffle mi-mot, décidé par la cascade escalate
    /// EXISTANTE (fast-accept P1 + accord des branches). Ne s'active que sous le
    /// flag `MW_ENGAGEMENT`, à l'intérieur de la branche long-ghost.
    /// - `.plein`   : greedy ~maxWords + rolling refill autorisé (living ghost).
    /// - `.prudent` : 1 mot (le modal), FIGÉ, rolling INTERDIT.
    /// - `.zero`    : abstention (rien montré).
    public enum MidWordEngagement: Sendable, Equatable {
        case plein
        case prudent
        case zero

        /// Le rolling refill n'est autorisé QU'EN PLEIN — PRUDENT figé, ZÉRO rien.
        public var rollingAllowed: Bool { self == .plein }

        /// Raison granulaire exposée à l'inspecteur (un niveau distinct par souffle).
        public var inspectorReason: String {
            switch self {
            case .plein: return "engage:plein"
            case .prudent: return "engage:prudent"
            case .zero: return "engage:zero"
            }
        }
    }

    /// **Gradient d'engagement (flag MW_ENGAGEMENT).** Mappe les signaux de la
    /// cascade escalate vers un niveau, en RÉUTILISANT les mêmes seuils que F1/F2 :
    ///   - mot dégénéré/invalide (`!midWordValidExtends`) ⇒ ZÉRO.
    ///   - fast-accept (P1 ≥ `escFastP1` ET `partial.count ≥ escMinFastLen`) ⇒ PLEIN.
    ///   - sinon accord des branches : ≥ `midWordEngagementPleinThresh` ⇒ PLEIN ;
    ///     ≥ `midWordEngagementPrudentThresh` ⇒ PRUDENT ; sinon ⇒ ZÉRO.
    /// `greedyLeadWord` = le mot de tête défragmenté du greedy (le modal greedy),
    /// `agreement` = l'accord [0,1] déjà calculé par `midWordBranchDecision`.
    public nonisolated static func midWordEngagementLevel(
        partial: String, greedyLeadWord: String, firstTokenProb: Double?, agreement: Double
    ) -> MidWordEngagement {
        // 1) ZÉRO seulement si STRUCTURELLEMENT dégénéré (le mot de tête ne prolonge
        //    pas le partiel : "i"/"pingo"/"a"/"s"). PAS de garde dico ici — elle
        //    recalait les OOV légitimes (marques, noms, anglais). Voir
        //    `midWordExtendsStructurally`.
        guard midWordExtendsStructurally(partial: partial, modal: greedyLeadWord) else { return .zero }
        // 2) Fast-accept (mêmes seuils que `midWordFastDecision`) ⇒ PLEIN direct.
        if (firstTokenProb ?? 0) >= Tuning.escFastP1, partial.count >= Tuning.escMinFastLen {
            return .plein
        }
        // 3) Sinon, accord des branches contre les deux seuils du gradient.
        if agreement >= Tuning.midWordEngagementPleinThresh { return .plein }
        if agreement >= Tuning.midWordEngagementPrudentThresh { return .prudent }
        return .zero
    }

    // MARK: - Anti-répétition de contenu (dédup du mot déjà tapé)

    /// Retire la portion de tête du `ghost` qui ne fait que RÉPÉTER, à la casse
    /// près, le mot que l'utilisateur vient de taper juste avant le caret — le
    /// bug « redit bonjour » : tail « …bonjour », ghost « bonjour, comment… ».
    ///
    /// Distingue une RÉPÉTITION d'un mot d'une CONTINUATION légitime : on ne
    /// retire que lorsque le premier mot du ghost est EXACTEMENT égal (casse
    /// ignorée) au dernier mot de `userTail`. Une vraie continuation mid-mot
    /// (« bonj » → « our ») a un premier mot différent (« our » ≠ « bonj ») et
    /// passe donc intacte — le token-healing n'est jamais cassé.
    ///
    /// Gestion du séparateur, pour que `userTail + ghost` se lise naturellement :
    ///   - caret collé au mot (aucun séparateur tapé) ⇒ on garde le séparateur
    ///     propre au ghost (« , » de « bonjour, comment ») → « bonjour, comment ».
    ///   - caret après un espace ⇒ on retire le séparateur de tête du ghost
    ///     (l'utilisateur a déjà tapé l'espace) → « bonjour comment ».
    ///   - caret après une ponctuation non-espace (« bonjour, ») ⇒ on réinsère
    ///     un espace pour ne pas coller la suite (« bonjour, comment »).
    ///
    /// Pur : `(ghost, userTail) → String`. Sans état, sans log.
    public nonisolated static func dedupLeadingRepeat(ghost: String, userTail: String) -> String {
        guard !ghost.isEmpty, !userTail.isEmpty else { return ghost }

        // Le dernier mot de `userTail` (en ignorant d'éventuels séparateurs de
        // fin). Vide ⇒ rien à dédupliquer.
        let typedWord = OutputFilter.trailingPartialWord(stripTrailingSeparators(userTail))
        guard !typedWord.isEmpty else { return ghost }

        // Le premier mot du ghost (en ignorant un espace de tête éventuel).
        let ghostLead = ghost.drop(while: { $0 == " " })
        let ghostWord = OutputFilter.leadingWordRun(String(ghostLead))
        guard !ghostWord.isEmpty else { return ghost }
        if ghostWord.lowercased() != typedWord.lowercased() {
            // Pas une répétition mot-à-mot. Mais le 1B re-tape parfois le mot déjà
            // tapé ÉCLATÉ en espaces (« demain » → « de ma in ») suivi de garbage
            // (« -car. ») : `ghostWord` vaut alors « de » ≠ « demain » et le passe
            // entre les mailles. On rejette tout le ghost si sa tête (espaces
            // collapsés) reproduit EXACTEMENT le mot tapé en ≥2 fragments.
            if Self.isSpacedWordRepeat(ghost: ghostLead, typedWord: typedWord) { return "" }
            return ghost
        }

        // Répétition confirmée → on retire le mot répété de la tête du ghost.
        var rest = Substring(ghostLead.dropFirst(ghostWord.count))

        let caretAfterSeparator = !(userTail.last.map(OutputFilter.isWordChar) ?? false)
        if caretAfterSeparator {
            // L'utilisateur a déjà tapé le séparateur. On retire UNIQUEMENT un
            // espace de tête du ghost pour ne pas le doubler — on NE touche PAS à
            // une ponctuation signifiante (guillemets/parenthèses ouvrants, tiret,
            // points de suspension…) qui introduit du contenu et doit survivre.
            if rest.first == " " { rest = rest.dropFirst() }
            guard !rest.isEmpty else { return "" }
            // Séparateur tapé = ponctuation collée (« bonjour, ») et reste qui
            // démarre sur un mot ⇒ réinsère un espace pour ne pas coller la suite.
            if !(userTail.last?.isWhitespace ?? false),
               let f = rest.first, OutputFilter.isWordChar(f) {
                return " " + String(rest)
            }
            return String(rest)
        }

        // Caret collé au mot : on garde le séparateur propre au ghost verbatim
        // (« , comment » → « bonjour, comment »). Vide ⇒ le ghost n'était QUE la
        // répétition → on rejette.
        guard !rest.isEmpty else { return "" }
        return String(rest)
    }

    /// Détecte une répétition FRAGMENTÉE : le ghost re-tape le mot déjà tapé
    /// éclaté en espaces (« demain » → « de ma in »). On accumule les lettres du
    /// ghost en sautant les espaces ; si elles reproduisent EXACTEMENT `typedWord`
    /// en ≥ 2 fragments (au moins une espace interne), c'est une répétition
    /// pathologique. Plancher 3 lettres pour ne pas faussement matcher des mots
    /// courts (« et », « la »). S'arrête au 1ᵉʳ caractère non-mot (ponctuation /
    /// tiret) ou dès que l'accumulation diverge du mot tapé. Pur.
    private nonisolated static func isSpacedWordRepeat(ghost: Substring, typedWord: String) -> Bool {
        let target = typedWord.lowercased()
        guard target.count >= 3 else { return false }
        var acc = ""
        var fragments = 1
        var sawSpace = false
        for ch in ghost {
            if ch == " " { sawSpace = true; continue }
            guard OutputFilter.isWordChar(ch) else { break }   // ponctuation → fin du run
            if sawSpace { fragments += 1; sawSpace = false }
            acc += ch.lowercased()
            if acc.count > target.count || !target.hasPrefix(acc) { return false }
            if acc == target { return fragments >= 2 }
        }
        return false
    }

    /// Retire le run de séparateurs (non word-chars) en fin de chaîne, pour que
    /// le mot complet qui précède puisse être récupéré. Pur.
    private nonisolated static func stripTrailingSeparators(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            if OutputFilter.isWordChar(s[prev]) { break }
            end = prev
        }
        return String(s[..<end])
    }

    // MARK: - Filtre salutations (pool few-shot)

    /// Détecte une entrée prose « essentiellement une salutation » — celles qui,
    /// injectées comme démonstration few-shot dans le prompt du modèle PT base,
    /// ré-amorcent la pollution multi-salutations (« Coucou… » → « Bonjour… »
    /// par imitation in-context). On EXCLUT seulement les entrées DOMINÉES par
    /// l'ouverture de politesse, pas tout message qui commence poliment : après
    /// retrait d'une ouverture de tête (« bonjour », « salut », « cher madame »…)
    /// si le reste est vide OU sous le plancher (≤ `maxResidualWords` mots ET
    /// ≤ `maxResidualChars` chars), l'entrée est jugée greeting-like.
    /// « Coucou », « Salut ! », « Bonjour Madame, », « Bonjour Gabriel » → exclus ;
    /// « Bonjour Madame, je vous écris au sujet de… » → gardé.
    ///
    /// L'entrée reste dans l'historique COMPLET : le biais n-gram et
    /// `strongCorpusMatch` peuvent toujours rappeler les salutations de
    /// l'utilisateur — on ne les retire QUE comme démonstration imitable.
    ///
    /// Pur / sans état / sans log.
    public nonisolated static func isGreetingLike(
        _ text: String,
        maxResidualWords: Int = 3,
        maxResidualChars: Int = 24
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }

        // Minuscule + suppression des accents pour comparer « Chère » à « chere ».
        func fold(_ s: Substring) -> String {
            String(s).folding(options: [.caseInsensitive, .diacriticInsensitive],
                              locale: Locale(identifier: "fr_FR"))
        }

        // Tokenise en « mots » en gardant les joints intra-mot (' ’ -) — sinon
        // « J'espère »/« vas-tu » explosent en plusieurs tokens et sur-comptent
        // le résidu (les salutations bavardes fuiraient le filtre).
        let words = trimmed.split { !OutputFilter.isWordChar($0) }.map(fold)
        guard let first = words.first else { return true }

        // Ouvertures de politesse FR/EN détectées en TÊTE uniquement. « re »
        // est volontairement ABSENT : un objet d'e-mail « Re: … » n'est pas une
        // salutation à exclure (et ses fragments restent disponibles via n-gram).
        let openers: Set<String> = [
            "bonjour", "bonsoir", "coucou", "salut", "salutations", "hello",
            "hi", "hey", "cher", "chere", "madame", "monsieur", "mademoiselle",
            "messieurs", "mesdames", "bjr", "slt", "yo",
        ]
        guard openers.contains(first) else { return false }

        // Les titres qui suivent l'ouverture font encore partie de la formule
        // de politesse (« cher monsieur », « bonjour madame »).
        let titles: Set<String> = [
            "madame", "monsieur", "mademoiselle", "messieurs", "mesdames",
        ]
        var consumed = 1
        while consumed < words.count && titles.contains(words[consumed]) {
            consumed += 1
        }
        let residual = words[consumed...]
        if residual.isEmpty { return true }

        let residualChars = residual.reduce(0) { $0 + $1.count }
        return residual.count <= maxResidualWords && residualChars <= maxResidualChars
    }
}

// MARK: - GhostUpdate + LifecycleEndReason (Plan 04-02)

/// Résultat d'une décision de routing — soit un nouveau ghost à afficher,
/// soit nil (aucun changement). Sendable + Equatable pour test seam.
public struct GhostUpdate: Sendable, Equatable {
    public let text: String
    public let source: SuggestionSource
    public let score: Score

    public init(text: String, source: SuggestionSource, score: Score) {
        self.text = text
        self.source = source
        self.score = score
    }
}

/// Cause de fin de vie d'un ghost. Le call-site `endLifecycle(reason:)` mappe
/// chaque cas vers AU PLUS UN event `ghost_classified_*` (D-09/D-10).
/// Pitfall 5 RESEARCH §728-736 : 1 ghost lifecycle = 1 classification event.
public enum LifecycleEndReason: Sendable {
    case acceptedFull
    case acceptedPartial(chunks: Int)
    case dismissedByEsc
    case typedPastWithoutOverlap
    case typedDiverged
    case replacedByOther
    case replacedByOtherStable
    case modelSwap
    case focusChange
    case blocklist
}

// MARK: - SuggestionPolicyEngine (Plan 04-02 — state-bearing)

/// Façade @MainActor qui porte le state du Ghost Relevance Gate + classification grid.
///
/// Responsabilités :
/// - **routeInstant** : cascade L0 (word-complete) + L1 (history exact-match) selon
///   la matrice D-08. Émet `ghost_word_complete` / `ghost_history_match`.
/// - **onLLMChunk** : Relevance Gate D-07 (passesGate + beats replacement bar +
///   L2-upgrade-over-L1). Émet `ghost_gate_block*` / `ghost_keep_under_bar` /
///   `ghost_classified_parasite` (parasite émis au moment du remplacement < parasiteWindow).
/// - **endLifecycle** : SINGLE CALL-SITE pour les 5 events `ghost_classified_*`.
///   Reset state — second call no-op (guard sur `!currentGhost.isEmpty`).
///
/// State strictement local : `currentGhost`, `currentSource`, `currentScore`, `shownAt`,
/// `lastReplacedSource`, `maxWords`. Aucun lien direct vers AppKit / MLX / AX.
@MainActor
public final class SuggestionPolicyEngine {
    public private(set) var currentGhost: String = ""
    public private(set) var currentSource: SuggestionSource = .none
    public private(set) var currentScore: Score = Score(sourcePrior: 0, prefixFit: 0, lengthFit: 0)
    public private(set) var shownAt: Date? = nil
    public private(set) var lastReplacedSource: SuggestionSource = .none
    /// `userTail` au moment où le ghost courant a été affiché. Sert à détecter
    /// qu'il est PÉRIMÉ : si l'utilisateur a depuis tapé des caractères qui
    /// DIVERGENT du ghost gardé (il a commencé un autre mot), ce ghost ne doit
    /// plus bloquer une nouvelle complétion via la barre de remplacement.
    private var currentGhostTail: String = ""
    /// DEV observabilité : motif de la dernière décision d'`onLLMChunk`
    /// (`shown` / `midword_block` / `gate_block` / `keep_under_bar`). Pur debug,
    /// lu par l'inspecteur de ghost. Ne contient AUCUN texte utilisateur.
    public private(set) var lastGateReason: String = ""
    private var maxWords: Int

    public init(maxWords: Int) {
        self.maxWords = maxWords
    }

    /// Étiquette courte de source pour le motif de gate (DEV/inspecteur).
    private static func srcTag(_ s: SuggestionSource) -> String {
        switch s {
        case .none: return "vide"
        case .wordComplete: return "wordComplete"
        case .learnedWord: return "learnedWord"
        case .history: return "corpus"
        case .cache: return "cache"
        case .undoCache: return "undo"
        case .llm: return "llm"
        }
    }

    /// Sync le cap de longueur depuis PreferencesStore.
    public func updateMaxWords(_ n: Int) {
        self.maxWords = n
    }

    /// Source decay : un HIGH-confidence source set par un PRECEDENT predict ne
    /// reflète plus la réalité. Demote vers `.llm` au début de predict afin que
    /// la cascade puisse re-confirmer ou accepter une mise à jour légitime.
    /// Migration verbatim depuis PVM:512-517 (pre-Phase-4).
    public func beginPredict() {
        switch currentSource {
        case .history, .cache, .undoCache:
            currentSource = .llm
        case .wordComplete, .learnedWord, .llm, .none:
            break
        }
    }

    /// Cascade routing instant (L0/L1) selon D-08.
    ///
    /// - Mid-word (tail finit par lettre) : **L0 exclusif** — WordCompleter
    ///   uniquement (≥3 chars, passesGate). Le L2 LLM est bloqué pour mid-word.
    /// - After-space ou tail vide : **L1 first** — history exact-match si
    ///   `score.value >= afterSpaceL1Bar` (0.4) ; sinon nil et L2 fillera.
    /// - Autre (ponctuation non-whitespace) : nil.
    ///
    /// Aucun side-effect sur le state interne — caller doit appeler `applyGhost`
    /// pour effectivement set le ghost.
    public func routeInstant(
        userTail: String,
        historySnapshot: [TypingHistoryEntry],
        wordCompleter: WordCompleter,
        lexicon: LearnedLexicon? = nil,
        activeDomain: DomainCluster = .other
    ) -> GhostUpdate? {
        // Recall verbatim (ghost sans LLM) ne considère QUE la prose de
        // l'utilisateur. Les fragments `.accept` (mot/bout de phrase validé au
        // Tab) restent dans le snapshot complet pour nourrir le biais n-gram,
        // mais ne doivent jamais être rappelés tels quels : ils produisent des
        // bouts tronqués que le prior strongCorpus — imbattable — épinglerait au
        // détriment d'une meilleure génération LLM. Même pattern que
        // `proseExamplesPool` (PVM).
        // Scope par CLUSTER de registre (P1.2). `activeDomain == .other` ⇒
        // AUCUN scope (comportement historique). Sinon on ne rappelle que la
        // prose des apps du MÊME registre : le privé (`.chat`) ne fuit jamais
        // dans un autre cluster, et la précision monte (corpus homogène). Pas de
        // fallback cross-cluster : un cluster connu mais sans prose ne rappelle
        // rien (le LLM gère) — privacy + précision d'abord.
        // Scope partagé avec le few-shot L2 (`FewShotScoping`) : même prédicat
        // `.prose` + cluster, défini une seule fois dans `DomainCluster.scopedProse`.
        let proseSnapshot = DomainCluster.scopedProse(historySnapshot, to: activeDomain)
        // Cas mid-word — historique d'abord (parité Cotypist), puis L0 système.
        if let last = userTail.last, last.isLetter {
            // Rappel de phrase mid-mot : le fragment de mot en cours + son
            // contexte précédent prolongent une phrase déjà tapée → on propose
            // la phrase ENTIÈRE, court-circuitant le LLM. C'est exactement ce
            // que fait Cotypist ("Bonjour, co" → "mment allez-vous ?") : il
            // n'embarque aucune liste de phrases, il rappelle l'historique. On
            // exige que la continuation commence par une LETTRE — elle complète
            // le mot en cours, pas un saut de mot accidentel — et le seuil
            // mid-word garantit qu'un fragment nu sans contexte ne recale rien.
            // Is the partial word already a COMPLETE dictionary word (≥N chars)?
            // Then the caret sits at an effective word boundary: a NEXT-WORD
            // history/LLM continuation is legitimate, and the system completer
            // must NOT extend it into a rarer word ("vais" → "vaisselle").
            // Mirror the gate `onLLMChunk` uses for the same decision.
            let midWordPartial = OutputFilter.trailingPartialWord(userTail)
            let partialIsComplete =
                midWordPartial.count >= SuggestionPolicy.Tuning.midWordLLMMinCompleteWordChars
                && SuggestionPolicy.defaultPartialWordIsComplete(userTail)

            // Corpus recall: complete the current word (letter-led continuation)
            // OR, when the word is already complete, continue with the next word
            // (space/punct-led). We no longer hard-gate on a letter-led
            // continuation — `prefixFit` (via `score.passesGate`) already encodes
            // exactly this rule (letter/joiner always, next-word only when the
            // partial word is complete), so a whitespace-led continuation after a
            // complete word ("…je vais" → " vous") now survives instead of being
            // rejected and handed to the word completer.
            if let strong = SuggestionPolicy.strongCorpusMatch(
                userTail: userTail,
                snapshot: proseSnapshot,
                minChars: SuggestionPolicy.Tuning.midWordCorpusMatchMinChars
            ) {
                let capped = SuggestionPolicy.capToWords(strong.continuation, max: maxWords)
                if !capped.isEmpty {
                    // Recall quality-gate (Task 4): drop a clearly-truncated recall
                    // so the cascade can reach the LLM instead of pinning a broken
                    // ghost via the unbeatable strong-corpus prior.
                    if SuggestionPolicy.Tuning.corpusRecallQualityGateEnabled
                        && SuggestionPolicy.corpusContinuationIsLowQuality(capped) {
                        Log.info(.predictor, "ghost_corpus_recall_rejected", count: capped.count)
                    } else {
                        let score = Score(
                            sourcePrior: SuggestionPolicy.Tuning.strongCorpusSourcePrior,
                            prefixFit: SuggestionPolicy.prefixFit(ghost: capped, userTail: userTail),
                            lengthFit: SuggestionPolicy.lengthFit(ghost: capped)
                        )
                        if score.passesGate {
                            Log.info(.predictor, "ghost_corpus_fastpath", count: strong.matchedChars)
                            return GhostUpdate(text: capped, source: .history, score: score)
                        }
                    }
                }
            }
            // System word-completion exists only to FINISH an incomplete partial
            // word ("Bonj" → "our"). Never extend an already-complete word — that
            // is the "vais" → "vaisselle" hijack; let the next-word path own it.
            if partialIsComplete { return nil }
            // ── L0 (learned lexicon) — the user's DISTINCTIVE terms (Binance,
            // Fiscalio, a client's name) that the base model cannot produce and the
            // system dictionary does not know. Capitalized-prefix-gated +
            // freq/dominance gates inside the lexicon (measured 90% precision on
            // real history). Pre-empts the long-ghost (instant, no inference) —
            // this is the on-device "personal lexicon ∥ neural" pattern (SwiftKey/
            // Gboard). Tried AFTER phrase-level corpus recall (L1 above) but
            // BEFORE the (paused) system completer.
            if let lexicon,
               let suffix = lexicon.completion(for: midWordPartial),
               !suffix.isEmpty {
                let score = SuggestionPolicy.score(
                    source: .learnedWord, ghost: suffix, userTail: userTail
                )
                if score.passesGate {
                    Log.info(.predictor, "ghost_learned_word", count: suffix.count)
                    return GhostUpdate(text: suffix, source: .learnedWord, score: score)
                }
            }
            // L0 system completer is PAUSED (off) by default — see
            // Tuning.wordCompleterEnabledRuntime. Mid-word is owned by the
            // context-aware LLM; re-enable for A/B via SOUFFLEUSE_WORDCOMPLETER=1.
            guard SuggestionPolicy.Tuning.wordCompleterEnabledRuntime,
                  let completion = wordCompleter.completion(for: userTail),
                  completion.count >= 3 else {
                return nil
            }
            let score = SuggestionPolicy.score(
                source: .wordComplete,
                ghost: completion,
                userTail: userTail
            )
            guard score.passesGate else { return nil }
            Log.info(.predictor, "ghost_word_complete", count: completion.count)
            return GhostUpdate(text: completion, source: .wordComplete, score: score)
        }

        // Phase 3 (b) — Cotypist "short" fast-path : a STRONG corpus match
        // wins over the cascade and is shown DIRECTLY (zero LLM inference).
        // Checked for BOTH after-space and punctuation tails — wherever the
        // user has re-entered a long known context. The high source prior
        // (strongCorpusSourcePrior) means a later LLM stream can only EXTEND
        // this ghost, never clobber it (replacement bar unreachable from [0,1]).
        if let strong = SuggestionPolicy.strongCorpusMatch(
            userTail: userTail,
            snapshot: proseSnapshot
        ) {
            let capped = SuggestionPolicy.capToWords(strong.continuation, max: maxWords)
            if !capped.isEmpty {
                // Recall quality-gate (Task 4): reject clearly-truncated recalls.
                if SuggestionPolicy.Tuning.corpusRecallQualityGateEnabled
                    && SuggestionPolicy.corpusContinuationIsLowQuality(capped) {
                    Log.info(.predictor, "ghost_corpus_recall_rejected", count: capped.count)
                } else {
                    let score = Score(
                        sourcePrior: SuggestionPolicy.Tuning.strongCorpusSourcePrior,
                        prefixFit: SuggestionPolicy.prefixFit(ghost: capped, userTail: userTail),
                        lengthFit: SuggestionPolicy.lengthFit(ghost: capped)
                    )
                    if score.passesGate {
                        Log.info(.predictor, "ghost_corpus_fastpath", count: strong.matchedChars)
                        return GhostUpdate(text: capped, source: .history, score: score)
                    }
                }
            }
        }

        // Cas after-space ou tail vide — L1 first.
        let isAfterSpaceLike = userTail.isEmpty || (userTail.last?.isWhitespace == true)
        if isAfterSpaceLike {
            if let raw = SuggestionPolicy.historyExactSubstringMatch(
                userTail: userTail,
                snapshot: proseSnapshot
            ) {
                let capped = SuggestionPolicy.capToWords(raw, max: maxWords)
                guard !capped.isEmpty else { return nil }
                let score = SuggestionPolicy.score(
                    source: .history,
                    ghost: capped,
                    userTail: userTail
                )
                if score.value >= SuggestionPolicy.Tuning.afterSpaceL1BarRuntime {
                    Log.info(.predictor, "ghost_history_match", count: capped.count)
                    return GhostUpdate(text: capped, source: .history, score: score)
                }
            }
            return nil
        }

        // Tail termine sur ponctuation non-whitespace — pas de routing instant.
        return nil
    }

    /// Décision Relevance Gate sur un chunk LLM (D-07). Remplace l'anti-churn
    /// high/low de PVM:874-898 pré-Phase-4.
    ///
    /// 1. Mid-word : AUTORISÉ (D-08 unblocked 2026-05-26). La cohérence du
    ///    splice mid-word est garantie EN AMONT par le coherence guard de
    ///    `generateLlama` ; seuls les survivants cohérents arrivent ici.
    /// 2. passesGate floor 0.25 : sinon bloqué.
    /// 3. Si currentGhost non-vide, replacement bar 1.15 OU L2-upgrades-L1 delta 0.15.
    /// 4. Si remplacement dans `parasiteWindow` (0.8s) du `shownAt` courant :
    ///    émission directe de `ghost_classified_parasite` (D-09/D-10).
    ///
    /// Retourne `GhostUpdate?` — le caller appelle `applyGhost(...)` pour set le state.
    public func onLLMChunk(_ chunk: String, userTail: String) -> GhostUpdate? {
        // D-08 mid-word handling — Option A REFINED (2026-05-27).
        //
        // History: the 2026-05-26 unblock let ALL free-LLM mid-word output
        // through; the live `overlay_shown` log showed the 1B routinely
        // completes a DIFFERENT word than intended ("co"→"lette", "c"→"aca",
        // "informations pe"→"peinardes"). A first-token confidence gate did NOT
        // discriminate (the model is often confidently wrong). The first fix
        // blocked ALL mid-word LLM — but the replay harness proved that was too
        // blunt: it also killed the GOOD case where the partial word is already
        // a COMPLETE word ("corrigé"→" dans la prochaine version", "vendredi"→
        // " prochain", "contrôle"→" de la température…", "exactement"→" ce que
        // je pensais"). Those are exactly the long, coherent ghosts we want.
        //
        // Refined rule: mid-word, block the LLM ONLY when the current partial
        // word is INCOMPLETE (a fragment the model must guess: "pr", "C'es",
        // "prha"). When it is already a complete dictionary word, the caret is
        // effectively at a word boundary → the LLM does a reliable NEXT-WORD
        // continuation → allow it (prefixFit already returns 1.0 for a
        // space-led ghost after a complete word).
        if let last = userTail.last, last.isLetter || last.isNumber {
            // Allow the LLM mid-word ONLY when the partial word is both a
            // complete dictionary word AND long enough to be unambiguous. The
            // replay harness showed short "complete" fragments are false
            // positives — NSSpellChecker accepts "es", "pr", "pu", "v" — and
            // letting them through reintroduces wrong-word guesses ("ma pr"→
            // "prunelle") and foreign-language drift on thin prefixes ("Si v"→
            // Spanish, "C'e"→Italian). A ≥N-char complete word ("frais",
            // "corrigé", "vendredi", "contrôle", "exactement") is a real word
            // boundary where the LLM's next-word continuation is reliable.
            let partial = OutputFilter.trailingPartialWord(userTail)
            let completeWordAllow =
                partial.count >= SuggestionPolicy.Tuning.midWordLLMMinCompleteWordChars
                && SuggestionPolicy.defaultPartialWordIsComplete(userTail)

            // Healing-admit (Task 2): with token healing on, the engine re-derives
            // the WHOLE current word from a clean boundary and the chunk's leading
            // run COMPLETES the partial. Admit when `partial + leadingPlainRun(chunk)`
            // is a valid dictionary word AND the run is letter-led (it continues the
            // SAME word — not a space/punct next-word jump and not an apostrophe/
            // hyphen sub-word boundary). E.g. "fis" + "cal" = "fiscal" (valid) →
            // ADMIT; "impe" + "rméable" = "imperméable" (valid) → ADMIT. Garbage
            // merges ("Bonjou" + "rné" = "Bonjourné") are NOT valid words → still
            // blocked, so the four pre-existing block tests are preserved.
            let healingAdmit = SuggestionPolicy.Tuning.midWordHealingEnabled
                && SuggestionPolicy.healingMidWordAdmits(partial: partial, chunk: chunk)

            // « Mot-suivant après mot court » : une suite SPACE-LED (« et »→« je
            // reviens vers ») n'est PAS une complétion de fragment — c'est un saut
            // au mot suivant, fiable quand le mot courant est COMPLET, même court
            // (et/va/la). Le seuil 4-chars la bloquait à tort (mesuré : excellentes
            // suites cachées « va »→« commencer par un », « la »→« maison »).
            // `defaultPartialWordIsComplete` garde le filet contre les vrais
            // fragments incomplets (« v », « pr ») ; et comme la suite est SPACE-LED
            // (saut de mot, pas complétion), elle ne peut pas mal-compléter le mot.
            let chunkIsNextWord = chunk.first.map { $0 == " " || $0 == "\t" } ?? false
            let nextWordAfterComplete = chunkIsNextWord
                && SuggestionPolicy.defaultPartialWordIsComplete(userTail)

            if !(completeWordAllow || healingAdmit || nextWordAfterComplete) {
                Log.info(.predictor, "ghost_midword_llm_block", count: chunk.count)
                lastGateReason = "midword_block"
                return nil
            }
            if healingAdmit && !completeWordAllow {
                // Distinct event for the healed admit (vs. the existing complete-word
                // boundary admit, which is silent here and scored below as usual).
                let merged = partial + OutputFilter.leadingPlainRun(chunk)
                Log.info(.predictor, "ghost_midword_healed", count: merged.count)
            }
        }

        // Word-boundary path (after space/punctuation). The Relevance Gate
        // below (gate floor, replacement bar / anti-churn, parasite-window
        // classification) applies as before.
        let score = SuggestionPolicy.score(
            source: .llm,
            ghost: chunk,
            userTail: userTail
        )

        // Gate floor.
        guard score.passesGate else {
            Log.info(.predictor, "ghost_gate_block", count: Int(score.value * 100))
            lastGateReason = "gate_block \(String(format: "%.2f", score.value))"
            return nil
        }

        // Replacement bar — only if currentGhost is non-empty.
        if !currentGhost.isEmpty {
            let isHistoryFirst = (currentSource == .history)
            let beatsBar = score.beats(currentScore)
            let l2Upgrades = isHistoryFirst
                && (score.value >= currentScore.value + SuggestionPolicy.Tuning.l2UpgradeDelta)
            // Micro-completion override: a mid-word corpus ghost that commits only
            // 1–2 chars ("Rapport fis" → "c") is a low-confidence placeholder. The
            // lengthFit-based bar can NEVER let a 1-word LLM chunk ("cal", score
            // 0.36) out-score a 1-word history micro (0.55), so the healed
            // completion of the WHOLE word would be stuck behind the bar and "c"
            // would stay pinned — exactly the live bug. Let an admitted LLM chunk
            // replace it, BUT only when the chunk EXTENDS the micro's committed run
            // — "c" → "cal" (same word, fuller → fiscal). A DIVERGENT heal does
            // NOT extend it ("Bonne journ" micro "ée" vs model "al" → journal), so
            // the user's learned recall is kept rather than clobbered. Scoped to
            // the mid-word micro case: long and after-space recalls keep the
            // anti-churn bar above.
            let replacesMicroCorpus = isHistoryFirst
                && SuggestionPolicy.isMicroCorpusCompletion(ghost: currentGhost, userTail: userTail)
                && OutputFilter.leadingWordRun(chunk).hasPrefix(OutputFilter.leadingWordRun(currentGhost))
            // Solution C — mid-word L0 override. A shown `.wordComplete` ghost mid-word
            // is a context-blind NSSpellChecker guess that is often the WRONG word
            // ("inv"→"invite"). The L2 chunk that reached this bar mid-word already
            // passed onLLMChunk's admit gate (it is a valid, context-aware whole-word
            // completion, e.g. "investissement"), so let it replace the blind L0
            // instead of staying pinned under the lengthFit-based bar. Scoped to
            // `.wordComplete`: history/cache/after-space ghosts are untouched.
            let replacesMidWordWordComplete = SuggestionPolicy.Tuning.midWordL2OverridesWordComplete
                && currentSource == .wordComplete
            // « Ghost qui grandit » : une EXTENSION pure du ghost LLM courant (le
            // nouveau chunk commence par l'actuel et est plus long) n'est PAS du
            // churn — c'est la même continuation cohérente qui s'allonge. La barre
            // ×1,15 + la pénalité lengthFit la bloquaient (« le retard » figé,
            // « le retard, je » gaté). On la laisse passer (mesuré : keep_under_bar
            // chute drastiquement, aucun churn introduit, le ghost s'allonge).
            let llmGrows = currentSource == .llm
                && chunk.count > currentGhost.count
                && chunk.hasPrefix(currentGhost)
            // Ghost gardé PÉRIMÉ : depuis son affichage l'utilisateur a tapé des
            // caractères qui DIVERGENT de lui (il a commencé un autre mot). Un
            // ghost 1-mot vaut toujours 0.36 ; à égalité la barre ×1,15 interdit
            // tout remplacement → la complétion correcte du NOUVEAU mot était
            // cachée derrière le ghost mort du mot précédent (« trop » → ghost
            // « petite » bloquait « bondée »). On le laisse remplacer.
            let heldGhostStale: Bool = {
                guard !currentGhostTail.isEmpty,
                      userTail.count > currentGhostTail.count,
                      userTail.hasPrefix(currentGhostTail) else { return false }
                let typedSince = userTail.dropFirst(currentGhostTail.count)
                return !currentGhost.lowercased().hasPrefix(typedSince.lowercased())
            }()
            if !(beatsBar || l2Upgrades || replacesMicroCorpus || replacesMidWordWordComplete
                 || llmGrows || heldGhostStale) {
                Log.info(.predictor, "ghost_keep_under_bar", count: currentGhost.count)
                // DEV : on accole CE QUE la barre protège (source + score) — c'est
                // le discriminateur clé. « ←corpus » = la barre a raison (protège
                // ton intention apprise) ; « ←wordComplete/vide » = elle cache une
                // bonne complétion LLM derrière un ghost aveugle.
                lastGateReason = "keep_under_bar new=\(String(format: "%.2f", score.value)) held=\(String(format: "%.2f", currentScore.value))←\(Self.srcTag(currentSource))"
                return nil
            }
            // Parasite detection : remplacement dans la fenêtre courte.
            if let shown = shownAt,
               Date().timeIntervalSince(shown) < SuggestionPolicy.Tuning.parasiteWindow {
                let visibleMs = Int(Date().timeIntervalSince(shown) * 1000)
                Log.info(.predictor, "ghost_classified_parasite", count: visibleMs)
                // Note : le state reset effectif arrive via applyGhost ci-dessous.
                // On NE veut PAS un second event parasite à endLifecycle plus tard
                // pour le même ghost remplacé — applyGhost va écraser shownAt et
                // currentGhost, qui sont la guard d'endLifecycle.
            }
        }

        lastGateReason = "shown"
        return GhostUpdate(text: chunk, source: .llm, score: score)
    }

    /// Set le ghost courant atomiquement. Track `lastReplacedSource` pour debug.
    /// `userTail` (le texte avant caret au moment de l'affichage) est mémorisé
    /// pour détecter la péremption du ghost à la frappe suivante (cf.
    /// `currentGhostTail` / la garde « held ghost stale » dans `onLLMChunk`).
    public func applyGhost(_ text: String, source: SuggestionSource, score: Score, userTail: String = "") {
        lastReplacedSource = currentSource
        currentGhost = text
        currentSource = source
        currentScore = score
        currentGhostTail = userTail
        shownAt = Date()
    }

    /// SINGLE CALL-SITE pour les 5 events `ghost_classified_*` (D-09/D-10).
    /// Pitfall 5 : 1 lifecycle = 1 event. Reset state après émission ; second
    /// call no-op via guard `!currentGhost.isEmpty`.
    public func endLifecycle(reason: LifecycleEndReason) {
        guard !currentGhost.isEmpty, let shown = shownAt else { return }
        let visibleMs = Int(Date().timeIntervalSince(shown) * 1000)
        switch reason {
        case .acceptedFull:
            Log.info(.predictor, "ghost_classified_correct", count: visibleMs)
        case .acceptedPartial(let chunks):
            Log.info(.predictor, "ghost_classified_acceptable", count: chunks)
        case .dismissedByEsc, .typedPastWithoutOverlap:
            if visibleMs >= SuggestionPolicy.Tuning.uselessMinVisibleMs {
                Log.info(.predictor, "ghost_classified_useless", count: visibleMs)
            }
        case .typedDiverged:
            if visibleMs <= SuggestionPolicy.Tuning.badMaxDivergeMs {
                Log.info(.predictor, "ghost_classified_bad", count: visibleMs)
            }
        case .replacedByOther:
            Log.info(.predictor, "ghost_classified_parasite", count: visibleMs)
        case .replacedByOtherStable, .modelSwap, .focusChange, .blocklist:
            break  // silent — pas de classification
        }
        // Reset — never double-emit (Pitfall 5).
        currentGhost = ""
        currentSource = .none
        currentScore = Score(sourcePrior: 0, prefixFit: 0, lengthFit: 0)
        shownAt = nil
    }

    /// Réinit complet. Appelé depuis `PredictorViewModel.cancel(...)` après
    /// `endLifecycle(...)`.
    public func reset() {
        currentGhost = ""
        currentSource = .none
        currentScore = Score(sourcePrior: 0, prefixFit: 0, lengthFit: 0)
        shownAt = nil
        lastReplacedSource = .none
    }
}
