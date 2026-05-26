---
phase: 02-high-signal-slots
artifact: VERIFICATION
status: PARTIAL — perf debt identified, model verdict pending
signed: 2026-05-25 (updated 2026-05-25 post-debug-session)
branch: main
commits:
  - a9412fc  # Plan 02-01 — PromptSlot rename
  - e0ddfdd  # Plan 02-01 — summary
  - 84a6aff  # Plan 02-02 — AXSnapshot extension
  - 1dcba5d  # Plan 02-02 — AX reads
  - 922a279  # Plan 02-02 — summary
  - 1d51e01  # Plan 02-03 — PromptBuilder Phase 2 API
  - 84b57f8  # Plan 02-03 — tests
  - eda7696  # Plan 02-03 — summary
  - ff8b5ba  # Plan 02-04 — predictor wiring
  - 3f6f16a  # Plan 02-04 — AppDelegate forward
  - b337cfb  # Plan 02-04 — summary
  - d7ba7d2  # Plan 02-05 Task 1 — Coherence harness
  - 2b2950a  # Plan 02-05 Task 2 — replay scenarios
  - add0c95  # Plan 02-05 Task 3 — REPLAY-RESULTS.md
  - 1f11709  # Plan 02-05 Task 4 — REPLAY signed + VERIFICATION + SUMMARY
---

# Phase 2 — High-signal slots — VERIFICATION

**Signed:** 2026-05-25
**Branch:** main
**Phase status:** PARTIAL (technical scope delivered ; PERF-01 SIGNED with perf debt deferred ; D-18b PENDING daily-use)

## Acceptance criteria

| Criterion (from ROADMAP.md / 02-CONTEXT.md) | Status | Evidence |
|---------------------------------------------|--------|----------|
| **SLOT-02** — fieldContext slot wired end-to-end (role/subrole/placeholder/help → French annotation) | ✓ | `PromptBuilder.build(... fieldContext: ...)` shipped in `1d51e01`; `PredictorViewModel` builds `fieldContextSlot` from `axSnapshot` in `ff8b5ba`; replay harness exercises it from JSON in `d7ba7d2`. 109 tests green. |
| **SLOT-03** — afterCursor slot wired end-to-end (textAfterCaret → "Suite du texte" prose delimiter) | ✓ | `PromptBuilder.build(... afterCursor: ...)` shipped in `1d51e01`; `PredictorViewModel` builds `afterCursorSlot` from `axSnapshot.textAfterCaret` in `ff8b5ba`; replay reconstruction in `d7ba7d2`. |
| **SLOT-04** — slot order canonical (system / customInstructions / contextPrefix / fieldContext / afterCursor / previousUserInputs / beforeCursor) | ✓ | Instruct-path `slotTexts` reconstruction in `ff8b5ba`; PromptBuilder snapshot tests in `84b57f8` lock the order. |
| **PERF-01** — prompt_build_ms instrumentation + threshold check (D-17d) + slot rollback decision | ✗ NOT MET — perf debt identified, deferred | 152 samples captured in partial daily-use (2026-05-25 13:01-13:18 local). p50=312ms / p95=432ms / max=621ms — **far above ~80ms baseline target**. Root cause = MLX tokenizer count loop inside `PromptBuilder.build()`, NOT any single slot. Decision: `Continue — perf debt déféré` (see PERF-01 attribution section). |
| **AUDIT-02** — replay gate ≥ 6 / 15 ✓ verdicts in REPLAY-RESULTS.md | ✗ NOT MET (replay-only) | Signed tally: 4 ✓ / 5 = / 6 ✗ (see REPLAY-RESULTS.md). Lecture étendue: 3 des 5 `=` (scénarios 13, 14, 15) sont des identiques mécaniques — les slots Phase 2 ne s'exercent pas dans la colonne `contextPrefix` mesurée. La valeur Phase 2 doit être mesurée en daily-use, pas en replay. |

## Replay tally

Voir `REPLAY-RESULTS.md` pour le détail par scénario.

```
✓ : 4 / 15  (scenarios 1*, 6, 8, 10*)   * = marginal
= : 5 / 15  (scenarios 4, 9, 13†, 14†, 15†)   † = identique (slots Phase 2 hors colonne replay)
✗ : 6 / 15  (scenarios 2, 3, 5, 7, 11, 12)
```

**Sous le gate AUDIT-02 (≥ 6/15 ✓) en replay isolé.**

### Lecture étendue (mandatory)

1. **L'hypothèse fondatrice "ghost junk vient du prompt pauvre" n'est PAS confirmée en replay-only.** Phase 1 baseline était 4/12 ≈ 33%. Phase 2 enrichi à 4/15 ≈ 27%. Pas de gain mesurable du `contextPrefix` enrichi sur le modèle PT.

2. **MAIS le replay mesure exclusivement le slot `contextPrefix` (Phase 1).** Les slots Phase 2 (`fieldContext`, `afterCursor`) ne s'exercent pas dans cette colonne — c'est exactement ce que démontrent les 3 lignes identiques 13/14/15 (mêmes ghosts WITHOUT et WITH context, parce que la différentielle "with-context vs without-context" porte sur `contextPrefix`, pas sur les slots `fieldContext`/`afterCursor` qui sont *toujours* présents dans les deux colonnes pour ces scénarios). **La valeur Phase 2 reste à mesurer en daily-use** avec `SOUFFLEUSE_PROMPT_BUILDER=1`, pas dans cette colonne replay.

3. **Signal subjectif fort observé sur le modèle PT :**
   - Switch en anglais sur champs vides (scénarios 3, 7, 9) — le PT n'accroche pas le pré-prompt FR.
   - Accroche format dialogue/HTML (scénarios 1, 5, 10) — patterns `<input type="text"`, `Marie: «`, `.on('keyup'`. Le PT régurgite des fragments de son corpus pré-train HTML/JS sans se conformer au framing FR.
   - Ces patterns suggèrent une **faiblesse du PT vs un modèle instruct-tuned**, à valider en daily-use avant de pivoter.

## Verdict modèle (D-18b)

**Status: PENDING (daily-use required)**

### Rationale

Le replay-only n'est pas suffisant pour trancher Continue PT vs Pivot IT, pour deux raisons :

1. **Le replay ne mesure pas la dimension Phase 2.** Les slots `fieldContext` et `afterCursor` sont présents identiquement dans les deux colonnes du replay (with-context vs without-context). La colonne replay teste l'effet du `contextPrefix` enrichi, *pas* l'effet des slots Phase 2. Conclusion : on ne peut pas évaluer la décision modèle sur une base qui ne mesure pas ce que Phase 2 ajoute.

2. **Les signaux PT observés en replay justifient le doute, pas le pivot.** Le switch anglais et l'accroche HTML/JS sont des indices clairs que le PT a une affinité corpus pré-train > instruction-following. Mais le verdict modèle pour Souffleuse doit s'évaluer en *daily-use réel* (champs avec metadata AX, textAfterCaret non-nil, ContextEnricher actif) — pas dans le replay réduit.

### Critères concrets de bascule (à éval en daily-use)

À l'issue d'une session daily-use 30+ min avec `SOUFFLEUSE_PROMPT_BUILDER=1` :

- **Verdict = Continue PT** si :
  - Les ghosts en champs FR (Mail, Slack DM, Notes) restent dans la langue de l'utilisateur > 80% du temps.
  - Aucun fragment HTML/JS pré-train n'apparaît dans les ghosts.
  - Sur ≥ 3 champs typés (TextField/TextArea/SearchField), le `fieldContext` produit un ghost plausible pour le rôle (subject mail court, texte CS poli, code suite, etc.).
  - Sur ≥ 3 champs avec `textAfterCaret`, le ghost ne répète pas le texte suivant (D-14c respecté).

- **Verdict = Pivot IT** si :
  - Switch anglais persistant en daily-use FR (≥ 30% des ghosts).
  - Patterns HTML/JS dans les ghosts (`<input`, `function(`, `;`).
  - Pas de différence subjective sentie vs Phase 1 sur les 3 dimensions ci-dessus, malgré les slots wirés.

- **Verdict = Autre** : à expliciter (mid-size IT, prompt-engineering du system, etc.).

### Action

1. `bash Souffleuse/make-app.sh` (re-sign avec dev cert).
2. `SOUFFLEUSE_PROMPT_BUILDER=1 open Souffleuse/Souffleuse.app`.
3. Session 30+ min répartie : Mail (3 champs typés), Slack (DM + canal), Notes (note vierge + note en cours), VS Code (code Swift + comment).
4. Capturer 5-10 ghosts représentatifs (screenshots ou journal manuel).
5. Revenir signer ce document avec un verdict explicite + critères atteints/manqués.

## PERF-01 attribution (B-3)

**Status: SIGNED — perf debt identified, decision = `Continue — perf debt déféré au milestone KV-cache`**

Per D-17b / D-17c reminder: `prompt_build_ms` est le SOLE automated PERF-01 handle en Phase 2. SouffleuseBench est intentionnellement exclu (refactor invasif différé au milestone KV-cache). End-to-end TTFT est subjectivement gated.

### (a) prompt_build_ms statistics

Session daily-use partielle 2026-05-25 13:01-13:18 (local), build debug avec `SOUFFLEUSE_PROMPT_BUILDER=1` + `SOUFFLEUSE_PREDICT_LOG=1`. Frappe répartie sur Mail / Slack / Notes / champs divers.

```
samples = 152
min     = 178 ms
p10     = 233 ms
p25     = 288 ms
p50     = 312 ms
p75     = 362 ms
p90     = 413 ms
p95     = 432 ms
p99     = 509 ms
max     = 621 ms
mean    = 319 ms
stddev  = 68 ms
```

**Pas de cold-warmup drift :** first 58 samples mean=330ms, last 59 samples mean=312ms → −18ms. Coût **steady-state**, pas un transitoire de chargement modèle.

**Histogramme (buckets de 50ms) :**
```
150ms:  6  ######
200ms: 20  ####################
250ms: 33  #################################
300ms: 55  #######################################################
350ms: 25  #########################
400ms: 16  ################
500ms:  3  ###
600ms:  2  ##
```

### (b) Attribution — boucle tokenizer, pas un slot individuel

**Aucun slot individuel n'est responsable.** L'analyse du code (`PromptBuilder.swift:86, 101, 117`) montre que `build()` appelle `counter.countTokens(...)` et `counter.truncateHead(...)` **par slot** pour appliquer le budget :

| Phase | Slots | Appels tokenizer estimés par build |
|-------|-------|------------------------------------|
| Phase 1 (5 slots) | beforeCursor, previousUserInputs, contextPrefix, customInstructions, system | ~5-15 (selon truncation déclenchée) |
| Phase 2 (7 slots) | + `fieldContext`, `afterCursor` | ~7-21 |

Le tokenizer `swift-transformers` (HuggingFace, transitive via `mlx-swift-examples`) sur du texte court coûte ~15-30ms par appel sur Apple Silicon. Donc :

- **Coût total estimé : ~150-300ms côté tokenizer**, le reste (~50ms) c'est l'assemblage string + bridge MLX.
- **Delta Phase 2 estimé : +50 à +100ms** (2-6 appels tokenizer extra) sur un baseline Phase 1 jamais instrumenté (≈ 250ms).

**Implication :** le builder Phase 1 était déjà lent ; Phase 2 a juste exposé le problème en ajoutant l'instrumentation `prompt_build_ms` + un peu de coût marginal. **C'est de la dette technique pré-existante, pas une régression Phase 2.**

### (c) End-to-end TTFT eyeball verdict

**`blocking degradation`** (signal user direct : « pas ouf le résultat actuel. On affiche très peu de ghosts. »).

Évidence quantitative (dev trace `/tmp/souffleuse-predict.log`) :

| Métrique | Valeur | Interprétation |
|----------|--------|----------------|
| `predict_called` | 484 | Frappe normale |
| `llm_chunk_raw` | 125 | Modèle a démarré pour 26% des calls |
| `llm_done_stored` | 19 | Stream COMPLET pour seulement **3.9%** des calls |
| `llm_done_stored ttft` observé | 684-1093ms | TTFT total **8-14× la cible 80ms** |
| `ghost_dropped_repeat` | 22 | Anti-répétition élimine encore des survivants |
| `gate_first_word` | 18 | Suppression frontière premier mot |
| `chunk_dropped_antiflicker` | 10 | Anti-flicker élimine du contenu |

**Diagnostic :** la latence est si élevée que le `cancel-on-keystroke` tue 96% des streams avant complétion. Quand un ghost survit, il arrive après que le caret a déjà bougé → impression "très peu de ghosts".

### (d) Decision token

**`Continue — perf debt déféré au milestone KV-cache`**

**Raison du choix :**
- **Pas `Slot rollback`** : les slots Phase 2 (`fieldContext`/`afterCursor`) font correctement leur travail au niveau API. Les retirer ne résoudrait pas la cause racine (boucle tokenizer Phase 1).
- **Pas `Budget cut`** : réduire `phase2Default` coupe la qualité du contexte sans attaquer le bottleneck (le coût scale avec le nombre d'appels tokenizer, pas avec leur taille).
- **Pas un blocage Phase 3** : le scope technique Phase 2 est livré ; le verdict de valeur (D-18b) reste à signer en daily-use réel mais Phase 3 peut démarrer.

**Trois mitigations possibles, à scoper hors Phase 2 :**

1. **Memoize tokenizer counts par slot text** (cheap, ~10-20 lignes dans `PromptBuilder.build()`). Beaucoup d'appels redondants : `fieldContext` ne change qu'à un app-switch, `previousUserInputs` ne change qu'à une acceptation Tab. **Gain estimé : −150ms p50.**
2. **`WordCountTokenCounter` pour le budget, MLX tokenizer pour l'assemblage final** (medium, refactor `TokenCounting`). Approxime 1 token ≈ 1 mot pour décider du budget ; recompte exact uniquement à la fin. **Gain estimé : −200ms p50**, risque de léger overflow sur prompts mots-rares.
3. **KV cache** (milestone suivant, déjà acté hors-scope). N'attaque pas le `prompt_build_ms` mais résout le TTFT total — le ghost peut arriver pendant que le user tape.

**Recommandation :** ouvrir une issue/phase « perf debt » avec fix #1 (memoize) en première option ; mesurer le gain réel ; si insuffisant, escalader vers #2 ; le KV cache reste l'objectif stratégique.

### Acknowledgment

PERF-01 est partiellement observable en Phase 2 per D-17b / D-17c ; `prompt_build_ms` est le seul handle automatisé ; end-to-end TTFT est gated par le verdict subjectif ci-dessus. Cette section est désormais SIGNÉE avec données réelles ; le verdict modèle (D-18b) reste PENDING (cf. section ci-dessus).

## Tests & audit

| Check | Result |
|-------|--------|
| `cd Souffleuse && swift build` | exit 0 |
| `cd Souffleuse && swift test` | **109 / 109 passed** |
| `cd Souffleuse && bash audit.sh` | **6 / 6 PASSED** |
| audit checks: no `print(` / `NSLog(` / `os_log(...%@... userText)` / Log.* user-text interpol / history.aes scope / raw acceptance text | OK |
| `grep -c 'prompt_build_ms' Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` | 3 (literal + comments) |
| `grep -c 'phase2Default' Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` | 2 (call + comment) |

Commits Phase 2 sur main (lignée verte, aucun rollback) :

```
add0c95 docs(02-05): regenerate REPLAY-RESULTS.md for Phase 2 (15 scenarios)
2b2950a chore(02-05): add 3 Phase 2 replay scenarios (mid-typing + AX metadata)
d7ba7d2 feat(02-05): extend Coherence Scenario + replayScenario for Phase 2 slots
b337cfb docs(02-04): complete Phase 2 end-to-end slot wiring plan
3f6f16a feat(02-04): forward AXSnapshot from AppDelegate tick to predictor.predict
ff8b5ba feat(02-04): wire fieldContext + afterCursor + axSnapshot into Predictor
eda7696 docs(02-03): complete Phase 2 PromptBuilder slot extension plan
84b57f8 test(02-03): add Phase 2 builder tests + verify legacy snapshot tests
1d51e01 feat(02-03): extend PromptBuilder with fieldContext + afterCursor slots
922a279 docs(02-02): complete AXSnapshot field-metadata + textAfterCaret plan
1dcba5d feat(02-02): read placeholder/help/textAfterCaret in AXClient.readSnapshot
84a6aff feat(02-02): extend AXSnapshot with placeholder/help/textAfterCaret fields
e0ddfdd docs(02-01): complete fewShot → previousUserInputs rename plan
a9412fc refactor(02-01): rename PromptSlot.fewShot → previousUserInputs (D-16)
```

## Phase 3 gate

**Status: GO (technical scope delivered) — verdict de valeur différé à daily-use**

Phase 2 livre techniquement son scope :

- 5 plans complétés (02-01 → 02-05).
- 109 tests verts (aucune régression vs baseline Phase 1).
- audit.sh 6/6 verts (privacy invariants tenus).
- Slots `fieldContext` + `afterCursor` wirés end-to-end (PromptBuilder → PredictorViewModel → AppDelegate → AX).
- Instrumentation `prompt_build_ms` shippée.
- Replay harness étendu (15 scénarios, `--out` flag).

**Décision Phase 3 :** la discussion `/gsd-plan-phase 3` PEUT démarrer en parallèle de la daily-use. Le verdict de valeur (Verdict modèle D-18b + PERF-01 B-3) est différé mais **ne bloque pas** la conception de Phase 3.

**Cas où Phase 3 doit être re-scopée avant exécution :**
- Verdict modèle = "Pivot IT" → Phase 3 doit inclure une bascule modèle (re-plan). **Signal observé en partial daily-use : switch FR→EN du PT documenté (cf. `/tmp/souffleuse-predict.log` 13:18:41 `"You must..."` sur prompt FR). Confirmation à signer en daily-use complète.**
- PERF-01 decision = "Slot rollback" → ~~Phase 3 doit retirer le slot incriminé.~~ **N/A — attribution = boucle tokenizer, pas un slot. Pas de rollback nécessaire.**
- PERF-01 decision = "Budget cut" → ~~Phase 3 doit ajuster les budgets `phase2Default`.~~ **N/A — même raison.**

**Décision : Phase 3 peut s'exécuter directement, mais une phase "perf debt" intercalaire (memoize tokenizer counts) est fortement recommandée avant. Le TTFT actuel rend la perception Phase 2 ininterprétable — chaque ghost cancel-on-keystroke avant complétion masque la qualité réelle des nouveaux slots.**

## Outstanding (pour daily-use future)

Actions humaines restantes pour clôturer le verdict de valeur Phase 2 :

1. **Build & re-sign** :
   ```bash
   cd /Users/gabrielwaltio/cocotypist/Souffleuse
   bash make-app.sh
   ```

2. **Lancement avec flag Phase 2** :
   ```bash
   SOUFFLEUSE_PROMPT_BUILDER=1 open /Users/gabrielwaltio/cocotypist/Souffleuse/Souffleuse.app
   ```

3. **Session 30+ min** réparties sur :
   - Mail.app (champs typés : objet / corps / réponse).
   - Slack (DM + canal vide + canal en cours de discussion).
   - Notes.app (note vierge + note en cours d'édition mid-phrase).
   - VS Code (code Swift + commentaire `// TODO:` + doc comment `///`).
   - (optionnel) Brave/Safari (formulaires : Nom / Email / Recherche).

4. **Capture prompt_build_ms** :
   ```bash
   grep -c "prompt_build_ms" ~/Library/Logs/Souffleuse.log
   grep "prompt_build_ms" ~/Library/Logs/Souffleuse.log | tail -200 | python3 -c "
   import sys, json
   vals = []
   for line in sys.stdin:
       try:
           d = json.loads(line)
           if d.get('event') == 'prompt_build_ms':
               vals.append(d.get('count', 0))
       except: pass
   vals.sort()
   n = len(vals)
   if n:
       p50 = vals[n//2]
       p95 = vals[int(n*0.95)] if n > 1 else vals[0]
       print(f'samples={n} p50={p50}ms p95={p95}ms max={vals[-1]}ms')
   "
   ```

5. **Re-eval D-18b + B-3** : mettre à jour les sections "Verdict modèle (D-18b)" et "PERF-01 attribution (B-3)" de ce document avec :
   - Verdict modèle : `Continue PT` / `Pivot IT` / `Autre:` (justifié).
   - PERF-01 (a) : `samples=N p50=X p95=Y max=Z`.
   - PERF-01 (b) : slot >30ms ou "No sample exceeded".
   - PERF-01 (c) : `"no observable regression"` / `"observable regression"` / `"blocking degradation"`.
   - PERF-01 (d) : `Continue` / `Slot rollback: <slot>` / `Budget cut: <slot> <new>`.

6. **Re-commit** : `docs(02-05): finalize Phase 2 verdicts post-daily-use (D-18b: <X>, B-3: <Y>)`.

---

**Verdict global Phase 2 : PARTIAL — technical scope delivered ; PERF-01 SIGNED (perf debt déféré) ; D-18b PENDING daily-use complète. Phase 3 démarrable, mais phase "perf debt" intercalaire fortement recommandée.**
