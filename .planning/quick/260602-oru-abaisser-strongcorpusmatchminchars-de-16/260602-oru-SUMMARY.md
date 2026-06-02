---
phase: quick-260602-oru
plan: 01
subsystem: SouffleuseCore — SuggestionPolicy corpus fast-path
tags: [corpus-recall, after-space, tuning, runtime-override, tdd]
dependency_graph:
  requires: []
  provides: [strongCorpusMatchMinCharsRuntime, MW_STRONG_MINCHARS override]
  affects: [SuggestionPolicy.strongCorpusMatch default, after-space fast-path recall]
tech_stack:
  added: []
  patterns: [runtime-overridable tuning constant (ProcessInfo env, clamp ≥ 1)]
key_files:
  created: []
  modified:
    - Souffleuse/Sources/SouffleuseCore/SuggestionPolicy+Tuning.swift
    - Souffleuse/Sources/SouffleuseCore/SuggestionPolicy.swift
    - Souffleuse/Tests/SouffleuseTests/CorpusFastPathTests.swift
decisions:
  - "Seuil after-space abaissé 16→12 : active le recall openers courts (Bonjour, ~9 chars) sans sacrifier la précision"
  - "Variante runtime MW_STRONG_MINCHARS pour A/B live — pattern identique à escBranchKRuntime"
  - "Défaut paramètre strongCorpusMatch changé (signature), pas le call-site : un seul point de changement, mid-word inchangé"
metrics:
  duration: ~8 minutes
  completed: "2026-06-02T15:57:27Z"
  tasks_completed: 3
  files_modified: 3
---

# Phase quick-260602-oru Plan 01: strongCorpusMatchMinChars 16→12 + runtime override MW_STRONG_MINCHARS Summary

**One-liner:** Seuil after-space corpus fast-path abaissé de 16 à 12 + variante runtime `MW_STRONG_MINCHARS` pour A/B live sans recompile.

---

## What Was Built

Le seuil `strongCorpusMatchMinChars` qui gouverne le recall corpus instantané en début de phrase (after-space) était trop haut (16 chars), bloquant les openers courants ("Bonjour, " = ~9 chars). Abaissé à 12, le ghost rappelle désormais les salutations et openers appris dès le début de frappe, comme Cotypist.

Trois changements atomiques :

1. **`SuggestionPolicy+Tuning.swift`** — `strongCorpusMatchMinChars` : 16 → 12, + nouvelle `var strongCorpusMatchMinCharsRuntime` qui lit `MW_STRONG_MINCHARS` (Int, clampé ≥ 1), fallback sur 12.

2. **`SuggestionPolicy.swift`** — signature `strongCorpusMatch` : paramètre par défaut `minChars` branché sur `Tuning.strongCorpusMatchMinCharsRuntime` (était `strongCorpusMatchMinChars`). Le call-site after-space hérite sans modification locale. Call-site mid-word (~l.927) conserve `midWordCorpusMatchMinChars` = 8 explicite, inchangé.

3. **`CorpusFastPathTests.swift`** — nouveau `@Test afterSpaceOpenerMatchesAt12NotAt16` : "Bonjour, je " (12 chars) → `strongCorpusMatch(..., minChars: 12)` ≠ nil, `minChars: 16` == nil. Démontre la bascule sans dépendance à l'env.

---

## Commits

| Task | Commit | Description |
|------|--------|-------------|
| 1 — Tuning constant + runtime var | f737ccb | feat(quick-260602-oru-01): strongCorpusMatchMinChars 16→12 + runtime override MW_STRONG_MINCHARS |
| 2 — Call-site default parameter | 85e75c9 | feat(quick-260602-oru-01): branche le défaut de strongCorpusMatch sur strongCorpusMatchMinCharsRuntime |
| 3 — Test + full suite + audit | 730c95f | test(quick-260602-oru-01): test de bascule strongCorpusMatch 12 vs 16 (after-space opener) |

---

## Verification Results

- `swift build` : OK (tâche 1 et tâche 2)
- `swift test --filter CorpusFastPathTests` : 23/23 verts (nouveau test inclus)
- `swift test` : **668/668 tests verts** (aucune régression)
- `bash audit.sh` : **6/6 checks OK** (AUDIT PASSED)

---

## Deviations from Plan

None - plan executed exactly as written.

---

## Known Stubs

None.

---

## Threat Flags

None. Changement purement interne au moteur de politique — aucune nouvelle surface réseau, auth, ou IO introduite.

---

## Self-Check: PASSED

- [x] `SuggestionPolicy+Tuning.swift` modifié : `strongCorpusMatchMinChars = 12`, `strongCorpusMatchMinCharsRuntime` présent
- [x] `SuggestionPolicy.swift` modifié : `minChars: Int = Tuning.strongCorpusMatchMinCharsRuntime`
- [x] `CorpusFastPathTests.swift` modifié : `afterSpaceOpenerMatchesAt12NotAt16` présent
- [x] Commits f737ccb, 85e75c9, 730c95f existent dans l'historique git
- [x] 668 tests verts, audit.sh 6/6
