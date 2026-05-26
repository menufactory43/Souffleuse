---
phase: 03-perf-kv-cache
plan: 01
subsystem: predictor
tags: [kv-cache, mlx, fingerprint, sha256, swift, scaffold]
requires: []
provides:
  - KVCacheHolder (@MainActor final class)
  - InvariancePrefix (Sendable, Equatable struct)
  - InvariancePrefix.fingerprint (SHA256 lower-hex, 64 chars)
  - InvariancePrefix.canonicalizePreviousUserInputs(_:delimiter:)
affects: []
tech-stack:
  added: []
  patterns:
    - "CryptoKit SHA256 over US-separated slot concatenation"
    - "[Any] opaque storage to keep scaffold MLX-free until 03-02 bridges"
key-files:
  created:
    - Souffleuse/Sources/Souffleuse/KVCacheHolder.swift
    - Souffleuse/Tests/SouffleuseTests/KVCacheHolderTests.swift
  modified: []
key-decisions:
  - "Stored caches as [Any]? instead of [KVCache]? — user-scope deviation from PLAN.md to keep the holder unit-testable without linking MLXLMCommon. Plan 03-02 will downcast at the MLX call site."
  - "Frozen 6-slot order (system → customInstructions → contextPrefix → fieldContext → afterCursor → previousUserInputs); beforeCursor is structurally absent (D-KV-03 compile-time guarantee)."
  - "US (0x1F) Unit Separator joins slots before SHA256 to defeat concatenation ambiguity (T-03-01-01 mitigation)."
  - "canonicalizePreviousUserInputs(_:delimiter:) sorts + whitespace-collapses few-shot blocks so SimilarHistoryRetrieval ranking jitter cannot invalidate the cache every predict (Warning #2 from plan-checker iter 2)."
requirements-completed: [KV-03, TEST-01, TEST-03]
duration: 9 min
completed: 2026-05-25
---

# Phase 03 Plan 01: KVCacheHolder + InvariancePrefix Scaffold Summary

SHA256-anchored pure-Swift cache-invariance scaffold (KVCacheHolder + InvariancePrefix value type), unit-tested without booting MLX — Plan 03-02 will wire it into `PredictorViewModel.predict()`.

**Duration:** 9 min · **Start:** 2026-05-25T14:21Z · **End:** 2026-05-25T14:30Z · **Tasks:** 2 · **Files:** 2 created.

## Final Fingerprint Algorithm

| Property | Value |
|---|---|
| Hash function | `CryptoKit.SHA256` |
| Output format | lower-case hex, 64 chars |
| Join separator | Unicode US (Unit Separator, 0x1F) — non-printable, never present in slot bodies |
| Slot order (FROZEN) | `system` → `customInstructions` → `contextPrefix` → `fieldContext` → `afterCursor` → `previousUserInputs` |
| `beforeCursor` | structurally absent from `InvariancePrefix` (extension axis per D-KV-03) |
| Determinism | byte-faithful — empty slot ≠ whitespace slot (caller owns normalisation) |

## Public Surface (verbatim — Plan 03-02 will quote)

```swift
public struct InvariancePrefix: Sendable, Equatable {
    public let system: String
    public let customInstructions: String
    public let contextPrefix: String
    public let fieldContext: String
    public let afterCursor: String
    public let previousUserInputs: String

    public init(
        system: String,
        customInstructions: String,
        contextPrefix: String,
        fieldContext: String,
        afterCursor: String,
        previousUserInputs: String
    )

    public var fingerprint: String { get }

    public static func canonicalizePreviousUserInputs(
        _ raw: String,
        delimiter: String = "\n\n"
    ) -> String
}

@MainActor
public final class KVCacheHolder {
    public private(set) var caches: [Any]?
    public private(set) var fingerprint: String?
    public private(set) var beforeCursorTokens: Int

    public init()

    public enum InvalidationReason: Sendable {
        case cold
        case fingerprintChanged
        case beforeCursorDiverged
        case explicit
    }

    public func invalidate(reason: InvalidationReason)
    public func install(caches: [Any], fingerprint: String, beforeCursorTokens: Int)
    public func updateBeforeCursorTokens(_ n: Int)
}
```

## Test Count Delta

- Baseline: 109 tests
- New (`KVCacheHolderTests`): 17 tests (`@Test` annotations)
- Full suite post-plan: **126 tests passing**, 0 failed
- Audit: 6/6 ✓

Tests cover: determinism, hex-alphabet+length, six per-slot mutations, separator ambiguity-freeness, empty-vs-whitespace byte-faithfulness, canonicalisation order-invariance, canonicalisation whitespace collapse, canonicalisation empty round-trip, holder cold start, install→invalidate round-trip, token counter clamping, and the explicit `.explicit` invalidation reason path.

## No Behavior Change Yet

Verification: `grep -rn "KVCacheHolder\|InvariancePrefix" Sources/ --include="*.swift" | grep -v "KVCacheHolder.swift"` returns empty — no call site imports the new types. Plan 03-02 will:

1. Add `MLXLMCommon` import to a thin bridge layer.
2. Cast `holder.caches as? [KVCache]` at the predict call site.
3. Emit `kv_cache_extend` / `kv_cache_trim` / `kv_cache_invalidate` count-only events via `Log.info`.
4. Wire `InvariancePrefix.canonicalizePreviousUserInputs(...)` through the `SimilarHistoryRetrieval` boundary so few-shot order jitter does not flip the fingerprint.

## Deviations from Plan

### [Rule 4 → user-pre-approved] Storage type swapped from `[KVCache]?` to `[Any]?`

- **Found during:** Pre-execution (user scope override).
- **Issue:** PLAN.md prescribes `import MLXLMCommon` and `public private(set) var caches: [KVCache]?`. User scope in this execution explicitly directs "Pure Swift only — no `MLXLMCommon` imports in 03-01. Store `[KVCache]` opaquely as `Any?` (or via typealias bridged later by 03-02) so the holder is testable without booting a model."
- **Fix:** Used `[Any]?` for `caches` and `[Any]` for the `install(...)` parameter. Doc-comment on `caches` and on the class header explicitly calls out that 03-02 bridges to `[KVCache]` via downcast. The frontmatter `must_haves.artifacts[0].provides` field tolerated the swap because the holder semantics (state machine, install/invalidate/updateBeforeCursorTokens, fingerprint storage, reason enum) are unchanged — only the element type became opaque.
- **Files modified:** `Souffleuse/Sources/Souffleuse/KVCacheHolder.swift`.
- **Verification:** `swift build` 0; full suite green at 126; audit 6/6; `grep "import MLXLMCommon"` on the new file returns empty (confirming no MLX dep added in this plan).
- **Commit:** `8a4f75a`.
- **Impact:** Plan 03-02 must add the downcast (one line at the call site). The cost is one cast and a documented contract; the win is that 03-01 is now a pure-Swift, MLX-independent scaffold that boots in <1 ms in tests. The plan's `<verification>` line `grep -q "import MLXLMCommon"` is not satisfied — that's the trade-off the user directed.

### [Rule 2 - Missing critical] Added empty-vs-whitespace + empty-canonicalisation + install/invalidate tests

- **Found during:** Task 2 test design review.
- **Issue:** Plan's `<behavior>` block specifies "Empty-string slot is NOT the same as a slot containing only whitespace: fingerprints differ" but no test case enforced it. Likewise empty-input round-trip on `canonicalizePreviousUserInputs` and a holder `install(...)` round-trip with non-zero state were behaviourally required but absent from the action template.
- **Fix:** Added `fingerprintEmptyVsWhitespace`, `canonicalizePreviousUserInputs_emptyIsEmpty`, and `holderInstallThenInvalidate` (3 extra tests, bringing the suite to 17 — comfortably above the plan's "≥ 14" gate).
- **Files modified:** `Souffleuse/Tests/SouffleuseTests/KVCacheHolderTests.swift`.
- **Verification:** All 17 pass in `swift test --filter "KVCacheHolder"`; full suite 126/126.
- **Commit:** `6431f44`.

**Total deviations:** 2 (1 user-pre-approved Rule 4, 1 auto-added Rule 2). **Impact:** zero negative — both extend the safety net the plan intended; the storage-type swap is a documented hand-off contract to Plan 03-02.

## Authentication Gates

None — no network or auth involved.

## Verification Results

| Check | Result |
|---|---|
| `swift build` exits 0 | ✓ (9.63s) |
| `swift test --filter "KVCacheHolder"` exits 0 | ✓ (17/17 in 0.002s) |
| `swift test` (full suite) | ✓ 126 tests passing, 0 failed |
| `bash audit.sh` | ✓ 6/6 green |
| `grep -c "@Test"` on test file ≥ 14 | ✓ 17 |
| `struct InvariancePrefix` + `final class KVCacheHolder` present | ✓ |
| No stored `beforeCursor: String` field in `InvariancePrefix` | ✓ (D-KV-03 compile-time guarantee) |
| US (0x1F) separator literal present | ✓ |
| No call sites wired (grep empty outside `KVCacheHolder.swift`) | ✓ |

## Commits

- `8a4f75a` — `feat(03-01): add KVCacheHolder + InvariancePrefix scaffold`
- `6431f44` — `test(03-01): KVCacheHolder + InvariancePrefix deterministic-fingerprint suite`

## Next Step

Ready for **Plan 03-02** (wave 2) — wire `KVCacheHolder` into `PredictorViewModel.predict()`:
- Add `MLXLMCommon` import to the bridge layer.
- Cast `holder.caches as? [KVCache]` at the predict call site.
- Build the `InvariancePrefix` from current slot values, hash, compare against `holder.fingerprint`; invalidate on mismatch.
- Emit `kv_cache_extend` / `kv_cache_trim` / `kv_cache_invalidate` count-only events.
- Route the few-shot block through `InvariancePrefix.canonicalizePreviousUserInputs(...)` BEFORE constructing the prefix.

## Self-Check: PASSED

- `Souffleuse/Sources/Souffleuse/KVCacheHolder.swift` exists ✓
- `Souffleuse/Tests/SouffleuseTests/KVCacheHolderTests.swift` exists ✓
- Both commits `8a4f75a` and `6431f44` present in `git log` ✓
- All plan-level `<success_criteria>` re-verified: build 0, tests 126/126, audit 6/6, `InvariancePrefix` + `KVCacheHolder` defined, ≥ 12 tests (17 actual), holder not wired into `PredictorViewModel` (grep confirms) ✓
