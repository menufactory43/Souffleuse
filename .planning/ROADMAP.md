# Roadmap: Context Builder token-aware

**Milestone:** Context Builder
**Defined:** 2004-05-24
**Granularity:** coarse
**Mode:** yolo
**Core Value:** Le ghost doit *sembler* aussi instantané et pertinent que Cotypist en usage quotidien. Qualité contextuelle prime sur vitesse brute.

**Hypothèse fondatrice à valider :** le ghost junk vient du prompt pauvre, pas du modèle. Quand le champ est vide, on n'a rien à donner au modèle → il invente du générique.

---

## Phases

- [x] **Phase 1: Foundation + Hypothesis Validation** — PromptBuilder structuré token-aware, slot `beforeCursor` budgeté, mode replay sur scénarios scriptés pour valider l'hypothèse avant d'investir Phase 2.
- [x] **Phase 2: High-Signal Slots** — `afterCursor` (AX), `fieldContext` (AX field metadata), `previousUserInputs` (refactor du few-shot Jaccard sur l'API builder). Délivre le gain qualitatif sur champs sparse.
- [ ] **Phase 3: Perf debt — KV cache MLX** — réutilisation cross-keystroke du KV cache via `RotatingKVCache` + `TokenIterator(cache:)` + `trimPromptCache`. Cible : TTFT 700-1000ms → 104-200ms. Sans ça, le verdict de parité Cotypist (Phase 4) n'est pas mesurable.

---

## Phase Details

### Phase 1: Foundation + Hypothesis Validation
**Goal**: La pipeline LLM consomme un prompt assemblé par un PromptBuilder structuré et token-budgeté, et l'audit replay confirme (ou réfute) que l'enrichissement contextuel améliore le ghost sur les scénarios champ-vide avant que les autres slots ne soient construits.
**Depends on**: Nothing (first phase)
**Requirements**: BUILDER-01, BUILDER-02, BUILDER-03, BUILDER-04, SLOT-01, AUDIT-01, AUDIT-02, TEST-01, TEST-02, TEST-03
**Plans:** 5 plans
Plans:
**Wave 1**
- [x] 01-01-PLAN.md — Create SouffleusePrompt SPM target (PromptSlot/Budget/BuiltPrompt/TokenCounting/PromptBuilder) + Package wiring + audit.sh extension

**Wave 2** *(blocked on Wave 1 completion)*
- [x] 01-02-PLAN.md — Snapshot/eviction/determinism tests for PromptBuilder (Swift Testing, mock TokenCounting, MLX-independent)
- [x] 01-03-PLAN.md — MLXTokenCounter adapter + feature-flagged PromptBuilder integration in PredictorViewModel.predict()

**Wave 3** *(blocked on Wave 2 completion)*
- [x] 01-04-PLAN.md — SouffleuseCoherence --replay sub-command + replay-scenarios.json (12 seeded) + REPLAY-RESULTS.md atomic writer

**Wave 4** *(blocked on Wave 3 completion)*
- [x] 01-05-PLAN.md — TTFT bench + human verdict on replay + cleanup feature flag/legacy path (if verdict ≥ 6/12 ✓)
**Success Criteria** (what must be TRUE):
  1. La pipeline `PredictorViewModel.predict()` consomme un string final produit par un PromptBuilder structuré (slots nommés, assemblage déterministe) au lieu de la flat-string concat actuelle, et la pipeline de production (debounce, cancel-on-keystroke, cache mémo) continue de fonctionner sans régression observable.
  2. Le PromptBuilder alloue un budget *en tokens* (pas chars) par slot, applique une eviction-policy explicite quand un slot dépasse, et le slot `beforeCursor` préserve le dernier mot complet sous son budget (plus de truncate dumb à 512 chars).
  3. Un mode replay du PromptBuilder rejoue 04-20 scénarios scriptés (champ vide, message neuf Slack, sujet de mail vide, code comment, etc.) et produit pour chaque scénario un verdict A/B (avec-contexte vs sans-contexte) loggué et inspectable hors-MLX.
  4. L'audit produit un verdict explicite sur l'hypothèse fondatrice (`avec-contexte > sans-contexte` sur N/M scénarios). Si l'hypothèse n'est pas confirmée, le milestone est revu avant Phase 2.
  5. Les 94 tests existants restent verts, `audit.sh` (6 checks) continue de passer, et de nouveaux snapshot tests valident l'assemblage déterministe du PromptBuilder en isolation de MLX.
**Plans**: TBD

### Phase 2: High-Signal Slots
**Goal**: Quand le caret est dans un champ avec peu ou pas de texte avant, le ghost devient pertinent grâce au texte après le caret, aux métadonnées AX du champ, et aux few-shots de l'historique utilisateur recablés sur l'API du builder.
**Depends on**: Phase 1
**Requirements**: SLOT-02, SLOT-03, SLOT-04, PERF-01
**Success Criteria** (what must be TRUE):
  1. Quand l'utilisateur édite au milieu d'un texte existant, le slot `afterCursor` lit le texte après le caret via AX (`kAXSelectedTextRangeAttribute` + `kAXStringForRangeAttribute`) et l'injecte dans le prompt sous une frontière typographique claire pour le modèle.
  2. Le slot `fieldContext` enrichit le prompt avec les métadonnées AX du champ focal (`kAXPlaceholderValueAttribute`, role/subrole, `kAXIdentifierAttribute`, `kAXHelpAttribute`) au-delà du bundle/window-title déjà fournis par `AppContextProbe`.
  3. Le slot `previousUserInputs` consomme `SimilarHistoryRetrieval` (Jaccard existant) via l'API du builder — la source few-shot fonctionnelle d'avant le milestone est branchée proprement dans le pipeline structuré.
  4. Sur les scénarios scriptés où le champ est vide ou très court, le ghost produit est observablement plus pertinent qu'à la fin de Phase 1 (gain mesuré via le mode replay du PromptBuilder).
  5. Le TTFT reste sous ~80ms après dernier keystroke en flow typique (non-cold-start) malgré les nouvelles lectures AX, et toute dégradation observée est attribuée à un slot identifié.
**Plans:** 5 plans
Plans:
**Wave 1**
- [ ] 02-01-PLAN.md — Atomic rename PromptSlot.fewShot → previousUserInputs across SouffleusePrompt + integration sites + tests (D-16)

**Wave 2** *(blocked on Wave 1 completion; 02-02 and 02-03 are parallel-safe — no file overlap)*
- [ ] 02-02-PLAN.md — Extend AXSnapshot + AXClient.readSnapshot() with placeholder / help / textAfterCaret reads (D-15b, SLOT-02 + SLOT-03 AX surface)
- [ ] 02-03-PLAN.md — Add PromptBudget.phase2Default + extend PromptBuilder.build(...) with fieldContext / afterCursor + Phase 2 evictionPriority & assemblyOrder + roleLabelFR helper + ≥4 new tests (SLOT-02, SLOT-03, SLOT-04, TEST-02)

**Wave 3** *(blocked on Wave 2 completion)*
- [ ] 02-04-PLAN.md — Wire AXSnapshot → fieldContext / afterCursor slot bodies in PredictorViewModel.predict + AppDelegate snapshot forwarding + prompt_build_ms log (SLOT-02, SLOT-03, SLOT-04, PERF-01)

**Wave 4** *(blocked on Wave 3 completion)*
- [ ] 02-05-PLAN.md — Extend Coherence Scenario schema + add 3 mid-typing replay scenarios + regen REPLAY-RESULTS.md + write 02-VERIFICATION.md with explicit Verdict modèle (D-18b garde-fou)

### Phase 3: Perf debt — KV cache MLX
**Goal**: Diviser le TTFT inline-autocomplete par ~5× (de ~700-1000ms à ~104-200ms) en implémentant la réutilisation cross-keystroke du KV cache MLX dans `PredictorViewModel` via `RotatingKVCache` + `TokenIterator(cache:)` + `trimPromptCache`. Sans ce gain, le `cancel-on-keystroke` étrangle 94% des streams et le verdict de parité Cotypist (Phase 4) n'est pas mesurable.
**Depends on**: Phase 2
**Requirements**: KV-02, KV-03, KV-04, KV-05, KV-06, KV-07, TEST-01, TEST-03
**Reference**: `.planning/phases/03-perf-kv-cache/03-CONTEXT.md` + `.planning/kv-cache-discovery.md`
**Success Criteria** (what must be TRUE):
  1. TTFT chute mesurable — re-run du bench session 2004-05-25 : cible **p50 ≤ 300ms** (vs 700-1000ms baseline). Stretch : p50 ≤ 200ms.
  2. Stream completion rate (`llm_done_stored / predict_called`) passe de 5.8% à ≥ **30%** sur typing soutenu (cible stretch : 50%).
  3. `prompt_build_ms` non régressé — le `MemoizingTokenCounter` continue de fonctionner ; p50 reste ≤ 60ms.
  4. Les 109 tests existants restent verts + `audit.sh` (6 checks) passe. Zéro régression.
  5. Replay 15 scénarios — `SouffleuseCoherence --replay` produit des ghost outputs *fonctionnellement identiques* avec et sans KV cache (epsilon greedy-near). Le cache n'est qu'une optim.
  6. Env var bypass — `SOUFFLEUSE_DISABLE_KV_CACHE=1` désactive le cache au runtime et reproduit le comportement baseline (régression de contrôle).
**Plans:** 5 plans
Plans:
**Wave 1**
- [ ] 03-01-PLAN.md — KVCacheHolder + InvariancePrefix SHA256 fingerprint + ≥12 unit tests (pure-Swift scaffold, no MLX wiring yet)

**Wave 2** *(blocked on Wave 1)*
- [ ] 03-02-PLAN.md — Wire KVCacheHolder into PredictorViewModel.predict() — both call sites + decision tree (cold/extend/trim/invalidate) + swapModel invalidation + 3 count-only StaticString log events

**Wave 3** *(blocked on Wave 2)*
- [ ] 03-03-PLAN.md — Centralise SOUFFLEUSE_DISABLE_KV_CACHE into KVCacheBypassFlag (top-of-file private enum mirroring PromptBuilderFlag) + ≥5 holder-cold-invariant tests

**Wave 4** *(blocked on Wave 3)*
- [ ] 03-04-PLAN.md — Run SouffleuseCoherence --replay twice (with / without KV cache) + write REPLAY-EQUIVALENCE.md verdict (IDENTICAL / EPSILON-NEAR / REGRESSION) — human checkpoint

**Wave 5** *(blocked on Wave 4)*
- [ ] 03-05-PLAN.md — Reproduce session 2004-05-25 bench protocol post-implementation + write 03-VERIFICATION.md (TTFT p50/p95, completion rate, kv_cache_event distribution) — human checkpoint

### Phase 4: Cascade Quality + Architecture

**Goal:** Stabiliser et restructurer la cascade ghost (L0 WordCompleter / L1 history exact-match / L2 LLM) bricolée pendant la session debug 2026-05-25 en un système architecturalement propre, mesurable, et qui rend prononçable un verdict de parité Cotypist sur les apps réelles.
**Requirements**: D-01..D-17 (verrouillés en 04-CONTEXT.md — pas d'IDs REQ-XX au niveau REQUIREMENTS.md pour cette phase)
**Depends on:** Phase 3
**Plans:** 9 plans

Plans:
**Wave 1** (foundation — pure-function scorer + Tuning)
- [ ] 04-01-PLAN.md — Score + scorer pur + Tuning single-file + RelevanceGateTests (≥12)

**Wave 2** (PVM split — SuggestionPolicy first, then GenerationPlanner — D-01)
- [ ] 04-02-PLAN.md — SuggestionPolicyEngine + GhostUpdate + LifecycleEndReason + cascade migration + L1 re-enable + classification grid émission (5 events)
- [ ] 04-03-PLAN.md — GenerationPlanner + GenerationToken + counter monotonicity tests

**Wave 3** (PVM split — CompletionCache)
- [ ] 04-04-PLAN.md — CompletionCache + KVDecision + decideExtendTrimInvalidate + KVCacheBypassFlag migration (env var byte-identique)

**Wave 4** (PVM split — ModelRuntime, dernière extraction)
- [ ] 04-05-PLAN.md — ModelRuntime + StreamMetrics + PredictRequest + OutputFilter + PVM façade slim

**Wave 5** (L1 history Gate coverage tests)
- [ ] 04-06-PLAN.md — Extend HistoryExactMatchTests with ≥6 Gate-behavior cases

**Wave 6** (TypingSession extraction — D-04 + remaining classification hooks)
- [ ] 04-07-PLAN.md — TypingSession extracted from AppDelegate ; typedDiverged / typedPastWithoutOverlap / acceptedPartial classifications wired

**Wave 7** (Replay harness extension — D-12 confusion matrix)
- [ ] 04-08-PLAN.md — Scenario v2 schema + confusion matrix + classifyReplayGhost + ≥6 scenarios annotated

**Wave 8** (Real-app Tier 1 verification — D-14..D-17, manual checkpoints)
- [ ] 04-09-PLAN.md — Build/sign dev bundle + Mail/Notes/Brave verification + roll-up 04-VERIFICATION.md

**Success Criteria** (what must be TRUE):
  1. PVM ≤ 400 LOC ; 4 modules extraits (SuggestionPolicy, GenerationPlanner, CompletionCache, ModelRuntime) ; AppDelegate ≤ 700 LOC ; TypingSession extracted (D-03, D-04).
  2. Ghost Relevance Gate scalar [0,1] active (D-05..D-08) ; hard-block <0.25 ; replacement bar ×1.15 ; L1 re-enable derrière afterSpaceL1Bar=0.4.
  3. Classification grid : 5 events ghost_classified_* émis EXCLUSIVEMENT via SuggestionPolicy.endLifecycle, 1 event par lifecycle (D-09..D-11).
  4. Replay harness produit confusion matrix + release gate D-11 simulé (D-12).
  5. Tier 1 acceptance gate (Mail, Notes, Brave) : classification grid pass D-11 + blind A/B not-worse-than Cotypist ≥5/5 + parasite rate <5% (D-16).
  6. ≥214 tests verts, audit.sh 6/6 ✓, replay equivalence verdict EQUIVALENT à chaque commit du split.

---

*Roadmap created: 2004-05-24*
*Last updated: 2004-05-25 — Phase 3 perf-debt KV cache inserted, ex-Phase 3 renumbered to Phase 4*
