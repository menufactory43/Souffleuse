---
phase: 02-high-signal-slots
plan: 02
subsystem: SouffleuseAX
tags: [ax, snapshot, slot-02, slot-03, sendable]
requires:
  - "01: PromptSlot.previousUserInputs rename (Wave 1)"
provides:
  - "AXSnapshot fields: placeholder, help, textAfterCaret"
  - "AXClient.readSnapshot populates 3 new fields upstream of predict debounce"
  - "Private helper stringForRange(_:location:length:) on kAXStringForRangeParameterizedAttribute"
affects:
  - "Plan 02-04 (slot wiring) — directly consumes new AXSnapshot fields"
tech-stack:
  added: []
  patterns:
    - "parameterized AX read via CFRange + AXValueCreate (mirrors boundsForRange)"
    - "snapshot-time AX read (D-15b) keeps predict hot path debt-free"
key-files:
  created: []
  modified:
    - Souffleuse/Sources/SouffleuseAX/AXClient.swift
decisions:
  - "Bounded textAfterCaret to 500 chars at AX boundary (well above 120-token afterCursor budget; absolute cap on multi-MB docs)"
  - "All 3 new fields routed through existing secure-field early-return — zero new privacy surface"
  - "No barrel helper or hasFieldMetadata convenience — Plan 02-04 composes slots inline"
metrics:
  duration: "≈8 min"
  completed: "2026-05-25"
requirements:
  - SLOT-02
  - SLOT-03
---

# Phase 02 Plan 02: AXSnapshot Field Metadata + textAfterCaret Summary

Extended `AXSnapshot` with `placeholder`, `help`, and `textAfterCaret` optional fields and populated them in `AXClient.readSnapshot()` at the 80ms tick — upstream of the 50ms predict debounce — so downstream slot builders pay zero TTFT cost (D-15b).

## What Changed

### `AXSnapshot` struct (`Souffleuse/Sources/SouffleuseAX/AXClient.swift`)

Added three optional stored properties with documented intent:

- `public let placeholder: String?` — `kAXPlaceholderValueAttribute` of the focused element. High-signal for empty-field cases per Phase 1 verdict.
- `public let help: String?` — `kAXHelpAttribute`. Tooltip-style framing exposed by accessibility-aware apps.
- `public let textAfterCaret: String?` — substring read via `kAXStringForRangeParameterizedAttribute`, bounded to 500 chars upstream.

All three fields default to `nil` in the init signature so existing AXSnapshot call sites (test fixtures, mocks, early-return paths) compile unchanged.

### `AXClient.readSnapshot()`

Inserted a Phase-2-tagged block after the `caretFont` read, INSIDE the text-element gate (`role` validated; secure-field early-return already passed). The block:

1. Reads `placeholder` and `help` via the existing `copyStringAttr(_:_:)` helper — single AX call each, no allocation surprises.
2. Computes `textAfterCaret` from `(text, caretIndex)`: returns `nil` when caret is at end-of-text or `text.count - caretIndex <= 0`; otherwise reads `min(remaining, 500)` chars via the new helper.

The final `return AXSnapshot(...)` now passes all three fields. The other three `return AXSnapshot(...)` paths (no focused app, no focused element, secure field, non-text element) construct without naming the new params, so all three default to `nil` for those snapshots — matching the secure-field privacy expectation.

### New private helper `stringForRange(_:location:length:)`

Placed immediately after `boundsForRange`, mirroring the same `CFRange + AXValueCreate + AXUIElementCopyParameterizedAttributeValue` machinery but on `kAXStringForRangeParameterizedAttribute` with a `String?` return cast. Guards: `length > 0`, AX status `.success`, non-empty cast result.

## AX Attribute Constants Used

| Constant | Used by | Lines |
|---|---|---|
| `kAXPlaceholderValueAttribute` | `placeholder` read | doc-comment + read site |
| `kAXHelpAttribute` | `help` read | doc-comment + read site |
| `kAXStringForRangeParameterizedAttribute` | `stringForRange` helper | doc-comment + 2 call/read sites |

## Privacy & Safety Verification

- **Secure-field guard preserved.** Lines 397-399 still short-circuit `AXSecureTextField` before our new reads execute. The early-return constructs an AXSnapshot without naming the new params → all three default to `nil`. Verified by code inspection: the new block sits in the body that runs ONLY after `role`/`textRoles` validation.
- **No new log statements.** `grep -nE '(print\(|NSLog\(|os_log\()' AXClient.swift` returns 0. No `Log.*` call references placeholder/help/textAfterCaret. Audit checks #1-3 stay green.
- **`audit.sh`: 6/6 PASS** (`AUDIT PASSED` reported).
- **Bounded read.** `textAfterCaret` capped via `min(remaining, 500)`. Caps `text.count - caretIndex` at 500 chars upstream of any downstream slot work — defends against multi-MB documents.
- **Sendable + Equatable.** All new fields are `String?` (already `Sendable`); `Equatable` synthesis still applies. No `@unchecked Sendable` introduced.

## 500-Char Cap Rationale

Phase 2 afterCursor slot budget is ~120 tokens (D-14d), which is roughly 480 chars at the byte-pair-encoding ratios we see in French + English. 500 chars gives:

- ≥ 1.04× the worst-case slot budget so downstream truncation always operates on a non-degraded source.
- A hard ceiling at the AX boundary — if a user is editing a 10MB Markdown document, AX never has to serialize more than 500 chars to us.
- Headroom for upstream slicing (e.g. character-boundary fixups, leading-space trimming) before the slot budget bite.

## Tests & Audit

- **`swift build`**: PASS (build complete, 8.00s).
- **`swift test`**: 104/104 tests passed (no fixture changes required — defaulted init params absorbed all existing call sites).
- **`audit.sh`**: 6/6 checks green.

## Deviations from Plan

None — plan executed exactly as written. Both tasks landed atomically with the commit messages prescribed by the plan.

## Commits

| Task | Commit | Description |
|---|---|---|
| 1 | `84a6aff` | feat(02-02): extend AXSnapshot with placeholder/help/textAfterCaret fields |
| 2 | `1dcba5d` | feat(02-02): read placeholder/help/textAfterCaret in AXClient.readSnapshot() (SLOT-02, SLOT-03) |

## Downstream Handoff

Plan 02-04 (Wave 3) now has working AXSnapshot data on hand:

- `snapshot.placeholder` → input to a `PromptSlot.fieldMetadata` body builder.
- `snapshot.help` → input to the same fieldMetadata slot, blended with placeholder.
- `snapshot.textAfterCaret` → direct input to a `PromptSlot.afterCursor` slot.

The PredictorViewModel debounce is unchanged; no new AX calls happen on the predict hot path.

## Self-Check: PASSED

- `Souffleuse/Sources/SouffleuseAX/AXClient.swift` modified: FOUND.
- Commit `84a6aff` (Task 1): FOUND in `git log`.
- Commit `1dcba5d` (Task 2): FOUND in `git log`.
- `swift test`: 104/104 PASS.
- `audit.sh`: 6/6 PASS.
- `grep -c 'public let placeholder: String?'` → 1, `'public let help: String?'` → 1, `'public let textAfterCaret: String?'` → 1.
- `grep -c 'private func stringForRange'` → 1, `'min(remaining, 500)'` → 1.
