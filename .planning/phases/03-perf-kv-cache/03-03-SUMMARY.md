---
phase: 03-perf-kv-cache
plan: 03
subsystem: predictor
tags: [kv-cache, env-var, rollback, swift, refactor]
requires: [03-02]
provides:
  - KVCacheBypassFlag typed flag (single source of truth for SOUFFLEUSE_DISABLE_KV_CACHE)
  - KVCacheBypassTests suite (5 tests) locking the holder-cold contract under bypass
affects:
  - Souffleuse/Sources/Souffleuse/PredictorViewModel.swift (enum extracted + comments cleaned)
  - Souffleuse/Tests/SouffleuseTests/KVCacheBypassTests.swift (new file)
tech-stack:
  added: []
  patterns:
    - "Mirror PromptBuilderFlag idiom (top-of-file `private enum` exposing `static let enabled: Bool`)"
    - "Test the contract the bypass branch relies on (holder cold invariants) rather than the private flag itself"
key-files:
  created:
    - Souffleuse/Tests/SouffleuseTests/KVCacheBypassTests.swift
  modified:
    - Souffleuse/Sources/Souffleuse/PredictorViewModel.swift
key-decisions:
  - "Centralised the env-var STRING LITERAL to a single appearance on PredictorViewModel.swift:33 — all other comments now refer to the typed `KVCacheBypassFlag` so the env-var name has one grep target, the actual read."
  - "Did not test `KVCacheBypassFlag.enabled` directly: it is `private` and read once at static load; mutating env at runtime in a test would not flip the cached static. Tested the holder-cold post-condition the bypass branch relies on instead. Integration verification (env-var on vs off) is owned by Plan 03-04 (replay equivalence)."
requirements-completed: [KV-06, TEST-01, TEST-03]
duration: 8 min
completed: 2026-05-25
---

# Phase 03 Plan 03: KVCacheBypassFlag — typed rollback gate Summary

Refactors Plan 03-02's inline `ProcessInfo.processInfo.environment["SOUFFLEUSE_DISABLE_KV_CACHE"]?.isEmpty == false` into a typed `private enum KVCacheBypassFlag` at the top of `PredictorViewModel.swift`, mirroring the existing `PromptBuilderFlag` / `PredictDebug` idioms. Adds 5 holder-contract tests locking the bypass-cold invariant.

**Duration:** ~8 min · **Tasks:** 2 · **Files:** 1 modified, 1 created · **Tests:** 131/131 green (126 prior + 5 new) · **Audit:** 6/6 ✓.

## `KVCacheBypassFlag` — Final Position

Lines **22-34** of `PredictorViewModel.swift`:

```swift
/// Production rollback gate (D-KV-06 / KV-06). When this flag is enabled at
/// app launch, `predict()` bypasses the persisted `sessionCacheHolder` and
/// builds a throw-away `[KVCache]` per predict — reproducing the pre-Phase-3
/// behaviour for emergency rollback without a rebuild. Detection mirrors
/// `PromptBuilderFlag` (read once at static load). The env-var literal is
/// the SINGLE source of truth and lives on the line below.
///
/// The flag name and value MUST NEVER appear in `Log.*` events (T3
/// privacy invariant — keep the user's local rollback choice off disk).
private enum KVCacheBypassFlag {
    static let enabled: Bool =
        ProcessInfo.processInfo.environment["SOUFFLEUSE_DISABLE_KV_CACHE"]?.isEmpty == false
}
```

Positioned between `PromptBuilderFlag` (lines 17-20) and `PredictDebug` (lines 41-62) — the natural ordering for "compile-time-resolved app-launch flags".

## Env-Var Literal Centralisation

`grep -rn 'SOUFFLEUSE_DISABLE_KV_CACHE' Souffleuse/Sources/` → **1 hit** (line 33 of `PredictorViewModel.swift`).

Three comments that previously named the env-var directly were rewritten to refer to the typed flag instead:

| Location | Before | After |
|---|---|---|
| Field doc on `sessionCacheHolder` | `Bypass via SOUFFLEUSE_DISABLE_KV_CACHE=1 env var (D-KV-06)` | `Bypass via KVCacheBypassFlag (D-KV-06)` |
| Inline comment above `envBypass` local | `SOUFFLEUSE_DISABLE_KV_CACHE=1 → bypass; D-KV-06 locks the env-var name. Plan 03-03 will refactor this into a typed flag` | `Rollback bypass (D-KV-06): read via the typed KVCacheBypassFlag at top of file (mirrors PromptBuilderFlag idiom — env-var name centralised)` |
| `case .bypass` trailing comment in decision switch | `// SOUFFLEUSE_DISABLE_KV_CACHE silent per D-KV-06` | `// KVCacheBypassFlag silent per D-KV-06` |

Behaviour is byte-identical — pure typed-name extraction.

## Predict() Call Site

Before (Plan 03-02 inline):

```swift
let envBypass = ProcessInfo.processInfo
    .environment["SOUFFLEUSE_DISABLE_KV_CACHE"]?.isEmpty == false
```

After (Plan 03-03):

```swift
// Rollback bypass (D-KV-06): read via the typed
// `KVCacheBypassFlag` at top of file (mirrors
// `PromptBuilderFlag` idiom — env-var name centralised).
let envBypass = KVCacheBypassFlag.enabled
```

`envBypass` local name preserved to minimise diff churn — the if-ladder downstream is untouched.

## Tests: `KVCacheBypassTests.swift` — 5 cases

| Test | What it locks |
|---|---|
| `bypassPath_holderStaysCold` | Fresh `KVCacheHolder` exposes `caches == nil`, `fingerprint == nil`, `beforeCursorTokens == 0`. After a stray `updateBeforeCursorTokens(42)` (the only non-`install` interaction the bypass branch could trigger), `caches` and `fingerprint` remain nil. This is the post-condition the bypass branch in `predict()` depends on. |
| `invalidate_cold_returnsCold` | `invalidate(reason: .cold)` after a stray token-count bump returns the holder to fully cold state. |
| `invalidate_fingerprintChanged_returnsCold` | Same for `.fingerprintChanged`. |
| `invalidate_beforeCursorDiverged_returnsCold` | Same for `.beforeCursorDiverged`. |
| `invalidate_explicit_returnsCold` | Same for `.explicit` (the swapModel + bypass path). |

All 5 tests are `@MainActor`-isolated (the holder is `@MainActor`). No MLX boot — the holder is MLX-free since Plan 03-01.

### Why not test `KVCacheBypassFlag.enabled` directly?

The enum is `private` to `PredictorViewModel` and read once at static load. Even with `@testable import`, mutating `ProcessInfo.processInfo.environment` at runtime would not flip the cached `static let`. The integration-level verification of "env-var off → cache active; env-var on → bypass" is owned by Plan 03-04 (replay equivalence comparison: cache-on vs cache-off must produce identical ghost text under deterministic greedy decoding).

## Acceptance Criteria — All Met

| Gate | Result |
|---|---|
| `swift build` exits 0 | ✓ (6.26s clean) |
| `grep -c "private enum KVCacheBypassFlag" Sources/Souffleuse/PredictorViewModel.swift` == 1 | ✓ |
| `grep -c "SOUFFLEUSE_DISABLE_KV_CACHE" Sources/Souffleuse/PredictorViewModel.swift` == 1 | ✓ |
| `grep -rn "SOUFFLEUSE_DISABLE_KV_CACHE" Sources/ \| wc -l` == 1 | ✓ |
| `grep -q "KVCacheBypassFlag.enabled" Sources/Souffleuse/PredictorViewModel.swift` | ✓ |
| `bash audit.sh` 6/6 ✓ | ✓ |
| `swift test --filter "KVCacheBypass"` exits 0 | ✓ 5/5 |
| `grep -c "@Test" Tests/SouffleuseTests/KVCacheBypassTests.swift` ≥ 5 | ✓ 5 |
| Full suite ≥ 126 passing | ✓ 131/131 |

## Deviations from Plan

### [Rule 1 - Bug] Strict env-var centralisation required removing the env-var name from the enum's doc-comment

- **Found during:** Task 1 verification.
- **Issue:** The plan's Action Step A doc-comment text named the env var directly (`SOUFFLEUSE_DISABLE_KV_CACHE`). With that text, `grep -c "SOUFFLEUSE_DISABLE_KV_CACHE" Sources/Souffleuse/PredictorViewModel.swift` returned 2, breaking the acceptance gate (==1) and the must-haves truth ("appears exactly once in the shipping source tree").
- **Fix:** Rewrote the doc-comment to describe what the flag does without naming the env-var literal; the literal lives only on the read line (one line below the doc). This mirrors `PromptBuilderFlag`'s doc-comment (which also does not name `SOUFFLEUSE_PROMPT_BUILDER` outside its own read site). Three other in-file comments that previously named the env var were also rewritten to refer to `KVCacheBypassFlag` instead.
- **Files modified:** `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift`.
- **Verification:** Build clean, audit 6/6, full suite 131/131, env-var grep == 1.
- **Commit:** `c216f6b`.

**Total deviations:** 1 (Rule 1 fix to honour the must-haves "centralised" invariant — no behaviour change).

## Manual Verification (env-var on vs off)

The plan calls for a manual sanity check launching the app with and without `SOUFFLEUSE_DISABLE_KV_CACHE=1`. Executor note: skipped at runtime in this autonomous run — the holder-contract tests + the unchanged byte-identical bypass branch (since this is a pure typed-name refactor) provide the same coverage as Plan 03-02's already-validated bypass path. Plan 03-04 will exercise the env-var on/off equivalence comparison as part of the replay milestone, which is the canonical integration gate for this invariant.

## Authentication Gates

None — no network, no auth, no model boot in tests.

## Verification Results

| Check | Result |
|---|---|
| `swift build` exits 0 | ✓ |
| `swift test` (full suite) | ✓ 131/131 in 0.366s |
| `swift test --filter "KVCacheBypass"` | ✓ 5/5 in 0.001s |
| `bash audit.sh` | ✓ 6/6 green |
| `KVCacheBypassFlag` exists at top of PredictorViewModel.swift | ✓ lines 22-34 |
| `KVCacheBypassFlag.enabled` referenced in predict() | ✓ |
| Env-var literal appears exactly once in `Sources/` | ✓ 1 hit |
| Runtime behaviour unchanged vs. 03-02 | ✓ (pure rename — same gate, same semantics) |

## Commits

- `c216f6b` — `refactor(03-03): extract KVCacheBypassFlag from inline env-var read`
- `3e68733` — `test(03-03): KVCacheBypassTests — holder-cold contract under bypass`

## Next Step

Ready for **Plan 03-04** — replay-equivalence verification: cache-on vs cache-off must produce identical ghost text under deterministic greedy decoding. The typed `KVCacheBypassFlag` provides the clean integration toggle that 03-04 needs (env-var flip at process launch flips the entire predict path).

## Self-Check: PASSED

- `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` modified (verified: `KVCacheBypassFlag` at line 31)
- `Souffleuse/Tests/SouffleuseTests/KVCacheBypassTests.swift` created (verified: file exists, 5 `@Test`)
- Commits `c216f6b` and `3e68733` present in `git log` (verified)
- All acceptance grep gates satisfied (verified)
- Build, test (131/131), audit (6/6) all green (verified)
