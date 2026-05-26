---
phase: 04-cascade-quality-architecture
plan: 07
subsystem: predictor-runtime
tags:
  - phase-04
  - split-pvm
  - model-runtime
  - cleanup
  - empirical-gate
  - facade
requires:
  - 04-05
  - 04-06
provides:
  - "PredictorViewModel as the final D-03 facade (cascade wiring + observable surface only)"
  - "ModelRuntime as the single source of truth for MLX container + generate body"
  - "Empirical AB validation log (04-07-EMPIRICAL-VALIDATION.md) — PASS verdict"
  - "Global split D-03 closeout — 4-module structure stabilised"
affects:
  - Souffleuse/Sources/Souffleuse/PredictorViewModel.swift (-1148 LOC, now 626)
  - .planning/phases/04-cascade-quality-architecture/04-07-EMPIRICAL-VALIDATION.md (new)
tech-stack:
  added: []
  patterns:
    - "Facade pattern (PVM = observable surface ; ModelRuntime = engine)"
    - "Empirical AB validation gate before destructive cleanup (Core Value protect)"
    - "Single source of truth for OutputFilter helpers (dedup PVM-side)"
key-files:
  created:
    - .planning/phases/04-cascade-quality-architecture/04-07-EMPIRICAL-VALIDATION.md
    - .planning/phases/04-cascade-quality-architecture/04-07-SUMMARY.md
  modified:
    - Souffleuse/Sources/Souffleuse/PredictorViewModel.swift
decisions:
  - "Cleanup proceeded immediately after PASS verdict — empirical AB session showed runtime path subjectively equivalent to legacy on Mail and Notes (Tier-1 apps). The few-shot/cache surconsommation concern raised during validation is path-independent (reproduces identically on both paths) so it does not block D-03 closure ; it lives upstream in PVM.predict cascade routing and CompletionCache, not in container.perform. Tracked as a separate follow-up jalon."
  - "PVM.container dropped entirely — runtime.container is the only ModelContainer in PVM's reach. rebuildPersonalization and ingestAccepted now route through runtime.container instead of self.container. This removes the dual-container memory cost (~80 MB MLX footprint) that was a known transitional tradeoff in 04-06."
  - "loadModel and swapModel are pure delegators. loadModel publishes LoadState by reading runtime.lastError after the await ; swapModel calls cancel(reason: .modelSwap) first (preserves the silent classification grid lifecycle event from D-09) then awaits runtime.swap which internally calls cache.invalidateAll (emitting kv_cache_invalidate count:3) and reloads."
  - "PredictDebug enum (gated by SOUFFLEUSE_PREDICT_LOG) kept in PVM — it is a dev-only side-channel that audit.sh explicitly excludes from privacy rules. Its call sites are the cascade decision points in predict() that aid debugging without touching production logs."
  - "PromptBuilderFlag removed from PVM (single call site lived in the legacy predict body). ModelRuntime.generate still has its own inline duplicate of the same ProcessInfo lookup — promoting it to a shared SouffleusePrompt symbol is out of scope for the D-03 split and would be a separate refactor."
metrics:
  duration: ~25 minutes
  completed: 2026-05-26
---

# Phase 4 Plan 07: Cleanup + final D-03 facade Summary

Empirical AB validation (Task 1) returned PASS — runtime path is subjectively
equivalent to legacy. Task 2 removed the feature flag, deleted predict_legacy,
inlined predict_new as predict(), dropped PVM.container, and dedupliquéd
every helper (CacheBox, StreamMetrics, stripPrefixOverlap, ghostIsRepeating-
Prefix, hasCompletedFirstWord, stripTrailingPartialWord, normalizeFor-
RepeatCheck, capToWords, buildSystemPrompt, detectLanguage,
autocompleteSystemPrompt, PromptBuilderFlag) so that ModelRuntime is the
single source of truth.

## PVM final shape

| Element | State |
|---------|-------|
| `container: ModelContainer?` | **removed** — was the legacy MLX handle |
| `predict_legacy(...)` | **removed** — was 938 LOC of inline container.perform |
| `predict_new(...)` | **renamed** to `predict(...)` |
| `useModelRuntime` flag | **removed** |
| `SOUFFLEUSE_USE_MODEL_RUNTIME` env var | **removed** from PVM (still exists nowhere — gone) |
| `runtime: ModelRuntime` | **kept** — only the @ObservationIgnored lazy hand-off |
| `cache`, `planner`, `policy`, `ngramModel`, `wordCompleter` | **unchanged** — façade keeps them |
| `loadModel()` | pure delegator → `runtime.loadModel()` + LoadState mirror |
| `swapModel(to:)` | pure delegator → `runtime.swap(to:completionCache:)` |
| `rebuildPersonalization` / `ingestAccepted` | use `runtime.container` instead of `self.container` |
| `cancel(reason:)` / `cancel()` | unchanged — façade keeps them |
| OutputFilter helpers | **removed** — call sites use `ModelRuntime.OutputFilter.*` |
| `buildSystemPrompt` / `detectLanguage` / `autocompleteSystemPrompt` | **removed** — call sites use `ModelRuntime.*` |
| `CacheBox` / `StreamMetrics` (nested struct) | **removed** — gone with predict_legacy |
| `PromptBuilderFlag` | **removed** — only used by predict_legacy |

## LOC delta

| File | Pre 04-07 | Post 04-07 | Δ |
|------|-----------|------------|---|
| `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` | 1774 | **626** | **−1148 (−65 %)** |

Under the plan target (≤700) ; not at the stretch target (≤500) because
`rebuildPersonalization` + `ingestAccepted` were intentionally kept in PVM
per Task 2 "Décision pragmatique" guidance — their migration to ModelRuntime
would have added comparable LOC there without behavioural gain.

## Empirical validation outcome

`.planning/phases/04-cascade-quality-architecture/04-07-EMPIRICAL-VALIDATION.md`

```
Session 1 — Flag ON (new ModelRuntime path)
  Ghost fonctionne (no crash, no hang, no missing suggestion).
Session 2 — Flag OFF (legacy path baseline)
  Comportement identique sur surconsommation cache/few-shots.
Verdict: PASS — runtime path subjectively equivalent to legacy.
```

The surconsommation concern raised during validation is documented as
path-independent and routed to a follow-up jalon (logique cascade routing
+ CompletionCache, en amont du container.perform body migré).

## Tests + audit

```
swift build --package-path Souffleuse     → exit 0
swift test --package-path Souffleuse      → 238/238 ✔
bash Souffleuse/audit.sh                  → 6/6 OK
```

PVM acceptance criteria (grep counts) :

| Pattern                                | Count | Required |
|----------------------------------------|-------|----------|
| `SOUFFLEUSE_USE_MODEL_RUNTIME`         | 0     | 0        |
| `predict_legacy` / `predict_new`       | 0     | 0        |
| `static func stripPrefixOverlap`       | 0     | 0        |
| `static func capToWords`               | 0     | 0        |
| `static func buildSystemPrompt`        | 0     | 0        |
| `struct CacheBox`                      | 0     | 0        |
| `struct StreamMetrics`                 | 0     | 0        |
| `runtime.` references                  | 12    | ≥1       |
| PVM LOC                                | 626   | ≤700     |

## Phase 4 D-03 PVM Split — Verdict Global

```
========================================================================
04-02 SuggestionPolicyEngine extraction   : EQUIVALENT
                                            (modulo Gate D-07 + L1 re-enable, both intended)
04-03 GenerationPlanner extraction        : EQUIVALENT
04-04 CompletionCache extraction          : EQUIVALENT
04-05 ModelRuntime skeleton + helpers     : NO BEHAVIORAL CHANGE
                                            (alongside extraction, no callers)
04-06 ModelRuntime.generate (flag-gated)  : EQUIVALENT per empirical validation 04-07
04-07 Cleanup (flag/legacy removed)       : EQUIVALENT (post-validation, no new code path)
────────────────────────────────────────────────────────────────────────
PVM LOC : 1566 → 1774 (peak transitoire 04-06) → 626 (final 04-07)
                  net Δ vs pre-D-03 : −940 LOC, −60 %

4-module structure final :
    PredictorViewModel     626 LOC  (observable facade)
    ModelRuntime           826 LOC  (MLX container + generate body + helpers)
    SuggestionPolicy       443 LOC  (cascade routing + relevance gate)
    CompletionCache        262 LOC  (predict memo + tokenCount cache + KV holder + fp)
    GenerationPlanner      137 LOC  (counter + currentTask + debounce)
                         ──────────
                          2294 LOC total (D-03 perimeter)
========================================================================
```

## Architecture façade

```
        ┌────────────────────────────────────────────────────────────┐
        │ PredictorViewModel  @MainActor @Observable                 │
        │   - suggestion, suggestionSource, loadState, ttftMillis    │
        │   - predict(prefix, contextPrefix, customInstructions, ax) │
        │   - loadModel / swapModel / cancel / rebuildPersonalization│
        │   - ingestAccepted / clearPredictCache                     │
        └──────┬────────────┬─────────────┬────────────┬─────────────┘
               │            │             │            │
       ┌───────▼──────┐  ┌──▼─────────┐ ┌─▼──────────┐ ┌▼────────────┐
       │ ModelRuntime │  │ Suggestion │ │ Completion │ │ Generation  │
       │  container   │  │ PolicyEngine│ │ Cache      │ │ Planner     │
       │  generate()  │  │  routeInst. │ │  lookup    │ │  counter    │
       │  swap()      │  │  applyGhost │ │  store     │ │  debounce   │
       │  loadModel   │  │  onLLMChunk │ │  KV holder │ │  Task track │
       │  OutputFilter│  └─────────────┘ └────────────┘ └─────────────┘
       │  detect/build│
       │  Prompt      │
       └──────────────┘
```

## Deviations from Plan

**1. [Rule 3 — Blocking] `self` used in property access before init completes**

- **Found during:** Task 2 build
- **Issue:** The natural transcription of `init() { self.runtime = ModelRuntime(initialModelId: self.modelId) }` violates Swift init rules — `self.modelId` is referenced before `self.runtime` is initialised (Swift cannot prove the read is safe when other stored properties might still be uninitialised).
- **Fix:** Hoisted the model id literal to a local `let`, then assign both `self.modelId` and `self.runtime` from that local. Dropped the default value on `var modelId` (it is now assigned in init only) so the two values can never drift.
- **Files modified:** `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift`
- **Commit:** `687f999`

**2. [No deviation] Acceptance criterion strictness on documentation comments**

- The plan's grep criteria are stated as "count = 0" for `SOUFFLEUSE_USE_MODEL_RUNTIME`, `predict_legacy`, `predict_new`. My first cleanup left mentions in a historical doc-comment explaining the cleanup itself ("Pre-04-07 the model dispatched between predict_legacy and predict_new via the env-flag SOUFFLEUSE_USE_MODEL_RUNTIME..."). I rewrote the comment to refer to the historical state without naming the removed symbols, so the strict grep stays at 0 — this matches the plan's literal acceptance criterion. The historical context lives in 04-06-SUMMARY.md where it belongs.
- **Files modified:** `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift`
- **Commit:** `687f999`

No Rule 4 (architectural) deviations.

## Pointer to next plans

The D-03 split is closed. Remaining Phase 4 work, per `04-CONTEXT.md` and
the post-05-decomposition plan-set :

- **04-08 PLAN** — HistoryExactMatchTests + L1 cascade verification (was
  originally 04-06 pre-decomposition).
- **04-09 PLAN** — TypingSession extraction (D-04 sibling split — partial
  accept + typedDiverged hooks).
- **04-10 PLAN** — Coherence v2 (n-gram bias + few-shot tuning loop).
- **04-11 PLAN** — 3-app verify (Mail / Notes / Brave) on the post-split
  app — empirical confirmation of Phase 4 closeout.

Suivi orthogonal au split D-03 :

- Diagnose cache/few-shot surconsommation flagged during the empirical AB
  validation (path-independent, lives in PVM.predict cascade + Completion-
  Cache lookup ordering). Probably a separate follow-up jalon after Phase 4.

## Commits

| Hash | Type | Description |
|------|------|-------------|
| `687f999` | refactor | final PVM facade after empirical validation PASS |
| (this file) | docs | 04-07 summary + global D-03 verdict |

## Self-Check: PASSED

- `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` : FOUND (626 LOC)
- `.planning/phases/04-cascade-quality-architecture/04-07-EMPIRICAL-VALIDATION.md` : FOUND (PASS verdict)
- `.planning/phases/04-cascade-quality-architecture/04-07-SUMMARY.md` : FOUND (this file)
- Commit `687f999` (refactor cleanup) : FOUND
- `grep 'SOUFFLEUSE_USE_MODEL_RUNTIME' PVM.swift` : 0 matches verified
- `grep 'predict_legacy\|predict_new' PVM.swift` : 0 matches verified
- `grep 'struct CacheBox\|struct StreamMetrics' PVM.swift` : 0 matches verified
- `grep 'static func stripPrefixOverlap\|static func capToWords\|static func buildSystemPrompt' PVM.swift` : 0 matches verified
- `grep 'runtime.generate\|self.runtime' PVM.swift` : ≥1 verified (12 matches)
- `swift build --package-path Souffleuse` : exit 0 verified
- `swift test --package-path Souffleuse` : 238/238 verified
- `bash Souffleuse/audit.sh` : 6/6 OK verified
