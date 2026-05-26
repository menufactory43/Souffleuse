import Foundation
import SouffleuseLog
import SouffleusePersonalization
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
enum SuggestionSource: Sendable {
    case none           // suggestion is "" or stale
    case wordComplete   // Layer 0 — NSSpellChecker
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
struct Score: Sendable, Equatable, CustomStringConvertible {
    let sourcePrior: Float
    let prefixFit: Float
    let lengthFit: Float

    /// Produit des trois facteurs. Toujours dans [0,1] tant que les facteurs y sont.
    var value: Float { sourcePrior * prefixFit * lengthFit }

    /// D-07 hard floor : sous ce seuil le ghost est rejeté sans affichage.
    var passesGate: Bool { value >= SuggestionPolicy.Tuning.gateFloor }

    /// D-07 replacement bar : un nouveau ghost doit battre le score courant
    /// d'un facteur `Tuning.replacementBar` pour le supplanter. Évite le
    /// churn (régression de la session 2026-05-25, commits 2b6b6be..7316a8c).
    /// L'égalité stricte est volontairement insuffisante : `a.beats(a) == false`
    /// quand `value == 0` ; sinon `value >= value * 1.15` est false.
    func beats(_ other: Score) -> Bool {
        value >= other.value * SuggestionPolicy.Tuning.replacementBar
    }

    var description: String {
        "Score(src=\(sourcePrior) pref=\(prefixFit) len=\(lengthFit) → \(value))"
    }
}

// MARK: - SuggestionPolicy namespace (pure-function helpers)

/// Namespace pour les pure-function helpers du Ghost Relevance Gate.
/// Tous les seuils consommés ici vivent dans `SuggestionPolicy+Tuning.swift`
/// (Pitfall 6 — aucun littéral autorisé ailleurs).
enum SuggestionPolicy {

    /// Calcule le `Score` complet pour un ghost candidat (D-06).
    ///
    /// Pure function : `(source, ghost, userTail) → Score`. Aucun effet de bord.
    /// Le caller (PVM ou le futur `SuggestionPolicyEngine`) compose `passesGate`
    /// et `beats(_:)` au-dessus pour décider d'afficher/replacer.
    static func score(source: SuggestionSource, ghost: String, userTail: String) -> Score {
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

    /// Le mot partiel en fin de `userTail` est-il un mot COMPLET/valide ?
    /// Réutilise `ModelRuntime.OutputFilter.trailingPartialWord` (même notion
    /// que le coherence guard mid-word) puis `TypoDetector.isValidWord`.
    /// Permissif FR+EN. Vide ⇒ pas mid-word ⇒ false (caller ne l'appelle pas).
    nonisolated static func defaultPartialWordIsComplete(_ userTail: String) -> Bool {
        let partial = ModelRuntime.OutputFilter.trailingPartialWord(userTail)
        guard !partial.isEmpty else { return false }
        return sharedTypoDetector.isValidWord(partial, language: nil)
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
    nonisolated static func prefixFit(
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
            // Ponctuation non-whitespace (`.`, `,`, `!`, etc.) — non spécifié par D-06,
            // on traite comme un "after-space-like" : autoriser lettre/digit/quote.
            return Self.isNaturalContinuationStart(g) ? 1.0 : 0.0
        }
        // userTail vide ⇒ comme after-space.
        return Self.isNaturalContinuationStart(g) ? 1.0 : 0.0
    }

    /// D-06 length_fit : bell curve sur le nombre de mots du ghost.
    /// Table `Tuning.lengthFitByWordCount` ; clamp à la dernière entrée pour ≥10.
    nonisolated static func lengthFit(ghost: String) -> Float {
        let wordCount = ghost.split(whereSeparator: { $0.isWhitespace }).count
        let table = Tuning.lengthFitByWordCount
        guard !table.isEmpty else { return 0.0 }
        let index = min(wordCount, table.count - 1)
        return table[index]
    }

    // MARK: - Private helpers

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
    nonisolated static func historyExactSubstringMatch(
        userTail: String,
        snapshot: [TypingHistoryEntry]
    ) -> String? {
        let lookback = String(userTail.suffix(40))
        guard lookback.count >= 6 else { return nil }
        if lookback.last?.isWhitespace == true { return nil }
        for entry in snapshot {
            let full = entry.contextBefore.isEmpty
                ? entry.accepted
                : entry.contextBefore + " " + entry.accepted
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
    nonisolated static func strongCorpusMatch(
        userTail: String,
        snapshot: [TypingHistoryEntry]
    ) -> (continuation: String, matchedChars: Int)? {
        let minChars = Tuning.strongCorpusMatchMinChars
        // Look back over a generous window; the longest suffix of userTail that
        // is also a substring of some entry (ending the entry's recorded text
        // BEFORE its tail) wins.
        let lookbackFull = String(userTail.suffix(120))
        guard lookbackFull.count >= minChars else { return nil }

        var best: (continuation: String, matchedChars: Int)?
        for entry in snapshot {
            let full = entry.contextBefore.isEmpty
                ? entry.accepted
                : entry.contextBefore + " " + entry.accepted
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
    nonisolated static func capToWords(_ text: String, max: Int) -> String {
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
            s = words.prefix(max).joined(separator: " ")
        }
        return s
    }
}

// MARK: - GhostUpdate + LifecycleEndReason (Plan 04-02)

/// Résultat d'une décision de routing — soit un nouveau ghost à afficher,
/// soit nil (aucun changement). Sendable + Equatable pour test seam.
struct GhostUpdate: Sendable, Equatable {
    let text: String
    let source: SuggestionSource
    let score: Score
}

/// Cause de fin de vie d'un ghost. Le call-site `endLifecycle(reason:)` mappe
/// chaque cas vers AU PLUS UN event `ghost_classified_*` (D-09/D-10).
/// Pitfall 5 RESEARCH §728-736 : 1 ghost lifecycle = 1 classification event.
enum LifecycleEndReason: Sendable {
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
final class SuggestionPolicyEngine {
    private(set) var currentGhost: String = ""
    private(set) var currentSource: SuggestionSource = .none
    private(set) var currentScore: Score = Score(sourcePrior: 0, prefixFit: 0, lengthFit: 0)
    private(set) var shownAt: Date? = nil
    private(set) var lastReplacedSource: SuggestionSource = .none
    private var maxWords: Int

    init(maxWords: Int) {
        self.maxWords = maxWords
    }

    /// Sync le cap de longueur depuis PreferencesStore.
    func updateMaxWords(_ n: Int) {
        self.maxWords = n
    }

    /// Source decay : un HIGH-confidence source set par un PRECEDENT predict ne
    /// reflète plus la réalité. Demote vers `.llm` au début de predict afin que
    /// la cascade puisse re-confirmer ou accepter une mise à jour légitime.
    /// Migration verbatim depuis PVM:512-517 (pre-Phase-4).
    func beginPredict() {
        switch currentSource {
        case .history, .cache, .undoCache:
            currentSource = .llm
        case .wordComplete, .llm, .none:
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
    func routeInstant(
        userTail: String,
        historySnapshot: [TypingHistoryEntry],
        wordCompleter: WordCompleter
    ) -> GhostUpdate? {
        // Cas mid-word — L0 exclusif.
        if let last = userTail.last, last.isLetter {
            guard let completion = wordCompleter.completion(for: userTail),
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
            snapshot: historySnapshot
        ) {
            let capped = SuggestionPolicy.capToWords(strong.continuation, max: maxWords)
            if !capped.isEmpty {
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

        // Cas after-space ou tail vide — L1 first.
        let isAfterSpaceLike = userTail.isEmpty || (userTail.last?.isWhitespace == true)
        if isAfterSpaceLike {
            if let raw = SuggestionPolicy.historyExactSubstringMatch(
                userTail: userTail,
                snapshot: historySnapshot
            ) {
                let capped = SuggestionPolicy.capToWords(raw, max: maxWords)
                guard !capped.isEmpty else { return nil }
                let score = SuggestionPolicy.score(
                    source: .history,
                    ghost: capped,
                    userTail: userTail
                )
                if score.value >= SuggestionPolicy.Tuning.afterSpaceL1Bar {
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
    func onLLMChunk(_ chunk: String, userTail: String) -> GhostUpdate? {
        // D-08 mid-word handling — UNBLOCKED (2026-05-26).
        //
        // The blunt mid-word block was removed. Coherent mid-word LLM
        // continuations (Cotypist parity: "fai"→"s", "problè"→"me") must reach
        // the screen. Quality is now enforced UPSTREAM in
        // `ModelRuntime.generateLlama` by the mid-word coherence guard
        // (`OutputFilter.midWordCandidate` + `TypoDetector.isValidWord`), which
        // already DROPS incoherent splices ("fai"+"que"="faique") before the
        // chunk ever reaches here and KEEPS coherent ones. Only the survivors
        // arrive — so the unconditional block was redundant and was the sole
        // reason coherent mid-word ghosts never showed.
        //
        // The rest of the Relevance Gate (gate floor, replacement bar /
        // anti-churn, parasite-window classification) stays intact and applies
        // mid-word too: `prefixFit` already returns 1.0 for a letter-starting
        // ghost on a mid-word tail (and 0.0 for a non-letter splice), so a
        // coherent continuation scores sanely and a stray punctuation/markdown
        // splice is still gated out.
        let score = SuggestionPolicy.score(
            source: .llm,
            ghost: chunk,
            userTail: userTail
        )

        // Gate floor.
        guard score.passesGate else {
            Log.info(.predictor, "ghost_gate_block", count: Int(score.value * 100))
            return nil
        }

        // Replacement bar — only if currentGhost is non-empty.
        if !currentGhost.isEmpty {
            let isHistoryFirst = (currentSource == .history)
            let beatsBar = score.beats(currentScore)
            let l2Upgrades = isHistoryFirst
                && (score.value >= currentScore.value + SuggestionPolicy.Tuning.l2UpgradeDelta)
            if !(beatsBar || l2Upgrades) {
                Log.info(.predictor, "ghost_keep_under_bar", count: currentGhost.count)
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

        return GhostUpdate(text: chunk, source: .llm, score: score)
    }

    /// Set le ghost courant atomiquement. Track `lastReplacedSource` pour debug.
    func applyGhost(_ text: String, source: SuggestionSource, score: Score) {
        lastReplacedSource = currentSource
        currentGhost = text
        currentSource = source
        currentScore = score
        shownAt = Date()
    }

    /// SINGLE CALL-SITE pour les 5 events `ghost_classified_*` (D-09/D-10).
    /// Pitfall 5 : 1 lifecycle = 1 event. Reset state après émission ; second
    /// call no-op via guard `!currentGhost.isEmpty`.
    func endLifecycle(reason: LifecycleEndReason) {
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
    func reset() {
        currentGhost = ""
        currentSource = .none
        currentScore = Score(sourcePrior: 0, prefixFit: 0, lengthFit: 0)
        shownAt = nil
        lastReplacedSource = .none
    }
}
