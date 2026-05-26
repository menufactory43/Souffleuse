# 04-03 Replay Equivalence Diff — Post GenerationPlanner Extraction

**Date :** 2026-05-25
**Commit HEAD :** 4090278 (post 04-03 Task 3)
**Baseline reference :** 04-02-BASELINE-REPLAY.md (commit 3e9a826 baseline)
**MODE :** BUILD-ONLY (same justification as 04-02 — replay live MLX non-headless)

## Verdict

**EQUIVALENT**

GenerationPlanner extraction est un refactor strictement mécanique :
- `generation: UInt64` → `planner.currentGeneration: GenerationToken` (wrapper Sendable
  sur le même `UInt64`)
- `currentTask: Task<Void, Never>?` → `planner.currentTask` (même ownership)
- `generation &+= 1 ; currentTask?.cancel()` → `planner.beginGeneration()` /
  `planner.beginGenerationDetachingPrevious()` / `planner.cancel()` — appels qui
  préservent verbatim la séquence d'opérations

Aucun ghost-text, aucun log événement, aucun ordering observable n'est modifié.
La sémantique cancel-on-keystroke est verrouillée par les 12 nouveaux tests
`GenerationPlannerTests` + les 187 tests pré-existants restent verts.

## Build-only equivalence checks

| Check | Baseline (04-02 post) | This plan (04-03 post) | Δ |
|---|---|---|---|
| `swift build` exit | 0 | 0 | 0 |
| `swift test` exit | 0 | 0 | 0 |
| Tests count | 187 | 199 | +12 (GenerationPlannerTests) |
| `bash audit.sh` exit | 0 | 0 | 0 |
| Scenarios hash sha256 | `d4fa5820383b51dd9226ac7d905c788396f8f7abbc46b6fe7359c9928d288f23` | `d4fa5820383b51dd9226ac7d905c788396f8f7abbc46b6fe7359c9928d288f23` | identical |

## Code-path equivalence (manual diff)

| Site PVM (pre-04-03) | Site PVM (post-04-03) | Sémantique |
|---|---|---|
| `currentTask?.cancel(); currentTask = nil; generation &+= 1` (cache_hit L637-639) | `planner.cancel()` | identique : cancel + nil + bump |
| `currentTask?.cancel(); currentTask = nil; generation &+= 1` (cache_undo_hit L674-676) | `planner.cancel()` | identique |
| `let previousTask = currentTask; previousTask?.cancel(); generation &+= 1; let myGeneration = generation` (predict L768-772) | `let (myGeneration, previousTask) = planner.beginGenerationDetachingPrevious()` | identique : la nouvelle method retourne tuple |
| `currentTask = Task { ... }` (predict L929) | `let task = Task { ... } ; planner.setCurrentTask(task)` | identique : ownership transfert |
| `guard self.generation == myGeneration` (L840, L849, L1388) | `guard self.planner.isCurrent(myGeneration)` | identique : `isCurrent` = `token == currentGeneration` |
| `currentTask?.cancel(); currentTask = nil; generation &+= 1` (cancel(reason:) L1486-1488) | `planner.cancel()` | identique |

## Pitfall 1 verification

Avant 04-03 : la closure onChunk capturait `myGeneration: UInt64` par valeur ; comparait
à `self.generation` (lecture sur self au moment de l'exécution). Stale chunks droppés
correctement.

Après 04-03 : la closure capture `myGeneration: GenerationToken` par valeur ; compare
via `self.planner.isCurrent(myGeneration)` (qui fait `token == self.planner.currentGeneration`).
La sémantique est strictement la même — la token est un wrapper Sendable sur l'UInt64.

Tests `beginGenerationCancelsPriorTask` + `isCurrentTrueForLatestToken` + `cancelBumpsGeneration`
verrouillent l'invariant.

## Risk surface

- Aucun changement de threading model (toujours `@MainActor`).
- Aucun changement de log event (PVM continue d'émettre tous ses events).
- Aucun changement de file API ou de Sendable closure crossing.
- Une seule extension d'API : `beginGenerationDetachingPrevious()` ajouté pour
  préserver l'invariant `await previousTask?.value` (sync cross-stream) qui
  existait avant via `let previousTask = currentTask` local. Pas une déviation
  fonctionnelle, juste une recomposition mécanique.

## Conclusion

**Replay équivalent.** Le ghost-text behavior, le cancel-on-keystroke discipline,
le timing debounce, et tous les logs events restent strictement identiques. Le
refactor déplace simplement la ownership des champs `generation` + `currentTask`
de PVM vers GenerationPlanner sans changer leur sémantique.
