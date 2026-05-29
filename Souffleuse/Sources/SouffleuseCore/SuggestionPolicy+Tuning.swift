import Foundation

extension SuggestionPolicy {
    /// Constantes tunables centralisées pour le Ghost Relevance Gate (D-06..D-13).
    ///
    /// **Single source of truth.** Pitfall 6 (RESEARCH §"Common Pitfalls") :
    /// aucun seuil littéral ne doit apparaître ailleurs dans le code ou les
    /// tests — toujours via `SuggestionPolicy.Tuning.*`. Le grep CI en fin
    /// de plan (Task 4) refuse tout literal de la liste D-06..D-09 hors de
    /// ce fichier.
    ///
    /// Visibilité `internal` (pas `private`) : les tests accèdent via
    /// `@testable import Souffleuse`.
    public enum Tuning {
        // MARK: - D-07 Gate floor + replacement bar
        public static let gateFloor: Float = 0.25
        public static let replacementBar: Float = 1.15

        // MARK: - D-08 Routing thresholds
        ///
        /// Tightening pass 2026-05-26 (post 04-07 empirical validation):
        /// raised from 0.4 → 0.6 after observing that history substring matches
        /// were polluting after-space contexts ("Je reviens " → "Je suis…" stale
        /// injection). A 0.4 bar lets too many low-relevance history fragments
        /// through. Local completions or LLM generations should win unless
        /// history is highly confident.
        public static let afterSpaceL1Bar: Float = 0.6

        /// Runtime-overridable variant. Reads `SOUFFLEUSE_REPLAY_L1_BAR` env
        /// (parsable Float) and returns it; otherwise returns `afterSpaceL1Bar`.
        /// Used by `SuggestionPolicy` L1 gate so offline replay can A/B
        /// different L1 thresholds without recompiling. Production runtime
        /// without the env var sees the unchanged 0.6 threshold.
        public static var afterSpaceL1BarRuntime: Float {
            if let s = ProcessInfo.processInfo.environment["SOUFFLEUSE_REPLAY_L1_BAR"],
               let f = Float(s) { return f }
            return afterSpaceL1Bar
        }

        public static let l2UpgradeDelta: Float = 0.15

        /// **Token-healing master switch (Task 1 + Task 2).** When `true`, a
        /// mid-word caret feeds the trailing partial word to the engine as a
        /// `healPrefix` so the model re-derives the WHOLE word from a clean
        /// boundary (engine drops the partial token + masks the first generated
        /// tokens to be prefix-compatible). `onLLMChunk` then ADMITS the healed
        /// chunk when `partial + leadingPlainRun(chunk)` forms a valid dictionary
        /// word, instead of blocking it as a "guess". Set to `false` to revert to
        /// the un-healed behaviour byte-for-byte (engine default `healPrefix: nil`
        /// + the original "complete word ≥4 chars" admit rule).
        public static let midWordHealingEnabled: Bool = true

        /// **Corpus recall quality-gate (Task 4).** When `true`, a strong-corpus
        /// instant recall whose continuation (after `capToWords`) ends mid-word on
        /// an INCOMPLETE fragment — and is not sentence-terminated — is rejected so
        /// the cascade falls through to the LLM. Stops a truncated stored phrase
        /// ("… il est indiqué s'ils report") from pre-empting a better LLM
        /// generation via the unbeatable `strongCorpusSourcePrior`. Conservative:
        /// only clearly-broken recalls are rejected; good recalls keep the speed
        /// win. Set to `false` to revert to always emitting any strong recall.
        public static let corpusRecallQualityGateEnabled: Bool = true

        // MARK: - Phase 3 (b) — Cotypist "short" fast-path (strong corpus match)
        ///
        /// Minimum matched-context length (in characters) for a corpus
        /// continuation to be shown DIRECTLY as the ghost with zero LLM
        /// inference. Below this we treat the match as too weak and let the
        /// L1/L2 cascade decide. ~16 chars ≈ several words — long enough that
        /// the user has clearly re-entered a known context.
        public static let strongCorpusMatchMinChars: Int = 16

        /// Mid-word variant of the threshold above. When the caret sits INSIDE a
        /// word, the in-progress fragment plus its preceding context recalls a
        /// learned phrase that completes the word — Cotypist parity: "Bonjour,
        /// co" → "mment allez-vous ?". This fires on a SHORTER matched context
        /// (the after-space 16-char bar would never trigger on "Bonjour, co" =
        /// 11 chars) but stays safe two ways: the matched needle still has to
        /// reach this length (so a bare 2-letter fragment with no context never
        /// recalls anything), and the continuation must START with a letter (it
        /// genuinely completes the current word rather than jumping to a new
        /// one). 8 ≈ one short word of leading context + the fragment.
        public static let midWordCorpusMatchMinChars: Int = 8

        /// Minimum length of the (complete) current partial word for a mid-word
        /// LLM continuation to be allowed (Option A refined, 2026-05-27). Below
        /// this, a "complete" word is most likely a short fragment the
        /// NSSpellChecker false-accepts ("es", "pr", "pu", "v") that would let
        /// the model guess the wrong word or drift to another language. ≥4 keeps
        /// real finished words ("frais", "corrigé", "vendredi", "contrôle").
        public static let midWordLLMMinCompleteWordChars: Int = 4

        /// Source prior for a STRONG corpus fast-path match. Higher than the
        /// regular `.history` prior (0.75) so that a confident instant ghost is
        /// NOT clobbered by a divergent LLM stream — `onLLMChunk`'s replacement
        /// bar (1.15) requires the LLM to beat `≈0.92 × 1.15 ≈ 1.06`, which an
        /// in-[0,1] score can never reach. The LLM may therefore only EXTEND
        /// (never replace) a strong corpus ghost, honouring the anti-churn rule.
        public static let strongCorpusSourcePrior: Float = 0.92

        /// A mid-word corpus recall that commits FEWER than this many letters/
        /// digits of the word the user is still typing is a MICRO completion
        /// ("Rapport fis" → "c", "…2024" → "9", "qu" → "'a"). It is still shown
        /// INSTANTLY (with the normal strong prior, so it appears immediately),
        /// but `onLLMChunk` lets an admitted, gate-passing LLM completion of the
        /// WHOLE word REPLACE it freely — bypassing the lengthFit-based bar that
        /// a 1-word healed completion ("cal" → "fiscal") could otherwise never
        /// clear. At/above this committed length the recall is treated as a
        /// confident learned completion ("fiscalité", "comment allez-vous ?") and
        /// keeps the anti-churn bar. 3 ⇒ only 1–2 char completions are overridable.
        public static let corpusMicroCompletionMaxChars: Int = 3

        // MARK: - LLM context window (coherence, 2026-05-29 measurement)
        ///
        /// Number of trailing characters of the (corrected) preceding text fed
        /// to the model as `beforeCursor`. Sized by a window A/B on the real
        /// engine (19 FR+EN coherence cases, windows 256→2048): **512 was the
        /// WORST window** — a 512-char cut can land mid-sentence and sever the
        /// discourse thread, producing generic filler instead of a
        /// context-anchored continuation (e.g. a far "remboursement"/"dashboard"
        /// antecedent is lost). The previous "more context dilutes a 1B model"
        /// rationale was UNSUPPORTED (0/14 within-512 controls changed across any
        /// window). 1024 never truncates mid-thought, matches/beats 512
        /// everywhere, and recovers far-antecedent coherence; cost ≈ +60ms warm
        /// prefill TTFT, paid once per cold field (KV reuse covers steady
        /// typing). 2048 added nothing for +185ms. NOTE: conjugation/agreement
        /// was already correct even at 256 (French cues sit near the caret) — the
        /// window fixes DISCOURSE coherence, not distance agreement.
        public static let llmContextWindowChars: Int = 1024

        // MARK: - D-08 Cache / undo-cache floors (tightening 2026-05-26)
        ///
        /// `cacheFloor` gates `cache.lookup(...)` hits. Before this tightening,
        /// any non-empty cache hit was displayed unconditionally — that's how
        /// stale LLM fragments from prior sessions kept polluting the ghost
        /// after the user typed an unrelated prefix. Now cache hits must score
        /// above `cacheFloor` (re-using `SuggestionPolicy.score(...)` with
        /// `source: .cache`) to be shown.
        public static let cacheFloor: Float = 0.55

        /// `undoCacheFloor` gates `cache.longestExtendingKey(...)` hits (undo
        /// as ghost — "user just backspaced, propose to restore"). Slightly
        /// more permissive than `cacheFloor` because the semantic signal is
        /// strong (the suffix was literally typed before backspacing).
        public static let undoCacheFloor: Float = 0.45

        // MARK: - D-09 Classification windows (assumptions A2-A4 in RESEARCH)
        public static let parasiteWindow: TimeInterval = 0.8
        public static let uselessMinVisibleMs: Int = 200
        public static let badMaxDivergeMs: Int = 500

        // MARK: - D-06 Source priors
        public static let sourcePrior: [SuggestionSource: Float] = [
            .wordComplete: 0.55,
            .history:      0.75,
            .llm:          0.60,
            .cache:        0.70,
            .undoCache:    0.65,
            .none:         0.0,
        ]

        // MARK: - D-06 Bell curve length_fit (index = word count, clamp to last for >=10)
        public static let lengthFitByWordCount: [Float] = [
            0.0,  // 0 mots — défensif
            0.6,  // 1 mot
            1.0,  // 2
            1.0,  // 3
            1.0,  // 4
            1.0,  // 5
            0.85, // 6 — bord du sweet spot
            0.6,  // 7
            0.6,  // 8
            0.3,  // 9+ — trop long
        ]
    }
}
