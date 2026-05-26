# Phase 2: High-Signal Slots - Context

**Gathered:** 2026-05-25
**Status:** Ready for planning

<domain>
## Phase Boundary

Activer dans le `PromptBuilder` (livré Phase 1) trois nouveaux slots **à haut signal** qui visent les cas où le ghost actuel est faible — champ vide ou très court — en injectant du contexte structurel que la flat-string `contextPrefix` actuelle ne porte pas :

1. **`afterCursor`** — texte après le caret, lu via AX (`kAXSelectedTextRangeAttribute` + `kAXStringForRangeAttribute`)
2. **`fieldContext`** — métadonnées AX du champ focal (placeholder, role, subrole, help) au-delà du bundle/window-title déjà fourni par `AppContextProbe`
3. **`previousUserInputs`** — refactor nomenclature du slot `fewShot` existant pour aligner sur ROADMAP/REQUIREMENTS

Garde-fou perf : TTFT ≤ 80ms (baseline commit `6ad70df`).

**Phase 2 ne livre PAS :** `clipboardContext` opt-in et `screenContext` OCR conditional (Phase 3), ni le pivot modèle PT→IT (deferred, garde-fou de réouverture documenté ci-dessous). Le `contextPrefix` flat actuel (produit par `ContextEnricher`) **reste actif** comme en Phase 1 — pas de refactor en sous-slots app/clipboard/screen ici. Le feature flag `SOUFFLEUSE_PROMPT_BUILDER=1` reste dev-only ; le legacy path reste préservé (verdict Phase 1 conditionnel).

**Apprentissages Phase 1 portés en input** (cf. `01-05-SUMMARY.md` §Key learnings) :
- L'hypothèse "ghost junk = prompt pauvre" est validée pour empty-field, faiblement pour mid-typing (où le legacy fait déjà bien). Phase 2 vise précisément les cas empty-field/sparse.
- PT 1B-8bit bascule en EN sur app FR quand le contexte aide à éviter le junk → format des nouveaux slots reste **prose FR in-distribution**, pas de marker `<|cursor|>` style FIM.
- `--replay` harness + 12 scénarios JSON sont permanent asset — régen ~1min après chaque slot.

</domain>

<decisions>
## Implementation Decisions

### `afterCursor` — frontière typographique et activation

- **D-14: Format prose FR avec délimiteurs `« … »`, placé AVANT `beforeCursor`.** Le slot rend la chaîne `Suite du texte (à ne pas répéter) : « <afterCursor> »`. La typographie française est in-distribution pour le PT model ; pas de marker spécial (`<|cursor|>`, `[CURSOR]`, FIM) qui serait OOD pour gemma-3-1b-pt-8bit. La consigne "à ne pas répéter" est défensive — le model PT ne suit pas les instructions, mais le pattern aide les models IT si on pivote plus tard.
- **D-14b: Nouvelle assembly order.** `system → customInstructions → contextPrefix → fieldContext → afterCursor → previousUserInputs → beforeCursor`. `beforeCursor` reste en queue (juste avant la continuation modèle). `afterCursor` est placé après `fieldContext` (qui contextualise le champ) et avant `previousUserInputs` (qui contextualise l'utilisateur).
- **D-14c: Skip activation si vide.** Quand le caret est en fin de doc / `kAXStringForRangeAttribute` retourne vide / la range sélectionnée est nil, le slot est **skipped entièrement** — pas de header vide injecté. Cohérent avec le verdict Phase 1 (signal faible nuit).
- **D-14d: Budget proposé 120 tokens** — calibré sur la moyenne attendue (1-3 phrases après le caret). À ré-affiner au planner si le TTFT eyeball remonte une dégradation.

### `fieldContext` — attributs AX retenus, format, emplacement de la lecture

- **D-15: 4 attributs AX retenus : `placeholder`, `role`, `subrole`, `help`. Identifier EXCLU.**
  - `kAXIdentifierAttribute` est souvent UUID-like ou identifiant interne (`msg_xQ9z`, `_someInternalRef`) — bruit > signal, validé dans `01-CONTEXT.md`.
  - `placeholder` et `help` portent du texte utilisateur intentionnel (haute valeur quand présents).
  - `subrole` prioritaire sur `role` quand les deux sont présents (plus spécifique : `AXSearchField` > `AXTextField`).
- **D-15b: Lecture via `AXSnapshot` étendu — coût TTFT zéro pour predict path.** `AXSnapshot` est déjà capturé au tick 80ms en amont du debounce predict (50ms). Ajouter les 4 nouveaux attributs au snapshot signifie qu'ils sont gratuits côté predict (lus avant le debounce, déjà cachés sur le `MainActor`). **PAS de lecture AX dédiée dans `predict()`** — paierait le coût AX deux fois.
- **D-15c: Format FR annotation, lignes optionnelles selon dispo.**
  Exemple complet :
  ```
  Champ : recherche.
  Placeholder : « Rechercher dans la conversation… ».
  Aide : « Entrez un terme pour filtrer ».
  ```
  Chaque ligne est omise si l'attribut correspondant est vide. Le slot entier est skip si AUCUN des 4 attributs ne produit de valeur.
- **D-15d: Table de mapping role/subrole → label FR.** Petite table statique (probablement dans `SouffleuseAX` ou `SouffleusePrompt`). Exemples : `AXSearchField` → `recherche`, `AXTextArea` → `zone de texte`, `AXTextField` → `champ texte`, `AXSecureTextField` → déjà filtré upstream (pas de predict sur secure). À étendre par le planner — pas exhaustif.
- **D-15e: Budget proposé 60 tokens** — la plupart des champs produisent 1-3 lignes courtes.

### `previousUserInputs` — migration du slot `fewShot`

- **D-16: Renommer le slot `PromptSlot.fewShot` → `PromptSlot.previousUserInputs`. Slot `fewShot` retiré de l'enum.**
  - `PromptSlot.previousUserInputs` est déjà déclaré (reserved Phase 2/3) — on le bascule en actif et on supprime `fewShot`.
  - `PromptBuilder.build(...)` : paramètre `fewShot:` renommé `previousUserInputs:`.
  - `SimilarHistoryRetrieval.buildExamplesBlock(...)` : logique Jaccard inchangée. Seul l'appelant change le nom du slot cible.
  - `PromptBuilderTests` : tests snapshot mis à jour pour le nouveau nom.
- **D-16b: Eviction priority et budget hérités.** `previousUserInputs` prend la position de `fewShot` dans `evictionPriority` (first to drop quand squeeze global) et son budget (80 tokens).
- **D-16c: Aucun refactor profond de `SimilarHistoryRetrieval`.** L'API `buildExamplesBlock` reste telle quelle (formattage multi-exemples). Refactor "raw examples + builder formatte" écarté comme over-engineering pour cette phase.
- **D-16d: Impact production : zéro.** Le flag `SOUFFLEUSE_PROMPT_BUILDER=1` reste dev-only, legacy path préservé. Seul le path PromptBuilder voit le rename.

### Stratégie PERF-01 (TTFT ≤ 80ms)

- **D-17: Instrumentation per-slot dans `PromptBuilder.build()`.**
  - Mesure du temps d'assemblage **du builder lui-même** (pas TTFT end-to-end LLM) en ms via `Date()` delta (ou `mach_absolute_time` si plus précis nécessaire — planner tranche).
  - Logging via `Log.info(.predictor, "prompt_built", count: ms_total)` — `count` est un champ whitelisted (audit-safe). Optionnellement, log événement séparé par slot si utile pour diagnose.
  - **Privacy preserved :** event-only `StaticString`, pas de texte user dans les logs (TEST-03 verrouillé).
- **D-17b: Pas d'extension de `SouffleuseBench` cette phase.** Phase 1 SUMMARY a flaggé que le bench a son propre prompt path hardcodé — refactor pour router via `PredictorViewModel.predict()` est invasif. Reporté à PERF-01 hors Phase 2 ou milestone latence suivant (KV cache).
- **D-17c: TTFT end-to-end mesuré subjectivement.** Daily-use + régen `--replay` après chaque slot ajouté (3 regen attendus minimum — un par slot SLOT-02/03/04). Le `REPLAY-RESULTS.md` est régénéré idempotent (cf. `01-04-PLAN.md`).
- **D-17d: Seuil informel pour déclencher rollback.** Si daily-use perçoit une dégradation > ~30ms (eyeball, subjectif), l'instrumentation per-slot identifie le slot coûteux ; décision : drop slot / reduce budget / accept (qualité prime per Core Value). Documenté en cas de rollback dans `02-VERIFICATION.md` ou `02-XX-SUMMARY.md`.

### Modèle PT vs IT — garde-fou de réouverture

- **D-18: Phase 2 reste sur `mlx-community/gemma-3-1b-pt-8bit` (PT, statu quo).**
  - Pivot IT hors scope strict du roadmap Phase 2 (qui parle slots + PERF-01, pas model choice).
  - Phase 1 a livré l'infrastructure + l'évaluation harness ; Phase 2 livre les slots ; le pivot modèle est une décision orthogonale qu'on ne veut pas mélanger avec l'évaluation des slots (sinon impossible d'attribuer un gain ou une régression).
- **D-18b: Garde-fou de réouverture explicite — condition de re-décision AVANT Phase 3.**
  Si, après ajout complet des 3 slots Phase 2 et régen du `--replay` sur les 12 scénarios :
  - le tally reste sous le seuil **6/12** (cf. AUDIT-02), ET
  - le daily-use ne montre pas d'amélioration observable sur empty-field / message neuf,

  alors **avant** d'enchaîner Phase 3, la décision PT vs IT est rouverte. Sans ce garde-fou explicite, le milestone risque de s'enchaîner par inertie et de buter sur la même limitation modèle constatée en Phase 1 (PT bascule en EN sur app FR).

  Mécanisme : Phase 2 `VERIFICATION.md` doit contenir un section "Verdict modèle" qui statue explicitement (continue PT / pivot IT / autre).

### Claude's Discretion

- **Proportions exactes des budgets par slot** (fieldContext=60, afterCursor=120, previousUserInputs=80) — D-14d/D-15e fixent l'ordre de grandeur ; le planner peut affiner si le sweep TTFT le commande.
- **Re-calibration du `global` cap.** Phase 1 default = 512 tokens. Phase 2 ajoute 60+120 et conserve 80 (rename) → sum nouveau = 80+40+150+60+120+80+200 = 730, vs global=512 → squeeze fréquent. Le planner doit décider : bumper le `global` (ex. 768 ou 1024 — gemma-3-1b a 8192 tokens de contexte, marge), garder 512 et accepter les drops fréquents de `previousUserInputs`/`customInstructions`, ou stratégie mixte. À trancher en PLAN avec input bench/eyeball.
- **`evictionPriority` complet pour Phase 2.** Principe à suivre (planner) : drop d'abord les slots replaceables (`previousUserInputs`, `customInstructions`), puis `contextPrefix` (Phase 1 a montré qu'il porte peu de signal), puis garder le plus longtemps possible les slots haut-signal (`fieldContext`, `afterCursor`), `beforeCursor` est head-truncate (jamais drop), `system` est last-resort. Ordre exact à proposer en PLAN.
- **Format exact de l'instrumentation log** (D-17). `Log.info(.predictor, "prompt_built", count: ms)` vs un nouvel event `"prompt_build_per_slot"` avec un count par slot — planner tranche selon volume de logs vs valeur diagnostic.
- **Table de mapping role/subrole → label FR** (D-15d). Exhaustivité progressive (extend à chaque app testée).
- **Si `--replay` doit s'enrichir** de nouveaux scénarios spécifiquement mid-field / cursor-in-middle pour mieux tester `afterCursor`. Les 12 scénarios actuels sont majoritairement empty-field — peut-être en ajouter 3-5 pour Phase 2. Planner décide.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Vision et requirements (lock complet)
- `.planning/PROJECT.md` — Core Value, Active milestone (notamment CB-04/CB-05/CB-06 pour Phase 2), Key Decisions, Constraints, Context (§reframe stratégique 2026-05-24)
- `.planning/REQUIREMENTS.md` — pour Phase 2 spécifiquement : **SLOT-02, SLOT-03, SLOT-04, PERF-01** ; cross-cutting verrouillés à toute frontière de phase : **TEST-01, TEST-02, TEST-03**
- `.planning/ROADMAP.md` — Phase 2 Goal + Success Criteria + Requirements (§Phase 2 details) ; Out-of-Scope Reminders
- `.planning/STATE.md` — Performance baseline (commit `6ad70df`, TTFT ~80ms, 94+10=104 tests verts, audit.sh 6/6 OK)

### Phase 1 artifacts (lecture obligatoire — Phase 2 construit dessus)
- `.planning/phases/01-foundation-hypothesis-validation/01-CONTEXT.md` — 13 décisions D-01..D-13 verrouillées (notamment D-01..D-04 token-aware budget, D-10 SPM target, D-11 head-truncation, D-12 feature flag)
- `.planning/phases/01-foundation-hypothesis-validation/01-05-SUMMARY.md` — **verdict partiellement confirmée** (4/12 ✓) + 4 key learnings critiques (notamment learning #2 PT model EN drift)
- `.planning/phases/01-foundation-hypothesis-validation/01-VERIFICATION.md` — état réel du builder livré (10/10 truths verified, links wiring trace)
- `.planning/phases/01-foundation-hypothesis-validation/REPLAY-RESULTS.md` — verdict per-scenario (12 sections), pattern HTML-junk identifié pour empty-field WITHOUT-context
- `.planning/phases/01-foundation-hypothesis-validation/replay-scenarios.json` — 12 scénarios curated (v1 schema), permanent asset à régen pour chaque slot Phase 2 ajouté
- `.planning/phases/01-foundation-hypothesis-validation/01-RESEARCH.md` — research notes builder/eviction/tokenizer/replay schema
- `.planning/phases/01-foundation-hypothesis-validation/01-PATTERNS.md` — patterns mappés (1 type/fichier, Sendable value-type, `-ing` protocol naming)

### Codebase intel (lecture obligatoire avant tout refactor AX/builder)
- `.planning/codebase/ARCHITECTURE.md` — modular monolith, dependency graph, §Threading + §Privacy invariants + §5.bis (XPC hors scope)
- `.planning/codebase/STRUCTURE.md` — file layout par target SPM (à respecter : nouveau code Phase 2 vit dans `SouffleusePrompt` + `SouffleuseAX` + `Souffleuse` (app))
- `.planning/codebase/CONVENTIONS.md` — naming, Swift 6 strict concurrency, Sendable/actor/MainActor patterns, doc-comment style
- `.planning/codebase/TESTING.md` — patterns XCTest et conventions de mock
- `.planning/codebase/CONCERNS.md` — privacy invariants détaillés, `audit.sh` rules (TEST-03 verrouillé)
- `.planning/codebase/STACK.md` — versions MLX, dépendances exactes
- `.planning/codebase/INTEGRATIONS.md` — points de connexion AppKit/AX/MLX

### Sites de modification primaires (code production)
- `Souffleuse/Sources/SouffleusePrompt/PromptSlot.swift` — renommer `fewShot` → `previousUserInputs` ; conserver les autres reserved (`clipboardContext`, `screenContext` toujours reserved Phase 3)
- `Souffleuse/Sources/SouffleusePrompt/PromptBuilder.swift` — étendre `build(...)` signature avec `fieldContext:`, `afterCursor:`, `previousUserInputs:` (3 nouveaux paramètres) ; mettre à jour `evictionPriority` ; assembly order nouvelle (cf. D-14b) ; instrumentation per-slot
- `Souffleuse/Sources/SouffleusePrompt/PromptBudget.swift` — `phase2Default` (ou évolution de `phase1Default`) : ajout `fieldContext: 60, afterCursor: 120`, renommer `fewShot: 80` → `previousUserInputs: 80`, revisiter `global` cap (cf. Claude's Discretion)
- `Souffleuse/Sources/SouffleusePrompt/BuiltPrompt.swift` — clés `slotTexts` / `slotTokenCounts` mises à jour par le rename (mécanique)
- `Souffleuse/Sources/SouffleuseAX/AXClient.swift` — ajouter lecture de `kAXPlaceholderValueAttribute` et `kAXHelpAttribute` (role/subrole déjà lus à `:333-334, :393-394`) ; ajouter helper pour lire texte après caret via `kAXSelectedTextRangeAttribute` + `kAXStringForRangeAttribute` (range déjà lue à `:488`)
- `Souffleuse/Sources/SouffleuseAX/AXSnapshot.swift` — étendre la struct snapshot avec `placeholder: String?`, `help: String?`, `role: String?`, `subrole: String?`, `textAfterCaret: String?` (noms à finaliser au planner). Garder `Sendable`.
- `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` — wire les 3 nouveaux slots dans le path `if PromptBuilderFlag.enabled` (`:703-779`) ; consommer les nouveaux champs d'`AXSnapshot` ; appliquer la nouvelle assembly order pour le path instruct (reconstruction depuis `slotTexts`)
- `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift` — `tick()` consomme déjà `AXSnapshot` ; si extension AXSnapshot, propager le nouveau snapshot dans le ViewModel (peut-être un nouveau champ caché ou via passage direct au predict)
- `Souffleuse/Sources/SouffleusePersonalization/SimilarHistoryRetrieval.swift` — pas de refactor profond (D-16c) ; l'appelant change juste le nom du slot cible
- `Souffleuse/Sources/SouffleuseCoherence/main.swift` — `--replay` : reconstruire les slots Phase 2 dans le harness (peut-être ajouter des champs `fieldContext`, `afterCursor` aux scénarios JSON ; cf. Claude's Discretion sur enrichissement scénarios)
- `Souffleuse/Tests/SouffleuseTests/PromptBuilderTests.swift` — étendre 10 tests existants pour couvrir 3 nouveaux slots : determinism avec nouveaux slots, eviction priority révisée, never-mid-word toujours respecté sur `beforeCursor`, snapshot avec/sans `afterCursor`, fallback `fieldContext` vide

### Infrastructure du replay
- `Souffleuse/Sources/SouffleuseCoherence/main.swift:454-457` — dispatch `--replay`, helper `replayScenario` à `:271`. Étendre pour les nouveaux slots ou enrichir scénarios.
- `.planning/phases/01-foundation-hypothesis-validation/replay-scenarios.json` — v1 schema 12 scénarios. Schéma à étendre potentiellement pour `fieldContext`/`afterCursor` (vérifier ce qu'il faut au planner — peut être schemaless si `--replay` injecte directement les slots depuis des champs JSON optionnels).

### Audit privacy (non négociable)
- `Souffleuse/audit.sh` — 6 checks à maintenir verts à chaque atomic commit (TEST-03). `Sources/SouffleusePrompt` est déjà dans SHIPPING_DIRS (Phase 1).
- `Souffleuse/Sources/SouffleuseLog/Log.swift` — log facade event-only (5 champs whitelisted) ; instrumentation Phase 2 utilise UNIQUEMENT `count: Int` (audit-safe).

### Context historique (background only)
- `NEXT-MILESTONE-NOTES.md` — handoff de session 2026-05-23→24, analyse gap Cotypist vs Souffleuse ; reframe stratégique intégré dans PROJECT.md mais utile pour la généalogie

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **`PromptBuilder` (Phase 1)** — value-type Sendable, eviction priority, per-slot truncation déjà en place. Phase 2 étend `build(...)` signature et `evictionPriority`, n'écrit pas un nouveau builder.
- **`MLXTokenCounter` (Phase 1)** — adapter tokenizer MLX déjà câblé, `truncateHead` sentence-then-word fonctionnel. Phase 2 le réutilise tel quel pour les nouveaux slots (pas de mid-word).
- **`AXClient.swift`** — lit déjà `role` (`:290, :333, :393`), `subrole` (`:176, :334, :394`), `kAXSelectedTextRangeAttribute` (`:488`). Extensions Phase 2 = `kAXPlaceholderValueAttribute`, `kAXHelpAttribute`, `kAXStringForRangeAttribute`. La pattern `copyStringAttr(element, ...)` est déjà l'API helper à réutiliser.
- **`AXSnapshot`** — value-type Sendable déjà capturé à tick 80ms. Extension propre = nouveaux champs optionnels, pas de refactor structurel.
- **`SimilarHistoryRetrieval.buildExamplesBlock`** — alimente déjà le slot `fewShot` en Phase 1 (verifié dans `01-VERIFICATION.md` Truth 5). Phase 2 = juste un rename de la cible.
- **`SouffleuseCoherence --replay`** — harness fonctionnel ; régen `REPLAY-RESULTS.md` idempotent. Phase 2 régen après chaque slot.
- **`Log.info(.predictor, "event", count: N)`** — facade event-only avec champ count whitelisted. Pattern d'instrumentation D-17 utilise exclusivement ce mécanisme.
- **`PromptBuilderFlag` enum (PredictorViewModel.swift:16-19)** — lit env var `SOUFFLEUSE_PROMPT_BUILDER`. Phase 2 reste derrière ce flag, legacy path préservé.

### Established Patterns
- **Value-type Sendable + counter injection** — le pattern Phase 1 (`PromptBuilder(counter: counter, budget: budget)`) reste. Pas d'introduction d'actor pour le builder.
- **`-ing` protocol suffix pour rôles** (`TokenCounting`, `OCRCaretLocating`). Si Phase 2 introduit un protocol pour mocking AX (peu probable — extension AXSnapshot suffit), suivre la convention.
- **Tests XCTest/Swift Testing avec mock counter `WordCountTokenCounter`** (`PromptBuilderTests.swift`) — étendre, pas réécrire.
- **Configuration centralisée** — `PromptBudget.phase1Default` est un static const ; Phase 2 ajoute `phase2Default` ou évolue `phase1Default` (planner tranche).
- **Slot reserved → active migration** — Phase 1 a déjà déclaré 5 slots reserved (`afterCursor`, `fieldContext`, `previousUserInputs`, `clipboardContext`, `screenContext`). Phase 2 active 3 d'entre eux (`afterCursor`, `fieldContext`, `previousUserInputs`). `clipboardContext` et `screenContext` restent reserved pour Phase 3.

### Integration Points
- **`PredictorViewModel.predict()` ligne ~703-779** — le `if PromptBuilderFlag.enabled` branch existe déjà ; Phase 2 ajoute la lecture des nouveaux champs d'`AXSnapshot` et passe les nouveaux slots au `builder.build(...)`.
- **`SouffleuseAppDelegate.tick()`** — orchestrateur déjà câblé : appelle `axClient.snapshot()` toutes les 80ms et déclenche le predict après debounce. Extension `AXSnapshot` est transparente pour ce path tant que les champs nouveaux sont propagés au ViewModel.
- **`AXSnapshot` ↔ `PredictorViewModel`** — frontière `Sendable` actuelle. Ajouter des champs `String?` au snapshot ne change pas la nature Sendable.
- **`SouffleuseCoherence/main.swift:454-457`** — dispatch `--replay`. La fonction `replayScenario` (`:271`) construit le predict à partir du JSON ; Phase 2 doit injecter les nouveaux champs (`fieldContext` et `afterCursor`) si les scénarios sont enrichis, ou laisser ces slots vides si on garde le schema v1.

</code_context>

<specifics>
## Specific Ideas

- **Préférence forte pour FR in-distribution** — pas de markers spéciaux pour `afterCursor`. Tous les délimiteurs visibles dans le prompt sont de la typographie française (`« … »`).
- **AX reads dans le snapshot, pas dans predict** — préférence forte pour préserver TTFT côté predict. Le builder ne fait jamais de read AX direct.
- **PT model maintenu** — pas de pivot modèle dans Phase 2. Le pivot, si nécessaire, est tranché APRÈS Phase 2 et AVANT Phase 3 (garde-fou D-18b).
- **`--replay` est la source de vérité d'évaluation** — chaque slot ajouté = régen. Le markdown side-by-side reste le verdict.
- **Instrumentation log audit-safe** — uniquement `count: Int`, jamais de texte user, conformité TEST-03.

</specifics>

<deferred>
## Deferred Ideas

- **Pivot PT → IT model** — pas en Phase 2 (D-18). Réouverture conditionnelle AVANT Phase 3 selon le tally `--replay` post-Phase-2 et l'eyeball daily-use (D-18b).
- **Refactor profond de `SimilarHistoryRetrieval`** — D-16c écarte l'option "raw examples + builder formatte" comme over-engineering pour cette phase. Si le few-shot devient bruyant en pratique, à revisiter Phase 3 ou milestone suivant.
- **Instrumentation TTFT end-to-end via SouffleuseBench refactor** — D-17b reporte. Le bench actuel a son propre prompt path hardcodé ; refactor pour router via `predict()` est un milestone latence à part entière (KV cache).
- **Slot-level instrumentation TTFT plus granulaire** (timing par AX read individuel, par lecture tokenizer, etc.) — D-17 livre un timing builder-only ; si la diagnose Phase 2 le commande, le planner peut affiner mais ce n'est pas la cible.
- **Refactor `ContextEnricher` en slots indépendants** (`appContext`, `clipboardContext`, `screenContext` séparés) — Phase 3 (SLOT-05, SLOT-06). Phase 2 le traite comme une boîte noire alimentant `contextPrefix` flat.
- **Enrichissement des scénarios `--replay` avec cas mid-field / cursor-in-middle** — Claude's Discretion ; les 12 scénarios actuels sont majoritairement empty-field. Pour bien tester `afterCursor`, possiblement ajouter 3-5 scénarios mid-typing. À évaluer en plan-phase ; non bloquant Phase 2.
- **Table de mapping role/subrole → label FR exhaustive** — extension progressive à chaque app testée. Pas de pré-construction massive.
- **Heuristiques automatiques pour le verdict A/B** (déjà deferred en Phase 1) — toujours hors scope.
- **LLM-as-judge externe** — hors scope absolu (privacy : pas de réseau au runtime).
- **Retrait du feature flag legacy** — toujours conditionnel à un verdict positif observable. Reste deferred à la fin de Phase 2 (ou Phase 3) selon ce que les slots livrent. Phase 1 a déjà documenté cette logique en `01-05-SUMMARY.md` §Implications ROADMAP.

</deferred>

---

*Phase: 2-High-Signal Slots*
*Context gathered: 2026-05-25*
