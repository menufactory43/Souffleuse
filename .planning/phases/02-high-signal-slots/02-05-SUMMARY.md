---
phase: 02-high-signal-slots
plan: 05
subsystem: SouffleuseCoherence (replay harness) + Phase 2 verification artefacts
tags: [replay-harness, scenarios, verification, phase2-gate, perf-01, verdict-modele]
requires:
  - "Plan 02-01: PromptSlot.previousUserInputs rename"
  - "Plan 02-02: AXSnapshot.placeholder/.help/.textAfterCaret"
  - "Plan 02-03: PromptBuilder Phase 2 7-arg build + phase2Default + roleLabelFR (public)"
  - "Plan 02-04: PredictorViewModel + AppDelegate Phase 2 wiring + prompt_build_ms instrumentation"
provides:
  - "SouffleuseCoherence Scenario schema extended with 5 optional Phase 2 fields (role, subrole, placeholder, help, textAfterCaret) — additive, v1 scenarios decode unchanged"
  - "SouffleuseCoherence.replayScenario(...) reconstructs fieldContext + afterCursor slot bodies from JSON fields and routes to PromptBuilder with phase2Default budget"
  - "SouffleuseCoherence.runReplay(...) gains optional --out <path> flag (B-2) — Phase 2 REPLAY-RESULTS.md does NOT overwrite Phase 1's colocated record"
  - "replay-scenarios.json: 3 new mid-typing scenarios (13/14/15) with AX metadata + textAfterCaret"
  - "REPLAY-RESULTS.md regenerated at .planning/phases/02-high-signal-slots/REPLAY-RESULTS.md with signed eyeball tally 4✓/5=/6✗"
  - "02-VERIFICATION.md with mandatory Verdict modèle (D-18b) and PERF-01 attribution (B-3) sections — both PENDING daily-use"
affects:
  - "Phase 3 planning: GO (technical scope delivered) — value verdict deferred but does NOT block Phase 3 design discussion"
  - "Future daily-use session will finalize Verdict modèle + PERF-01 decision tokens"
tech-stack:
  added: []
  patterns:
    - "Additive optional fields in Codable scenarios — version=1 preserved, v1 JSON decodes unchanged"
    - "CLI `--out <path>` flag with legacy colocated default fallback — eliminates execution-time ambiguity (B-2)"
    - "Verdict artefact pattern: explicit decision tokens (Continue PT / Pivot IT / Autre) + (Continue / Slot rollback / Budget cut) — converts silent miss into traceable decision (D-18b, B-3)"
key-files:
  created:
    - ".planning/phases/02-high-signal-slots/02-VERIFICATION.md"
    - ".planning/phases/02-high-signal-slots/02-05-SUMMARY.md"
  modified:
    - "Souffleuse/Sources/SouffleuseCoherence/main.swift"
    - ".planning/phases/01-foundation-hypothesis-validation/replay-scenarios.json"
    - ".planning/phases/02-high-signal-slots/REPLAY-RESULTS.md"
decisions:
  - "Verdict modèle D-18b = PENDING (daily-use required). Le replay-only mesure exclusivement le slot contextPrefix; les slots Phase 2 (fieldContext, afterCursor) ne s'exercent pas dans la colonne replay (scénarios 13/14/15 identiques le démontrent). Trancher Continue PT vs Pivot IT exige une session daily-use."
  - "PERF-01 attribution B-3 = PENDING. Zéro sample prompt_build_ms dans ~/Library/Logs/Souffleuse.log — instrumentation shippée mais build daily-use pas encore exécuté. Decision token déféré post-daily-use."
  - "AUDIT-02 gate (≥ 6/15 ✓) NON ATTEINT en replay isolé (4/15 ✓). Décision : ne pas bloquer Phase 3 sur cette mesure car le replay ne mesure pas ce que Phase 2 ajoute. Lecture étendue documentée dans 02-VERIFICATION.md §Replay tally."
  - "Phase 3 gate = GO (technical scope delivered). La discussion /gsd-plan-phase 3 peut démarrer en parallèle de la daily-use; re-scope déclenché uniquement si Verdict modèle = Pivot IT/Autre OU PERF-01 decision ∈ {Slot rollback, Budget cut}."
  - "Signaux PT observés en replay (switch anglais sur champs vides; fragments HTML/JS pré-train) justifient le doute modèle, pas le pivot. Validation en daily-use requise avant de basculer IT."
metrics:
  duration: "≈ 2h wall-clock (Tasks 1-3 ≈ 1h auto + Task 4 finalize ≈ 1h post-eyeball)"
  completed: "2026-05-25"
  tests_before: 109
  tests_after: 109
  new_tests: 0
status: "complete (with PENDING daily-use verdict)"
---

# Phase 2 Plan 05: Close Phase 2 with Empirical Validation — Summary

One-liner: extension de la harness `SouffleuseCoherence` pour exercer les slots Phase 2 (`fieldContext` + `afterCursor`) sur 15 scénarios (12 baseline Phase 1 + 3 mid-typing nouveaux), génération signée de `REPLAY-RESULTS.md` (4 ✓ / 5 = / 6 ✗ — sous le gate AUDIT-02 en replay-only), et `02-VERIFICATION.md` avec sections obligatoires Verdict modèle (D-18b) et PERF-01 attribution (B-3) statuant explicitement **PENDING (daily-use required)** — Phase 3 gate **GO (technical scope delivered)** mais verdict de valeur différé.

## What Changed

### Task 1 — Coherence harness extension (commit `d7ba7d2`)

`Souffleuse/Sources/SouffleuseCoherence/main.swift` :

- `Scenario` struct étendu avec 5 champs optionnels Phase 2 : `role`, `subrole`, `placeholder`, `help`, `textAfterCaret`. `ScenarioFile.version` reste à 1 (additif sur optionnels).
- `replayScenario(...)` : builder bascule vers `PromptBudget.phase2Default`. Reconstruit `fieldContextSlot` (D-15c FR annotation via `PromptBuilder.roleLabelFR`) et `afterCursorSlot` (D-14 prose-FR delimiter) à partir des champs JSON.
- `runReplay(scenariosPath:outPath:modelId:container:)` gagne un paramètre optionnel `outPath`. Dispatch `main.swift` parse `--out <path>` après le scenarios path. Fallback legacy = colocated-with-scenarios (Phase 1 callers préservés).
- **Single-commit pattern (B-2) :** schema + replayScenario + --out wiring committed ensemble — pas de follow-up flottant.

### Task 2 — Phase 2 replay scenarios (commit `2b2950a`)

`.planning/phases/01-foundation-hypothesis-validation/replay-scenarios.json` :

- 3 nouveaux scénarios ajoutés à la fin du tableau `scenarios`:
  - `13-mid-field-mail-subject` — Mail subject, placeholder + textAfterCaret continuing the sentence.
  - `14-search-field-empty-with-help` — Slack search field, role + subrole + placeholder + help (afterCursor skipped per D-14c).
  - `15-mid-code-comment-textarea` — VS Code mid-`// TODO:` with code following.
- Les 12 scénarios baseline Phase 1 sont byte-identical (T-02-05-02 mitigation respectée).
- `version: 1` préservé.

### Task 3 — REPLAY-RESULTS.md generation (commit `add0c95`)

`.planning/phases/02-high-signal-slots/REPLAY-RESULTS.md` :

- Généré par `SOUFFLEUSE_PROMPT_BUILDER=1 swift run SouffleuseCoherence --replay <p1>/replay-scenarios.json --out <p2>/REPLAY-RESULTS.md` (B-2 single mechanism).
- 15 sections par-scénario WITHOUT/WITH context.
- Eyeball signature ajoutée (Task 4 finalize) : **4 ✓ / 5 = / 6 ✗**.
- Note "Performance notes" : `prompt_build_ms` samples = 0 (pas de daily-use exécutée).
- Note explicite "AUDIT-02 gate (4/15) : NON ATTEINT en replay-only" + renvoi vers 02-VERIFICATION.md pour la lecture étendue.

### Task 4 — Phase 2 verification artefacts (this commit)

`.planning/phases/02-high-signal-slots/02-VERIFICATION.md` créé avec sections obligatoires :

1. **Acceptance criteria** — table SLOT-02/SLOT-03/SLOT-04 (✓), PERF-01 (PARTIAL — PENDING), AUDIT-02 (✗ NOT MET en replay-only avec lecture étendue).
2. **Verdict modèle (D-18b)** = **PENDING (daily-use required)** + rationale (replay ne mesure pas la dimension Phase 2) + critères concrets de bascule Continue PT / Pivot IT / Autre.
3. **PERF-01 attribution (B-3)** = **PENDING** avec 4 sous-parties :
   - (a) stats `prompt_build_ms` = `samples=0`, `p50=N/A`, `p95=N/A`, `max=N/A`, B-3 grep gate = EMPTY.
   - (b) slot >30ms = N/A.
   - (c) end-to-end TTFT eyeball verdict = N/A (no daily-use yet).
   - (d) decision token = PENDING (defer to post-daily-use).
4. **Replay tally** = 4 ✓ / 5 = / 6 ✗ + lecture étendue (slots Phase 2 hors colonne replay).
5. **Tests & audit** = 109/109 + 6/6 + 14 commits Phase 2 listés.
6. **Phase 3 gate** = **GO (technical scope delivered)**, verdict de valeur différé sans bloquer Phase 3 design.
7. **Outstanding (pour daily-use future)** = 6 étapes actionables (build, lancement, session 30+ min, capture stats, re-eval D-18b/B-3, re-commit final).

## Deviations from Plan

### Auto-fixed / signed

**1. [Signed deviation] Verdict modèle (D-18b) statué PENDING au lieu de Continue PT / Pivot IT / Autre**
- **Found during:** Task 4 eyeball signature.
- **Issue:** Le plan demande un verdict explicite, mais le replay isolé ne mesure pas la dimension Phase 2 (3 scénarios identiques le prouvent : 13/14/15). Trancher sur replay-only serait infondé.
- **Resolution:** Verdict signé `PENDING (daily-use required)` avec rationale documentée + critères de bascule + plan d'action.
- **User sign-off:** Oui (gabrielwaltio, 2026-05-25).

**2. [Signed deviation] PERF-01 attribution (B-3) statué PENDING au lieu de Continue / Slot rollback / Budget cut**
- **Found during:** Task 3 / 4.
- **Issue:** Aucun sample `prompt_build_ms` dans `~/Library/Logs/Souffleuse.log` car aucune session daily-use n'a été exécutée avec le build Phase 2.
- **Resolution:** PERF-01 sections (a)-(d) statuées N/A / PENDING avec instructions explicites pour capture post-daily-use.
- **User sign-off:** Oui (gabrielwaltio, 2026-05-25).

**3. [Signed deviation] AUDIT-02 gate NON ATTEINT en replay isolé (4/15 < 6/15)**
- **Found during:** Task 4 eyeball signature.
- **Issue:** Le tally 4/15 ne satisfait pas le gate planner-set ≥ 6/15.
- **Resolution:** Documenté dans REPLAY-RESULTS.md et 02-VERIFICATION.md avec lecture étendue : le replay teste exclusivement la colonne `contextPrefix` (Phase 1) ; les slots Phase 2 ne s'y exercent pas (scénarios 13/14/15 identiques en témoignent). La valeur Phase 2 doit être mesurée en daily-use. Décision : ne pas bloquer Phase 3 design discussion.
- **User sign-off:** Oui (gabrielwaltio, 2026-05-25).

## Verification

| Check | Result |
|-------|--------|
| `cd Souffleuse && swift build` | exit 0 |
| `cd Souffleuse && swift test` | **109 / 109 passed** |
| `cd Souffleuse && bash audit.sh` | **6 / 6 PASSED** |
| `grep -c 'Verdict modèle' .planning/phases/02-high-signal-slots/02-VERIFICATION.md` | 5 |
| `grep -c 'PERF-01 attribution' .planning/phases/02-high-signal-slots/02-VERIFICATION.md` | 3 |
| `grep -cE '(Continue PT\|Pivot IT\|Autre)' .planning/phases/02-high-signal-slots/02-VERIFICATION.md` | 6 |
| `grep -cE '(Continue\|Slot rollback\|Budget cut)' .planning/phases/02-high-signal-slots/02-VERIFICATION.md` | 8 |
| `grep -c 'prompt_build_ms' .planning/phases/02-high-signal-slots/02-VERIFICATION.md` | 13 |
| `grep -cE 'p50\|p95\|max' .planning/phases/02-high-signal-slots/02-VERIFICATION.md` | 8 |
| `grep -cE '(no observable regression\|observable regression\|blocking degradation)' .planning/phases/02-high-signal-slots/02-VERIFICATION.md` | 4 |
| `grep -c 'Phase 3 gate' .planning/phases/02-high-signal-slots/02-VERIFICATION.md` | 1 |
| `grep -c '\[x\] ✓' REPLAY-RESULTS.md` | 4 |
| `grep -c '\[x\] =' REPLAY-RESULTS.md` | 5 |
| `grep -c '\[x\] ✗' REPLAY-RESULTS.md` | 6 |

## Commits

| Task | Hash | Message |
| ---- | ---- | ------- |
| 1 | `d7ba7d2` | feat(02-05): extend Coherence Scenario + replayScenario for Phase 2 slots + --out path (SLOT-02, SLOT-03, B-2) |
| 2 | `2b2950a` | chore(02-05): add 3 Phase 2 replay scenarios (mid-typing + AX metadata) |
| 3 | `add0c95` | docs(02-05): regenerate REPLAY-RESULTS.md for Phase 2 (15 scenarios) |
| 4 | _(this commit)_ | docs(02-05): sign REPLAY-RESULTS.md (4/15 ✓), write 02-VERIFICATION.md (PARTIAL — D-18b/B-3 PENDING daily-use) + 02-05-SUMMARY.md |

## Handoff

Voir `.planning/phases/02-high-signal-slots/02-VERIFICATION.md` pour :
- Le verdict de valeur Phase 2 (PARTIAL — daily-use pending).
- Les critères concrets de bascule Continue PT / Pivot IT.
- Les 6 étapes Outstanding à exécuter en daily-use pour finaliser D-18b + B-3.
- La décision Phase 3 gate (GO technical, value PENDING).

## Self-Check: PASSED

- File `.planning/phases/02-high-signal-slots/REPLAY-RESULTS.md` (modified, signed with 4✓/5=/6✗): FOUND
- File `.planning/phases/02-high-signal-slots/02-VERIFICATION.md` (created): FOUND
- File `.planning/phases/02-high-signal-slots/02-05-SUMMARY.md` (created — this file): FOUND
- Commit `d7ba7d2` (Task 1): FOUND in git log
- Commit `2b2950a` (Task 2): FOUND in git log
- Commit `add0c95` (Task 3): FOUND in git log
- 109/109 tests pass
- audit.sh: 6/6 PASSED
- All mandatory grep gates on 02-VERIFICATION.md returned ≥1 hit (Verdict modèle, PERF-01 attribution, decision tokens, prompt_build_ms, p50/p95/max, TTFT eyeball verdict tokens, Phase 3 gate)
