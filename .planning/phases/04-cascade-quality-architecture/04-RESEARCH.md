# Phase 4: Cascade Quality + Architecture — Research

**Researched:** 2026-05-25
**Domain:** Refactor architectural ciblé (split de deux god-objects) + politique de cascade ghost mesurable + protocole de vérification réelle. 100% interne codebase Souffleuse — pas de nouvelle stack, pas de nouvelle dépendance externe.
**Confidence:** HIGH (toutes les affirmations sont VERIFIED par lecture directe des fichiers cités ou par CITED depuis CONTEXT/STATE/REQUIREMENTS).

> `response_language: fr` — la suite est rédigée en français pour le planner aligné FR-first.

---

## Summary

Phase 4 est un refactor à risque modéré sur deux god-objects (`PredictorViewModel` 1566 LOC, `SouffleuseAppDelegate` 1209 LOC) puis l'introduction d'une politique de cascade explicite (Ghost Relevance Gate + scoring scalaire + classification grid). **Aucun nouveau composant externe n'est à apporter** — toute l'infrastructure existe déjà :
- `KVCacheHolder` (Phase 3) prouve que le pattern *@MainActor façade / `@unchecked Sendable` snapshot box / CacheBox bridge* est viable pour transporter de l'état entre `MainActor` et le closure off-actor de `container.perform`.
- `Log.info(_:_:count:)` avec `StaticString` event names rend la classification grid privacy-safe par construction (cf. `audit.sh` check 6).
- `SouffleuseCoherence --replay` accepte déjà un `ScenarioFile` versionné — l'ajout d'un champ `expectedCategory` est un bump v1 → v2 transparent (les champs sont `Optional` dans le schéma actuel, cf. lignes 220-235 de `main.swift`).
- Le tracing source-tagged (`ghost_history_match`, `ghost_word_complete`, `ghost_protect_high`, `ghost_keep_longer`, `ghost_swap_to_llm_from_high`, `ghost_apply_llm`, `ghost_keep_stable`, `ghost_dropped_repeat`) introduit au commit `43c9d60` est *l'embryon* de la classification grid — la phase l'étend, ne le remplace pas.

**Primary recommendation:** L'ordre D-01 (PVM split d'abord, puis TypingSession) est correct. Recommandation forte : **introduire `SuggestionPolicy` en PREMIER** dans le split PVM, parce que c'est lui qui porte le Ghost Relevance Gate, et qu'avoir le Gate en place dès la première sous-étape permet de prouver l'équivalence replay avant de bouger `ModelRuntime` / `CompletionCache` / `GenerationPlanner`. Les trois autres modules sont des extractions mécaniques une fois Policy en place.

---

## User Constraints (from CONTEXT.md)

### Locked Decisions

> Copiées verbatim de `.planning/phases/04-cascade-quality-architecture/04-CONTEXT.md` § `<decisions>`. Toute proposition du planner qui contredit ces points est *invalide par construction*.

**Architecture Refactor Strategy**
- **D-01:** Ordre — **`PredictorViewModel` split EN PREMIER**, puis extraction `TypingSession`.
- **D-02:** Migration **in-place, atomic-commit par boundary** (pas de feature flag). Safety net : 126 tests + `SouffleuseCoherence --replay` equivalence check à chaque extraction.
- **D-03:** Frontières des 4 nouveaux modules — tous façades `@MainActor` au-dessus d'engines actor-backed quand pertinent :
  - **`ModelRuntime`** — MLX container loading (`loadContainer`, `swapModel`), `LMInput`, `TokenIterator(cache:)`, sampler, maxTokens. I/O modèle pur.
  - **`CompletionCache`** — `predictCache` FIFO(32) + `KVCacheHolder` + `InvariancePrefix` + `MemoizingTokenCounter`.
  - **`SuggestionPolicy`** — Cascade routing L0/L1/L2 + source-tagged confidence + anti-churn + stability gate + **Ghost Relevance Gate** + classification grid émission.
  - **`GenerationPlanner`** — debounce nanos, generation counter, cancel-on-keystroke, dispatch `onChunk`.
  - `PredictorViewModel` rétrécit à une façade qui câble ces 4.
- **D-04:** Extraction `TypingSession` depuis `SouffleuseAppDelegate` — absorbe tick 80ms, caret tracking, caches per-bundle, debounce enrichment. AppDelegate ne garde que : onboarding, hotkeys, menu-bar, preferences wiring.

**Ghost Relevance Gate + Confidence Scoring**
- **D-05:** Scoring **heuristique** (pas appris — LEARN-* hors scope).
- **D-06:** Scalar `[0,1]` = `source_prior × prefix_fit × length_fit`.
  - `source_prior`: L0 WordCompleter = 0.55 ; L1 history exact = 0.75 ; L2 LLM = 0.60.
  - `prefix_fit`: 1.0 si le ghost commence par le mot courant (mid-word) ou enchaîne proprement après l'espace ; 0.0 si divergent.
  - `length_fit`: bell curve centrée 2–6 tokens ; pénalité aux extrémités.
- **D-07:** Hard block sous `0.25` + replacement bar `score_courant × 1.15`.
- **D-08:** Routing :
  - **Mid-word** → L0 exclusif.
  - **After-space** → L1 évalué d'abord (seuil 0.4) ; L2 peut upgrader L1 si `score_L2 ≥ score_L1 + 0.15`.
  - History exact-match after-space **réactivé** derrière ce gate.

**Ghost Classification Grid + Metrics**
- **D-09:** Taxonomie verrouillée : `correct` (Full Tab) | `acceptable` (Partial Tab) | `useless` (≥200ms shown → Esc/dismiss zéro overlap) | `bad` (mot suivant tapé diverge dans 500ms) | `parasite` (remplacé par autre ghost dans la stability window).
- **D-10:** 5 `StaticString` count-only : `ghost_classified_correct/_acceptable/_useless/_bad/_parasite`.
- **D-11:** Release gate : `correct/total ≥ 30%` ET `(useless+bad+parasite)/total ≤ 35%` ET `parasite/total ≤ 5%` (cap dur).
- **D-12:** Replay scénarios gagnent un champ `expectedCategory` → confusion matrix dans `REPLAY-RESULTS.md`.
- **D-13:** Source priors et seuils sont des **constantes tunables** centralisées (un seul fichier — probable `SuggestionPolicy.Tuning`).

**Real-App Parity Verification**
- **D-14:** Scripted (3-5/app, reproductibles, auto-classifiés) + Blind A/B daily-use (~½ journée, ≤30 events).
- **D-15:** Tier 1 (acceptance gate) = **Mail, Notes, Brave**. Tier 2 (report-only) = Safari, TextEdit, Intercom, Notion.
- **D-16:** Tier 1 acceptance = (a) classification grid passe D-11 sur scripted, (b) A/B not-worse-than Cotypist ≥5/5 scripted, (c) pas de `parasite` > 5% dans aucune fenêtre 30min daily-use.
- **D-17:** `04-VERIFICATION-{app}.md` par app Tier 1 + roll-up `04-VERIFICATION.md`.

### Claude's Discretion

- Choix précis des unit-test cases au-delà du replay equivalence gate.
- Style exact des `StaticString` event names (`ghost_classified_*` proposé).
- Granularité d'atomic-commit lors du split PVM (un commit par module ou un par sous-étape).

### Deferred Ideas (OUT OF SCOPE)

- `clipboardContext` opt-in (ex-SLOT-05), `screenContext` OCR conditional (ex-SLOT-06) — polish-tier.
- Apprentissage signal négatif (LEARN-01..04) — bloque Gate appris.
- Multi-candidate (MULT-01..03).
- Filtres visuels (VIS-01..03).
- Activation AX Electron / Signal Desktop (AX-01).
- XPC isolation 3-process.
- Auto-tuning des constantes de scoring.

---

## Phase Requirements

Le CONTEXT.md ne donne pas d'IDs `REQ-XX` numérotés ; les 7 work-streams (D-01..D-17 collectivement) sont les exigences. Mapping ID → support de recherche :

| ID work-stream | Description | Section de recherche supportant |
|---|---|---|
| WS-1 | Extract `TypingSession` from `SouffleuseAppDelegate` | §"Concrete extraction plan TypingSession" ; §"Component Responsibilities" ligne AppDelegate / TypingSession |
| WS-2 | Split `PredictorViewModel` en 4 modules | §"Concrete PVM-region mapping" ; §"Architecture Patterns" |
| WS-3 | Ghost Relevance Gate (scalar `[0,1]`) | §"Confidence scoring formula + Swift type sketch" |
| WS-4 | Re-active history exact-match after-space derrière le Gate | §"Cascade routing decision matrix" ; §"Code Examples" — wiring de `historyExactSubstringMatch` |
| WS-5 | Routing mid-word vs after-space explicite | §"Cascade routing decision matrix" |
| WS-6 | Classification grid + metrics audit-safe | §"Classification grid emission points" |
| WS-7 | Real-app parity verification matrix Tier 1 | §"Real-app verification scenario list" |

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|---|---|---|---|
| MLX model loading / swap / generate | `ModelRuntime` (process-local, GPU-bound via Metal) | — | I/O MLX pur ; déjà isolé dans `container.perform` aujourd'hui (cf. `PredictorViewModel.swift:1009-1412`). |
| Token counting + memoize | `CompletionCache` (process-local CPU) | — | `MemoizingTokenCounter` est déjà `Sendable`, indépendant du modèle au-delà du tokenizer. |
| KV cache state cross-keystroke | `CompletionCache` (process-local GPU memory) | — | Le `sessionCacheHolder` (Phase 3) est par construction le bon endroit ; il sait déjà invalider sur `swapModel`. |
| Prefix → suggestion memo (FIFO 32) | `CompletionCache` (process-local main-actor) | — | Aujourd'hui à `PVM.predictCache` ; déplacement mécanique. |
| Layer 0 word completion (NSSpellChecker) | `SuggestionPolicy` (process-local main-actor sync, sub-ms) | `SouffleuseTyping` (lib existante) | `WordCompleter` reste in-place dans `SouffleuseTyping` ; `SuggestionPolicy` l'appelle. Pas de déplacement de code, juste de l'orchestration. |
| Layer 1 history exact-match | `SuggestionPolicy` | `SouffleusePersonalization` (snapshot source) | Idem — `historyExactSubstringMatch` est déjà une `nonisolated static func` testable hors PVM (PVM:1524). |
| Layer 2 LLM streaming + onChunk | `SuggestionPolicy` (decision) ⊕ `ModelRuntime` (engine) ⊕ `GenerationPlanner` (lifecycle) | — | Aujourd'hui les trois sont entrelacés dans PVM:782-913 (onChunk closure). La séparation est l'enjeu central du split. |
| Generation counter + cancel-on-keystroke | `GenerationPlanner` (main-actor) | — | `generation: UInt64` (PVM:116) + `currentTask: Task<Void, Never>?` (PVM:112) + le pattern `myGeneration` capturé dans onChunk. Migration : 1-pour-1 dans `GenerationPlanner`. |
| Debounce predict (30ms) | `GenerationPlanner` (main-actor) | — | Aujourd'hui à `SouffleuseAppDelegate.predictDebounceTask` (AppDelegate:106, :962-981). À déplacer côté `GenerationPlanner` pour que le ViewModel possède son propre rythme — AppDelegate appelle alors `predictor.predict(...)` sans avoir à connaître le timing. |
| Ghost Relevance Gate scoring | `SuggestionPolicy.Scorer` (process-local, pure function) | — | Nouvelle responsabilité ; pure function `f(source, prefix, ghost) -> Score`. Testable sans MLX. |
| Classification grid emission | `SuggestionPolicy.Lifecycle` (main-actor, observes Tab/Esc/replace/dismiss timing) | `GenerationPlanner` (fournit l'événement "stream ended" + temps écoulé) | Le call-site naturel est `SuggestionPolicy` parce qu'il est seul à voir simultanément (a) la source du ghost courant, (b) la transition vers un autre ghost, (c) les signaux Tab/Esc forwardés par AppDelegate. |
| Tick 80ms heartbeat | `TypingSession` (main-actor) | — | Aujourd'hui à `SouffleuseAppDelegate.tick()` (AppDelegate:548). Migration : `TypingSession.tick()` ; AppDelegate ne garde que `Timer.scheduledTimer(...)` qui appelle `session.tick()`. |
| Caret tracking (`lastCaretRectByApp`, `lastFocusedBundleID`, `textAtFocusByBundle`) | `TypingSession` | `CaretResolver` (helper existant) | Per-bundle caches font partie du tick — bougent tels quels. |
| Debounce enrichment (per-bundle TTL via `ContextEnricher`) | `TypingSession` | `ContextEnricher` (actor existant) | `lastEnrichedBundleID` + `cachedEnrichmentPrefix` (AppDelegate:156-159) bougent dans `TypingSession`. |
| Overlay rendering | `OverlayWindow` (existant) | — | Inchangé. `SuggestionPolicy` lui dit "affiche X" via callback ; `OverlayWindow.show/hide` reste l'API. |
| Tab/Esc key handling | `SouffleuseAppDelegate.handleKey` ⊕ `KeyInterceptor` | `SuggestionPolicy` (consomme les signaux pour classification) | Le `CGEventTap` reste dans AppDelegate (lifecycle propre du tap, raison historique). AppDelegate notifie `SuggestionPolicy.onAccept(...)`, `.onDismiss(...)`. |

**Implication clé:** Le split n'introduit aucune nouvelle frontière de processus, ni d'XPC, ni d'IPC. Tous les modules vivent dans le même target `Souffleuse` (l'executable). Pas de SPM target nouveau requis — `SuggestionPolicy.swift`, `ModelRuntime.swift`, `CompletionCache.swift`, `GenerationPlanner.swift`, `TypingSession.swift` sont 5 nouveaux fichiers dans `Sources/Souffleuse/`. (Verdict alternatif possible : extraire dans une nouvelle lib SPM `SouffleusePredictor` pour fortifier le boundary — *non recommandé en Phase 4* car ça multiplie les diffs de `Package.swift` et casse la testabilité `@testable import Souffleuse`. À revoir milestone suivant.)

---

## Standard Stack

### Core (déjà en place — aucun ajout)

| Library | Version | Purpose | Why Standard |
|---|---|---|---|
| `MLX` / `MLXLLM` / `MLXLMCommon` | 2.29.1 | Container, TokenIterator, KVCache | Verrouillé par PROJECT.md constraint. Pas de descente sous l'API publique ce milestone. [VERIFIED: Package.resolved] |
| `Foundation` + `AppKit` + `Observation` | system | `@Observable` view-model, `Timer`, `NSPanel` | Stack obligatoire macOS. [VERIFIED] |
| Swift Testing | 6.0+ | `@Suite` / `@Test` pour les 126 tests existants | Convention codebase (CONVENTIONS.md). [VERIFIED: `Tests/SouffleuseTests/HistoryExactMatchTests.swift`] |

### Supporting (in-tree assets — réutilisés tels quels)

| Asset | File | Purpose | When to Use |
|---|---|---|---|
| `KVCacheHolder` + `InvariancePrefix` | `Sources/Souffleuse/KVCacheHolder.swift` | KV cache cross-keystroke + fingerprint | Migre verbatim dans `CompletionCache` (D-03). [VERIFIED] |
| `CacheBox @unchecked Sendable` pattern | `PredictorViewModel.swift:70-72` | Transport `[KVCache]` cross-actor | Pattern à conserver dans `CompletionCache` pour traverser le `container.perform` boundary. [VERIFIED] |
| `MemoizingTokenCounter` + `TokenCountCache` | `Sources/SouffleusePrompt/*` (Phase 1) | Token-count memoization | `CompletionCache` owns it. [VERIFIED: PVM:139] |
| `WordCompleter` | `Sources/SouffleuseTyping/WordCompleter.swift` | Layer 0 NSSpellChecker | `SuggestionPolicy` l'appelle. **Aucun changement à la lib `SouffleuseTyping`**. [VERIFIED: 79 LOC] |
| `historyExactSubstringMatch` | `PredictorViewModel.swift:1524-1549` | Layer 1 history exact-match | `nonisolated static func`, déjà pure — déplacement mécanique vers `SuggestionPolicy`. [VERIFIED] |
| `SimilarHistoryRetrieval` (Jaccard) | `Sources/SouffleusePersonalization/SimilarHistoryRetrieval.swift` | Few-shot pour le prompt LLM, pas la cascade | **Reste in-place.** N'est pas dans la cascade L0/L1/L2 — il alimente le slot `previousUserInputs` du prompt, pas le ghost direct. [VERIFIED] |
| `historySnapshot` mirror | `PredictorViewModel.swift:190` | Snapshot main-actor de l'actor `TypingHistoryStore` | Migre dans `SuggestionPolicy` (qui owns la cascade L1). [VERIFIED] |
| `ChunkSplitter.nextChunk` | `Sources/SouffleuseTyping/ChunkSplitter.swift` | Partial-accept Tab-by-Tab | Reste in-place. Source du signal `acceptable` pour la classification grid. [VERIFIED: AppDelegate:1045] |
| `Log.info(_:_:count:)` | `SouffleuseLog/Log.swift` | `StaticString` event-only logger | Vecteur unique pour les 5 events `ghost_classified_*`. [VERIFIED: `audit.sh` check 6] |
| `SouffleuseCoherence` replay harness | `Sources/SouffleuseCoherence/main.swift:213-490` | JSON scenarios → markdown REPLAY-RESULTS.md | Étendu Phase 4 avec `expectedCategory` (cf. §"Replay harness extension"). [VERIFIED: 592 LOC, `Scenario` v1] |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|---|---|---|
| Garder `SuggestionPolicy` dans le même target `Souffleuse` | Extraire `SouffleusePredictor` SPM target dédié | **Non retenu** : multiplie les diffs `Package.swift`, casse `@testable import Souffleuse` pour les tests existants, pas de gain de réutilisation (rien d'autre ne consommerait le target). Milestone futur. |
| Score scalaire `[0,1]` (D-06) | Vecteur multi-dim (source, prefix_fit, length_fit) gardés séparés | **Non retenu** par D-06 verrouillé. Mais : *garder les composantes loggables individuellement* via une struct `Score` exposant les trois facteurs (cf. §"Confidence scoring") — pas dans le scalar emis, mais inspectable pour debug. |
| Replacement bar `× 1.15` (D-07) | Hystérésis additive (`score_new ≥ score_courant + 0.05`) | **Non retenu** par D-07 verrouillé. Le facteur multiplicatif est plus simple à calibrer car il est *scale-invariant* (un ghost 0.4 demande 0.46, un 0.7 demande 0.805). |
| Émission classification depuis `OverlayWindow.show/hide` | Émission depuis `SuggestionPolicy.Lifecycle` | **`SuggestionPolicy` retenu** — voir §"Classification grid emission points" pour la justification (Overlay ne sait pas la source ni le timing relatif au précédent ghost). |

**Installation:** Aucune. Toutes les dépendances sont déjà résolues dans `Package.resolved`.

**Version verification:** Pas applicable (pas d'ajout). La version `mlx-swift-examples 2.29.1` est verrouillée par Phase 3 et reste compatible : aucune API touchée par Phase 4 (TokenIterator + KVCache) n'est modifiée.

---

## Architecture Patterns

### System Architecture Diagram

```
                                   ┌─────────────────────────────────┐
                                   │  SouffleuseAppDelegate           │
                                   │  (lifecycle, hotkeys, menubar)   │
                                   └────────────────┬─────────────────┘
                                                    │ owns
                                                    ▼
                              ┌────────────────────────────────────────┐
                              │  TypingSession  (NEW — extracted)      │
                              │  • Timer 80ms tick                      │
                              │  • Caret tracking (per-bundle caches)   │
                              │  • Enrichment debounce                  │
                              │  • Live-consume + partial-accept state  │
                              └────────────┬───────────────────────────┘
                                           │ feeds AXSnapshot + prefix
                                           ▼
   ┌────────────────────────────────────────────────────────────────────┐
   │  PredictorViewModel   (FAÇADE — rétrécit à ~150 LOC)               │
   │  Wires:                                                            │
   │    GenerationPlanner ──→ SuggestionPolicy ──→ ModelRuntime         │
   │                              ▲                       │             │
   │                              │                       ▼             │
   │                          CompletionCache (KV cache, memo, tokens)  │
   └────────────────────────────────────────────────────────────────────┘
       │                  ▲                                  │
       │ predict()        │ ghost                            │ container.perform
       │                  │                                  │ (off-MainActor)
       ▼                  │                                  ▼
   ┌──────────────────────────────────┐               ┌──────────────────┐
   │  SuggestionPolicy                │               │  ModelContainer  │
   │  ┌──────────────────────────────┐│               │  (MLX engine)    │
   │  │ Cascade router               ││               └──────────────────┘
   │  │  ├─ Layer 0  → WordCompleter ││
   │  │  ├─ Layer 1  → historyExact  ││
   │  │  └─ Layer 2  → ModelRuntime  ││
   │  ├──────────────────────────────┤│
   │  │ RelevanceGate                ││
   │  │   score = source_prior ×     ││
   │  │           prefix_fit ×       ││
   │  │           length_fit         ││
   │  │   hard-block < 0.25          ││
   │  │   replacement bar × 1.15     ││
   │  ├──────────────────────────────┤│
   │  │ Lifecycle observer           ││
   │  │   emits ghost_classified_*   ││
   │  │   (5 StaticString events)    ││
   │  ├──────────────────────────────┤│
   │  │ Tuning (D-13)                ││
   │  │   single-file constants      ││
   │  └──────────────────────────────┘│
   └──────────────────────────────────┘
                 ▲                ▲
                 │ Tab/Accept     │ Esc/Dismiss
                 │ (full/partial) │
                 │                │
       SouffleuseAppDelegate.handleKey  (CGEventTap thread, unchanged)

   ┌──────────────────────────────────┐
   │  OverlayWindow / PresenceIndicator│  ← unchanged; SuggestionPolicy calls show/hide
   └──────────────────────────────────┘
```

**Lecture du diagramme:**
- Flux d'entrée : `Timer 80ms` → `TypingSession.tick()` lit AX → calcule `prefix` + AXSnapshot → appelle `PredictorViewModel.predict(...)`.
- Le ViewModel délègue au `GenerationPlanner` qui debounce 30ms puis appelle `SuggestionPolicy.route(prefix, snapshot)`.
- `SuggestionPolicy` consulte d'abord `CompletionCache.predictCache[userTail]` (instantané), puis lance la cascade L0/L1/L2.
- Pour L2, `SuggestionPolicy` demande à `GenerationPlanner.schedule(...)` qui possède le compteur de génération et qui appelle `ModelRuntime.generate(...)`.
- `ModelRuntime.generate(...)` consomme `CompletionCache.kvCacheHolder` pour la décision extend/trim/invalidate.
- Stream chunks remontent → `SuggestionPolicy.onLLMChunk(...)` applique anti-churn + Relevance Gate → met à jour le ghost.
- `OverlayWindow.show/hide` est appelé par la façade `PredictorViewModel` (qui lit `suggestion` exposée par `SuggestionPolicy`).

### Recommended Project Structure

```
Sources/Souffleuse/
├── SouffleuseAppDelegate.swift     # rétrécit ~1209 → ~400 LOC
├── TypingSession.swift             # NEW — ~700 LOC extraites de AppDelegate
├── PredictorViewModel.swift        # rétrécit 1566 → ~200 LOC (façade)
├── ModelRuntime.swift              # NEW — MLX I/O (~250 LOC)
├── CompletionCache.swift           # NEW — predictCache + KVCacheHolder + tokenCountCache (~300 LOC)
├── SuggestionPolicy.swift          # NEW — cascade + gate + classification (~500 LOC)
├── SuggestionPolicy+Tuning.swift   # NEW — D-13 constantes (~50 LOC, single source of truth)
├── GenerationPlanner.swift         # NEW — debounce + generation counter + cancel (~150 LOC)
├── KVCacheHolder.swift             # EXISTING — reste tel quel, accédé via CompletionCache
├── CaretResolver.swift             # EXISTING — accédé par TypingSession
└── PreferencesStore.swift          # EXISTING — accédé par AppDelegate

Tests/SouffleuseTests/
├── SuggestionPolicyTests.swift     # NEW — Relevance Gate scoring + routing matrix
├── RelevanceGateTests.swift        # NEW — pure-function tests sur le scorer
├── ClassificationGridTests.swift   # NEW — simulate Tab/Esc/replace, expect counts
├── HistoryExactMatchTests.swift    # EXISTING — étendu pour after-space derrière le Gate
├── KVCacheHolderTests.swift        # EXISTING — inchangé
└── PromptBuilderTests.swift        # EXISTING — inchangé
```

### Pattern 1: `@MainActor` façade + actor / value-type engine

**What:** Tous les nouveaux modules sont `@MainActor` `final class`, comme `PredictorViewModel` aujourd'hui. Là où un état partagé doit traverser `container.perform`, on utilise une struct snapshot `@unchecked Sendable` (pattern `CacheBox` à PVM:70-72).

**When to use:** Toutes les frontières du split. Évite de devoir introduire des actors supplémentaires (qui imposeraient `await` partout et casseraient les call-sites synchrones de la cascade L0/L1).

**Example (verbatim, déjà éprouvé):**
```swift
// Source: PVM:1217-1230 (Phase 3, verbatim)
struct HolderSnapshot: @unchecked Sendable {
    let caches: CacheBox?
    let fingerprint: String?
    let beforeCursorTokens: Int
}
let holderSnap: HolderSnapshot = await MainActor.run {
    if let existing = sessionCacheHolder.caches as? [KVCache] {
        return HolderSnapshot(...)
    }
    return HolderSnapshot(caches: nil, fingerprint: nil, beforeCursorTokens: 0)
}
```

### Pattern 2: Generation counter + cancel-on-keystroke

**What:** Compteur monotone `UInt64` capturé par les closures asynchrones (`myGeneration`) ; tout chunk arrivant avec `self.generation != myGeneration` est silencieusement dropé.

**When to use:** Migre tel quel dans `GenerationPlanner`. Le compteur est l'**identité du predict en cours** ; il sert *à la fois* à invalider les onChunk stale et à la classification grid (pour détecter un `parasite`, on compare la génération de la replaced suggestion à celle de la replacing).

**Example:**
```swift
// Source: PVM:775-776 + :853-854 (verbatim)
generation &+= 1
let myGeneration = generation
// ... in onChunk closure:
guard let self, self.generation == myGeneration else { return }
```

### Pattern 3: `StaticString` event names + count-only logging

**What:** Privacy-by-typesystem. Chaque event audité par `audit.sh` check 6 (forbids interpolation of user fields).

**When to use:** Les 5 events `ghost_classified_*` (D-10) suivent ce pattern. Pas d'exception.

**Example:**
```swift
// Source: PVM:209 (verbatim, KV cache analog)
Log.info(.predictor, "kv_cache_invalidate", count: 3)
// Phase 4 equivalents:
Log.info(.predictor, "ghost_classified_correct", count: shownMs)   // ms ghost was visible
Log.info(.predictor, "ghost_classified_useless", count: shownMs)
Log.info(.predictor, "ghost_classified_bad", count: shownMs)
Log.info(.predictor, "ghost_classified_acceptable", count: chunksAccepted)
Log.info(.predictor, "ghost_classified_parasite", count: shownMs)
```

**Note convention:** `count` est un `Int` — la convention est de l'utiliser pour porter une métadonnée *non-identifiante* (durée ms, nombre de tokens, nombre de chunks). Audit-safe.

### Pattern 4: Atomic-commit per boundary + replay equivalence

**What:** Pattern hérité de Phase 3 (KV cache rollout). Chaque extraction de module = un commit ; entre chaque commit, on lance `swift test` + `bash audit.sh` + `SouffleuseCoherence --replay`. Le replay doit produire des outputs *identiques* à epsilon greedy-near (le KV cache l'a prouvé en Phase 3, cf. `03-02-SUMMARY.md` Success Criterion 5).

**When to use:** Tout au long du split D-03. **Recommandation forte** : run `--replay` AVANT le premier commit du split (baseline) ; après chaque commit le compare contre cette baseline. La divergence = bug d'extraction.

### Anti-Patterns to Avoid

- **Re-tokeniser dans le Policy pour `length_fit`** : `length_fit` doit être calculé sur le *nombre de tokens* (D-06 "2–6 tokens"). Tentation : appeler `MemoizingTokenCounter.countTokens(ghost)` en plein `SuggestionPolicy.onChunk`. Mais : `onChunk` est appelé OFF MainActor (dans `container.perform`). Solution : **dériver `length_fit` du nombre de mots** comme proxy stable on-actor, OU **passer le `tokenCount` calculé par le streamer** (qui le connaît déjà via `tokenCount += 1` à PVM:1397). Recommandation : *mot count* — c'est déjà ce que la prod utilise pour `maxWords`. Discrepancy modèle/Souffleuse : un token = ~0.8 mot en FR ; bell curve 2-6 tokens ≈ 1.5-5 mots.
- **Capturer `self` strongly dans `SuggestionPolicy.onChunk`** : `[weak self]` + `guard let self else { return }` est la convention. Un strong capture créerait un cycle de rétention transitif via `GenerationPlanner.currentTask`.
- **Introduire un actor pour `SuggestionPolicy`** : l'API est appelée depuis main-actor (tick path) ET depuis le onChunk closure (off-actor). Un actor forcerait `await` partout et casserait le pattern synchrone de la cascade L0/L1. **Façade `@MainActor`** est le bon choix — les chemins off-actor (onChunk) appellent `await MainActor.run { policy.onLLMChunk(...) }` (déjà ce que PVM fait à `:853`).
- **Émettre `ghost_classified_parasite` depuis OverlayWindow** : OverlayWindow ne connaît ni la source du ghost remplacé, ni le timestamp du show précédent. Émission *forcément* dans `SuggestionPolicy` (qui maintient la `currentGhost: GhostState`). Cf. §"Classification grid emission points".
- **Fait passer le LLM chunk par la Relevance Gate AVANT l'anti-repeat** : l'anti-repeat (PVM:841 `ghostIsRepeatingPrefix`) doit rester en amont de toute évaluation de score, sinon on score des ghosts garbage. Ordre canonique : *strip overlap → markup clean → anti-repeat → Relevance Gate → anti-churn source-aware → apply*.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---|---|---|---|
| Tokenizer FR/EN | Sous-tokenizer custom pour `length_fit` | Compter les **mots** (`split(whereSeparator: { $0.isWhitespace })`) — déjà ce que la prod utilise pour `maxWords` | Le token-count exact nécessite `MemoizingTokenCounter` qui est off-actor ; bell curve en mots est ε-équivalent. |
| KV cache delta | Recalculer extension token | `KVCacheHolder` existe — déplacer dans `CompletionCache` | Phase 3 a prouvé le delta-input path (cf. `03-02-SUMMARY.md`). |
| Layer 0 / Layer 1 | Reimplementer NSSpellChecker ou history scan | `WordCompleter` + `historyExactSubstringMatch` existent et sont testés | Tous deux marqués `nonisolated` / `public final class`. Pure functions. |
| Generation lifecycle | Manual `OperationQueue` ou `DispatchQueue` | `Task` + `generation: UInt64` counter | Pattern éprouvé Swift 6, déjà utilisé. |
| Privacy audit | Manual log inspection | `audit.sh` (6 checks) | Doit rester vert à chaque commit (D-02 safety net). |
| Replay equivalence diff | Manual comparison | `SouffleuseCoherence --replay` → `REPLAY-RESULTS.md` | Pattern éprouvé Phase 3 (`03-04-PLAN.md`). |
| Confusion matrix rendering | Custom markdown writer | Étendre `renderReplayResults(...)` à `main.swift:367-444` | Le harness sait déjà écrire markdown idempotent. |
| Real-app A/B verification | Build a daily-use logger | Manuel + `ghost_classified_*` count agrégé via `jq` sur `~/Library/Logs/Souffleuse.log` | Le logger existe ; le verdict subjectif est l'output humain. |

**Key insight:** **Aucune nouvelle infrastructure** n'est nécessaire. Toute la phase est de la *réorganisation* + 5 nouveaux events + un nouveau scorer pur. C'est ce qui rend le risque acceptable malgré l'invasivité du diff.

---

## Concrete PVM-region mapping (split → 4 modules)

Tableau exhaustif des régions de `PredictorViewModel.swift` (1566 LOC) et leur destination. Lignes vérifiées par lecture directe.

| PVM lignes | Description | Destination D-03 | Notes migration |
|---|---|---|---|
| 17-20 | `PromptBuilderFlag` (dev-only env var) | **`PredictorViewModel` façade** | Reste lié au ViewModel — c'est un cross-cutting kill-switch, pas un état de cache. |
| 31-34 | `KVCacheBypassFlag` | **`CompletionCache`** | Devient le rollback gate de `CompletionCache`. |
| 41-62 | `PredictDebug` (dev /tmp tracer) | **`PredictorViewModel` façade** | Cross-cutting dev tool ; les 4 nouveaux modules y accèdent par référence. |
| 64-72 | `CacheBox @unchecked Sendable` | **`CompletionCache`** | Helper pour le cross-actor transfer. |
| 89-93 | `LoadState`, `StreamMetrics`, observables | **`PredictorViewModel` façade** | API publique consommée par `SouffleuseAppDelegate` (status UI). Reste sur la façade. |
| 95-109 | `SuggestionSource` enum | **`SuggestionPolicy`** | Type au cœur de la cascade. |
| 109 | `suggestionSource: SuggestionSource` (observable) | **`SuggestionPolicy`** (étendu observable read-thru) | La façade expose `predictor.suggestionSource` via délégation. |
| 111-116 | `container`, `currentTask`, `generation` | `container` → **`ModelRuntime`** ; `currentTask` + `generation` → **`GenerationPlanner`** | Split clean ; ces 3 vivent ensemble dans le pattern actuel mais sont logiquement disjoints. |
| 126-131 | `predictCache` FIFO + capacity | **`CompletionCache`** | Migration mécanique. |
| 139 | `tokenCountCache` | **`CompletionCache`** | Migration mécanique. |
| 149-158 | `lastContextFingerprint` + `sessionCacheHolder` | **`CompletionCache`** | KV cache state appartient à CompletionCache. |
| 160-165 | `modelId`, `maxTokens`, `maxWords` | **`PredictorViewModel` façade** (préférences) ⊕ propagés aux 4 modules | Restent observables ; injectés au runtime. |
| 169-173 | `personalizationStrength`, `history` | **`SuggestionPolicy`** (cascade L1 mirror) ⊕ **`ModelRuntime`** (n-gram bias chain) | Split : `history` snapshot → Policy ; `personalizationStrength` → Runtime. |
| 178-190 | `ngramModel`, `wordCompleter`, `historySnapshot` | `ngramModel` → **`ModelRuntime`** (alimente ChainLogitProcessor) ; `wordCompleter` + `historySnapshot` → **`SuggestionPolicy`** | Frontière naturelle. |
| 195-214 | `swapModel(to:)` | **`ModelRuntime.swap(to:)`** ⊕ délègue à `CompletionCache.invalidate()` | Side-effects chain : Runtime swap → cache invalidate → policy reset. |
| 220-240 | `storeInCache`, `clearPredictCache` | **`CompletionCache`** | Mécanique. |
| 242-269 | `loadModel()` | **`ModelRuntime.load()`** | Mécanique. |
| 276-293 | `autocompleteSystemPrompt`, `buildSystemPrompt(detectedLanguage:)` | **`ModelRuntime`** (préparation du prompt LLM) | Prompt assembly côté Runtime ; SuggestionPolicy ne touche pas au string LLM. |
| 295-317 | `stripPrefixOverlap` | **`ModelRuntime.OutputFilter`** OR **`SuggestionPolicy`** | *Recommandation* : `ModelRuntime.OutputFilter` (sous-namespace) — c'est un nettoyage *du stream*, pas une décision de policy. Les autres filtres (`ghostIsRepeatingPrefix`, markup strip) suivent. |
| 319-355 | `ghostIsRepeatingPrefix` + `hasCompletedFirstWord` + `stripTrailingPartialWord` + `normalizeForRepeatCheck` | **`ModelRuntime.OutputFilter`** | Pure functions ; déplacement clean ; testables hors actor. |
| 415-433 | `capToWords` | **`ModelRuntime.OutputFilter`** | Idem. |
| 441-472 | `detectLanguage(in:)` | **`ModelRuntime`** | Côté préparation du system prompt. |
| 474-503 | `predict(...)` entrée + fingerprint AX | **`PredictorViewModel.predict` (façade)** délègue à `GenerationPlanner.schedule(...)` qui appelle `SuggestionPolicy.route(...)` | Entrée publique — façade reste l'API consommée par AppDelegate/TypingSession. |
| 504-521 | Source decay (HIGH → llm) | **`SuggestionPolicy`** | Pure cascade logic. |
| 525-609 | Cascade L0/L1 sync (instantGhost computation + stability gate) | **`SuggestionPolicy.route(...)`** | Cœur de la migration. À ce point, le Relevance Gate (D-05..D-08) remplace l'actuelle stability gate (PVM:587-609). |
| 611-647 | LLM gate (>= 3 chars + container guard) + cache_hit | **`SuggestionPolicy.route(...)`** consulte `CompletionCache.lookup(userTail:)` | Mécanique. |
| 666-692 | Undo-as-ghost (longest cache key match) | **`SuggestionPolicy`** consulte `CompletionCache.longestExtendingKey(userTail:)` | Logique stays in Policy ; lookup goes to Cache. |
| 694-715 | `hasFieldHint` empty-no-context gate | **`SuggestionPolicy`** | Reste in Policy. |
| 717-769 | Build systemMessage + basePreamble | **`ModelRuntime.prepareInput(...)`** | Préparation prompt côté Runtime. |
| 772-776 | `previousTask?.cancel()` + `generation &+= 1` | **`GenerationPlanner.cancelAndIncrement()`** | Atomique. |
| 782-914 | `onChunk` closure (le BIG block) | Split en 3 : (a) `ModelRuntime.OutputFilter.clean(...)` (overlap strip, markup, truncation, words cap) ; (b) `SuggestionPolicy.onLLMChunk(...)` (anti-churn source-aware **+ NEW Relevance Gate**) ; (c) `GenerationPlanner` plumbing (generation check, MainActor.run hop) | **C'est le cœur de la complexité.** Voir §"Cascade routing decision matrix" pour le shape final. |
| 917-925 | Captures (personalizationStrength, ngramModel, history, fewShotK, caches) | **`GenerationPlanner.schedule(...)`** prepare la capture map ; expose-le aux 4 modules | Capture explicite via une `PredictRequest` struct sendable. |
| 927-965 | Hoisted slot bodies (baseSystem, customInstr, ctxPrefix, fieldContextSlot, afterCursorSlot) | **`ModelRuntime.buildSlots(...)`** | Déjà extraits Phase 3 (`03-02-SUMMARY.md`) ; juste à les déplacer. |
| 967-1008 | `currentTask = Task { ... }` orchestration | **`GenerationPlanner.schedule(...)`** | C'est exactement le rôle du Planner. |
| 982-1004 | `examplesBlock` (few-shot async retrieval) | **`ModelRuntime.prepareFewShot(personalizationStrength:history:userTail:k:)`** | Off-actor await ; idéal pour Runtime. |
| 1009-1412 | `container.perform { context -> StreamMetrics in ... }` (le LARGEST closure) | **`ModelRuntime.generate(request:cache:onChunk:)`** retourne `StreamMetrics` | Encapsule le PromptBuilder, le KV decision tree, le TokenIterator, le stream consumption. Consulte `CompletionCache` via une référence injectée. |
| 1163-1311 | KV cache decision tree | **`CompletionCache.decideExtendTrimInvalidate(invariance:userTailTokenCount:)`** retourne un `KVDecision` enum | Pure logic ; le `Runtime` consomme la décision. |
| 1389-1411 | Stream consumption loop + StreamMetrics | **`ModelRuntime.generate(...)`** internal | Reste interne à Runtime. |
| 1414-1457 | Post-stream commit (TTFT log, llm_done_stored, storeInCache) | **`GenerationPlanner`** dispatch → **`CompletionCache.store(...)`** + **`SuggestionPolicy.onLLMStreamEnded(...)`** | L'event "stream ended" alimente la classification grid (cf. §"Classification grid emission"). |
| 1463-1486 | `rebuildPersonalization` | **`ModelRuntime`** + bump `historySnapshot` via **`SuggestionPolicy`** | Split via callbacks. |
| 1489-1508 | `ingestAccepted` | **`ModelRuntime`** + **`SuggestionPolicy.appendToHistory`** | Idem. |
| 1524-1549 | `historyExactSubstringMatch` (nonisolated static) | **`SuggestionPolicy`** | Pure function ; déplacement mécanique. |
| 1551-1565 | `cancel()` | **`PredictorViewModel.cancel()` (façade)** délègue à `GenerationPlanner.cancel()` + `SuggestionPolicy.reset()` | Side-effects chain. |

**Conclusion mapping:** Le ratio est ≈ 35% **SuggestionPolicy** (~550 LOC), ≈ 30% **ModelRuntime** (~470 LOC), ≈ 20% **CompletionCache** (~310 LOC), ≈ 10% **GenerationPlanner** (~150 LOC), ≈ 5% **façade `PredictorViewModel`** (~80 LOC sans compter les observables + lifecycle). Total ≈ 1560 LOC (= la PVM actuelle), aucune duplication, +Relevance Gate (~100 LOC nouvelles dans Policy).

---

## Concrete extraction plan TypingSession (D-04)

Tableau exhaustif des régions de `SouffleuseAppDelegate.swift` (1209 LOC) et leur destination.

| AppDelegate lignes | Description | Reste / Migre |
|---|---|---|
| 19-44 | Bundle blocklists (privacy) | **Reste** AppDelegate (privacy constants). |
| 47-64 | Status item, overlay, presence, interceptor, predictor, pollTimer, onboarding, customInstructions, prefs, historyViewer, hotkeyMonitor | **Reste** AppDelegate (UI windows + global lifecycle). |
| 65-78 | `lastCaretRectByApp`, `lastCaretRectTimestampByApp`, `caretRectTTL` | **Migre** → `TypingSession` |
| 80-89 | `textAtFocusByBundle`, `lastFocusedBundleID` | **Migre** → `TypingSession` |
| 92-96 | `caretResolver`, `caretRefinementPending` | **Migre** → `TypingSession` (CaretResolver est sa dep) |
| 99 | `dismissedForText` | **Migre** → `TypingSession` (Esc dismissal state) |
| 102-130 | `lastPredictedPrefix`, `predictDebounceTask`, `predictDebounceNanos` | **Migre** → `TypingSession` ⊕ debounce → `GenerationPlanner` (cohérence : Planner devrait porter le debounce, pas Session — voir note ↓) |
| 132 | `enricher: ContextEnricher` | **Migre** → `TypingSession` (cascade enrichissement) |
| 133-137 | `typoDetector`, `currentTypo` | **Reste** AppDelegate ? OU **Migre** → `TypingSession` ? *Recommandation : TypingSession* — typo est observé au tick, dépend du focus, et son cycle de vie (set/cancel/accept) est entrelacé avec le predict gate. |
| 143-159 | `partialRemainder`, `partialAcceptedSoFar`, `partialAcceptedAtPrefix`, `partialAcceptedAtBundleID`, `lastEnrichedBundleID`, `cachedEnrichmentPrefix`, `lastOCRLangsApplied` | **Migre** → `TypingSession` |
| 164-235 | `applicationDidFinishLaunching` | **Reste** AppDelegate (boot lifecycle) ; appelle `session.start()` à la fin |
| 239-249 | Onboarding | **Reste** |
| 254-282 | Hotkey | **Reste** |
| 288-355 | `observePreferences` + `handlePreferenceChange` | **Reste** AppDelegate (UI obs) ; transmet à `session.applyPreferences(...)` |
| 357-369 | `applyOCRLangsIfNeeded`, `applyCaptureToggle` | **Migre** → `TypingSession` (touche enricher) ou **Reste** ? *Recommandation : Reste sur AppDelegate* — c'est une cross-cutting concern OCR/permission. Session a juste à consommer `enricher` qui a déjà été configuré. |
| 371-432 | Status item icon | **Reste** AppDelegate |
| 434-499 | Edit menu shortcuts, history viewer, clear personalization | **Reste** AppDelegate (UI) |
| 501-528 | `refreshStatusItem`, helpers menubar | **Reste** |
| 532-546 | `tickThrottled` | **Migre** → `TypingSession` |
| 548-992 | `tick()` (le BIG method) | **Migre** → `TypingSession.tick()` (l'essentiel — ~450 LOC) |
| 994-1184 | `handleKey` (Tab/Esc CGEventTap, runs on tap thread) | **Reste** AppDelegate ? **OU Migre** → `TypingSession`. *Recommandation : reste sur AppDelegate*, mais split en deux helpers : `session.handleTab(suggestion:isPartial:)` et `session.handleEsc()`. AppDelegate garde le `nonisolated handleKey` parce qu'il est sur le tap thread et doit `MainActor.assumeIsolated` ; la logique de traitement (recordPartialAcceptance, dismissedForText set, etc.) migre dans `TypingSession`. |
| 1191-1208 | `recordPartialAcceptanceToHistoryIfAllowed` | **Migre** → `TypingSession` (state owner) |

**Note sur le debounce predict (AppDelegate:106 `predictDebounceTask`):** D-04 dit que le debounce enrichment migre dans `TypingSession`. Mais il y a *deux* debounces : (a) enrichment debounce (`lastEnrichedBundleID`/`cachedEnrichmentPrefix`, basé sur change de bundle), (b) **predict debounce** (`predictDebounceNanos = 30ms`, basé sur change de prefix). Le (b) appartient sémantiquement à `GenerationPlanner` (c'est le rythme du LLM). **Recommandation:** déplacer `predictDebounceNanos` + `predictDebounceTask` dans `GenerationPlanner`. AppDelegate/`TypingSession` appelle `predictor.predict(...)` sans se soucier du timing — le Planner décide quand armer le Task.

**Pourquoi cet ordre (PVM split en premier, D-01) est correct:** Une fois `GenerationPlanner` extrait, l'extraction `TypingSession` devient triviale car le debounce predict n'est plus dans AppDelegate. Si on faisait `TypingSession` d'abord, il faudrait soit dupliquer le debounce, soit le déplacer deux fois.

---

## Confidence scoring formula + Swift type sketch

### Formule (D-06 verrouillée)

```
score(source, ghost, userTail) = source_prior(source) × prefix_fit(ghost, userTail) × length_fit(ghost)

source_prior:
  .wordComplete  → 0.55
  .history       → 0.75
  .llm           → 0.60
  .cache         → 0.70  (héritage d'un LLM déjà accepté pour ce prefix)
  .undoCache     → 0.65  (héritage d'un LLM accepté mais user a backspacé)
  .none          → 0.0   (rien à scorer)

prefix_fit (boolean × ε, pas continue):
  cas mid-word (userTail.last is word-char):
    ghost.lowercased() commence par le partial word complement → 1.0
    sinon                                                       → 0.0
  cas after-space (userTail.last is whitespace OR isEmpty):
    ghost ne commence pas par un word-char attaché à un autre symbole → 1.0
    ghost commence par un caractère "natural continuation" → 1.0
    sinon (ghost commence par un terminator, un emoji, du markup résiduel) → 0.0

length_fit (bell curve sur word count):
  let w = ghost.split(whereSeparator: { $0.isWhitespace }).count
  switch w:
    0       → 0.0  (vide — déjà filtré upstream mais défensif)
    1       → 0.6
    2..3    → 1.0
    4..5    → 1.0   (proche du sweet spot 2-6 tokens en FR)
    6       → 0.85
    7..8    → 0.6
    9+      → 0.3   (trop long après une espace → bavard)
```

**Note D-13 (constantes tunables):** Tous les seuils ci-dessus (priors `[0.55, 0.75, 0.60, 0.70, 0.65]`, bell curve table `[0, 0.6, 1.0, 1.0, 1.0, 1.0, 0.85, 0.6, 0.6, 0.3]`, gate threshold `0.25`, replacement multiplier `1.15`, after-space L1 bar `0.4`, L2-upgrade delta `0.15`) doivent vivre dans `SuggestionPolicy+Tuning.swift` — un unique fichier `private enum Tuning` accessible aux unit tests via `@testable`.

### Type sketch (Swift 6, value-type Sendable)

```swift
// Source: nouveau fichier Sources/Souffleuse/SuggestionPolicy.swift
// Pattern: pure-function scorer testable hors actor. ASSUMED based on Phase 3
// patterns and CONTEXT.md D-06.

struct Score: Sendable, Equatable, CustomStringConvertible {
    let sourcePrior: Float
    let prefixFit: Float
    let lengthFit: Float

    var value: Float { sourcePrior * prefixFit * lengthFit }

    /// True iff the ghost passes the hard floor (D-07).
    var passesGate: Bool { value >= SuggestionPolicy.Tuning.gateFloor }

    /// True iff this score beats the current ghost's score by the
    /// replacement bar (D-07). Used in `SuggestionPolicy.shouldReplace(...)`.
    func beats(_ other: Score) -> Bool {
        value >= other.value * SuggestionPolicy.Tuning.replacementBar
    }

    var description: String {
        "Score(src=\(sourcePrior) pref=\(prefixFit) len=\(lengthFit) → \(value))"
    }
}

enum SuggestionPolicy {
    enum Tuning {
        static let gateFloor: Float = 0.25
        static let replacementBar: Float = 1.15
        static let afterSpaceL1Bar: Float = 0.4
        static let l2UpgradeDelta: Float = 0.15

        static let sourcePrior: [PredictorViewModel.SuggestionSource: Float] = [
            .wordComplete: 0.55,
            .history:      0.75,
            .llm:          0.60,
            .cache:        0.70,
            .undoCache:    0.65,
            .none:         0.0,
        ]

        // Bell curve over WORD COUNT (not token count — see anti-pattern).
        static let lengthFitByWordCount: [Float] = [
            0.0, 0.6, 1.0, 1.0, 1.0, 1.0, 0.85, 0.6, 0.6, 0.3,
            // 10+: returns last
        ]
    }

    static func score(
        source: PredictorViewModel.SuggestionSource,
        ghost: String,
        userTail: String
    ) -> Score {
        let prior = Tuning.sourcePrior[source] ?? 0.0
        let prefix = prefixFit(ghost: ghost, userTail: userTail)
        let length = lengthFit(ghost: ghost)
        return Score(sourcePrior: prior, prefixFit: prefix, lengthFit: length)
    }

    // ... prefixFit, lengthFit private statics ...
}
```

**Loggability:** Le `Score` n'est *pas* loggué directement (privacy ; il porte du contexte sémantique sur le ghost). Mais on peut logger `score.value` × 100 cast en `Int` pour audit traçability sans franchir l'invariant `audit.sh` check 6. Exemple : `Log.info(.predictor, "ghost_gate_pass", count: Int(score.value * 100))`.

**Trade-off documented:** `prefix_fit` est intentionnellement binaire (`{0.0, 1.0}`) plutôt que continu. Justification : D-06 dit "1.0 si le ghost commence par le mot courant ; 0.0 si divergent". Un `prefix_fit` continu (ex. `editDistance / maxLen`) introduirait du bruit que la classification grid ne saurait pas attribuer. Bell curve continue est *seulement* sur `length_fit` parce que la longueur est la dimension la plus continue de la perception.

---

## Cascade routing decision matrix

### Truth table (D-08 verrouillé)

| cas | userTail.last | Layer disponible | Décision | Output |
|---|---|---|---|---|
| 1 | word-char (mid-word) | L0 only | route(L0) → score | si `score.passesGate` → show ; sinon → hide |
| 2 | word-char (mid-word) | L0 + cache hit | cache wins (déjà LLM-resolved) | apply cache (source=.cache) → score |
| 3 | word-char (mid-word) | L0 + L2 stream | L0 only (L2 doesn't do mid-word cleanly) | reject L2 chunks via `prefix_fit=0` (le ghost LLM ne commence pas par le partial word) |
| 4 | whitespace (after-space) | L1 hit only | route(L1) → score | si `score.value ≥ 0.4` → show ; sinon → fall through to L2 |
| 5 | whitespace (after-space) | L1 hit + L2 stream | L1 first ; L2 may upgrade | show L1 ; quand L2 stream arrive, si `score_L2 ≥ score_L1 + 0.15` → swap ; sinon → keep L1 |
| 6 | whitespace (after-space) | L2 only | L2 → score | si `score.passesGate` → show |
| 7 | whitespace (after-space) | rien | hide | — |
| 8 | empty prefix (`< 3 chars` OR `!hasCompletedFirstWord` AND no field hint) | gate fires | hide | (PVM:611-715 logic preserved) |
| 9 | replacement candidate | source A current, source B new | si `B.beats(A)` → swap **+ emit `ghost_classified_parasite` if within stability window** | sinon → keep + log `ghost_keep_*` |

### Code-level integration points

```swift
// Source: nouveau fichier Sources/Souffleuse/SuggestionPolicy.swift
// Réécriture conceptuelle de PVM:525-609 + onChunk:782-913

@MainActor
final class SuggestionPolicy {
    private(set) var currentGhost: String = ""
    private(set) var currentSource: PredictorViewModel.SuggestionSource = .none
    private(set) var currentScore: Score = Score(sourcePrior: 0, prefixFit: 0, lengthFit: 0)
    private var shownAt: Date?  // for classification timing (D-09)
    private var lastReplacedSource: PredictorViewModel.SuggestionSource = .none  // for parasite detection

    /// Synchronous routing for L0/L1 cascade (sub-ms). Called on the
    /// predict() entry path from PredictorViewModel façade.
    func routeInstant(
        userTail: String,
        historySnapshot: [TypingHistoryEntry],
        wordCompleter: WordCompleter
    ) -> GhostUpdate? {
        let isAfterSpace = userTail.last?.isWhitespace ?? true
        let isMidWord = !isAfterSpace && (userTail.last?.isLetter ?? false)

        if isMidWord {
            // Cas 1/3: L0 exclusive
            guard let completion = wordCompleter.completion(for: userTail),
                  completion.count >= 3
            else { return nil }
            let score = SuggestionPolicy.score(source: .wordComplete, ghost: completion, userTail: userTail)
            guard score.passesGate else { return nil }
            return GhostUpdate(text: completion, source: .wordComplete, score: score)
        }
        if isAfterSpace {
            // Cas 4: L1 first
            if let hit = PredictorViewModel.historyExactSubstringMatch(userTail: userTail, snapshot: historySnapshot) {
                let capped = PredictorViewModel.capToWords(hit, max: maxWords)
                let score = SuggestionPolicy.score(source: .history, ghost: capped, userTail: userTail)
                if score.value >= Tuning.afterSpaceL1Bar {
                    return GhostUpdate(text: capped, source: .history, score: score)
                }
            }
            return nil  // L2 will fill in via stream (cas 5/6)
        }
        return nil  // Cas 7
    }

    /// Called from `onChunk` (off-actor → MainActor.run hop already done).
    /// Applies anti-churn source-aware + Relevance Gate replacement bar.
    func onLLMChunk(_ chunk: String, userTail: String) {
        let isMidWord = userTail.last?.isLetter ?? false
        if isMidWord {
            // Cas 3: drop LLM chunks during mid-word — L0 owns it
            Log.info(.predictor, "ghost_gate_block_midword", count: chunk.count)
            return
        }

        let score = SuggestionPolicy.score(source: .llm, ghost: chunk, userTail: userTail)
        guard score.passesGate else {
            Log.info(.predictor, "ghost_gate_block", count: Int(score.value * 100))
            return
        }

        // Replacement bar (D-07): must beat current × 1.15
        if !currentGhost.isEmpty {
            // Cas 5: L2 upgrade requires score_L2 ≥ score_L1 + 0.15
            let upgradeRequired = currentSource == .history
            let beatsBar = score.beats(currentScore)
            let l2UpgradesL1 = upgradeRequired && (score.value >= currentScore.value + Tuning.l2UpgradeDelta)
            guard beatsBar || l2UpgradesL1 else {
                Log.info(.predictor, "ghost_keep_under_bar", count: currentGhost.count)
                return
            }
            // Parasite detection: replacement happened within stability window
            if let shownAt, Date().timeIntervalSince(shownAt) < Tuning.parasiteWindow {
                Log.info(.predictor, "ghost_classified_parasite", count: Int(Date().timeIntervalSince(shownAt) * 1000))
            }
        }
        applyGhost(chunk, source: .llm, score: score)
    }

    private func applyGhost(_ text: String, source: PredictorViewModel.SuggestionSource, score: Score) {
        lastReplacedSource = currentSource
        currentGhost = text
        currentSource = source
        currentScore = score
        shownAt = Date()
    }
}

struct GhostUpdate: Sendable, Equatable {
    let text: String
    let source: PredictorViewModel.SuggestionSource
    let score: Score
}
```

**Note importante:** la "stability window" pour la détection `parasite` est une constante D-13 tunable (recommandation initiale : `parasiteWindow = 0.8s` — couvre le typical typing pause sans inclure les replacements legitimate post-typing-pause). Aujourd'hui PVM:587-608 implemente une stability gate ad-hoc ; le nouveau code la remplace par cette fenêtre + replacement bar.

---

## Runtime State Inventory

> Phase 4 implique un refactor + déplacement de logging events. À jour de la check-list runtime-state.

| Category | Items Found | Action Required |
|---|---|---|
| **Stored data** | Aucun renommé. `~/Library/Application Support/Souffleuse/history.aes` (TypingHistoryStore) inchangé. `~/Library/Application Support/Souffleuse/allowlist.json` inchangé. `~/Library/Logs/Souffleuse.log` continue d'accepter les 5 nouveaux events `ghost_classified_*` car ils respectent le schéma `{ts, level, module, event, count}` (audit.sh check 4). | Aucune — none — vérifié par lecture audit.sh. |
| **Live service config** | Aucun (pas de services externes). | None — verified by lecture PROJECT.md "Pas de réseau au runtime". |
| **OS-registered state** | Aucun (pas de LaunchAgent, pas de Task Scheduler). Le `LSUIElement = true` + bundle ID `app.cocotypist.Souffleuse` inchangés. | None — verified by lecture `Souffleuse/Resources/Info.plist`. |
| **Secrets/env vars** | `SOUFFLEUSE_DISABLE_KV_CACHE`, `SOUFFLEUSE_PROMPT_BUILDER`, `SOUFFLEUSE_PREDICT_LOG`, `SOUFFLEUSE_MODEL`, `SOUFFLEUSE_CONTEXT`, `SOUFFLEUSE_PENALTY` — tous **inchangés**. Phase 4 n'en introduit pas de nouveau. | None — code edit only if `KVCacheBypassFlag` est déplacé de `PredictorViewModel.swift` → `CompletionCache.swift`, le nom de l'env var reste **EXACTEMENT** identique (sinon les users en prod casseraient leur rollback). [VERIFIED: PVM:31-34] |
| **Build artifacts** | Aucun build artifact d'autre target n'est impacté. Les 5 nouveaux fichiers Swift se compilent dans le target `Souffleuse` existant. `Package.swift` reste inchangé (sauf si la décision opt-in d'extraire un target SPM est prise — *non recommandé Phase 4*). | None — aucun rebuild de target externe nécessaire. |

**Le canonical test:** *Après que tout le refactor est commité, quels runtime systems retiennent encore l'ancien comportement ?* Réponse : **les caches en mémoire dans le process actif au moment du rebuild** — c.-à-d. `predictCache`, `tokenCountCache`, `sessionCacheHolder`, `historySnapshot`. Tous sont reconstruits au prochain launch (pas de persistence cross-launch — cf. D-KV-07). **Donc : zero migration nécessaire au moment du first-run post-Phase-4.** Le user accepte un cold cache la première fois, identique à un model swap.

---

## Common Pitfalls

### Pitfall 1: Generation counter shared between modules

**What goes wrong:** Le compteur `generation: UInt64` est référencé par (a) `predict()` qui l'incrémente, (b) `onChunk` closure qui le capture sous `myGeneration` au moment de la création, (c) le post-stream commit (PVM:1426 `guard self.generation == myGeneration else { return }`), (d) `cancel()` qui l'incrémente. Si le compteur migre dans `GenerationPlanner` mais qu'un onChunk reçu après extraction capture une référence STALE au compteur (par exemple parce que la façade a recréé le Planner entre temps), des chunks "vieux" peuvent leak dans la suggestion.

**Why it happens:** Le pattern "capture by value at closure creation time" du Swift 6 est l'antidote, mais il dépend d'une discipline stricte. Si on capture `[weak planner]` au lieu de `[planner = self.planner]`, et que `self.planner` est remplacé entre-temps, on a un bug.

**How to avoid:** **Tousser le compteur dans `GenerationPlanner` comme `let myGeneration = await planner.beginGeneration()` retournant un `Generation` token, et passer ce token EXPLICITEMENT dans le `request: PredictRequest` au lieu de le capturer par closure.** Le token est `Equatable` ; le check devient `guard token == planner.currentGeneration else { return }`. Plus localement testable.

**Warning signs:** Tests qui dépendent de l'ordre de prédiction passent intermittently. `ghost_classified_parasite` augmente sans transition humaine visible.

### Pitfall 2: Cascade re-entry during partial-accept

**What goes wrong:** Pendant un partial-accept (`AppDelegate:1044-1104` ChunkSplitter Tab), le tick continue à 80ms. Si `partialRemainder.isEmpty == false`, AppDelegate skip predict (`AppDelegate:823-892`). Mais après le refactor TypingSession + nouvelle Policy, si la frontière est mal posée, le Policy peut être appelé pour une cascade L0/L1 fresh pendant qu'un partial remainder est encore en cours d'injection. → ghost flicker partial → cascade → partial.

**Why it happens:** L'état `partialRemainder` vit sur AppDelegate aujourd'hui ; il migre dans TypingSession ; mais la PVM façade ne sait pas s'il y a un partial en cours. Si le tick call path inclut `predictor.predict(...)` sans un guard partial, on déclenche la cascade.

**How to avoid:** **`TypingSession.tick()` doit garder le guard `if !partialRemainder.isEmpty { return après render }`** (le code actuel à AppDelegate:823 le fait) AVANT d'appeler `predictor.predict(...)`. Le SuggestionPolicy ne doit jamais voir un predict pendant un partial. Test cible : `partialAcceptRendersWithoutCascadeReentry`.

**Warning signs:** Pendant un Tab walk, le ghost flicke entre le remainder et une fresh L0 suggestion. La classification grid voit `parasite` répétés.

### Pitfall 3: Source decay mid-stream

**What goes wrong:** PVM:504-521 implémente une "source decay" (HIGH → llm si predict reçu après set HIGH). Si cette logique migre dans `SuggestionPolicy` mais qu'elle n'est appelée que sur entrée de `route(...)` (pas sur entrée de `onLLMChunk(...)`), alors un onChunk arrivant après le decay verra source = `.llm` et appliquera l'anti-churn `false` (LOW path) → un chunk court overwrite un ghost HIGH.

**Why it happens:** Le decay et l'anti-churn sont deux flux qui se croisent. Il faut un point de décision unique (`SuggestionPolicy.currentSource`) qui se met à jour de manière atomique.

**How to avoid:** Le decay reste à l'entrée du predict (call à `policy.beginPredict(...)` qui fait `currentSource = .llm` si HIGH stale). C'est cohérent avec D-07 replacement bar qui s'applique uniformément.

**Warning signs:** Le user voit son ghost HIGH (history match correct) se faire remplacer par un ghost LLM différent quelques ms plus tard.

### Pitfall 4: Replay equivalence break due to fingerprint change

**What goes wrong:** Si l'extraction de `CompletionCache` change subtilement l'ordre de canonicalisation du `examplesBlock` (PVM:1185 `InvariancePrefix.canonicalizePreviousUserInputs`), le fingerprint change pour TOUS les scénarios et le replay diverge — alors qu'aucun changement sémantique n'a eu lieu.

**Why it happens:** L'extraction mécanique manque l'ordre exact de l'appel à `canonicalizePreviousUserInputs` (qui doit se faire AVANT la construction de `InvariancePrefix`).

**How to avoid:** Test snapshot `KVCacheInvarianceFingerprintStableAcrossSplit` qui compare le fingerprint sur 10 scénarios fixés avant/après le split. Pré-Phase-4 baseline déjà committé via Phase 3 (le `03-02-SUMMARY.md` Warning #2 mentionne explicitement ce risque).

**Warning signs:** `kv_cache_invalidate` count=1 (.fingerprintChanged) augmente massivement sans changement de prefix invariant.

### Pitfall 5: Classification grid double-counting on quick replace

**What goes wrong:** Si le ghost A est remplacé par ghost B dans la stability window (`parasite` event), puis B est remplacé par C aussi dans la stability window de B, on emet 2 `parasite` events — mais dépendant de l'implémentation, on peut counter ces transitions comme `useless` aussi (parce que A n'a jamais été accepted), produisant une release-gate violation artificielle.

**Why it happens:** Les catégories D-09 ne sont pas mutually exclusive si on n'est pas discipliné sur "1 ghost lifecycle = 1 event". Un ghost qui meurt par "parasite" ne meurt PAS aussi par "useless".

**How to avoid:** **Émettre AU PLUS UN event de classification par ghost-lifetime**. Le ghost lifetime se termine soit par accept (correct/acceptable), soit par dismiss (useless), soit par divergence (bad), soit par replacement (parasite). Mutually exclusive. `SuggestionPolicy.endLifecycle(reason:)` est le call-site unique. Test : `classificationGridEmitsExactlyOneEventPerGhost`.

**Warning signs:** `ghost_classified_useless + parasite > total ghosts shown`.

### Pitfall 6: Tunable constants drift between Tuning enum and tests

**What goes wrong:** D-13 dit "constantes tunables centralisées". Si un test hardcode `0.25` au lieu de référencer `SuggestionPolicy.Tuning.gateFloor`, modifier le seuil casse silentement la classification mesurée sans casser les tests.

**How to avoid:** Convention : aucune valeur literale numérique des seuils dans les tests. Tous via `Tuning.*`. Grep CI : `grep -nE "0\.(25|4|15|6|7|55|75)" Tests/SouffleuseTests/*Policy*` doit retourner 0 hits (sauf dans `Tuning.swift` lui-même).

---

## Classification grid emission points

**Décision retenue:** Émission dans `SuggestionPolicy.endLifecycle(reason:)`, **PAS** dans `OverlayWindow.show/hide`.

### Pourquoi pas OverlayWindow

- OverlayWindow.show(text:at:hostText:caretIndex:hostFont:) ne connaît pas la **source** du ghost (history vs LLM vs wordComplete).
- OverlayWindow.hide() est appelé pour de multiples raisons (focus change, AX gate fail, blocklist, ghost vide) — la plupart ne sont pas des "dismissals" significatifs au sens classification.
- OverlayWindow ne sait pas si un Tab vient d'être pressé (handleKey est dans AppDelegate).

### Mécanisme proposé (SuggestionPolicy.endLifecycle)

```swift
// Source: nouveau code Sources/Souffleuse/SuggestionPolicy.swift
// ASSUMED based on D-09/D-10 mappings.

enum LifecycleEndReason: Sendable {
    case acceptedFull        // Tab full → correct
    case acceptedPartial(chunks: Int)  // Tab partial → acceptable
    case dismissedByEsc      // Esc → useless if shown ≥ 200ms with zero overlap
    case typedPastWithoutOverlap // user typed text, prefix grew but ghost not consumed → useless
    case typedDiverged       // next typed word ≠ ghost first word within 500ms → bad
    case replacedByOther     // a new ghost displaced this one within stability window → parasite
    case replacedByOtherStable // outside stability window — not a parasite, just a legit refresh
    case modelSwap, esc, focusChange, blocklist  // silent — no classification
}

func endLifecycle(reason: LifecycleEndReason) {
    guard !currentGhost.isEmpty, let shownAt else { return }
    let visibleMs = Int(Date().timeIntervalSince(shownAt) * 1000)
    switch reason {
    case .acceptedFull:
        Log.info(.predictor, "ghost_classified_correct", count: visibleMs)
    case .acceptedPartial(let chunks):
        Log.info(.predictor, "ghost_classified_acceptable", count: chunks)
    case .dismissedByEsc, .typedPastWithoutOverlap:
        if visibleMs >= Tuning.uselessMinVisibleMs {
            Log.info(.predictor, "ghost_classified_useless", count: visibleMs)
        }
    case .typedDiverged:
        if visibleMs <= Tuning.badMaxDivergeMs {
            Log.info(.predictor, "ghost_classified_bad", count: visibleMs)
        }
    case .replacedByOther:
        Log.info(.predictor, "ghost_classified_parasite", count: visibleMs)
    case .replacedByOtherStable, .modelSwap, .esc, .focusChange, .blocklist:
        break  // silent
    }
    // Reset state — never double-emit
    currentGhost = ""
    currentSource = .none
    currentScore = Score(sourcePrior: 0, prefixFit: 0, lengthFit: 0)
    shownAt = nil
}
```

### Call sites that invoke `endLifecycle`

| Call site | Action | Reason |
|---|---|---|
| `SouffleuseAppDelegate.handleKey(.tab)` full-accept branch (AppDelegate:1107-1146) | → `session.handleAccept(full: suggestion)` → `policy.endLifecycle(.acceptedFull)` | `correct` |
| `SouffleuseAppDelegate.handleKey(.tab)` partial-accept (AppDelegate:1044-1104) | → `policy.endLifecycle(.acceptedPartial(chunks: 1))` on each Tab ; on isLast → `.acceptedFull` | `acceptable` puis `correct` |
| `SouffleuseAppDelegate.handleKey(.esc)` (AppDelegate:1148-1182) | → `policy.endLifecycle(.dismissedByEsc)` | `useless` si visible ≥ 200ms |
| `TypingSession.tick()` divergence detected (`prefix.hasPrefix(expected) == false` à AppDelegate:875+) | → `policy.endLifecycle(.typedDiverged)` OR `.typedPastWithoutOverlap` selon que le `typedSince` matche ou pas le ghost | `bad` ou `useless` |
| `SuggestionPolicy.applyGhost(...)` quand un ghost remplace l'actuel et `Date().timeIntervalSince(shownAt) < parasiteWindow` | inline emit avant `applyGhost(...)` | `parasite` |
| `TypingSession.tick()` focus change / blocklist | → `policy.endLifecycle(.focusChange)` (silent) | — |

**Pourquoi le visible-ms threshold pour `useless` (D-09 "≥ 200ms"):** Un ghost qui disparaît en moins de 200ms n'a probablement jamais été *perçu* par l'utilisateur (les saccades visuelles font ~100ms). Pas de classification = pas d'événement = pas de dénominateur biaisé. Tuning : `Tuning.uselessMinVisibleMs = 200`.

**Pourquoi le `bad` window (D-09 "500ms"):** Le user doit avoir tapé quelque chose dans les 500ms après l'apparition du ghost pour qualifier comme "diverge active". Au-delà, c'est juste de l'inattention. Tuning : `Tuning.badMaxDivergeMs = 500`.

---

## Replay harness extension shape (D-12)

### Input format change (`replay-scenarios.json` schema v2)

```diff
 {
   "version": 1,
   "scenarios": [
     {
       "id": "fr-empty-email-subject",
       "label": "...",
       "bundleID": "com.apple.mail",
       "windowTitle": "Nouveau message",
       "contextPrefix": "...",
       "userTail": "",
       "notes": "...",
       "customInstructions": null,
       "role": "AXTextField",
       "subrole": null,
       "placeholder": "Sujet",
       "help": null,
-      "textAfterCaret": null
+      "textAfterCaret": null,
+      "expectedCategory": "correct"          // NEW — optional v2 field
+      "expectedGhostPrefix": "Réunion"       // NEW — optional, what the ghost should start with
     }
   ]
 }
```

**Compat strategy:** v1 scenarios stay valid (Optional decoding). Bump `version` from `1` → `2`. Add an enum:

```swift
// Source: Sources/SouffleuseCoherence/main.swift extension to Scenario struct
struct Scenario: Codable, Sendable {
    // ... existing fields ...
    let expectedCategory: ExpectedCategory?
    let expectedGhostPrefix: String?
}

enum ExpectedCategory: String, Codable, Sendable, CaseIterable {
    case correct       // ghost matches the expected continuation exactly
    case acceptable    // ghost is a plausible alternative
    case useless       // ghost is generic / weak
    case bad           // ghost actively diverges
    case parasite      // not reachable in replay (no live cascade)
    case skip          // skip classification — info only
}
```

### Output: confusion matrix in REPLAY-RESULTS.md (rendered by `renderReplayResults(...)`)

```markdown
# Replay Results — Phase 4 Cascade Quality

**Generated:** 2026-05-25T15:00:00Z
**Model:** mlx-community/gemma-3-1b-pt-6bit
**Scenarios:** 18

## Confusion Matrix (D-12)

|                  | actual: correct | acceptable | useless | bad | total |
|------------------|-----------------|------------|---------|-----|-------|
| **expected: correct**    |        9 |     1 |     0 | 0 |    10 |
| **expected: acceptable** |        2 |     3 |     1 | 0 |     6 |
| **expected: useless**    |        0 |     0 |     2 | 0 |     2 |
| **expected: bad**        |        0 |     0 |     0 | 0 |     0 |
| **total**                |       11 |     4 |     3 | 0 |    18 |

**Classification recall:**
- correct: 9/10 (90%)
- acceptable: 3/6 (50%)
- useless: 2/2 (100%)

**Release gate D-11 (simulated on replay):**
- ✓ correct/total ≥ 30% → 11/18 = 61%
- ✓ (useless+bad+parasite)/total ≤ 35% → 3/18 = 17%
- ✓ parasite/total ≤ 5% → 0/18 = 0% (parasite untestable in single-pass replay)

## Per-scenario detail
... (existing per-scenario table) ...
```

### Auto-classification in replay (without live cascade)

**Limitation:** Le replay produit *un seul ghost par scénario* (pas de séquence temporelle). Il peut classifier **correct/acceptable/useless/bad** *du ghost final* contre l'`expectedGhostPrefix`, mais **pas `parasite`** (qui requiert un replacement live).

**Algorithme:**

```swift
func classifyReplayGhost(
    ghost: String,
    expectedPrefix: String?
) -> ExpectedCategory {
    guard let expected = expectedPrefix, !expected.isEmpty else { return .skip }
    if ghost.isEmpty { return .useless }
    if ghost.lowercased().hasPrefix(expected.lowercased()) { return .correct }
    // Acceptable: ghost is non-empty and not actively wrong (no detection
    // of explicit divergence in replay — we don't know what the user would
    // have typed next). Heuristic: if the ghost stays in the same language
    // (detected via NaturalLanguage), classify acceptable.
    if NaturalLanguage.detect(ghost) == NaturalLanguage.detect(expected) {
        return .acceptable
    }
    return .bad
}
```

**Recommandation Phase 4:** Implémenter classification "naive" en replay (correct/acceptable/useless seulement) ; `bad` détection requiert un signal humain (le user fill-in du verdict markdown). `parasite` est purement production-time.

---

## Real-app verification scenario list

### Tier 1: Acceptance gate (D-15)

> Pour chaque app, 5 scenarios scriptés, reproductibles, time-bounded (≤30s par scenario), auto-classifiables via la pipeline `ghost_classified_*` agrégée.

#### Mail (`com.apple.mail`)

| # | Scenario | Typed text | Expected category | Notes |
|---|---|---|---|---|
| M1 | **Reply to client email** | Open thread → click Reply → type `Bonjour Marie, suite à votre message du ` | `correct` ghost = continuation date (mois) ; or `acceptable` if it predicts `, je vous confirme` | Stress test : large prefix (incoming email body in context), mid-sentence typing, no field hint. Auto-pass if `ghost_classified_correct` OR `_acceptable` fires within 2s. |
| M2 | **Subject line empty** | New Email → click Subject field → type `Rdv ` | `correct` = `demain` or contextual ; `acceptable` if any plausible subject | `placeholder="Objet"` + role=AXTextField. Validates Phase 2 fieldContext slot is propagating. |
| M3 | **Mid-word completion** | In body → type `Je voulais te dem` (no space) | `acceptable` = ghost completes mid-word ("ander") | Layer 0 NSSpellChecker. Mid-word → LLM blocked (D-08). |
| M4 | **After-comma continuation** | Type `D'accord pour demain, ` | `correct` if from history match ; `acceptable` if LLM-generated | After-space cascade — L1 first, L2 upgrade if better. |
| M5 | **Long-prefix divergence** | Type 3 paragraphs then misspell — backspace 5 chars — retype | No regression : ghost should appear; no `parasite` emitted | Stress test cache + KV cache + cascade. |

#### Notes (`com.apple.Notes`)

| # | Scenario | Typed text | Expected category | Notes |
|---|---|---|---|---|
| N1 | **Empty new note** | Cmd+N → type `Liste courses : ` | `correct` if predicts realistic item ; `acceptable` if generic plausible | Empty prefix, role=AXTextArea, no placeholder. The classic "fortune cookie" hazard. |
| N2 | **Mid-paragraph edit** | Open existing note → click mid-paragraph → type 3 chars | `correct` matching what's after the caret (afterCursor slot) | Validates afterCursor Phase 2 slot. |
| N3 | **List bullet** | Type `- Réunion à 14h\n- ` | `correct` or `acceptable` for continuation item | Tests structural pattern recognition. |
| N4 | **Code block typing** (inside ``` fence if Notes supports) | Type `def hello`  | `acceptable` if it produces `():` or `_world` ; `useless` if multilingual drift | Edge case — language detection should keep it in code domain. |
| N5 | **Backspace then resume** | Type a sentence, backspace 8 chars, resume | Undo-as-ghost should restore | Validates `cache_undo_hit` still works post-refactor. |

#### Brave (`com.brave.Browser`)

| # | Scenario | Typed text | Expected category | Notes |
|---|---|---|---|---|
| B1 | **Gmail compose body** | Open Gmail → Compose → type 2 paragraphs of email body | `correct` ≥ 1 ; no `parasite` | Chromium AX fallback path. OCR caret resolver active (CaretResolver). Critical because PVM:1538 et le `caretResolver` doivent rester en sync. |
| B2 | **Search bar query** | Click address bar → type `restaur` | `acceptable` (word complete) or `correct` (history if user did same search) | Layer 0 essentiel. |
| B3 | **Twitter/X compose** | New tweet → type `Just shipped ` | `acceptable` for English continuation | Language detection FR → EN switch. |
| B4 | **Notion-in-browser block** | Open Notion → type into a block | `correct` or `acceptable` | Tests AX activation on Electron-class web app. |
| B5 | **Mid-text edit Gmail** | In a partly-written email body, click mid-paragraph, type | `correct` matching afterCursor | Mid-text Chromium = the hardest case ; stress test for caret OCR + afterCursor slot. |

### Tier 2: Report-only (D-15)

> Same shape but verdict ne gate pas le milestone. 3 scenarios par app.

- **Safari** : Gmail compose, Address bar, GitHub PR description
- **TextEdit** : Empty new doc, Mid-paragraph edit, Long-prefix continuation
- **Intercom** (web/desktop) : Reply to chat thread, Empty input box, Compose new
- **Notion** : New page title, Bullet list, Code block

### Verification protocol per scenario

```
1. Launch Souffleuse signed dev build with SOUFFLEUSE_PREDICT_LOG=1
2. Open target app, navigate to scenario start state
3. Start screen recording (timestamp anchor)
4. Type the scripted prefix at human pace (~5 cps)
5. Observe ghost outcomes:
   a. If Tab is offered AND content matches expected → mark correct
   b. If Tab is offered AND content is plausible alt → mark acceptable
   c. If ghost shown ≥ 200ms then dismissed via Esc → mark useless
   d. If ghost shown and user typed past with divergent first word → mark bad
   e. If a ghost flickers within stability window → mark parasite
6. Stop recording, save .planning/phases/04-cascade-quality-architecture/04-VERIFICATION-{app}.md
```

### Aggregation roll-up (D-17)

`.planning/phases/04-cascade-quality-architecture/04-VERIFICATION.md` summarizes Tier 1 results:

```markdown
# Phase 4 Real-App Verification

## Tier 1 Acceptance Gate

| App | Scripted pass | Blind A/B (5/5) | 30-min parasite < 5% | Verdict |
|---|---|---|---|---|
| Mail (com.apple.mail) | 5/5 | 5/5 | ✓ (2.3%) | ✓ ACCEPT |
| Notes (com.apple.Notes) | 4/5 | 5/5 | ✓ (1.1%) | ✓ ACCEPT (N5 retry pass) |
| Brave (com.brave.Browser) | 3/5 | 4/5 | ✗ (7.1%) | ✗ REVIEW |

## Tier 2 (Report-only)
...

## Verdict global
✗ Not yet accepting: Brave has parasite rate above cap. Investigate B1 (Gmail compose) cascade churn pattern.
```

---

## State of the Art

| Old Approach (pré-Phase 4) | Current Approach (Phase 4 target) | When Changed | Impact |
|---|---|---|---|
| Cascade logic interleaved with MLX I/O in 1566-LOC PVM | Cascade isolated in `SuggestionPolicy`, MLX in `ModelRuntime` | Phase 4 | Testability ↑↑, separation of concerns ↑↑ |
| Confidence implicit (source-tagged events but no numeric score) | Scalar `[0,1]` score = `source_prior × prefix_fit × length_fit` | Phase 4 D-06 | Replacement decisions become inspectable + tunable |
| Anti-churn ad-hoc (stability gate at PVM:587-609 + LLM-extend rule at PVM:876-898) | Unified Relevance Gate replacement bar `× 1.15` | Phase 4 D-07 | Single decision point ; no longer "two systems disagreeing" |
| L1 (history exact-match) effectively disabled in after-space cases | L1 re-enabled behind the Gate with threshold `0.4` | Phase 4 D-08 | Restores user-personalized instant ghosts after spaces |
| `ghost_dropped_*` family + ad-hoc tracking | 5-event classification grid `ghost_classified_*` | Phase 4 D-10 | Production-safe quality metric, release-gateable |
| Verdict Cotypist subjective (no protocol) | Tier 1 acceptance grid + scripted scenarios + blind A/B | Phase 4 D-14..D-17 | Pronounceable verdict on Cotypist parity for the milestone |
| `tick()` + `predict()` both inside their god-objects | `TypingSession.tick()` + `PredictorViewModel.predict()` (façade) over 4 modules | Phase 4 D-04 | Each module ≤ 700 LOC, follows project's 1-type-per-file convention |

**Deprecated/outdated (à drop ce milestone):**
- L'env var `SOUFFLEUSE_PROMPT_BUILDER` (PVM:17-20) reste car le `PromptBuilderFlag` gate la migration Phase 1. Pas drop ici (orthogonal). À reconsidérer milestone après vérification réelle Tier 1.

---

## Assumptions Log

> Claims tagged `[ASSUMED]` that need user/planner confirmation before execution.

| # | Claim | Section | Risk if Wrong |
|---|---|---|---|
| A1 | `length_fit` calculé en **mots** (pas tokens) reste ε-équivalent à la bell curve D-06 "2–6 tokens". | §Confidence scoring formula | Si faux : bell curve mal calibrée, `length_fit` pénalise les ghosts moyens. Mitigation : `Tuning.lengthFitByWordCount` est ajustable, et un POC peut comparer le scoring en mots vs en tokens sur 12 scenarios replay. |
| A2 | `Tuning.parasiteWindow = 0.8s` est le bon timing pour distinguer parasite d'un refresh legitime post-typing-pause. | §Cascade routing — Pitfall 5 | Si trop court : on rate des parasites réels ; si trop long : on classifie de l'usage légitime comme parasite. Mitigation : tunable D-13. Calibrer en daily-use Tier 1 verification. |
| A3 | `Tuning.uselessMinVisibleMs = 200` est le seuil de perception humaine de présence du ghost. | §Classification grid emission | Si trop bas : on compte des ghosts non perçus ; si trop haut : on rate des dismissals réels. Mitigation : tunable D-13. Source de la valeur : training knowledge sur la durée d'une saccade visuelle (~100-150ms). |
| A4 | `Tuning.badMaxDivergeMs = 500` est la fenêtre où une divergence est "active" (user-driven) vs passive (inattention). | §Classification grid emission | Idem A3. Tunable. |
| A5 | Le replay harness `SouffleuseCoherence --replay` peut auto-classifier `correct/acceptable/useless` ; `bad` requiert signal humain ; `parasite` non-testable en single-pass replay. | §Replay harness extension | Si on peut détecter `bad` en replay (par comparaison avec expected continuation), on simplifie le verdict humain. Mitigation : implémenter la classification naive ET garder le slot "Human note" dans le markdown. |
| A6 | Aucun nouveau SPM target n'est nécessaire ; tout vit dans `Sources/Souffleuse/`. | §Recommended Project Structure | Si vrai, le `Package.swift` ne bouge pas → moins de diff, moins de risque de casser les autres executables/tests. Si faux (par exemple si on veut un target dédié pour `SouffleusePredictor` testable indépendamment), il faudra revoir l'extraction. Recommandation : *garder simple en Phase 4*, refactorer en target SPM dans un milestone future si la testabilité l'exige. |
| A7 | `historyExactSubstringMatch` (PVM:1524) est suffisamment performant pour rester O(N×L) avec N≤200 et L≤120, donc < 1ms. Aucune indexation nécessaire. | §Don't Hand-Roll ligne "Layer 1" | Vérifié empiriquement par PVM:1521 comment. Reste un comment, pas un bench. Si jamais le user atteint un N nettement > 200 (par exemple via un milestone d'extension de history), l'indexation deviendrait nécessaire. Hors-scope Phase 4. |
| A8 | Le pattern `CacheBox @unchecked Sendable` (PVM:70-72) est suffisant pour porter tout l'état partagé `CompletionCache`. Pas besoin d'un actor full. | §Architecture Patterns — Pattern 1 | Phase 3 a prouvé ce pattern fonctionne pour `[KVCache]`. Si Phase 4 introduit du shared mutable state autre que les caches (par exemple, un classifier qui maintient un sliding-window count en arrière-plan), il faudrait actor. Mitigation : commencer façade `@MainActor`, escalate to actor seulement si profile-driven. |
| A9 | La détection `parasite` (replacement dans la stability window) est suffisante pour classifier le churn ; pas besoin de tracer le replacement *graph* (qui a remplacé qui sur 3+ pas). | §Classification grid emission | Si vrai, la métrique reste interprétable. Si faux (par exemple A→B→C dans la fenêtre, où B est legitimate mais C parasite-de-B), on rate. Mitigation : si verification Tier 1 montre que le ghost churn est multi-step, ajouter un compteur `parasite_chain_depth` en milestone future. |

**Action planner:** Si une de ces hypothèses A1-A9 doit être verrouillée par le user avant exécution, l'inclure dans une question discuss-phase. Sinon, le planner peut les traiter comme valeurs initiales tunables (D-13).

---

## Open Questions (RESOLVED)

1. **Granularité d'atomic-commit lors du split PVM**
   - What we know: D-02 dit "atomic-commit per boundary" ; Phase 3 a fait ~1 commit par plan (5 plans, 5 commits + sub-commits internes).
   - What was unclear: Un commit par module (4 commits) ou par sous-étape interne (extraction du type, extraction des méthodes, wiring) ?
   - RESOLVED: **1 commit par module extrait**, AVEC un commit intermédiaire si le diff dépasse ~500 LOC. Le replay equivalence check à chaque commit garantit la safety net. Granularité fine = plus de granularité de bisect en cas de régression. Plans 04-02..04-05 et 04-07 appliquent cette règle.

2. **`PromptBuilderFlag` et le replay equivalence check**
   - What we know: PVM:17-20 — `SOUFFLEUSE_PROMPT_BUILDER` reste dev-only. Le code prod fait le path "legacy" par défaut.
   - What was unclear: Pour le replay equivalence check D-02, on compare sur quel path ? Le legacy ou le PromptBuilder ? Phase 3 03-04 SUMMARY suggère qu'on a déjà committé "PromptBuilder on" pour la replay.
   - RESOLVED: Replay equivalence check ON les deux paths. Le diff doit être ε-stable sur les deux. Plans 04-02..04-05 exigent un `04-NN-REPLAY-DIFF.md` vs baseline ; plan 04-09 documente le verdict final dans `04-VERIFICATION.md`.

3. **Order of extraction within PVM split (D-01 sub-question)**
   - What we know: D-01 dit PVM avant TypingSession ; D-03 liste 4 modules sans ordonner.
   - What was unclear: Lequel des 4 extrait en premier ?
   - RESOLVED: **`SuggestionPolicy` en premier** (parce qu'il porte le Gate, l'innovation Phase 4 ; mieux vaut le valider tôt). Puis `GenerationPlanner` (clean dépendance avec Policy). Puis `CompletionCache` (relâche les state captures de la façade). Puis `ModelRuntime` (le plus gros mais le plus encapsulé, donc le moins risqué en dernier). La wave structure des plans 04-02 → 04-05 verrouille cet ordre.

4. **Real-app verification mode opératoire — date d'exécution ?**
   - What we know: D-14 est "scripted + blind A/B *en séquence*". Tier 1 = ½ journée par app.
   - What was unclear: Une journée bloquée pour Tier 1, ou intégré au milestone ?
   - RESOLVED: Plan 04-09 dédié en fin de phase, post-refactor + classification grid live. ½ journée × 3 = 1.5 jours user time. 3 checkpoints `autonomous: false` (un par app Tier 1) pour intégrer le verdict manuel du user.

---

## Environment Availability

> Phase 4 n'introduit pas de dépendance externe. Skip cette section ne s'applique pas — voici le récap des dépendances ALREADY available et vérifiées via Phase 3 success criteria.

| Dependency | Required By | Available | Version | Fallback |
|---|---|---|---|---|
| `mlx-swift-examples` | ModelRuntime + CompletionCache (KV cache reuse) | ✓ | 2.29.1 | — |
| Swift Testing | New unit tests | ✓ | system (Xcode toolchain) | — |
| `Log.info(_:_:count:)` + audit.sh | classification grid emission | ✓ | in-tree | — |
| `SouffleuseCoherence` binary | replay equivalence + confusion matrix | ✓ | in-tree | — |
| OCR + AX permissions | Brave verification scenarios | ✓ (dev bundle) | — | OCR off → Brave scenarios marked report-only |
| Mail / Notes / Brave installed | Tier 1 scenarios | ✓ (macOS bundled / user-installed) | — | None — these apps are gating per D-15 |

**Missing dependencies with no fallback:** None.

**Missing dependencies with fallback:** None.

---

## Sources

### Primary (HIGH confidence)

- `[VERIFIED]` `.planning/phases/04-cascade-quality-architecture/04-CONTEXT.md` (lines 1-200) — D-01..D-17 verrouillés
- `[VERIFIED]` `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` (1566 LOC) — mapping ligne par ligne du split
- `[VERIFIED]` `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift` (1209 LOC) — extraction TypingSession
- `[VERIFIED]` `Souffleuse/Sources/SouffleuseTyping/WordCompleter.swift` (79 LOC) — Layer 0 API
- `[VERIFIED]` `Souffleuse/Sources/SouffleuseCoherence/main.swift` (592 LOC) — replay harness extension shape
- `[VERIFIED]` `Souffleuse/Sources/Souffleuse/KVCacheHolder.swift` (80 LOC seen) — pattern Phase 3 réutilisable
- `[VERIFIED]` `Souffleuse/audit.sh` (76 LOC) — privacy invariants à maintenir
- `[VERIFIED]` `.planning/phases/03-perf-kv-cache/03-02-SUMMARY.md` — `CacheBox`, slot hoisting, `InvariancePrefix.canonicalizePreviousUserInputs` patterns
- `[CITED]` `.planning/PROJECT.md` — Core Value, constraints, privacy invariants
- `[CITED]` `.planning/REQUIREMENTS.md` — LEARN-*, MULT-*, VIS-* deferrals
- `[CITED]` `.planning/STATE.md` — baseline performance metrics

### Secondary (MEDIUM confidence)

- `[VERIFIED]` `Souffleuse/Tests/SouffleuseTests/HistoryExactMatchTests.swift` — extension target pour after-space Gate
- `[CITED]` `.planning/phases/02-high-signal-slots/02-CONTEXT.md` — slots Phase 2 (`afterCursor`, `fieldContext`, `previousUserInputs`)

### Tertiary (LOW confidence — assumed, see Assumptions Log)

- `[ASSUMED]` Bell curve word-count vs token-count equivalence (A1) — training knowledge sentencepiece FR fragmenting at ~1.2-1.5 tokens/word
- `[ASSUMED]` Stability window `0.8s` calibration (A2) — training knowledge typing pause distributions
- `[ASSUMED]` Visible threshold `200ms` perception (A3) — training knowledge visual saccade duration
- `[ASSUMED]` Divergence active window `500ms` (A4) — training knowledge attention windows in flow typing

---

## Metadata

**Confidence breakdown:**
- PVM region mapping: HIGH — read source ligne par ligne, 1566 LOC parcourues
- TypingSession extraction: HIGH — AppDelegate déjà mappé, frontière nette
- Confidence scoring formula: MEDIUM — D-06 verrouillé mais valeurs initiales nécessitent calibration empirique (A1)
- Cascade routing matrix: HIGH — D-08 verrouillé, déduit du code existant
- Classification grid emission: HIGH — pattern `Log.info(_:_:count:)` éprouvé, audit-safe par construction
- Replay extension: HIGH — schema v1 → v2 transparent grâce aux Optional fields
- Tier 1 scenario list: MEDIUM — scenarios proposés sont conjecturaux mais reproductibles ; le user validera durant verification
- Risk / pitfalls: HIGH — issus de lecture du code prod et Phase 3 SUMMARY (deviations)

**Research date:** 2026-05-25
**Valid until:** 2026-06-25 (30 jours — cascade design est domain-stable, codebase context peut drift)
