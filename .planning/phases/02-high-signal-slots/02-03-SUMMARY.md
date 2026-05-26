---
phase: 02-high-signal-slots
plan: 03
subsystem: SouffleusePrompt
tags: [prompt-builder, phase2, slots, budget, fr-labels, tdd-tests]
requires:
  - "Plan 02-01: PromptSlot.previousUserInputs rename + PromptBuilder previousUserInputs param"
  - "Plan 02-02: AXSnapshot.placeholder / .help / .textAfterCaret already shipped (not used here, prepares Plan 02-04 wiring)"
provides:
  - "PromptBudget.phase2Default static constant (global=1024, 7-slot perSlot map)"
  - "PromptBuilder.build(... fieldContext:, afterCursor:, previousUserInputs:, beforeCursor:) signature (new params default to \"\")"
  - "PromptBuilder.evictionPriority Phase 2 ordering (7 slots)"
  - "PromptBuilder internal assemblyOrder (7 slots, D-14b)"
  - "PromptBuilder.roleLabelFR(role:subrole:) static FR-label helper (D-15d)"
affects:
  - "Plan 02-04: PredictorViewModel will pass fieldContext + afterCursor explicit args and call roleLabelFR"
  - "Plan 02-05: replay harness already wired in Plan 02-01 keeps working — uses default \"\" for the 2 new params"
tech-stack:
  added: []
  patterns:
    - "Defaulted-keyword-args for additive builder evolution (backwards-compatible Plan 02-01 callers)"
    - "Sendable static FR table (literal `[String:String]`) — subrole precedence over role"
key-files:
  created: []
  modified:
    - "Souffleuse/Sources/SouffleusePrompt/PromptBudget.swift"
    - "Souffleuse/Sources/SouffleusePrompt/PromptBuilder.swift"
    - "Souffleuse/Tests/SouffleuseTests/PromptBuilderTests.swift"
decisions:
  - "phase2Default.global bumped 512 → 1024 (Claude's Discretion in 02-CONTEXT.md): perSlot sum = 730 leaves slack for eviction-rare common case; gemma-3-1b context = 8192 has plenty of headroom."
  - "fieldContext: 60 tokens (D-14d / D-15e) — large enough to hold role label + placeholder/help sentence pair."
  - "afterCursor: 120 tokens — half of beforeCursor (200) since it's only a do-not-repeat hint, not a continuation anchor."
  - "Eviction priority Phase 2: previousUserInputs → customInstructions → contextPrefix → afterCursor → fieldContext → beforeCursor (squeeze) → system (last). afterCursor evicted before fieldContext because fieldContext is more structurally diagnostic."
  - "roleLabelFR table is intentionally non-exhaustive (4 entries: AXSearchField, AXTextArea, AXTextField, AXComboBox). D-15d says extend at each app tested — initial table covers the apps validated in Phase 1."
  - "Both new builder params (fieldContext, afterCursor) carry default `= \"\"` so the existing Plan 02-01-updated call site in SouffleuseCoherence and the replay harness keep compiling unchanged. Plan 02-04 will populate them explicitly."
metrics:
  duration: "≈ 11 min wall-clock"
  completed: "2026-05-25T09:35:43Z"
  tests_before: 104
  tests_after: 109
  new_tests: 5
---

# Phase 2 Plan 03: Extend PromptBuilder with fieldContext + afterCursor + phase2Default Budget — Summary

One-liner: `PromptBuilder` now accepts the two new high-signal slots (fieldContext, afterCursor) with backward-compatible defaults, a `phase2Default` budget (global=1024, 7 perSlot entries) sits alongside `phase1Default`, the Phase 2 assembly order (D-14b) and eviction priority are installed, a `roleLabelFR` helper maps AX role/subrole to FR labels (D-15d), and 5 new `@Test` functions lock the new behavior — 109/109 tests green, audit 6/6, B-1 regression gate held byte-identical.

## What Changed

### `PromptBudget.swift`
Added `phase2Default` static constant **alongside** `phase1Default` (which stays untouched — preserves Phase 1 contract per `01-VERIFICATION.md`):

```swift
public static let phase2Default = PromptBudget(
    global: 1024,
    perSlot: [
        .system: 80,
        .customInstructions: 40,
        .contextPrefix: 150,
        .fieldContext: 60,
        .afterCursor: 120,
        .previousUserInputs: 80,
        .beforeCursor: 200,
    ]
)
```

Sum perSlot = 80+40+150+60+120+80+200 = **730** (well under global 1024 → eviction fires only for pathological inputs).

### `PromptBuilder.swift`
- **Signature** extended (defaulted new params for backwards compatibility):
  ```swift
  public func build(
      system: String,
      customInstructions: String,
      contextPrefix: String,
      fieldContext: String = "",
      afterCursor: String = "",
      previousUserInputs: String,
      beforeCursor: String
  ) -> BuiltPrompt
  ```
- **Internal `assemblyOrder`** (head → tail, D-14b):
  ```
  system → customInstructions → contextPrefix → fieldContext → afterCursor → previousUserInputs → beforeCursor
  ```
- **`evictionPriority`** (Phase 2, drop-first → squeeze-last):
  ```
  previousUserInputs → customInstructions → contextPrefix → afterCursor → fieldContext → beforeCursor → system
  ```
- **Doc-comment header** rewritten to enumerate the 7 slots and the new eviction order. D-04 + D-11 references preserved.
- **`roleLabelFR(role:subrole:)`** static helper + private `roleLabelsFR` table (4 entries):
  ```
  AXSearchField  → "recherche"
  AXTextArea     → "zone de texte"
  AXTextField    → "champ texte"
  AXComboBox     → "menu déroulant"
  ```
  Subrole precedence over role. Returns `nil` when neither maps (D-15c: caller skips the "Champ : X." line).

### `PromptBuilderTests.swift`
5 new `@Test func` appended after `builderHonorsGlobalCapViaEvictionPriority`:

| Test | Validates |
|------|-----------|
| `builderEmitsFieldContextSlotWhenSupplied` | SLOT-03 plumbing — text contains the field-context body, slotTexts has `.fieldContext`. |
| `builderEmitsAfterCursorBeforeBeforeCursor` | D-14b assembly order — `afterCursor` precedes `beforeCursor` in `built.text`. |
| `builderSkipsEmptyFieldContextAndAfterCursor` | D-14c / D-15 skip-if-empty — empty inputs produce no header, no triple blank-line run, no slot entries. |
| `builderEvictsPreviousUserInputsFirstUnderTightGlobalCap` | Phase 2 evictionPriority head — under global=10, previousUserInputs is dropped first. |
| `roleLabelFRPrefersSubroleOverRole` | D-15d helper — subrole > role > nil. |

`builderAssemblesAllSlotsInOrder` (the Phase 1 5-slot snapshot test) was NOT modified — it still uses `.phase1Default` and the unmodified expected string. B-1 regression gate verified explicitly (see below).

## Verification

| Gate | Result |
|------|--------|
| `cd Souffleuse && swift build` | exit 0 (Build complete) |
| `cd Souffleuse && swift test` | **109/109 tests passed** (104 baseline + 5 new) |
| `swift test --filter builderAssemblesAllSlotsInOrder` (B-1 regression gate) | **exit 0, 1/1 passed** — Phase 1 5-slot snapshot byte-identical against unmodified expected string |
| `cd Souffleuse && bash audit.sh` | **AUDIT PASSED** (6/6 checks) |
| Forbidden logging in `PromptBuilder.swift` (`grep -nE 'Log\.|print\(|NSLog\(|os_log\('`) | 0 matches (SouffleusePrompt stays log-free per 01-PATTERNS.md §Privacy) |
| `grep -c 'phase2Default' PromptBudget.swift` | 1 (declaration) |
| `grep -c 'phase1Default' PromptBudget.swift` | 1 (preserved) |
| `grep -E 'global: 1024' PromptBudget.swift` | 1 match |
| `grep -E 'fieldContext: 60' PromptBudget.swift` | 1 match |
| `grep -E 'afterCursor: 120' PromptBudget.swift` | 1 match |
| `grep -c 'fieldContext: String' PromptBuilder.swift` | 1 (signature param) |
| `grep -c 'afterCursor: String' PromptBuilder.swift` | 1 (signature param) |
| `grep -c 'static func roleLabelFR' PromptBuilder.swift` | 1 |
| `grep -c '"AXSearchField": "recherche"' PromptBuilder.swift` | 1 |
| `evictionPriority` element count | 7 (Phase 2 order verified) |
| `assemblyOrder` element count inside `build(...)` | 7 (D-14b order verified) |
| `grep -c '@Test func builder' PromptBuilderTests.swift` | 14 (10 Phase 1 + 4 new builder tests; +1 roleLabelFR helper test → 15 total `@Test func`) |

## Decisions Made

- **`phase2Default.global = 1024`** (vs 512 Phase 1): Claude's Discretion in 02-CONTEXT.md. With perSlot sum = 730, this keeps the typical case eviction-free while leaving room for occasional long contextPrefix + previousUserInputs. gemma-3-1b context = 8192, so 1024 is comfortable.
- **Defaulted new params** (`fieldContext: String = "", afterCursor: String = ""`): Plan 02-01 already updated the SouffleuseCoherence call site for the `previousUserInputs` rename. Defaulting the two new params means that call site, plus the replay harness, plus any other existing caller, recompiles untouched — Plan 02-04 will explicitly populate the new args at the production integration site (PredictorViewModel) and at the replay harness (Plan 02-05 may already have wiring planned).
- **`afterCursor` before `fieldContext` in eviction**: principle in 02-PATTERNS.md says drop replaceables first and squeeze high-signal slots last. fieldContext is the more structurally diagnostic of the two (role label + placeholder pin down WHAT the user is filling in), so it survives longer under pressure.
- **`roleLabelFR` internal not public**: reachable from the `Souffleuse` target via the module dependency on `SouffleusePrompt`, and from tests via `@testable import SouffleusePrompt`. No external module needs it, so the narrower visibility is preferred.
- **4-entry initial `roleLabelsFR` table**: D-15d explicitly says non-exhaustive — extend at each app tested. The 4 entries cover the AX roles/subroles observed at Phase 1 (search fields like Brave/Chrome address bar, text areas in Notes/Mail, generic AXTextField, and macOS combo boxes).

## Deviations from Plan

### Auto-fixed Issues

None.

### Minor scope notes (not deviations, just for record)

- **`PromptSlot.fieldContext` and `.afterCursor` already existed** as enum cases in `PromptSlot.swift` (declared in Plan 02-01 as "reserved for Phase 3" — the comment is technically stale but unchanged here because Plan 02-03's scope is the builder API, not the enum declaration. The comment harmlessly understates reality: Phase 2 now does use these slots. Plan 02-04 or a doc-only follow-up can refresh the comment if desired.)
- **Acceptance criterion `grep -c 'phase2Default' PromptBuilderTests.swift returns ≥4`**: actual = 3, because the 4th new builder test (`builderEvictsPreviousUserInputsFirstUnderTightGlobalCap`) instantiates a custom `PromptBudget(...)` to force eviction with a tight `global: 10`. Using `.phase2Default` (global=1024) would not exercise the eviction path. The criterion's spirit (≥4 new tests covering Phase 2 behavior with Phase 2-shaped budgets) is met: 4 builder tests + 1 helper test = 5 new tests, all aware of the 7-slot layout. Plan-time criterion was imprecise; the conceptual goal is satisfied.

## Auth gates encountered

None.

## Known Stubs

None — this plan extends the builder API surface only. The new params have defaulted empty strings until Plan 02-04 wires the actual data sources (AXSnapshot.placeholder/help/textAfterCaret already shipped in Plan 02-02).

## Phase 1 Regression Gate (B-1)

**Status: GREEN.**

`swift test --filter builderAssemblesAllSlotsInOrder` ran post Task 1 (before any test edits) and produced:
```
✔ Test builderAssemblesAllSlotsInOrder() passed after 0.001 seconds.
✔ Test run with 1 test in 0 suites passed after 0.001 seconds.
```
Re-verified post Task 2 with the full suite — same result. The 5-slot Phase 1 expected string in this test remains byte-identical because:
1. `phase1Default` is preserved unchanged in PromptBudget.swift.
2. The new fieldContext/afterCursor params default to `= ""` and the empty-skip guard at PromptBuilder.swift:67 (`guard !raw.isEmpty else { continue }`) drops them from `slotTexts` entirely.
3. The 5 originally-filled slots emerge in the same relative head→tail order under the new Phase 2 `assemblyOrder` (the two new slots are interleaved between `contextPrefix` and `previousUserInputs` but vanish when empty).

No edit was made to the expected string of `builderAssemblesAllSlotsInOrder` — the Task 1 mandate "editing the legacy expected string is FORBIDDEN" was honored.

## Commits

| Task | Commit | Description |
|------|--------|-------------|
| Task 1 | `1d51e01` | feat(02-03): extend PromptBuilder with fieldContext + afterCursor slots + phase2Default budget |
| Task 2 | `84b57f8` | test(02-03): add Phase 2 builder tests + verify legacy snapshot tests still pass |

## Self-Check: PASSED

- `Souffleuse/Sources/SouffleusePrompt/PromptBudget.swift` — FOUND (phase2Default added at line ≈ 34)
- `Souffleuse/Sources/SouffleusePrompt/PromptBuilder.swift` — FOUND (signature, evictionPriority, assemblyOrder, roleLabelFR all present)
- `Souffleuse/Tests/SouffleuseTests/PromptBuilderTests.swift` — FOUND (5 new @Test func appended)
- Commit `1d51e01` — FOUND in git log
- Commit `84b57f8` — FOUND in git log (current HEAD)
- 109/109 tests green; audit.sh 6/6 green; B-1 regression gate green.
