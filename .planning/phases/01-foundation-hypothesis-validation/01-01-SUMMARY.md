---
phase: 01-foundation-hypothesis-validation
plan: 01
subsystem: SouffleusePrompt
tags: [swift, mlx, prompt-engineering, spm, audit, foundation]
requires: []
provides:
  - "SPM library target `SouffleusePrompt` (5 public types)"
  - "Pure value-type `PromptBuilder` ready for snapshot tests (plan 01-02)"
  - "`TokenCounting` protocol seam over MLX tokenizer (plan 01-03 site)"
affects:
  - "Souffleuse/Package.swift (1 library + 1 target + 2 consumer deps)"
  - "Souffleuse/audit.sh (SHIPPING_DIRS scope extended)"
tech-stack:
  added: []
  patterns:
    - "Value-type Sendable struct mirroring AXSnapshot/EnrichedContext shape"
    - "`-ing`-suffixed Sendable protocol mirroring OCRCaretLocating"
    - "Per-slot independent truncation + global eviction priority (D-04)"
    - "Head-truncation preserving tail for beforeCursor (D-11)"
key-files:
  created:
    - "Souffleuse/Sources/SouffleusePrompt/PromptSlot.swift"
    - "Souffleuse/Sources/SouffleusePrompt/PromptBudget.swift"
    - "Souffleuse/Sources/SouffleusePrompt/BuiltPrompt.swift"
    - "Souffleuse/Sources/SouffleusePrompt/TokenCounting.swift"
    - "Souffleuse/Sources/SouffleusePrompt/PromptBuilder.swift"
  modified:
    - "Souffleuse/Package.swift"
    - "Souffleuse/audit.sh"
decisions:
  - "Followed D-12 (feature flag dev-only in parallel) by introducing a brand-new SPM target rather than refactoring PredictorViewModel in-place."
  - "evictionPriority order kept identical to RESEARCH §4 tie-breaker: fewShot → customInstructions → contextPrefix → beforeCursor (squeeze, not drop) → system."
  - "phase1Default budget kept at RESEARCH §4 values: system=80, customInstructions=40, contextPrefix=150, fewShot=80, beforeCursor=200, global=512."
  - "beforeCursor is special-cased in eviction: instead of being dropped when the global cap fires, it is further head-truncated (preserves tail = caret-adjacent signal). All other slots are dropped wholesale."
metrics:
  duration: "~6 minutes (single executor session)"
  tasks_completed: 3
  files_created: 5
  files_modified: 2
  tests_run: 94
  tests_passed: 94
  tests_failed: 0
  audit_checks_passed: 6
  audit_checks_total: 6
  completed: "2026-05-24"
requirements_covered: [BUILDER-01, BUILDER-02, SLOT-01, TEST-03]
---

# Phase 01 Plan 01: SouffleusePrompt Foundation Skeleton Summary

**One-liner:** New SPM target `SouffleusePrompt` exposes 5 public Sendable types (`PromptSlot`, `PromptBudget`, `BuiltPrompt`, `TokenCounting`, `PromptBuilder`) implementing token-budgeted prompt assembly with per-slot eviction and head-truncation for `beforeCursor`; wired into `Package.swift` + `audit.sh` with 94 existing tests still green.

## What Was Built

### 5 New Swift Files in `Sources/SouffleusePrompt/`

| File | Type | Lines | Role |
|------|------|------:|------|
| `PromptSlot.swift` | `public enum PromptSlot: String, Sendable, CaseIterable, Hashable` | 22 | 10 cases — 5 active Phase 1 (`system`, `customInstructions`, `contextPrefix`, `fewShot`, `beforeCursor`) + 5 reserved Phase 2/3 (`afterCursor`, `fieldContext`, `previousUserInputs`, `clipboardContext`, `screenContext`) |
| `PromptBudget.swift` | `public struct PromptBudget: Sendable, Equatable` | 31 | `global: Int` + `perSlot: [PromptSlot: Int]` + `static let phase1Default` |
| `BuiltPrompt.swift` | `public struct BuiltPrompt: Sendable, Equatable` | 44 | Assembly result: `text`, `slotTexts`, `slotTokenCounts`, `truncatedSlots`, `totalTokens`, `didEvict` |
| `TokenCounting.swift` | `public protocol TokenCounting: Sendable` | 20 | `countTokens(_:) -> Int` and `truncateHead(_:toBudget:) -> String` — the seam decoupling builder from MLX tokenizer (D-06) |
| `PromptBuilder.swift` | `public struct PromptBuilder: Sendable` | 155 | Deterministic `build(system:customInstructions:contextPrefix:fewShot:beforeCursor:) -> BuiltPrompt` with per-slot truncation + global eviction loop |

Total: 272 lines (5 files), one primary type per file (CONVENTIONS.md §Naming).

### Final Per-Slot Budget Values (Confirmed)

```swift
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
```

Sum-of-slots = **550**, global = **512** ⇒ eviction triggered when all slots fill simultaneously. Identical to RESEARCH §4.

### evictionPriority Order

```swift
public static let evictionPriority: [PromptSlot] = [
    .fewShot,             // drop first — quality enhancer only
    .customInstructions,  // drop second — usually small but optional
    .contextPrefix,       // drop third — large but useful
    .beforeCursor,        // squeeze (head-truncate, not drop) — load-bearing
    .system,              // never drop in Phase 1 — last resort
]
```

Direct match with RESEARCH §4 tie-breaker. `beforeCursor` is special-cased inside the eviction loop: it is head-truncated by the exact overflow amount and re-measured, rather than dropped.

### Package.swift Wiring

- Added `.library(name: "SouffleusePrompt", targets: ["SouffleusePrompt"])` product (line 22).
- Added `.target(name: "SouffleusePrompt", dependencies: ["SouffleuseLog", .product(name: "MLXLMCommon", package: "mlx-swift-examples")])` (lines 55–61) — minimal deps per RESEARCH §9.
- Added `"SouffleusePrompt"` to `Souffleuse` executable target deps (line 80).
- Added `"SouffleusePrompt"` to `SouffleuseTests` test target deps (line 110).

### audit.sh Scope

`Sources/SouffleusePrompt` added to `SHIPPING_DIRS`. The 6 privacy checks now scan the new module.

## Audit Results (all 6 checks)

| # | Check | Result |
|---|------|--------|
| 1 | No `print()` in shipping targets | **OK** |
| 2 | No `NSLog` in shipping targets | **OK** |
| 3 | No `os_log` with user-text interpolation | **OK** |
| 4 | Log file fields whitelisted (`{ts, level, module, event, count?}`) | **OK** (4311 lines scanned) |
| 5 | `history.aes` never read outside `TypingHistoryStore` + `HistoryViewerWindow` | **OK** |
| 6 | No raw acceptance text logged via `Log.*` interpolating user fields | **OK** |

`=== AUDIT PASSED ===`

## Test Results

```
Test run with 94 tests in 0 suites passed after 0.398 seconds.
Build complete! (9.65s)
```

**94 / 94 passed**, 0 failed. Zero regression on TEST-01.

## Build Results

- `swift build --target SouffleusePrompt` → **exit 0** (target compiles in isolation).
- `swift build` → **exit 0** (entire package, including consumers, links cleanly — 127 build steps).

## Commits

| Task | Commit | Subject |
|------|--------|---------|
| 1 | `028ff00` | feat(01-01): add SouffleusePrompt module skeleton (5 types) |
| 2 | `1f96796` | feat(01-01): wire SouffleusePrompt target in Package.swift |
| 3 | `e0234b3` | chore(01-01): extend audit.sh SHIPPING_DIRS to cover SouffleusePrompt |

## Deviations from Plan

### [Rule 3 — Missing artifact] `SouffleuseCoherence` target not in worktree

- **Found during:** Task 2.
- **Issue:** Plan instruction 2.4 directed adding `"SouffleusePrompt"` to the `SouffleuseCoherence` executable target deps. The `SouffleuseCoherence` target is **absent** from this worktree — neither declared in `Package.swift` nor present under `Sources/`. (It exists on `main` as an untracked WIP directory, but the worktree was reset to base `670d1f0` which predates that work.)
- **Fix:** Skipped step 2.4. All other 3 wiring edits (library product, target declaration, `Souffleuse` deps, `SouffleuseTests` deps) applied. Documented in commit body so the next time `SouffleuseCoherence` is committed, whoever introduces it will know to add `"SouffleusePrompt"` to its deps if needed.
- **Files modified:** None beyond plan (in fact, one fewer edit than planned).
- **Commit:** `1f96796`.

### [Rule 1 — Compile fix] `Self.tailTruncateToWordBoundary` + explicit eviction branch

- **Found during:** Task 1 (mental compile pass before writing).
- **Issue 1:** Plan's `PromptBuilder.swift` snippet called `tailTruncateToWordBoundary(...)` unqualified from inside `build(...)`. Without `Self.`, Swift would resolve this against instance scope and fail to find the static helper.
- **Issue 2:** Plan's snippet attempted `slotTexts[victim] = shrunk.isEmpty ? nil : shrunk` to clear a dictionary entry — but a `[K: V]` subscript expression can't elegantly assign `nil` here when the value type is non-optional `String`. Same shape used for `slotCounts`.
- **Fix:** Qualified the helper call with `Self.tailTruncateToWordBoundary(...)`. Replaced the ternary subscript-to-nil with an explicit `if shrunk.isEmpty { removeValue(forKey:) } else { ... = shrunk }` branch (same semantics, type-checks cleanly).
- **Files modified:** `Souffleuse/Sources/SouffleusePrompt/PromptBuilder.swift` (only this file; logic identical to plan's intent).
- **Commit:** `028ff00`.

### [Acceptance criterion adjustment] `grep -c 'SouffleusePrompt' Package.swift`

- **Found during:** Task 2 post-edit verification.
- **Issue:** Plan acceptance criterion expected `grep -c 'SouffleusePrompt' Souffleuse/Package.swift ≥ 6`. Actual count: **4 matching lines** (5 occurrences total — line 22 contains the name twice). Because `SouffleuseCoherence` wasn't wired (above), one expected line is missing. The remaining 4 lines (`library product`, `target declaration`, `Souffleuse exec deps`, `SouffleuseTests deps`) account for every required wiring point that exists in this worktree.
- **Fix:** Verified functional correctness via direct line inspection (`grep -n`) rather than count threshold. Build success (`swift build` exit 0) is the ultimate proof.

No other deviations.

## Threat Flags

None. No new attack surface beyond what was anticipated in `<security_threat_model>` (T-01-01 mitigated by zero `Log.*`/`print(`/`NSLog(`/`os_log(` calls verified by audit; T-01-02 mitigated by adding `Sources/SouffleusePrompt` to SHIPPING_DIRS).

## Known Stubs

None. The 5 types are complete public APIs ready to be exercised by plan 01-02 (snapshot tests) and plan 01-03 (MLX tokenizer adapter + integration into `PredictorViewModel`).

## Requirements Coverage

- **BUILDER-01** (PromptBuilder struct exists with correct API surface): ✅ `public struct PromptBuilder: Sendable` with `init(counter:budget:)` and `build(system:customInstructions:contextPrefix:fewShot:beforeCursor:) -> BuiltPrompt`.
- **BUILDER-02** (Per-slot token budget + eviction policy): ✅ `PromptBudget.phase1Default` + `PromptBuilder.evictionPriority`.
- **SLOT-01** (`beforeCursor` head-truncation preserving tail): ✅ implemented via `counter.truncateHead` call inside both the per-slot truncation loop and the global eviction squeeze branch.
- **TEST-03** (`audit.sh` extended and green over new module): ✅ `Sources/SouffleusePrompt` added; 6/6 checks pass.

## Self-Check

- File `Souffleuse/Sources/SouffleusePrompt/PromptSlot.swift`: **FOUND**
- File `Souffleuse/Sources/SouffleusePrompt/PromptBudget.swift`: **FOUND**
- File `Souffleuse/Sources/SouffleusePrompt/BuiltPrompt.swift`: **FOUND**
- File `Souffleuse/Sources/SouffleusePrompt/TokenCounting.swift`: **FOUND**
- File `Souffleuse/Sources/SouffleusePrompt/PromptBuilder.swift`: **FOUND**
- Commit `028ff00`: **FOUND**
- Commit `1f96796`: **FOUND**
- Commit `e0234b3`: **FOUND**

## Self-Check: PASSED
