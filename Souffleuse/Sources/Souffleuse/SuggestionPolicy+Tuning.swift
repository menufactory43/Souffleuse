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
    enum Tuning {
        // MARK: - D-07 Gate floor + replacement bar
        static let gateFloor: Float = 0.25
        static let replacementBar: Float = 1.15

        // MARK: - D-08 Routing thresholds
        ///
        /// Tightening pass 2026-05-26 (post 04-07 empirical validation):
        /// raised from 0.4 → 0.6 after observing that history substring matches
        /// were polluting after-space contexts ("Je reviens " → "Je suis…" stale
        /// injection). A 0.4 bar lets too many low-relevance history fragments
        /// through. Local completions or LLM generations should win unless
        /// history is highly confident.
        static let afterSpaceL1Bar: Float = 0.6
        static let l2UpgradeDelta: Float = 0.15

        // MARK: - D-08 Cache / undo-cache floors (tightening 2026-05-26)
        ///
        /// `cacheFloor` gates `cache.lookup(...)` hits. Before this tightening,
        /// any non-empty cache hit was displayed unconditionally — that's how
        /// stale LLM fragments from prior sessions kept polluting the ghost
        /// after the user typed an unrelated prefix. Now cache hits must score
        /// above `cacheFloor` (re-using `SuggestionPolicy.score(...)` with
        /// `source: .cache`) to be shown.
        static let cacheFloor: Float = 0.55

        /// `undoCacheFloor` gates `cache.longestExtendingKey(...)` hits (undo
        /// as ghost — "user just backspaced, propose to restore"). Slightly
        /// more permissive than `cacheFloor` because the semantic signal is
        /// strong (the suffix was literally typed before backspacing).
        static let undoCacheFloor: Float = 0.45

        // MARK: - D-09 Classification windows (assumptions A2-A4 in RESEARCH)
        static let parasiteWindow: TimeInterval = 0.8
        static let uselessMinVisibleMs: Int = 200
        static let badMaxDivergeMs: Int = 500

        // MARK: - D-06 Source priors
        static let sourcePrior: [SuggestionSource: Float] = [
            .wordComplete: 0.55,
            .history:      0.75,
            .llm:          0.60,
            .cache:        0.70,
            .undoCache:    0.65,
            .none:         0.0,
        ]

        // MARK: - D-06 Bell curve length_fit (index = word count, clamp to last for >=10)
        static let lengthFitByWordCount: [Float] = [
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
