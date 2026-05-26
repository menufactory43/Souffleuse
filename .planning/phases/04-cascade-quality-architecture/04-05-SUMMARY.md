---
phase: 04-cascade-quality-architecture
plan: 05
subsystem: predictor-runtime
tags:
  - phase-04
  - split-pvm
  - model-runtime
  - low-risk-extract
requires:
  - 04-02
  - 04-03
  - 04-04
provides:
  - ModelRuntime (@MainActor final class, skeleton)
  - ModelRuntime.OutputFilter (enum, 6 nonisolated static helpers)
  - PredictRequest (Sendable value-type)
  - StreamMetrics (Sendable value-type, top-level)
  - CacheBox (fileprivate Sendable transfer box — duplicate of PVM's)
affects:
  - Souffleuse/Sources/Souffleuse/ModelRuntime.swift (new)
  - Souffleuse/Tests/SouffleuseTests/ModelRuntimeOutputFilterTests.swift (new)
tech-stack:
  added: []
  patterns:
    - "Alongside extraction (no caller) for low-risk refactor staging"
    - "Pure-function lock-in tests verrouillant la sémantique verbatim avant dédup"
    - "fileprivate duplicate type for symbolic non-collision pending cleanup phase"
key-files:
  created:
    - Souffleuse/Sources/Souffleuse/ModelRuntime.swift
    - Souffleuse/Tests/SouffleuseTests/ModelRuntimeOutputFilterTests.swift
  modified: []
decisions:
  - "ModelRuntime existe alongside PVM en 04-05 : aucun caller PVM modifié. Le wiring vit en 04-06 (behind env flag SOUFFLEUSE_USE_MODEL_RUNTIME) et 04-07 (cleanup + dédup PVM-side)."
  - "CacheBox déclaré fileprivate dans ModelRuntime.swift pour éviter la collision symbolique avec PVM.CacheBox (private struct au niveau fichier). Promotion à internal avec drop simultané de la copie PVM = 04-07."
  - "detectLanguage retourne String? (pas NLLanguage?) — aligné sur le retour réel PVM:383-414. Le plan mentionnait NLLanguage? dans <interfaces> mais l'instruction 'COPIER verbatim' prime. PredictRequest reflète ce choix."
  - "Tasks 1 + 2 du plan consolidées dans un même commit (Task 1) : loadModel + swap étaient triviaux à implémenter en même temps que le skeleton, et leur séparation n'apportait aucune réduction de risque (build clean dès le premier write). Task 3 (tests) reste son propre commit, Task 4 (audit + summary) idem."
  - "loadModel ne publie pas LoadState UI dans ModelRuntime (façade UI = 04-07). lastError est exposé en lecture seule comme seul signal d'erreur ; la façade PVM mappera vers LoadState.failed quand elle wrappera Runtime."
metrics:
  duration: ~20 minutes
  completed: 2026-05-26
---

# Phase 4 Plan 05: ModelRuntime extraction step 1 (low-risk pure-function + lifecycle) Summary

ModelRuntime skeleton + OutputFilter enum + buildSystemPrompt/detectLanguage helpers extraits **alongside PVM** ; PVM est byte-identical pour préserver intégralement le comportement ghost. Aucun caller PVM ne route encore par ModelRuntime — le wiring derrière env flag arrive en 04-06.

## LOC

| File | LOC | Notes |
|------|-----|-------|
| `Souffleuse/Sources/Souffleuse/ModelRuntime.swift` (created) | **378** | ≥ 180 LOC objectif |
| `Souffleuse/Tests/SouffleuseTests/ModelRuntimeOutputFilterTests.swift` (created) | **177** | ≥ 80 LOC objectif |
| `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` | **1443** (= pre-plan) | byte-identical |

PVM `git diff` byte count : **0** — confirmation que cette extraction n'affecte AUCUN caller.

## Behavioral change: none

ModelRuntime existe sans consommateur. Le pipeline ghost continue d'utiliser :

- `PVM.stripPrefixOverlap`, `PVM.ghostIsRepeatingPrefix`, `PVM.capToWords` (private static internes).
- `PVM.buildSystemPrompt`, `PVM.detectLanguage` (private static).
- `PVM.loadModel`, `PVM.swapModel` (méthodes d'instance).
- `PVM.container.perform { … }` (body legacy, intact).

La copie OutputFilter et les helpers ModelRuntime sont des **doublons documentés** dont la dédup vit en 04-07 (cleanup phase). Cette duplication est volontaire — elle est le mécanisme qui rend ce plan **byte-identique** au pre-plan dans son impact sur le ghost.

## Tests

| Suite | Pre | Post | Δ |
|-------|-----|------|---|
| Total | 213 | **238** | +25 |
| ModelRuntimeOutputFilterTests | n/a | 25 | new |

Cible plan = ≥10. Atteint 25 (×2.5) — chaque helper a ≥3 tests (nominal + edge cases).

| Helper | Tests |
|--------|-------|
| `stripPrefixOverlap` | 4 (basic, no-overlap, empty-ghost, empty-prefix) |
| `ghostIsRepeatingPrefix` | 3 (echo detected, continuation false, too-short guard) |
| `hasCompletedFirstWord` | 5 (space, punctuation, mid-word, empty, apostrophe-in-word) |
| `stripTrailingPartialWord` | 4 (basic, trailing punctuation, empty, single-word) |
| `normalizeForRepeatCheck` | 4 (lowercase+collapse, multi-punct, trim, empty) |
| `capToWords` | 5 (word-limit, below-limit, sentence-terminator, comma-cut, short-string) |

`swift test` exit 0. `bash audit.sh` exit 0 (6/6 OK).

## ModelRuntime API actuelle (04-05)

```swift
@MainActor
final class ModelRuntime {
    private(set) var container: ModelContainer?
    private(set) var modelId: String
    private(set) var lastError: String?

    init(initialModelId: String)
    func loadModel() async
    func swap(to id: String, completionCache: CompletionCache) async
    func cancel()  // no-op (kept for API symmetry)

    enum OutputFilter {
        nonisolated static func stripPrefixOverlap(_ snapshot: String, prefix: String) -> String
        nonisolated static func ghostIsRepeatingPrefix(_ ghost: String, prefix: String) -> Bool
        nonisolated static func hasCompletedFirstWord(_ s: String) -> Bool
        nonisolated static func stripTrailingPartialWord(_ s: String) -> String
        nonisolated static func normalizeForRepeatCheck(_ s: String) -> String
        nonisolated static func capToWords(_ text: String, max: Int) -> String
    }

    static let autocompleteSystemPrompt: String
    static func buildSystemPrompt(detectedLanguage: String?) -> String
    static func detectLanguage(in text: String) -> String?
}

// Top-level value types (also new):
fileprivate struct CacheBox: @unchecked Sendable { let caches: [KVCache] }
struct StreamMetrics: Sendable { var ttftMillis: Int?; var tokensPerSecond: Double? }
struct PredictRequest: Sendable { /* 13 fields — see ModelRuntime.swift */ }
```

**Absent volontairement** (cible 04-06) : `func generate(...) async throws -> StreamMetrics`. Cette méthode portera le body actuel de `container.perform { context -> StreamMetrics in ... }` (PVM:1009-1412 zone) derrière le flag `SOUFFLEUSE_USE_MODEL_RUNTIME`.

## Commits

| Hash | Type | Description |
|------|------|-------------|
| `d18870a` | feat | add ModelRuntime skeleton + OutputFilter + value types (Tasks 1 + 2 consolidés) |
| `7604cac` | test | ModelRuntimeOutputFilterTests — pure-function lock-in |

## Deviations from Plan

**1. [Rule 3 — Blocking] CacheBox déclaré fileprivate (pas internal/public)**

- **Found during:** Task 1 (premier swift build)
- **Issue:** Le plan listait `struct CacheBox: @unchecked Sendable { let value: KVCache? }` au niveau type. La déclaration au top-level a immédiatement causé `error: 'CacheBox' is ambiguous for type lookup in this context` à `PVM:1100` (le PVM déclare aussi un `private struct CacheBox` au fichier-niveau et l'utilise sans préfixe dans des nested types).
- **Fix:** Promotion du visibilité keyword à `fileprivate` (et conservation du shape `[KVCache]` legacy au lieu de `KVCache?` listé dans le plan — la copie suit le verbatim PVM:56-58 strict). Pas de symbole exporté ; aucun caller PVM impacté.
- **Files modified:** `Souffleuse/Sources/Souffleuse/ModelRuntime.swift`
- **Commit:** `d18870a`

**2. [Rule 3 — Blocking] detectLanguage retourne String? pas NLLanguage?**

- **Found during:** Task 1 (lecture PVM)
- **Issue:** Le plan documentait la signature comme `detectLanguage(in:) -> NLLanguage?`. La réalité PVM (L383-414) est `-> String?` — le switch sur `NLLanguage` est interne et renvoie l'anglais ("French", "Spanish", …) directement consommable par `buildSystemPrompt(detectedLanguage:)` (qui prend lui aussi `String?`).
- **Fix:** Signature copiée verbatim depuis PVM (`String?`). `PredictRequest.detectedLanguage` aligné en conséquence. Doc-comment explicite la décision.
- **Files modified:** `Souffleuse/Sources/Souffleuse/ModelRuntime.swift`
- **Commit:** `d18870a`

**3. [Rule 3 — Efficiency] Tasks 1 + 2 du plan consolidées en un seul commit**

- **Found during:** Task 2 review (après Task 1 build vert)
- **Issue:** Task 2 demandait d'implémenter `loadModel()` et `swap(to:completionCache:)`. Task 1 demandait juste le skeleton avec ces fonctions vides commentées `// Task 2 — copier de PVM`. Au moment d'écrire Task 1, implémenter immédiatement les bodies (12 lignes pour loadModel, 6 lignes pour swap) ne ralentit pas la review et économise un commit no-op de "fill the stubs".
- **Fix:** Le commit Task 1 inclut directement les bodies réels (loadModel = copie verbatim PVM:184-211 moins le LoadState publishing, swap = aligné sur PVM:157-173 sans cancel/cache.invalidateAll qui sont délégués au caller). Toutes les acceptance criteria Task 1 ET Task 2 sont passées en une commit. Task 3 (tests) reste son propre commit, Task 4 (docs SUMMARY) idem.
- **Files modified:** `Souffleuse/Sources/Souffleuse/ModelRuntime.swift`
- **Commit:** `d18870a` (consolidé)

**4. [Rule 2 — Critical functionality] LoadState UI non publié par ModelRuntime**

- **Found during:** Task 2 design
- **Issue:** PVM legacy publie `loadState: LoadState` via Observation pour driver l'UI (badge "Chargement…" pendant `loadContainer`). Le plan dit "ModelRuntime expose juste `lastError` et `container != nil`".
- **Fix:** Honoré le plan — ModelRuntime ne publie PAS LoadState. La façade UI (04-07) wrappera Runtime et exposera son propre LoadState dérivé du `container` state + des hooks progress. Le hook progress de `loadContainer` est swallowed pour l'instant avec un comment explicite. Cette décision est tracée dans le doc-comment de `loadModel()` ET dans le frontmatter `decisions:`.
- **Files modified:** `Souffleuse/Sources/Souffleuse/ModelRuntime.swift`
- **Commit:** `d18870a`

Aucune déviation Rule 4 (architectural).

## Threat surface

Aucune nouvelle surface réseau, AX, AppleEvents, fichier ou IPC introduite. ModelRuntime est in-process MainActor pur, dépend uniquement de :

- `LLMModelFactory.shared.loadContainer(configuration:)` (déjà utilisé par PVM, même call-site).
- `MLX.GPU.set(cacheLimit:)` (déjà fait par PVM).
- `NLLanguageRecognizer` (déjà utilisé par PVM).

Audit invariants préservés : aucun nouveau `Log.*` event introduit dans ce plan (l'unique log est `model_load_failed` qui était déjà émis par PVM et est ici une copie d'event — pas de doublon problématique car aucun caller appelle `ModelRuntime.loadModel()`).

## Known Stubs

**Absent volontairement (cible 04-06)** :

- `func generate(_ req: PredictRequest, …) async throws -> StreamMetrics` — body de `container.perform` non encore migré. Documenté dans le doc-comment de classe.
- `PredictRequest` value-type n'a aucun caller. Documenté.

Ces "stubs" ne sont PAS des bugs — ils sont la définition du périmètre 04-05 (low-risk extract). Ils seront comblés en 04-06 derrière un env flag, ce qui maintient l'AB-testability vs le pipeline legacy intact.

## Next step

→ **04-06 PLAN.md** : migration de `PVM.container.perform { context -> StreamMetrics in ... }` (zone L1009-1412) vers `ModelRuntime.generate(...)` derrière `SOUFFLEUSE_USE_MODEL_RUNTIME` env flag. PVM conserve `predict_legacy()` comme fallback. AB-testable empiriquement.

→ **04-07 PLAN.md** : empirical ghost validation (user gate non-autonomous) + retrait du flag + cleanup PVM façade + dédup OutputFilter (suppression des copies PVM:247-375 et bascule sur `ModelRuntime.OutputFilter.*`).

## Self-Check: PASSED

- `Souffleuse/Sources/Souffleuse/ModelRuntime.swift` : FOUND (378 LOC)
- `Souffleuse/Tests/SouffleuseTests/ModelRuntimeOutputFilterTests.swift` : FOUND (177 LOC, 25 @Test)
- Commit `d18870a` (feat ModelRuntime) : FOUND
- Commit `7604cac` (test OutputFilter) : FOUND
- `swift build --package-path Souffleuse` exit 0 : verified
- `swift test --package-path Souffleuse` : 238/238 passed (213 baseline + 25 new) : verified
- `bash Souffleuse/audit.sh` : 6/6 OK : verified
- `git diff PVM.swift` = empty : verified (byte-identical confirmation)
- ModelRuntime ne contient PAS `func generate(...)` : verified (cible 04-06) — `grep -c 'func generate' ModelRuntime.swift` = 0
