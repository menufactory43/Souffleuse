# 04-09 — TypingSession Extraction (D-04) : DEFERRED

**Status** : Deferred to a future milestone.
**Date deferred** : 2026-05-26

## Pourquoi

Le gsd-executor a déclenché un Rule 4 architectural checkpoint avant exécution, similaire au cas 04-05 (qui a abouti à la décomposition 04-05/06/07 + flag empirical gate). L'analyse :

1. **Aucun filet automatisé** pour les sémantiques critiques de `tick()` et `handleKey()` — les 246 tests existants n'exercent pas le pipeline end-to-end (besoin AX réel, NSPanel, CGEventTap, Timer 80ms).

2. **Pitfall 2 — Partial-accept guard** : le commentaire dans `SouffleuseAppDelegate.swift:1063-1092` documente explicitement la nécessité de mutation d'état SYNCHRONE dans `handleKey()`. Un déplacement de la boundary `MainActor.assumeIsolated` lors de l'extraction risque de ré-introduire le bug historique « Tab Tab Tab produces new words each press instead of walking through cached suggestion ».

3. **Plan mêle extraction + nouvelle sémantique** : 3 nouvelles classifications cascade (`.typedDiverged`, `.typedPastWithoutOverlap`, `.acceptedPartial(chunks:)`) sont introduites en même temps que l'extraction. Mélange de concerns risqué.

4. **Pseudo-code du plan buggy** : `if predictor.suggestion != lastGhostShownAt` (comparaison String vs Date) — signal que le plan n'a pas été matérialisé/compilé par le planificateur.

5. **Ratio bénéfice/risque déséquilibré** : purement architectural (D-04). AppDelegate à 1209 LOC fonctionne, validé par sessions récentes (Ghost intelligence, Live consume). L'extraction redistribue ~700 LOC vers TypingSession + ~400 LOC restant dans AppDelegate, sans réduire la complexité totale — la complexité unique (sémantiques temporelles intriquées) reste exactement la même.

## Décision

**Option C retenue** : skip 04-09 entirely pour ce milestone. Le D-03 split (objectif headline de la phase 04) est livré (PVM 1566 → 626 LOC, 4 modules + façade). Le D-04 split AppDelegate → TypingSession est reporté à un futur milestone, conditionnellement :

1. **Prerequisite** : ajouter d'abord un AX-mock test harness qui exerce `tick()` et `handleKey()` end-to-end avec assertions sur le comportement cascade. Sans ce filet, toute extraction restera empirically-only-validable.

2. **Decoupling** : le câblage des 3 nouvelles classifications cascade (`.typedDiverged`, `.typedPastWithoutOverlap`, `.acceptedPartial`) peut être livré dans un plan séparé, in-place dans AppDelegate, sans extraction. Cela délivre D-09 (classification grid complète) sans toucher au scaffolding.

## Impact sur la phase 04

- **Phase 04 reste cohérente sans 04-09** : le headline goal (D-03 split PVM, parité subjective post-refactor) est atteint sans dépendre du D-04 split.
- Plans suivants (04-10 Coherence v2, 04-11 3-app verify) ne dépendent pas structurellement de TypingSession.
- `04-11-PLAN.md` (verification finale) doit ajuster ses critères : le test 3-app valide le comportement post-D-03 split, pas post-D-04 split.

## Suivi

- D-04 TypingSession extraction : à replanifier dans un futur milestone, après AX-mock test harness.
- D-09 classification grid câblage : à livrer dans un plan séparé in-place dans AppDelegate (peut être ajouté à la phase 04 si désiré, ou reporté).
- Concern cache/few-shots surconsommation (vu pendant 04-07 empirical validation) : à diagnostiquer dans un follow-up séparé.

## Files

- `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift` — **non modifié** (reste à ~1209 LOC).
- `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` — **non modifié** (reste à 626 LOC façade post-D-03).
- `Souffleuse/Sources/Souffleuse/TypingSession.swift` — **non créé** (sera créé dans un futur milestone).
- `Souffleuse/Tests/SouffleuseTests/TypingSessionDivergenceTests.swift` — **non créé**.

Tests, audit, build : non affectés (246 tests verts, 6/6 audit, build clean).
