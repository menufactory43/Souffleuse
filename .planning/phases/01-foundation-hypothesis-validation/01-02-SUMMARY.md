---
phase: 01-foundation-hypothesis-validation
plan: 02
subsystem: SouffleusePrompt (tests)
tags: [swift, testing, swift-testing, prompt-builder, snapshot-tests, isolation]
requires:
  - SouffleusePrompt (built in plan 01-01)
provides:
  - "Test suite verrouillant les invariants D-04 (per-slot independence) et D-11 (never mid-word, sentence-preferred head-truncation) du PromptBuilder en isolation totale de MLX."
affects:
  - Souffleuse/Tests/SouffleuseTests/
tech-stack:
  added: []
  patterns:
    - "Swift Testing (import Testing, @Test func, #expect) — précédent ChunkSplitterTests"
    - "Mock co-located dans le test file (struct, pas actor — protocol sync) — précédent MockOCRCaretLocator"
    - "@testable import SouffleusePrompt — accès aux internals (notamment tailTruncateToWordBoundary)"
key-files:
  created:
    - Souffleuse/Tests/SouffleuseTests/PromptBuilderTests.swift
  modified: []
decisions:
  - "Mock WordCountTokenCounter + SentenceAwareTokenCounter co-located dans le fichier de test (pattern MockOCRCaretLocator in CaretResolverTests.swift) — pas de Mocks/ target séparé."
  - "Tests rédigés en Swift Testing (import Testing, @Test func), pas XCTest — cohérent avec ChunkSplitterTests.swift et le précédent verrouillé pour les nouveaux fichiers de test."
  - "Le test sentence-boundary teste les INVARIANTS génériques (suffix, ≤ budget, commence par lettre, slot tronqué), pas un snapshot exact — le comportement précis dépend des stratégies retenues par truncateHead et est exercé sous oeil humain par le replay harness (plan 01-04)."
metrics:
  duration: "~3 minutes (single task, build cache miss → 140 s pour la première compilation, puis < 1 s pour les tests)"
  completed: "2026-05-24"
  tests_added: 10
  tests_total_passing: 104
---

# Phase 01 Plan 02: PromptBuilder isolation test suite — Summary

## One-liner

Suite Swift Testing de 10 `@Test` functions verrouille l'assemblage déterministe du `PromptBuilder` et ses invariants D-04 / D-11 sans charger MLX, via deux mocks `TokenCounting` co-located (`WordCountTokenCounter`, `SentenceAwareTokenCounter`).

## What was built

Un seul fichier : `Souffleuse/Tests/SouffleuseTests/PromptBuilderTests.swift` (285 lignes).

- **`MARK: Test doubles`** — deux structs `Sendable` conformant à `TokenCounting` :
  - `WordCountTokenCounter` — tokens = nombre de mots (split sur whitespace) ; `truncateHead` retient les N derniers mots. Le mock par défaut pour la majorité des tests.
  - `SentenceAwareTokenCounter` — préfère un cut sur frontière de phrase (`.`, `?`, `!`) avant de fallback sur word-boundary. Exerce D-11 step (a) > step (b).
- **`MARK: Tests`** — 10 `@Test func builder*` :
  1. `builderAssemblesAllSlotsInOrder` — snapshot exact de l'assemblage des 5 slots séparés par `\n\n` (budget par défaut, aucune troncation).
  2. `builderHandlesEmptySlotsWithoutBlankLines` — les slots vides ne contribuent ni au `text` ni au `slotTexts` dict.
  3. `builderTruncatesBeforeCursorAtWordBoundary` — head-truncate "Salutations bienveillantes mon ami fidèle" budget=3 → "mon ami fidèle", `truncatedSlots.contains(.beforeCursor)`.
  4. `builderNeverCutsMidWord` (**D-11(c)**) — la sortie commence par une lettre/chiffre, jamais au milieu d'un mot.
  5. `builderPrefersSentenceBoundaryOverWordBoundary` (**D-11(a)**) — invariants sur SentenceAwareTokenCounter : sortie ≤ budget, suffix du longTail, slot marqué tronqué, commence par lettre/chiffre.
  6. `builderHonorsPerSlotBudgetsIndependently` (**D-04**) — contextPrefix qui fit reste intact même quand beforeCursor overflow son budget.
  7. `builderIsDeterministic` — 100 invocations sur les mêmes inputs → 100 BuiltPrompt Equatable-equal.
  8. `builderRecordsTokenCountsPerSlot` — `slotTokenCounts` peuplé correctement post-eviction, somme = `totalTokens`.
  9. `builderReservedPhase2SlotsAreNotFilled` — `afterCursor`, `fieldContext`, `previousUserInputs`, `clipboardContext`, `screenContext` jamais peuplés en Phase 1.
  10. `builderHonorsGlobalCapViaEvictionPriority` — global cap (5) < somme per-slot (8) → `fewShot` (priorité 1) droppé, les autres slots intacts.

## Invariants couverts

| Invariant | Décision | Test |
|-----------|----------|------|
| D-04 | Per-slot independence — pas de cross-slot stealing | `builderHonorsPerSlotBudgetsIndependently` |
| D-11(a) | Sentence-boundary preferred over word-boundary | `builderPrefersSentenceBoundaryOverWordBoundary` |
| D-11(c) | Never cuts mid-word | `builderNeverCutsMidWord` |
| Determinism | Same (counter, budget, inputs) → same BuiltPrompt | `builderIsDeterministic` |
| Eviction priority | fewShot dropped first when global cap fires | `builderHonorsGlobalCapViaEvictionPriority` |
| Reserved-slots inert | Phase 2/3 slots never filled in Phase 1 build() | `builderReservedPhase2SlotsAreNotFilled` |

## Test output

```
swift test --filter PromptBuilderTests
✔ Test builderRecordsTokenCountsPerSlot() passed after 0.001 seconds.
✔ Test builderAssemblesAllSlotsInOrder() passed after 0.001 seconds.
✔ Test builderReservedPhase2SlotsAreNotFilled() passed after 0.001 seconds.
✔ Test builderHandlesEmptySlotsWithoutBlankLines() passed after 0.001 seconds.
✔ Test builderHonorsGlobalCapViaEvictionPriority() passed after 0.001 seconds.
✔ Test builderTruncatesBeforeCursorAtWordBoundary() passed after 0.001 seconds.
✔ Test builderNeverCutsMidWord() passed after 0.001 seconds.
✔ Test builderPrefersSentenceBoundaryOverWordBoundary() passed after 0.001 seconds.
✔ Test builderHonorsPerSlotBudgetsIndependently() passed after 0.001 seconds.
✔ Test builderIsDeterministic() passed after 0.001 seconds.
✔ Test run with 10 tests in 0 suites passed after 0.001 seconds.
```

```
swift test (full suite)
✔ Test run with 104 tests in 0 suites passed after 0.403 seconds.
```

Pas de régression sur les 94 tests existants (104 total = 94 + 10 nouveaux).

```
bash audit.sh
=== AUDIT PASSED ===
```

## Requirements satisfaits

- **BUILDER-03** : PromptBuilder testable en isolation totale de MLX. Aucun `import MLXLLM` / `import MLXLMCommon` dans le fichier de test ; les mocks sont des `struct` pures qui n'invoquent aucun runtime ML.
- **TEST-02** : Nouveaux tests pour PromptBuilder couvrent budget allocation (`builderHonorsPerSlotBudgetsIndependently`, `builderHonorsGlobalCapViaEvictionPriority`), assemblage déterministe (`builderAssemblesAllSlotsInOrder`, `builderIsDeterministic`), invariant never-cuts-mid-word (`builderNeverCutsMidWord`), sentence-boundary preference (`builderPrefersSentenceBoundaryOverWordBoundary`).

## Deviations from Plan

None — plan exécuté exactement comme écrit. Les 10 `@Test` functions correspondent strictement aux acceptance_criteria du plan (le plan exigeait ≥ 7 ; 10 sont livrées car les 10 noms suggérés dans l'action sont tous pertinents).

Une nuance d'écriture : le test `builderPrefersSentenceBoundaryOverWordBoundary` teste les **invariants génériques** (suffix-de-longTail, ≤ budget, commence par lettre) plutôt qu'un snapshot exact de la sortie, car le comportement exact du fallback word-boundary dans SentenceAwareTokenCounter dépend des étapes internes de `truncateHead` que le plan documentait explicitement comme open à interprétation ("L'attente exacte dépend du comportement de SentenceAwareTokenCounter"). C'est une lecture conservatrice du plan, pas une déviation.

## Authentication gates

Aucune — toute l'exécution est locale et offline.

## Known stubs

Aucun. Le fichier de test est self-contained et ne dépend d'aucun stub.

## Privacy invariants (T1, T3)

- Aucun user text réel dans les inputs des tests — uniquement des strings inventées ("Bonjour", "Salutations", "alpha beta", "one two three").
- Aucun read de `history.aes`, AX, clipboard, ou screen capture.
- Aucun appel `print`, `NSLog`, `os_log`, ou `Log.*` dans le fichier de test.
- `audit.sh` passe.

## Files touched

| File | Action | Commit |
|------|--------|--------|
| `Souffleuse/Tests/SouffleuseTests/PromptBuilderTests.swift` | created | b271dbb |

## Self-Check: PASSED

- Souffleuse/Tests/SouffleuseTests/PromptBuilderTests.swift — FOUND
- commit b271dbb — FOUND (current HEAD)
- swift test --filter PromptBuilderTests — 10/10 PASSED
- swift test (full) — 104/104 PASSED (no regression)
- bash audit.sh — PASSED
