# Phase 2: High-Signal Slots - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-05-25
**Phase:** 02-high-signal-slots
**Areas discussed:** afterCursor (frontière + activation), fieldContext (attributs AX + format), previousUserInputs (migration du slot fewShot), PERF-01 + escape PT/IT

---

## Initial gray-area selection

Quatre zones grises présentées avec recommandations explicites. Le user a répondu "Je serais parti en recommandé" — interprété comme : accepter le path recommandé pour chacune des 4 zones, mais en passant par une discussion séquentielle pour confirmation explicite slot par slot.

| Option | Description | Selected |
|--------|-------------|----------|
| afterCursor | Frontière typographique + activation | ✓ |
| fieldContext | Attributs AX retenus + format | ✓ |
| previousUserInputs | Migration du slot fewShot | ✓ |
| PERF-01 + PT/IT | Stratégie de défense + escape modèle | ✓ |

**User's choice:** Tout discuté en recommandé.
**Notes:** Discussion conduite area-par-area avec reco explicite à chaque tour.

---

## afterCursor — frontière typographique et activation

| Option | Description | Selected |
|--------|-------------|----------|
| OK pour D-14 (recommandé) | Prose FR `Suite du texte (à ne pas répéter) : « … »` placé avant beforeCursor, skip si vide, budget ~120 tokens (à affiner au planner). | ✓ |
| Marker explicite [CURSOR] | Plus structuré mais OOD pour le PT model — risque de fuite dans le ghost. À reconsidérer si on bascule vers IT. | |
| Toujours injecter (header vide si pas de texte) | Plus prédictible mais Phase 1 a montré que signal faible nuit. Je déconseille. | |

**User's choice:** OK pour D-14 (recommandé).
**Notes:**
- Prose FR retenue pour rester in-distribution sur PT model.
- Skip-si-vide cohérent avec apprentissage Phase 1 (signal faible nuit).
- Assembly order nouvelle : system → ci → ctx → fieldContext → afterCursor → previousUserInputs → beforeCursor.

---

## fieldContext — attributs AX retenus + format + emplacement de la lecture

| Option | Description | Selected |
|--------|-------------|----------|
| OK pour D-15 (recommandé) | 4 attributs (placeholder, role, subrole, help), exclu identifier, lecture dans AXSnapshot (coup TTFT zéro), format FR annotation, skip si rien, budget 60 tokens. | ✓ |
| Ajouter identifier malgré le bruit | Inclure identifier dans le format. Risque de UUID-like dans le prompt. À considérer si tu veux maximiser le signal pour des apps custom qui exposent des IDs sémantiques. | |
| Lecture on-demand dans predict path | Plus simple architecturalement mais paye le coût AX 2 fois (tick + predict). Risque PERF-01. | |

**User's choice:** OK pour D-15 (recommandé).
**Notes:**
- Identifier exclu (bruit > signal, validé Phase 1).
- Lecture via AXSnapshot étendu : coût TTFT zéro côté predict (snapshot déjà capté au tick 80ms en amont du debounce 50ms).
- Format annotation FR multi-lignes optionnelles, skip si tous attributs vides.
- Table mapping role/subrole → label FR à construire progressivement.

---

## previousUserInputs — migration du slot fewShot

| Option | Description | Selected |
|--------|-------------|----------|
| OK pour D-16 (recommandé) | Rename fewShot → previousUserInputs dans l'enum, dans build() param, et dans tests. Même logique Jaccard, même budget 80, même eviction priority. | ✓ |
| Garder fewShot tel quel (Alt B) | Considérer SLOT-04 déjà satisfait par Phase 1. Zéro refactor. On traine deux noms pour la même chose jusqu'à Phase 3. | |
| Refactor profond de SimilarHistoryRetrieval | Au-delà du rename : reshape l'API pour retourner des exemples bruts que le builder formatte. Plus invasif, sur-architecture pour cette phase. | |

**User's choice:** OK pour D-16 (recommandé).
**Notes:**
- Rename PromptSlot.fewShot → PromptSlot.previousUserInputs.
- SimilarHistoryRetrieval.buildExamplesBlock(...) inchangé (logique Jaccard préservée).
- Eviction priority et budget hérités.
- Impact production : zéro (flag dev-only, legacy path préservé).

---

## PERF-01 + escape PT/IT

| Option | Description | Selected |
|--------|-------------|----------|
| OK pour D-17 + D-18 (recommandé) | Instrumentation per-slot via Log.info count=ms, pas de bench refactor cette phase. PT maintenu, garde-fou explicite : si tally <6/12 + daily-use plat post-Phase-2 → rouvrir PT/IT avant Phase 3. | ✓ |
| D-17 OK, mais pivot IT dans Phase 2 | Inclure le switch vers IT model comme partie de Phase 2. Plus ambitieux, mais double l'incertitude (slots ET model en même temps). Plus difficile d'attribuer un gain ou une régression. | |
| Tout reporter en eyeball pur (pas d'instrumentation) | Zéro code de mesure, eyeball daily-use only. Moins de bruit, mais aveugle si une slot devient coûteuse silencieusement. | |
| Instrumenter SouffleuseBench dans la phase | Plus complet mais invasif (extraire predict path). Phase 1 SUMMARY l'avait flaggé hors scope cette phase. | |

**User's choice:** OK pour D-17 + D-18 (recommandé).
**Notes:**
- Instrumentation per-slot dans PromptBuilder.build() via Log.info(.predictor, "prompt_built", count: ms).
- Audit-safe (count whitelisted, pas de texte user).
- SouffleuseBench refactor reporté (milestone latence suivant, possible avec KV cache).
- PT maintenu en Phase 2 pour isoler l'évaluation des slots.
- Garde-fou D-18b verrouille la réouverture PT/IT avant Phase 3 si tally <6/12 ET daily-use plat post-Phase-2.

---

## Claude's Discretion

- Proportions exactes des budgets par slot (fieldContext=60, afterCursor=120, previousUserInputs=80) — ordres de grandeur fixés ; planner affine selon TTFT sweep.
- Re-calibration du `global` cap (Phase 1: 512). Nouveau sum estimé : 730. Bumper à 768/1024 vs accepter drops fréquents — à trancher en PLAN.
- `evictionPriority` complet pour Phase 2. Principe : drop d'abord replaceables (previousUserInputs, customInstructions), puis contextPrefix, puis garder le plus longtemps high-signal (fieldContext, afterCursor). beforeCursor head-truncate (jamais drop), system last-resort.
- Format exact de l'instrumentation log (single event "prompt_built" avec count total vs event par slot) — planner.
- Table de mapping role/subrole → label FR (extension progressive).
- Enrichissement potentiel des scénarios `--replay` avec cas mid-field/cursor-in-middle pour mieux tester afterCursor — planner décide.

## Deferred Ideas

- Pivot PT → IT model (D-18b : réouverture conditionnelle avant Phase 3).
- Refactor profond de SimilarHistoryRetrieval (D-16c écarté comme over-engineering).
- Instrumentation TTFT end-to-end via SouffleuseBench refactor (milestone latence suivant).
- Slot-level instrumentation TTFT plus granulaire (timing par AX read).
- Refactor ContextEnricher en slots indépendants (Phase 3).
- Enrichissement scénarios --replay mid-typing.
- Table mapping role/subrole exhaustive.
- Heuristiques auto verdict A/B (hors scope, déjà deferred Phase 1).
- LLM-as-judge externe (privacy invariant).
- Retrait feature flag legacy (conditionnel à verdict positif, deferred jusqu'à Phase 2 ou 3 fin).
