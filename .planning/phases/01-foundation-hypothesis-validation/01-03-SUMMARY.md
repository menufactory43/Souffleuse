---
phase: 01-foundation-hypothesis-validation
plan: 03
subsystem: predictor
tags: [swift, mlx, integration, feature-flag, predictor, prompt-builder]
requires:
  - SouffleusePrompt target (built by 01-01)
  - SouffleusePrompt/TokenCounting protocol
  - SouffleusePrompt/PromptBuilder, PromptBudget, BuiltPrompt
  - MLXLMCommon (any Tokenizer via swift-transformers)
provides:
  - struct MLXTokenCounter: TokenCounting (production adapter)
  - private enum PromptBuilderFlag (env-var gate)
  - dual predict() path (legacy verbatim + new builder)
affects:
  - Souffleuse target predict path
  - Phase 1 replay harness (plan 01-04 will toggle SOUFFLEUSE_PROMPT_BUILDER=1)
tech-stack:
  added:
    - none (uses existing MLXLMCommon + SouffleusePrompt)
  patterns:
    - env-var feature flag mirror of PredictDebug
    - fresh tokenizer-adapter allocation inside container.perform (per R2)
    - per-slot routing for customInstructions + contextPrefix (BUILDER-02)
key-files:
  created:
    - Souffleuse/Sources/Souffleuse/MLXTokenCounter.swift
  modified:
    - Souffleuse/Sources/Souffleuse/PredictorViewModel.swift
decisions:
  - "Migration strategy: feature flag dev-only (D-12). Legacy path stays verbatim; new path gated by SOUFFLEUSE_PROMPT_BUILDER=1. Flag is removed after plan 01-05 replay verdict."
  - "MLXTokenCounter placed in Souffleuse target (not SouffleusePrompt) so SouffleusePrompt stays MLX-free and unit-testable."
  - "stateless struct: Sendable (not actor) — tokenizer calls are sync, no mutable state."
  - "import Tokenizers explicitly: kept (swift-transformers re-exports via MLXLMCommon but explicit import improves readability and matches RESEARCH §2 confidence note)."
metrics:
  duration: ~30 min
  completed: 2026-05-24
  tasks: 2
  files: 2
  commits:
    - a3c3a8c feat(01-03): add MLXTokenCounter adapter conforming TokenCounting
    - dab3c26 feat(01-03): wire PromptBuilder into predict() behind SOUFFLEUSE_PROMPT_BUILDER flag
---

# Phase 01 Plan 03: Integrate PromptBuilder behind feature flag — Summary

One-liner: Production wiring of the Phase 1 PromptBuilder into `PredictorViewModel.predict()` via MLX tokenizer adapter, gated by `SOUFFLEUSE_PROMPT_BUILDER=1` env var with the legacy flat-string path preserved verbatim.

## What Was Built

### Task 1 — MLXTokenCounter adapter (commit a3c3a8c)

- File: `Souffleuse/Sources/Souffleuse/MLXTokenCounter.swift` (89 LOC)
- `struct MLXTokenCounter: TokenCounting` — stateless `Sendable`
- `countTokens(_:)` thin wrapper over `tokenizer.encode(text:).count` with an empty-string short-circuit
- `truncateHead(_:toBudget:)`:
  - Quick path if input already fits
  - Two-pass cut search: sentence-boundary first (`.`, `?`, `!`, `…`), then word boundary
  - D-11 invariant respected: never cuts mid-word; returns `""` only if no cut fits (defensive)
- Imports: `Foundation`, `MLXLMCommon`, `SouffleusePrompt`, `Tokenizers` (the last is explicit per RESEARCH §2 even though MLXLMCommon re-exports it)
- Privacy: no `print`, `NSLog`, `os_log`, or `Log.*` calls — adapter is pure

### Task 2 — Wire builder into predict() (commit dab3c26)

- File: `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` (+111 / -10 LOC)
- New file-scope enum `PromptBuilderFlag` placed just before `PredictDebug` — pattern-mirrors it (single `static let enabled: Bool` from `ProcessInfo.processInfo.environment`)
- New `import SouffleusePrompt` added
- Hoisted `baseSystemPrompt` local (line ~501) so the value is computed on @MainActor and captured by the Sendable Task closure instead of calling `Self.buildSystemPrompt` from inside it
- Converted `var examplesBlock` to `let` via inline `await { … }()` so Swift 6 strict concurrency accepts the capture in the `container.perform` closure
- Inside `container.perform`:
  - Branch 1 (`PromptBuilderFlag.enabled`): builds `MLXTokenCounter(tokenizer: context.tokenizer)`, `PromptBuilder(counter:, budget: .phase1Default)`, calls `builder.build(system:customInstructions:contextPrefix:fewShot:beforeCursor:)` with **per-slot routing** (variables `customInstr`, `ctxPrefix`, `examplesBlock`, `userTail`). Logs `Log.info(.predictor, "prompt_built", count: built.totalTokens)` exactly once.
  - For instruct models: reconstructs `system` content by joining `built.slotTexts[.system]`, `.customInstructions`, `.contextPrefix`, `.fewShot` (preserves per-slot routing through the chat template) and uses `built.slotTexts[.beforeCursor] ?? ""` as the user message.
  - For base/PT models: feeds `built.text` to `context.tokenizer.encode(text:)` raw.
  - Branch 2 (`else if isInstructModel` + `else`): legacy code verbatim (kept lines for `systemMessage`, `llmTail`, `basePromptText`).

## Verification Results

- `swift build` — exit 0 (full pipeline, MLX layers + Souffleuse target)
- `bash audit.sh` — all 6 checks green (the new `Log.info(.predictor, "prompt_built", count:)` is StaticString event + Int count, no user-text interpolation; check 6 verifies)
- `swift test` — exit 0, all 94 tests pass (flag is OFF by default in test runs, so legacy path is exercised)

## Acceptance Grep Gates (BUILDER-02 enforcement)

Positive (1 hit each):
- `private enum PromptBuilderFlag`
- `SOUFFLEUSE_PROMPT_BUILDER`
- `PromptBuilder(counter:`
- `MLXTokenCounter(tokenizer:`
- `customInstructions: customInstr`  ← per-slot routing
- `contextPrefix: ctxPrefix`         ← per-slot routing
- `Log.info(.predictor, "prompt_built"`
- `import SouffleusePrompt`
- `PromptBuilderFlag.enabled`
- `let llmTail = String(userTail.suffix(512))` (legacy preserved)
- `basePromptText = basePreamble` (legacy preserved, 2 occurrences with/without examplesBlock)

Negative (0 hits, confirmed):
- `(customInstructions|contextPrefix):\s*""` — no empty string literals in slot args
- `Log\.(info|warn|error)\(...\\(.*(built|userTail|examplesBlock)` — no user-text interpolated in Log calls

## Deviations from Plan

### Rule 1/3 — Swift 6 strict concurrency adjustments

**1. [Rule 3 - Blocking] Hoisted `baseSystemPrompt` to @MainActor scope**
- Found during: Task 2 first build
- Issue: `Self.buildSystemPrompt(detectedLanguage:)` is implicitly @MainActor-isolated (host class is @MainActor); calling from Sendable `container.perform` closure violates Swift 6 strict concurrency
- Fix: extracted the value to a `let baseSystemPrompt` on line ~501 (inside @MainActor `predict()`) and captured that. Plan suggested calling it inline; we adapted to avoid touching the static's actor isolation.
- Files modified: `PredictorViewModel.swift`
- Commit: dab3c26

**2. [Rule 3 - Blocking] Converted `var examplesBlock` to `let`**
- Found during: Task 2 first build
- Issue: `examplesBlock` was declared `var` and captured in the `container.perform` Sendable closure — Swift 6 #SendableClosureCaptures error
- Fix: rewrote as `let examplesBlock: String = await { ... }()` — semantically identical, satisfies the Sendable capture rule
- Files modified: `PredictorViewModel.swift`
- Commit: dab3c26

Both deviations are within Rule 3 scope (blocking issues directly caused by this task's introduction of a new closure that captures formerly-mutable locals). No architectural change.

## Privacy Invariants

- The only new `Log.*` call is `Log.info(.predictor, "prompt_built", count: built.totalTokens)`. `count` is an Int; the event name is a `StaticString` literal — audit.sh check 6 grep gate verified clean.
- `SOUFFLEUSE_PROMPT_BUILDER` env var is read once at static load (mirror of `PredictDebug.enabled`) and is NEVER logged or written anywhere.
- `MLXTokenCounter` is pure — no logging, no I/O, no global state.
- `built.text`, `built.slotTexts`, `userTail`, `examplesBlock`, `systemMessage` are NEVER passed to any `Log.*` call. Verified by grep.

## Threat Model Mitigations Applied

- T-03-01 (Info Disclosure via `prompt_built` log): mitigated by StaticString event + count-only payload (audit check 6 enforces).
- T-03-02 (Info Disclosure via env var lookup): mitigated by passive non-logging (`PromptBuilderFlag.enabled` is read once, never written).
- T-03-03 (Tampering via removed legacy path): mitigated by preserving `systemMessage`, `basePreamble`, `basePromptText`, `llmTail` verbatim — 94 existing tests still cover this path because flag defaults OFF.

## Phase 1 Continuity

- Plan 01-04 (replay harness) can now toggle `SOUFFLEUSE_PROMPT_BUILDER=1` to exercise the new path.
- Plan 01-05 (verdict) is responsible for removing the feature flag after replay verdict is positive.

## Self-Check: PASSED

- File `Souffleuse/Sources/Souffleuse/MLXTokenCounter.swift` exists: FOUND
- File `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` (modified): FOUND
- Commit `a3c3a8c`: FOUND
- Commit `dab3c26`: FOUND
- `swift build`: exit 0
- `swift test`: exit 0 (94 tests)
- `bash audit.sh`: exit 0 (6/6 green)
- All positive grep gates: hit ≥ 1
- All negative grep gates: 0 hits
