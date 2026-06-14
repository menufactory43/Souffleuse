---
phase: quick-260614-fib
plan: 01
subsystem: package/build
tags: [cleanup, mlx, spm, dead-targets]
dependency_graph:
  requires: []
  provides: [mlx-dep-removed, 8-dead-targets-deleted]
  affects: [Souffleuse/Package.swift, Souffleuse/Package.resolved, CLAUDE.md, Souffleuse/BENCHMARKS.md]
tech_stack:
  removed: [mlx-swift-examples SPM dependency]
  patterns: []
key_files:
  modified:
    - Souffleuse/Package.swift
    - CLAUDE.md
    - Souffleuse/BENCHMARKS.md
  deleted:
    - Souffleuse/Sources/SouffleuseBench/Bench.swift
    - Souffleuse/Sources/SouffleuseCoherence/main.swift
    - Souffleuse/Sources/SouffleuseEnrichmentBench/main.swift
    - Souffleuse/Sources/SouffleuseTTFTBench/main.swift
    - Souffleuse/Sources/SouffleuseCorpusEval/main.swift
    - Souffleuse/Sources/SouffleuseBeamEval/main.swift
    - Souffleuse/Sources/SouffleusePersonalizationEval/main.swift
    - Souffleuse/Sources/SouffleuseMaxWordsEval/main.swift
decisions:
  - "Package.resolved is gitignored — only Package.swift updated in commit; swift package resolve updated the resolved file locally."
metrics:
  duration: "~8 min"
  completed_date: "2026-06-14"
  tasks_completed: 3
  files_modified: 3
  files_deleted: 8
---

# Quick Task 260614-fib: Supprimer 8 cibles dev mortes + dépendance MLX — Summary

**One-liner:** Removed 8 dead/superseded dev-only SPM targets and the `mlx-swift-examples` dependency from Package.swift; 938 tests remain green.

## What Was Done

Three tasks executed atomically in a single commit (`6535438`):

**Task 1 — Safety checks + git rm 8 source dirs**

Pre-flight checks passed:
- `grep -rl 'import MLX' Sources/` returned exactly 4 files, all in the delete list: `SouffleuseBench`, `SouffleuseCoherence`, `SouffleuseEnrichmentBench`, `SouffleuseTTFTBench`.
- No kept target had any of the 8 deleted target names in its `dependencies:` array — only product lines and own `executableTarget` name blocks matched.

8 source directories deleted via `git rm`:
- `SouffleuseBench` — MLX consumer (A/B TTFT bench for the now-removed MLX container)
- `SouffleuseCoherence` — MLX consumer
- `SouffleuseEnrichmentBench` — MLX consumer
- `SouffleuseTTFTBench` — MLX consumer (A/B contention harness)
- `SouffleuseCorpusEval` — marked JETABLE, throwaway eval harness
- `SouffleuseBeamEval` — superseded by `SouffleuseCascadeVsBeamEval`
- `SouffleusePersonalizationEval` — synthetic, superseded by `SouffleuseRealPersoEval`
- `SouffleuseMaxWordsEval` — one-shot knob-sweep

**Task 2 — Package.swift surgery**

- Removed 4 `.executable` product lines: `SouffleuseBench`, `SouffleuseCoherence`, `SouffleuseEnrichmentBench`, `SouffleuseMaxWordsEval`
- Removed `mlx-swift-examples` dependency line (Sparkle kept intact)
- Removed 8 `.executableTarget(...)` blocks (including JETABLE comment above `SouffleuseCorpusEval` and A/B comment in `SouffleuseTTFTBench`)
- `swift package resolve` ran clean — `Package.resolved` no longer lists `mlx-swift-examples`

**Task 3 — Doc sync + build + test**

- `CLAUDE.md` Constraints section: replaced "MLX reste une dépendance SPM pour les probes dev" with "MLX supprimé du package le 14/06/2026"
- `CLAUDE.md` Technology Stack MLX entry: updated to describe suppression, not presence
- `CLAUDE.md` Probes & evals list: removed 8 deleted targets, added note about suppression date
- `Souffleuse/BENCHMARKS.md`: added "référence historique" heading suffix + note to Run 1, Run 2, Run 3, and Personnalisation Jalon 3.X sections (data preserved, engine note added)
- `swift build` succeeded in 21s — no errors, only pre-existing warnings
- `swift test` ran 938 tests across 83 suites — all green

## Deviations from Plan

None — plan executed exactly as written.

## Self-Check

**Created files:** None (only modifications and deletions).

**Commits exist:**
- `6535438` — chore(260614-fib): supprimer 8 cibles dev mortes + dépendance MLX

**Verification commands passed:**
- `grep -rl 'import MLX' Sources/` → empty (no MLX consumers remain)
- `grep -cE 'mlx-swift-examples|...' Package.swift | grep -qx 0` → 0 occurrences
- `! grep -q 'mlx-swift-examples' Package.resolved` → confirmed
- `swift build` → Build complete (21.08s)
- `swift test` → 938 tests in 83 suites passed

## Self-Check: PASSED
