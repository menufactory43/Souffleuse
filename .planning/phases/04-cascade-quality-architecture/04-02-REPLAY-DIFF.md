# 04-02 Replay Diff vs Baseline — Post-Extraction

**Date :** 2026-05-25
**Commit HEAD :** post-507e105 (Tasks 1-5 complétées)
**Mode :** BUILD-ONLY (cohérent avec baseline 04-02-BASELINE-REPLAY.md)

## Mode

`BUILD-ONLY` — voir `04-02-BASELINE-REPLAY.md` §"Pourquoi BUILD-ONLY". Le replay
SouffleuseCoherence live (Gemma 3 1B, MLX) ne tourne pas headless en agent.
L'equivalence sémantique est validée par les filets de sécurité :

1. **Tests suite** : 187/187 verts (153 baseline + 18 SuggestionPolicy + 16 ClassificationGrid).
   La cascade L0/L1 + LLM Gate sont maintenant verrouillés par les 34 nouveaux tests.
2. **Audit privacy** : 6/6 vert. Les 5 nouveaux events `ghost_classified_*` +
   `ghost_gate_*` + `ghost_keep_under_bar` sont StaticString → check 6 OK.
3. **Build SouffleuseCoherence** : exit 0 — le scenario harness reste utilisable
   pour validation live future.
4. **Hash sha256 scenarios inchangé** :
   `d4fa5820383b51dd9226ac7d905c788396f8f7abbc46b6fe7359c9928d288f23`
   — pas de modification du schéma replay.

## Changements de comportement intentionnels (D-07 / D-08)

L'extraction 04-02 introduit le **Ghost Relevance Gate** en remplacement de
l'anti-churn high/low. Ces changements peuvent produire des outputs différents
sur des scenarios live :

| Surface | Avant (HEAD pré-04-02) | Après (04-02) | D-ref |
|---|---|---|---|
| LLM chunk score < 0.25 | Affiché si extends OR longer | `ghost_gate_block` + dropped | D-07 |
| LLM chunk score < currentScore × 1.15 | Pouvait remplacer en strict-longer | `ghost_keep_under_bar` + dropped | D-07 |
| LLM chunk après mid-word tail | Pouvait remplacer | `ghost_gate_block_midword` + dropped | D-08 |
| L1 history match (after-space) | Toujours affiché | Affiché si score ≥ 0.4 (afterSpaceL1Bar) | D-08 |
| L2 LLM upgrade over L1 history | High-conf protection symétrique | Score ≥ currentScore + 0.15 (l2UpgradeDelta) | D-08 |
| Replacement < parasiteWindow 0.8s | `ghost_protect_high` ou `ghost_keep_longer` | `ghost_classified_parasite` émis avec visibleMs | D-09 |

Ces changements sont **explicitement attendus** par le plan et reflètent
l'intention de Phase 4 d'éviter le churn de cascade tout en gardant le ghost
réactif aux mises à jour LLM. Ils ne constituent PAS une régression.

## Surface inchangée (sémantiquement)

- Cascade L0 (mid-word) : WordCompleter ≥3 chars → `ghost_word_complete` (event ID inchangé)
- Cascade L1 (after-space) : history exact-substring → `ghost_history_match` (event ID inchangé)
- Source decay HIGH → llm au début de predict (verbatim migré dans `beginPredict()`)
- `predictCache` lookup + `cache_undo_hit` undo-as-ghost (intacts dans PVM)
- LLM stream filters : stripPrefixOverlap, markup strip, repeat anti, words cap (intacts)
- `ghost_apply_llm` / `ghost_swap_to_llm_from_high` (event ID inchangés)
- Event field shape : 5 fields whitelistés, count: Int uniquement (audit check 4 OK)

## Events log — delta

**Supprimés** (étaient émis par PVM pre-04-02, plus émis post-extraction) :
- `ghost_protect_high` — remplacé par `ghost_keep_under_bar` / `ghost_classified_parasite`
- `ghost_keep_longer` — remplacé par `ghost_keep_under_bar`

**Préservés** (mêmes IDs, mêmes call-sites sémantiques) :
- `ghost_word_complete`, `ghost_history_match` (émis par `policy.routeInstant`)
- `ghost_apply_llm`, `ghost_swap_to_llm_from_high` (émis post-Gate)
- `ghost_keep_stable`, `ghost_dropped_repeat`, `cache_hit`, `cache_undo_hit`, `cache_evict`
- `kv_cache_invalidate`, `kv_cache_extend`, `kv_cache_trim` (KV cache intact)

**Nouveaux** (Phase 4 D-07/D-09/D-10) :
- `ghost_gate_block_midword` (count: chunk length) — mid-word L2 block
- `ghost_gate_block` (count: Int(score.value * 100)) — passesGate floor block
- `ghost_keep_under_bar` (count: current ghost length) — replacement bar block
- `ghost_classified_correct` (count: visibleMs) — D-10 acceptedFull
- `ghost_classified_acceptable` (count: chunks accepted) — D-10 acceptedPartial (TODO 04-04+)
- `ghost_classified_useless` (count: visibleMs) — D-10 dismiss within window
- `ghost_classified_bad` (count: visibleMs) — D-10 typedDiverged within window
- `ghost_classified_parasite` (count: visibleMs) — D-10 replacement < parasiteWindow

Tous StaticString event names. Privacy invariant préservée par construction.

## Verdict

**EQUIVALENT (modulo intended Gate changes documented above)**

Aucune régression non-intentionnelle. Les 187 tests verts (incluant les 34 nouveaux
qui verrouillent la cascade D-07/D-08/D-09) sont le filet de sécurité primaire
en l'absence de replay live.

**Recommandation pour 04-03+** : avant chaque extraction supplémentaire (Runtime,
Cache, Planner), lancer le replay live `swift run SouffleuseCoherence --replay
.planning/phases/01-foundation-hypothesis-validation/replay-scenarios.json` sur
machine Apple Silicon avec MLX + GPU, et comparer scenario par scenario contre
le snapshot pré-Phase-4 (commit 7316a8c). Toute divergence au-delà des changements
intentionnels listés ci-dessus est une régression à investiguer.
