---
phase: 04-cascade-quality-architecture
plan: 10
subsystem: replay-harness
tags: [phase-04, replay-harness, confusion-matrix, D-12]
requires:
  - phase: 04
    plans: [02, 08]
provides:
  - "SouffleuseCoherence schema v2 (expectedCategory + expectedGhostPrefix Optional)"
  - "ExpectedCategory enum + classifyReplayGhost helper"
  - "renderReplayResults confusion matrix + D-11 release gate simulation"
  - "--dry-run flag (worktree/CI MLX-less validation)"
  - "7 scenarios annotated v2 (6 expectedGhostPrefix + 1 useless null-prefix)"
affects:
  - "Souffleuse/Sources/SouffleuseCoherence/main.swift"
  - "Souffleuse/Sources/SouffleuseCoherence/replay-scenarios.json (canonical path: .planning/phases/01-foundation-hypothesis-validation/replay-scenarios.json)"
tech-stack:
  added: []
  patterns:
    - "Optional fields for backward-compat versioned config (Codable synthesised)"
    - "Dry-run env flag for GPU-less harness validation"
key-files:
  created:
    - ".planning/phases/04-cascade-quality-architecture/04-08-REPLAY-RESULTS.md"
    - ".planning/phases/04-cascade-quality-architecture/04-10-SUMMARY.md"
  modified:
    - "Souffleuse/Sources/SouffleuseCoherence/main.swift"
    - ".planning/phases/01-foundation-hypothesis-validation/replay-scenarios.json"
decisions:
  - "D-12 confusion matrix lands in renderReplayResults BEFORE per-scenario detail."
  - "classifyReplayGhost stays naive: correct/acceptable/useless only — bad+parasite require human signal."
  - "v1 backward compat preserved via Optional fields (no v2 file required to keep existing harness consumers working)."
  - "Scenarios JSON canonical path is .planning/phases/01-foundation-hypothesis-validation/replay-scenarios.json (Rule 3 deviation — plan-stated path Souffleuse/Sources/SouffleuseCoherence/replay-scenarios.json does not exist; preserved existing location, see 04-02-BASELINE-REPLAY.md)."
  - "Added --dry-run flag (Rule 3) to validate markdown structure in worktree environments lacking the MLX metallib (only the .app bundle from make-app.sh ships it)."
metrics:
  duration_minutes: ~20
  completed_date: "2026-05-26"
  tasks_completed: 4
  files_created: 2
  files_modified: 2
  tests_baseline: 246
  tests_after: 246
---

# Phase 4 Plan 10: Coherence harness v2 with confusion matrix (D-12) Summary

`SouffleuseCoherence --replay` now emits a D-12 confusion matrix + D-11 release gate simulation, schema bumped 1→2 with Optional fields preserving v1 compatibility.

## Objective (recap)

Étendre le replay harness pour produire une **confusion matrix** (D-12) dans `REPLAY-RESULTS.md`. Schema passe v1 → v2 avec deux champs optionnels (`expectedCategory`, `expectedGhostPrefix`). v1 décode toujours sans erreur.

## Tasks executed

| # | Task | Commit | Files |
|---|------|--------|-------|
| 1 | Scenario v2 + `ExpectedCategory` + `classifyReplayGhost` | `d3e114d` | `main.swift` |
| 2 | `renderReplayResults` confusion matrix + D-11 gate sim | `096cd33` | `main.swift` |
| 3 | Annotate 7 scenarios (6 prefix + 1 useless) + bump version 1→2 | `2ab0363` | `replay-scenarios.json` |
| 4 | `--dry-run` + capture `04-08-REPLAY-RESULTS.md` baseline | `c7abcff` | `main.swift` + new RESULTS.md |

## Scenarios annotated (7 total)

| ID | expectedCategory | expectedGhostPrefix |
|----|------------------|---------------------|
| `slack-reply-mid` | acceptable | `regarde` |
| `mail-reply-body` | acceptable | `votre` |
| `intercom-cs-reply` | acceptable | `vais` |
| `discord-reply` | acceptable | `le` |
| `mid-edit-rewrite` | acceptable | `les` |
| `13-mid-field-mail-subject` | acceptable | `déjeuner` |
| `14-search-field-empty-with-help` | useless | `null` (cannot auto-classify; `.skip`) |

## Confusion matrix sample (dry-run, MLX-less)

```
| expected \ actual | correct | acceptable | useless | bad | total |
|--------------------|---------|------------|---------|-----|-------|
| expected: correct  | 0 | 0 | 0 | 0 | 0 |
| expected: acceptable | 0 | 0 | 6 | 0 | 6 |
| expected: useless  | 0 | 0 | 0 | 0 | 0 |
| expected: bad      | 0 | 0 | 0 | 0 | 0 |
| total              | 0 | 0 | 6 | 0 | 15 |
```

**Note**: in dry-run mode, all ghosts are empty strings → every annotated scenario lands in `useless`. This validates the matrix code path; the production run on the packaged `.app` will populate `correct`/`acceptable` correctly.

## D-11 release gate (dry-run simulation)

- ✗ correct/total ≥ 30% → 0/15 = 0.0% (dry-run: no MLX inference)
- ✗ (useless+bad)/total ≤ 35% → 6/15 = 40.0% (dry-run: all empty)
- parasite/total ≤ 5% — untestable in single-pass replay (live production only)

Production-run verdict on packaged `.app` is left to a follow-up (worktree environment cannot load metallib).

## Deviations from plan

### Rule 3 — Auto-fix blocking issue

**1. Scenarios JSON path** — plan specifies `Souffleuse/Sources/SouffleuseCoherence/replay-scenarios.json`, but the canonical path actually used by the harness and prior phases is `.planning/phases/01-foundation-hypothesis-validation/replay-scenarios.json` (cf. `04-02-BASELINE-REPLAY.md` line 30). Annotated the canonical file; the harness loads from the path passed via `--replay <path>`.

**2. MLX metallib absent in worktree** — `swift run … --replay` fails with `Failed to load the default metallib` in worktree environments because the metallib is bundled into the `.app` only by `make-app.sh`. Added a `--dry-run` flag that skips MLX load + inference and emits empty ghosts. Validates the markdown structure of the confusion matrix end-to-end. Production-quality numbers must be re-captured on the packaged app.

### Rule 2 — Auto-add missing critical functionality

None.

## Verification

- `swift build --package-path Souffleuse --product SouffleuseCoherence` — PASS
- `bash Souffleuse/audit.sh` — 6/6 PASS (SouffleuseCoherence not in shipping targets)
- `swift test --package-path Souffleuse` — 246 / 246 PASS (baseline preserved)
- `swift run … --replay … --out … --dry-run` — emits `04-08-REPLAY-RESULTS.md` with confusion matrix + D-11 gate sections

## Known limitations

- Dry-run verdict is structural only; live MLX run pending packaged-app execution.
- `bad` + `parasite` categories require human-in-the-loop signal — not produced by `classifyReplayGhost`.
- 8 of 15 scenarios remain unannotated (v2 Optional fields tolerate absence; matrix simply excludes them from row totals).

## Self-Check: PASSED

- [x] `Souffleuse/Sources/SouffleuseCoherence/main.swift` — modified (all 4 tasks)
- [x] `.planning/phases/01-foundation-hypothesis-validation/replay-scenarios.json` — version 2, 7 scenarios annotated
- [x] `.planning/phases/04-cascade-quality-architecture/04-08-REPLAY-RESULTS.md` — created, contains "Confusion Matrix" and "Release gate D-11"
- [x] Commits `d3e114d`, `096cd33`, `2ab0363`, `c7abcff` — all present in `git log`
- [x] Audit PASS, 246 tests green
