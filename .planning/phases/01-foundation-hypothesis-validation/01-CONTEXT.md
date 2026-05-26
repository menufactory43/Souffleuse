# Phase 1: Foundation + Hypothesis Validation - Context

**Gathered:** 2026-05-24
**Status:** Ready for planning

<domain>
## Phase Boundary

Remplacer la flat-string concat actuelle dans `PredictorViewModel.predict()` (lignes 478-513) par un **PromptBuilder structuré token-budgeté**, livrer le slot `beforeCursor` proprement budgeté (remplace le truncate dumb à 512 chars), et embarquer un **mode replay** qui rejoue 10-20 scénarios scriptés pour produire un verdict A/B (avec-contexte vs sans-contexte) — afin de valider ou réfuter l'hypothèse fondatrice (« le ghost junk vient du prompt pauvre, pas du modèle ») avant d'investir Phase 2.

**Phase 1 ne livre PAS** : les slots `afterCursor`, `fieldContext`, `previousUserInputs` (Phase 2), ni `clipboardContext`, `screenContext` (Phase 3). L'infra builder doit être conçue pour les accueillir, mais seul `beforeCursor` est actif au runtime ce phase. `customInstructions` et `contextPrefix` (ContextEnricher flat) restent injectés comme aujourd'hui — passés au builder comme slots "flat passthrough" non-budgétés ou avec budget dédié séparé. À trancher au planner si granularité plus fine nécessaire.

</domain>

<decisions>
## Implementation Decisions

### Comptage de tokens

- **D-01: Tokenizer MLX réel.** Le PromptBuilder utilise le tokenizer du `ModelContainer` chargé (via `MLXLMCommon`) pour mesurer exactement la longueur en tokens de chaque slot. Pas d'estimateur heuristique (chars/4) — la précision compte plus que le coût (qui reste de quelques ms par predict).
- **D-02: Tokenizer requis, pas de fallback.** `predict()` n'est jamais appelé avant que `loadContainer` ait livré le tokenizer (invariant déjà respecté via `loadState`). Le builder est construit après le model load et n'a aucun chemin "cold-start estimator". Surface API plus simple, tests plus déterministes.
- **D-03: Budget total ~512 tokens** pour le prompt complet (≈3-4× la baseline char actuelle de 512 chars/~150-200 tokens). Marge confortable pour les slots actifs en Phase 1 (system + `beforeCursor` + `contextPrefix` flat + few-shot dynamique) sans exploser TTFT. Valeur à ré-affiner si SouffleuseBench remonte une dégradation > seuil au planner.
- **D-04: Allocation fixe par slot.** Chaque slot déclare son budget en tokens dans sa config (ex: `beforeCursor=200, system=80, contextPrefix=150, fewShot=80, customInstructions=40` — proportions indicatives, à finaliser au planner). Builder additionne et rejette si total > budget global. Eviction se fait **par slot indépendamment** (pas de "vol" cross-slot). Prédictible, testable en isolation, et compatible avec l'ajout des slots Phase 2/3 sans refactor de la policy.

### Scope du replay harness

- **D-05: Le replay étend `SouffleuseCoherence`** (executable existant : `Souffleuse/Sources/SouffleuseCoherence/main.swift`). On ajoute un mode `--replay` ou un nouveau sub-command qui charge un fichier de scénarios et produit le rendu A/B. Réutilise la machinerie MLX/load model déjà en place. Pas de nouveau target SPM dédié au replay.
- **D-06: Tests snapshot du builder en complément.** Indépendamment du replay MLX (slow, requiert modèle), le builder a des tests unitaires XCTest qui snapshottent le prompt assemblé pour des scénarios fixés — déterministes, rapides, CI-friendly, satisfont BUILDER-03 et TEST-02. Le replay MLX est pour le verdict humain ; les snapshot tests sont pour la non-régression du builder.
- **D-07: Scénarios curated checked-in.** Les 10-20 scénarios vivent dans un fichier YAML ou JSON checked-in (chemin proposé : `.planning/phases/01-foundation-hypothesis-validation/replay-scenarios.json`). Chaque scénario définit : `id`, `label`, `bundleID`, `windowTitle`, `contextPrefix` (string), `userTail` (string), `notes` (optionnel). Versionné, diffable, reproductible. Pas de capture depuis logs (privacy + complexité), pas de templating (artificiel à ce stade).
- **D-08: Verdict = eyeball humain side-by-side.** Le replay produit pour chaque scénario : ghost sans-contexte (PromptBuilder avec `contextPrefix` désactivé) ET ghost avec-contexte (PromptBuilder complet), côte-à-côte. C'est toi qui votes (✓ / ✗ / =). Cohérent avec le critère projet « parité subjective vs Cotypist ». Pas d'heuristiques automatiques en Phase 1 (peuvent venir en Phase 2/3 si valeur prouvée). Pas de LLM-as-judge (out-of-scope: réseau).
- **D-09: Output = markdown checked-in.** Le replay regen `.planning/phases/01-foundation-hypothesis-validation/REPLAY-RESULTS.md` à chaque exécution. Chaque scénario rend en une section markdown avec les deux variantes côte-à-côte, plus un slot vide pour le verdict humain (✓ / ✗ / = + notes). Diffable git, partageable, audit trail. AUDIT-02 verrouille : si verdict global ≥ N/M positifs (seuil à fixer au planner, par ex 6/10), milestone continue ; sinon, milestone est revu avant Phase 2.

### Placement SPM + eviction beforeCursor

- **D-10: Nouveau target SPM `SouffleusePrompt`.** Cohérent avec la convention codebase (`.planning/codebase/STRUCTURE.md`, CONVENTIONS.md) : « chaque capacité réutilisable est un target SPM préfixé `Souffleuse` ». Le builder est une capacité distincte de l'enrichment (qui produit la matière première) et de la prédiction (qui run MLX). Le target dépend de : `SouffleuseLog`, `SouffleuseContext` (pour les types EnrichedContext), `SouffleusePersonalization` (pour `SimilarHistoryRetrieval` quand Phase 2 le branchera), et `MLXLMCommon` (pour accès tokenizer). Consommé par le target `Souffleuse` (app) et par `SouffleuseCoherence` (replay).
- **D-11: Eviction `beforeCursor` = truncation côté tête, frontière phrase-puis-mot.** Le slot préserve la queue (le texte juste avant le caret est le plus signal-rich). Stratégie : (a) si le budget permet, couper à la dernière frontière de phrase qui rentre (`.`, `?`, `!`, `\n` doublé) ; (b) sinon, couper à la dernière frontière de mot (whitespace / ponctuation) ; (c) **jamais** de coupe mid-word (invariant testable). Cela remplace le truncate dumb à 512 chars actuel et satisfait SLOT-01 (« préserve le dernier mot complet sous son budget »).

### Direction migration strategy

- **D-12: Feature flag dev-only en parallèle.** Pendant la construction, le nouveau path PromptBuilder coexiste avec la flat-string actuelle dans `predict()`, sélectionné par env var (proposé : `SOUFFLEUSE_PROMPT_BUILDER=1`) ou pref cachée. Ça garantit BUILDER-04 (« la pipeline existante continue de fonctionner sans régression pendant la construction ») de manière mécanique, permet de basculer le replay harness sur l'un ou l'autre, et autorise un revert local instantané si un bug pernicieux apparaît. Le flag est retiré (et la flat-string supprimée) à la fin de Phase 1 une fois que le verdict replay est positif et que les 94 tests + nouveaux snapshot tests sont verts.
- **D-13: Direction indicative, pas verrouillée.** Le planner reste libre de pivoter en in-place refactor si l'invasivité s'avère minimale (par exemple si `predict()` peut être découpé pour que `systemMessage` / `basePreamble` soient déjà produits par un builder sans changement d'interface). Marquer ça comme « default = feature flag, escape hatch = in-place avec justification dans PLAN.md ».

### Claude's Discretion

- Proportions exactes des budgets par slot (`beforeCursor=200, system=80, contextPrefix=150, …`) — D-04 fixe la policy, mais les chiffres précis se règlent au planner avec un mini-bench TTFT/qualité.
- Seuil de validation AUDIT-02 (par ex 6/10, 7/10) — à proposer au planner et discuter en plan-review.
- Schéma exact du fichier scénarios JSON/YAML (D-07 fixe le minimum requis ; le planner peut ajouter `expectedTopic`, `mustNotContain`, etc.).
- Nom exact du target SPM (`SouffleusePrompt` proposé en D-10 ; `SouffleusePromptBuilder` acceptable si le planner préfère plus explicite).
- Choix exact du nom de l'env var de feature flag (D-12 propose `SOUFFLEUSE_PROMPT_BUILDER=1`).

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Vision et requirements (lock complet)
- `.planning/PROJECT.md` — Core Value, Active milestone (CB-01..CB-11), Key Decisions, Constraints, Context (notamment §reframe stratégique 2026-05-24)
- `.planning/REQUIREMENTS.md` — 18 v1 requirements ; pour Phase 1 spécifiquement : AUDIT-01, AUDIT-02, BUILDER-01, BUILDER-02, BUILDER-03, BUILDER-04, SLOT-01, TEST-01, TEST-02, TEST-03
- `.planning/ROADMAP.md` — Phase 1 Goal + Success Criteria + Requirements (lignes 23-34) ; Out-of-Scope Reminders (lignes 89-99)
- `.planning/STATE.md` — Performance baseline (commit `6ad70df`, TTFT ~80ms, 94 tests verts, audit.sh 6 checks)

### Codebase intel (lecture obligatoire avant tout refactor)
- `.planning/codebase/ARCHITECTURE.md` — modular monolith, dependency graph, §Threading + §Privacy invariants + §5.bis (XPC target hors-scope)
- `.planning/codebase/STRUCTURE.md` — file layout par target SPM ; à respecter pour le nouveau target `SouffleusePrompt`
- `.planning/codebase/CONVENTIONS.md` — naming patterns (1 type par fichier, préfixe `Souffleuse`, `UpperCamelCase`), Swift 6 strict concurrency rules, `Sendable` / `actor` / `@MainActor` patterns, doc-comment style
- `.planning/codebase/TESTING.md` — patterns XCTest et conventions de mock (`MockOCRCaretLocator` style)
- `.planning/codebase/CONCERNS.md` — privacy invariants détaillés, `audit.sh` rules
- `.planning/codebase/STACK.md` — versions MLX, dépendances exactes
- `.planning/codebase/INTEGRATIONS.md` — points de connexion AppKit/AX/MLX

### Sites de modification primaires (code production)
- `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` — site du refactor ; spécifiquement lignes 478-513 (assemblage `systemMessage` + `basePreamble`) et lignes 506-513 (few-shot insertion path)
- `Souffleuse/Sources/SouffleuseContext/ContextEnricher.swift` — producteur du `contextPrefix` flat actuel ; consommé par PromptBuilder en Phase 1, refactor possible en Phase 2/3
- `Souffleuse/Sources/Souffleuse/PreferencesStore.swift` — `K` enum pour ajouter d'éventuelles préférences (env var préféré pour le flag dev, mais pref si on veut exposer ; à trancher au planner)

### Infrastructure du replay
- `Souffleuse/Sources/SouffleuseCoherence/main.swift` — executable existant à étendre avec mode `--replay`. Inspecter la pattern actuelle (load model, run, render markdown) pour réutiliser.
- `Souffleuse/Package.swift` — manifeste SPM à modifier pour ajouter target `SouffleusePrompt` et brancher `SouffleuseCoherence` dessus.

### Audit privacy (non négociable)
- `Souffleuse/audit.sh` — 6 checks à maintenir verts à chaque atomic commit (TEST-03)
- `Souffleuse/Sources/SouffleuseLog/Log.swift` — log facade event-only (5 champs whitelisted), aucune source de contexte ne peut écrire de texte user dans les logs

### Context historique (background only)
- `NEXT-MILESTONE-NOTES.md` — handoff de session 2026-05-23→24, analyse gap Cotypist vs Souffleuse ; le reframe stratégique a déjà été intégré dans PROJECT.md, mais utile pour comprendre la généalogie des décisions

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **`ContextEnricher`** (`SouffleuseContext/ContextEnricher.swift`) — produit déjà un `contextPrefix` flat (`"App X, window \"…\". Clipboard: …. On screen: …"`). En Phase 1, le PromptBuilder consomme cette string telle quelle dans un slot "passthrough contextPrefix". Le refactor en slots séparés (`appContext`, `clipboardContext`, `screenContext` indépendants) viendra plus tard (Phase 3). Ne pas tout casser maintenant.
- **`SimilarHistoryRetrieval`** (`SouffleusePersonalization/SimilarHistoryRetrieval.swift`) — source few-shot Jaccard déjà fonctionnelle. Phase 1 ne la touche pas mais le builder doit avoir un slot reservé `previousUserInputs` (Phase 2 le branchera proprement).
- **`SouffleuseCoherence/main.swift`** — executable MLX déjà câblé (load container, run benches, env-gated par `SOUFFLEUSE_MODEL`, `SOUFFLEUSE_PENALTY`, `SOUFFLEUSE_CONTEXT`). Extension `--replay` réutilise toute cette machinerie.
- **`PreferencesStore.K`** — enum centralisant les UserDefaults keys. Précédent à respecter si on expose le flag de migration via une pref (sinon env var = pas d'impact).
- **`PredictDebug`** (`PredictorViewModel.swift:10`) — debug logger env-gated (`SOUFFLEUSE_PREDICT_LOG`). Pattern à imiter si on veut instrumenter le builder en dev sans toucher les invariants privacy.

### Established Patterns
- **Builder pur, value-type, Sendable.** Les autres value types du projet (`AXSnapshot`, `EnrichedContext`, `LogEntry`) sont tous `Sendable + Equatable`. Le PromptBuilder lui-même peut être une `struct` configurée avec une `init(tokenizer:)` ; chaque `build(slots:)` retourne un `BuiltPrompt: Sendable, Equatable` (string + métadonnées de comptage). Facilite snapshot tests et tests d'eviction.
- **Naming protocols avec suffix `-ing`.** Exemple : `OCRCaretLocating`. Si on veut un protocol pour tokenizer-abstraction (utile pour mocks de tests sans charger MLX), nommer `TokenCounting` ou `TokenMeasuring`.
- **Configuration centralisée.** Précédent dans `PreferencesStore.K` (UserDefaults keys) et `TypoDetector.maxLevenshtein` (static constants). Budgets par slot doivent vivre dans une struct dédiée (proposé : `PromptBudget`) ou sur le builder lui-même.
- **`@MainActor` côté UI/AppKit, `actor` côté state, `nonisolated` pour pure fonctions.** Le builder est probablement `nonisolated` (pure assembly) — il prend ses dépendances en paramètre et n'a pas de state mutable.
- **Tests XCTest avec test-only seams.** Précédent : `TypingHistoryStore` expose `init(fileURL:testKey:)`. Le builder doit accepter un tokenizer mock (protocol) pour tests sans MLX.

### Integration Points
- **`PredictorViewModel.predict()` lignes 478-513** : c'est ici que la flat-string concat actuelle vit. Le PromptBuilder remplace `systemMessage` ET `basePreamble` (les deux paths : instruct via `applyChatTemplate` et base/PT via raw text). Le feature flag dev-only (D-12) sélectionne lequel des deux paths utiliser pendant la construction.
- **Few-shot dynamique lignes 500-513 + plus bas dans la Task async** : la composition actuelle insère le bloc few-shot JUSTE AVANT le `userTail`. Le PromptBuilder doit avoir un slot dédié (proposé : `previousUserInputs`) qui occupe cette position, alimenté par `SimilarHistoryRetrieval` (Phase 2). Pour Phase 1, ce slot peut rester vide ou alimenté de la même façon qu'aujourd'hui — préserver le comportement existant.
- **`Package.swift`** : ajouter `SouffleusePrompt` comme library target, brancher `Souffleuse` (app) et `SouffleuseCoherence` dessus. Inspecter `Souffleuse/Package.swift:9-22` pour le pattern exact des declarations de target.
- **`SouffleuseCoherence/main.swift`** : ajouter un sub-command ou parser d'argument pour `--replay <scenarios.json>`. Le replay charge le modèle (déjà fait par le main existant), instancie le builder, exécute le predict pour chaque scénario en deux variantes (avec/sans contextPrefix), et écrit le markdown.

</code_context>

<specifics>
## Specific Ideas

- **Inspiration Cotypist (analyse binaire, NEXT-MILESTONE-NOTES.md §1-3)** : Cotypist expose `tokenBudget`, `maxPromptTokens`, `contentBudget` — donc le pattern « budget par catégorie en tokens » est validé concurrence. On reproduit l'esprit sans copier le code.
- **`SouffleuseCoherence` existe déjà** comme harness MLX. La décision D-05 (étendre, pas créer un nouveau target) capitalise sur ce travail.
- **Le replay verdict reste humain.** Cohérent avec « parité subjective + soft latency » dans PROJECT.md. Pas de tentation d'automatiser un goût.
- **Feature flag = dev-only**, jamais exposé à un user final. Pas de UI, pas de pref visible — env var ou pref cachée. Le flag disparaît avant la fin de Phase 1.

</specifics>

<deferred>
## Deferred Ideas

- **Slot-level instrumentation TTFT.** Mesurer le coût en ms apporté par chaque slot individuellement (instrumentation au niveau du builder). Utile en Phase 2 où `afterCursor` ajoute une lecture AX qui peut coûter. Proposé pour PERF-01 (Phase 2) ou plus tôt si le replay révèle une régression flagrante.
- **Refactor de `ContextEnricher` en slots indépendants** (`appContext`, `clipboardContext`, `screenContext` produits séparément). Cohérent avec la décomposition cible du milestone (SLOT-05, SLOT-06 en Phase 3 quand l'OCR devient conditional). Phase 1 le traite comme une boîte noire.
- **Heuristiques automatiques pour le verdict A/B** (substring matching, blocklist de "Coucou", etc.). Peut compléter l'eyeball verdict si la Phase 1 montre que certains scénarios sont triviaux à juger. Tracker comme future enhancement de l'audit, pas pour Phase 1.
- **LLM-as-judge externe.** Hors scope absolu (privacy invariant : pas de réseau au runtime). Mention pour mémoire seulement.
- **Choix entre env var et UserDefaults pref pour le feature flag.** Sans impact fonctionnel ; à trancher au planner. Env var = zero impact runtime user, pref = plus simple à activer en dev sans relancer le process.
- **Schéma JSON/YAML pour les scénarios.** Le minimum requis est documenté en D-07. Extensions possibles (`expectedTopic`, `mustNotContain`, `targetLanguage`, `tagsForFiltering`) à itérer en Phase 2/3 si valeur prouvée.
- **Capture de scénarios depuis logs anonymisés.** Source initialement considérée puis écartée pour Phase 1 (privacy + complexité d'instrumentation). Si la Phase 1 valide l'hypothèse, peut devenir intéressant en Phase 3 pour enrichir la collection de scénarios avant le verdict de parité final.

</deferred>

---

*Phase: 1-Foundation + Hypothesis Validation*
*Context gathered: 2026-05-24*
