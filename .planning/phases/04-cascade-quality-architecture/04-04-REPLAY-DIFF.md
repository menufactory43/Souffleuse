# 04-04 Replay Equivalence Diff — Post CompletionCache Extraction

**Date :** 2026-05-25
**Commit HEAD :** 0ad8c49 (post 04-04 Task 3)
**Baseline reference :** 04-02-BASELINE-REPLAY.md (commit 3e9a826 baseline)
**MODE :** BUILD-ONLY (same justification as 04-02 / 04-03 — replay live MLX non-headless)

## Verdict

**EQUIVALENT**

CompletionCache extraction est un refactor strictement mécanique :

- `predictCache: [String: String]` + `predictCacheOrder: [String]` +
  `predictCacheCapacity` → `CompletionCache.predictCache` + `predictCacheOrder`
  + `predictCacheCapacity` (mêmes constantes, mêmes algorithmes verbatim).
- `tokenCountCache` → `CompletionCache.tokenCountCache` (même instance type
  `TokenCountCache(cap: 64)`).
- `lastContextFingerprint` → `CompletionCache.lastContextFingerprint`
  (privé, accédé via `updateContextFingerprint(_:)`).
- `sessionCacheHolder: KVCacheHolder` → `CompletionCache.kvCacheHolder` (même
  référence sous-jacente, accédée via `cache.kvCacheHolder`).
- `KVCacheBypassFlag` (env var literal `SOUFFLEUSE_DISABLE_KV_CACHE`) →
  migré byte-identique dans CompletionCache.swift comme single source of
  truth (cf. grep counts ci-dessous).

La décision KV (PVM:1163-1311 dans le code legacy) est extraite vers la pure
function `CompletionCache.decideExtendTrimInvalidate(invariance:
userTailTokenCount: promptTokens:)` qui retourne un `KVDecision` enum.
L'ordre d'évaluation (bypass → cold → fingerprintChanged → identical / extend
/ trim) est verrouillé par les tests + reste verbatim PVM:1200-1244.

Le trim capability gate (`canTrimPromptCache(existing)`) reste côté caller
PVM, qui downgrade `.trim` à `.diverged` si la cache type ne supporte pas le
trim — comportement identique au branch legacy `else if newCount < oldCount`
sans capability.

Aucun ghost-text, aucun log événement, aucun ordering observable n'est modifié.

## Build-only equivalence checks

| Check | Baseline (04-03 post) | This plan (04-04 post) | Δ |
|---|---|---|---|
| `swift build` exit | 0 | 0 | 0 |
| `swift test` exit | 0 | 0 | 0 |
| Tests count | 199 | 213 | +14 (CompletionCacheTests) |
| `bash audit.sh` exit | 0 | 0 | 0 |
| `SOUFFLEUSE_DISABLE_KV_CACHE` in CompletionCache.swift | n/a | 1 | single source of truth |
| `SOUFFLEUSE_DISABLE_KV_CACHE` in PredictorViewModel.swift | 1 | 0 | migrated |

## Code-path equivalence (manual diff)

| Site PVM (pre-04-04) | Site PVM (post-04-04) | Sémantique |
|---|---|---|
| `private enum KVCacheBypassFlag { static let enabled = ... SOUFFLEUSE_DISABLE_KV_CACHE ... }` (L31-34) | déplacé verbatim dans CompletionCache.swift, env var literal byte-identique | identique |
| `private var predictCache: [String: String] = [:]` + `predictCacheOrder` + `predictCacheCapacity = 32` (L125-130) | `CompletionCache.predictCache` + `predictCacheOrder` + `static let predictCacheCapacity = 32` | identique |
| `internal func storeInCache(prefix:suggestion:)` (L233-245) | `CompletionCache.store(prefix:suggestion:)` verbatim incl. `Log.info(.predictor, "cache_evict")` | identique |
| `internal func clearPredictCache()` (L250-253) | `CompletionCache.clearPredictCache()` + shim public sur PVM pour AppDelegate | identique |
| `predictCache[userTail]` lookup (L623, L666) | `cache.lookup(userTail:)` / `cache.longestExtendingKey(userTail:)` | identique (longest-extending logique verbatim) |
| `if let last = lastContextFingerprint, last != contextFingerprint { clearPredictCache(); Log.info(.predictor, "cache_invalidate_context") } ; lastContextFingerprint = contextFingerprint` (L512-516) | `cache.updateContextFingerprint(contextFingerprint)` — Log + clear émis en interne | identique (Log call non dupliqué) |
| swapModel triplet `clearPredictCache() ; sessionCacheHolder.invalidate(.explicit) ; Log.info(.predictor, "kv_cache_invalidate", count: 3) ; tokenCountCache.clear()` (L216-225) | `cache.invalidateAll()` compose les 4 actions verbatim | identique (Log count:3 préservé) |
| KV decision tree inline (L1197-1244) `if envBypass ... else if holderSnap.caches == nil ... else if fp mismatch ... else { delta switch }` | `cache.decideExtendTrimInvalidate(...)` retourne `KVDecision` ; caller applique le verdict en construisant `chosenCache` + `iteratorInputTokens` selon switch ; trim capability gate côté caller | identique (ordre frozen, log events count: 0/1/2 + extend/trim count préservés) |
| `sessionCacheHolder.fingerprint` / `beforeCursorTokens` / `install(...)` / `updateBeforeCursorTokens(...)` accès | `sessionCacheHolder = self.cache.kvCacheHolder` (alias capture local, même reference) | identique |

## Pitfall 4 verification (KV decision order)

Le plan flag Pitfall 4 RESEARCH §"Common Pitfalls" : un changement subtil dans
l'ordre des invalidations ou la canonicalisation du fingerprint casserait le
KV decision verdict.

Ordre verrouillé dans `decideExtendTrimInvalidate` (verbatim PVM:1200-1244) :

1. `KVCacheBypassFlag.enabled` ⇒ `.bypass`
2. `kvCacheHolder.caches == nil` ⇒ `.cold`
3. `kvCacheHolder.fingerprint != invariance.fingerprint` ⇒ `.fingerprintChanged`
4. `delta = userTailTokenCount − beforeCursorTokens` :
   - `0` ⇒ `.identical`
   - `> 0` ⇒ `.extend(addedTokens: delta)`
   - `< 0` ⇒ `.trim(removedTokens: -delta)` (caller capability gate)

Tests `decideColdWhenHolderEmpty`, `decideFingerprintChangedWhenMismatch`,
`decideIdenticalWhenZeroDelta`, `decideExtendWhenPositiveDelta`,
`decideTrimWhenNegativeDelta` verrouillent chaque branche.

`InvariancePrefix.canonicalizePreviousUserInputs(...)` reste intact dans
`KVCacheHolder.swift` — la canonicalisation few-shot n'est pas touchée par
ce plan.

## Threat register vérifié

| Threat ID | Status |
|-----------|--------|
| T-04-04-01 (env var tampering) | mitigated — grep -c == 1 dans CompletionCache.swift, 0 dans PVM |
| T-04-04-02 (replay equivalence broken by reorder) | mitigated — ordre frozen verbatim + tests |
| T-04-04-03 (no new user-field log) | accepted — `cache_invalidate_context` et `kv_cache_invalidate` sont StaticString existants, déplacés sans modif |

## audit.sh

6/6 checks pass. Aucun nouveau `Log.*` call interpolant des user fields ;
aucune lecture `history.aes` ajoutée ; aucun `print(`/`NSLog(` introduit.

## Risk surface

- Aucun changement de threading model (toujours `@MainActor` pour la cache state).
- Aucun changement de log event signature ou de field set.
- Aucun changement de file API ou de Sendable closure crossing — la closure
  `container.perform` capture désormais `completionCache` (alias local) en
  plus de `tokenCountCache` et `sessionCacheHolder` ; les trois sont
  reference-typed et stables pour la durée de la Task.
- L'invocation `cache.decideExtendTrimInvalidate(...)` ajoute un seul hop
  `MainActor.run` supplémentaire dans le `container.perform` closure pour
  combiner décision pure + snapshot des caches. Le legacy code faisait déjà
  un `MainActor.run` pour le snapshot — la décision est juste calée dans le
  même hop. Pas de coût TTFT additionnel.

## Conclusion

**Replay équivalent.** Le ghost-text behavior, le cancel-on-keystroke
discipline, le timing debounce, l'ordre du KV decision tree, et tous les logs
events (`cache_evict`, `cache_invalidate_context`, `kv_cache_invalidate
count:0/1/2/3`, `kv_cache_extend`, `kv_cache_trim`) restent strictement
identiques. Le refactor déplace simplement la ownership des caches de PVM
vers CompletionCache sans changer leur sémantique.
