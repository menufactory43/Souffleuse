---
phase: 01-foundation-hypothesis-validation
verified: 2026-05-25T12:00:00Z
status: passed
score: 10/10 must-haves verified
overrides_applied: 0
---

# Phase 1: Foundation Hypothesis Validation — Verification Report

**Phase Goal:** La pipeline `PredictorViewModel.predict()` consomme un string final produit par un PromptBuilder structuré (slots nommés, assemblage déterministe) au lieu de la flat-string concat actuelle, et la pipeline de production (debounce, cancel-on-keystroke, cache mémo) continue de fonctionner sans régression observable.

**Verified:** 2026-05-25T12:00:00Z
**Status:** passed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| #  | Truth | Status | Evidence |
|----|-------|--------|----------|
| 1  | `SouffleusePrompt` SPM target exists with 5 files (`PromptBuilder`, `PromptSlot`, `PromptBudget`, `BuiltPrompt`, `TokenCounting`) | ✓ VERIFIED | `Souffleuse/Sources/SouffleusePrompt/` contains exactly 5 .swift files; `Package.swift:56-62` declares target wired with `SouffleuseLog` + `MLXLMCommon` deps |
| 2  | `PromptBuilder` is value-type, `Sendable`, with deterministic assembly + per-slot truncation + global-cap eviction | ✓ VERIFIED | `PromptBuilder.swift:21` `public struct PromptBuilder: Sendable`; eviction priority static array `:28-34`; per-slot truncation loop `:65-87`; global-cap eviction `:91-115` |
| 3  | `PromptBudget.phase1Default` exposes per-slot token budgets summing > global cap (squeeze required) | ✓ VERIFIED | `PromptBudget.swift:22-31`: system=80, ci=40, ctx=150, fewShot=80, beforeCursor=200 (sum 550) vs global=512 |
| 4  | `MLXTokenCounter` adapter implements `TokenCounting` against real `Tokenizer`, with head-truncation honoring sentence-then-word boundary (never mid-word) | ✓ VERIFIED | `MLXTokenCounter.swift:19-89` — `countTokens` via `tokenizer.encode`; `truncateHead` sentence-end set `{".", "?", "!", "…"}` `:55`, two-pass walk (sentence first `:66-74`, word fallback `:77-82`), defensive `""` return `:87` |
| 5  | `PredictorViewModel.predict()` routes through builder when `SOUFFLEUSE_PROMPT_BUILDER=1`, with **per-slot routing** (`customInstr`, `ctxPrefix` named locals — not empty strings) | ✓ VERIFIED | `PredictorViewModel.swift:16-19` `PromptBuilderFlag` enum reads env var; `:703` `if PromptBuilderFlag.enabled` branch; `:724-744` constructs `MLXTokenCounter` from `context.tokenizer`, builds with `customInstr`/`ctxPrefix`/`examplesBlock`/`userTail` slot args (NOT `""`) |
| 6  | Legacy path **preserved** under `else` branch (per Plan 01-05 negative-verdict cleanup-skip) | ✓ VERIFIED | `PredictorViewModel.swift:781-803` — both legacy `isInstructModel` and `else` paths verbatim, using `systemMessage` + `basePromptText`; flag enum preserved `:16-19` |
| 7  | `PromptBuilderTests.swift` exists with 10 `@Test` cases covering determinism, eviction, never-mid-word, per-slot budgets, global cap, reserved Phase 2/3 slots | ✓ VERIFIED | `Tests/SouffleuseTests/PromptBuilderTests.swift` (285 LOC); 10 `@Test` annotations enumerated covering assembly order, empty slots, word-boundary, never-mid-word, sentence-boundary preference, per-slot independence, determinism, token counts, reserved slots, global-cap eviction |
| 8  | `SouffleuseCoherence --replay` sub-command exists and reads scenarios JSON | ✓ VERIFIED | `Sources/SouffleuseCoherence/main.swift:454-457` `if args.count >= 3, args[1] == "--replay"` dispatch to `runReplay`; `replayScenario` defined `:271`; `replay-scenarios.json` v1 schema with 12 scenarios (confirmed via `python3 -c "len(d['scenarios'])"` = 12) |
| 9  | `REPLAY-RESULTS.md` documents an **explicit verdict** on the founding hypothesis (12 scenarios scored, tally documented — verdict need not be positive) | ✓ VERIFIED | `REPLAY-RESULTS.md`: 12 verdict checkboxes filled (`[x]` on each scenario); line 255 `**HYPOTHÈSE PARTIELLEMENT CONFIRMÉE** (4/12 strict — sous le seuil 6/12)`; line 257 `**HYPOTHÈSE NON CONFIRMÉE** au sens strict du seuil 6/12` marker present per Plan 01-05 negative-branch gate |
| 10 | 104 tests green (94 baseline + 10 new) AND `audit.sh` passes 6/6 checks with `Sources/SouffleusePrompt` in SHIPPING_DIRS | ✓ VERIFIED | `swift test` last line: `Test run with 104 tests in 0 suites passed after 0.360 seconds`; `audit.sh:15` `"Sources/SouffleusePrompt"` listed in SHIPPING_DIRS; `bash audit.sh` exit 0 with 6/6 OK markers + `=== AUDIT PASSED ===` |

**Score:** 10/10 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `Souffleuse/Sources/SouffleusePrompt/PromptBuilder.swift` | Value-type Sendable builder, eviction priority, per-slot truncate | ✓ VERIFIED | 156 LOC, eviction priority array + global-cap loop + assembly join present |
| `Souffleuse/Sources/SouffleusePrompt/PromptSlot.swift` | 5 active + 5 reserved slots | ✓ VERIFIED | enum with 5 active (system, customInstructions, contextPrefix, fewShot, beforeCursor) + 5 reserved Phase 2/3 |
| `Souffleuse/Sources/SouffleusePrompt/PromptBudget.swift` | Phase1Default per-slot allocations | ✓ VERIFIED | Sum 550 > global 512 (squeeze designed-in) |
| `Souffleuse/Sources/SouffleusePrompt/BuiltPrompt.swift` | Sendable result struct | ✓ VERIFIED | File exists (1.6K) |
| `Souffleuse/Sources/SouffleusePrompt/TokenCounting.swift` | Protocol with countTokens + truncateHead | ✓ VERIFIED | File exists (984B) |
| `Souffleuse/Sources/Souffleuse/MLXTokenCounter.swift` | Production adapter against `any Tokenizer` | ✓ VERIFIED | 89 LOC, never-mid-word algorithm with sentence-first then word fallback |
| `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` | Feature-flagged dual path | ✓ VERIFIED | `PromptBuilderFlag` enum + `if PromptBuilderFlag.enabled` branch + per-slot routing |
| `Souffleuse/Tests/SouffleuseTests/PromptBuilderTests.swift` | 10 `@Test` snapshot/invariant tests | ✓ VERIFIED | 10 `@Test` functions, 285 LOC |
| `Souffleuse/Sources/SouffleuseCoherence/main.swift` | `--replay` sub-command + `replayScenario` | ✓ VERIFIED | Dispatch at line 454, helper at line 271 |
| `.planning/phases/01-foundation-hypothesis-validation/replay-scenarios.json` | v1 schema, 12 scenarios | ✓ VERIFIED | `{"version": 1, "scenarios": [...]}` with len 12 |
| `.planning/phases/01-foundation-hypothesis-validation/REPLAY-RESULTS.md` | Eyeball verdict per scenario + tally | ✓ VERIFIED | 12 `[x]` verdict marks, tally section, explicit hypothesis verdict marker |
| `Souffleuse/audit.sh` | `Sources/SouffleusePrompt` in SHIPPING_DIRS | ✓ VERIFIED | Line 15: `"Sources/SouffleusePrompt"` listed |
| `Souffleuse/Package.swift` | `SouffleusePrompt` lib target + dep on Souffleuse/Tests/Coherence | ✓ VERIFIED | Target declared `:56-62`, consumed by Souffleuse `:81`, SouffleuseCoherence `:96`, SouffleuseTests `:119` |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|----|--------|---------|
| `PredictorViewModel.predict()` | `PromptBuilder.build()` | `if PromptBuilderFlag.enabled` branch with named per-slot args | ✓ WIRED | `:738-744` calls `builder.build(system:customInstructions:contextPrefix:fewShot:beforeCursor:)` with non-empty named locals (`customInstr`, `ctxPrefix`) |
| `PromptBuilder` | `MLXTokenCounter` | `TokenCounting` protocol injection at construction | ✓ WIRED | `:724-725` `let counter = MLXTokenCounter(tokenizer: context.tokenizer); let builder = PromptBuilder(counter: counter, ...)` |
| `BuiltPrompt.text` | MLX `container.perform` tokenizer | `context.tokenizer.encode(text: built.text)` (base) or `applyChatTemplate` reconstructed from `slotTexts` (instruct) | ✓ WIRED | `:770-779` both paths use builder output as the final string passed to MLX |
| `SouffleuseCoherence --replay` | scenarios JSON | `runReplay(scenariosPath:)` | ✓ WIRED | `:454-456` arg dispatch + load |
| `audit.sh` | `Sources/SouffleusePrompt` | SHIPPING_DIRS array | ✓ WIRED | Line 15 entry — all 6 checks scan SouffleusePrompt source |
| `Package.swift Souffleuse target` | `SouffleusePrompt` | dependencies array | ✓ WIRED | Line 81 entry; consumed identically by SouffleuseCoherence + SouffleuseTests |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|----|
| `BuiltPrompt.text` (consumed by MLX) | `built.text` | `PromptBuilder.build(...)` invoked with `customInstr`, `ctxPrefix`, `examplesBlock`, `userTail` (real `PredictorViewModel` state, not stubs) | ✓ Yes — per-slot routing of real `customInstructions` UserDefaults + real `contextPrefix` from `ContextEnricher` (legacy daily-use evidence in 01-05-SUMMARY confirms ContextEnricher already supplies non-empty prefixes) | ✓ FLOWING |
| `MLXTokenCounter.tokenizer` | `tokenizer` | `context.tokenizer` from MLX `container.perform` (live tokenizer) | ✓ Yes | ✓ FLOWING |
| `SouffleuseCoherence --replay` ghost output | `ghost` per variant | `replayScenario(...)` calls real MLX inference; results streamed to `REPLAY-RESULTS.md` table cells | ✓ Yes — REPLAY-RESULTS rows show non-empty ghosts (e.g. row 1 WITHOUT=`<input type="text"...`, WITH=` Marie: « Ok`) | ✓ FLOWING |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|----|
| Full test suite green (94 baseline + 10 PromptBuilder) | `swift test` | `Test run with 104 tests in 0 suites passed after 0.360 seconds` | ✓ PASS |
| Privacy invariants (audit.sh) | `bash audit.sh` | 6/6 OK, `=== AUDIT PASSED ===`, exit 0 | ✓ PASS |
| `SouffleusePrompt` files present | `ls Sources/SouffleusePrompt/` | 5 .swift files (BuiltPrompt, PromptBudget, PromptBuilder, PromptSlot, TokenCounting) | ✓ PASS |
| 10 `@Test` annotations | `grep "@Test" PromptBuilderTests.swift` | 10 matches | ✓ PASS |
| `replay-scenarios.json` has 12 scenarios | `python3 -c "len(d['scenarios'])"` | 12 | ✓ PASS |
| Verdict marker present in REPLAY-RESULTS | `grep "HYPOTHÈSE"` | Line 255 `**HYPOTHÈSE PARTIELLEMENT CONFIRMÉE**`; Line 257 `HYPOTHÈSE NON CONFIRMÉE` (negative-branch gate marker) | ✓ PASS |
| Feature flag enum preserved (legacy not removed) | `grep "PromptBuilderFlag\|basePromptText"` in PredictorViewModel | Both present (`:16` enum, `:680` legacy local) | ✓ PASS |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| BUILDER-01 | 01-01, 01-03 | PromptBuilder structuré remplace flat-string concat dans `PredictorViewModel.predict()` | ✓ SATISFIED | `PromptBuilder.swift` value-type with named slot args; `PredictorViewModel.swift:703-779` routes through builder when flag enabled, with per-slot inputs (Truths 1, 5) |
| BUILDER-02 | 01-01, 01-03 | Budget en tokens (pas chars) avec allocation par slot + eviction policy | ✓ SATISFIED | `PromptBudget.phase1Default` per-slot map; `PromptBuilder.evictionPriority` static array + global-cap squeeze; `MLXTokenCounter` counts actual tokens (Truths 2, 3, 4) |
| BUILDER-03 | 01-02 | Builder testable en isolation, snapshot tests indépendants de MLX | ✓ SATISFIED | `PromptBuilderTests.swift` uses `WordCountTokenCounter` mock (no MLX), 10 `@Test` covering determinism + invariants (Truth 7) |
| BUILDER-04 | 01-03, 01-05 | Pipeline existante continue sans régression. Migration strategy (feature flag) tranchée | ✓ SATISFIED | Feature flag `SOUFFLEUSE_PROMPT_BUILDER` chosen (PROMPTbuilderFlag enum); legacy path preserved; 104/104 tests green; audit OK (Truths 5, 6, 10) |
| SLOT-01 | 01-01 | Slot `beforeCursor` mieux budgeté (token-aware, préservation dernier mot complet) | ✓ SATISFIED | `MLXTokenCounter.truncateHead` head-truncates `beforeCursor` with sentence-then-word boundary, never mid-word (Truth 4); `PromptBuilder.swift:73-76` special-cases `.beforeCursor` for head-truncation |
| AUDIT-01 | 01-04 | Mode replay rejouant 10-20 scénarios avec/sans contexte enrichi, logue le ghost | ✓ SATISFIED | `SouffleuseCoherence --replay` + `replay-scenarios.json` (12 scenarios) + `REPLAY-RESULTS.md` markdown table per scenario (Truth 8) |
| AUDIT-02 | 01-04, 01-05 | Verdict A/B clair avant Phase 2. Si non-confirmée, milestone revu | ✓ SATISFIED | `REPLAY-RESULTS.md` documents EXPLICIT verdict: 4/12 ✓ < seuil 6/12 → `HYPOTHÈSE NON CONFIRMÉE` strict; Plan 01-05 negative-branch executed (cleanup skipped, legacy preserved, rationale documented in 01-05-SUMMARY "Decision rationale" section) (Truth 9) |
| TEST-01 | 01-05 | 94 tests existants restent verts à chaque atomic commit | ✓ SATISFIED | `swift test` 104/104 pass = 94 baseline + 10 new, zero regressions (Truth 10) |
| TEST-02 | 01-02 | Nouveaux tests PromptBuilder : budget allocation, snapshot determinism | ✓ SATISFIED | 10 `@Test` covering determinism, eviction, per-slot budgets, never-mid-word, reserved slots (Truth 7) |
| TEST-03 | 01-01, 01-05 | `audit.sh` (6 checks) continue de passer | ✓ SATISFIED | `bash audit.sh` exit 0; 6/6 OK with `Sources/SouffleusePrompt` now in SHIPPING_DIRS (Truth 10) |

**Coverage: 10/10 phase requirements SATISFIED. Zero ORPHANED.**

### Anti-Patterns Found

None blocking. Notes:

- `PredictorViewModel.swift` retains dual paths (legacy + builder) — this is **by design** per Plan 01-05 negative-verdict branch; feature flag preserved intentionally. The 01-05 plan documents that cleanup is deferred to Phase 2/3 once additional slots prove differential signal.
- `PromptBuilder.swift:152` self-comment notes word-count proxy for non-`beforeCursor` slots — acknowledged approximation, documented, falls within Phase 1 scope.

No TODO/FIXME blockers, no empty `return null` stubs, no placeholder strings, no `console.log`/`print` smells (audit confirms).

### Human Verification Required

None. Phase goal is structural (builder integration + replay verdict). All gates are programmatically verifiable:
- File presence: confirmed
- Wiring (per-slot routing, no empty-string args): confirmed via grep
- Test suite green: `swift test` 104/104
- Privacy audit: 6/6 green
- Explicit verdict on hypothesis: confirmed in `REPLAY-RESULTS.md`

Subjective ghost-quality assessment is documented in `REPLAY-RESULTS.md` and `01-05-SUMMARY.md` ("Decision rationale" section) and is itself the artifact of AUDIT-02 — the verdict is recorded, not pending.

### Gaps Summary

No gaps. Phase goal achieved:

1. **Structural goal:** ✓ `PredictorViewModel.predict()` consumes a string produced by a structured PromptBuilder (slots nommés, assemblage déterministe) when the `SOUFFLEUSE_PROMPT_BUILDER=1` flag is active. The per-slot routing is real (named locals `customInstr`/`ctxPrefix`, not empty strings) — the per-slot budgets are exercised in production.
2. **Non-regression goal:** ✓ Pipeline (debounce, cancel-on-keystroke, cache) continues to work — legacy path preserved verbatim under the `else` branch; 94 baseline tests remain green alongside 10 new PromptBuilder tests (104/104).
3. **Hypothesis validation goal (AUDIT-02):** ✓ An explicit verdict was produced — `HYPOTHÈSE NON CONFIRMÉE` strict (4/12 ✓ < seuil 6/12). Per the critical-context rules and the AUDIT-02 wording ("verdict A/B clair", "si non confirmée le milestone est revu"), the requirement is satisfied by the DECISION being documented, not by the decision being positive. Plan 01-05's negative-branch was correctly executed: cleanup skipped, legacy path preserved, rationale recorded in `01-05-SUMMARY.md` "Decision rationale" section. Phase 2 mandate is clarified — `contextPrefix` alone is insufficient, high-signal AX-driven slots (`afterCursor`, `fieldContext`) are needed.

The infrastructure (5-file `SouffleusePrompt` target, `MLXTokenCounter`, 10 isolation tests, `--replay` harness, 12 curated scenarios, REPLAY-RESULTS markdown) is fully built and ready for Phase 2 iteration.

---

_Verified: 2026-05-25T12:00:00Z_
_Verifier: Claude (gsd-verifier)_
