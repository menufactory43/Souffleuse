---
phase: 04-cascade-quality-architecture
plan: 04
subsystem: predictor-runtime
tags:
  - phase-04
  - split-pvm
  - completion-cache
  - kv-cache
requires:
  - 04-02
  - 04-03
provides:
  - CompletionCache (@MainActor final class)
  - KVDecision (Sendable, Equatable)
  - KVCacheBypassFlag (single source of truth for SOUFFLEUSE_DISABLE_KV_CACHE)
affects:
  - Souffleuse/Sources/Souffleuse/PredictorViewModel.swift
  - Souffleuse/Tests/SouffleuseTests/SouffleuseTests.swift
tech-stack:
  added: []
  patterns:
    - "Pure decision function + caller-side application (KV decision tree)"
    - "Test seam via internal snapshot properties (predictCacheSnapshot, predictCacheOrderSnapshot)"
key-files:
  created:
    - Souffleuse/Sources/Souffleuse/CompletionCache.swift
    - Souffleuse/Tests/SouffleuseTests/CompletionCacheTests.swift
    - .planning/phases/04-cascade-quality-architecture/04-04-REPLAY-DIFF.md
  modified:
    - Souffleuse/Sources/Souffleuse/PredictorViewModel.swift
    - Souffleuse/Tests/SouffleuseTests/SouffleuseTests.swift
decisions:
  - "Decision pure : decideExtendTrimInvalidate retourne KVDecision (Sendable, Equatable). Caller applique le verdict + log event + trim capability gate. Ordre Pitfall 4 frozen via tests."
  - "Trim capability gate (canTrimPromptCache) reste côté caller — la décision pure ne connaît pas le type concret du cache. Downgrade .trim → .diverged si non supporté préserve la sémantique legacy."
  - "Env var SOUFFLEUSE_DISABLE_KV_CACHE migré dans CompletionCache.swift comme single source of truth (grep count 1 ici, 0 dans PVM)."
  - "Test seams internes (predictCacheSnapshot / predictCacheOrderSnapshot / lastContextFingerprintSnapshot) ajoutés pour preserver les tests legacy d'introspection FIFO."
metrics:
  duration: ~50 minutes
  completed: 2026-05-25
---

# Phase 4 Plan 04: CompletionCache extraction Summary

CompletionCache `@MainActor final class` consolide les 4 caches cross-keystroke (predictCache FIFO 32, tokenCountCache, kvCacheHolder, lastContextFingerprint) hors PVM ; KVDecision enum + decideExtendTrimInvalidate(...) extraient le KV decision tree comme fonction pure testable.

## LOC

| File | LOC |
|------|-----|
| `Souffleuse/Sources/Souffleuse/CompletionCache.swift` (created) | **262** |
| `Souffleuse/Tests/SouffleuseTests/CompletionCacheTests.swift` (created) | **202** |
| `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` | 1513 → **1443** (−70) |

PVM −70 LOC après suppression de : KVCacheBypassFlag enum (4 lignes), 4 propriétés cache (predictCache / predictCacheOrder / predictCacheCapacity / tokenCountCache / lastContextFingerprint / sessionCacheHolder), `storeInCache` (13 lignes), `clearPredictCache` (4 lignes), inline `enum KVDecision` (1 ligne) + branches inline (47 lignes consolidées en 60 lignes de switch sur le verdict pur ; net réduction par déduplication des bypass / cold / fingerprintChanged branches qui faisaient toutes `makePromptCache(...)`).

## Tests

| Suite | Pre | Post | Δ |
|-------|-----|------|---|
| Total | 199 | **213** | +14 |
| CompletionCacheTests | n/a | 14 | new |

Exit `swift test` : 0. Audit 6/6 OK.

## KVCacheBypassFlag migration confirmation

| Grep target | Result |
|-------------|--------|
| `grep -c 'SOUFFLEUSE_DISABLE_KV_CACHE' Souffleuse/Sources/Souffleuse/CompletionCache.swift` | **1** |
| `grep -c 'SOUFFLEUSE_DISABLE_KV_CACHE' Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` | **0** |
| `grep -c 'private enum KVCacheBypassFlag' Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` | **0** |
| `grep -c 'private enum KVCacheBypassFlag' Souffleuse/Sources/Souffleuse/CompletionCache.swift` | **1** |

Env var literal `SOUFFLEUSE_DISABLE_KV_CACHE` est byte-identique au legacy (vérifié par diff sémantique : la chaîne provient du même `ProcessInfo.processInfo.environment[...]` pattern).

## Replay verdict

**EQUIVALENT** (BUILD-ONLY mode, same as 04-02 / 04-03).

Voir `04-04-REPLAY-DIFF.md` pour le diff détaillé. CompletionCache extraction est un refactor mécanique : aucun ghost-text behavior, log event signature, threading model, ou ordering observable n'est modifié. L'ordre Pitfall 4 (bypass → cold → fingerprintChanged → delta) reste verbatim et est verrouillé par 5 tests dédiés.

## Commits

| Hash | Type | Description |
|------|------|-------------|
| `00bd767` | feat | add CompletionCache with KVDecision pure decision tree |
| `1c82508` | refactor | wire CompletionCache dans PredictorViewModel |
| `0ad8c49` | test | CompletionCacheTests — FIFO + fingerprint + KV decision |
| `88f0124` | docs | replay diff verdict — EQUIVALENT (BUILD-ONLY mode) |

## Deviations from Plan

**1. [Rule 3 - Blocking] Test seams internes ajoutés sur CompletionCache**

- **Found during:** Task 2 (wire dans PVM)
- **Issue:** Les tests legacy (`SouffleuseTests.swift` L362-489) accédaient à `vm.predictCache`, `vm.predictCacheOrder`, `vm.storeInCache(...)`. Après l'extraction, ces propriétés deviennent privées dans `CompletionCache`. Sans seam, les tests legacy auraient cassé.
- **Fix:** Ajout de 3 `internal` snapshot properties (`predictCacheSnapshot`, `predictCacheOrderSnapshot`, `lastContextFingerprintSnapshot`) sur `CompletionCache` + adaptation des call-sites des tests legacy pour utiliser la nouvelle API (`p.cache.store(...)` / `p.cache.predictCacheSnapshot[...]`).
- **Files modified:** `Souffleuse/Sources/Souffleuse/CompletionCache.swift`, `Souffleuse/Tests/SouffleuseTests/SouffleuseTests.swift`
- **Commit:** `1c82508`

**2. [Rule 3 - Blocking] Shim public `clearPredictCache()` conservé sur PVM**

- **Found during:** Task 2
- **Issue:** `SouffleuseAppDelegate.swift:352, 1176` appelle `predictor.clearPredictCache()` directement (toggle off + bundle focus change). Le plan demandait de supprimer cette méthode de PVM.
- **Fix:** Conservation d'une shim publique sur PVM qui délègue à `cache.clearPredictCache()`. La sémantique est strictement préservée (drop predictCache memo uniquement, KV holder + tokenCountCache restent intacts car ils sont model/tokenizer-spécifiques pas UI-context-spécifiques). Documenté inline.
- **Files modified:** `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift`
- **Commit:** `1c82508`

**3. [Rule 1 - Bug avoidance] decideExtendTrimInvalidate ne retourne pas `.diverged` directement**

- **Found during:** Task 1 (design)
- **Issue:** Le plan listait 7 cas dans `KVDecision` (incluant `.diverged`). La sémantique legacy `.diverged` était : "newCount < oldCount mais le cache type ne supporte pas le trim → rebuild". Cette branche dépend du type concret du cache (`canTrimPromptCache(existing)`), qui n'est pas accessible depuis CompletionCache (pure decision MainActor sans deps MLX bridging).
- **Fix:** Documenté que `.diverged` ne provient pas de `decideExtendTrimInvalidate` directement. Le caller (PVM) reçoit `.trim(removedTokens:)` puis check `canTrimPromptCache(existing)` ; si non supporté il bascule lui-même à `.diverged` + rebuild + emit `kv_cache_invalidate count:2`. Sémantique replay-équivalente vérifiée dans 04-04-REPLAY-DIFF.md §"Code-path equivalence". Le `case .diverged` du switch côté caller est défensif (jamais émis par la décision pure).
- **Files modified:** `Souffleuse/Sources/Souffleuse/CompletionCache.swift`, `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift`
- **Commit:** `00bd767` + `1c82508`

**4. [Rule 1 - Bug avoidance] Pas de constante `MAX_TRIM_TOKENS` dans le legacy code**

- **Found during:** Task 1 (lecture PVM:1163-1311 demandée par le plan)
- **Issue:** Le plan demandait : "Lire PVM:1163-1311 pour la valeur exacte de `MAX_TRIM_TOKENS` (ou nom équivalent). Si la constante a un autre nom (par ex. `maxTrimWindow`), la migrer verbatim et garder le même nom + valeur dans CompletionCache.swift via `private static let`." Cette constante **n'existe pas** dans le legacy : le cap implicite vient de la capability check `canTrimPromptCache(existing)` qui dépend du type concret du cache MLX (pas d'un compteur fixe).
- **Fix:** Documenté dans la doc-comment de `KVDecision` que la cap est implicite côté caller, pas d'un constant. La décision pure retourne `.trim(removedTokens:)` sans gate ; le gate vit côté caller via `canTrimPromptCache`. Sémantique strictement préservée vs legacy.
- **Files modified:** `Souffleuse/Sources/Souffleuse/CompletionCache.swift`
- **Commit:** `00bd767`

Aucune déviation Rule 4 (architectural).

## Known Stubs

Aucun. Toutes les API sont câblées de bout en bout.

## Self-Check: PASSED

- `Souffleuse/Sources/Souffleuse/CompletionCache.swift` : FOUND (262 LOC)
- `Souffleuse/Tests/SouffleuseTests/CompletionCacheTests.swift` : FOUND (14 tests)
- `.planning/phases/04-cascade-quality-architecture/04-04-REPLAY-DIFF.md` : FOUND
- Commit `00bd767` (feat CompletionCache) : FOUND
- Commit `1c82508` (refactor wire PVM) : FOUND
- Commit `0ad8c49` (test CompletionCacheTests) : FOUND
- Commit `88f0124` (docs replay-diff) : FOUND
- `swift build` exit 0 : verified
- `swift test` exit 0, 213 tests passed : verified
- `bash Souffleuse/audit.sh` exit 0, 6/6 OK : verified
- `grep -c 'SOUFFLEUSE_DISABLE_KV_CACHE'` : 1 in CompletionCache.swift, 0 in PVM : verified
