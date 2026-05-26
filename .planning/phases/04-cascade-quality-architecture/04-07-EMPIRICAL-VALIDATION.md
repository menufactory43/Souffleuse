# 04-07 Empirical Validation

**Date** : 2026-05-26
**Build commit** : `af8b5cc` (docs(04-06): complete dual-path ModelRuntime.generate migration plan)
**Tester** : project owner

## Sessions

### Session 1 — Flag ON (new ModelRuntime path)

```bash
SOUFFLEUSE_USE_MODEL_RUNTIME=1 open Souffleuse.app
```

**Observations** :
- Ghost fonctionne (pas de crash, pas d'hang, pas d'absence de suggestion en contexte attendu)
- Surconsommation perçue de few-shots / cache (suggestions semblent trop "memorisées" plutôt que "génératives")

### Session 2 — Flag OFF (legacy path baseline)

```bash
open Souffleuse.app  # no env var
```

**Observations** :
- Comportement identique à session 1 sur la surconsommation cache/few-shots
- Aucune différence perceptible vs session 1 sur les autres dimensions (TTFT, relevance baseline, pas de "Coucou !" syndrome)

## Verdict

**PASS** — runtime path subjectively equivalent to legacy.

Le concern cache/few-shots surconsommation est **path-independent** : il se reproduit identiquement sur les deux paths. La logique concernée (cascade routing, cache lookup, `SimilarHistoryRetrieval` few-shot retrieval) vit dans `PredictorViewModel.predict_*` et `CompletionCache`, en amont du `container.perform` body migré dans 04-06. Le split D-03 n'affecte pas cette logique.

## Suivi

- Concern cache/few-shots à diagnostiquer dans un plan séparé (probablement post-phase 04, comme follow-up jalon).
- 04-07 cleanup procède : retrait du flag `SOUFFLEUSE_USE_MODEL_RUNTIME`, suppression de `predict_legacy`, inline de `predict_new` → `predict`, dedup des helpers (OutputFilter, buildSystemPrompt, detectLanguage, CacheBox, StreamMetrics) qui restent dupliqués dans PVM depuis 04-05.

## Next action

→ Proceed to Task 2 cleanup of 04-07.
