---
quick_id: 260528-1hn
status: complete
date: 2026-05-28
---

# Quick Task 260528-1hn — Summary

**Task:** Fix ghost "vér ifi" — record a word-boundary flag in typing history so `joinHistory` stops guessing with the dictionary, plus a one-shot legacy sanitation pass.

**Status:** Complete — 3/3 tasks, 397 tests green (+10), `audit.sh` 6/6, replay proof passing.

## Commits

- `21ff094` — feat: add `midWordContinuation` flag + nullable `mid_word` column + Layer-2 sanitation
- `2699e67` — feat: `joinHistory` flag overload + matcher threading + recording-site flag

## What changed

### Layer 1 — deterministic recording
- `TypingHistoryEntry.midWordContinuation: Bool?` (nil = legacy/unknown, true = glue, false = space). Backward-compatible `Codable` (`decodeIfPresent` → nil for legacy JSON / AES-blob migration).
- `TypingHistoryStore`: nullable `mid_word INTEGER` column via idempotent ALTER (tolerates "duplicate column"); insert/select map 0/1/NULL ↔ false/true/nil; legacy AES→SQLite migration preserved.
- `SuggestionPolicy.joinHistory(_:_:midWordContinuation:)` overload — honors the flag when non-nil (true → glue, false → space), falls back to the existing dictionary heuristic only for legacy nil entries. The pure 2-arg signature is preserved (delegates with nil) so existing tests pass. `strongCorpusMatch` / `historyExactSubstringMatch` thread `entry.midWordContinuation`.
- Flag computed at both recording sites in `SouffleuseAppDelegate` (full-accept + partial-accept) via a free `deriveMidWordContinuation` helper (structural: contextBefore ends word-char ∧ accepted starts word-char ∧ no leading whitespace). Made a free function (not `@MainActor static`) to be callable from the non-isolated CGEventTap context.
- Hardened fragment gate (`isTruncatedFragment`): a mid-word accept whose merged word is not a complete dictionary word AND whose accepted leading word is not itself a valid standalone word is rejected (not recorded). The 4th condition was added to avoid rejecting valid next-word accepts like "premiere"+"entrée".

### Layer 2 — legacy cleanup
- `sanitizeLegacyCorruption()` runs on load (after migration), inside `TypingHistoryStore` (privacy invariant intact). Drops legacy (flag nil) entries matching the corrupt mid-word fragment pattern (contextBefore ends word-char, accepted starts word-char, merged not a valid word). Idempotent. Logged with StaticString event + count only — no user text.

### Dependency
- Added `SouffleuseTyping` to `SouffleusePersonalization` (for `TypoDetector.isValidWord`) — no dependency cycle (`SouffleuseTyping` has no deps).

## Verification
- `swift test`: 397/397 green (+10: 3 persistence round-trip, 3 sanitation, 4 joinHistory overload).
- `Souffleuse/audit.sh`: 6/6.
- `SouffleuseReplay` on `userTail="Merci beaucoup pour votre"` → " vérification" (NOT "vér ifi"). On the live history.db, `sanitizeLegacyCorruption()` dropped the corrupt fragment on load; the clean "vérification" entry now produces the correct ghost.

## Files touched
- `Souffleuse/Package.swift`
- `Souffleuse/Sources/SouffleusePersonalization/TypingHistoryEntry.swift`
- `Souffleuse/Sources/SouffleusePersonalization/TypingHistoryStore.swift`
- `Souffleuse/Sources/SouffleuseCore/SuggestionPolicy.swift`
- `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift`
- `Souffleuse/Tests/SouffleuseTests/HistoryJoinTests.swift`
- `Souffleuse/Tests/SouffleuseTests/TypingHistoryPersistenceTests.swift` (new)
- `Souffleuse/Tests/SouffleuseTests/HistorySanitationTests.swift` (new)
