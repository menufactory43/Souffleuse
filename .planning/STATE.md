---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: milestone
status: Phase 04 complete
last_updated: "2026-05-26T09:25:57.518Z"
progress:
  total_phases: 4
  completed_phases: 3
  total_plans: 26
  completed_plans: 24
  percent: 92
---

# Project State: Cocotypist / Souffleuse

**Last updated:** 2026-05-24

---

## Project Reference

**Project:** Cocotypist / Souffleuse — assistant de frappe local-LLM pour macOS (menu-bar accessory, MLX, Gemma 3 1B). Ghost text au caret via API d'accessibilité, accept (Tab) / dismiss (Esc), 100% on-device.

**Core Value:** Le ghost doit *sembler* aussi instantané et pertinent que Cotypist en usage quotidien. Qualité contextuelle prime sur vitesse brute.

**Current Milestone:** Context Builder token-aware

**Current Focus:** Phase 04 — cascade-quality-architecture

---

## Current Position

Phase: 04 — COMPLETE
Plan: 1 of 9
| Field | Value |
|-------|-------|
| Milestone | Context Builder token-aware |
| Phase | 3 — Perf debt: KV cache MLX |
| Plan | None (awaiting `/gsd-plan-phase 3`) |
| Status | Phase 02 livrée (5 plans, 109 tests verts) + 8 commits perf/bugfix session 2026-05-25. Phase 3 CONTEXT.md prêt avec discovery technique. |
| Progress | Phase 2/4 complete · phase intercalaire 03 insérée (KV cache) |

**Progress bar:**

```
[██████████░░░░░░░░░░] 50% (2/4 phases — perf-kv-cache insérée comme phase 03)
```

**Next command:** `/gsd-plan-phase 3` — produira 5 plans (1 par étape de `.planning/kv-cache-discovery.md` §"Plan d'implémentation par étapes").

---

## Performance Metrics

**Baseline (commit `6ad70df`, 2026-05-24):**

- TTFT cible : ~80ms après dernier keystroke en flow typique (non-cold-start)
- 94 tests verts
- `audit.sh` 6 checks ✓

**Post-Phase 02 + debug session (2026-05-25):**

- 109 tests verts (5 nouveaux Phase 2)
- `audit.sh` 6/6 ✓
- `prompt_build_ms` p50: 312ms → 47ms (commit `e56fdd2` — memoize)
- `ghost_dropped_repeat` rate: 87% → 1.1% (commit `5a843b0` — `.hasSuffix` fix)
- TTFT total mesuré: **544-1056ms** (Phase 03 cible: 120-200ms via KV cache)
- Stream completion rate: 5.8% (Phase 03 cible: ≥ 30%)

**Metrics to track during Phase 03 (KV cache):**

- TTFT p50/p95 avant vs après — bench replay 15 scénarios
- Stream completion rate `llm_done_stored / predict_called`
- Memory growth GPU (cumul du KV cache cross-keystroke)
- Regression check sur les 15 scénarios — outputs DOIVENT être identiques (KV cache est une optim, pas un changement sémantique)
- Verdict subjectif side-by-side vs Cotypist sur 5-10 scénarios (différé à Phase 4 — mais devient mesurable une fois KV cache en place)

---

## Accumulated Context

### Key Decisions (reportées de PROJECT.md)

| Decision | Rationale |
|----------|-----------|
| Milestone = Context Builder, pas Inference Infra | Hypothèse user : ghost junk vient du prompt pauvre. KV cache reporté. |
| Budget par token, pas par char | Sentencepiece fragmente les mots. Truncate char (512) imprécis. |
| Critère de parité = subjectif + soft latency | Side-by-side daily-use vs Cotypist + envelope ~80ms TTFT. |
| 6 slots dans l'ordre user-priority | beforeCursor → afterCursor → fieldContext → previousInputs → clipboard opt-in → OCR conditional |
| Audit léger en Phase 1 (pas phase dédiée) | Mode replay embarqué dans le builder Phase 1. Économise une phase d'instrumentation pure. |
| Migration strategy déférée au plan-phase 1 | Feature flag vs in-place refactor — dépend de l'invasivité. |

### Open TODOs

- [ ] Lancer `/gsd-plan-phase 1` pour décomposer Phase 1 en plans exécutables
- [ ] Décider la migration strategy (feature flag vs in-place) au plan-phase 1
- [ ] Définir précisément les 10-20 scénarios scriptés pour le mode replay (Phase 1)

### Blockers

Aucun.

### Notes

- Brownfield codebase, mappé le 2026-05-24 (`.planning/codebase/*.md`)
- Assets existants à réutiliser (NE PAS reconstruire) : `ContextEnricher`, `AppContextProbe`, `ClipboardReader`, `ScreenCapturer + VisionOCR`, `SimilarHistoryRetrieval`
- Asset à refactor : `PredictorViewModel.predict()` lignes 478-513 (prompt concat inlined)
- Slots à construire from scratch : `afterCursor` capture AX, `fieldContext` AX metadata (au-delà de app/window), budget token-aware

---

## Session Continuity

**Last session ended:** 2026-05-24 — Roadmap créé après définition de PROJECT.md et REQUIREMENTS.md. 18 v1 requirements mappés sur 3 phases (granularity=coarse).

**Next session should:**

1. Lancer `/gsd-plan-phase 1` pour planifier la Phase 1 (Foundation + Hypothesis Validation)
2. Trancher la migration strategy (feature flag vs in-place) durant le planning
3. Lister les 10-20 scénarios scriptés cibles du mode replay

**Files of interest:**

- `.planning/PROJECT.md` — vision, core value, key decisions, constraints
- `.planning/REQUIREMENTS.md` — 18 v1 requirements avec traceability mappée
- `.planning/ROADMAP.md` — 3 phases, success criteria, coverage
- `.planning/codebase/ARCHITECTURE.md` — modular monolith, SouffleuseContext déjà en place
- `.planning/codebase/STRUCTURE.md` — file layout par target SPM
- `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` — site du refactor PromptBuilder
- `Souffleuse/Sources/SouffleuseContext/ContextEnricher.swift` — flat-string actuel à structurer

---

*State initialized: 2026-05-24*
