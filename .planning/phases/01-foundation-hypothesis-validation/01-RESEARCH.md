# Phase 1: Foundation + Hypothesis Validation — Research

**Researched:** 2026-05-24
**Domain:** Token-budgeted prompt assembly + MLX tokenizer integration + replay harness extension
**Confidence:** HIGH (codebase-internal, no external lookup required)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**D-01: Tokenizer MLX réel.** Le PromptBuilder utilise le tokenizer du `ModelContainer` chargé (via `MLXLMCommon`) pour mesurer exactement la longueur en tokens de chaque slot. Pas d'estimateur heuristique (chars/4) — la précision compte plus que le coût (qui reste de quelques ms par predict).

**D-02: Tokenizer requis, pas de fallback.** `predict()` n'est jamais appelé avant que `loadContainer` ait livré le tokenizer (invariant déjà respecté via `loadState`). Le builder est construit après le model load et n'a aucun chemin "cold-start estimator". Surface API plus simple, tests plus déterministes.

**D-03: Budget total ~512 tokens** pour le prompt complet (≈3-4× la baseline char actuelle de 512 chars/~150-200 tokens). Marge confortable pour les slots actifs en Phase 1 (system + `beforeCursor` + `contextPrefix` flat + few-shot dynamique) sans exploser TTFT. Valeur à ré-affiner si SouffleuseBench remonte une dégradation > seuil au planner.

**D-04: Allocation fixe par slot.** Chaque slot déclare son budget en tokens dans sa config (ex: `beforeCursor=200, system=80, contextPrefix=150, fewShot=80, customInstructions=40` — proportions indicatives, à finaliser au planner). Builder additionne et rejette si total > budget global. Eviction se fait **par slot indépendamment** (pas de "vol" cross-slot). Prédictible, testable en isolation, et compatible avec l'ajout des slots Phase 2/3 sans refactor de la policy.

**D-05: Le replay étend `SouffleuseCoherence`** (executable existant : `Souffleuse/Sources/SouffleuseCoherence/main.swift`). On ajoute un mode `--replay` ou un nouveau sub-command qui charge un fichier de scénarios et produit le rendu A/B. Réutilise la machinerie MLX/load model déjà en place. Pas de nouveau target SPM dédié au replay.

**D-06: Tests snapshot du builder en complément.** Indépendamment du replay MLX (slow, requiert modèle), le builder a des tests unitaires XCTest qui snapshottent le prompt assemblé pour des scénarios fixés — déterministes, rapides, CI-friendly, satisfont BUILDER-03 et TEST-02. Le replay MLX est pour le verdict humain ; les snapshot tests sont pour la non-régression du builder.

**D-07: Scénarios curated checked-in.** Les 10-20 scénarios vivent dans un fichier JSON checked-in (chemin : `.planning/phases/01-foundation-hypothesis-validation/replay-scenarios.json`). Chaque scénario définit : `id`, `label`, `bundleID`, `windowTitle`, `contextPrefix` (string), `userTail` (string), `notes` (optionnel). Versionné, diffable, reproductible. Pas de capture depuis logs (privacy + complexité), pas de templating.

**D-08: Verdict = eyeball humain side-by-side.** Le replay produit pour chaque scénario : ghost sans-contexte (PromptBuilder avec `contextPrefix` désactivé) ET ghost avec-contexte (PromptBuilder complet), côte-à-côte. C'est toi qui votes (✓ / ✗ / =). Pas d'heuristiques automatiques en Phase 1. Pas de LLM-as-judge (out-of-scope: réseau).

**D-09: Output = markdown checked-in.** Le replay regen `.planning/phases/01-foundation-hypothesis-validation/REPLAY-RESULTS.md` à chaque exécution. Chaque scénario rend en une section markdown avec les deux variantes côte-à-côte, plus un slot vide pour le verdict humain (✓ / ✗ / = + notes). AUDIT-02 verrouille : si verdict global ≥ N/M positifs (seuil à fixer au planner, par ex 6/10), milestone continue ; sinon, milestone est revu avant Phase 2.

**D-10: Nouveau target SPM `SouffleusePrompt`.** Le target dépend de : `SouffleuseLog`, `SouffleuseContext` (pour les types `EnrichedContext`), `SouffleusePersonalization` (pour `SimilarHistoryRetrieval` quand Phase 2 le branchera), et `MLXLMCommon` (pour accès tokenizer). Consommé par le target `Souffleuse` (app) et par `SouffleuseCoherence` (replay).

**D-11: Eviction `beforeCursor` = truncation côté tête, frontière phrase-puis-mot.** Le slot préserve la queue (le texte juste avant le caret est le plus signal-rich). Stratégie : (a) si le budget permet, couper à la dernière frontière de phrase qui rentre (`.`, `?`, `!`, `\n` doublé) ; (b) sinon, couper à la dernière frontière de mot (whitespace / ponctuation) ; (c) **jamais** de coupe mid-word (invariant testable). Remplace le truncate dumb à 512 chars actuel.

**D-12: Feature flag dev-only en parallèle.** Le nouveau path PromptBuilder coexiste avec la flat-string actuelle dans `predict()`, sélectionné par env var `SOUFFLEUSE_PROMPT_BUILDER=1` (proposé). Le flag est retiré (et la flat-string supprimée) à la fin de Phase 1 une fois que le verdict replay est positif et que les 94 tests + nouveaux snapshot tests sont verts.

**D-13: Direction indicative, pas verrouillée.** Le planner reste libre de pivoter en in-place refactor si l'invasivité s'avère minimale. Marquer ça comme « default = feature flag, escape hatch = in-place avec justification dans PLAN.md ».

### Claude's Discretion

- Proportions exactes des budgets par slot — D-04 fixe la policy, mais les chiffres précis se règlent au planner avec un mini-bench TTFT/qualité.
- Seuil de validation AUDIT-02 (par ex 6/10, 7/10).
- Schéma exact du fichier scénarios JSON (D-07 fixe le minimum requis ; le planner peut ajouter `expectedTopic`, `mustNotContain`, etc.).
- Nom exact du target SPM (`SouffleusePrompt` proposé en D-10).
- Choix exact du nom de l'env var de feature flag (`SOUFFLEUSE_PROMPT_BUILDER=1`).

### Deferred Ideas (OUT OF SCOPE)

- **Slot-level instrumentation TTFT.** Mesurer le coût en ms apporté par chaque slot individuellement.
- **Refactor de `ContextEnricher` en slots indépendants.**
- **Heuristiques automatiques pour le verdict A/B** (substring matching, blocklist).
- **LLM-as-judge externe.** Hors scope absolu (privacy invariant : pas de réseau).
- **Choix entre env var et UserDefaults pref pour le feature flag.**
- **Schéma JSON/YAML extensions.**
- **Capture de scénarios depuis logs anonymisés.**
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| BUILDER-01 | Un PromptBuilder structuré remplace la flat-string concat dans `PredictorViewModel.predict()`. Slots nommés, assemblage déterministe, output = string final passé à MLX `container.perform`. | §1 PromptBuilder API · §5 Integration with predict() |
| BUILDER-02 | Budget exprimé en tokens (pas chars), allocation par catégorie, eviction-policy explicite préférant truncation propre. | §2 Tokenizer access · §3 Eviction algorithm · §4 Budget proposal |
| BUILDER-03 | Le PromptBuilder est testable en isolation — snapshot tests indépendants de MLX. | §1 (TokenCounting protocol) · §8 Test strategy |
| BUILDER-04 | Pipeline existante continue de fonctionner sans régression pendant la construction. Migration tranchée. | §5 Integration · §10 Audit verification (feature flag plumbing) |
| SLOT-01 | Slot `beforeCursor` mieux budgeté — préservation du dernier mot complet, contexte amont gardé maximum sous budget alloué. | §3 Eviction algorithm |
| AUDIT-01 | Le PromptBuilder Phase 1 expose un mode test/replay qui rejoue 10-20 scénarios reproductibles. | §6 Replay harness · §7 Scenario schema |
| AUDIT-02 | Avant Phase 2, audit produit un verdict A/B clair. | §6 Replay harness (REPLAY-RESULTS.md generation) · §12 Open questions |
| TEST-01 | Les 94 tests existants restent verts. | §8 Test strategy (feature-flag period coexistence) |
| TEST-02 | Nouveaux tests PromptBuilder : budget allocation, assemblage déterministe. | §8 Test strategy (snapshot + eviction tables) |
| TEST-03 | Privacy invariants : `audit.sh` continue de passer. | §10 Audit verification |
</phase_requirements>

## Summary

Phase 1 introduces a new SPM target `SouffleusePrompt` containing a value-type `PromptBuilder` that consumes a `TokenCounting` protocol (real MLX tokenizer in production, mock in tests). The builder declares named slots with fixed per-slot token budgets, fills them from `BuiltPrompt` source values, applies head-truncation at sentence-then-word boundaries when a slot overflows, and emits a final string + per-slot accounting metadata. The legacy flat-string assembly in `PredictorViewModel.predict()` (lines 478-513 for `systemMessage`/`basePreamble`, lines 632-664 for the few-shot insertion inside the detached Task) stays alive behind an env var `SOUFFLEUSE_PROMPT_BUILDER=1` until the replay verdict is positive.

`SouffleuseCoherence/main.swift` gets a `--replay <scenarios.json>` mode that loads the curated scenario file at `.planning/phases/01-foundation-hypothesis-validation/replay-scenarios.json`, runs each scenario twice (with/without `contextPrefix`), and writes `REPLAY-RESULTS.md` side-by-side. The human eyeballs the verdict and fills in checkboxes per scenario; AUDIT-02 gate is a counted threshold (planner-decided, 6/10 suggested).

XCTest snapshot coverage (deterministic, no MLX) is added to `SouffleuseTests` via a hand-rolled mock `TokenCounting` that maps `String → Int` by word count or stable hash — the builder's assembly logic is exercised without booting a transformer. Privacy invariants (`audit.sh` 6 checks) hold by construction: the builder receives strings, never logs them, and uses only `Log.info(.module, "static_event_name", count: n)` for instrumentation.

**Primary recommendation:** Build `SouffleusePrompt` as a leaf SPM library (depends only on `SouffleuseLog` + `MLXLMCommon`; consumes `EnrichedContext.prefix` as opaque string in Phase 1), wire a `TokenCounting` protocol so the builder is MLX-independent for tests, gate at the call site in `PredictorViewModel.predict()` with `if ProcessInfo.processInfo.environment["SOUFFLEUSE_PROMPT_BUILDER"] != nil`, and extend `SouffleuseCoherence/main.swift` with a sub-command guarded by `ArgumentParser.first == "--replay"` (no new dep — manual arg parse, consistent with the existing env-var style).

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Token measurement | SouffleusePrompt (production); test mock | MLXLMCommon (real tokenizer) | Pure measurement is library-level; mock allows tests |
| Slot assembly + eviction | SouffleusePrompt (`PromptBuilder` struct) | — | Pure value-type logic, no MLX or AppKit dependency |
| Slot configuration (per-slot budgets) | SouffleusePrompt (`PromptBudget` struct) | — | Static const lives with the type that uses it |
| Builder integration | Souffleuse (`PredictorViewModel.predict()`) | SouffleusePrompt | App layer wires the model's tokenizer into the builder |
| Replay scenario loading | SouffleuseCoherence (executable) | SouffleusePrompt | Coherence is the existing MLX harness; reuses load logic |
| REPLAY-RESULTS.md writing | SouffleuseCoherence | — | One file produced by one executable — keep co-located |
| Feature flag detection | Souffleuse (call site) | — | Env-var read at predict() entry; no global state |
| Privacy gate (audit.sh) | audit.sh (script) | All shipping targets | Existing convention: SHIPPING_DIRS list extended for SouffleusePrompt |
| Snapshot tests | SouffleuseTests (test target) | SouffleusePrompt (`@testable import`) | Existing pattern: one test target for all libraries |

---

## 1. PromptBuilder API Surface

Exact Swift type signatures, with rationale.

### Why struct, not actor

The builder owns no mutable state across calls. Each `build(...)` invocation takes its inputs as parameters and returns an immutable `BuiltPrompt`. A struct is:
- `Sendable` for free (all stored properties Sendable)
- Cheap to construct per-predict (no actor isolation hop)
- Trivially testable without await
- Matches the existing convention of `EnrichedContext` (value-type, no state)

The only "state" the builder needs is its `TokenCounting` dependency, injected at init.

### Why protocol for tokenizer

The MLX tokenizer is wrapped behind `container.perform { context in context.tokenizer }` — only reachable inside the actor-isolated `ModelContainer.perform` closure. Tests can't easily host an MLX container. A `TokenCounting` protocol seam:
- Lets production wire a `MLXTokenCounter` thin adapter
- Lets tests wire a deterministic mock (word-count-based or fixed-table)
- Matches the project precedent: `OCRCaretLocating` for `OCRCaretLocator` (`Sources/SouffleuseContext/OCRCaretLocator.swift` + `MockOCRCaretLocator` in `CaretResolverTests.swift`)

### Types

```swift
// In SouffleusePrompt/TokenCounting.swift

import Foundation

/// Abstraction over a tokenizer that maps strings to token counts.
/// Production: thin wrapper over MLX `Tokenizer.encode(text:).count`.
/// Tests: deterministic mock (word-count or fixed-table) so snapshot
/// assertions don't depend on a loaded MLX model.
public protocol TokenCounting: Sendable {
    /// Returns the number of tokens `text` would produce. MUST be deterministic
    /// for a given (tokenizer, text) pair so eviction is reproducible.
    func countTokens(_ text: String) -> Int

    /// Returns the head-truncated form of `text` whose token count is `≤ budget`,
    /// preferring boundaries (sentence terminator, then whitespace). MUST NOT
    /// cut mid-word. Returns "" if budget < 1 or no boundary fits.
    func truncateHead(_ text: String, toBudget budget: Int) -> String
}
```

```swift
// In SouffleusePrompt/PromptSlot.swift

import Foundation

/// Named slot in the assembled prompt. Slot identity is fixed at Phase 1 to
/// what's active today + reserved Phase 2/3 names so the builder's API doesn't
/// shift between phases.
public enum PromptSlot: String, Sendable, CaseIterable, Hashable {
    // ── Active in Phase 1 ────────────────────────────────────
    case system            // framing prompt + language steering
    case customInstructions
    case contextPrefix     // ContextEnricher flat passthrough
    case fewShot           // SimilarHistoryRetrieval (currently inside Task)
    case beforeCursor      // user tail — the only token-budgeted slot at Phase 1

    // ── Reserved for Phase 2/3 (declared, never filled at Phase 1) ────
    case afterCursor
    case fieldContext
    case previousUserInputs
    case clipboardContext
    case screenContext
}
```

```swift
// In SouffleusePrompt/PromptBudget.swift

import Foundation

/// Per-slot token allocation + global cap. Indicative defaults — final numbers
/// settled at planner stage after a mini SouffleuseBench reading.
public struct PromptBudget: Sendable, Equatable {
    public let global: Int                       // hard upper bound on assembled prompt
    public let perSlot: [PromptSlot: Int]        // each slot's independent allowance

    public init(global: Int, perSlot: [PromptSlot: Int]) {
        self.global = global
        self.perSlot = perSlot
    }

    /// Phase 1 default. system=80 + customInstructions=40 + contextPrefix=150
    /// + fewShot=80 + beforeCursor=200 = 550, with global cap 512 enforcing
    /// "if all slots fill, beforeCursor gets squeezed". Adjust at planner stage.
    public static let phase1Default = PromptBudget(
        global: 512,
        perSlot: [
            .system: 80,
            .customInstructions: 40,
            .contextPrefix: 150,
            .fewShot: 80,
            .beforeCursor: 200,
        ]
    )
}
```

```swift
// In SouffleusePrompt/BuiltPrompt.swift

import Foundation

/// Result of `PromptBuilder.build(...)`. Carries the assembled text + per-slot
/// accounting metadata so the planner / replay tool can show "what was kept,
/// what was truncated". Equatable for snapshot testing.
public struct BuiltPrompt: Sendable, Equatable {
    public let text: String                                // final prompt string fed to MLX
    public let slotTokenCounts: [PromptSlot: Int]          // tokens consumed per slot post-eviction
    public let truncatedSlots: Set<PromptSlot>             // slots that were head-truncated
    public let totalTokens: Int

    public init(
        text: String,
        slotTokenCounts: [PromptSlot: Int],
        truncatedSlots: Set<PromptSlot>,
        totalTokens: Int
    ) {
        self.text = text
        self.slotTokenCounts = slotTokenCounts
        self.truncatedSlots = truncatedSlots
        self.totalTokens = totalTokens
    }
}
```

```swift
// In SouffleusePrompt/PromptBuilder.swift

import Foundation

/// Token-budgeted prompt assembly. Pure value-type. Build is deterministic for
/// a given (counter, budget, inputs) triple.
///
/// Slots in fixed assembly order:
///   1. system               (head)
///   2. customInstructions
///   3. contextPrefix
///   4. fewShot
///   5. beforeCursor         (tail — appears RIGHT before model continues)
public struct PromptBuilder: Sendable {
    public let counter: TokenCounting
    public let budget: PromptBudget

    public init(counter: TokenCounting, budget: PromptBudget = .phase1Default) {
        self.counter = counter
        self.budget = budget
    }

    /// Assemble. Each slot is independently truncated to its per-slot budget
    /// (D-04: no cross-slot stealing). Slots whose input is empty contribute
    /// nothing to the final text. Order matters: see fixed assembly above.
    ///
    /// `beforeCursor` is the only slot using head-truncation at Phase 1; other
    /// slots that overflow are tail-truncated at word boundary (rare in practice
    /// because system/customInstructions/contextPrefix are small).
    public func build(
        system: String,
        customInstructions: String,
        contextPrefix: String,
        fewShot: String,
        beforeCursor: String
    ) -> BuiltPrompt { /* see §3 + §5 for algorithm */ }

    /// Variant for the replay harness: lets the caller disable any slot for
    /// A/B comparison without rebuilding the inputs.
    public func build(
        slots: [PromptSlot: String]
    ) -> BuiltPrompt { /* convenience overload */ }
}
```

```swift
// In Souffleuse/MLXTokenCounter.swift  (production adapter, lives in app target
// because it imports MLXLMCommon)

import MLXLMCommon
import SouffleusePrompt

/// Thin adapter wrapping an MLX `Tokenizer`. Constructed lazily inside the
/// `container.perform` closure where the tokenizer is reachable.
struct MLXTokenCounter: TokenCounting {
    let tokenizer: any Tokenizer    // MLXLMCommon protocol; @Sendable via package

    func countTokens(_ text: String) -> Int {
        tokenizer.encode(text: text).count
    }

    func truncateHead(_ text: String, toBudget budget: Int) -> String {
        // see §3 for algorithm — binary-search a head-trim point at sentence,
        // then word boundary.
    }
}
```

**Why split `MLXTokenCounter` into the app target instead of `SouffleusePrompt`:** `SouffleusePrompt` should be importable by tests without pulling MLX. Putting the MLX adapter alongside `PredictorViewModel.swift` lets the protocol stay leaf-pure. Alternative is fine too (counter inside `SouffleusePrompt` since the target already depends on `MLXLMCommon` per D-10) — planner decides. The protocol seam is the load-bearing part.

[VERIFIED: codebase grep — `OCRCaretLocating` protocol + `MockOCRCaretLocator` pattern in `Sources/SouffleuseContext/OCRCaretLocator.swift` and `Tests/SouffleuseTests/CaretResolverTests.swift`]

---

## 2. Tokenizer Access Pattern

### How to reach the MLX tokenizer

The MLX tokenizer lives inside the `ModelContainer.perform` closure:

```swift
// Current usage in PredictorViewModel.swift:690-702
try await container.perform { context -> StreamMetrics in
    // context.tokenizer is `any Tokenizer` from MLXLMCommon
    let promptTokens = context.tokenizer.encode(text: basePromptText)
    // OR with chat template:
    let templated = try? context.tokenizer.applyChatTemplate(messages: messages)
    // ...
}
```

`context.tokenizer` is `any Tokenizer` (a protocol from `MLXLMCommon` re-exporting `swift-transformers` `Tokenizers.Tokenizer`).

**Critical:** `context.tokenizer` is only directly accessible inside the actor-isolated `perform` closure. It is `Sendable` (per `swift-transformers` 1.0.0) so the tokenizer reference can be hoisted out and stored on the `MLXTokenCounter`, then used from any actor.

### Cost per call

`tokenizer.encode(text:)` on a 512-char string is ~0.1-0.5 ms on M1 (sentencepiece is implemented in Rust under the hood for swift-transformers). For Phase 1's budget of ~5 token-count calls per predict (one per slot), total tokenizer cost adds ~1-3 ms to the TTFT. Cotypist's `TokenizationCache` (per NEXT-MILESTONE-NOTES.md §1) addresses repeated calls — explicitly out of scope for Phase 1 (KV milestone).

[VERIFIED: codebase grep — `context.tokenizer.encode(text:)` already used in `PredictorViewModel.swift:693, 701, 835, 851`. No new API to learn.]

[ASSUMED: encode cost ≤0.5 ms on M1 for 512-char input. Not directly measured. Risk: if proven larger by SouffleuseBench, consider caching the last-encoded `beforeCursor` token count keyed on string identity.]

### Lifecycle: when to construct the counter

Because the tokenizer reference is reachable only inside `container.perform`, the cleanest pattern is:

```swift
// In PredictorViewModel.predict(), inside the detached Task:
let metrics = try await container.perform { context -> StreamMetrics in
    let counter = MLXTokenCounter(tokenizer: context.tokenizer)
    let builder = PromptBuilder(counter: counter)
    let built = builder.build(
        system: systemMessage,
        customInstructions: customInstructions,
        contextPrefix: contextPrefix,
        fewShot: examplesBlock,
        beforeCursor: userTail
    )
    // Then encode and run generation as today:
    let promptTokens = context.tokenizer.encode(text: built.text)
    // ...
}
```

The builder is reconstructed per-predict (cheap, value type). The tokenizer reference is captured once per `perform` block. No global state.

**Alternative for fewer allocations:** Hoist `MLXTokenCounter` to a `@MainActor` property on `PredictorViewModel`, populated once at `loadModel()` completion. This requires confirming `tokenizer` outlives the container, which it does (the container owns it, and the model lifecycle is the same as the predictor's). Cleaner but more state to track. Planner trade-off.

### What if we need to cache counts

Don't — Phase 1 budget makes this premature optimization. The KV milestone (V2 KV-01..KV-04) explicitly owns tokenization caching. For Phase 1, accept the ~1-3 ms overhead; if SouffleuseBench shows ≥10 ms regression, the planner can revisit.

[VERIFIED: `MLXLMCommon` re-exports `swift-transformers` `Tokenizers.Tokenizer`. Source: `Package.resolved` shows `swift-transformers` 1.0.0 transitive. Per code pattern at `PredictorViewModel.swift:693`.]

---

## 3. Slot Eviction Algorithm — `beforeCursor` head-truncation

Pseudo-code for D-11 (truncation côté tête, frontière phrase-puis-mot, jamais mid-word).

### Algorithm

```
Input: text (the full beforeCursor), budget (max tokens), counter (TokenCounting)
Output: head-truncated string that preserves the tail, ≤ budget tokens, with cut at sentence-then-word boundary

1. If counter.countTokens(text) ≤ budget: return text unchanged.

2. Compute target_char_estimate = (budget / current_token_count) * text.count.
   (Rough proportional estimate to seed the search.)

3. Identify candidate cut points = positions in text from start, ordered preferentially:
   a. Sentence boundaries: positions immediately AFTER ". ", "! ", "? ", "… ", or "\n\n"
   b. Word boundaries: positions immediately AFTER whitespace (`isWhitespace`)
   Filter to cut points where text.suffix(from: cut_point).count >= target_char_estimate * 0.5
   (we want to drop at least some content but not over-trim).

4. Binary-search the largest cut point such that
   counter.countTokens(text.suffix(from: cut_point)) ≤ budget.

5. Among candidates that fit:
   - Prefer the SMALLEST cut (= MOST text retained) that is at a sentence boundary.
   - If no sentence boundary fits, fall back to the SMALLEST cut at a word boundary.
   - Never return a string starting mid-word.

6. If even the LAST word boundary doesn't fit (text is one giant token blob with no whitespace):
   - Search remaining whitespace cut points right-to-left until one fits, OR
   - Return "" (defensive — should never happen with real user text).

7. Never cut mid-word: invariant enforced by step 5's candidate generation.
```

### Edge cases

| Edge case | Behavior |
|-----------|----------|
| Text shorter than budget | Return unchanged (step 1 short-circuit) |
| Text with no whitespace (URL-only, base64 blob) | Step 6 falls through; if no whitespace cut fits, return "" with `truncatedSlots.insert(.beforeCursor)` flag set — caller can log a `Log.warn(.prompt, "beforecursor_no_boundary")` (no user text in log) |
| Multi-language sentence delimiters | Recognize `。` (Chinese/Japanese full stop), `！` `？` (fullwidth), `\n\n` (paragraph break). Add to the sentence terminator list. Reference: same lists already used in `PredictorViewModel.swift:312-318` (`. ", "? ", "! ", "… "`) — extend with paragraph break for the head-truncation case |
| Budget = 0 | Return "" |
| Budget ≥ count | Return unchanged |
| Text contains only whitespace | Return "" (step 6 default) |
| `text` is empty | Return "" |

### Reusability

The `truncateHead(_:toBudget:)` method on `TokenCounting` lets each tokenizer implementation choose its own efficient strategy. The mock implementation in tests can use a simple "drop tokens from the front until count ≤ budget" approach since tests don't care about real boundary detection — they care that the builder calls `truncateHead` when expected.

[VERIFIED: Sentence-terminator list pattern exists at `PredictorViewModel.swift:312-318` (`capToWords`) and 569-575 (`onChunk` truncation). Reusing those character constants ensures consistency with the existing visible-suffix logic.]

[ASSUMED: Binary-search over candidate cut points is fast enough at ~5-10 iterations per predict. The text is ≤ a few thousand chars typically.]

---

## 4. Budget Allocation Proposal

Concrete starting numbers, with justification. Final values determined at planner stage with a SouffleuseBench reading.

| Slot | Tokens | Why |
|------|--------|-----|
| `system` | 80 | Current `autocompleteSystemPrompt` is ~130 chars (~30-40 tokens). With language-steering header adds ~30 chars (~10 tokens). Headroom for future system additions. |
| `customInstructions` | 40 | Optional. Today's median user-supplied custom instructions are ~80-150 chars; the cap of 40 tokens (~150 chars) covers the common case and truncates over-eager personas. |
| `contextPrefix` | 150 | `EnrichedContext.prefix` is already capped (`clipboardCap=200 chars`, `visibleCap=240 chars`). Adding app+window prose (~50 chars), total caps near 500 chars = ~150 tokens. Match the existing visible cap. |
| `fewShot` | 80 | `SimilarHistoryRetrieval.maxConcatenatedExamplesChars=400`. 400 chars ≈ 100-130 tokens with sentencepiece on French. Budget 80 means few-shot is the first slot squeezed if global cap fires. |
| `beforeCursor` | 200 | Replaces the 512-char dumb truncate. 200 tokens ≈ 600-800 chars in French (sentencepiece fragments accented words). Larger than today's effective `llmTail` (`String(userTail.suffix(512))` at `PredictorViewModel.swift:658`). |
| **Sum** | **550** | Sum exceeds global cap (512) by design — D-04 "Allocation fixe par slot" means the global cap is a safety net, not the sum of per-slot budgets. If every slot fills to its max simultaneously, the planner needs to decide a tie-breaker: drop `fewShot` first (it's a quality enhancer, not core signal), then `customInstructions`, then truncate `contextPrefix`, then truncate `beforeCursor`. **The current 512 char input gives ~150-200 tokens — Phase 1 with these budgets gives 350-550 tokens, a 2.5-3× increase.** |

### TTFT consideration

The MLX prefill cost scales roughly linearly with prompt token count. Doubling the prompt from ~200 to ~400 tokens may add ~30-50 ms to TTFT on M1 (per the rough rule of thumb cited in `.planning/codebase/CONCERNS.md` §"LLM prefill on every keystroke"). This is acceptable per the milestone's "qualité prime sur vitesse brute" core value, but worth measuring with `SouffleuseBench` mid-phase to confirm we stay near the 80 ms baseline.

### Tunability

Make `PromptBudget.phase1Default` swappable via an init parameter from `PredictorViewModel` so the planner can experiment without code edits. Don't ship a UserDefaults pref — these numbers are developer-tuning concerns, not user-facing.

[VERIFIED: `EnrichedContext.clipboardCap = 200`, `EnrichedContext.visibleCap = 240` in `Sources/SouffleuseContext/ContextEnricher.swift:12-13`. `SimilarHistoryRetrieval.maxConcatenatedExamplesChars = 400` at `SimilarHistoryRetrieval.swift:30`. `String(userTail.suffix(512))` at `PredictorViewModel.swift:658`.]

[ASSUMED: TTFT delta of ~30-50 ms when prompt doubles. Based on rough rule of thumb in CONCERNS.md, not measured. Plan should include a SouffleuseBench measurement task.]

---

## 5. Integration with `predict()`

Exact insertion plan with both branches (instruct chat template AND base/PT raw text).

### Current code shape (lines 478-513 + 632-664)

The current flat-string assembly happens in two places:
1. **Lines 478-513** (synchronous, on `@MainActor`): builds `systemMessage` and `basePreamble` from `customInstructions` + `contextPrefix`.
2. **Lines 632-664** (detached `Task`, inside `container.perform`): retrieves `examplesBlock` via `await history.similarEntries(...)`, builds `basePromptText = basePreamble + examplesBlock + "\n\n" + llmTail`, optionally calls `applyChatTemplate` for instruct models.

### Insertion plan

The builder replaces both steps. Because the tokenizer is reachable only inside `container.perform`, **all builder construction must move into the detached Task / `container.perform` closure.** The `systemMessage`, `customInstructions`, `contextPrefix` strings are computed at the `@MainActor` entry as today and captured into the closure.

```swift
func predict(prefix: String, contextPrefix: String = "", customInstructions: String = "") {
    // ... existing gates: cache hit, undo-as-ghost, hasCompletedFirstWord ...

    // ── Existing system/customInstructions/contextPrefix string assembly (lines 478-513) ──
    // stays at the top to keep MainActor work cheap; these strings are captured
    // into the detached Task below.
    let detectedLanguage = Self.detectLanguage(in: userTail)
    var systemParts: [String] = [Self.buildSystemPrompt(detectedLanguage: detectedLanguage)]
    if !customInstructions.isEmpty {
        systemParts.append("Style and persona:\n\(customInstructions.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    if !contextPrefix.isEmpty {
        systemParts.append("Context:\n\(contextPrefix.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    let systemMessage = systemParts.joined(separator: "\n\n")

    // ── NEW: feature-flag detection at call site ──
    let useBuilder = ProcessInfo.processInfo.environment["SOUFFLEUSE_PROMPT_BUILDER"]
        .flatMap { $0.isEmpty ? nil : $0 } != nil

    // ── basePreamble path (unchanged when useBuilder == false) ──
    var parts: [String] = []
    if !customInstructions.isEmpty {
        parts.append(customInstructions.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    if !contextPrefix.isEmpty {
        parts.append(contextPrefix.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    let basePreamble = parts.isEmpty ? "" : parts.joined(separator: "\n\n") + "\n\n"

    // ... existing onChunk + parameter snapshotting unchanged ...

    currentTask = Task { [weak self] in
        _ = await previousTask?.value
        if Task.isCancelled { return }

        // ── Few-shot retrieval (unchanged, lives in Task because store is actor) ──
        var examplesBlock = ""
        if personalizationStrength > 0, let history {
            let similar = await history.similarEntries(to: userTail, limit: fewShotK)
            if !similar.isEmpty {
                examplesBlock = SimilarHistoryRetrieval.buildExamplesBlock(from: similar)
            }
        }

        let llmTail = String(userTail.suffix(512))  // legacy path only

        do {
            let metrics = try await container.perform { context -> StreamMetrics in
                let promptTokens: [Int]

                if useBuilder {
                    // ── NEW PATH ──
                    let counter = MLXTokenCounter(tokenizer: context.tokenizer)
                    let builder = PromptBuilder(counter: counter, budget: .phase1Default)
                    let built = builder.build(
                        system: systemMessage,
                        customInstructions: "",  // already folded into systemMessage at line 487
                        contextPrefix: "",       // ditto, at line 491
                        fewShot: examplesBlock,
                        beforeCursor: userTail   // FULL tail; builder handles head-truncation
                    )
                    Log.info(.predictor, "prompt_built", count: built.totalTokens)

                    if isInstructModel {
                        // Instruct path: feed `built.text` minus the system part as user, system as system.
                        // For Phase 1 simplest: system = systemMessage, user = built.beforeCursorView
                        // (need a way for the builder to expose the head-truncated beforeCursor separately).
                        // ALTERNATIVE: pass `built.text` as user message, empty system. Less idiomatic but works.
                        let messages: [[String: String]] = [
                            ["role": "system", "content": systemMessage],
                            ["role": "user", "content": builder.extractSlotText(built, slot: .beforeCursor)],
                        ]
                        if let templated = try? context.tokenizer.applyChatTemplate(messages: messages) {
                            promptTokens = templated
                        } else {
                            promptTokens = context.tokenizer.encode(text: built.text)
                        }
                    } else {
                        promptTokens = context.tokenizer.encode(text: built.text)
                    }
                } else {
                    // ── LEGACY PATH (verbatim from current code) ──
                    let basePromptText: String
                    if examplesBlock.isEmpty {
                        basePromptText = basePreamble + llmTail
                    } else {
                        basePromptText = basePreamble + examplesBlock + "\n\n" + llmTail
                    }

                    if isInstructModel {
                        let messages: [[String: String]] = [
                            ["role": "system", "content": systemMessage],
                            ["role": "user", "content": llmTail],
                        ]
                        if let templated = try? context.tokenizer.applyChatTemplate(messages: messages) {
                            promptTokens = templated
                        } else {
                            promptTokens = context.tokenizer.encode(text: basePromptText)
                        }
                    } else {
                        promptTokens = context.tokenizer.encode(text: basePromptText)
                    }
                }

                // ... existing generation loop unchanged ...
            }
            // ...
        }
    }
}
```

### Required builder extension

The instruct-model path needs to extract the truncated `beforeCursor` as a separate string so it can fill the chat template `user` role (the rest of the slots fold into `system`). Two options:

**Option A — expose all truncated slot texts on `BuiltPrompt`:**
```swift
public struct BuiltPrompt {
    public let text: String
    public let slotTexts: [PromptSlot: String]  // post-truncation slot bodies
    // ...
}
```
Caller does `built.slotTexts[.beforeCursor] ?? ""`. Clean.

**Option B — second build entry point that returns slot-level structure:**
```swift
public func buildStructured(...) -> [PromptSlot: String]
```
And the caller assembles per chat template. Symmetric with the chat template's own slot-orientation.

Option A is simpler and what the snapshot tests want — recommend planner picks Option A.

### Migration removal (end of Phase 1)

Once the replay verdict is positive and the 94 + new snapshot tests are green:
1. Delete the `useBuilder` branch (keep only the builder path).
2. Delete `basePreamble` assembly (lines 506-513) at MainActor.
3. Delete `llmTail` (line 658) and the legacy `basePromptText` construction (660-664).
4. Delete the env var detection.

[VERIFIED: predict() shape via line-by-line read of `Sources/Souffleuse/PredictorViewModel.swift` lines 368-817. Chat template path at line 690-694, base path at line 701.]

---

## 6. Replay Harness Extension

How to add `--replay` to `SouffleuseCoherence/main.swift` (D-05).

### Argument parsing

No new dependency — manual parse consistent with the existing env-var style:

```swift
@main
struct Coherence {
    static func main() async {
        let args = CommandLine.arguments
        if args.count >= 3, args[1] == "--replay" {
            await runReplay(scenariosPath: args[2])
        } else {
            await runDefaultCoherenceLoop()  // existing behaviour
        }
    }
}
```

CLI usage:
```bash
swift run SouffleuseCoherence --replay .planning/phases/01-foundation-hypothesis-validation/replay-scenarios.json
```

### Scenario loader

```swift
struct Scenario: Codable, Sendable {
    let id: String
    let label: String
    let bundleID: String
    let windowTitle: String?
    let contextPrefix: String     // assembled EnrichedContext.prefix-style string
    let userTail: String
    let notes: String?
    let customInstructions: String?  // optional; defaults to ""
}

struct ScenarioFile: Codable, Sendable {
    let version: Int   // = 1, matches the AllowlistFile precedent
    let scenarios: [Scenario]
}

func loadScenarios(from path: String) throws -> ScenarioFile {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(ScenarioFile.self, from: data)
}
```

### Two-variant predict loop

For each scenario, run `predict` twice:

```swift
func runScenario(_ s: Scenario, container: ModelContainer) async -> (withCtx: String, withoutCtx: String) {
    // Variant A: WITH context
    let withCtx = await rawGhost(
        scenario: s,
        contextPrefix: s.contextPrefix,
        container: container
    )
    // Variant B: WITHOUT context (contextPrefix disabled)
    let withoutCtx = await rawGhost(
        scenario: s,
        contextPrefix: "",
        container: container
    )
    return (withCtx, withoutCtx)
}
```

`rawGhost` reuses the existing pattern from `SouffleuseCoherence/main.swift:181-194` but routes through the `PromptBuilder` so the replay tests the actual production code path:

```swift
func rawGhost(scenario: Scenario, contextPrefix: String, container: ModelContainer) async -> String {
    let result = try? await container.perform { ctx -> String in
        let counter = MLXTokenCounter(tokenizer: ctx.tokenizer)
        let builder = PromptBuilder(counter: counter)
        let built = builder.build(
            system: Prod.systemPrompt(),  // mirror PredictorViewModel
            customInstructions: scenario.customInstructions ?? "",
            contextPrefix: contextPrefix,
            fewShot: "",  // Phase 1: few-shot not exercised in replay
            beforeCursor: scenario.userTail
        )
        let toks = ctx.tokenizer.encode(text: built.text)
        let input = LMInput(tokens: MLXArray(toks))
        let params = GenerateParameters(
            maxTokens: Prod.maxTokens, temperature: 0, topP: 0.9,
            repetitionPenalty: 1.0, repetitionContextSize: 32
        )
        let stream = try MLXLMCommon.generate(input: input, parameters: params, context: ctx)
        var out = ""
        for await ev in stream { if case .chunk(let t) = ev { out += t } }
        return out
    }
    let raw = result ?? ""
    return Prod.displayGhost(rawSnapshot: raw, prefix: scenario.userTail)
}
```

### REPLAY-RESULTS.md writer

Generate one markdown section per scenario:

```swift
func renderReplayResults(
    scenarios: [Scenario],
    results: [(scenario: Scenario, withCtx: String, withoutCtx: String)]
) -> String {
    var out = """
    # Replay Results — Phase 1 Hypothesis Validation

    **Generated:** \(ISO8601DateFormatter().string(from: Date()))
    **Model:** \(modelId)
    **Scenarios:** \(scenarios.count)

    ---

    """
    for (i, r) in results.enumerated() {
        out += """

        ## \(i+1). [\(r.scenario.id)] \(r.scenario.label)

        - **bundleID:** `\(r.scenario.bundleID)`
        - **windowTitle:** \(r.scenario.windowTitle.map { "`\($0)`" } ?? "—")
        - **userTail:** `\(r.scenario.userTail.replacingOccurrences(of: "`", with: "\\`"))`
        - **notes:** \(r.scenario.notes ?? "—")

        | Variant | Ghost |
        |---------|-------|
        | **WITHOUT context** | `\(r.withoutCtx)` |
        | **WITH context**    | `\(r.withCtx)` |

        **Verdict:** [ ] ✓ with-context better  [ ] = neutral  [ ] ✗ with-context worse

        **Human note:** _(fill in)_

        ---

        """
    }
    let countSlot = """

    ## Tally (fill in after eyeball pass)

    - ✓ with-context better: ___ / \(scenarios.count)
    - = neutral:              ___ / \(scenarios.count)
    - ✗ with-context worse:   ___ / \(scenarios.count)

    **AUDIT-02 gate (planner-set):** ≥ ___ / \(scenarios.count) ✓ verdicts to proceed to Phase 2.

    """
    return out + countSlot
}
```

Write to `.planning/phases/01-foundation-hypothesis-validation/REPLAY-RESULTS.md` (D-09).

**Idempotency:** Each run overwrites the file. If user-edited verdict marks are precious (filled-in checkboxes), the writer should preserve them by reading the existing file first and merging the `[ ]` → `[x]` state per scenario id. **Planner decision:** Phase 1 simplicity = just overwrite; if iteration churn becomes painful, add merge later.

### Reuse points with existing bench machinery

- `MLX.GPU.set(cacheLimit:)` + `LLMModelFactory.shared.loadContainer` setup at `SouffleuseCoherence/main.swift:224-230` — keep verbatim.
- `Prod` enum (lines 25-118) — keep the `displayGhost` logic, optionally factor out shared truncation into `SouffleuseTyping` or `SouffleusePrompt` if duplication grows. Phase 1: leave duplicated, mark with `// TODO Phase 2: dedupe`.
- `SOUFFLEUSE_MODEL` env var for model override — keep, applies to replay too.

[VERIFIED: existing structure of `Sources/SouffleuseCoherence/main.swift` line-by-line; `@main struct Coherence` pattern at line 211, model load at 224-230, `rawGhost` at 181-194.]

---

## 7. Scenario File Schema

Concrete JSON schema for `replay-scenarios.json` (D-07).

### Schema

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "Souffleuse Phase 1 Replay Scenarios",
  "type": "object",
  "required": ["version", "scenarios"],
  "properties": {
    "version": { "type": "integer", "const": 1 },
    "scenarios": {
      "type": "array",
      "minItems": 10,
      "maxItems": 20,
      "items": {
        "type": "object",
        "required": ["id", "label", "bundleID", "contextPrefix", "userTail"],
        "properties": {
          "id":             { "type": "string", "pattern": "^[a-z0-9-]+$" },
          "label":          { "type": "string" },
          "bundleID":       { "type": "string" },
          "windowTitle":    { "type": ["string", "null"] },
          "contextPrefix":  { "type": "string", "description": "Pre-assembled EnrichedContext.prefix-style string. Empty for cold-start scenarios." },
          "userTail":       { "type": "string" },
          "notes":          { "type": ["string", "null"] },
          "customInstructions": { "type": ["string", "null"] }
        }
      }
    }
  }
}
```

### Initial seed (12 scenarios)

```json
{
  "version": 1,
  "scenarios": [
    {
      "id": "slack-empty-channel",
      "label": "Slack: empty message in channel #equipe-produit",
      "bundleID": "com.tinyspeck.slackmacgap",
      "windowTitle": "Slack — #equipe-produit",
      "contextPrefix": "App Slack, window \"#equipe-produit\". On screen: Marie: « On a une demande urgente de Carrefour pour la migration ». Paul: « Je peux prendre, j'ai du temps cet aprem ».",
      "userTail": "",
      "notes": "Cold start — champ vide, contexte de canal visible. Sans contexte: ghost générique \"Coucou !\". Avec contexte: devrait proposer une réponse liée à la demande Carrefour."
    },
    {
      "id": "slack-reply-mid",
      "label": "Slack: réponse en cours après salutation",
      "bundleID": "com.tinyspeck.slackmacgap",
      "windowTitle": "Slack — DM Paul",
      "contextPrefix": "App Slack, window \"DM Paul\". On screen: Paul: « Tu peux me filer un coup de main sur le bug paiement ? ».",
      "userTail": "Hello Paul, je ",
      "notes": "Réponse engagée mais incomplète. Doit continuer naturellement (\"regarde ça tout de suite\" plutôt que \"vais bien merci\")."
    },
    {
      "id": "mail-new-subject",
      "label": "Mail: champ sujet vide, nouveau message",
      "bundleID": "com.apple.mail",
      "windowTitle": "Nouveau message — Mail",
      "contextPrefix": "App Mail, window \"Nouveau message\". On screen: À: client@example.com. Cc: equipe@cocotypist.io. Sujet: .",
      "userTail": "",
      "notes": "Sujet vide. Avec contexte → propose un sujet en lien avec le destinataire."
    },
    {
      "id": "mail-reply-body",
      "label": "Mail: corps de réponse, salutation seulement",
      "bundleID": "com.apple.mail",
      "windowTitle": "Re: Devis Q3 — Mail",
      "contextPrefix": "App Mail, window \"Re: Devis Q3\". On screen: Bonjour, suite à notre échange du 15 mai, je vous joins le devis révisé. N'hésitez pas si vous avez des questions. Cordialement, Sophie.",
      "userTail": "Bonjour Sophie,\n\nMerci pour ",
      "notes": "Devrait enchaîner naturellement (\"l'envoi du devis\" / \"votre retour\")."
    },
    {
      "id": "vscode-comment-fn",
      "label": "VSCode: commentaire au-dessus d'une fonction Swift",
      "bundleID": "com.microsoft.VSCode",
      "windowTitle": "PredictorViewModel.swift — Souffleuse",
      "contextPrefix": "App Visual Studio Code, window \"PredictorViewModel.swift — Souffleuse\". On screen: func capToWords(_ text: String, max: Int) -> String { ... } func detectLanguage(in text: String) -> String? { ... }.",
      "userTail": "/// ",
      "notes": "Doc comment au-dessus d'une fonction. Avec contexte → devrait proposer un summary lié au code visible (truncation, language detection)."
    },
    {
      "id": "vscode-impl-line",
      "label": "VSCode: implémentation, milieu de fonction",
      "bundleID": "com.microsoft.VSCode",
      "windowTitle": "PromptBuilder.swift — Souffleuse",
      "contextPrefix": "App Visual Studio Code, window \"PromptBuilder.swift\". On screen: public struct PromptBuilder { public let counter: TokenCounting; public func build(...) -> BuiltPrompt { ... }.",
      "userTail": "        let total = ",
      "notes": "Au milieu d'une expression. Devrait compléter avec un nom de variable plausible."
    },
    {
      "id": "notes-blank",
      "label": "Notes: nouvelle note vide",
      "bundleID": "com.apple.Notes",
      "windowTitle": "Nouvelle note — Notes",
      "contextPrefix": "App Notes, window \"Nouvelle note\". On screen: Notes précédentes: « Liste courses du 12 mai », « Idées projet souffleuse »",
      "userTail": "",
      "notes": "Champ vide, contexte de notes adjacentes. Sans contexte → fortune cookie. Avec → peut-être un titre cohérent."
    },
    {
      "id": "intercom-cs-reply",
      "label": "Intercom: réponse customer support, milieu de phrase",
      "bundleID": "com.intercom.intercom-inbox",
      "windowTitle": "Intercom — Conversation #4821",
      "contextPrefix": "App Intercom, window \"Conversation #4821\". On screen: Client: « Mon paiement par carte n'a pas fonctionné hier soir vers 22h, j'ai eu un message d'erreur ‹ 3D Secure failed ›. Pouvez-vous m'aider ? ».",
      "userTail": "Bonjour, je suis désolé pour ce souci de paiement. Je ",
      "notes": "Réponse CS engagée. Devrait continuer en direction \"vais vérifier votre transaction\" plutôt que générique."
    },
    {
      "id": "browser-form-name",
      "label": "Brave: champ Nom dans un formulaire",
      "bundleID": "com.brave.Browser",
      "windowTitle": "Inscription — Cocotypist",
      "contextPrefix": "App Brave, window \"Inscription — Cocotypist\". On screen: Inscription. Nom: ___. Prénom: ___. Email: ___. Mot de passe: ___.",
      "userTail": "",
      "notes": "Champ formulaire vide. Difficile sans field metadata (Phase 2). Doit AU MINIMUM ne pas proposer de phrase."
    },
    {
      "id": "discord-reply",
      "label": "Discord: réply dans un fil",
      "bundleID": "com.hnc.Discord",
      "windowTitle": "Discord — #dev-souffleuse",
      "contextPrefix": "App Discord, window \"#dev-souffleuse\". On screen: alice: « le bench TTFT remonte 95ms avec le builder activé, c'est attendu ? ». bob: « oui c'est la 1ère mesure post-refactor ».",
      "userTail": "yep on devrait pouvoir ",
      "notes": "Conversation technique en français mêlé d'anglais. Doit continuer dans le même registre."
    },
    {
      "id": "mid-edit-rewrite",
      "label": "Notes: édition au milieu d'un texte existant",
      "bundleID": "com.apple.Notes",
      "windowTitle": "Compte-rendu réunion — Notes",
      "contextPrefix": "App Notes, window \"Compte-rendu réunion\".",
      "userTail": "L'équipe a discuté du planning Q3 et a décidé de prioriser ",
      "notes": "Curseur au milieu d'une phrase déjà engagée. Contexte = juste app+window, signal vient surtout du userTail. Test du baseline beforeCursor budget."
    },
    {
      "id": "long-tail-truncation",
      "label": "Mail: corps très long approchant la budget cap",
      "bundleID": "com.apple.mail",
      "windowTitle": "Re: Spec v2 — Mail",
      "contextPrefix": "App Mail, window \"Re: Spec v2\". On screen: Spec v2 du PromptBuilder. Points discutés: 1. allocation par slot 2. eviction policy 3. tests snapshot.",
      "userTail": "Bonjour Alex,\n\nMerci pour ta proposition de spec sur le PromptBuilder. J'ai bien noté les trois points que tu soulèves : l'allocation par slot avec budgets fixes, la policy d'éviction qui préfère couper sur frontière de phrase puis de mot, et les tests snapshot indépendants de MLX. Sur le point 1, je suis aligné — c'est cohérent avec ce que Cotypist fait en interne. Sur le point 2, j'aimerais juste qu'on s'assure qu'on ne ",
      "notes": "Test du head-truncation: userTail ~750 chars, budget beforeCursor=200 tokens (~600 chars). Le builder doit cut head sur frontière phrase, jamais mid-mot. Doit continuer le raisonnement engagé (\"coupe pas mid-word\" ou similaire)."
    }
  ]
}
```

**Justification of scenarios:** Cover the rebrand of phase 1 hypothesis ("ghost junk on empty prefix") with 4 cold-start cases (`slack-empty-channel`, `mail-new-subject`, `notes-blank`, `browser-form-name`), 4 short-prefix-with-context cases (`slack-reply-mid`, `mail-reply-body`, `intercom-cs-reply`, `discord-reply`), 2 code editing cases (`vscode-comment-fn`, `vscode-impl-line`), 1 mid-edit (`mid-edit-rewrite`), and 1 head-truncation stress test (`long-tail-truncation`). Languages: 10 FR, 1 EN-FR mix, 1 code. Apps: Slack ×2, Mail ×3, VSCode ×2, Notes ×2, Intercom ×1, Brave ×1, Discord ×1.

[VERIFIED: Bundle IDs against the project's `personalizationBundleBlocklist` / `bundleBlocklist` in `SouffleuseAppDelegate.swift:19-44` — none of the listed bundles are in the blocklist, confirming they're representative of typical user surfaces.]

---

## 8. Test Strategy

XCTest snapshot pattern for the builder + how to keep 94 existing tests green during the feature-flag period.

### Mock `TokenCounting`

```swift
// In Tests/SouffleuseTests/PromptBuilderTests.swift
import Testing
@testable import SouffleusePrompt

/// Deterministic mock: counts tokens as whitespace-separated words.
/// Truncation: drop words from the head until count ≤ budget, then restore
/// the largest sentence-prefix that still fits.
struct WordCountTokenCounter: TokenCounting {
    func countTokens(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
    func truncateHead(_ text: String, toBudget budget: Int) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count > budget else { return text }
        return words.suffix(budget).joined(separator: " ")
    }
}

/// Optional stricter mock that enforces sentence-boundary head-truncation,
/// to exercise the boundary-detection branch of TokenCounting implementations.
struct SentenceAwareTokenCounter: TokenCounting {
    // ... uses regex on ". ", "? ", "! " ...
}
```

### Snapshot tests (BUILDER-03, TEST-02)

```swift
@Test func builderAssemblesAllSlotsInOrder() {
    let counter = WordCountTokenCounter()
    let builder = PromptBuilder(counter: counter, budget: .phase1Default)
    let built = builder.build(
        system: "You are an inline autocomplete.",
        customInstructions: "Be concise.",
        contextPrefix: "App Slack, window #equipe.",
        fewShot: "Hello team how is it going",
        beforeCursor: "Bonjour, je voulais vous dire"
    )
    #expect(built.text == """
    You are an inline autocomplete.

    Be concise.

    App Slack, window #equipe.

    Hello team how is it going

    Bonjour, je voulais vous dire
    """)
    #expect(built.totalTokens == counter.countTokens(built.text))
    #expect(built.truncatedSlots.isEmpty)
}

@Test func builderTruncatesBeforeCursorHeadAtSentenceBoundary() {
    let counter = WordCountTokenCounter()
    let budget = PromptBudget(global: 100, perSlot: [.beforeCursor: 10])
    let builder = PromptBuilder(counter: counter, budget: budget)
    let longTail = "First sentence here. Second sentence here. Third short."
    let built = builder.build(
        system: "", customInstructions: "", contextPrefix: "", fewShot: "",
        beforeCursor: longTail
    )
    // 12 words → budget 10 → drop "First sentence here." (head sentence)
    #expect(built.text == "Second sentence here. Third short.")
    #expect(built.truncatedSlots.contains(.beforeCursor))
}

@Test func builderNeverCutsMidWord() {
    let counter = WordCountTokenCounter()
    let budget = PromptBudget(global: 100, perSlot: [.beforeCursor: 3])
    let builder = PromptBuilder(counter: counter, budget: budget)
    let text = "Salutations bienveillantes mon ami fidèle"
    let built = builder.build(
        system: "", customInstructions: "", contextPrefix: "", fewShot: "",
        beforeCursor: text
    )
    // 5 words → budget 3 → drop first 2; remainder MUST start at a word boundary.
    let first = built.text.first!
    #expect(first.isLetter || first.isNumber)
    #expect(!built.text.contains(" "))  // 3 words, no leading space
    // More importantly: ensure assertEqual against expected text (snapshot test)
    #expect(built.text == "mon ami fidèle")
}

@Test func builderHandlesEmptySlots() {
    let counter = WordCountTokenCounter()
    let builder = PromptBuilder(counter: counter)
    let built = builder.build(
        system: "Sys", customInstructions: "", contextPrefix: "", fewShot: "",
        beforeCursor: "User text"
    )
    // Empty slots contribute nothing — no extra blank lines.
    #expect(built.text == "Sys\n\nUser text")
}

@Test func builderHonorsPerSlotBudgetsIndependently() {
    // D-04: no cross-slot stealing. If contextPrefix fits within its 150
    // budget but beforeCursor overflows its 200, only beforeCursor is truncated.
    // ...
}

@Test func builderRecordsTokenCountsPerSlot() {
    // Validates BuiltPrompt.slotTokenCounts is populated correctly.
    // ...
}
```

### Determinism assertion

Run the same `build(...)` call 100 times; require all `BuiltPrompt`s `Equatable`-equal. (Catches a future regression where the builder accidentally introduces nondeterminism through a `Set` iteration or unsorted dictionary.)

```swift
@Test func builderIsDeterministic() {
    let counter = WordCountTokenCounter()
    let builder = PromptBuilder(counter: counter)
    let first = builder.build(system: "s", customInstructions: "c", contextPrefix: "p", fewShot: "f", beforeCursor: "b")
    for _ in 0..<99 {
        let again = builder.build(system: "s", customInstructions: "c", contextPrefix: "p", fewShot: "f", beforeCursor: "b")
        #expect(again == first)
    }
}
```

### Keeping the 94 existing tests green during feature-flag period (TEST-01)

- The feature flag (`SOUFFLEUSE_PROMPT_BUILDER` env var) defaults to OFF. With no env var set, `predict()` takes the legacy path verbatim. **Every existing test runs in the legacy path** — none of them spawn child processes with the env var set.
- Add a new test file `PromptBuilderTests.swift` to `Tests/SouffleuseTests/`. Register it in `Package.swift:99-110` test target dependencies — add `SouffleusePrompt` to the dependency list.
- Existing `PredictorViewModel`-touching tests: none exist (per CONCERNS.md §"Test Coverage Gaps" — `PredictorViewModel.predict()` is not exercised end-to-end). So no test changes needed for the legacy path.
- After Phase 1 removal of the flag, snapshot tests stay green because they exercise the builder directly, not via `PredictorViewModel`.

### New test naming convention

Follow the existing project pattern (TESTING.md): test functions read as descriptive sentences without `test_` prefix. Examples already shown: `builderAssemblesAllSlotsInOrder`, `builderTruncatesBeforeCursorHeadAtSentenceBoundary`, `builderNeverCutsMidWord`. File name: `PromptBuilderTests.swift`.

[VERIFIED: Test pattern from `Tests/SouffleuseTests/ChunkSplitterTests.swift`, `Tests/SouffleuseTests/SimilarHistoryRetrievalTests.swift`. Uses Swift Testing (`import Testing` + `@Test` + `#expect`).]

---

## 9. SPM Target Wiring

Exact diff for `Souffleuse/Package.swift` (D-10).

### Add product declaration (after line 22)

```swift
.library(name: "SouffleusePersonalization", targets: ["SouffleusePersonalization"]),
+.library(name: "SouffleusePrompt", targets: ["SouffleusePrompt"]),
],
```

### Add target declaration (after line 54)

```swift
.target(
    name: "SouffleusePersonalization",
    dependencies: [
        "SouffleuseLog",
        .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
    ]
),
+.target(
+    name: "SouffleusePrompt",
+    dependencies: [
+        "SouffleuseLog",
+        .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
+    ]
+),
```

**Note:** D-10 mentions depending on `SouffleuseContext` (for `EnrichedContext` types). In Phase 1 the builder treats `contextPrefix` as an opaque string, so it does NOT actually need to import `SouffleuseContext`. Phase 2 may revisit. Recommendation: **omit `SouffleuseContext` from `SouffleusePrompt` deps at Phase 1** to keep the dependency graph minimal — add it only if/when the builder ingests typed `EnrichedContext`. Same for `SouffleusePersonalization`: Phase 1 receives the few-shot block as a string, so no need to import yet.

### Wire `Souffleuse` (app) to depend on it

```swift
.executableTarget(
    name: "Souffleuse",
    dependencies: [
        "SouffleuseAX",
        "SouffleuseContext",
        "SouffleuseInput",
        "SouffleuseLog",
        "SouffleuseOverlay",
        "SouffleuseTyping",
        "SouffleusePersonalization",
+       "SouffleusePrompt",
        .product(name: "MLXLLM", package: "mlx-swift-examples"),
        .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
    ]
),
```

### Wire `SouffleuseCoherence` (replay)

```swift
.executableTarget(
    name: "SouffleuseCoherence",
    dependencies: [
+       "SouffleusePrompt",
        .product(name: "MLXLLM", package: "mlx-swift-examples"),
        .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
    ]
),
```

### Wire test target

```swift
.testTarget(
    name: "SouffleuseTests",
    dependencies: [
        "Souffleuse",
        "SouffleuseAX",
        "SouffleuseContext",
        "SouffleuseLog",
        "SouffleuseOverlay",
        "SouffleuseTyping",
        "SouffleusePersonalization",
+       "SouffleusePrompt",
    ]
),
```

### Add directory + files

Create `Souffleuse/Sources/SouffleusePrompt/` with:
- `TokenCounting.swift`
- `PromptSlot.swift`
- `PromptBudget.swift`
- `BuiltPrompt.swift`
- `PromptBuilder.swift`

(One primary type per file — matches the project convention from CONVENTIONS.md §Naming Patterns.)

[VERIFIED: Package.swift declaration patterns at lines 9-23 (products), 27-110 (targets). Library precedent from `SouffleusePersonalization` declaration at lines 49-54.]

---

## 10. Audit Verification

How the new code paths interact with `audit.sh`'s 6 checks (TEST-03).

### Check-by-check assessment

| Check | Risk in new code | Mitigation |
|-------|------------------|------------|
| 1. No `print(` in shipping targets | Easy to accidentally add a `print(built.text)` while debugging | Use `Log.info(.predictor, "prompt_built", count: built.totalTokens)` only. Add `Sources/SouffleusePrompt` to `SHIPPING_DIRS` array in `audit.sh:7-15`. |
| 2. No `NSLog(` in shipping targets | Same as above | Same mitigation. |
| 3. No `os_log(...%@...userText)` | Builder receives user strings; tempting to log them | Builder MUST NOT call `os_log` or interpolate user text into any log call. |
| 4. Log file fields whitelisted | New `Log.info` calls must use only `(.module, "static_event_name", count: n)` form | Use only the existing `Log` API; the `StaticString` constraint enforces compile-time literal events. |
| 5. `history.aes` only in TypingHistoryStore + HistoryViewerWindow | Builder doesn't touch history files | Builder must not import `SouffleusePersonalization` for history access. It receives the few-shot block as an already-rendered string. |
| 6. No `Log.*` call interpolating `accepted` / `contextBefore` / `entry.` / `prefix` | Builder receives `beforeCursor` (the user's prefix). High temptation to log it for debug | **Hard rule: never `Log.*` with any string parameter coming from `build(...)`.** Snapshot tests catch correctness; logs stay counter-only. |

### Defensive design rules

1. **Builder API never accepts a logger.** No optional `logger:` parameter. Logging happens at the call site (`PredictorViewModel`) where context is well understood, never inside the builder.
2. **`BuiltPrompt.text` is a regular `String`, not wrapped in a "redacted" container.** The audit relies on convention + grep, not type discipline at this layer. Reviewers should pay attention to PR diffs adding `Log.*` lines that mention `built`, `slot`, `text`, `prompt`, `beforeCursor`.
3. **Add `Sources/SouffleusePrompt` to `audit.sh`'s `SHIPPING_DIRS`.** Without this, the grep checks skip the new module — silently allowing `print(...)` slip-throughs.

### Concrete audit.sh diff

```bash
SHIPPING_DIRS=(
  "Sources/Souffleuse"
  "Sources/SouffleuseAX"
  "Sources/SouffleuseContext"
  "Sources/SouffleuseInput"
  "Sources/SouffleuseLog"
  "Sources/SouffleuseOverlay"
  "Sources/SouffleusePersonalization"
+ "Sources/SouffleusePrompt"
)
```

### `PredictDebug` interaction

`PredictDebug.log` (lines 15-36 of `PredictorViewModel.swift`) is env-gated via `SOUFFLEUSE_PREDICT_LOG`. Current production audit explicitly does NOT scan for `/tmp/souffleuse-*.log` writes (per CONCERNS.md §"Security Considerations"). When wiring the builder, **do not extend `PredictDebug` into `SouffleusePrompt`**. If dev tracing is needed inside the builder, route through `PredictorViewModel.predict()` which already has access to `PredictDebug`. Keep the builder pure.

### What does NOT need an audit change

- `SouffleuseCoherence` and tests are NOT in `SHIPPING_DIRS`. They can use `print(...)` freely (and the replay harness already does at `SouffleuseCoherence/main.swift:207-209`).

[VERIFIED: `audit.sh` 6-check structure at `Souffleuse/audit.sh` lines 22-68. SHIPPING_DIRS list at lines 7-15.]

---

## 11. Risks / Pitfalls

| # | Risk | Mitigation |
|---|------|------------|
| R1 | **Tokenizer cold-start cost** — first `encode(text:)` after model load may be slower than steady-state (lazy SP table init). Builder construction happens inside `container.perform` so the cost is paid on first predict. | Negligible (one-shot). If measured > 50 ms, hoist `MLXTokenCounter` to `@MainActor` property primed at `loadModel` completion. |
| R2 | **MLX threading constraints** — `context.tokenizer` reference: confirmed `Sendable` via `swift-transformers` 1.0.0 but capturing it outside `perform` is undocumented. | Construct `MLXTokenCounter` fresh inside each `perform` block (no hoisting). Cost is a struct allocation. |
| R3 | **Snapshot test brittleness across MLX versions** — if production tokenizer changes, snapshot tests would break too. | Mock tokenizer (`WordCountTokenCounter`) is independent of MLX. Snapshot tests use mock, not real tokenizer. Real tokenizer is exercised only via replay (which has eyeball verdict, not snapshot equality). |
| R4 | **Swift 6 actor isolation around tokenizer access** — `MLXTokenCounter` is `Sendable` but the `Tokenizer` it wraps may have isolation. | Mark `MLXTokenCounter` as a `Sendable struct` with `let` properties only. If `swift-transformers` `Tokenizer` is `Sendable` (verified for 1.0.0), no issue. If not, wrap in `@unchecked Sendable` with serial-queue justification comment. |
| R5 | **Eviction order ambiguity when multiple slots overflow** — D-04 says no cross-slot stealing, but if global cap fires AND multiple slots are at their per-slot budget, which gets squeezed first? | Add a fixed eviction priority constant on `PromptBudget`: `fewShot` → `customInstructions` → `contextPrefix` → `beforeCursor`. Tests assert this ordering. |
| R6 | **Few-shot interaction with builder** — `examplesBlock` retrieval happens inside the detached Task (line 644), but builder construction is also inside the same Task. Builder needs `examplesBlock` ready before `build(...)`. | Compute `examplesBlock` BEFORE entering `container.perform` (per the current code flow at lines 642-651). Pass to `build(...)` as the `fewShot:` parameter. |
| R7 | **Replay results overwriting human verdicts** — re-running `--replay` after a user filled checkboxes would wipe their input. | Phase 1: accept this (Markdown is in git, restore via `git diff`). Add merge logic in Phase 2 only if churn proves painful. |
| R8 | **Chat template path needs structured slot extraction** — `applyChatTemplate(messages:)` requires distinct `system`/`user` strings, but `BuiltPrompt.text` is concatenated. | Option A from §5: expose `BuiltPrompt.slotTexts[.beforeCursor]` for chat template path. Snapshot tests cover that field too. |
| R9 | **Performance regression from new tokenizer calls** — 5 `encode(text:)` calls per predict (one per slot for counting) instead of 1 today. | Mitigate by computing each slot's count once and caching within the builder for the duration of one `build()` call. The current draft already does this implicitly since `truncateHead` returns the truncated text and the caller measures the result. |
| R10 | **`SouffleuseCoherence` already simulates the prod pipeline** — extending it for replay reuses `Prod.displayGhost` which is duplicated from `PredictorViewModel.onChunk`. If the production behavior changes, the duplicate drifts. | Phase 1: accept the duplication (it already exists, lines 25-118 of `SouffleuseCoherence/main.swift`). Add a TODO comment to extract `displayGhost` into `SouffleuseTyping` or `SouffleusePrompt` in Phase 2. |
| R11 | **Feature flag risk: user-side leaks** — `SOUFFLEUSE_PROMPT_BUILDER=1` is dev-only, but if a curious user sets it, they get a new code path that's been validated only by replay + snapshot tests, not by production daily-use. | This is acceptable per D-12 (dev-only). Don't document the env var in user-facing materials. Mention only in PLAN.md and a `// dev-only flag` comment at the call site. |
| R12 | **Privacy audit drift** — adding `Sources/SouffleusePrompt` to `SHIPPING_DIRS` is the kind of change easy to forget when adding a new target. | Include the `audit.sh` diff as an explicit task in PLAN.md, and add a `./audit.sh` invocation to the PLAN's verification checklist. |

---

## 12. Open Questions for Planner (RESOLVED)

> **All 10 questions resolved during plan-phase iteration 2** (2026-05-24). The planner accepted every suggested default. Each row carries a `**RESOLVED**` marker linking to the plan(s) that implement the decision. No question remains open.

| # | Question | Why it matters | Suggested default | Resolution |
|---|----------|----------------|-------------------|------------|
| Q1 | **Exact per-slot budget numbers** — §4 suggests `system=80, ci=40, ctx=150, fewShot=80, beforeCursor=200, global=512`. Should the planner adjust based on a quick SouffleuseBench reading? | Affects TTFT and the quality ceiling of what fits. | Use §4 numbers; add a SouffleuseBench task in PLAN.md to validate. | **RESOLVED**: §4 numbers locked as `PromptBudget.phase1Default` in `01-01-PLAN.md` Task 1. Mid-phase SouffleuseBench validation is `01-05-PLAN.md` Task 1. |
| Q2 | **AUDIT-02 verdict threshold** — at what `N/12` ✓ count do we proceed to Phase 2? | Controls the milestone-pivot decision. | **6/12 ✓ verdicts** (= 50% improvement) for "proceed", less than that = revisit. Rationale: a flat tie suggests the hypothesis is at best uncertain; >50% strict majority is meaningful given small N. | **RESOLVED**: 6/12 threshold hardcoded in `01-04-PLAN.md` Task 2 `renderReplayResults` and gated in `01-05-PLAN.md` Task 3 verify. |
| Q3 | **Env var vs UserDefaults pref for the feature flag** — D-12 proposes env var, marked as deferred discretion. | Affects ergonomics of switching the flag mid-session. | Env var (no restart needed since `ProcessInfo` reads live; pref would require observation plumbing). | **RESOLVED**: Env var `SOUFFLEUSE_PROMPT_BUILDER` per `01-03-PLAN.md` Task 2 (file-scope `private enum PromptBuilderFlag` mirroring `PredictDebug` pattern). |
| Q4 | **Should `MLXTokenCounter` live in `SouffleusePrompt` or `Souffleuse` app target?** — Both work; affects target purity. | `SouffleusePrompt` already depends on `MLXLMCommon` per D-10, so co-locating is fine. App-side keeps the library testable without MLX. | Place it in `SouffleusePrompt` (D-10 already accepts the MLX dep). Simpler call sites. | **RESOLVED**: Planner placed `MLXTokenCounter` in the `Souffleuse` app target per `01-03-PLAN.md` Task 1 (`Sources/Souffleuse/MLXTokenCounter.swift`). Rationale: keeps SouffleusePrompt library purely value-types/protocols, easier to test without MLX. Duplication with `CoherenceTokenCounter` flagged `TODO Phase 2: dedupe` per W7. |
| Q5 | **Should `BuiltPrompt` expose `slotTexts: [PromptSlot: String]` (post-truncation) for chat template path?** | Instruct models need separated `system`/`user` strings. Choice between richer struct vs second build method. | Yes — add the field. Snapshot tests get richer assertions for free. | **RESOLVED**: `slotTexts: [PromptSlot: String]` included in `BuiltPrompt` per `01-01-PLAN.md` Task 1. Asserted by snapshot tests in `01-02-PLAN.md`. |
| Q6 | **How many scenarios — 10, 12, 15, or 20?** | Affects replay runtime + statistical signal. | 12 (seeded in §7). Below 10 = D-07 floor violated; above 15 = eyeball fatigue. | **RESOLVED**: 12 scenarios authored in `01-04-PLAN.md` Task 1 from §7 seed. |
| Q7 | **Scenario file location** — D-07 fixes `.planning/phases/01-foundation-hypothesis-validation/replay-scenarios.json`. Confirm this path stays even after Phase 1 closes (so historical replays remain reproducible). | Affects long-term traceability. | Keep at that path; do not move to a "milestone-wide" path because scenarios are Phase-1-specific. | **RESOLVED**: Path preserved per D-07. `01-04-PLAN.md` writes to that exact path. |
| Q8 | **Should `--replay` print to stdout AND write the markdown, or only write?** | Affects ergonomics: stdout shows results immediately; markdown is the artifact. | Both. Stdout = condensed table (scenario id, ghost-A, ghost-B); markdown = full content. | **RESOLVED**: Both — `01-04-PLAN.md` Task 2 emits condensed stdout summary + writes full markdown atomically. |
| Q9 | **Should the legacy code path be removed at end of Phase 1, or kept as a fallback for Phase 2/3?** | D-12 says "removed at end of Phase 1." Confirm. | Remove per D-12. Reduces maintenance burden; revert via git if needed. | **RESOLVED**: Removal conditional on positive verdict ≥ 6/12, per `01-05-PLAN.md` Task 3. If verdict negative, legacy path is preserved and milestone is revisited (no auto-removal). |
| Q10 | **Does the builder need to handle the language-steering header dynamically, or is it pre-baked into `systemMessage` by the caller?** | The current `buildSystemPrompt(detectedLanguage:)` at line 190 is `@MainActor`-bound (because `NLLanguageRecognizer` is `@MainActor`-safe). Pushing it into the builder would reshape the API. | Keep language detection at the call site (current location). Pass the fully-formed `systemMessage` into `build(system:)`. Cleanest separation. | **RESOLVED**: Language detection stays at call site. `01-03-PLAN.md` Task 2 passes `baseSystem = buildSystemPrompt(detectedLanguage:)` into the builder's `system:` slot. |

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `MLXLMCommon` `Tokenizer.encode(text:)` cost ≤ 0.5 ms on M1 for typical 512-char input | §2 | Builder's per-slot count calls add measurable TTFT (5 × 0.5 = 2.5 ms acceptable; 5 × 5 = 25 ms is a flag). Mitigation: measure with SouffleuseBench task in PLAN. |
| A2 | TTFT delta of ~30-50 ms when prompt token count doubles from ~200 to ~400 | §4 | Budget numbers may be too aggressive — could blow past 80 ms baseline. Mitigation: measure mid-phase, adjust per-slot budgets down if needed. |
| A3 | Binary-search over candidate cut points in `truncateHead` is fast enough (~5-10 iterations, each one `countTokens(text)` call) | §3 | If `encode` is expensive AND text is large, truncation could dominate predict time. Mitigation: cache last-truncated tail keyed on prefix-length hash. |
| A4 | The 12-scenario seed in §7 is representative enough for the founding-hypothesis verdict | §7 | If scenarios are skewed (e.g., all FR, all-text-only), verdict may not generalize. Mitigation: planner can expand to 15-20 if Phase 1's mid-point review shows blindspots. |
| A5 | `swift-transformers` 1.0.0 `Tokenizer` reference is `Sendable` when captured outside the actor-isolated `perform` closure | §2, R2, R4 | Could trigger Swift 6 strict-concurrency errors at build time. Mitigation: discovered immediately at compile, falls back to constructing counter inside each `perform` block (no hoisting). |
| A6 | Cotypist binary analysis cited in NEXT-MILESTONE-NOTES.md (`tokenBudget`, `maxPromptTokens`, `contentBudget`) accurately describes a per-category budget pattern | Summary, §1 | Pattern is broadly used (it's not Cotypist-specific); even if the analysis is partly wrong, the design pattern stands. Low risk. |

---

## Sources

### Primary (HIGH confidence) — direct codebase reads

- `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` (870 lines, lines 478-513 + 632-664 are the refactor target)
- `Souffleuse/Sources/SouffleuseContext/ContextEnricher.swift` (`EnrichedContext`, `prefix` property)
- `Souffleuse/Sources/SouffleuseCoherence/main.swift` (existing MLX harness shape)
- `Souffleuse/Package.swift` (SPM target structure)
- `Souffleuse/audit.sh` (6 privacy checks)
- `Souffleuse/Sources/SouffleusePersonalization/SimilarHistoryRetrieval.swift` (`buildExamplesBlock`)
- `Souffleuse/Sources/SouffleuseLog/Log.swift` (event-only logging API)
- `.planning/codebase/CONVENTIONS.md` (naming, Sendable rules)
- `.planning/codebase/TESTING.md` (Swift Testing patterns, `@Test` + `#expect`)
- `.planning/codebase/ARCHITECTURE.md` (threading, privacy invariants)
- `.planning/codebase/STACK.md` (`mlx-swift-examples` 2.29.1, `swift-transformers` 1.0.0)
- `.planning/codebase/CONCERNS.md` (existing fragility around `PredictorViewModel`)
- `.planning/PROJECT.md` (core value, constraints, milestone framing)
- `.planning/REQUIREMENTS.md` (BUILDER-* / SLOT-01 / AUDIT-* / TEST-* definitions)
- `.planning/ROADMAP.md` (Phase 1 goal + success criteria)
- `.planning/phases/01-foundation-hypothesis-validation/01-CONTEXT.md` (D-01 through D-13)
- `NEXT-MILESTONE-NOTES.md` (Cotypist binary analysis, founding hypothesis)

### Secondary (MEDIUM confidence)

- Tokenizer cost estimates (A1) — based on `swift-transformers` 1.0.0 being Rust-backed sentencepiece; not directly measured in this codebase.
- TTFT delta from prompt doubling (A2) — extrapolated from CONCERNS.md commentary on KV reuse; not benchmarked for Phase 1's exact budget.

### Tertiary (LOW confidence)

- None. Phase 1 is entirely codebase-internal; no external lookups needed.

---

## Metadata

**Confidence breakdown:**
- PromptBuilder API: HIGH — convention-driven, exact precedents in code.
- Tokenizer access: HIGH — direct read of `PredictorViewModel.swift:693-702` confirms `context.tokenizer.encode(text:)` is the only API in use.
- Eviction algorithm: HIGH (logic) / MEDIUM (perf claim A3).
- Budget numbers: MEDIUM — proportions defensible, exact tokens are best-guess pending SouffleuseBench.
- Integration plan: HIGH — line-numbered against current `predict()`.
- Replay harness: HIGH — extends an existing pattern.
- Scenario schema: HIGH — fields directly mirror CONTEXT.md D-07 specification.
- Test strategy: HIGH — matches existing project conventions verbatim.
- SPM wiring: HIGH — exact diff against `Package.swift`.
- Audit verification: HIGH — direct line reference into `audit.sh`.

**Research date:** 2026-05-24
**Valid until:** 2026-06-23 (30 days; stable codebase, no fast-moving external deps to track for Phase 1 scope)

---

*Phase 1 Research: 2026-05-24*
