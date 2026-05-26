---
phase: 04-cascade-quality-architecture
plan: 01
subsystem: Souffleuse (app target)
tags:
  - phase-04
  - foundation
  - scoring
  - relevance-gate
dependency-graph:
  requires:
    - SouffleuseLog
    - SouffleusePersonalization
    - SouffleuseTyping
  provides:
    - SuggestionSource (top-level enum)
    - Score (struct, Sendable, Equatable, CustomStringConvertible)
    - SuggestionPolicy (enum namespace, pure-function helpers)
    - SuggestionPolicy.Tuning (10 constants D-06..D-09/D-13)
  affects:
    - Souffleuse/Sources/Souffleuse/PredictorViewModel.swift (SuggestionSource déplacé hors classe)
tech-stack:
  added: []
  patterns:
    - Sendable value-type Score (Pattern D)
    - nonisolated static pure helpers (Pattern E)
    - Single-file constants holder (Tuning, calqué sur PromptBuilderFlag)
key-files:
  created:
    - Souffleuse/Sources/Souffleuse/SuggestionPolicy.swift (156 LOC)
    - Souffleuse/Sources/Souffleuse/SuggestionPolicy+Tuning.swift (52 LOC)
    - Souffleuse/Tests/SouffleuseTests/RelevanceGateTests.swift (165 LOC)
  modified:
    - Souffleuse/Sources/Souffleuse/PredictorViewModel.swift (enum SuggestionSource supprimé, références globales préservées)
decisions:
  - "SuggestionPolicy reste un `enum` namespace en 04-01 ; la classe state-bearing arrivera en 04-02 sous le nom SuggestionPolicyEngine pour éviter le rename `enum → class` qui aurait cassé tous les call-sites Tuning."
  - "Tasks 1 + 2 committées atomiquement : Score.passesGate référence Tuning.gateFloor ; le package ne build pas avec T1 seule (Rule 3 — ordering blocker)."
metrics:
  duration_minutes: ~25
  completed_date: 2026-05-25
  tests_before: 139
  tests_after: 153
  tests_added: 14
  audit_checks: 6/6
---

# Phase 4 Plan 01 : SuggestionPolicy Foundation Summary

**One-liner :** Fondation pure-function du Ghost Relevance Gate — `Score` scalar [0,1] composé de `sourcePrior × prefixFit × lengthFit`, namespace `SuggestionPolicy` avec helpers `nonisolated static`, et single-file `Tuning` regroupant tous les seuils tunables D-06..D-13.

## What Shipped

### New files (3)

| File | LOC | Role |
|---|---|---|
| `Souffleuse/Sources/Souffleuse/SuggestionPolicy.swift` | 156 | Top-level `SuggestionSource`, struct `Score`, namespace `enum SuggestionPolicy` avec `score(...)`, `prefixFit(...)`, `lengthFit(...)` |
| `Souffleuse/Sources/Souffleuse/SuggestionPolicy+Tuning.swift` | 52 | Extension `SuggestionPolicy` avec `enum Tuning` — 10 constantes (gateFloor 0.25, replacementBar 1.15, afterSpaceL1Bar 0.4, l2UpgradeDelta 0.15, parasiteWindow 0.8, uselessMinVisibleMs 200, badMaxDivergeMs 500, sourcePrior dict 6 sources, lengthFitByWordCount array 10 entrées) |
| `Souffleuse/Tests/SouffleuseTests/RelevanceGateTests.swift` | 165 | 14 `@Test` cases sous `@Suite "Phase 4 — Relevance Gate scoring"` |

### Modified files (1)

| File | Change |
|---|---|
| `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` | `enum SuggestionSource` supprimé (était imbriqué dans la classe PVM L101-108). Le type est maintenant top-level dans `SuggestionPolicy.swift` ; les références internes PVM (`suggestionSource: SuggestionSource = .none`, `let instantSource: SuggestionSource`) résolvent via global lookup — aucun call-site n'a besoin d'être modifié. |

### Tests

- **Baseline :** 139 tests verts (état post Phase 3)
- **Après plan 04-01 :** **153 tests verts** (139 + 14 RelevanceGate)
- Suite : `Phase 4 — Relevance Gate scoring (D-06, D-07, D-13)`
- Coverage :
  - `scoreValueIsProductOfThreeFactors` — formule × 3 combos
  - `passesGateBlocksUnderFloor` / `passesGateAcceptsAboveFloor` — gateFloor D-07
  - `beatsReturnsFalseForEqualScores` / `beatsReturnsTrueWhenAboveReplacementBar` / `beatsReturnsFalseJustBelowReplacementBar` — replacementBar D-07
  - `sourcePriorOrderingMatchesD06` — history > cache > undoCache > llm > wordComplete > none
  - `prefixFitMidWordMatchReturnsOne` / `prefixFitMidWordDivergentReturnsZero` — D-06 mid-word
  - `prefixFitAfterSpaceLetterReturnsOne` / `prefixFitAfterSpaceMarkdownReturnsZero` / `prefixFitEmptyTailReturnsOne` — D-06 after-space + edge cases
  - `lengthFitBellCurveByWordCount` — table complète (0,1,3,6,9,15-clamp)
  - `scoreEndToEndHistoryAfterSpace` — composition complète

### Privacy / Audit

- `bash Souffleuse/audit.sh` : **6/6 vert** ✓
- Aucun nouveau `Log.*` call dans ce plan — le scorer est pur, surface privacy nulle.
- Aucune lecture de `history.aes`, clipboard, ou AX dans les nouveaux fichiers.
- Convention "no literal threshold outside Tuning.swift" tenue :
  ```
  grep -nE '0\.(25|4|15|55|60|70|75|85)' RelevanceGateTests.swift SuggestionPolicy.swift \
    | grep -v 'Tuning\.' | grep -vE '^[^:]+:[0-9]+:\s*//' → 0 hits
  ```

## Key Decisions

- **Tasks 1 + 2 committées atomiquement (single commit `428819c`).** Justification : `Score.passesGate` (Task 1) référence `Tuning.gateFloor` (Task 2). Sans Tuning, le module ne compile pas. Plutôt que d'introduire un literal temporaire que Task 4 aurait flaggé, fusion atomique. Rule 3 (auto-fix blocking ordering) — pas de permission user requise. Le contenu de chaque Task reste vérifiable par les acceptance_criteria respectifs.

- **`SuggestionPolicy` reste un `enum` namespace en 04-01.** Le plan 04-02 introduira `@MainActor final class SuggestionPolicyEngine` séparément. Cela évite le rename `enum → class` qui aurait cassé tous les call-sites `SuggestionPolicy.Tuning.*`. Documenté en file-header.

- **Float precision dans `scoreValueIsProductOfThreeFactors`.** L'expression `0.75 * 1.0 * 0.85` évaluée comme Double-then-cast-to-Float donne `0.6375` ; le runtime Float donne `0.63750005`. Assertion réécrite : `s.value == s.sourcePrior * s.prefixFit * s.lengthFit` (même précision sur les deux côtés). Rule 1 (bug introduit par le test lui-même).

- **`prefixFit` couvre l'edge case "ponctuation non-whitespace".** Le plan ne spécifie pas explicitement le comportement quand `userTail` se termine sur `.`, `,`, `!`, etc. Choix retenu : traité comme after-space-like (autoriser lettre/digit/quote, refuser whitespace/markdown). Documenté en doc-comment.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 — Blocking ordering] Tasks 1 + 2 fusionnés en un seul commit**
- **Found during :** Task 1 verify (swift build)
- **Issue :** `Score.passesGate { value >= SuggestionPolicy.Tuning.gateFloor }` ne compile pas sans Tuning ; Task 2 crée Tuning. Plan demandait commit séparé par Task mais le package serait cassé entre commits.
- **Fix :** Commit atomique `428819c` couvrant les deux files (`SuggestionPolicy.swift` + `SuggestionPolicy+Tuning.swift`) + la suppression du nested enum dans PVM.
- **Files modified :** Sources/Souffleuse/SuggestionPolicy.swift, Sources/Souffleuse/SuggestionPolicy+Tuning.swift, Sources/Souffleuse/PredictorViewModel.swift
- **Commit :** `428819c`

**2. [Rule 1 — Bug] Float precision dans `scoreValueIsProductOfThreeFactors`**
- **Found during :** Task 3 verify (swift test --filter RelevanceGateTests)
- **Issue :** Assertion `c.value == 0.75 * 1.0 * 0.85` échouait — `0.63750005 != 0.6375`. Le RHS est computé en Double puis cast à Float ; le LHS (`Score.value`) multiplie déjà en Float.
- **Fix :** Assertion réécrite `c.value == c.sourcePrior * c.prefixFit * c.lengthFit` — mêmes opérations Float sur les deux côtés.
- **Files modified :** Tests/SouffleuseTests/RelevanceGateTests.swift
- **Commit :** `e9fc64a`

**3. [Rule 1 — Bug] File-header commentaire mentionnait `history.aes`**
- **Found during :** Task 4 verify (bash audit.sh)
- **Issue :** Le check 5 d'audit.sh refuse toute référence à `history.aes` hors `TypingHistoryStore.swift` et `HistoryViewerWindow.swift`. Mon doc-comment "ce fichier n'émet aucun log et ne lit ni `history.aes` ni le clipboard" déclenche le grep.
- **Fix :** Reformulé en "n'accède à aucune source de contexte user (typing history, clipboard, AX)".
- **Files modified :** Sources/Souffleuse/SuggestionPolicy.swift
- **Commit :** `e9fc64a` (regroupé avec le commit de tests)

**4. [Rule 1 — Bug] Literals `0.75` / `0.85` dans les tests violaient Pitfall 6**
- **Found during :** Task 4 verify (grep CI literals)
- **Issue :** Trois tests instanciaient `Score(sourcePrior: 0.75, …)` ou `Score(…, lengthFit: 0.85)` — literals interdits hors `SuggestionPolicy+Tuning.swift` per D-13.
- **Fix :** Remplacés par `SuggestionPolicy.Tuning.sourcePrior[.history] ?? 0` et `SuggestionPolicy.Tuning.lengthFitByWordCount[6]`.
- **Files modified :** Tests/SouffleuseTests/RelevanceGateTests.swift
- **Commit :** `e9fc64a`

### Authentication Gates

Aucune — le plan est 100% pure-function offline.

## Confirmation D-02 Migration

- **Avant :** `enum SuggestionSource` était imbriqué dans `class PredictorViewModel` (PVM:101-108). Référencé en interne par PVM uniquement (3 sites).
- **Après :** `enum SuggestionSource: Sendable` est défini top-level dans `Souffleuse/Sources/Souffleuse/SuggestionPolicy.swift`. Les 3 références internes PVM (`suggestionSource: SuggestionSource = .none`, `let instantSource: SuggestionSource`, et les `case` literals comme `.history` / `.llm`) compilent inchangés grâce à la résolution globale Swift.
- **Vérification :**
  ```
  grep -n 'enum SuggestionSource' Souffleuse/Sources/Souffleuse/PredictorViewModel.swift  # → 0 hits
  swift build → exit 0
  swift test → 153/153 passing
  ```

## Commits

| Hash | Type | Description |
|---|---|---|
| `428819c` | feat(04-01) | introduce SuggestionPolicy foundation (Score + SuggestionSource + Tuning) |
| `e9fc64a` | test(04-01) | RelevanceGate pure-function suite (14 tests) + audit fix |

## Success Criteria — All Met

1. ✅ `swift build --package-path Souffleuse` exit 0
2. ✅ `swift test --package-path Souffleuse` exit 0 — **153 tests passing** (≥ 151)
3. ✅ `bash Souffleuse/audit.sh` exit 0 — 6/6 checks vert
4. ✅ `SuggestionPolicy.swift`, `SuggestionPolicy+Tuning.swift`, `RelevanceGateTests.swift` créés
5. ✅ Aucun seuil tuning n'apparaît comme literal numérique hors `SuggestionPolicy+Tuning.swift` (grep CI vérifié)
6. ✅ `enum SuggestionSource` n'est plus défini dans `PredictorViewModel.swift`

## Self-Check: PASSED

- `Souffleuse/Sources/Souffleuse/SuggestionPolicy.swift` — FOUND
- `Souffleuse/Sources/Souffleuse/SuggestionPolicy+Tuning.swift` — FOUND
- `Souffleuse/Tests/SouffleuseTests/RelevanceGateTests.swift` — FOUND
- Commit `428819c` — FOUND in git log
- Commit `e9fc64a` — FOUND in git log
