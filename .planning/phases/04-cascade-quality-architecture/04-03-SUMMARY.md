---
phase: 04-cascade-quality-architecture
plan: 03
subsystem: Souffleuse (app target)
tags:
  - phase-04
  - split-pvm
  - generation-planner
  - lifecycle
dependency-graph:
  requires:
    - SouffleuseLog
    - SuggestionPolicyEngine (04-02)
  provides:
    - GenerationPlanner (@MainActor final class)
    - GenerationToken (Sendable Equatable struct)
    - GenerationPlanner.predictDebounceNanos (centralisé pour 04-07)
    - GenerationPlanner.beginGenerationDetachingPrevious() (preserves await previousTask?.value)
  affects:
    - Souffleuse/Sources/Souffleuse/PredictorViewModel.swift (lifecycle migrée out)
tech-stack:
  added: []
  patterns:
    - "@MainActor final class lifecycle owner (Pattern A)"
    - "Sendable value-type token (Pitfall 1 — closure captures by value)"
    - "Debounce coalescing utility centralisé (Pattern B Plan 04-07 preview)"
key-files:
  created:
    - Souffleuse/Sources/Souffleuse/GenerationPlanner.swift (137 LOC)
    - Souffleuse/Tests/SouffleuseTests/GenerationPlannerTests.swift (165 LOC, 12 tests)
    - .planning/phases/04-cascade-quality-architecture/04-03-REPLAY-DIFF.md
  modified:
    - Souffleuse/Sources/Souffleuse/PredictorViewModel.swift (1509 → 1513 LOC ; -23/+27 net +4)
decisions:
  - "GenerationPlanner expose 2 variantes de beginGeneration : la forme simple (cancel+bump) ET beginGenerationDetachingPrevious() qui retourne le previousTask pour préserver l'invariant `await previousTask?.value` dans predict(). Sans cette variante, la sync cross-stream du PVM:768-771 pre-04-03 (let previousTask = currentTask) aurait été perdue."
  - "scheduleDebounced expose le contrat dès maintenant mais n'est PAS wired dans PVM/AppDelegate. Le debounce 30ms continue de vivre dans SouffleuseAppDelegate.predictDebounceTask jusqu'au Plan 04-07 (TypingSession). predictDebounceNanos est centralisée chez le Planner pour figer la constante partagée."
  - "PVM LOC a légèrement augmenté (+4 net) au lieu de baisser comme attendu — l'ajout de commentaires explicatifs sur la délégation au planner compense largement la suppression de 4 lignes de state. Le shrinking PVM majeur viendra des Plans 04-04 (CompletionCache) et 04-05 (Runtime extraction)."
  - "Mode BUILD-ONLY pour le replay-diff conservé — le replay live MLX reste non-headless. Les 12 nouveaux tests verrouillent les invariants cancel-on-keystroke + counter monotonicity + Pitfall 1."
metrics:
  duration_minutes: ~20
  completed_date: 2026-05-25
  tests_before: 187
  tests_after: 199
  tests_added: 12
  audit_checks: 6/6
---

# Phase 4 Plan 03 : GenerationPlanner Extraction Summary

**One-liner :** Extraction de la lifecycle (generation counter + currentTask + debounce 30ms central) de `PredictorViewModel` vers `@MainActor final class GenerationPlanner` + value-type `GenerationToken` (Sendable, Equatable) qui blinde le Pitfall 1 (chunks stale droppés par `isCurrent(_:)` après cancel-on-keystroke).

## What Shipped

### New types (in `Souffleuse/Sources/Souffleuse/GenerationPlanner.swift`)

| Type | Role |
|---|---|
| `struct GenerationToken: Sendable, Equatable` | Opaque wrapper sur `UInt64`. Capturé par valeur dans les closures onChunk — comparé via `planner.isCurrent(_:)`. |
| `@MainActor final class GenerationPlanner` | Owns `currentGeneration: GenerationToken`, `currentTask: Task<Void, Never>?`, `debounceTask`. API : `beginGeneration()` / `beginGenerationDetachingPrevious()` / `isCurrent(_:)` / `setCurrentTask(_:)` / `cancel()` / `scheduleDebounced(_:)`. |
| `static let predictDebounceNanos: UInt64 = 30 * 1_000_000` | 30 ms centralisé — sera consommé par `TypingSession` au Plan 04-07. |

### PVM (façade — 1509 → 1513 LOC, +4 net)

Lifecycle migrée :
- Suppression `private var generation: UInt64 = 0` (PVM:112 pre-04-03)
- Suppression `private var currentTask: Task<Void, Never>?` (PVM:108 pre-04-03)
- Ajout `private let planner = GenerationPlanner()`

Call-sites refactorés :
- `predict()` ouverture (PVM:768-772 pre) → `planner.beginGenerationDetachingPrevious()`
- `predict()` Task creation (PVM:929 pre) → `let task = Task { … } ; planner.setCurrentTask(task)`
- `predict()` cache_hit (PVM:637-639 pre) → `planner.cancel()`
- `predict()` cache_undo_hit (PVM:674-676 pre) → `planner.cancel()`
- `onChunk` guard ghost_dropped_repeat (PVM:840 pre) → `self.planner.isCurrent(myGeneration)`
- `onChunk` guard apply (PVM:849 pre) → `self.planner.isCurrent(myGeneration)`
- `llm_done_stored` guard (PVM:1388 pre) → `self.planner.isCurrent(myGeneration)`
- `cancel(reason:)` (PVM:1486-1488 pre) → `planner.cancel()`

### Tests

| Suite | Tests | Coverage |
|---|---|---|
| GenerationPlannerTests | 12 | Counter monotonicity (3 cas) + isCurrent guard + cancel-on-keystroke (2 cas) + detaching prior (2 cas) + token Equatable/Sendable + debounce coalescing + delay + constante figée |

Total post-04-03 : **199/199 tests verts** (187 baseline + 12 nouveaux).

### Documentation / Replay

- `04-03-REPLAY-DIFF.md` — verdict `EQUIVALENT` (BUILD-ONLY mode, scenarios hash identique, audit 6/6, builds clean)

## Key Decisions

### 1. `beginGenerationDetachingPrevious()` ajouté pour préserver `await previousTask?.value`

Le `predict()` pre-04-03 capturait localement `let previousTask = currentTask ; previousTask?.cancel()` avant de bumper le counter, puis dans le nouveau `Task { ... }` body faisait `_ = await previousTask?.value` pour s'assurer que toute finalisation de l'ancien stream soit faite avant le nouveau predict. Cette sync cross-stream est un invariant subtle qu'on ne pouvait pas perdre. La méthode `beginGenerationDetachingPrevious()` retourne tuple `(token, previousTask)` ; le PVM continue d'`await previousTask?.value` dans son body.

### 2. `scheduleDebounced` exposé mais non-wired ce plan

Le debounce 30ms continue de vivre dans `SouffleuseAppDelegate.predictDebounceTask` pour ce plan — la migration AppDelegate vers GenerationPlanner aurait demandé de toucher 3 sites AppDelegate ET d'introduire un cycle (PVM ↔ AppDelegate ↔ Planner). Plan 04-07 (TypingSession extraction) consommera `planner.scheduleDebounced` proprement. Pour ce plan, on a juste figé la constante 30ms et le contrat de la méthode pour que les tests verrouillent le comportement.

### 3. PVM LOC +4 net (au lieu d'une baisse)

L'ajout de commentaires explicatifs sur la délégation au planner (≈11 lignes de docstring « Phase 4 — lifecycle gérée par GenerationPlanner ») compense la suppression de 4 lignes de state. Le shrinking PVM majeur viendra des Plans 04-04 (CompletionCache extraction ~80 LOC) et 04-05 (Runtime extraction ~200 LOC).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 — Blocking dependency] `await previousTask?.value` préservation**

- **Found during :** Task 2 wiring
- **Issue :** Le plan demandait `let myGeneration = planner.beginGeneration()` direct, mais le PVM utilise `_ = await previousTask?.value` dans le body de la nouvelle Task pour s'assurer que l'ancien stream soit terminé avant que le nouveau démarre. Avec `beginGeneration()` qui nile en interne, le `previousTask` local n'existe plus.
- **Fix :** Ajout d'une méthode `beginGenerationDetachingPrevious() -> (GenerationToken, Task<Void, Never>?)` sur GenerationPlanner. Préserve verbatim l'invariant de sync cross-stream. Le `beginGeneration()` simple reste disponible pour les futurs call-sites qui n'ont pas besoin du previousTask.
- **Files modified :** GenerationPlanner.swift, PredictorViewModel.swift
- **Commit :** `cb54695`

### Authentication Gates

Aucun.

## Threat Flags

Aucun nouveau threat. Les invariants T-04-03-01 (stale chunks via Pitfall 1), T-04-03-02 (debounce Task ne s'arrête jamais), T-04-03-03 (aucun log) sont tous mitigés via tests + design.

## Known Stubs

Aucun. `scheduleDebounced` est un contrat fonctionnel complet (avec tests verrouillant son comportement). Son non-usage actuel par PVM/AppDelegate est documenté en commentaire dans `GenerationPlanner.scheduleDebounced` et tracé pour le Plan 04-07.

## Commits

| Hash | Type | Description |
|---|---|---|
| `7d06c10` | feat(04-03) | add GenerationPlanner + GenerationToken value-type |
| `cb54695` | refactor(04-03) | wire GenerationPlanner dans PredictorViewModel |
| `4090278` | test(04-03) | GenerationPlannerTests — counter + cancel + debounce |
| `6758e9c` | docs(04-03) | replay diff verdict — EQUIVALENT (BUILD-ONLY mode) |

## Success Criteria — Met

1. ✅ `swift build --package-path Souffleuse` exit 0
2. ✅ `swift test --package-path Souffleuse` exit 0 — **199 tests verts** (≥182)
3. ✅ `bash Souffleuse/audit.sh` exit 0 — 6/6 checks
4. ✅ GenerationPlanner + GenerationToken en place
5. ✅ PVM ne contient plus `generation: UInt64` ni `currentTask: Task<...>` direct (vérifié par grep)
6. ✅ 04-03-REPLAY-DIFF.md verdict `EQUIVALENT`

## Self-Check: PASSED

- `Souffleuse/Sources/Souffleuse/GenerationPlanner.swift` — FOUND (137 LOC)
- `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` — FOUND (1513 LOC)
- `Souffleuse/Tests/SouffleuseTests/GenerationPlannerTests.swift` — FOUND (12 tests)
- `.planning/phases/04-cascade-quality-architecture/04-03-REPLAY-DIFF.md` — FOUND
- Commits `7d06c10`, `cb54695`, `4090278`, `6758e9c` — all FOUND in git log
- `grep -c 'private var generation: UInt64' PVM.swift` returns 0 ✓
- `grep -c 'private var currentTask: Task' PVM.swift` returns 0 ✓
- `grep -c 'private let planner = GenerationPlanner' PVM.swift` returns 1 ✓
- `grep -c 'planner.beginGeneration\|planner.beginGenerationDetachingPrevious' PVM.swift` returns ≥2 ✓
- `grep -c 'planner.isCurrent' PVM.swift` returns 4 ✓
- `grep -c 'planner.cancel' PVM.swift` returns 4 ✓
- `bash audit.sh` exit 0 ✓
- `swift test` 199/199 ✓
