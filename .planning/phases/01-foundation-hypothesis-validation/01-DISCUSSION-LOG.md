# Phase 1: Foundation + Hypothesis Validation - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-05-24
**Phase:** 1-foundation-hypothesis-validation
**Areas discussed:** Comptage de tokens, Scope du replay harness, Placement SPM + eviction beforeCursor, Direction migration strategy

---

## Comptage de tokens

### Q1 — Méthode de mesure des tokens

| Option | Description | Selected |
|--------|-------------|----------|
| Tokenizer MLX réel | Tokenizer du modèle chargé via MLXLMCommon. Précis, ~quelques ms par predict. | ✓ |
| Estimateur heuristique | Chars/4. Rapide mais ±20% d'erreur sur français accentué / code / emoji. | |
| Hybride mémoïsé | Tokenizer réel + cache LRU des comptages. Premier hit coûteux, repeats gratuits. | |

**User's choice:** Tokenizer MLX réel (Recommandé)
**Notes:** Précision > coût pour Phase 1.

### Q2 — Disponibilité du tokenizer (cold-start)

| Option | Description | Selected |
|--------|-------------|----------|
| Tokenizer requis | Builder jamais construit avant model load. Pas de fallback. | ✓ |
| Fallback heuristique pendant cold-start | Heuristique chars/4 le temps que le modèle charge, bascule après. | |
| Builder retardé | predict() bloque sur tokenizer ready. | |

**User's choice:** Tokenizer requis (Recommandé)
**Notes:** Invariant déjà respecté via `loadState` — surface API plus simple, tests plus déterministes.

### Q3 — Budget total du prompt

| Option | Description | Selected |
|--------|-------------|----------|
| ~512 tokens | ~3-4× cap actuel. Marge confortable. | ✓ |
| ~1024 tokens | Généreux. Risque TTFT mesurable. | |
| ~256 tokens | Strict. Force discipline mais peut étouffer SLOT-02 Phase 2. | |
| Tu décides | Planner propose et affine via mini-bench. | |

**User's choice:** ~512 tokens (Recommandé)
**Notes:** Valeur à ré-affiner si SouffleuseBench remonte une dégradation.

### Q4 — Politique d'allocation entre slots

| Option | Description | Selected |
|--------|-------------|----------|
| Allocation fixe par slot | Chaque slot déclare son budget en tokens. Eviction par slot indépendant. | ✓ |
| Allocation par priorité (greedy) | Slots ordonnés, low-pri évincés si pas de place. | |
| Allocation par poids | Pourcentages relatifs réparties proportionnellement. | |

**User's choice:** Allocation fixe par slot (Recommandé)
**Notes:** Prévisible, testable en isolation, compatible avec ajout slots Phase 2/3 sans refactor.

---

## Scope du replay harness

### Q1 — Localisation du harness

| Option | Description | Selected |
|--------|-------------|----------|
| Étendre SouffleuseCoherence | Mode --replay sur l'executable existant. Réutilise load model. | ✓ |
| Nouvel executable SouffleusePromptReplay | Target SPM dédié. Plus propre sémantiquement mais duplique boilerplate. | |
| Tests XCTest avec snapshot | Pas d'executable. Verdict A/B métrique-only, pas de ghost réel généré. | |
| Les deux: tests + exec | Snapshot tests builder + exec MLX pour verdict humain. | |

**User's choice:** Étendre SouffleuseCoherence (Recommandé)
**Notes:** Tests snapshot du builder restent prévus en complément (BUILDER-03 + TEST-02) — voir D-06 dans CONTEXT.md.

### Q2 — Source des scénarios

| Option | Description | Selected |
|--------|-------------|----------|
| Curated user, YAML/JSON checked-in | 10-20 scénarios en dur. Reproductible, versionné, diffable. | ✓ |
| Capturés depuis logs anonymisés | Plus authentique, effort instrumentation + privacy review. | |
| Templated avec paramétrage | Templates × N variations. Plus large mais artificiel. | |

**User's choice:** Curated user, YAML/JSON checked-in (Recommandé)
**Notes:** Schéma minimum documenté en D-07. Capture depuis logs reste candidate pour Phase 3.

### Q3 — Mécanisme de verdict A/B

| Option | Description | Selected |
|--------|-------------|----------|
| Eyeball humain side-by-side | Ghosts côte-à-côte, user vote ✓/✗/=. | ✓ |
| Heuristiques automatiques | Non-vide, non-générique, mention contextPrefix. Déterministe mais grossier. | |
| Mix : heuristiques + eyeball pour cas border | Heuristiques pré-filtrent, user arbitre litigieux. | |
| LLM-as-judge | Modèle plus gros vote. Hors-scope (réseau). | |

**User's choice:** Eyeball humain side-by-side (Recommandé)
**Notes:** Cohérent avec « parité subjective vs Cotypist ». Heuristiques candidates Phase 2/3.

### Q4 — Format de sortie du replay

| Option | Description | Selected |
|--------|-------------|----------|
| Markdown checked-in dans .planning/ | REPLAY-RESULTS.md regen à chaque run. Diffable, audit trail. | ✓ |
| JSON + script de rendu | Plus flexible mais 2 outils à maintenir. | |
| Console + fichier log | Print stdout + dump log. Simple, pas de markdown. | |

**User's choice:** Markdown checked-in (Recommandé)
**Notes:** Path proposé : `.planning/phases/01-foundation-hypothesis-validation/REPLAY-RESULTS.md`.

---

## Placement SPM + eviction beforeCursor

> **Mode auto-recommandé** activé par l'utilisateur (« passe en recommandé partout »).
> Options ci-dessous tirées de l'analyse pré-discussion (alignement convention codebase + REQUIREMENTS SLOT-01).

### Q1 — Placement SPM du PromptBuilder

| Option | Description | Selected |
|--------|-------------|----------|
| Nouveau target `SouffleusePrompt` | Cohérent avec convention "1 capacité = 1 target". Dépend SouffleuseLog/Context/Personalization + MLXLMCommon. | ✓ |
| Extension de SouffleuseContext | Le builder reste dans le module qui produit la matière première. Couple les deux capacités. | |
| Inline dans Souffleuse app | Pas de target dédié. Plus simple mais viole la convention. | |

**User's choice:** Nouveau target `SouffleusePrompt` (auto-recommandé)
**Notes:** Convention codebase respectée (cf. STRUCTURE.md, CONVENTIONS.md).

### Q2 — Granularité d'eviction `beforeCursor`

| Option | Description | Selected |
|--------|-------------|----------|
| Frontière phrase puis mot | Coupe à dernière phrase qui rentre, fallback dernier mot. Jamais mid-word. | ✓ |
| Frontière mot seulement | Toujours couper à un whitespace. Plus simple, moins signal-aware. | |
| Frontière paragraphe | Coupe à dernier `\n\n`. Très restrictif, garde peu de texte. | |

**User's choice:** Frontière phrase puis mot (auto-recommandé)
**Notes:** Satisfait SLOT-01 (« préserve le dernier mot complet sous son budget »).

---

## Direction migration strategy

> **Mode auto-recommandé** activé par l'utilisateur.
> Constraint codebase : « migration strategy à décider en plan-phase 1 » — direction indicative seulement.

### Q1 — Approche de migration de la flat-string vers le builder

| Option | Description | Selected |
|--------|-------------|----------|
| Feature flag dev-only parallèle | Builder coexiste avec flat-string, sélecteur env var. Revert local instantané. | ✓ |
| In-place refactor | Un commit qui bascule. Pas de double maintenance mais risque non-régression. | |
| Path parallèle sans flag | Builder construit mais predict() utilise flat-string jusqu'au cut-over. | |

**User's choice:** Feature flag dev-only parallèle (auto-recommandé)
**Notes:** Garantit BUILDER-04 (pipeline existante sans régression). Planner libre de pivoter si invasivité minimale (D-13).

---

## Claude's Discretion

- Proportions exactes des budgets par slot (chiffres précis) — D-04 fixe la policy, valeurs au planner
- Seuil de validation AUDIT-02 (par ex 6/10, 7/10) — au planner
- Schéma exact du fichier scénarios JSON/YAML (D-07 fixe minimum requis)
- Nom exact du target SPM (`SouffleusePrompt` proposé, `SouffleusePromptBuilder` acceptable)
- Choix exact du nom de l'env var de feature flag (proposé `SOUFFLEUSE_PROMPT_BUILDER=1`)

## Deferred Ideas

- Slot-level instrumentation TTFT (Phase 2, PERF-01)
- Refactor `ContextEnricher` en slots indépendants (Phase 3, SLOT-05/06)
- Heuristiques automatiques pour le verdict A/B (Phase 2/3 si valeur prouvée)
- LLM-as-judge externe (hors scope absolu — privacy invariant réseau)
- Choix env var vs UserDefaults pref pour le feature flag (sans impact fonctionnel)
- Schéma JSON/YAML étendu (`expectedTopic`, `mustNotContain`, etc.)
- Capture de scénarios depuis logs anonymisés (candidate Phase 3)
