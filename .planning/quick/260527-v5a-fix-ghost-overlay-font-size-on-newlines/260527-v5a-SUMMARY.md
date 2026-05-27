---
quick_id: 260527-v5a
status: complete
date: 2026-05-27
---

# Quick Task 260527-v5a — Summary

**Task:** Fix two ghost-overlay bugs in Souffleuse:
1. Ghost rendered far too large on empty lines / after newlines.
2. Ghost still appeared when the caret was placed mid-text to edit existing text.

**Status:** Complete — 2/2 tasks, all 380 tests green, `audit.sh` 6/6 passing.

## Commits

- `1b594bd` — test(quick-260527-v5a-01): add failing tests for estimatedFont clamp + mid-text suppression (RED)
- `ff8c6bf` — feat(quick-260527-v5a-01): lower estimatedFont clamp to 20pt + add shouldSuppressForCaretContext helper (GREEN)
- `9d85b12` — feat(quick-260527-v5a-01): wire per-bundle reliable-font cache + mid-text guard in tick()

## What changed

### Bug 1 — Oversized ghost on newlines
- `OverlayWindow.estimatedFont(forCaretRectHeight:)` upper clamp lowered 64pt → 20pt. A degenerate line-box caret rect on an empty line can no longer produce an oversized ghost.
- `SouffleuseAppDelegate.lastReliableFontByBundle` (`[String: NSFont]`, `@MainActor`): populated **only** from trustworthy sources — the AX `caretFont` attribute and OCR calibration. `hostFontForOverlay` falls back to this per-bundle cache when both live sources are nil (e.g. a fresh empty line in Notes), so the rect-height heuristic is bypassed entirely when a reliable font was previously seen for that app.

### Bug 2 — Ghost on mid-text caret
- `SouffleuseAppDelegate.shouldSuppressForCaretContext(text:caretIndex:)`: pure static helper using `Character.isWhitespace`. Returns true (suppress) only when the character immediately after the caret is non-whitespace — i.e. the caret sits inside/before a word. End-of-text, end-of-line, and caret-before-space cases are NOT suppressed.
- Guard wired into `tick()` immediately after prefix extraction: on suppress it mirrors the existing dismissal gate — `overlay.hide()`, `presence.hide()`, `interceptor.setActive(false)`, `return`.

## Verification
- `swift test`: 380/380 green.
- `Souffleuse/audit.sh`: 6/6 passing — no user text logged; font cache stores only `NSFont`, never content.
- Swift 6 strict concurrency holds — font cache is `@MainActor` state, no Sendable changes.

## Files touched
- `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift`
- `Souffleuse/Sources/SouffleuseOverlay/OverlayWindow.swift`
- `Souffleuse/Tests/SouffleuseTests/SouffleuseTests.swift`
