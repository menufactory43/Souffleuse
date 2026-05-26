---
phase: 04-cascade-quality-architecture
plan: 06
subsystem: predictor-runtime
tags:
  - phase-04
  - split-pvm
  - model-runtime
  - feature-flagged
  - high-risk
requires:
  - 04-05
provides:
  - ModelRuntime.generate(request:cache:onChunk:) async -> StreamMetrics?
  - PredictRequest extended with 13 additional precomputed Sendable fields
  - PVM.predict dispatcher + predict_legacy + predict_new (env-flag gated)
  - SOUFFLEUSE_USE_MODEL_RUNTIME env var (default OFF)
affects:
  - Souffleuse/Sources/Souffleuse/ModelRuntime.swift (+448 LOC, now 826)
  - Souffleuse/Sources/Souffleuse/PredictorViewModel.swift (+331 LOC, now 1774)
tech-stack:
  added: []
  patterns:
    - "Feature-flagged dual-path migration (env var + lazy runtime load)"
    - "Pure-value Sendable PredictRequest (no actor refs cross the closure boundary)"
    - "Empty-chunk signal for anti-repeat drop across the @Sendable @MainActor onChunk boundary"
key-files:
  modified:
    - Souffleuse/Sources/Souffleuse/ModelRuntime.swift
    - Souffleuse/Sources/Souffleuse/PredictorViewModel.swift
decisions:
  - "PredictRequest carries precomputed inputs (examplesBlock, ngramSnapshot, systemMessage, basePromptText, …) so ModelRuntime.generate never touches actor-isolated state. Caller (PVM.predict_new) awaits TypingHistoryStore.similarEntries and ngramModel.snapshot() inside its Task before assembling the request — option (a) from the plan, pure-value Sendable boundary."
  - "Anti-repeat drop sémantique cross-actor : the off-actor filter pipeline emits an EMPTY chunk on `ghostIsRepeatingPrefix == true`. The @MainActor onChunk closure interprets empty == fallback to instantGhost. Verbatim sémantique de PVM:755-766, just transported across the closure boundary via the empty-string convention."
  - "Runtime container loads alongside PVM.container when flag is ON (two MLX containers in memory transitorily, ~80 MB each). Trade-off explicit in the plan ; dev-only, dropped in 04-07 cleanup. Flag flip requires app restart in practice because loadModel() reads the flag once at boot."
  - "PromptBuilderFlag (`SOUFFLEUSE_PROMPT_BUILDER`) duplicated inline in ModelRuntime.generate because the PVM type is `private enum` at file scope. Dédup en 04-07 alongside the broader OutputFilter dédup (move to shared location)."
  - "Generation token (`request.token`) is carried in PredictRequest for symmetry / future use ; the planner.isCurrent(token) check happens in the caller's onChunk closure on @MainActor side. The runtime body itself relies only on Task.isCancelled."
metrics:
  duration: ~25 minutes
  completed: 2026-05-26
---

# Phase 4 Plan 06: ModelRuntime extraction step 2 (high-risk container.perform port behind env flag) Summary

ModelRuntime.generate(request:cache:onChunk:) ported verbatim from PVM container.perform body (PVM:894-1305). PVM now dispatches between `predict_legacy` (intact) and `predict_new` (wires to runtime.generate) via `SOUFFLEUSE_USE_MODEL_RUNTIME` env var. Default OFF — empirical validation lives in 04-07.

## Dual-path architecture

```
                         PVM.predict(prefix, ctx, custom, ax)
                                    │
                       useModelRuntime ? ─────────────┐
                                    │ no              │ yes
                                    ▼                 ▼
                          predict_legacy        predict_new
                          (body intact)         (cascade + PredictRequest +
                                  │              runtime.generate)
                                  ▼                 │
                       container.perform { ... }    ▼
                       (in-line 410 LOC)     runtime.generate(req, cache, onChunk)
                                                    │
                                                    ▼
                                          container.perform { ... }
                                          (verbatim port of legacy body)
```

Both paths share : observables (suggestion, suggestionSource, ttftMillis, tokensPerSecond), cache (CompletionCache), planner (GenerationPlanner), policy (SuggestionPolicyEngine). Only the LLM generation closure differs.

## SOUFFLEUSE_USE_MODEL_RUNTIME

| Value | Behaviour |
|-------|-----------|
| unset / `""` / anything ≠ `"1"` | **Default** — legacy path. PVM.container is loaded ; runtime is NOT loaded (lazy, never accessed). Zero overhead. |
| `"1"` | New path. Both PVM.container AND runtime.container are loaded at boot (~2× MLX memory transitorily). predict_new routes through runtime.generate. |

Read once per predict (cheap ProcessInfo lookup) ; read once per loadModel/swap. Flipping at runtime is technically possible but `loadModel` won't load the runtime container if flag was off at boot — so a runtime restart is required to flip in practice.

## LOC

| File | Pre | Post | Δ |
|------|-----|------|---|
| `Souffleuse/Sources/Souffleuse/ModelRuntime.swift` | 378 | **826** | +448 |
| `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` | 1443 | **1774** | +331 |

Total +779 LOC transitoire. 04-07 cleanup will drop predict_legacy + its container.perform body + the duplicate PromptBuilderFlag inline, plus the redundant container in PVM — net result should be **−400 to −500 LOC** vs current state.

## Tests

| Suite | Pre | Post | Δ |
|-------|-----|------|---|
| Total (default / legacy path) | 238 | **238** | 0 |
| Total (SOUFFLEUSE_USE_MODEL_RUNTIME=1) | n/a | **238** | smoke |

```
swift test                                    → 238/238 ✔
SOUFFLEUSE_USE_MODEL_RUNTIME=1 swift test     → 238/238 ✔
bash Souffleuse/audit.sh                      → 6/6 OK
swift build                                   → exit 0
```

No new test file created (skipped per Task 3 option). PVM has no public seam to inject runtime without touching `private lazy var`, and predict_new end-to-end testing requires MLX — out of BUILD-ONLY scope. The flag-on smoke pass guarantees the path compiles AND initialises cleanly through the test harness's PVM-touching code paths.

## ModelRuntime.generate signature

```swift
func generate(
    request: PredictRequest,
    cache: CompletionCache,
    onChunk: @escaping @Sendable @MainActor (String) -> Void
) async -> StreamMetrics?
```

- Returns `nil` on container missing / MLX failure (logged via `predict_failed`).
- `onChunk(chunk)` called for each filtered, capped, anti-repeat-checked stream chunk.
- Empty `chunk` is the **anti-repeat drop signal** : caller should fall back to instant ghost (matches PVM:755-766 semantic).
- `Task.isCancelled` checks preserved verbatim inside the stream loop.

## PredictRequest extension (04-06)

Added 13 fields on top of the 13 from 04-05 :

| Field | Purpose |
|-------|---------|
| `userTail` | suffix-2048 trim of `prefix` |
| `llmTail` | suffix-512 trim of `userTail` |
| `isInstructModel` | branches chat-template vs raw-text |
| `systemMessage` | legacy full system message |
| `baseSystem` / `customInstr` / `ctxPrefix` | slot bodies for PromptBuilder |
| `fieldContextSlot` / `afterCursorSlot` | AX-derived FR prose |
| `basePreamble` / `basePromptText` | preassembled prompts |
| `examplesBlock` | few-shot block (precomputed off-actor) |
| `ngramSnapshot` | NgramSnapshot? (precomputed off-actor) |

This keeps ModelRuntime.generate **pure off-actor** : no `await ngramModel.snapshot()` or `await history.similarEntries(...)` inside the container.perform closure. The Sendable boundary is crossed once, by value.

## Commits

| Hash | Type | Description |
|------|------|-------------|
| `d906d2d` | feat | add ModelRuntime.generate — verbatim port of container.perform |
| `d5a379b` | refactor | PVM dual-path predict — legacy intact + new wires to runtime |

## Deviations from Plan

**1. [Rule 1 — Bug] `@Observable` + `lazy var` incompatibility for `runtime`**

- **Found during:** Task 2 build
- **Issue:** First attempt declared `private lazy var runtime: ModelRuntime = ...` — `@Observable` macro tries to wrap `_runtime` as an init accessor and explodes on lazy storage.
- **Fix:** Added `@ObservationIgnored` on the property — runtime is not part of the observable surface (it's an implementation detail under the dispatcher), so omitting it is correct semantically as well as syntactically. Doc-comment updated.
- **Files modified:** `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift`
- **Commit:** `d5a379b`

**2. [Rule 3 — Blocking] PromptBuilderFlag duplicated inline in ModelRuntime.generate**

- **Found during:** Task 1 implementation
- **Issue:** `PromptBuilderFlag.enabled` lives in a `private enum` at PVM file scope → invisible to ModelRuntime. The container.perform body references it.
- **Fix:** Inlined the same `ProcessInfo.processInfo.environment["SOUFFLEUSE_PROMPT_BUILDER"]?.isEmpty == false` check directly in ModelRuntime.generate. Documented as a single-call-site duplicate to be removed in 04-07 alongside the broader cleanup (probable destination : a small `Flags` enum in `SouffleusePrompt` since it gates PromptBuilder).
- **Files modified:** `Souffleuse/Sources/Souffleuse/ModelRuntime.swift`
- **Commit:** `d906d2d`

**3. [Rule 2 — Critical functionality] Empty-chunk anti-repeat signal across closure boundary**

- **Found during:** Task 1 design — the original PVM anti-repeat path (PVM:755-766) updates `self.suggestion = instantGhost` directly from the @MainActor side of the Task. With ModelRuntime now decoupled and only emitting via `onChunk`, the natural translation is to emit an empty string to signal "drop this LLM, fall back".
- **Fix:** ModelRuntime emits `onChunk("")` on anti-repeat ; caller's onChunk closure restores `instantGhost / instantSource` on empty input. Sémantique préservée. Documented in both Source files.
- **Files modified:** `Souffleuse/Sources/Souffleuse/ModelRuntime.swift`, `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift`
- **Commits:** `d906d2d` + `d5a379b`

Aucune déviation Rule 4 (architectural).

## Empirical validation protocol (04-07)

The user must perform the following validation before flipping the flag default ON (and removing the legacy path in 04-07) :

### Baseline (flag OFF, current default)

1. Build dev-signed `Souffleuse.app` via `make-app.sh`.
2. Launch normally (no env vars).
3. Tier-1 apps : open Mail (compose), Notes (new note), Brave (Google search box).
4. Type a phrase that triggers a ghost in each. Record subjectively : speed, relevance, language match.

### Runtime path (flag ON)

5. Quit the app fully.
6. Launch with `SOUFFLEUSE_USE_MODEL_RUNTIME=1 open Souffleuse.app` (or set the env var system-wide via launchctl for the session).
7. Repeat the same Mail / Notes / Brave scenarios.
8. Confirm ghost behaviour is subjectively equivalent. Watch ~/Library/Logs/Souffleuse.log for `kv_cache_*` events — distribution should mirror baseline.

### Verdict

- **OK** → 04-07 removes predict_legacy + the legacy container.perform block + the runtime/legacy fork in loadModel/swapModel. Flag retired.
- **KO** → bisect runtime.generate body to find divergence. Likely suspects : KV-cache decision count mapping (T-04-06-01), n-gram bias timing, filter pipeline ordering. Re-test after each bisect.

### Rollback procedure (if regression detected after release)

The runtime path is OFF by default — no rollback needed for end users. For dev-build users who exported the env var, simply unset `SOUFFLEUSE_USE_MODEL_RUNTIME` and relaunch. Zero code changes, zero git revert.

## Residual risk

- **n-gram bias timing** : in legacy, the await on ngramModel.snapshot() happens INSIDE container.perform (same actor as the LLM call). In new, it happens in the outer Task BEFORE entering runtime.generate. Net : a few ms of ordering difference. Could alter cancel-on-keystroke behaviour for very fast typists. Empirical validation only can confirm.
- **Two-container memory** : when flag ON, both PVM.container AND runtime.container hold a copy of the model. Apple Silicon unified memory means ~2× footprint transitorily. Acceptable for dev validation, must be dropped in 04-07 cleanup.
- **Filter pipeline locale** : in new, the pipeline runs off-actor (inside ModelRuntime.generate). In legacy, it runs in the inline onChunk closure (mixed actor). Same regexes, same code — but execution context differs. No expected behavioural delta ; empirical confirmation needed.

## Threat surface

Aucune nouvelle surface introduced. ModelRuntime.generate uses only the same MLX / MLXLMCommon / SouffleusePrompt / SouffleusePersonalization APIs already exercised by PVM. No new Log events besides the verdict-mapped kv_cache_* (byte-identical to legacy). audit.sh 6/6 OK.

## Next step

→ **04-07 PLAN.md** : empirical validation gate (user-driven AB test) + retrait du flag + cleanup PVM façade (drop predict_legacy + the redundant container in PVM + the duplicate PromptBuilderFlag + the OutputFilter copies). Net LOC delta projected : −400 to −500.

## Self-Check: PASSED

- `Souffleuse/Sources/Souffleuse/ModelRuntime.swift` : FOUND (826 LOC, was 378 — +448)
- `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` : FOUND (1774 LOC, was 1443 — +331)
- Commit `d906d2d` (feat ModelRuntime.generate) : FOUND
- Commit `d5a379b` (refactor PVM dual-path) : FOUND
- `grep 'func generate' ModelRuntime.swift` : FOUND
- `grep 'container.perform' ModelRuntime.swift` : FOUND
- `grep 'kv_cache_extend' ModelRuntime.swift` : FOUND
- `grep 'kv_cache_trim' ModelRuntime.swift` : FOUND
- `grep 'predict_legacy' PredictorViewModel.swift` : FOUND
- `grep 'predict_new' PredictorViewModel.swift` : FOUND
- `grep 'useModelRuntime' PredictorViewModel.swift` : FOUND
- `grep 'SOUFFLEUSE_USE_MODEL_RUNTIME' PredictorViewModel.swift` : FOUND
- `grep 'runtime.generate' PredictorViewModel.swift` : FOUND
- `grep 'PredictRequest(' PredictorViewModel.swift` : FOUND
- `swift build` : exit 0 verified
- `swift test` (legacy default) : 238/238 verified
- `SOUFFLEUSE_USE_MODEL_RUNTIME=1 swift test` : 238/238 verified
- `bash audit.sh` : 6/6 OK verified
