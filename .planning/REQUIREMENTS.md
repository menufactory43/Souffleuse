# Requirements: Cocotypist / Souffleuse

**Defined:** 2026-05-24
**Core Value:** Le ghost doit *sembler* aussi instantané et pertinent que Cotypist en usage quotidien. Qualité contextuelle prime sur vitesse brute.

**Milestone scope :** Context Builder token-aware. Hypothèse fondatrice à valider : le ghost junk vient du prompt pauvre, pas du modèle. Reframe complet par rapport aux notes initiales (`NEXT-MILESTONE-NOTES.md`) qui priorisaient l'infra d'inférence (KV cache).

## v1 Requirements

Requirements pour ce milestone. Mappés en phases par le roadmapper.

> **Update 2026-05-25:** insertion de la Phase 3 *perf-debt KV cache* a promu `KV-01..KV-04` de v2 vers v1 et ajouté `KV-05..KV-07`. L'ex-Phase 3 (Optional Sources + Parity Verdict) devient Phase 4.

### Audit (validation empirique)

- [ ] **AUDIT-01**: Le PromptBuilder Phase 1 expose un mode test/replay qui rejoue 10-20 scénarios reproductibles (champ vide, message neuf, sujet vide, reply Slack, etc.) avec et sans contexte enrichi, et logue le ghost produit pour chaque variante.
- [ ] **AUDIT-02**: Avant de commencer le build complet du builder, l'audit produit un verdict A/B clair (avec-contexte > sans-contexte sur N/10 scénarios). Si l'hypothèse fondatrice n'est pas confirmée, le milestone est revu avant Phase 2.

### Context Builder (infrastructure prompt)

- [ ] **BUILDER-01**: Un PromptBuilder structuré remplace la flat-string concat actuelle dans `PredictorViewModel.predict()`. Slots nommés, assemblage déterministe, l'output est le string final passé à MLX `container.perform`.
- [ ] **BUILDER-02**: Budget exprimé en *tokens* (pas chars), avec allocation par catégorie (slot). Eviction-policy explicite quand un slot dépasse son budget — préférer truncation propre (frontière mot/phrase) plutôt que coupe brute.
- [ ] **BUILDER-03**: Le PromptBuilder est testable en isolation — tests snapshot du prompt assemblé pour scénarios fixés, indépendamment de MLX.
- [ ] **BUILDER-04**: La pipeline existante (predict path, debounce, cancel-on-keystroke, cache) continue de fonctionner sans régression pendant la construction. Migration strategy (feature flag vs in-place) tranchée en plan-phase 1.

### Slots de contexte (par ordre de priorité)

- [ ] **SLOT-01**: Slot `beforeCursor` mieux budgeté — remplace le truncate dumb à 512 chars actuel. Allocation token-aware, préservation du dernier mot complet, contexte amont gardé maximum sous le budget alloué.
- [ ] **SLOT-02**: Slot `afterCursor` capté via AX (`kAXSelectedTextRangeAttribute` + lecture du texte après le caret) et injecté dans le prompt sous une frontière typographique claire pour le modèle.
- [ ] **SLOT-03**: Slot `fieldContext` — métadonnées AX du champ focal : `kAXPlaceholderValueAttribute`, role/subrole, `kAXIdentifierAttribute`, `kAXHelpAttribute`. Au-delà de ce que `AppContextProbe` fait déjà au niveau app/window.
- [ ] **SLOT-04**: Slot `previousUserInputs` — refactor du few-shot `SimilarHistoryRetrieval` existant pour s'aligner sur l'API du builder. Source déjà fonctionnelle, à recabler proprement.
- [ ] **SLOT-05**: Slot `clipboardContext` opt-in — réutilise `ClipboardReader` (blocklist existante préservée), devient opt-in par préférence utilisateur dans PreferencesStore.
- [ ] **SLOT-06**: Slot `screenContext` OCR conditional — `ScreenCapturer + VisionOCR` n'est invoqué QUE si (a) les autres slots sont sparse, (b) la permission ScreenRecording est active, (c) la préférence utilisateur l'autorise. Plus d'always-on dans le cycle d'enrichissement.

### Performance & Quality Gates

- [ ] **PERF-01**: TTFT préservé sous ~80ms après dernier keystroke en flow typique (non-cold-start). La baseline est le commit `6ad70df`.
- [ ] **PERF-02**: Si la mesure de TTFT dépasse 80ms après l'enrichissement, le milestone documente le delta et la cause (laquelle des sources est coûteuse). Pas de blocker absolu (qualité prime), mais doit être traqué.
- [ ] **QUAL-01**: Validation subjective en side-by-side daily-use Souffleuse vs Cotypist sur 5-10 scénarios scriptés (email reply, code comment, Slack message, champ vide, sujet de mail neuf, etc.). Verdict "feels right" par scénario.

### KV cache MLX (Phase 3 — promu de v2)

- [x] **KV-01**: TokenizationCache — éviter de re-tokeniser le prefix répété entre predicts. **Implémenté commit `e56fdd2` (MemoizingTokenCounter)** — coché en pre-Phase 3 (gain 312→44 ms sur prompt_build_ms p50).
- [ ] **KV-02**: KV cache reuse via `RotatingKVCache` + `TokenIterator(cache:)` cross-keystroke dans `PredictorViewModel`. Cible TTFT p50 ≤ 300ms (vs 700-1000ms baseline). Préserve l'API model factory (`model.newCache(parameters:)`).
- [ ] **KV-03**: Decision tree extend / trim / invalidate keyé sur fingerprint (hash stable des slots invariants `system|customInstructions|contextPrefix|fieldContext|afterCursor|previousUserInputs`). `beforeCursor` = extension token-incrémentale. Toute autre mutation = invalidation complète.
- [ ] **KV-04**: Mesure TTFT incrémental reproductible — adaptation de `SouffleuseBench` ou nouveau bench dédié pour mesurer le delta de TTFT entre keystrokes consécutifs (avec / sans cache).
- [ ] **KV-05**: Replay équivalence — re-run `SouffleuseCoherence --replay` 15 scénarios produit des ghost outputs *fonctionnellement identiques* avec et sans KV cache (epsilon greedy-near). Le cache n'est qu'une optim, pas un changement sémantique.
- [ ] **KV-06**: Rollback env var `SOUFFLEUSE_DISABLE_KV_CACHE=1` désactive le cache au runtime sans rebuild, reproduit le comportement baseline (régression de contrôle).
- [ ] **KV-07**: Instrumentation count-only — events log `kv_cache_extend` / `kv_cache_trim` / `kv_cache_invalidate` via `StaticString`, audit-safe (5 fields whitelist `audit.sh` toujours vert).

### Non-régression & Tests

- [ ] **TEST-01**: Les 94 tests existants restent verts à chaque atomic commit du milestone.
- [ ] **TEST-02**: Nouveaux tests pour PromptBuilder : budget allocation (slot dépasse → eviction), assemblage déterministe (snapshot tests), comportement des nouveaux slots (afterCursor, fieldContext, OCR conditional).
- [ ] **TEST-03**: Privacy invariants : `audit.sh` (6 checks) continue de passer. Aucune nouvelle source de contexte ne franchit l'overlay process ni n'écrit du texte user dans les logs.

## v2 Requirements

Requirements reconnus mais reportés à un milestone ultérieur.

### Inference Infrastructure (latence) — promu en v1 / Phase 3

> `KV-01..KV-07` promus dans la section *v1 § KV cache MLX* après insertion de Phase 3 *perf-debt KV cache*. Voir §v1 pour la définition canonique.

### Multi-candidate Generation

- **MULT-01**: Génération de K candidats par predict, scoring par average logprob
- **MULT-02**: Sélection du meilleur candidat selon heuristique configurable
- **MULT-03**: Constrained decoding avec `requiredPrefix` quand pertinent

### Apprentissage Élargi

- **LEARN-01**: Capture des inputs dismissed (Esc explicite)
- **LEARN-02**: Capture des typed-instead (l'utilisateur a tapé autre chose que le ghost)
- **LEARN-03**: Capture des ignored (ghost timed-out sans action)
- **LEARN-04**: Refactor `TypingHistoryStore` schema pour ces signaux négatifs

### Filtres Visuels

- **VIS-01**: Refus de ghosts trop longs en rendu visuel (`completionWidthExceedsMaximum`)
- **VIS-02**: Refus de prefix trop longs en rendu (`prefixWidthExceedsMaximum`)
- **VIS-03**: Limites de search/result width configurables

### Activation AX Electron / Signal

- **AX-01**: Faire fonctionner Signal Desktop (résiste à AXManualAccessibility + AXObserver actuellement). Cotypist y arrive — identifier le mécanisme.

## Out of Scope

Explicitement exclus pour ce milestone (et au-delà si applicable).

| Feature | Reason |
|---------|--------|
| ~~KV cache reuse / TokenizationCache / SequenceManager~~ | **Promu en v1 / Phase 3 (perf-debt intercalaire 2026-05-25)** : Phase 2 a livré la qualité ; mesure session du 2026-05-25 a démontré que TTFT 700-1000ms étrangle 94% des streams (cancel-on-keystroke), masquant le verdict qualité de Phase 4. Voir `kv-cache-discovery.md`. |
| Multi-candidate generation + scoring | Gain qualitatif orthogonal au Context Builder. À traiter une fois l'infra prompt stable. |
| Filtres visuels (width-based refusal) | Rendering concern, traitement séparé. |
| Apprentissage avec signal négatif | Feedback loop, requires history schema changes. Futur milestone. |
| Activation AX Electron complète (Signal Desktop) | Connu, non-bloquant pour la majorité des apps. Reporté. |
| XPC isolation 3-process (UI / AXAgent / InferenceAgent) | Architectural target mentionné dans codebase ARCHITECTURE.md §5.bis, pas le moment. |
| Sparkle / auto-update | Déjà noté comme planned v1, pas dans ce milestone. |
| Changement de stack (sortir de MLX / Swift 6) | Hors scope absolu pour ce milestone. |
| Nouvelle source de contexte hors-process | Aucune source ne franchit le boundary process (privacy invariant). |
| Network telemetry / analytics | Privacy invariant absolu — pas de réseau au runtime sauf modèle initial. |

## Traceability

Mappage des requirements aux phases du ROADMAP.md (créé 2026-05-24).

| Requirement | Phase | Status |
|-------------|-------|--------|
| AUDIT-01 | Phase 1 | Pending |
| AUDIT-02 | Phase 1 | Pending |
| BUILDER-01 | Phase 1 | Pending |
| BUILDER-02 | Phase 1 | Pending |
| BUILDER-03 | Phase 1 | Pending |
| BUILDER-04 | Phase 1 | Pending |
| SLOT-01 | Phase 1 | Pending |
| SLOT-02 | Phase 2 | Pending |
| SLOT-03 | Phase 2 | Pending |
| SLOT-04 | Phase 2 | Pending |
| SLOT-05 | Phase 4 | Pending |
| SLOT-06 | Phase 4 | Pending |
| PERF-01 | Phase 2 | Pending |
| PERF-02 | Phase 4 | Pending |
| QUAL-01 | Phase 4 | Pending |
| KV-01 | Phase 3 (déjà implémenté commit `e56fdd2`) | Done |
| KV-02 | Phase 3 | Pending |
| KV-03 | Phase 3 | Pending |
| KV-04 | Phase 3 | Pending |
| KV-05 | Phase 3 | Pending |
| KV-06 | Phase 3 | Pending |
| KV-07 | Phase 3 | Pending |
| TEST-01 | Phase 1 (cross-cutting, verrouillé à chaque frontière de phase) | Pending |
| TEST-02 | Phase 1 (cross-cutting, étendu à chaque nouveau slot) | Pending |
| TEST-03 | Phase 1 (cross-cutting, verrouillé à chaque frontière de phase) | Pending |

**Coverage:**
- v1 requirements: 25 total (18 originaux + 7 KV promus)
- Mapped to phases: 25 ✓
- Unmapped: 0

**Notes:**
- `TEST-01` / `TEST-02` / `TEST-03` sont conceptuellement cross-cutting (présents à chaque phase). Assignés explicitement à Phase 1 (où le PromptBuilder + ses tests snapshot naissent), mais Phase 2 et Phase 3 doivent les maintenir verts. Phase 3 success criterion #5 verrouille la non-régression terminale.
- `AUDIT-01` / `AUDIT-02` sont intentionnellement dans Phase 1 (pas une phase dédiée) — le mode replay est embarqué dans le builder pour valider l'hypothèse fondatrice avant l'investissement Phase 2.

---

*Requirements defined: 2026-05-24*
*Last updated: 2026-05-25 — Phase 3 perf-debt KV cache insertion, KV-01..KV-07 promus v2 → v1*
