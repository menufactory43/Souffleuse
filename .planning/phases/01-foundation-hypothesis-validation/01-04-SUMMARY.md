---
phase: 01-foundation-hypothesis-validation
plan: 04
subsystem: testing
tags: [swift, mlx, replay-harness, audit, cli, prompt-builder]

# Dependency graph
requires:
  - phase: 01-foundation-hypothesis-validation/01
    provides: PromptBuilder + TokenCounting protocol + PromptBudget.phase1Default
  - phase: 01-foundation-hypothesis-validation/03
    provides: MLXTokenCounter adapter pattern (duplicated locally as CoherenceTokenCounter)
provides:
  - .planning/phases/01-foundation-hypothesis-validation/replay-scenarios.json (12 curated scenarios, version 1)
  - --replay sub-command on SouffleuseCoherence executable
  - REPLAY-RESULTS.md atomic-write generator with W5/W6 caveat preamble and AUDIT-02 gate (≥ 6/12)
affects: [01-05-PLAN human eyeball verdict pass, AUDIT-02 phase-gate decision]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Sub-command dispatch on CommandLine.arguments[1] in CLI executable (`--replay <path>`)"
    - "Versioned JSON config (version: 1) for in-repo planning artifacts — mirrors AllowlistFile pattern"
    - "Atomic markdown emission via Data.write(options: .atomic) — same pattern as AllowlistStore.save"
    - "Accepted duplication of MLX tokenizer adapter into dev-only CLI target (RESEARCH §6 posture)"

key-files:
  created:
    - .planning/phases/01-foundation-hypothesis-validation/replay-scenarios.json
  modified:
    - Souffleuse/Sources/SouffleuseCoherence/main.swift

key-decisions:
  - "Replay loop runs WITHOUT + WITH variants sequentially per scenario (MLX is GPU-bound, parallel doesn't help)"
  - "CoherenceTokenCounter duplicated locally in the CLI target rather than promoted to public SouffleusePrompt API — Phase 1 simplicity (RESEARCH §6); TODO Phase 2 dedupe noted in source"
  - "Simplified system prompt in replay (not PredictorViewModel.buildSystemPrompt) — W5 caveat documented in REPLAY-RESULTS.md preamble; verdict measures EFFECT OF contextPrefix, not full prompt parity"
  - "AUDIT-02 threshold (≥ 6/12 ✓ verdicts) hardcoded in markdown tally rendering — single source of truth"
  - "Model load factored to top of main() and shared by default + replay paths (no double-load on either entry)"

patterns-established:
  - "Codable+Sendable schema with optional fields (windowTitle, notes, customInstructions) for in-repo curated test data"
  - "Markdown safe-rendering helper: replace ` → \\` and \\n → ⏎ before embedding user/model strings in tables"

requirements-completed: [AUDIT-01]

# Metrics
duration: 18min
completed: 2026-05-25
---

# Phase 01 Plan 04: Build Replay Harness Summary

**SouffleuseCoherence gains a `--replay <scenarios.json>` sub-command that drives the production PromptBuilder over 12 curated scenarios in WITHOUT/WITH contextPrefix variants and emits a side-by-side REPLAY-RESULTS.md for the human eyeball verdict (AUDIT-01).**

## Performance

- **Duration:** ~18 min
- **Started:** 2026-05-25T06:50:00Z (approx — agent start)
- **Completed:** 2026-05-25T07:08:08Z
- **Tasks:** 2/2
- **Files modified:** 2 (1 created, 1 extended)

## Accomplishments

- Wired the production `PromptBuilder` (built in plan 01-01) and `TokenCounting` protocol into the dev-only `SouffleuseCoherence` executable without leaking AX / Context / Personalization imports into the harness (T2 mitigation preserved by construction)
- 12-scenario curated seed (10 FR, 1 EN-FR mix, 1 code) checked into `.planning/` so the audit is fully reproducible from a clean checkout — bundle IDs verified absent from `personalizationBundleBlocklist` / `bundleBlocklist`
- W5 + W6 caveats embedded directly in the markdown preamble so the eyeball verdict (plan 01-05) reads the simplification disclaimers inline rather than relying on out-of-band knowledge
- Default `swift run SouffleuseCoherence` (no args) behaviour preserved verbatim — the existing 8-target typing-simulé loop still runs, no regression on the chained coherence audit

## Task Commits

1. **Task 1: Créer replay-scenarios.json (12 scénarios seed)** — `80f242b` (chore)
2. **Task 2: Étendre SouffleuseCoherence/main.swift avec sub-command --replay** — `d4ce39b` (feat)

**Plan metadata:** _(this SUMMARY commit)_

## Files Created/Modified

- `.planning/phases/01-foundation-hypothesis-validation/replay-scenarios.json` (created, 7574 bytes) — 12 versioned scenarios with required {id, label, bundleID, contextPrefix, userTail} + optional {windowTitle, notes, customInstructions}
- `Souffleuse/Sources/SouffleuseCoherence/main.swift` (extended from 281 → 515 lines) — added `Scenario`, `ScenarioFile`, `CoherenceTokenCounter`, `replayScenario`, `loadScenarios`, `renderReplayResults`, `runReplay`; refactored `main()` to share model load between default and replay paths via a `--replay <path>` arg dispatch

## Decisions Made

- **CoherenceTokenCounter duplication accepted (Phase 1):** Rather than promote `MLXTokenCounter` (app target) to a public `SouffleusePrompt` API, the harness ships an inline twin with a `TODO Phase 2: dedupe` marker. Rationale: keeping SouffleusePrompt free of `MLXLMCommon` / `Tokenizers` deps keeps its unit-test surface mockable without loading a model. RESEARCH §6 posture explicitly endorses this for Phase 1.
- **Sequential variants per scenario:** Each scenario runs WITHOUT then WITH inside the same `container.perform` task lineage. MLX is GPU-bound — parallel `container.perform` calls would serialize on the device anyway. Sequential keeps the stdout progress line easy to follow.
- **W5/W6 caveats in markdown preamble, not footer:** Reading order for the human verdict (plan 01-05) is top-to-bottom. Putting the caveats up front prevents post-hoc rationalization of edge results.
- **AUDIT-02 threshold hardcoded in renderer (≥ 6/12):** Single source of truth — if the threshold ever changes, the renderer is the one place to touch and every regenerated REPLAY-RESULTS.md self-documents the gate.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Extended `long-tail-truncation` scenario `userTail` from 426 → 711 chars**
- **Found during:** Task 1 verify step (python assertion `len(userTail) > 600`).
- **Issue:** The RESEARCH §7 verbatim seed for `long-tail-truncation` is 426 chars. Its own `notes` field claims "~750 chars, budget beforeCursor=200 tokens (~600 chars). Le builder doit cut head sur frontière phrase." 426 chars (~100-150 tokens, well under the 200-token budget) does NOT exercise head-truncation. The plan's acceptance criterion `userTail de plus de 600 caractères (stress test head-truncation)` codifies the actual functional requirement.
- **Fix:** Extended the userTail with two additional sentences on the "point 1" / "point 3" alignment to reach 711 chars, while keeping the engaged-mid-sentence ending ("Sur le point 2, j'aimerais juste qu'on s'assure qu'on ne ") intact so the model still has a clear continuation hook.
- **Files modified:** `.planning/phases/01-foundation-hypothesis-validation/replay-scenarios.json`
- **Verification:** `python3 -c "...assert len(ltt['userTail']) > 600"` → `711 chars`.
- **Committed in:** `80f242b` (Task 1 commit). Deviation explanation embedded in the scenario's `notes` field.

---

**Total deviations:** 1 auto-fixed (1 Rule 1 bug).
**Impact on plan:** The deviation strictly satisfies an acceptance criterion that contradicted the verbatim seed. No scope creep — only the one scenario was modified, the other 11 are verbatim from RESEARCH §7.

## Issues Encountered

None — both tasks executed cleanly. Build/test/audit all green on first attempt after the long-tail fix.

## User Setup Required

None — no external services. The replay harness consumes only the in-repo `replay-scenarios.json` and the MLX model already downloaded on prior plans.

## Next Phase Readiness

- Plan 01-05 can now run `swift run SouffleuseCoherence --replay .planning/phases/01-foundation-hypothesis-validation/replay-scenarios.json` to populate `REPLAY-RESULTS.md`. Expected runtime: ~30s model load + ~30s for 24 generations (12 scenarios × 2 variants × ~12 tokens).
- The plan 01-05 human pass should: (a) read the W5/W6 caveats in the preamble, (b) tick exactly one of {✓, =, ✗} per scenario, (c) fill the tally block, (d) compare to the hardcoded `≥ 6/12 ✓` AUDIT-02 gate.
- Wave 4 (plan 01-05) is the owner of `REPLAY-RESULTS.md` — this wave intentionally did NOT generate the file (would require model load + GPU, which the executor must not assume in a worktree agent).
- Default `swift run SouffleuseCoherence` typing-simulé loop remains exerçable for any future regression audit on the production gating chain.

## Verification Trace

- `cd Souffleuse && swift build` → exit 0 (full package linked).
- `cd Souffleuse && swift build --target SouffleuseCoherence` → exit 0 (74.38s).
- `cd Souffleuse && swift test` → exit 0 (104 tests passed, all suites green).
- `cd Souffleuse && bash ./audit.sh` → exit 0 (6/6 checks: no print, no NSLog, no os_log user-text, log fields whitelisted, history.aes scope, no Log.* with user fields).
- All 12 grep-based acceptance criteria pass (import SouffleusePrompt, Scenario/ScenarioFile/CoherenceTokenCounter declarations, --replay literal, PromptBuilder(counter:, REPLAY-RESULTS.md, options: .atomic, default loop label preserved).
- Forbidden-import grep negative: no `SouffleuseAX|SouffleuseContext|SouffleusePersonalization` imports in the harness (T2 mitigation enforced).

## Self-Check: PASSED

- FOUND: `.planning/phases/01-foundation-hypothesis-validation/replay-scenarios.json`
- FOUND: `Souffleuse/Sources/SouffleuseCoherence/main.swift` (modified)
- FOUND: commit `80f242b` (Task 1 — scenarios JSON)
- FOUND: commit `d4ce39b` (Task 2 — main.swift extension)

---
*Phase: 01-foundation-hypothesis-validation*
*Completed: 2026-05-25*
