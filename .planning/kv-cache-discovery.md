---
type: discovery-note
phase: pre-phase-03
date: 2026-05-25
status: feasibility-confirmed
---

# KV Cache MLX — Discovery + Implementation Plan

## TL;DR

**MLX expose une API KV cache complète et production-ready dans `MLXLMCommon`.** L'intégration est faisable sans switch llama.cpp. Effort estimé : **3-5 jours focus** dans une phase dédiée. Gain attendu sur TTFT : **~700-1000ms → ~100-200ms** sur Gemma 3 1B 6-bit Apple Silicon.

## API publique vérifiée

Source : `Souffleuse/build/SourcePackages/checkouts/mlx-swift-examples/Libraries/MLXLMCommon/`

| Symbole | Rôle | Notes |
|---|---|---|
| `protocol KVCache: Evaluatable` | Interface | `var offset: Int` + `func trim(_ n: Int) -> Int` + `var isTrimmable: Bool` |
| `class KVCacheSimple` | Cache full attention | Suffisant pour la plupart des modèles |
| `class RotatingKVCache` | Cache **sliding window attention** | **Requis pour Gemma 3** (cf. GGUF metadata `gemma3.attention.sliding_window`) |
| `class QuantizedKVCache` | Cache compressé | Économise RAM, perf neutre |
| `class ChunkedKVCache` | Cache prefill par chunks | Pour prompts longs |
| `func makePromptCache(model:, parameters:)` | Factory | Délègue à `model.newCache(parameters:)` qui choisit le bon type SWA si applicable |
| `func canTrimPromptCache(_)` | Pré-condition | `cache.allSatisfy { $0.isTrimmable }` |
| `func trimPromptCache(_, numTokens:)` | Trim in-place | Retourne le nombre réel de tokens retirés |
| `TokenIterator(input:model:cache:processor:sampler:maxTokens:)` | Constructeur public | **Accepte le cache externe** — c'est notre point d'entrée |
| `TokenIterator.cache: [KVCache]` | Field public mutable | Permet de lire/écrire le cache entre appels |
| `TokenIterator.prepare(input:windowSize:)` | Prefill | Push les tokens de prefix dans le cache |

## Modèle conceptuel

Le KV cache stocke les "keys" et "values" déjà calculés des couches d'attention pour les tokens du prompt. Sans cache, chaque predict re-fait le prefill complet (200 tokens × N couches × calculs Q·K·V) → ~500ms d'overhead avant le 1er token de génération. Avec cache, seuls les tokens nouveaux (1-3 par keystroke en streaming inline) sont prefillés → quasi-zéro overhead.

Pour Souffleuse :
- **Avant** : chaque predict = prefill complet de [system + customInstructions + contextPrefix + fieldContext + afterCursor + previousUserInputs + beforeCursor]
- **Après** : prefill une fois la "prefix invariante" (slots Phase 2 + system + previousUserInputs) au début d'une session de typing dans un champ, puis incrémentalement seul `beforeCursor` étend le cache

## Conditions d'invalidation

Le cache n'est valide que si **toute la partie du prompt BEFORE beforeCursor n'a pas changé**. Donc :

| Évent | Action sur cache |
|---|---|
| User tape un caractère (beforeCursor étend) | **EXTEND** (prefill 1-3 nouveaux tokens) |
| User tape un mot (beforeCursor étend ~5 tokens) | **EXTEND** |
| User backspace (beforeCursor shrinks) | **TRIM** par `len(old) - len(new)` |
| User accepte Tab (beforeCursor étend par le ghost) | **EXTEND** ou refresh |
| User switch app (bundleID change → fieldContext change) | **INVALIDATE + rebuild** |
| User change de champ (placeholder/help/role change) | **INVALIDATE + rebuild** |
| User change `customInstructions` (Prefs) | **INVALIDATE + rebuild** |
| User change modèle (swapModel) | **INVALIDATE + rebuild** (déjà géré par `swapModel`) |
| Phase 2 `previousUserInputs` change (nouvelle acceptation Tab → new few-shot retrieval) | **INVALIDATE + rebuild** |

Le dernier point est nuancé : `previousUserInputs` est reconstruit à chaque predict via `SimilarHistoryRetrieval`. Si la même `userTail` produit le même `examplesBlock`, le cache reste valide. Sinon, il faut invalider. Pratique simple : fingerprinter le bloc few-shot et invalider si différent du dernier.

## Architecture proposée

### Nouveau state dans `PredictorViewModel`

```swift
/// Active KV cache for the current "session" within a field. Lazily created
/// on the first predict and rebuilt whenever any part of the prompt BEFORE
/// `beforeCursor` changes. nil means "cold — rebuild on next predict".
private var sessionCache: [KVCache]?

/// Snapshot of the prompt prefix (everything before beforeCursor) that
/// sessionCache currently corresponds to. Used to detect invalidation
/// vs. extension.
private var sessionPrefixFingerprint: String?

/// Token count of beforeCursor that sessionCache has prefilled. Lets us
/// compute the delta to extend (or the count to trim on backspace).
private var sessionBeforeCursorTokens: Int = 0
```

### Decision tree par predict

```
let newPrefixFP = hash(system + customInstructions + contextPrefix
                     + fieldContext + afterCursor + previousUserInputs)
let newBeforeTokens = tokenize(beforeCursor)

if sessionCache == nil || sessionPrefixFingerprint != newPrefixFP:
    # cold or invariant changed → full rebuild
    sessionCache = makePromptCache(model: model, parameters: params)
    sessionPrefixFingerprint = newPrefixFP
    sessionBeforeCursorTokens = 0
    # prefill the full prefix
    input = invariantPrefix + beforeCursor
else if newBeforeTokens.starts_with(oldBeforeTokens):
    # extension: prefill only the new suffix
    deltaTokens = newBeforeTokens.dropFirst(sessionBeforeCursorTokens)
    input = deltaTokens  # TokenIterator.prepare will extend the cache
    sessionBeforeCursorTokens = newBeforeTokens.count
else if oldBeforeTokens.starts_with(newBeforeTokens):
    # backspace: trim cache by the diff
    diff = sessionBeforeCursorTokens - newBeforeTokens.count
    trimPromptCache(sessionCache!, numTokens: diff)
    sessionBeforeCursorTokens = newBeforeTokens.count
    input = []  # nothing to prefill, generation starts from current cache state
else:
    # divergent beforeCursor (user navigated mid-text, pasted, etc.)
    # → invalidate the beforeCursor portion via trim back to 0, rebuild
    trimPromptCache(sessionCache!, numTokens: sessionBeforeCursorTokens)
    sessionBeforeCursorTokens = 0
    input = newBeforeTokens  # treat as fresh extension
    
# Now spawn TokenIterator with the cache
iterator = TokenIterator(
    input: input,
    model: model,
    cache: sessionCache!,    # ← the key change vs current code
    processor: ...,
    sampler: ...,
    maxTokens: maxTokens
)
```

### Sub-cases à gérer

1. **First predict of a session** : `sessionCache == nil`. Build cache via `makePromptCache(model:, parameters:)`. Prefill `invariantPrefix + beforeCursor`. Track all state.
2. **Pure type-extension** : majorité du flow steady-state typing. Delta de 1-3 tokens. C'est le cas qui paye 95% du ROI.
3. **Backspace** : trim par le delta exact en tokens. `RotatingKVCache.isTrimmable` doit retourner true (à vérifier — peut-être faux selon la config SWA).
4. **Big paste / cursor jump** : la nouvelle beforeCursor n'a aucun prefix commun avec l'ancienne. Trim total + treat as fresh prefill. C'est OK, on est juste back à la perf actuelle (full rebuild).
5. **App switch + retour** : on perd le cache pendant l'absence (autre app) puis on le reconstruit à la première frappe dans l'app d'origine. Acceptable.

## Plan d'implémentation par étapes

### Étape 1 — Plumberie minimale (1j)

- Ajouter les 3 nouveaux `var` au PredictorViewModel
- Modifier les deux call-sites à `TokenIterator(...)` pour passer `cache:`
- Initialiser `sessionCache` lazily au premier predict via `makePromptCache(...)`
- Invalidation grossière : reset complet sur tout changement de `bundleID`
- Pas encore d'extension incrémentale — chaque predict reconstruit, mais via l'API cache (sanity check : ça doit marcher comme avant)
- **Verdict gate** : `swift test` 109/109 + audit.sh ✓

### Étape 2 — Extension incrémentale (1-2j)

- Tracker `sessionBeforeCursorTokens` et computer le delta tokens à chaque predict
- Implémenter le decision tree (starts_with check)
- Quand delta détecté : ne prefill QUE le delta dans `TokenIterator.prepare`
- **Verdict gate** : `prompt_build_ms` reste OK + nouveau event `kv_cache_extend` count-only + observe TTFT real-world drop

### Étape 3 — Backspace trim (1j)

- Implémenter le path "old.startsWith(new) → trim by diff"
- Vérifier `RotatingKVCache.isTrimmable` (Gemma 3 SWA peut être trim-restrictive — à valider empiriquement)
- Fallback : si `canTrimPromptCache` false → invalidate complet
- Event `kv_cache_trim` count-only

### Étape 4 — Invalidation context-aware (0.5j)

- Computer le `prefixFingerprint` hash (md5 ou simple String join) à chaque predict
- Invalider quand fingerprint change : bundleID, role, subrole, placeholder, help, customInstructions, fewshot block
- Event `kv_cache_invalidate` count-only

### Étape 5 — Tests + verification (0.5j)

- Tests unitaires pour le decision tree (mock KVCache via protocole)
- Mesurer empiriquement le gain TTFT (avant/après sur les mêmes 15 scénarios replay)
- Mettre à jour `02-VERIFICATION.md` PERF-01 section avec les nouvelles métriques
- Documenter le rollback path (`SOUFFLEUSE_DISABLE_KV_CACHE=1` env var pour bypass d'urgence)

## Risques identifiés

| Risque | Probabilité | Mitigation |
|---|---|---|
| `RotatingKVCache` ne supporte pas le trim sur Gemma SWA | Moyenne | Fallback : invalider full sur backspace (perf identique à aujourd'hui sur cette path précise) |
| Memory growth si cache trim incomplet → fuite GPU | Faible | `maxKVSize` cap dans GenerateParameters + reset périodique forcé |
| Tokenization du delta diverge de la tokenization du whole (sentencepiece edge cases) | Moyenne | Toujours retokenize `invariantPrefix + beforeCursor` complet pour fingerprint, comparer aux tokens prefillés. Si mismatch → invalidate. |
| Le cache cumule entre apps malgré l'invalidation | Faible | Tests unitaires sur le decision tree + log assertions |
| MLX bug edge sur cache reuse (e.g. crash Metal observé tout à l'heure) | Faible-Moyenne | Garder l'env var bypass + un crash counter qui désactive auto le KV cache pour la session si MTLReportFailure |

## Verdict

L'API est mûre. L'archi est faisable. Le seul work est la Swift orchestration côté nous. **Le KV cache MLX n'est pas un saut dans l'inconnu — c'est du plumbing assez direct sur une API publique stable.**

Estimation totale **3-5 jours** focus si on attaque dans une phase dédiée GSD :
- 0.5j discuss-phase + plan-phase (clarifier les invariants, choisir entre RotatingKVCache vs KVCacheSimple)
- 3-4j execute-phase (5 plans selon le découpage ci-dessus)
- 0.5j verify-phase + perf benchmark

C'est exactement la taille typique d'une phase 03 ou phase intercalaire "perf-debt".
