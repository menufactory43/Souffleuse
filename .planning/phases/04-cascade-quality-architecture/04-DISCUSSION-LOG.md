# Phase 4: Cascade Quality + Architecture - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-05-25
**Phase:** 04-cascade-quality-architecture
**Areas discussed:** Architecture refactor strategy, Ghost Relevance Gate + confidence scoring, Ghost classification grid + metrics, Real-app parity verification

---

## Gray Area Selection

| Option | Description | Selected |
|--------|-------------|----------|
| Architecture refactor strategy | Sequencing of TypingSession extract + PredictorViewModel split, migration approach, module boundaries | ✓ |
| Ghost Relevance Gate + confidence scoring | Unified confidence policy, routing priorities, history exact-match re-enable safety | ✓ |
| Ghost classification grid + metrics | Taxonomy, detection signals, audit-safe capture, release gate | ✓ |
| Real-app parity verification protocol | Matrix of apps, scripted vs daily-use, acceptance criteria | ✓ |

**User's choice:** "recommandé partout" — user delegated all four areas to Claude's recommendation.
**Notes:** User trusted the recommendations as a batch; control point shifted to post-plan review rather than per-question grilling.

---

## Architecture refactor strategy

Bundled recommendation (presented as a single block; user locked all):

| Sub-decision | Alternatives considered | Selected |
|---|---|---|
| Order of split vs extract | (a) TypingSession first then PVM split. (b) PVM split first then TypingSession. (c) Both in parallel branches. | (b) PVM first |
| Migration approach | (a) Feature flag with dual code paths. (b) Branch + big-bang merge. (c) In-place atomic-commit per boundary. | (c) In-place atomic-commit |
| Module boundaries (PVM split) | Variations on how to slice the 1566-LOC PredictorViewModel | ModelRuntime / SuggestionPolicy / CompletionCache / GenerationPlanner (4-way split) |
| Safety net during refactor | (a) Tests-only. (b) Tests + manual smoke. (c) Tests + SouffleuseCoherence --replay equivalence at each commit. | (c) Tests + replay equivalence |

**User's choice:** Locked the recommended set (PVM-first, in-place, 4-way split, replay equivalence).
**Notes:** Same playbook as Phase 3 KV cache rollout — atomic-commit + replay equivalence already proven in this codebase.

---

## Ghost Relevance Gate + confidence scoring

| Sub-decision | Alternatives considered | Selected |
|---|---|---|
| Scoring model | (a) Learned scoring (requires LEARN-* signal capture — out of scope). (b) Heuristic with explicit per-source priors. | (b) Heuristic |
| Score shape | (a) Multi-dimensional vector. (b) Scalar [0,1] = source_prior × prefix_fit × length_fit. | (b) Scalar with 3 components |
| Gate decision | (a) Penalize (score weighting only). (b) Hard block below threshold. (c) Hard block + replacement bar. | (c) Hard block 0.25 + replacement bar 1.15× |
| Routing priorities | (a) Single source wins by score. (b) Mid-word L0 exclusive, after-space L1 then L2-upgrade. (c) L2 always preferred. | (b) Mid-word L0 exclusive, after-space L1→L2 upgrade at +0.15 |
| History exact-match after-space re-enable | Safety mechanism behind the gate | Re-enabled with bar 0.4 (higher than mid-word L0) |

**User's choice:** Locked the recommended set.
**Notes:** Heuristic is forced by REQUIREMENTS.md §LEARN-* deferral — no negative-signal capture available. Source priors and thresholds will live in a single tunable enum (D-13) so they can be adjusted without code hunting.

---

## Ghost classification grid + metrics

| Sub-decision | Alternatives considered | Selected |
|---|---|---|
| Taxonomy | User's introspective nomenclature locked: correct / acceptable / useless / bad / parasite | ✓ |
| Detection signals | Multiple per-category signal options (timing thresholds, divergence detection) | 200ms-after-show dismiss = useless; 500ms-after-show divergence = bad; replaced-within-stability-window = parasite |
| Capture mechanism | (a) Add a custom labeled metric field (audit risk). (b) 5 StaticString count-only events. (c) External replay-only. | (b) 5 StaticString count-only events |
| Release gate | (a) Single aggregate KPI. (b) Three-threshold gate (correct ≥ 30%, useless+bad+parasite ≤ 35%, parasite ≤ 5%). | (b) Three-threshold gate |
| Replay parity | (a) Production-only metrics. (b) Replay scenarios get expected category + confusion matrix in REPLAY-RESULTS.md. | (b) Both |

**User's choice:** Locked the recommended set.
**Notes:** Parasite cap at 5% is the hard regression line — directly motivated by session 2026-05-25 cascade-churn fixes (commits 2b6b6be..7316a8c).

---

## Real-app parity verification protocol

| Sub-decision | Alternatives considered | Selected |
|---|---|---|
| Verification protocol | (a) Scripted only. (b) Daily-use only. (c) Scripted + blind A/B sequentially. | (c) Both, in sequence |
| App tiering | All 7 apps as acceptance gate vs split into tiers | Tier 1 (Mail, Notes, Brave) = acceptance; Tier 2 (Safari, TextEdit, Intercom, Notion) = report-only |
| Acceptance criteria | (a) Classification grid only. (b) Blind A/B only. (c) Both + parasite-window check. | (c) Both + 30-min parasite-window check |
| Output artifacts | (a) Single markdown verdict. (b) Per-app verdict files + roll-up. | (b) Per-app + roll-up |

**User's choice:** Locked the recommended set.
**Notes:** Tier 1 prioritized for cascade stress (heavy prefix context, mid-text edits, Chromium fallback). Tier 2 acts as a regression net without gating the milestone.

---

## Claude's Discretion

- Exact set of unit-test cases beyond the replay equivalence gate (driven by emergent testability of the split, not specified upfront).
- Convention for the 5 `StaticString` classification event names (`ghost_classified_*` proposed; final naming at plan time).
- Atomic-commit granularity during the PVM split (one commit per module vs one per sub-step) — to be tuned at plan-phase.

## Deferred Ideas

- `clipboardContext` opt-in (ex-Phase 4 SLOT-05) — reclassified polish-tier in commit `28558c9`.
- `screenContext` OCR conditional (ex-Phase 4 SLOT-06) — reclassified polish-tier.
- Negative-signal capture (LEARN-01..04) — would unlock a learned Relevance Gate.
- Multi-candidate generation + scoring (MULT-01..03) — orthogonal quality lever, future milestone.
- Visual filters (VIS-01..03) — rendering concern, separate handling.
- Signal Desktop / Electron AX activation (AX-01) — known limitation, deferred.
- XPC isolation 3-process — architectural target, not this milestone.
- Auto-tuning of scoring constants (D-13) — heuristic priors might be learned in a later milestone once classification metrics accumulate.
