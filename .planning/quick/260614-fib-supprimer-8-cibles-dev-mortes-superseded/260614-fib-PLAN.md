---
phase: quick-260614-fib
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - Souffleuse/Package.swift
  - CLAUDE.md
  - Souffleuse/BENCHMARKS.md
  - Souffleuse/Sources/SouffleuseCorpusEval/
  - Souffleuse/Sources/SouffleuseTTFTBench/
  - Souffleuse/Sources/SouffleuseBeamEval/
  - Souffleuse/Sources/SouffleusePersonalizationEval/
  - Souffleuse/Sources/SouffleuseMaxWordsEval/
  - Souffleuse/Sources/SouffleuseBench/
  - Souffleuse/Sources/SouffleuseCoherence/
  - Souffleuse/Sources/SouffleuseEnrichmentBench/
autonomous: true
requirements: [CLEANUP-MLX]

must_haves:
  truths:
    - "The 8 dead/superseded dev targets no longer exist in Sources/ or Package.swift"
    - "mlx-swift-examples is gone from the package dependency graph and Package.resolved"
    - "swift build succeeds and the ~640 @Test suite stays green"
    - "Docs (CLAUDE.md, BENCHMARKS.md) no longer claim MLX is a live package dependency for probes"
  artifacts:
    - path: "Souffleuse/Package.swift"
      provides: "Manifest with 8 targets, 4 product lines, and the mlx dependency removed"
      contains: "Sparkle"
  key_links:
    - from: "Souffleuse/Package.swift"
      to: "mlx-swift-examples"
      via: "dependency removed — no remaining .product(...package: \"mlx-swift-examples\")"
      pattern: "mlx-swift-examples"
---

<objective>
Remove 8 dead/superseded dev-only targets and orphan the MLX SPM dependency from the Souffleuse package, then sync the docs.

Purpose: The MLX container was removed from the app on 11/06/2026 (870 MB resident for zero consumers). The only remaining `import MLX` sites are 4 throwaway/MLX-bench targets; deleting them lets us drop the `mlx-swift-examples` dependency entirely. Five other targets are explicitly throwaway or superseded.

Output: Slimmer Package.swift (no MLX dep, 8 fewer targets, 4 fewer product lines), 8 deleted source dirs, and docs that no longer claim MLX is a live package dependency. Single atomic commit.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/STATE.md
@CLAUDE.md
@Souffleuse/Package.swift
@Souffleuse/BENCHMARKS.md

<facts>
Pre-verified by the user (executor MUST re-confirm grep before the irreversible delete):

Targets to delete (Sources/<name>/ dir + their blocks in Package.swift):
  1. SouffleuseCorpusEval         — header "HARNAIS JETABLE … à SUPPRIMER après usage"
  2. SouffleuseTTFTBench          — throwaway TTFT harness; measured the now-removed MLX container; MLX consumer
  3. SouffleuseBeamEval           — superseded by SouffleuseCascadeVsBeamEval
  4. SouffleusePersonalizationEval — synthetic; superseded by SouffleuseRealPersoEval
  5. SouffleuseMaxWordsEval       — one-shot knob-sweep
  6. SouffleuseBench              — MLX consumer
  7. SouffleuseCoherence          — MLX consumer
  8. SouffleuseEnrichmentBench    — MLX consumer

The only 4 files with `import MLX*` are SouffleuseBench, SouffleuseCoherence,
SouffleuseEnrichmentBench, SouffleuseTTFTBench — all in the delete list. After
deletion the `mlx-swift-examples` dependency is fully orphaned.

Package.swift current locations (verified against the file in context):
  - products: SouffleuseBench (l.11), SouffleuseCoherence (l.12),
    SouffleuseEnrichmentBench (l.13), SouffleuseMaxWordsEval (l.19) have
    `.executable` product lines. The other 4 are target-only (no product line).
  - dependencies: `.package(url: ".../mlx-swift-examples", from: "2.0.0")` at l.43.
  - targets: all 8 have `.executableTarget` blocks. SouffleuseTTFTBench (l.162),
    SouffleuseBench (l.239), SouffleuseCoherence (l.246), SouffleuseEnrichmentBench
    (l.254), SouffleuseMaxWordsEval (l.425), SouffleuseBeamEval (l.382),
    SouffleuseCorpusEval (l.292), SouffleusePersonalizationEval (l.302).
  - KEEP: Sparkle dependency, every other eval/probe target, the app target,
    all libraries, the test target.
</facts>
</context>

<tasks>

<task type="auto">
  <name>Task 1: Confirm scope, then git rm the 8 source dirs</name>
  <files>
    Souffleuse/Sources/SouffleuseCorpusEval/, Souffleuse/Sources/SouffleuseTTFTBench/,
    Souffleuse/Sources/SouffleuseBeamEval/, Souffleuse/Sources/SouffleusePersonalizationEval/,
    Souffleuse/Sources/SouffleuseMaxWordsEval/, Souffleuse/Sources/SouffleuseBench/,
    Souffleuse/Sources/SouffleuseCoherence/, Souffleuse/Sources/SouffleuseEnrichmentBench/
  </files>
  <action>
    First RE-CONFIRM the pre-verified facts (do not skip — this is the only safety net before an irreversible delete):

    1. Confirm exactly these 4 files contain `import MLX` and all are in the delete list:
       `cd Souffleuse && grep -rl 'import MLX' Sources/`
       Expected output = exactly: SouffleuseBench, SouffleuseCoherence, SouffleuseEnrichmentBench, SouffleuseTTFTBench (4 files, any order). If a 5th file appears OUTSIDE the delete list, STOP and report — the MLX dependency is NOT orphaned and must not be removed.

    2. Confirm no NON-deleted target depends on any of the 8 target names:
       `cd Souffleuse && grep -nE '"(SouffleuseCorpusEval|SouffleuseTTFTBench|SouffleuseBeamEval|SouffleusePersonalizationEval|SouffleuseMaxWordsEval|SouffleuseBench|SouffleuseCoherence|SouffleuseEnrichmentBench)"' Package.swift`
       Every match must be either a product line or that target's own `executableTarget` name/product — NEVER inside another target's `dependencies:` array. If any of the 8 names appears as a dependency of a kept target, STOP and report.

    Only after both checks pass, delete the 8 source directories:
    `cd Souffleuse && git rm -r Sources/SouffleuseCorpusEval Sources/SouffleuseTTFTBench Sources/SouffleuseBeamEval Sources/SouffleusePersonalizationEval Sources/SouffleuseMaxWordsEval Sources/SouffleuseBench Sources/SouffleuseCoherence Sources/SouffleuseEnrichmentBench`

    Do NOT touch any other Sources/ dir. Do NOT edit Package.swift yet (Task 2).
  </action>
  <verify>
    <automated>cd Souffleuse && test ! -d Sources/SouffleuseBench && test ! -d Sources/SouffleuseTTFTBench && test ! -d Sources/SouffleuseCoherence && test ! -d Sources/SouffleuseEnrichmentBench && test ! -d Sources/SouffleuseCorpusEval && test ! -d Sources/SouffleuseBeamEval && test ! -d Sources/SouffleusePersonalizationEval && test ! -d Sources/SouffleuseMaxWordsEval && echo OK</automated>
  </verify>
  <done>All 8 dirs removed via git rm; the two grep pre-checks passed (exactly the 4 expected MLX files, no kept target depends on a deleted one).</done>
</task>

<task type="auto">
  <name>Task 2: Strip the 8 targets, 4 product lines, and the MLX dependency from Package.swift</name>
  <files>Souffleuse/Package.swift</files>
  <action>
    Edit Souffleuse/Package.swift surgically (Edit tool, not heredoc):

    1. In `products:` remove these 4 `.executable` lines (currently l.11-13, l.19):
       - `.executable(name: "SouffleuseBench", targets: ["SouffleuseBench"]),`
       - `.executable(name: "SouffleuseCoherence", targets: ["SouffleuseCoherence"]),`
       - `.executable(name: "SouffleuseEnrichmentBench", targets: ["SouffleuseEnrichmentBench"]),`
       - `.executable(name: "SouffleuseMaxWordsEval", targets: ["SouffleuseMaxWordsEval"]),`
       The other 4 deleted targets have NO product line — do not invent removals.

    2. In `dependencies:` remove the line:
       `.package(url: "https://github.com/ml-explore/mlx-swift-examples", from: "2.0.0"),`
       KEEP the Sparkle dependency and its explanatory comment immediately below.

    3. In `targets:` remove the 8 `.executableTarget(...)` blocks in full (name, dependencies, closing paren and trailing comma) for: SouffleuseTTFTBench, SouffleuseBench, SouffleuseCoherence, SouffleuseEnrichmentBench, SouffleuseMaxWordsEval, SouffleuseBeamEval, SouffleuseCorpusEval, SouffleusePersonalizationEval. For SouffleuseCorpusEval also remove the `// JETABLE (dev-only)…` comment line directly above it (l.292). For SouffleuseTTFTBench remove its inline `// A/B contention…` comment lines too.

    Leave every other target, the app target, all libraries, and the testTarget untouched. After editing, the file must contain zero occurrences of "mlx-swift-examples" and zero occurrences of any of the 8 deleted target names.
  </action>
  <verify>
    <automated>cd Souffleuse && grep -cE 'mlx-swift-examples|SouffleuseTTFTBench|"SouffleuseBench"|SouffleuseCoherence|SouffleuseEnrichmentBench|SouffleuseMaxWordsEval|SouffleuseBeamEval|SouffleuseCorpusEval|SouffleusePersonalizationEval' Package.swift | grep -qx 0 && swift package resolve && ! grep -q 'mlx-swift-examples' Package.resolved && echo OK</automated>
  </verify>
  <done>Package.swift has no MLX dep, no 8-target references, 4 product lines gone; `swift package resolve` succeeds and Package.resolved no longer lists mlx-swift-examples.</done>
</task>

<task type="auto">
  <name>Task 3: Sync docs, then build + test green</name>
  <files>CLAUDE.md, Souffleuse/BENCHMARKS.md</files>
  <action>
    Doc edits (surgical — keep all unrelated content):

    CLAUDE.md (project root): MLX is now FULLY gone from the package.
      - In Constraints/Stack: remove the justification "MLX (`MLXLLM`/`MLXLMCommon`) reste une dépendance SPM du package pour les probes dev" and "Reste en dépendance du package pour les probes dev (`SouffleuseBench`, `SouffleuseCoherence`, `SouffleuseEnrichmentBench`, `SouffleuseTTFTBench`)". Replace with a statement that MLX is no longer a dependency of the package at all (removed 14/06/2026); the n-gram path tokenises via the llama tokenizer.
      - In the probes/evals list: remove SouffleuseBench, SouffleuseCoherence, SouffleuseEnrichmentBench, SouffleuseTTFTBench (and don't leave dangling references to the other 4 deleted targets if any are listed: SouffleuseCorpusEval, SouffleuseBeamEval, SouffleusePersonalizationEval, SouffleuseMaxWordsEval).
      - Keep every other line intact (architecture, conventions, llama.cpp engine description).

    Souffleuse/BENCHMARKS.md: mark MLX-based runs as historical.
      - Add a short note at the top of the relevant MLX sections (Run 1/2/3, the `mlx-community/*` runs and the `SouffleuseEnrichmentBench` runs) stating the generation engine is now llama.cpp (GGUF Metal) and MLX is no longer in the package; these figures are kept as historical reference. Do not delete the data.

    Then run the build + full suite from the package dir:
      `cd Souffleuse && swift build`
      `cd Souffleuse && swift test`
    Both must succeed; the ~640 @Test suite stays green.
  </action>
  <verify>
    <automated>cd Souffleuse && ! grep -q 'mlx-swift-examples' ../CLAUDE.md && swift build && swift test 2>&1 | tail -5</automated>
  </verify>
  <done>Docs no longer claim MLX is a live package dependency; `swift build` succeeds and `swift test` reports the full suite green with zero failures.</done>
</task>

</tasks>

<verification>
- `cd Souffleuse && grep -rl 'import MLX' Sources/` returns nothing (no MLX consumers left).
- `cd Souffleuse && swift build` succeeds.
- `cd Souffleuse && swift package resolve` → `Package.resolved` has no mlx-swift-examples.
- `cd Souffleuse && swift test` → ~640 @Test suite green.
- `Souffleuse/audit.sh` behaviour unchanged (deleted targets were already outside SHIPPING_DIRS).
- Single atomic commit contains code + docs.
</verification>

<success_criteria>
- 8 target dirs deleted, their Package.swift blocks + 4 product lines removed.
- mlx-swift-examples dependency gone from manifest and Package.resolved.
- Sparkle and all other targets/libraries/tests untouched.
- CLAUDE.md + BENCHMARKS.md reflect that MLX is no longer a package dependency.
- Build green, tests green, in one commit.
</success_criteria>

<output>
After completion, create `.planning/quick/260614-fib-supprimer-8-cibles-dev-mortes-superseded/260614-fib-SUMMARY.md`
</output>
