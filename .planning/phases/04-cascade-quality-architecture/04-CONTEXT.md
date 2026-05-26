# Phase 4: Cascade Quality + Architecture - Context

**Gathered:** 2026-05-25
**Status:** Ready for planning

<domain>
## Phase Boundary

Stabiliser et restructurer la cascade ghost (L0 WordCompleter / L1 history exact-match / L2 LLM) — bricolée pendant la session debug du 2026-05-25 — en un système architecturalement propre et **mesurable**, qui rend enfin prononçable un verdict de parité Cotypist sur les apps réelles.

**En scope (sept work streams, issus du commit `28558c9`) :**
1. Architecture — extraction d'un module `TypingSession` depuis `SouffleuseAppDelegate` (1209 LOC).
2. Architecture — split de `PredictorViewModel` (1566 LOC) en `ModelRuntime` / `SuggestionPolicy` / `CompletionCache` / `GenerationPlanner`.
3. Policy — Ghost Relevance Gate avec scoring de confiance unifié (scalar [0,1]).
4. Coverage — réactivation de history exact-match after-space, derrière le Relevance Gate.
5. Routing — priorités explicites mid-word vs after-space dans `SuggestionPolicy`.
6. Quality — grille de classification (correct / acceptable / useless / bad / parasite) avec métriques production-safe.
7. Verification — matrice de parité Cotypist sur apps réelles (Mail, Notes, Safari, Brave, Intercom, Notion, TextEdit).

**Hors scope (déferrés explicites) :**
- `clipboardContext` opt-in (ex-Phase 4 SLOT-05) → reclassé polish-tier, futur milestone.
- `screenContext` OCR conditional (ex-Phase 4 SLOT-06) → reclassé polish-tier, futur milestone.
- Multi-candidate generation + scoring (REQUIREMENTS.md §MULT-*) → futur milestone.
- Apprentissage avec signal négatif (REQUIREMENTS.md §LEARN-*) — bloque un Relevance Gate appris, donc on reste sur du scoring heuristique ce milestone.
- Activation AX Electron complète (Signal Desktop) → futur milestone.
- XPC isolation 3-process → futur milestone.

</domain>

<decisions>
## Implementation Decisions

### Architecture Refactor Strategy

- **D-01:** Ordre — **`PredictorViewModel` split EN PREMIER**, puis extraction `TypingSession`. Justification : la cascade vit aujourd'hui dans PVM ; en la splittant, on fait émerger une frontière `SuggestionPolicy` qui est exactement le point d'attache du Ghost Relevance Gate (D-05..D-08). `TypingSession` devient ensuite un orchestrateur léger au-dessus d'une façade PVM propre.
- **D-02:** Migration approach — **in-place, atomic-commit par boundary** (pas de feature flag). PVM est privé au target app, aucune API externe à dual-pather. Filet de sécurité : 126 tests verts à chaque commit + `SouffleuseCoherence --replay` equivalence check avant/après chaque extraction (réplique le playbook KV-cache de Phase 3).
- **D-03:** Frontières des 4 nouveaux modules (tous façades `@MainActor` au-dessus d'engines actor-backed quand pertinent) :
  - **`ModelRuntime`** — MLX container loading (`loadContainer`, `swapModel`), `LMInput`, `TokenIterator(cache:)`, sampler, maxTokens. I/O modèle pur.
  - **`CompletionCache`** — `predictCache` FIFO(32) + `KVCacheHolder` (déjà extrait Phase 3) + `InvariancePrefix` fingerprint + `MemoizingTokenCounter`.
  - **`SuggestionPolicy`** — Cascade routing L0/L1/L2 + source-tagged confidence + anti-churn + stability gate + **Ghost Relevance Gate** (D-05..D-08) + classification grid émission (D-09..D-13).
  - **`GenerationPlanner`** — debounce nanos, generation counter, cancel-on-keystroke, dispatch `onChunk`.
  - `PredictorViewModel` rétrécit à une façade qui câble ces 4.
- **D-04:** Extraction `TypingSession` depuis `SouffleuseAppDelegate` — absorbe tick 80ms, caret tracking, caches per-bundle (`lastCaretRectByApp`, `textAtFocusByBundle`), debounce enrichment. AppDelegate ne garde que : onboarding, hotkeys, menu-bar, preferences wiring.

### Ghost Relevance Gate + Confidence Scoring

- **D-05:** Modèle de scoring — **heuristique** (pas appris). Justification : un scoring appris requiert capture du signal négatif (§LEARN-* explicitement hors scope ce milestone).
- **D-06:** Shape du score — **scalar dans [0,1]** = `source_prior × prefix_fit × length_fit`. Composants transparents, loggables au niveau `count` (audit-safe — aucun texte user). Valeurs initiales (tunables) :
  - `source_prior`: L0 WordCompleter = 0.55 ; L1 history exact = 0.75 ; L2 LLM = 0.60.
  - `prefix_fit`: 1.0 si le ghost commence par le mot courant (mid-word) ou enchaîne proprement après l'espace ; 0.0 si divergent.
  - `length_fit`: bell curve centrée 2–6 tokens ; pénalité aux extrémités (1 char et > 8 tokens after-space).
- **D-07:** Gate decision — **hard block sous `0.25`** + **replacement bar** : un nouveau ghost doit battre `score_courant × 1.15` pour displacer le ghost affiché. Étend le stability gate actuel dans le système de score.
- **D-08:** Routing sur désaccord de sources :
  - **Mid-word** → L0 exclusif (LLM/history ne savent pas faire mid-word sans bruit).
  - **After-space** → L1 évalué d'abord (seuil 0.4, plus strict que mid-word car L2 est une alternative dispo) ; L2 peut **upgrader** L1 si `score_L2 ≥ score_L1 + 0.15`.
  - History exact-match after-space **réactivé** derrière ce gate (résout `feat(cascade L1)` re-enable de la roadmap commit).

### Ghost Classification Grid + Metrics

- **D-09:** Taxonomie + signal de détection (auto-classifié dans `SuggestionPolicy` en fin de cycle de vie du ghost) :
  | Catégorie | Signal |
  |---|---|
  | `correct` | Full Tab accept |
  | `acceptable` | Partial accept (chunk Tab) |
  | `useless` | Shown ≥ 200ms puis dismissed (Esc) ou typed past avec zéro overlap |
  | `bad` | Le mot suivant tapé diverge du mot 1 du ghost dans les 500ms après show |
  | `parasite` | Ghost remplacé par un autre ghost à l'intérieur du stability window (reframing de la famille `ghost_dropped_*` existante) |
- **D-10:** Mécanisme de capture — **5 nouveaux events `StaticString` count-only** : `ghost_classified_correct`, `_acceptable`, `_useless`, `_bad`, `_parasite`. Audit-safe par construction (jamais de texte user dans les logs).
- **D-11:** Release gate (rolling session-level) — **les trois doivent tenir** :
  - `correct / total ≥ 30%`
  - `(useless + bad + parasite) / total ≤ 35%`
  - `parasite / total ≤ 5%` (cap dur — la cascade churn est la régression qu'on vient de fixer en commits `2b6b6be`..`7316a8c`).
- **D-12:** Replay parity — chaque scénario `SouffleuseCoherence --replay` reçoit une **catégorie attendue** ; le replay produit une confusion matrix dans `REPLAY-RESULTS.md`. Détecte les régressions de classification avant la production.
- **D-13:** Source prior et seuils (D-06..D-08, D-11) sont des **constantes tunables** — pas de magic numbers en dur, déclarées dans un seul fichier (probable `SuggestionPolicy.Tuning`) pour ajustement futur sans hunter dans le code.

### Real-App Parity Verification

- **D-14:** Protocole — **scripted + blind A/B en séquence** :
  1. **Scripted scenarios** : 3–5 par app (reply email, mid-sentence edit, blank form, code comment quand applicable, message Slack-style court). Reproductible, time-bounded, auto-classifié.
  2. **Blind A/B daily-use** : ~½ journée par app Tier 1, Souffleuse vs Cotypist en parallèle, user log un verdict par ghost event manuellement (≤ 30 events / app).
- **D-15:** App tiering :
  - **Tier 1 (acceptance gate)** — **Mail, Notes, Brave** (gros prefix context, mid-text edits, Chromium fallback path).
  - **Tier 2 (sanity, report-only)** — Safari, TextEdit, Intercom, Notion.
- **D-16:** Critères d'acceptance Tier 1 (les trois doivent tenir) :
  - Classification grid pass D-11 par app sur les scenarios scripted.
  - Blind A/B not-worse-than Cotypist sur ≥ 5/5 scenarios scripted par app.
  - Pas de `parasite` rate > 5% dans aucune fenêtre 30 min de daily-use.
- **D-17:** Output artifacts :
  - `.planning/phases/04-cascade-quality-architecture/04-VERIFICATION-{app}.md` par app Tier 1.
  - Roll-up `04-VERIFICATION.md` avec le verdict de parité final pour le milestone.

### Claude's Discretion

- Choix précis des unit-test cases à ajouter au-delà du replay equivalence gate (D-02) — driver par testabilité émergente du split, pas spécifié upfront.
- Style des `StaticString` event names exact pour la classification grid (D-10) — convention `ghost_classified_*` proposée, ajustable au moment du plan.
- Granularité d'atomic-commit lors du split PVM (D-02) — un commit par module extrait, ou un par sous-étape de chaque module. À trancher au plan.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Project & Milestone
- `.planning/PROJECT.md` — Core Value (qualité contextuelle prime sur vitesse brute), Constraints (Swift 6, MLX, privacy invariants).
- `.planning/REQUIREMENTS.md` §v1, §v2, §"Out of Scope" — locks ce qui est dedans/dehors ce milestone.
- `.planning/ROADMAP.md` §"Phase 4: Cascade Quality + Architecture" — phase boundary canonique.
- `NEXT-MILESTONE-NOTES.md` — gap analysis original Cotypist vs Souffleuse (référence historique : points 1-6 du binaire Cotypist).

### Roadmap restructure commit (Phase 4 scope source)
- Commit `28558c9` (`chore: roadmap restructure — drop Phase 4 (Optional Sources), add Phase 4 (Cascade Quality + Architecture)`) — le commit message liste les 7 work streams qui composent ce CONTEXT.md (architecture × 2, policy, coverage, routing, quality, verification).

### Cascade work shipped session 2026-05-25 (foundation à préserver)
- Commit `3bf0cc5` — `feat(cascade L0): re-enable WordCompleter for instant mid-word ghosts`.
- Commit `e72d9eb` — `feat(cascade L1): history exact-substring match for instant ghost`.
- Commit `793a9a3` — `test(cascade L1): HistoryExactMatchTests — 8 cases`.
- Commit `52ccd02` — `perf(cascade): lower predict debounce from 150ms to 30ms`.
- Commit `e6f2a47` — `fix(cascade): source-aware anti-churn for high-confidence ghosts`.
- Commit `2b6b6be` — `fix(cascade): stop the ghost from flickering between proposals`.
- Commit `33a321e` — `fix(cascade): stability gate on instant ghost replacement`.
- Commit `7316a8c` — `fix(cascade): unstick stale HIGH-conf ghosts + narrow stability gate`.
- Commit `43c9d60` — `feat(predictor): trace ghost lifecycle via source-tagged events`.

### Prior phase decisions à carry forward
- `.planning/phases/03-perf-kv-cache/03-CONTEXT.md` — D-KV-01..D-KV-08 (KV cache integré dans `CompletionCache` du nouveau split, D-03).
- `.planning/phases/03-perf-kv-cache/03-02-SUMMARY.md` — détail wiring `KVCacheHolder` dans `PredictorViewModel.predict()` (extraction futur D-03 sait quoi déplacer).
- `.planning/phases/02-high-signal-slots/02-CONTEXT.md` — décisions Phase 2 sur `afterCursor`, `fieldContext`, `previousUserInputs` (slots consommés par `SuggestionPolicy`, à recâbler proprement).
- `.planning/phases/01-foundation-hypothesis-validation/01-CONTEXT.md` — PromptBuilder shape, slots nommés, mode replay.

### Codebase entry points (à modifier ce milestone)
- `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` (1566 LOC) — point de split D-03.
- `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift` (1209 LOC) — source d'extraction `TypingSession` D-04.
- `Souffleuse/Sources/SouffleuseTyping/WordCompleter.swift` — L0 source de la cascade.
- `Souffleuse/Tests/SouffleuseTests/HistoryExactMatchTests.swift` — tests L1 existants, à étendre derrière le Relevance Gate (D-08).
- `Souffleuse/Sources/Souffleuse/CaretResolver.swift` — caret tracking utilisé par `TypingSession` (D-04).

### Audit + bench gates
- `Souffleuse/audit.sh` — les 6 checks doivent rester verts ; D-10 ajoute des `StaticString` event names, doit passer le `os_log` audit.
- `Souffleuse/Sources/SouffleuseCoherence/main.swift` — replay harness à étendre avec colonne "expected category" (D-12).
- `Souffleuse/Sources/SouffleuseBench/Bench.swift` — TTFT regression gate, à re-runner avant/après split (D-02 equivalence check).

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **`PromptBuilder` (`SouffleusePrompt` target)** — déjà token-budgeted et slot-named. `SuggestionPolicy` lit son output, ne le re-construit pas.
- **`KVCacheHolder` + `InvariancePrefix` (Phase 3, déjà dans `PredictorViewModel`)** — migre dans `CompletionCache` au moment du split D-03. Logique de fingerprint et bypass env var (`SOUFFLEUSE_DISABLE_KV_CACHE`) à préserver.
- **`MemoizingTokenCounter` (commit `e56fdd2`)** — composant interne de `CompletionCache` après split.
- **`SimilarHistoryRetrieval` (Jaccard)** — déjà recablé sur PromptBuilder slot `previousUserInputs` en Phase 2. Reste sur place ; `SuggestionPolicy` ne le touche pas.
- **`HistoryExactMatchTests` (8 cas)** — base à étendre quand on re-active after-space derrière le Relevance Gate (D-08).
- **`StaticString` Log.info pattern** — chaque event de classification (D-10) suit la convention existante (`module: .predictor, event: "ghost_classified_correct", count: 1`).
- **Source-tagged event family (`predictor: ghost_*`)** — commit `43c9d60` a déjà introduit le tracing de cycle de vie. La classification grid (D-09..D-12) prolonge ce système, ne le remplace pas.

### Established Patterns
- **`@MainActor` façade + actor backend** — pattern omniprésent (e.g. `ContextEnricher` actor avec consumers `@MainActor`). Les 4 nouveaux modules de D-03 suivent ce pattern.
- **Generation counter + cancel-on-keystroke** — pattern central de `PredictorViewModel`, migre dans `GenerationPlanner` (D-03).
- **Privacy-by-typesystem** — `Log.info(_:_:count:)` n'accepte que `StaticString` event. D-10 est compatible par construction.
- **Atomic-commit per boundary + replay equivalence** — pattern hérité de Phase 3 (KV cache rollout). D-02 le reprend tel quel.
- **`Tuning` enum centralisé** — pattern à introduire (D-13) ; précédents : `MemoizingTokenCounter` constants, `PromptBuilderFlag`, `KVCacheBypassFlag` — tous "single-file flag holders".

### Integration Points
- **`PredictorViewModel.predict()`** (le hot path) — entrée principale du split. Aujourd'hui ~600 LOC en une closure. Après split : façade qui appelle `GenerationPlanner.schedule()` → `SuggestionPolicy.route()` → `ModelRuntime.generate()` ou `CompletionCache.lookup()` → stream onChunk via `GenerationPlanner`.
- **`SouffleuseAppDelegate.tick()`** (80ms heartbeat) — point d'extraction `TypingSession`. Aujourd'hui orchestre AX read → context enrich → predict trigger. Après extraction : `tick()` délègue à `TypingSession.tick()`, AppDelegate ne garde que le timer + lifecycle.
- **`KeyInterceptor` Tab/Esc handlers** — alimentent la classification grid (D-09) via signals "Tab pressed", "Esc pressed within X ms". Reste in-place ; `SuggestionPolicy` consomme ses callbacks.
- **`OverlayWindow.show/hide`** — appelé par `SuggestionPolicy` (post-Gate). Sera le call-site qui émet les `ghost_classified_*` events à la dismiss/accept/replace.

</code_context>

<specifics>
## Specific Ideas

- Le user a explicitement aligné le shape de la classification grid sur sa propre taxonomie introspective ("correct / acceptable / useless / bad / parasite") — cette nomenclature est canonique, downstream ne doit pas la renommer.
- Hierarchie de cascade explicite : mid-word = L0 only, after-space = L1 puis L2-upgrade. Pas de fallback inverse (L0 ne récupère JAMAIS un cas after-space). Décision dure.
- Le `parasite rate ≤ 5%` est le **cap dur** — la régression cascade churn de la session 2026-05-25 est l'événement qui motive la phase, ne pas régresser dessus.
- "Recommandé partout" — le user a délégué les 4 areas avec confiance. Aucune préférence stylistique explicite remontée pendant la discussion. La revue post-plan reste son levier de contrôle.

</specifics>

<deferred>
## Deferred Ideas

- **`clipboardContext` opt-in (ex-Phase 4 SLOT-05)** — reclassé polish-tier au commit `28558c9`. Préférence UserDefaults + UI toggle + wiring déjà conçu, juste pas ce milestone.
- **`screenContext` OCR conditional (ex-Phase 4 SLOT-06)** — reclassé polish-tier. Même statut que clipboard opt-in.
- **Apprentissage avec signal négatif (LEARN-01..04)** — débloquerait un Relevance Gate appris (vs D-05 heuristique). Différé milestone explicite.
- **Multi-candidate generation + scoring (MULT-01..03)** — orthogonal au Gate ; pourrait amplifier la qualité une fois l'infra cascade stable.
- **Filtres visuels (VIS-01..03)** — rendering concern indépendant du scoring.
- **Activation AX Electron / Signal Desktop (AX-01)** — connu, non-bloquant majorité, pas ce milestone.
- **XPC isolation 3-process** — architectural target ARCHITECTURE.md §5.bis, pas le moment.
- **Auto-tuning des constantes de scoring (D-13)** — la phase introduit des constantes tunables manuellement ; un milestone ultérieur pourrait les apprendre depuis les métriques de classification (D-10).

</deferred>

---

*Phase: 4-cascade-quality-architecture*
*Context gathered: 2026-05-25*
