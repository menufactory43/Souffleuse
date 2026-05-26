---
phase: 03-perf-kv-cache
plan: 02
subsystem: predictor
tags: [kv-cache, mlx, rotating, token-iterator, predictor, swift, delta-input]
requires: [03-01]
provides:
  - sessionCacheHolder (KVCacheHolder owned on PredictorViewModel)
  - KV cache decision tree (cold / extend / trim / diverged / fingerprintChanged / identical)
  - Delta-input path to TokenIterator on extend (promptTokens.suffix(newCount).dropFirst(oldCount))
  - swapModel KV invalidation hook
  - Production count-only log events kv_cache_extend / kv_cache_trim / kv_cache_invalidate / llm_done_stored
  - SOUFFLEUSE_DISABLE_KV_CACHE env-var bypass (inline; Plan 03-03 will type it)
affects:
  - PredictorViewModel.swift (single file change end-to-end)
tech-stack:
  added: []
  patterns:
    - "CacheBox @unchecked Sendable wrapper for [KVCache] across MainActor.run boundary"
    - "Slot-bodies hoist out of PromptBuilderFlag branch up to @MainActor scope"
    - "InvariancePrefix.canonicalizePreviousUserInputs before fingerprinting (Warning #2)"
    - "MLXLMCommon TokenIterator(input:model:cache:processor:sampler:maxTokens:) on BOTH paths"
key-files:
  created: []
  modified:
    - Souffleuse/Sources/Souffleuse/PredictorViewModel.swift
key-decisions:
  - "Used @unchecked Sendable CacheBox to transfer [KVCache] (non-Sendable protocol) across MainActor.run; safe by construction (sequential per-predict access)."
  - "Hoisted the 5 invariant slot bodies (baseSystem / customInstr / ctxPrefix / fieldContextSlot / afterCursorSlot) out of the `if PromptBuilderFlag.enabled` branch so the fingerprint is computed identically on BOTH paths (PromptBuilder + legacy)."
  - "Stock generate path migrated from MLXLMCommon.generate(input:parameters:context:) to manual TokenIterator(cache: chosenCache, processor: nil, ...) so the holder participates on EVERY predict — not only personalization-on predicts."
  - "Empty-input guard: TokenIterator needs ≥1 token. On trim/identical paths we feed the LAST beforeCursor token so the iterator can prepare from a real state."
  - "Decision tree split into a KVDecision enum so log emission is a single switch, keeping the if/else ladder readable."
requirements-completed: [KV-02, KV-03, KV-07, TEST-01, TEST-03]
duration: 18 min
completed: 2026-05-25
---

# Phase 03 Plan 02: Wire KVCacheHolder into predict() Summary

Wires the 03-01 scaffold into `PredictorViewModel.predict()` so the `[KVCache]` is persisted across keystrokes. Both call sites (personalization + stock) now route through `KVCacheHolder` via a manual `TokenIterator(cache:)`. The extend path feeds ONLY delta tokens (`promptTokens.suffix(newCount).dropFirst(oldCount)`) — the actual KV-02/KV-03 TTFT-win path per `kv-cache-discovery.md` §"Étape 2".

**Duration:** ~18 min · **Tasks:** 2 · **Files:** 1 modified · **Tests:** 126/126 green · **Audit:** 6/6 ✓.

## Diff Range (PredictorViewModel.swift)

| Region | Before | After | Notes |
|---|---|---|---|
| Top of file (private types) | (none) | `private struct CacheBox: @unchecked Sendable` | New helper for cross-actor `[KVCache]` transfer |
| Field declarations | L109 `lastContextFingerprint` | + L110-119 `sessionCacheHolder` | New @MainActor field |
| `swapModel(to:)` | L138-151 | + 2 lines `sessionCacheHolder.invalidate(.explicit)` + `Log.info kv_cache_invalidate count:3` | T-03-02-06 mitigation |
| Pre-Task scope | L739-747 (capture block) | Same capture block PLUS hoisted slot bodies (`baseSystem`, `customInstr`, `ctxPrefix`, `fieldContextSlot`, `afterCursorSlot`) | Slots now visible on both paths |
| Inside `PromptBuilderFlag.enabled` branch | duplicated slot computations | removed (now reuse hoisted locals) | Single source of truth for slot bodies |
| Inside `container.perform` after `promptTokens = ...` | L942-1004 (LMInput + params + stock/perso if/else) | L967-1211 (new KV decision tree + delta input + dual-path TokenIterator + post-stream install) | Hot-path replacement |
| Same closure, after stream completes | (no holder commit) | `if !envBypass { await MainActor.run { sessionCacheHolder.install(...) or updateBeforeCursorTokens(...) } }` | Closes the loop |
| MainActor commit-suggestion path | L1043-1046 | + 2 lines emitting production `Log.info(.predictor, "llm_done_stored", count:)` | Task 1 |

## Both Call Sites Share Manual TokenIterator

Before:

```swift
if let snapshot, !snapshot.isEmpty, personalizationStrength > 0 {
    let iterator = try TokenIterator(input: input, model: context.model,
                                     processor: chain, sampler: ..., maxTokens: ...)
    stream = MLXLMCommon.generate(input: input, context: context, iterator: iterator)
} else {
    stream = try MLXLMCommon.generate(input: input, parameters: params, context: context)
    //                                                       ^^^^^^^^^^ stock path built its own cache internally
}
```

After:

```swift
if let snapshot, !snapshot.isEmpty, personalizationStrength > 0 {
    let iterator = try TokenIterator(input: input, model: context.model,
                                     cache: chosenCache, processor: chain,
                                     sampler: params.sampler(), maxTokens: maxTokens)
    stream = MLXLMCommon.generate(input: input, context: context, iterator: iterator)
} else {
    let iterator = try TokenIterator(input: input, model: context.model,
                                     cache: chosenCache, processor: nil,
                                     sampler: params.sampler(), maxTokens: maxTokens)
    stream = MLXLMCommon.generate(input: input, context: context, iterator: iterator)
}
```

Grep confirms: 0 occurrences of `MLXLMCommon.generate(input: input, parameters: params, context: context)` outside of comments. 2 occurrences of `cache: chosenCache`. 2 manual `TokenIterator(` constructions.

## Six Log Event Sites + Reason Ordinals

| Site | Path | Event | Count | Reason |
|---|---|---|---|---|
| L172 | swapModel | `kv_cache_invalidate` | 3 | `.explicit` |
| L1124 | cold | `kv_cache_invalidate` | 0 | `.cold` |
| L1126 | fingerprint changed | `kv_cache_invalidate` | 1 | `.fingerprintChanged` |
| L1128 | extend | `kv_cache_extend` | delta tokens | — |
| L1130 | trim | `kv_cache_trim` | diff tokens | — |
| L1132 | trim disallowed → rebuild | `kv_cache_invalidate` | 2 | `.beforeCursorDiverged` |

Plus production `llm_done_stored` count-only emitted at the existing PredictDebug call site (Task 1) — enables Plan 03-05's stream-completion ratio without `SOUFFLEUSE_PREDICT_LOG=1`.

`.bypass` and `.identical` decisions are intentionally SILENT (D-KV-06 + no state change), matching the discovery-note §"Sub-cases à gérer" item 1 and the env-var bypass semantics.

## Delta-Input Path — The Win

```swift
} else {
    let existing = holderSnap.caches!.caches
    let oldCount = holderSnap.beforeCursorTokens
    let newCount = userTailTokenCount
    chosenCache = existing
    if newCount > oldCount {
        // Extend: feed ONLY the delta tokens (suffix of the
        // beforeCursor token range, after the previously
        // prefilled portion). This is the KV-02/KV-03 win.
        let beforeCursorTokens = Array(promptTokens.suffix(newCount))
        let deltaTokens = Array(beforeCursorTokens.dropFirst(oldCount))
        iteratorInputTokens = deltaTokens
        decision = .extend(newCount - oldCount)
    }
```

Grep evidence:
- `grep -c "promptTokens.suffix" Sources/Souffleuse/PredictorViewModel.swift` → 2 (both branches that touch the beforeCursor token range).
- `grep -c "dropFirst(oldCount)" Sources/Souffleuse/PredictorViewModel.swift` → 1 (the delta path).

Plan 03-05's TTFT bench will measure the actual ms savings; this plan provides the mechanism.

## Production `llm_done_stored` Emission (Task 1)

```swift
guard self.generation == myGeneration else { return }
let producedTokens = self.suggestion.isEmpty ? 0 : max(1, self.suggestion.count / 4)
Log.info(.predictor, "llm_done_stored", count: producedTokens)
PredictDebug.log("llm_done_stored", "userTail=\(userTail.debugDescription) final=\(self.suggestion.debugDescription) ttft=\(metrics.ttftMillis ?? -1)ms")
self.storeInCache(prefix: userTail, suggestion: self.suggestion)
```

Production log emits a count-only StaticString event; the dev `/tmp` trace stays untouched (debugger view). The char/4 proxy is documented as coarse — Plan 03-05 needs the RATIO `llm_done_stored / predict_called`, not the absolute count.

## Acceptance Criteria — All Met

| Gate | Result |
|---|---|
| `swift build` exits 0 | ✓ (6.13s clean) |
| `swift test` ≥ 121 tests passing, 0 failed | ✓ 126/126 in 0.333s |
| `bash audit.sh` exits 0 (6/6 green) | ✓ |
| `grep -c "cache: chosenCache"` ≥ 2 | ✓ 2 |
| `grep -c "TokenIterator("` ≥ 2 | ✓ 2 |
| `grep -q "var chosenCache"` | ✓ |
| `grep -q "promptTokens.suffix"` | ✓ |
| `grep -q "dropFirst(oldCount)"` | ✓ (BLOCKER#3 delta-input fix) |
| `grep -q "sessionCacheHolder.invalidate(reason: .explicit)"` | ✓ |
| `grep -q "SOUFFLEUSE_DISABLE_KV_CACHE"` | ✓ |
| Old stock-path call gone (`MLXLMCommon.generate(input: input, parameters: params, context: context)`) | ✓ 0 outside comments |
| `grep -cE '"kv_cache_(extend\|trim\|invalidate)"'` ≥ 5 | ✓ 6 (5 decision sites + 1 swapModel) |
| `grep -q "InvariancePrefix.canonicalizePreviousUserInputs"` | ✓ Warning #2 wired |

## Deviations from Plan

### [Rule 3 - Blocking] CacheBox `@unchecked Sendable` wrapper for cross-actor `[KVCache]` transfer

- **Found during:** Task 2 implementation.
- **Issue:** The plan's verbatim code accesses `sessionCacheHolder.caches`, `.fingerprint`, `.beforeCursorTokens` directly inline. But the KV decision tree must run inside `container.perform` (it needs `context.model` to call `makePromptCache(model:parameters:)` and `context.tokenizer` for `userTailTokenCount`). The perform closure is `@Sendable` and runs OFF the MainActor — direct access to the `@MainActor` holder there is not allowed under Swift 6 strict concurrency.
- **Fix:** Introduced a private `CacheBox: @unchecked Sendable` struct that wraps `[KVCache]`. Holder reads/writes are bracketed by `await MainActor.run { ... }` calls; CacheBox bridges the non-Sendable `[KVCache]` protocol array across the actor boundary. Safe by construction — only one predict touches the holder at a time (the previous task is awaited at the top of the new Task and predict() bumps `generation` to invalidate stale stream chunks).
- **Files modified:** `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` (added `private struct CacheBox` near top of file, used inside `container.perform` for holder snapshot + commit).
- **Verification:** Build clean, 126/126 tests, audit 6/6.
- **Commit:** `0b35dd9`.

### [Rule 2 - Critical] Hoisted 5 slot bodies out of `PromptBuilderFlag.enabled` branch

- **Found during:** Task 2 reading.
- **Issue:** The plan's `<interfaces>` block lists `baseSystem` / `customInstr` / `ctxPrefix` / `fieldContextSlot` / `afterCursorSlot` as locals at lines 823-866. Those lines are INSIDE the `if PromptBuilderFlag.enabled` branch. The legacy path (the default — `SOUFFLEUSE_PROMPT_BUILDER` is not set) does not compute them, so the new KV decision-tree block (which must run on EVERY predict, not only PromptBuilder predicts) would have them undefined.
- **Fix:** Moved the 5 slot-body computations OUT of the `if PromptBuilderFlag.enabled` branch and UP to the @MainActor scope (right after the `tokenCountCache` / `sessionCacheHolder` captures, before `currentTask = Task { ... }`). The new path branch now references the same hoisted locals; the legacy path uses them too for the InvariancePrefix fingerprint. The PromptBuilder body's `let builder.build(system: baseSystem, ...)` is unchanged — same values, same call.
- **Files modified:** `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift`.
- **Verification:** Build clean, 126/126 tests, audit 6/6. PromptBuilder branch still compiles and constructs identical prompts (same slot values, no behavioral diff on the PromptBuilder path).
- **Commit:** `0b35dd9`.

### [Rule 1 - Bug] Empty-input guard for TokenIterator on trim/identical

- **Found during:** Task 2 design (anticipated from MLX `TokenIterator.prepare` semantics).
- **Issue:** When the decision is `.trim` (cache exactly represents the new shorter prefix) or `.identical` (same beforeCursor token count), the plan's code sets `iteratorInputTokens = []`. But `TokenIterator(input: LMInput(tokens: MLXArray([])), ...)` would attempt to `prepare` from an empty input — MLX would either crash or produce an undefined state.
- **Fix:** Added a 3-line guard: `if iteratorInputTokens.isEmpty, !promptTokens.isEmpty { iteratorInputTokens = [promptTokens.last!] }`. This feeds the LAST beforeCursor token so the iterator has a real state to step from. The KV cache already contains the corresponding entry (or, in trim case, the trimmed-back state matches this last token).
- **Files modified:** `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift`.
- **Verification:** Build clean, 126 tests green. Empirical TTFT impact will be measured in Plan 03-05.
- **Commit:** `0b35dd9`.

### [Rule 2 - Missing] `.identical` decision case (newCount == oldCount but trim path also matched)

- **Found during:** Task 2 implementation — the plan's pseudocode handled `newCount > oldCount`, `newCount < oldCount canTrim`, `newCount < oldCount !canTrim` but not the `newCount == oldCount` boundary explicitly.
- **Fix:** Added explicit `.identical` decision: no prefill, no log emission, holder beforeCursorTokens unchanged. Most likely path when the user types a character and immediately backspaces it (or when a duplicate predict fires).
- **Files modified:** `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift`.
- **Verification:** Build clean, audit green.
- **Commit:** `0b35dd9`.

**Total deviations:** 4 (all auto-applied per Rule 1/2/3). All are correctness extensions to the plan's intent — none change semantics.

## Authentication Gates

None — no network or auth involved.

## Verification Results

| Check | Result |
|---|---|
| `swift build` exits 0 | ✓ |
| `swift test` (full suite) | ✓ 126 tests passing, 0 failed |
| `bash audit.sh` | ✓ 6/6 green |
| sessionCacheHolder + InvariancePrefix used in PredictorViewModel | ✓ |
| `cache: chosenCache` on both TokenIterator constructions | ✓ |
| Stock `MLXLMCommon.generate(input:parameters:context:)` removed | ✓ |
| Delta-input path (`promptTokens.suffix` + `dropFirst(oldCount)`) | ✓ |
| swapModel invalidates holder + emits log | ✓ |
| `SOUFFLEUSE_DISABLE_KV_CACHE` env-var bypass | ✓ |
| Few-shot block canonicalised before fingerprint | ✓ |
| Six KV log call sites | ✓ |
| Production `llm_done_stored` count-only log | ✓ |

## Commits

- `36e1462` — `feat(03-02): emit production llm_done_stored count-only log event`
- `0b35dd9` — `feat(03-02): wire KVCacheHolder into predict() with delta-input extend`

## Next Step

Ready for **Plan 03-03** — refactor the inline `SOUFFLEUSE_DISABLE_KV_CACHE` read into a typed flag (and likely surface a Preferences toggle for development-mode bypass without env var). Plan 03-04 will add equivalence-verification tests (cache-on vs cache-off produces identical ghost text via deterministic greedy decoding). Plan 03-05 will benchmark TTFT via the existing `SouffleuseCoherence` harness with `--replay` to confirm the p50 ≤ 300 ms target.

## Self-Check: PASSED

- `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` modified (verified via `grep "sessionCacheHolder"` = 8 hits)
- Both commits `36e1462` and `0b35dd9` present in `git log` (verified)
- All acceptance grep gates satisfied (verified)
- Build, test, audit all green (verified)
