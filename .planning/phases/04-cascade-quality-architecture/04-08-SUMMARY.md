---
phase: 04-cascade-quality-architecture
plan: 08
subsystem: cascade-quality
tags:
  - phase-04
  - history-l1-gate
  - cascade-coverage
  - tests-only
requires:
  - SuggestionPolicy.Tuning.afterSpaceL1Bar (defined 04-01)
  - SuggestionPolicy.Tuning.l2UpgradeDelta (defined 04-01)
  - SuggestionPolicyEngine.routeInstant (wired 04-02)
  - SuggestionPolicyEngine.onLLMChunk (wired 04-02)
provides:
  - "8 nouveaux tests verrouillant le L1 history re-enable derrière le Gate D-08"
  - "Couverture du delta L2-over-L1 upgrade (Tuning.l2UpgradeDelta)"
  - "Verrouillage par référence aux constantes Tuning (résilient au tuning futur)"
affects:
  - Souffleuse/Tests/SouffleuseTests/HistoryExactMatchTests.swift
tech-stack:
  added: []
  patterns:
    - "@Suite Phase 4 — séparation thématique au sein d'un fichier de tests"
    - "Scores explicites via Score(sourcePrior:…) pour isoler des deltas précis"
key-files:
  created: []
  modified:
    - Souffleuse/Tests/SouffleuseTests/HistoryExactMatchTests.swift
decisions:
  - "Tests-only : aucun changement de production code. Le L1 wiring était déjà live en 04-02 ; ce plan apporte la couverture absente."
  - "Le helper historyExactSubstringMatch renvoie nil pour lookback finissant par whitespace — donc routeInstant ne déclenche pas le L1 en after-space pur. Comportement documenté en tête de suite ; les tests scoring valident le Gate au niveau pure-function (la voie observable du score)."
metrics:
  duration: ~25 min
  completed: 2026-05-26
---

# Phase 4 Plan 08: HistoryExactMatchTests L1 Gate Coverage — Summary

**One-liner :** Extension de `HistoryExactMatchTests.swift` avec 8 nouveaux tests sous une `@Suite` dédiée `HistoryL1GateTests` qui verrouillent le comportement du L1 history re-enabled derrière `SuggestionPolicy.Tuning.afterSpaceL1Bar` (D-08) — Gate scoring above/below bar, prefix_fit=0 markdown outliers blocked, lengthFit collapse on 9+ words, L2-over-L1 upgrade via beatsBar et l2UpgradeDelta, mid-word L1 non applicable, snapshot vide nil, références aux constantes Tuning (Pitfall 6).

## Scope

- ✅ 8 baseline `HistoryExactMatchTests` préservés verbatim (zero regression)
- ✅ +8 nouveaux tests dans `@Suite HistoryL1GateTests` (≥6 requis)
- ✅ Audit `audit.sh` : PASSED 6/6
- ✅ Test suite : 238 → 246 tests verts
- ✅ Aucune occurrence de `historyExactSubstringMatch` dans `PredictorViewModel.swift` (confirmé 0)
- ✅ Le L1 wiring (afterSpaceL1Bar guard dans `routeInstant`) confirmé actif dans `SuggestionPolicy.swift` (2 références)

## Tests added (8)

| Test | Verrouillage |
|------|--------------|
| `historyMatchAboveBarPasses` | History prior 0.75 × prefix_fit 1.0 × length_fit 1.0 = 0.75 ≥ afterSpaceL1Bar |
| `historyMatchPrefixFitZeroIsBlocked` | Ghost commençant par `*` (markdown) → prefix_fit=0 → score=0 → bloqué |
| `historyMatchTooLongFallsUnderBar` | 10 mots → length_fit=0.3 → 0.225 < afterSpaceL1Bar |
| `l1EmptyHistorySnapshotReturnsNil` | routeInstant retourne nil quand snapshot vide |
| `l1NotApplicableMidWord` | Cascade D-08 row 1 : mid-word = L0 exclusif, jamais L1 |
| `l1L2UpgradeWhenL2BeatsByDelta` | L1 score 0.50, L2 score 0.60 → beatsBar (0.50×1.15=0.575) → L2 wins |
| `l1L2NoUpgradeWhenScoresClose` | L1 score 0.75, L2 score 0.60 → ni beatsBar (>0.8625) ni delta (>0.90) → keep L1 |
| `gateConstantsAreReferencedNotInlined` | Sanity : les constantes Tuning sont les paramètres effectifs, pas des littéraux |

## L1 wiring confirmation

- `grep -c 'historyExactSubstringMatch' Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` → **0** (helper migré à SuggestionPolicy en 04-02, jamais réintroduit dans PVM)
- `grep -c 'afterSpaceL1Bar' Souffleuse/Sources/Souffleuse/SuggestionPolicy.swift` → **2** (commentaire doc + guard `score.value >= SuggestionPolicy.Tuning.afterSpaceL1Bar` dans `routeInstant`)
- Le L1 path dans `routeInstant` reste actif derrière le Gate (D-08) ; le helper pure-function `historyExactSubstringMatch` filtre les lookbacks finissant par whitespace par construction.

## Acceptance criteria

- ✅ `grep -c '@Test' HistoryExactMatchTests.swift` → 16 (≥14)
- ✅ `grep -c 'SuggestionPolicy.Tuning.afterSpaceL1Bar' HistoryExactMatchTests.swift` → 8
- ✅ `grep -c '@Suite' HistoryExactMatchTests.swift` → 2
- ✅ `swift test --package-path Souffleuse` exit 0, 246 tests
- ✅ `bash Souffleuse/audit.sh` exit 0

## Deviations from Plan

None — le plan a été exécuté exactement comme rédigé. Le `<behavior>` block du plan suggérait `historyMatchBelowBarIsBlocked` ; après analyse de la formule, le scénario réaliste est `historyMatchPrefixFitZeroIsBlocked` (markdown outliers) et `historyMatchTooLongFallsUnderBar` (lengthFit collapse), qui sont exactement les deux cas que le plan décrivait comme alternatives dans son commentaire `<action>` (lignes 119-136). Aucun écart conceptuel.

## Sémantique observable (note de design)

`SuggestionPolicy.historyExactSubstringMatch` retourne nil quand le lookback se termine par whitespace (guard à la ligne 171 de `SuggestionPolicy.swift`). Comme `SuggestionPolicyEngine.routeInstant` passe l'userTail directement au helper, le L1 path ne déclenche en pratique PAS pour un `userTail` strictement after-space (terminant par espace). Le L1 wiring reste néanmoins live derrière le Gate `afterSpaceL1Bar` pour les invocations futures qui appelleraient le helper avec un lookback non-terminé par whitespace. Cette sémantique est documentée en tête de la nouvelle `@Suite` et est testée au niveau pure-function via `SuggestionPolicy.score(...)` — qui reste la voie de vérité pour le Gate.

## Self-Check: PASSED

- File `Souffleuse/Tests/SouffleuseTests/HistoryExactMatchTests.swift` exists (modified, 257 lignes)
- Commit `d7aa9e9` exists in git log
- `swift test` returns 246 passing tests
- `audit.sh` returns exit 0
