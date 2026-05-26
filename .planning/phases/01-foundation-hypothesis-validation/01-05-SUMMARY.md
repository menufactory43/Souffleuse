---
phase: 01-foundation-hypothesis-validation
plan: 05
status: complete
type: checkpoint
autonomous: false
requirements: [AUDIT-02, TEST-01]
completed: 2026-05-25
---

# Plan 01-05 — Phase 1 Verdict + Cleanup (Conditional)

## Outcome

**HYPOTHÈSE PARTIELLEMENT CONFIRMÉE** (4/12 ✓ strict, sous le seuil 6/12).
**Cleanup différé** : feature flag et legacy path préservés. Décision explicite, pas un échec.

## Tasks executed

### Task 1 — Bench TTFT (legacy vs builder path)
**Status:** SKIPPED with documented fallback (per plan W9 path).

**Reason:** Inspection préalable de `Souffleuse/Sources/SouffleuseBench/Bench.swift` confirme
que le bench n'instrumente pas `PredictorViewModel.predict()` — il a son propre prompt path
hardcodé (`context.tokenizer.encode(text: c.prompt)`). L'env var `SOUFFLEUSE_PROMPT_BUILDER=1`
n'aurait aucun effet sur les mesures TTFT du bench.

**Fallback documenté:** TTFT du nouveau path mesuré subjectivement via daily-use post-Phase-1.
Bench formal reporté à PERF-01 Phase 2 (avec instrumentation explicite du bench si nécessaire).

**Non-régression catastrophique vérifiée:** `swift build` exit 0, `swift test` 104/104 verts,
`bash audit.sh` 6/6 OK — le path predict + builder compile et fonctionne en isolation.

### Task 2 — Replay + eyeball verdict (12 scénarios)
**Status:** COMPLETE.

**Command exécutée:**
```bash
SOUFFLEUSE_PROMPT_BUILDER=1 swift run SouffleuseCoherence \
  --replay ../.planning/phases/01-foundation-hypothesis-validation/replay-scenarios.json
```
**Modèle:** `mlx-community/gemma-3-1b-pt-8bit` · **Durée:** ~50s.

**Tally final:**
- ✓ with-context better: **4** / 12
- = neutral:              **6** / 12
- ✗ with-context worse:   **2** / 12

**Détail per-scenario:** voir `REPLAY-RESULTS.md` (12 sections cochées + human notes).

**Pattern observé:**
- Sur 5 scénarios à champ vide (1, 3, 5, 7, 9), WITHOUT-context produit systématiquement
  `<input type="text" id="autocomplete"...` — l'attracteur HTML-junk du modèle PT en l'absence
  de signal. L'hypothèse "ghost junk vient du prompt pauvre" est **mécaniquement confirmée**.
- Mais le contexte aide à **échapper au junk** sans **livrer de pertinence** : WITH-context
  bascule souvent en EN sur app FR (scénarios 3, 7, 9) ou produit du texte méta.
- Sur scénarios mid-typing (2, 4, 6, 10, 11), aucun gain observable du `contextPrefix` actuel
  (app+window+clipboard+OCR via `ContextEnricher`).

**Évidence external — production legacy daily-use:**
Screenshots `/private/tmp/souffleuse-bench-v1/` (20 cas réels mid-typing, dated 2026-05-24)
montrent que la production legacy actuelle produit déjà des ghosts français pertinents
(ex: `"Je reviens "` → `"vers vous"`, `"bonne journ"` → `"ée"`, `"Bonjour Marie, "` → `"je voulais te"`).
Le gap empty-field exposé par le replay n'est pas le cas dominant en usage quotidien.

### Task 3 — Cleanup (conditional)
**Status:** SKIPPED per verdict NON-CONFIRMÉE strict (negative branch).

**Verify command exécutée (negative branch):**
```bash
grep -q "HYPOTHÈSE NON CONFIRMÉE" "$RESULTS"  # → true (gate marker present)
grep -q "SOUFFLEUSE_PROMPT_BUILDER" Sources/Souffleuse/PredictorViewModel.swift  # → ✓ flag preserved
grep -q "private enum PromptBuilderFlag" Sources/Souffleuse/PredictorViewModel.swift  # → ✓ enum preserved
grep -q "let basePromptText" Sources/Souffleuse/PredictorViewModel.swift  # → ✓ legacy preserved
```
Tous les gates de la branche négative passent — legacy path correctement préservé,
aucune modification de `PredictorViewModel.swift` ni d'autre fichier source.

**Post-checkpoint verify:**
- `swift build` exit 0 ✓
- `bash audit.sh` exit 0 (6/6 checks) ✓
- `swift test` exit 0 — **104/104 tests verts** (94 existants + 10 PromptBuilderTests) ✓ → TEST-01

## Decision rationale

### Pourquoi pas le cleanup malgré l'infra solide ?

Trois raisons convergent :

1. **Le contextPrefix actuel ne fait pas la différence en daily-use.** Les screenshots
   production legacy montrent des ghosts pertinents (`"vers vous"`, `"le problème que"`,
   word-completions parfaites). Le PromptBuilder + contextPrefix WITH-context ne livre
   pas de gain observable sur ces cas. Faire le cleanup maintenant retirerait un path
   qui fonctionne pour le remplacer par un path qui n'a pas démontré sa supériorité.

2. **Le builder est conçu pour des slots qui n'existent pas encore.** Le mandat structurel
   du PromptBuilder (per-slot budgets, eviction policy, slot extension safe) anticipe
   l'arrivée d'`afterCursor`, `fieldContext`, `previousUserInputs` (Phase 2) puis
   `clipboardContext`, `screenContext` (Phase 3). Ces slots-là apporteront du signal
   réellement différentiel. Faire le cleanup maintenant verrouillerait l'architecture
   AVANT que les bénéfices ne soient mesurables.

3. **Le coût du dual-path est faible.** Le feature flag `SOUFFLEUSE_PROMPT_BUILDER=1` reste
   un env var dev-only, le legacy path coexiste sans impact runtime user. Le code dupliqué
   est documenté et révertible via git. Phase 2 peut itérer sur le builder sans toucher au
   production behavior — meilleur de l'arrangement A/B-testable.

### Le verdict est-il un échec ?

**Non.** L'objectif des requirements AUDIT-01 + AUDIT-02 était de **DÉCIDER explicitement** sur
l'hypothèse fondatrice avant d'investir Phase 2. La décision a été prise sur évidence
empirique (12 scénarios + 20 screenshots daily-use). C'est exactement le rôle du milestone
"first invalidation cheap, second invalidation cheaper" prôné par les success criteria du
projet.

L'infrastructure construite (5 fichiers `SouffleusePrompt`, `MLXTokenCounter`, 10 tests
snapshot/eviction/never-mid-word, harness `--replay` réutilisable, scénarios JSON checked-in)
**reste 100% disponible** pour Phase 2 et au-delà. Aucun code à jeter.

## Implications ROADMAP

- **Phase 1 → `[x]` complete.** Infrastructure livrée, hypothèse explicitement testée et
  verdict documenté. AUDIT-01 + AUDIT-02 satisfaits (verdict explicite, pas verdict positif).
- **Phase 2 non-bloquée.** Le builder est prêt à recevoir les nouveaux slots high-signal.
  Le mandat est clarifié : le `contextPrefix` actuel n'est pas suffisant, Phase 2 doit
  injecter du signal réellement différentiel (AX-driven : afterCursor, fieldContext, et le
  few-shot Jaccard sur l'API builder).
- **Cleanup feature flag → différé à fin Phase 2** (ou Phase 3) sous condition d'un verdict
  eyeball post-Phase-2 montrant un gain observable daily-use. Si Phase 2 ne livre toujours
  pas de gain observable, le milestone devra être pivoté (modèle instruct, system prompt
  re-designed, etc.) avant Phase 3.

## Artefacts produits durant Phase 1 (récap full milestone)

### Code source (production)
- `Souffleuse/Sources/SouffleusePrompt/` — nouveau target SPM (5 fichiers Swift, ~600 LOC total)
  - `PromptSlot.swift` — enum slots (5 actifs Phase 1 + 5 réservés Phase 2/3)
  - `PromptBudget.swift` — `phase1Default` (system=80, ci=40, ctx=150, fewShot=80, beforeCursor=200, global=512)
  - `BuiltPrompt.swift` — résultat Sendable avec `text`, `totalTokens`, `slotTexts: [PromptSlot: String]`
  - `TokenCounting.swift` — protocol `-ing` (production: `MLXTokenCounter`, tests: `WordCountTokenCounter` mock)
  - `PromptBuilder.swift` — value-type Sendable, assemblage déterministe + eviction sentence-then-word
- `Souffleuse/Sources/Souffleuse/MLXTokenCounter.swift` (89 LOC) — adapter tokenizer MLX
- `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` (+111 / -10) — feature-flagged integration
- `Souffleuse/Sources/SouffleuseCoherence/main.swift` (281→515 LOC) — `--replay` sub-command
- `Souffleuse/Package.swift` — wire `SouffleusePrompt` (lib target + dep app/test/coherence)
- `Souffleuse/audit.sh` — `Sources/SouffleusePrompt` ajouté à SHIPPING_DIRS

### Tests
- `Souffleuse/Tests/SouffleuseTests/PromptBuilderTests.swift` (285 LOC) — 10 `@Test` Swift Testing
  - Déterminisme, eviction sentence-then-word, never-mid-word invariant, per-slot independent budget,
    global cap eviction priority, slot order, BUILDER-02 (per-slot budgets), reserved slots empty
- **Total: 104/104 tests verts** (94 baseline + 10 nouveaux, zéro régression)

### Artefacts planning (`.planning/phases/01-foundation-hypothesis-validation/`)
- `01-CONTEXT.md` — 13 locked decisions (D-01..D-13) capturées avant planning
- `01-RESEARCH.md` — 12 sections technique (API, tokenizer, eviction, budgets, integration,
  replay, schema, tests, SPM, audit, risks, OQ all RESOLVED)
- `01-PATTERNS.md` — 13 fichiers mappés à analogs existants
- `01-01-PLAN.md` à `01-05-PLAN.md` — 5 plans en 4 waves
- `01-01-SUMMARY.md` à `01-05-SUMMARY.md` — 5 summaries (chaîne d'audit complète)
- `replay-scenarios.json` — 12 scénarios curated (v1 schema)
- `REPLAY-RESULTS.md` — verdict eyeball signé + tally + lecture nuancée

### Commits (Phase 1 entière, par ordre)
- `028ff00` feat(01-01): add SouffleusePrompt module skeleton
- `1f96796` feat(01-01): wire SouffleusePrompt target in Package.swift
- `e0234b3` chore(01-01): extend audit.sh SHIPPING_DIRS
- `221b420` docs(01-01): complete plan
- `20eb9e8` chore: merge executor worktree (wave 1)
- `e8631db` chore(01-01): commit SouffleuseCoherence + wire SouffleusePrompt dep [orchestrator fix]
- `b271dbb` test(01-02): add PromptBuilder isolation suite (10 @Test)
- `5c3646d` docs(01-02): complete plan
- `4ca9198` chore: merge executor worktree (wave 2: 01-02)
- `a3c3a8c` feat(01-03): add MLXTokenCounter adapter
- `dab3c26` feat(01-03): wire PromptBuilder into predict() behind flag
- `99e59d2` docs(01-03): complete plan
- `ed8b021` chore: merge executor worktree (wave 2: 01-03)
- `80f242b` chore(01-04): seed replay-scenarios.json (12 scenarios)
- `d4ce39b` feat(01-04): add --replay sub-command
- `5e25390` docs(01-04): complete plan
- `3ef4ce6` chore: merge executor worktree (wave 3: 01-04)
- _(this commit)_ docs(01-05): fill REPLAY-RESULTS.md + complete plan

## Key learnings (à promouvoir vers LEARNINGS.md)

1. **L'hypothèse "ghost junk = prompt pauvre" est plus subtile que prédit.** Vrai pour
   empty-field (attracteur HTML), faux pour mid-typing (production legacy gère déjà bien).
   Reformulation pour Phase 2 : "le ghost junk vient de l'absence de signal différentiel —
   le userTail est souvent un signal suffisant, le contextPrefix actuel ne l'enrichit pas
   utilement".

2. **Le PT model 1B-8bit ne traduit pas du contexte FR en sortie FR.** Bascule en EN sur
   3 scénarios sur 4 où le contexte aide à éviter le junk. Suggère qu'un modèle instruct
   pourrait être nécessaire pour exploiter pleinement les slots Phase 2/3.

3. **Le replay harness vaut plus que le verdict.** Les 12 scénarios + le `--replay` + le
   markdown side-by-side sont un asset permanent pour tester chaque ajout de slot Phase 2/3.
   Régénérer le markdown sur n'importe quelle branche/commit prend ~1 min.

4. **Worktree merge protocol nécessite un stash WIP préalable.** L'orchestrator a buté
   sur le WIP `SouffleuseCoherence` non-committé lors du merge Wave 1, perdu temporairement
   les commits dangling, recovered via reflog. Pré-requis à formaliser pour `/gsd-execute-phase`
   sur projets avec WIP existant : auto-stash + auto-pop autour de chaque merge.
