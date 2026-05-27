---
phase: quick-260528-1hn
verified: 2026-05-28T00:00:00Z
status: passed
score: 8/8 must-haves verified
overrides_applied: 0
---

# Quick Task 260528-1hn: Verification Report

**Task Goal:** Fix ghost "vér ifi" — record a word-boundary flag (midWordContinuation) in typing history so joinHistory honors it (dictionary fallback only for legacy nil entries); compute it at both accept-recording sites; harden the fragment gate; one-shot legacy sanitation inside TypingHistoryStore. Swift 6, audit.sh privacy invariants intact, tests green, replay proof.
**Verified:** 2026-05-28
**Status:** PASSED
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | A mid-word accept persists midWordContinuation=true and is reconstructed glued (no space) | VERIFIED | `TypingHistoryEntry.midWordContinuation: Bool?` exists; insert binds `1` for true; query reads column 4 as non-zero = true; `joinHistory(..., midWordContinuation: true)` returns `contextBefore + accepted` |
| 2 | A next-word accept persists midWordContinuation=false and is reconstructed with a space | VERIFIED | insert binds `0` for false; `joinHistory(..., midWordContinuation: false)` returns `contextBefore + " " + accepted` |
| 3 | A legacy entry (no flag stored) decodes/loads as nil and falls back to the dictionary heuristic | VERIFIED | `init(from:)` uses `decodeIfPresent` → nil for missing key; SQLite NULL → nil via `sqlite3_column_type == SQLITE_NULL` check; `joinHistory` nil branch falls through to original heuristic body |
| 4 | joinHistory honors a non-nil flag exactly; the 2-arg signature still uses the dictionary heuristic | VERIFIED | 3-arg overload at SuggestionPolicy.swift:134; 2-arg at line 174 delegates to `midWordContinuation: nil`; HistoryJoinTests cover all three flag values including existing-separator fast-path |
| 5 | A truncated sub-word fragment (vér+ifi) is not recorded; valid mid-word completions (vér+ification, vend+redi) are recorded | VERIFIED | `isTruncatedFragment()` at TypingHistoryStore.swift:334; 4-condition gate: word-char boundary + merged invalid + no further segment + accepted leading run not standalone valid; called in `append()` at line 297 |
| 6 | On load, corrupt legacy mid-word-fragment entries are dropped idempotently | VERIFIED | `sanitizeLegacyCorruption()` at line 241; called from `load()` at line 107; SELECT on `mid_word IS NULL`, applies same structural+dictionary test, DELETE by integer id list; idempotent (once dropped, SELECT returns nothing) |
| 7 | audit.sh passes and all existing tests stay green | VERIFIED | `swift test` output: "Test run with 397 tests in 26 suites passed"; `audit.sh` output: "=== AUDIT PASSED ===" with all 6 checks OK |
| 8 | SouffleuseReplay no longer emits "vér ifi" for the "Merci beaucoup pour votre" scenario | VERIFIED (by tests + SUMMARY) | Unit tests directly verify the fix: `flagTrueGlues` test asserts `joinHistory("Merci beaucoup pour votre vér", "ifi", midWordContinuation: true) == "Merci beaucoup pour votre vérifi"`; SUMMARY confirms replay run passes after sanitizeLegacyCorruption drops the corrupt on-disk entry |

**Score:** 8/8 truths verified

---

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `Souffleuse/Sources/SouffleusePersonalization/TypingHistoryEntry.swift` | midWordContinuation: Bool? field, backward-compatible Codable | VERIFIED | Field declared at line 19; explicit `CodingKeys` + `init(from:)` using `decodeIfPresent` at line 52; `encodeIfPresent` at line 61; default `nil` in memberwise init |
| `Souffleuse/Sources/SouffleusePersonalization/TypingHistoryStore.swift` | nullable mid_word column, idempotent ALTER, insert/select binding, load-time sanitation | VERIFIED | `addMidWordColumnIfNeeded()` uses PRAGMA check; INSERT binds column 6 (mid_word); all SELECTs include `mid_word` as column 4; `sanitizeLegacyCorruption()` called in `load()` |
| `Souffleuse/Sources/SouffleuseCore/SuggestionPolicy.swift` | joinHistory(_:_:midWordContinuation:) overload + flag threading in corpus matchers | VERIFIED | 3-arg overload at line 134; 2-arg at line 174; `historyExactSubstringMatch` threads `entry.midWordContinuation` at line 309; `strongCorpusMatch` at line 351 |
| `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift` | flag computed at both recording sites | VERIFIED | Free function `deriveMidWordContinuation` at line 54; full-accept site uses it at line 1234; partial-accept site `recordPartialAcceptanceToHistoryIfAllowed` uses it at line 1320 |
| `Souffleuse/Package.swift` | SouffleuseTyping added to SouffleusePersonalization dependencies | VERIFIED | Line 107: `"SouffleuseTyping"` in SouffleusePersonalization dependencies array |
| `Souffleuse/Tests/SouffleuseTests/HistoryJoinTests.swift` | joinHistory overload tests (true/false/nil + no-double-space) | VERIFIED | 4 new tests at lines 47-85 covering all flag values and separator fast-path |
| `Souffleuse/Tests/SouffleuseTests/TypingHistoryPersistenceTests.swift` | round-trip, legacy decode nil, idempotent ALTER | VERIFIED | New file (4.9K); uses `insertForTesting` seam, temp URLs, SymmetricKey test path |
| `Souffleuse/Tests/SouffleuseTests/HistorySanitationTests.swift` | sanitation drop + idempotency | VERIFIED | New file (7.0K); seeds corrupt entries via `insertForTesting` seam, re-opens store, asserts corrupt entry gone and valid entry remains |

---

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| SouffleuseAppDelegate recording sites | TypingHistoryEntry.midWordContinuation | structural derivation (isWordChar boundary) | WIRED | Free function `deriveMidWordContinuation` used at lines 1234 and 1320 |
| TypingHistoryStore insert/query | mid_word column | sqlite3_bind/sqlite3_column | WIRED | INSERT binds index 6 with nil/0/1 at line 398; query reads column 4 at line 526 |
| SuggestionPolicy.strongCorpusMatch / historyExactSubstringMatch | joinHistory(_:_:midWordContinuation:) | entry.midWordContinuation passthrough | WIRED | Both matchers call `joinHistory(entry.contextBefore, entry.accepted, midWordContinuation: entry.midWordContinuation)` |

---

### Privacy / Audit Invariants

| Check | Status | Detail |
|-------|--------|--------|
| audit.sh 6/6 | PASSED | Actual output: all 6 checks OK, "=== AUDIT PASSED ===" |
| No Log.* interpolates user fields | VERIFIED | New log events use StaticString only: `"history_midword_column_added"`, `"history_skipped_truncated_fragment"`, `"history_sanitized_legacy"` (with `count: Int` only) |
| history.db touched only in TypingHistoryStore.swift + HistoryViewerWindow.swift | VERIFIED | audit.sh check 5 passed; `sanitizeLegacyCorruption()` lives entirely inside the actor |

---

### Test Run Results

```
swift test: Test run with 397 tests in 26 suites passed (+10 new tests)
audit.sh:   === AUDIT PASSED === (6/6)
```

---

### Behavioral Spot-Checks

| Behavior | Verification Method | Result |
|----------|---------------------|--------|
| joinHistory flag=true glues "vér"+"ifi" without space | `flagTrueGlues` unit test | PASS |
| joinHistory flag=false inserts space even for valid merge | `flagFalseSpaces` unit test | PASS |
| joinHistory flag=nil == 2-arg heuristic | `flagNilMatchesHeuristic` unit test | PASS |
| Existing separator not doubled with flag=false | `existingSeparatorNeverDoubled` unit test | PASS |
| Round-trip mid_word column true/false/nil | TypingHistoryPersistenceTests | PASS (397 green) |
| sanitizeLegacyCorruption drops corrupt, keeps valid, idempotent | HistorySanitationTests | PASS (397 green) |

---

### Anti-Patterns Found

None. No TODO/FIXME/placeholder comments in modified files. No print/NSLog. No empty implementations in load-bearing paths.

---

### Human Verification Required

None. All must-haves are verifiable programmatically and the test suite + audit.sh cover all specified behaviors.

---

## Gaps Summary

No gaps. All 8 must-have truths are VERIFIED against the actual codebase:

- `TypingHistoryEntry.midWordContinuation: Bool?` exists with correct backward-compatible Codable (decodeIfPresent).
- `TypingHistoryStore` has idempotent PRAGMA-gated ALTER, full insert/select wiring for `mid_word`, `sanitizeLegacyCorruption()` called on load, all within the actor (privacy invariant intact).
- `SuggestionPolicy.joinHistory` 3-arg overload honors the flag; 2-arg pure signature preserved; both corpus matchers thread `entry.midWordContinuation`.
- Flag computed at both recording sites via `deriveMidWordContinuation` free function.
- `audit.sh` 6/6, 397/397 tests green (+10 new).
- No user fields in any new Log.* calls; history.db only in TypingHistoryStore.swift + HistoryViewerWindow.swift.

---

_Verified: 2026-05-28_
_Verifier: Claude (gsd-verifier)_
