---
phase: 02-high-signal-slots
plan: 04
subsystem: Souffleuse (app target) + SouffleusePrompt (visibility tweak)
tags: [predictor, app-delegate, phase2-wiring, slots, perf-01, prompt-build-ms]
requires:
  - "Plan 02-01: PromptSlot.previousUserInputs rename + PromptBuilder previousUserInputs param"
  - "Plan 02-02: AXSnapshot.placeholder / .help / .textAfterCaret shipped (read here for the first time on the predict path)"
  - "Plan 02-03: PromptBuilder.build(... fieldContext:, afterCursor:, ...), PromptBudget.phase2Default, PromptBuilder.roleLabelFR(role:subrole:)"
provides:
  - "PredictorViewModel.predict(prefix:, contextPrefix:, customInstructions:, axSnapshot:) — axSnapshot defaults to nil (source-compat for CLI bench callers)"
  - "fieldContextSlot body builder (D-15c French annotation) from snap.role/.subrole/.placeholder/.help"
  - "afterCursorSlot body builder (D-14 prose-FR delimiter) from snap.textAfterCaret"
  - "PromptBuilder switched to phase2Default budget when PromptBuilderFlag.enabled"
  - "Instruct-path slotTexts reconstruction now joins fieldContext + afterCursor between contextPrefix and previousUserInputs"
  - "Log.info(.predictor, \"prompt_build_ms\", count: ms) — SOLE automated PERF-01 handle in Phase 2"
  - "SouffleuseAppDelegate.tick() captures and forwards live snap to predictor.predict(...)"
  - "PromptBuilder.roleLabelFR promoted internal → public (Rule 3 — cross-module access)"
affects:
  - "Plan 02-05: replay harness now exercises the Phase 2 end-to-end pipeline when SOUFFLEUSE_PROMPT_BUILDER=1 is set; subjective TTFT verdict per D-17b/D-17c will compare end-to-end against the baseline 6ad70df commit"
tech-stack:
  added: []
  patterns:
    - "Optional-defaulted Sendable parameter (axSnapshot: AXSnapshot? = nil) — source-compat for CLI callers (SouffleuseCoherence, SouffleuseEnrichmentBench) that have no AX access"
    - "Captured-let pattern at debounce site (capturedSnap = snap) — mirrors existing capturedPrefix/capturedContext/capturedCustom convention for Sendable closure crossing"
    - "Per-build wall-clock timing via Date().timeIntervalSince(...) → Int ms — count-only log payload, StaticString event literal (TEST-03 audit-safe)"
key-files:
  created:
    - ".planning/phases/02-high-signal-slots/02-04-SUMMARY.md"
  modified:
    - "Souffleuse/Sources/Souffleuse/PredictorViewModel.swift"
    - "Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift"
    - "Souffleuse/Sources/SouffleusePrompt/PromptBuilder.swift (Rule 3 deviation — public)"
decisions:
  - "axSnapshot parameter is optional (= nil) — source-compat with CLI bench targets (SouffleuseCoherence, SouffleuseEnrichmentBench) that drive the predictor without an AX path. Production hot path (AppDelegate.tick) always forwards a live snap."
  - "fieldContextSlot and afterCursorSlot are constructed in PredictorViewModel rather than inside the builder. Rationale: the builder is a pure tokenizer-aware assembler; AX-shape knowledge stays in the layer that already imports SouffleuseAX."
  - "prompt_build_ms instrumentation logs builder ms only (NOT end-to-end TTFT). Per D-17b/D-17c, SouffleuseBench is intentionally excluded from Phase 2 (refactor invasive — deferred to KV-cache milestone). End-to-end TTFT is gated subjectively in Plan 02-05 Task 4."
  - "Both slot bodies emit empty string when their inputs are nil/empty — builder then skips the slot (D-14c / D-15). No 'Champ : nil.' or 'Suite du texte : « ».' ever reaches the prompt."
  - "Per CLAUDE.md privacy invariants, the only new log statement is Log.info(.predictor, \"prompt_build_ms\", count: buildMs) — StaticString event, Int-only payload. audit.sh check #2 and #5 enforce this globally; the explicit grep regex over Log.* with placeholder/help/textAfterCaret/built.text/fieldContextSlot/afterCursorSlot returns 0 hits as required."
metrics:
  duration: "≈ 15 min wall-clock"
  completed: "2026-05-25T09:43:17Z"
  tests_before: 109
  tests_after: 109
  new_tests: 0
---

# Phase 2 Plan 04: Wire fieldContext + afterCursor + axSnapshot End-to-End — Summary

One-liner: `PredictorViewModel.predict(...)` now accepts an optional `axSnapshot: AXSnapshot?`, builds the Phase 2 `fieldContext` (D-15c French annotation) and `afterCursor` (D-14 prose-FR delimiter) slot bodies inline from the live AX snapshot, switches the builder to `phase2Default`, threads the two new slots through the instruct-path `slotTexts` reconstruction, emits `Log.info(.predictor, "prompt_build_ms", count: ms)` as the sole automated PERF-01 handle for Phase 2, and the AppDelegate's debounced predict call forwards the same `snap` it already captured in `tick()` — 109/109 tests green, audit 6/6 green, legacy path entirely untouched.

## What Changed

### `PredictorViewModel.swift`

**New import** — `import SouffleuseAX` added to the import block so the `AXSnapshot` type is reachable.

**Signature change** at line 380:

```swift
func predict(
    prefix: String,
    contextPrefix: String = "",
    customInstructions: String = "",
    axSnapshot: AXSnapshot? = nil
) {
```

The `= nil` default keeps source compat with `SouffleuseCoherence` and `SouffleuseEnrichmentBench` CLI bench targets that have no AX access path.

**Inside the `if PromptBuilderFlag.enabled` branch**, the builder construction switches to `phase2Default`:

```swift
let builder = PromptBuilder(counter: counter, budget: .phase2Default)
```

**`fieldContextSlot` construction** (D-15c French annotation) — inserted before `builder.build(...)`:

```swift
let fieldContextSlot: String = {
    guard let snap = axSnapshot else { return "" }
    var lines: [String] = []
    if let label = PromptBuilder.roleLabelFR(role: snap.role, subrole: snap.subrole) {
        lines.append("Champ : \(label).")
    }
    if let placeholder = snap.placeholder?
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !placeholder.isEmpty {
        lines.append("Placeholder : « \(placeholder) ».")
    }
    if let help = snap.help?
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !help.isEmpty {
        lines.append("Aide : « \(help) ».")
    }
    return lines.joined(separator: "\n")
}()
```

When all 4 attributes are nil/empty, the slot resolves to `""` and the builder skips it (D-15 / `slotTexts[.fieldContext]` becomes nil).

**`afterCursorSlot` construction** (D-14 prose-FR delimiter):

```swift
let afterCursorSlot: String = {
    guard let snap = axSnapshot,
          let after = snap.textAfterCaret?
            .trimmingCharacters(in: .whitespacesAndNewlines),
          !after.isEmpty else { return "" }
    return "Suite du texte (à ne pas répéter) : « \(after) »."
}()
```

The PT model reads French typography natively; no FIM marker (per D-14c).

**Build call updated** to the Phase 2 7-arg form and wrapped with wall-clock timing:

```swift
let buildT0 = Date()
let built = builder.build(
    system: baseSystem,
    customInstructions: customInstr,
    contextPrefix: ctxPrefix,
    fieldContext: fieldContextSlot,
    afterCursor: afterCursorSlot,
    previousUserInputs: examplesBlock,
    beforeCursor: userTail
)
let buildMs = Int(Date().timeIntervalSince(buildT0) * 1000)
Log.info(.predictor, "prompt_built", count: built.totalTokens)
Log.info(.predictor, "prompt_build_ms", count: buildMs)
```

**Instruct-path `slotTexts` reconstruction** now joins the 2 new slots in the canonical order (D-14b):

```swift
let userContent = built.slotTexts[.beforeCursor] ?? ""
let systemContent = [
    built.slotTexts[.system],
    built.slotTexts[.customInstructions],
    built.slotTexts[.contextPrefix],
    built.slotTexts[.fieldContext],
    built.slotTexts[.afterCursor],
    built.slotTexts[.previousUserInputs],
].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
```

**Doc comment** above the `if PromptBuilderFlag.enabled` branch extended with 3 sentences explaining the Phase 2 additions, that AX reads happen at tick-time in `AXClient.readSnapshot` per D-15b (zero new AX cost on the predict path), and that `prompt_build_ms` is builder ms only — end-to-end TTFT remains subjectively gated in Plan 02-05 Task 4 per D-17b/D-17c.

**Legacy `else if isInstructModel` / `else` branches untouched.** `examplesBlock` derivation untouched (D-16c). `fewShotK` / `SimilarHistoryRetrieval` integration untouched.

### `SouffleuseAppDelegate.swift`

Single insertion alongside the existing capture group at the debounce site (line ~944):

```swift
predictDebounceTask?.cancel()
let capturedPrefix = prefix
let capturedContext = cachedEnrichmentPrefix
let capturedCustom = CustomInstructionsWindow.current()
let capturedSnap = snap                                    // Phase 2: forward live AX snapshot
predictDebounceTask = Task { @MainActor [weak self] in
    try? await Task.sleep(nanoseconds: Self.predictDebounceNanos)
    guard !Task.isCancelled, let self else { return }
    guard self.lastPredictedPrefix != capturedPrefix else { return }
    self.lastPredictedPrefix = capturedPrefix
    self.predictor.predict(
        prefix: capturedPrefix,
        contextPrefix: capturedContext,
        customInstructions: capturedCustom,
        axSnapshot: capturedSnap                           // Phase 2: feeds fieldContext + afterCursor slots
    )
}
```

`snap` is the same `let snap = axClient.snapshot()` (line 548) that already gates `isTextElement`, allowlist, and predict-debounce decisions. `AXSnapshot: Sendable` (locked in Plan 02-02 acceptance) so it crosses the closure boundary safely. No other `predictor.predict(...)` call site exists in the file (the matches at lines 122/172 are doc-comments).

No new log statement added to `SouffleuseAppDelegate.swift`. The existing dev-only `SOUFFLEUSE_PREDICT_LOG` tick observability at lines 551-563 is unchanged and remains out of the production audit scope.

### `PromptBuilder.swift` (deviation)

Promoted `PromptBuilder.roleLabelFR(role:subrole:)` from `internal` to `public`. Plan 02-03 left it `internal` based on the assumption that PredictorViewModel was reachable "within the same module-graph". In practice, `PredictorViewModel` lives in the `Souffleuse` SPM target while `PromptBuilder` lives in `SouffleusePrompt` — `internal` access does not cross SPM target boundaries. Fixed inline as Rule 3 (blocking issue).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] `PromptBuilder.roleLabelFR` access level**
- **Found during:** Task 1 — first `swift build` after editing `PredictorViewModel.swift` failed with `'roleLabelFR' is inaccessible due to 'internal' protection level`.
- **Issue:** Plan 02-03 declared `static func roleLabelFR(...)` as `internal` with a doc-comment claiming reachability "within the same module-graph". `PredictorViewModel` is in the `Souffleuse` SPM target; `roleLabelFR` is in the `SouffleusePrompt` target. Cross-target Swift symbols require `public`.
- **Fix:** Changed `static func roleLabelFR(...)` to `public static func roleLabelFR(...)`. Updated the doc-comment to reflect cross-target reachability. No call-site or behavior change.
- **Files modified:** `Souffleuse/Sources/SouffleusePrompt/PromptBuilder.swift`
- **Commit:** Included in Task 1 commit `ff8b5ba`.

## Verification

| Check | Result |
| ----- | ------ |
| `cd Souffleuse && swift build` | exit 0 |
| `cd Souffleuse && swift test` | 109/109 passed |
| `cd Souffleuse && bash audit.sh` | 6/6 PASSED |
| `grep -c 'axSnapshot: AXSnapshot? = nil' …/PredictorViewModel.swift` | 1 |
| `grep -c 'let fieldContextSlot: String' …/PredictorViewModel.swift` | 1 |
| `grep -c 'let afterCursorSlot: String' …/PredictorViewModel.swift` | 1 |
| `grep -c 'phase2Default' …/PredictorViewModel.swift` | 2 (call site + comment) |
| `grep -c 'prompt_build_ms' …/PredictorViewModel.swift` | 3 (string literal + comment refs) |
| `grep -c 'PromptBuilder.roleLabelFR' …/PredictorViewModel.swift` | 1 |
| `grep -c '"Champ : '`/`'"Placeholder : « '`/`'"Aide : « '`/`'"Suite du texte'` | 1 each (B-4 interpolation-safe substrings) |
| `grep -c 'fieldContext: fieldContextSlot' …/PredictorViewModel.swift` | 1 |
| `grep -c 'afterCursor: afterCursorSlot' …/PredictorViewModel.swift` | 1 |
| `grep -c 'built.slotTexts\[.fieldContext\]' …/PredictorViewModel.swift` | 1 |
| `grep -c 'built.slotTexts\[.afterCursor\]' …/PredictorViewModel.swift` | 1 |
| `grep -c 'let capturedSnap = snap' …/SouffleuseAppDelegate.swift` | 1 |
| `grep -c 'axSnapshot: capturedSnap' …/SouffleuseAppDelegate.swift` | 1 |
| `grep -nE 'Log\\.(info\|warn\|error)\\(.*(placeholder\|help\|textAfterCaret\|built\\.text\|fieldContextSlot\|afterCursorSlot)' …/PredictorViewModel.swift` | 0 matches (no user-text logging) |

## PERF-01 Scope (D-17b / D-17c reminder)

`prompt_build_ms` is the **SOLE automated PERF-01 handle** in Phase 2. It measures **builder ms only** — it is NOT end-to-end TTFT.

Per D-17b/D-17c, `SouffleuseBench` is intentionally excluded from Phase 2 (its refactor would be invasive — deferred to the KV-cache milestone). End-to-end TTFT is therefore evaluated subjectively during daily-use in Plan 02-05 Task 4 (verdict captured in `02-VERIFICATION.md` "PERF-01 attribution" subsection).

If `prompt_build_ms` ever exceeds the ~30 ms rollback threshold (D-17d), the slot attribution is observable on the builder ms axis. End-to-end degradation cannot be attributed to a single slot from `prompt_build_ms` alone — that requires the Plan 02-05 subjective verdict + per-slot toggle protocol.

## Commits

| Task | Hash | Message |
| ---- | ---- | ------- |
| 1    | `ff8b5ba` | feat(02-04): wire fieldContext + afterCursor + axSnapshot into PredictorViewModel (SLOT-02, SLOT-03, SLOT-04, PERF-01) |
| 2    | `3f6f16a` | feat(02-04): forward AXSnapshot from AppDelegate tick to predictor.predict (SLOT-02, SLOT-03) |

## Self-Check: PASSED

- File `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` modified: FOUND
- File `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift` modified: FOUND
- File `Souffleuse/Sources/SouffleusePrompt/PromptBuilder.swift` modified (Rule 3): FOUND
- Commit `ff8b5ba`: FOUND in git log
- Commit `3f6f16a`: FOUND in git log
- 109/109 tests pass (verified twice, no regression)
- audit.sh: 6/6 PASSED
- No new user-text-interpolating log statement (regex returns 0 matches)
