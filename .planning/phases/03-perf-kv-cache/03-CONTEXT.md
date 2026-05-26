---
phase: 03-perf-kv-cache
type: phase-context
created: 2026-05-25
status: ready-for-plan-phase
parent_discovery: ../../kv-cache-discovery.md
locks_in_from_session: 2026-05-25-debug-session
---

# Phase 03 — Perf debt: KV cache MLX

## Phase Goal

Diviser le TTFT inline-autocomplete par **~5×** (de ~700-1000ms à ~120-180ms estimé) en implémentant la réutilisation cross-keystroke du KV cache MLX dans `PredictorViewModel`. Une fois ce gain en place, le `cancel-on-keystroke` cessera d'étrangler 94% des streams, et la perception "ghost qui n'arrive jamais" disparaîtra.

C'est une **phase de dette technique intercalaire** entre Phase 02 (high-signal slots, livrée) et l'ancienne Phase 03 (Optional Sources + Parity Verdict, qui devient Phase 04). Justification : sans KV cache, le verdict de parité Cotypist (success criterion #3 de l'ex-Phase 3) n'est pas mesurable — toute évaluation qualité est masquée par la latence.

## Core Value

**Le ghost doit apparaître DANS la fenêtre perceptuelle de la frappe suivante**, pas après. Aujourd'hui, le user tape "Bonjour " et il faut attendre 700-1000ms avant qu'un ghost apparaisse — si la prochaine frappe survient dans cet intervalle (typique : ~150ms inter-keystroke), le stream est tué avant production. Avec KV cache : ~120-180ms TTFT cible → le stream survit à la majorité des frappes.

## What Was Just Done (Session 2026-05-25)

Cette phase est posée après une session debug intense qui a livré 8 commits de **perf + bug fixes** ciblant les symptômes du TTFT élevé, sans toucher au runtime modèle :

| Commit | Effet mesuré |
|---|---|
| `e56fdd2` | `MemoizingTokenCounter` — prompt build p50 312 → 44 ms (−86%) |
| `4ef9490` | `02-VERIFICATION.md` PERF-01 signée avec données réelles |
| `64bd4fb` | `CompletionLength.medium.maxTokens` 6 → 4 (parité Cotypist Free) |
| `4d1c18e` | Ajout `mlx-community/gemma-3-1b-pt-6bit` au catalogue (équivalent Q5_K_M imatrix Cotypist) |
| `5a843b0` | `ghostIsRepeatingPrefix` `.contains` → `.hasSuffix` (drop 87% → 1.1%) + cache invalidation context-aware |
| `edd60b1` | `gate_first_word` retiré (Phase 2 fieldContext groundé le mid-word) + `SimilarHistoryRetrieval` Jaccard floor 0.1 |
| `51b383a` | Debounce predict 50 → 150ms (calibration temporaire en attendant ce KV cache) |
| `7bac93d` | `.planning/kv-cache-discovery.md` — plan technique 5 étapes (cette phase) |

**État actuel mesuré post-fixes (session 2026-05-25 13:00-13:10) :**

- `prompt_build_ms` : p50 ≈ 47 ms (avant memoize : 312 ms)
- `ghost_dropped_repeat` : 1.1% (avant fix : 87%)
- `prompt_built` → `llm_done_stored` completion rate : **5.8%** (149/654 → 38/654)
- TTFT modèle pur observé : **544-1056 ms**
- `cache_invalidate_context` : fonctionne (4 fires confirmés sur switch d'app)

**Tous les "symptômes" sont attaqués. Le bottleneck restant est l'inférence MLX elle-même.**

## What This Phase Tackles

1. **Persister le `[KVCache]` entre predicts** au lieu de le recréer à chaque appel
2. **Extension incrémentale** quand l'user étend `beforeCursor` (cas dominant — 90%+ du flow)
3. **Trim sur backspace** quand `beforeCursor` raccourcit
4. **Invalidation context-aware** quand la "prefix invariante" (system + customInstructions + contextPrefix + fieldContext + afterCursor + previousUserInputs) change
5. **Instrumentation** : `kv_cache_extend` / `kv_cache_trim` / `kv_cache_invalidate` (count-only, audit-safe)
6. **Rollback path** : env var `SOUFFLEUSE_DISABLE_KV_CACHE=1` pour bypass d'urgence
7. **Mesure** : reproduire le bench `prompt_build_ms` post-implémentation + comparer side-by-side replay 15 scénarios pour vérifier TTFT chute

## Reference Material

- **Discovery technique complète** : `.planning/kv-cache-discovery.md` (186 lignes — lire EN PREMIER)
- **API MLX à utiliser** :
  - `Souffleuse/build/SourcePackages/checkouts/mlx-swift-examples/Libraries/MLXLMCommon/KVCache.swift`
  - `Souffleuse/build/SourcePackages/checkouts/mlx-swift-examples/Libraries/MLXLMCommon/Evaluate.swift` (TokenIterator)
- **Call sites actuels à modifier** :
  - `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift:988` (personalization TokenIterator path)
  - `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift:999` (stock generate path)
- **Architecture comparée Cotypist** : analyse complète dans le commit `7bac93d` discovery note section "API publique vérifiée"

## Key Decisions (locked in)

| # | Décision | Rationale |
|---|---|---|
| **D-KV-01** | Cache type = `RotatingKVCache` (via `model.newCache(parameters:)`) | Gemma 3 a SWA — `KVCacheSimple` casserait les couches global/sliding interleaved. Délégué au model pour qu'il choisisse correctement. |
| **D-KV-02** | Granularité d'invalidation = fingerprint hash des slots invariants | Computer un fingerprint stable (md5/SHA des `system|customInstructions|contextPrefix|fieldContext|afterCursor|previousUserInputs`). N'importe lequel change → invalidate complet. |
| **D-KV-03** | `beforeCursor` est traité comme "extension token-incrémentale" | C'est le seul slot qui change keystroke par keystroke. Toute autre mutation = invalidation. |
| **D-KV-04** | `previousUserInputs` change = invalidation | Quand l'user accepte un Tab, le retrieval Jaccard peut produire un block différent au predict suivant. Plus simple que d'isoler le few-shot dans un sous-cache. |
| **D-KV-05** | Pas d'invalidation sur changement `textAfterCaret` ou `windowTitle` | Ces fields changent trop souvent. `textAfterCaret` est dans `afterCursor` slot → SI le slot body change, fingerprint change, on invalide. Mais on n'observe pas le raw field. |
| **D-KV-06** | Rollback env var `SOUFFLEUSE_DISABLE_KV_CACHE` | Sécurité production. Si le cache cause un comportement bizarre, l'utilisateur peut désactiver sans rebuild. |
| **D-KV-07** | Pas de persistence cross-launch | `savePromptCache(...)` existe mais hors scope. Le cache est rebuild à chaque lancement de l'app — coût acceptable une fois par session. |
| **D-KV-08** | Pas de TDD strict — tests post-implémentation sur la logique pure (decision tree, fingerprint) | Le KV cache lui-même est testé par MLX upstream. Notre job = correct orchestration. Tests sur les helpers déterministes (mock KVCache via protocol) suffisent. |

## Constraints

- **Tech stack** : Swift 6 strict concurrency, MLX, AppKit. Aucun changement de stack.
- **No breakage** : 109 tests doivent rester verts. `audit.sh` 6/6 ✓. Le PromptBuilder, MemoizingTokenCounter, et l'ensemble de la stack Phase 2 ne changent pas.
- **Privacy invariants** : nouveaux events log `kv_cache_*` count-only via `StaticString`. Aucune fuite user-text.
- **Compatibility** : macOS 14+ Apple Silicon. Pas de changement.
- **MLX dependency** : `mlx-swift-examples` 2.29.1 — l'API utilisée (`makePromptCache`, `RotatingKVCache`, `TokenIterator(cache:)`, `trimPromptCache`) est stable. Pas de bump de version requis.
- **Memory budget** : le KV cache cumule en RAM (estimé ~50-100 MB pour 200 tokens × 26 couches × 1024 hidden dim × fp16). On reste très en dessous du `MLX.GPU.cacheLimit = 20 * 1024 * 1024` actuel — si problème, augmenter à 100 MB.

## Success Criteria

1. **TTFT chute mesurable** : reproduire la mesure session du 2026-05-25 → cible **p50 ≤ 300ms** (vs 700-1000ms baseline). Stretch : p50 ≤ 200ms.
2. **Stream completion rate ↑** : ratio `llm_done_stored / predict_called` passe de 5.8% à ≥ **30%** sur typing soutenu (cible stretch : 50%).
3. **`prompt_build_ms` non régressé** : le memoize cache ne se casse pas — p50 reste ≤ 60ms.
4. **109 tests + audit.sh verts** : zéro régression.
5. **Replay 15 scénarios** : re-run de `SouffleuseCoherence --replay ../01-foundation-hypothesis-validation/replay-scenarios.json --out ./REPLAY-RESULTS-WITH-KV.md` → comparer ghost outputs avec/sans KV cache pour vérifier l'identité fonctionnelle (le KV cache n'est qu'une optim, les outputs DOIVENT être identiques à epsilon de greedy near).
6. **Env var bypass fonctionne** : `SOUFFLEUSE_DISABLE_KV_CACHE=1` désactive le cache et reproduit le comportement d'aujourd'hui (régression contrôle).

## Out-of-Scope (deferred to Phase 04 or beyond)

- **Persistence cross-launch** (`savePromptCache`) — savings minimal, complexity élevée
- **Quantized KV cache** (`QuantizedKVCache`) — gain RAM, pas latency, hors enjeu
- **Speculative decoding** — différent milestone
- **Switch llama.cpp** — pas la peine si MLX KV cache marche (cf. discovery note)
- **Phase 04 work** : `clipboardContext`, `screenContext`, parity verdict subjectif — repris à l'identique de l'ex-Phase 3

## Migration de la roadmap

L'ancienne `Phase 3: Optional Sources + Parity Verdict` est renumérotée **Phase 4**. Justification : sans KV cache, le success criterion #3 (verdict side-by-side vs Cotypist) n'est pas mesurable parce que la latence masque la qualité. Inverser l'ordre n'aurait pas de sens. Cette phase 03 est donc une dette intercalaire.

## Next Command After Clear

```
/gsd-plan-phase 03
```

L'orchestrateur lira automatiquement ce CONTEXT.md + le discovery note pour produire 5 plans alignés sur les étapes décrites dans `.planning/kv-cache-discovery.md` §"Plan d'implémentation par étapes".
