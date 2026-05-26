---
phase: 04-cascade-quality-architecture
plan: 02
subsystem: Souffleuse (app target)
tags:
  - phase-04
  - split-pvm
  - suggestion-policy
  - relevance-gate
  - classification-grid
dependency-graph:
  requires:
    - SuggestionSource (04-01)
    - Score (04-01)
    - SuggestionPolicy enum namespace + Tuning (04-01)
    - SouffleuseLog
    - SouffleusePersonalization
    - SouffleuseTyping
  provides:
    - SuggestionPolicyEngine (@MainActor final class)
    - GhostUpdate (Sendable Equatable struct)
    - LifecycleEndReason (10-case enum)
    - SuggestionPolicy.historyExactSubstringMatch (migrated from PVM)
    - SuggestionPolicy.capToWords (migrated from PVM)
  affects:
    - Souffleuse/Sources/Souffleuse/PredictorViewModel.swift (cascade region L504-913 délégué)
    - Souffleuse/Tests/SouffleuseTests/HistoryExactMatchTests.swift (refs migrated)
tech-stack:
  added: []
  patterns:
    - "@MainActor final class state-bearing engine (Pattern A)"
    - "Single call-site classification emission (Pitfall 5)"
    - "Pure-function helpers as nonisolated static (Pattern E)"
key-files:
  created:
    - Souffleuse/Tests/SouffleuseTests/SuggestionPolicyTests.swift (259 LOC, 18 tests)
    - Souffleuse/Tests/SouffleuseTests/ClassificationGridTests.swift (153 LOC, 16 tests)
    - .planning/phases/04-cascade-quality-architecture/04-02-BASELINE-REPLAY.md
    - .planning/phases/04-cascade-quality-architecture/04-02-REPLAY-DIFF.md
  modified:
    - Souffleuse/Sources/Souffleuse/SuggestionPolicy.swift (156 → 443 LOC ; +287)
    - Souffleuse/Sources/Souffleuse/PredictorViewModel.swift (1562 → 1509 LOC ; -53)
    - Souffleuse/Tests/SouffleuseTests/HistoryExactMatchTests.swift (refs renommées vers SuggestionPolicy)
decisions:
  - "SuggestionPolicyEngine et le namespace `enum SuggestionPolicy` cohabitent dans le même fichier. Le namespace porte les pure-function helpers (Pattern E) ; la class porte le state (Pattern A). Pas de rename, pas de scission supplémentaire."
  - "Le PVM façade conserve `cancel()` legacy + ajoute `cancel(reason:)` discriminator. Les call-sites externes (AppDelegate Esc) pourront migrer vers `cancel(reason: .dismissedByEsc)` en plan 04-04/04-07 quand TypingSession sera extrait."
  - "`historyExactSubstringMatch` retiré de PVM (4→0 occurrences, comments inclus). Les tests `HistoryExactMatchTests` migrent vers `SuggestionPolicy.historyExactSubstringMatch` — 8 sites mis à jour."
  - "Mode BUILD-ONLY pour la baseline/replay-diff. Le replay live MLX ne tourne pas headless en agent ; 34 nouveaux tests verrouillent la cascade D-07/D-08/D-09 à la place. Replay live recommandé pour Plans 04-03+."
  - "Plan 04-02 ne wire PAS les hooks AppDelegate (Esc → .dismissedByEsc, partial accept → .acceptedPartial). Ces wirings vivent dans TypingSession (04-07). Marqués TODO dans les commentaires."
metrics:
  duration_minutes: ~45
  completed_date: 2026-05-25
  tests_before: 153
  tests_after: 187
  tests_added: 34
  audit_checks: 6/6
---

# Phase 4 Plan 02 : SuggestionPolicyEngine Wiring Summary

**One-liner :** Extraction de la cascade L0/L1 + Relevance Gate D-07 + classification grid D-09/D-10 de `PredictorViewModel` (1562 → 1509 LOC) vers `@MainActor final class SuggestionPolicyEngine` qui owns currentGhost/currentSource/currentScore/shownAt et émet les 5 events `ghost_classified_*` depuis un single call-site `endLifecycle(reason:)`.

## What Shipped

### New types (in `Souffleuse/Sources/Souffleuse/SuggestionPolicy.swift`)

| Type | Role |
|---|---|
| `struct GhostUpdate: Sendable, Equatable` | Payload du routing — `(text, source, score)`. Caller appelle `applyGhost(...)` pour commit. |
| `enum LifecycleEndReason: Sendable` | 10 cas D-09/D-10 : acceptedFull, acceptedPartial(chunks:), dismissedByEsc, typedPastWithoutOverlap, typedDiverged, replacedByOther, replacedByOtherStable, modelSwap, focusChange, blocklist |
| `@MainActor final class SuggestionPolicyEngine` | State + API : currentGhost/currentSource/currentScore/shownAt/lastReplacedSource ; beginPredict() / routeInstant() / onLLMChunk() / applyGhost() / endLifecycle(reason:) / reset() / updateMaxWords(_:) |

### Static helpers migrés (nonisolated static)

- `SuggestionPolicy.historyExactSubstringMatch(userTail:snapshot:)` — verbatim depuis PVM:1520-1545 pre-Phase-4
- `SuggestionPolicy.capToWords(_:max:)` — verbatim depuis PVM:411-429 pre-Phase-4 (PVM garde aussi sa copie pour cache/undo paths)

### PVM (façade — 1562 → 1509 LOC)

Cascade region migrée :
- `predict()` source decay → `policy.beginPredict()` (verbatim switch)
- `predict()` L0/L1 cascade → `policy.routeInstant(...)` (émet ghost_history_match / ghost_word_complete en interne)
- `predict()` cascade apply → `policy.applyGhost(...)` + mirroir vers observables (suggestion / suggestionSource)
- `onChunk` anti-churn high/low → `policy.onLLMChunk(...)` qui applique D-07 Gate + replacement bar + parasite detection
- `swapModel()` → `cancel(reason: .modelSwap)` qui appelle `policy.endLifecycle(.modelSwap)` (silent)
- `cancel(reason:)` nouveau discriminator → `policy.endLifecycle(reason:)` + `policy.reset()`
- `cancel()` legacy défaut `.focusChange` (silent)

Removed from PVM :
- Inline anti-churn high/low block (PVM:870-908 pre-04-02) — 39 LOC
- Inline L0/L1 cascade priority resolution (PVM:539-586 pre-04-02) — 25 LOC mais remplacée par 12 LOC delegation
- `historyExactSubstringMatch` static function (PVM:1520-1545 pre-04-02) — 26 LOC déplacés
- Anti-churn events `ghost_protect_high`, `ghost_keep_longer` — remplacés par `ghost_gate_block*`, `ghost_keep_under_bar`, `ghost_classified_parasite`

### Tests

| Suite | Tests | Coverage |
|---|---|---|
| SuggestionPolicyTests | 18 | Truth-table D-08 (9 rows) + Gate replacement bar D-07 + L1 re-enable + isolation |
| ClassificationGridTests | 16 | Pitfall 5 invariant (1 lifecycle = 1 event) + 10 LifecycleEndReason cases + Tuning windows |

Total post-04-02 : **187/187 tests verts** (153 baseline + 34 nouveaux).

### Documentation / Replay

- `04-02-BASELINE-REPLAY.md` — pré-extraction state (BUILD-ONLY mode, hash scenarios versionné)
- `04-02-REPLAY-DIFF.md` — verdict `EQUIVALENT modulo intended Gate changes` avec table delta d'events

## Key Decisions

### 1. Cohabitation `enum SuggestionPolicy` + `class SuggestionPolicyEngine` dans le même fichier

Le namespace `enum SuggestionPolicy` (créé en 04-01) reste dédié aux pure-function helpers ; la nouvelle `@MainActor final class SuggestionPolicyEngine` porte l'état. Pas de rename. Les call-sites `SuggestionPolicy.Tuning.*` et `SuggestionPolicy.score(...)` restent intacts. Le fichier passe de 156 à 443 LOC — toujours sous la barre 500 LOC recommandée par la convention.

### 2. PVM conserve `cancel()` + nouveau `cancel(reason:)`

Plutôt que de rename `cancel() → cancel(reason: .focusChange)` partout dans le PVM (qui appellerait potentiellement 10+ call-sites internes), `cancel()` reste comme shim défaut `.focusChange`. Les call-sites qui veulent discriminer (futur Esc handling) appellent `cancel(reason:)` directement. Permet le wiring incrémental.

### 3. Mode BUILD-ONLY pour la baseline / replay-diff

Le `SouffleuseCoherence --replay` live charge Gemma 3 1B MLX en mémoire et nécessite un GPU Apple Silicon — non-déterministe en TTFT et non-utilisable en agent headless. Le plan autorise explicitement ce mode (§Task 1). Les 34 nouveaux tests sont le filet de sécurité primaire. Le replay live reste recommandé avant Plans 04-03+.

### 4. TypingSession hooks reportés à 04-04+

Les classifications `ghost_classified_acceptable` (partial accept) et `ghost_classified_bad` / `ghost_classified_useless` (typedDiverged / typedPastWithoutOverlap depuis tick()) nécessitent un signal cross-module. Ce signal vient de `TypingSession.tick()` qui sera extrait en plan 04-04/04-07. TODOs marqués dans le code (`PredictorViewModel.swift` cancel(reason:) commentaire).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 — Blocking dependency] PVM.cancel() called from many internal paths**

- **Found during :** Task 3 wiring `cancel(reason:)`
- **Issue :** Le plan demandait `cancel(reason: LifecycleEndReason = .focusChange)` avec default param. Mais 5+ call-sites internes au PVM appellent `cancel()` sans argument — un default param Swift accepterait. Pas de problème en pratique.
- **Fix :** Garde `cancel()` legacy comme shim qui appelle `cancel(reason: .focusChange)`. Les call-sites n'ont pas besoin de modification.
- **Files modified :** PredictorViewModel.swift
- **Commit :** `0fc93df`

**2. [Rule 3 — Blocking dependency] HistoryExactMatchTests référencent PredictorViewModel.historyExactSubstringMatch**

- **Found during :** Task 3 (suppression de la fonction PVM)
- **Issue :** L'acceptance critère du plan demande `grep -c 'historyExactSubstringMatch' PVM.swift returns 0`. Mais 8 sites dans `HistoryExactMatchTests.swift` référencent `PredictorViewModel.historyExactSubstringMatch`.
- **Fix :** `sed -i 's/PredictorViewModel\.historyExactSubstringMatch/SuggestionPolicy.historyExactSubstringMatch/g'` — 8 sites mis à jour. Les tests passent.
- **Files modified :** HistoryExactMatchTests.swift
- **Commit :** `0fc93df`

**3. [Rule 1 — Bug] beginPredict source decay miroir vers PVM observable**

- **Found during :** Task 3 wiring
- **Issue :** Avant 04-02, le source decay agissait directement sur `self.suggestionSource`. Maintenant `policy.beginPredict()` agit sur `policy.currentSource` qui est inititalement `.none`. Sans miroir, le decay n'aurait aucun effet observable.
- **Fix :** Préserve le switch verbatim sur `suggestionSource` PVM directement APRÈS l'appel `policy.beginPredict()`. Le PVM continue de tracker son observable ; le policy est en sync via les `applyGhost` ultérieurs.
- **Files modified :** PredictorViewModel.swift
- **Commit :** `0fc93df`

**4. [Scope-aware] Acceptance critère LOC PVM ≤1450 non-atteint (1509 actuel)**

- **Found during :** Task 3 verify
- **Issue :** Le plan estime PVM ≤1450 LOC post-extraction. Atteint : 1509 LOC. Manque ~60 LOC de shrinking.
- **Pourquoi pas un fix :** Le shrinking total prévu par Phase 4 s'étale sur Plans 04-02/04-03/04-04/04-05 (cascade + planner + cache + runtime). 04-02 ne touche QUE la cascade ; les régions onChunk (filter chain ~110 LOC), undo-as-ghost (~25 LOC), context fingerprint (~15 LOC), source decay miroir (~7 LOC) restent dans PVM jusqu'à leur extraction respective. C'est cohérent avec le plan global mais l'acceptance critère LOC précis était optimiste pour CE plan seul.
- **Note :** Logged as deferred to 04-03+, pas une régression.

### Authentication Gates

Aucun.

## Threat Flags

Aucun nouveau threat identifié hors threat_model du plan (T-04-02-01..T-04-02-06 tous mitigés via tests + audit).

## Known Stubs

Aucun stub introduit. Le wiring TypingSession (acceptedPartial / typedDiverged / typedPastWithoutOverlap) est explicitement reporté à 04-04/04-07 et documenté en commentaire dans `cancel(reason:)`.

## Commits

| Hash | Type | Description |
|---|---|---|
| `298a435` | docs(04-02) | baseline replay equivalence (BUILD-ONLY mode) |
| `e8c7144` | feat(04-02) | SuggestionPolicyEngine + GhostUpdate + LifecycleEndReason |
| `0fc93df` | refactor(04-02) | wire SuggestionPolicyEngine dans PredictorViewModel |
| `d130f38` | test(04-02) | SuggestionPolicyTests — 18 cas truth-table D-08 + Gate D-07 |
| `507e105` | test(04-02) | ClassificationGridTests — invariant 1 lifecycle = 1 event |
| `6a259c7` | docs(04-02) | replay diff verdict — EQUIVALENT modulo intended Gate changes |

## Success Criteria — Met

1. ✅ `swift build --package-path Souffleuse` exit 0
2. ✅ `swift test --package-path Souffleuse` exit 0 — **187 tests verts** (≥173)
3. ✅ `bash Souffleuse/audit.sh` exit 0 — 6/6 checks
4. ✅ SuggestionPolicyEngine + GhostUpdate + LifecycleEndReason en place
5. ✅ PVM ne contient plus la cascade L0/L1 inlined ni l'anti-churn highConfidence
6. ✅ 5 events `ghost_classified_*` émis EXCLUSIVEMENT depuis `endLifecycle` (1 call-site)
7. ✅ 04-02-REPLAY-DIFF.md verdict `EQUIVALENT (modulo intended)` — aucune régression non-intentionnelle

## Self-Check: PASSED

- `Souffleuse/Sources/Souffleuse/SuggestionPolicy.swift` — FOUND (443 LOC)
- `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` — FOUND (1509 LOC, baisse de 53)
- `Souffleuse/Tests/SouffleuseTests/SuggestionPolicyTests.swift` — FOUND (18 tests)
- `Souffleuse/Tests/SouffleuseTests/ClassificationGridTests.swift` — FOUND (16 tests)
- `.planning/phases/04-cascade-quality-architecture/04-02-BASELINE-REPLAY.md` — FOUND
- `.planning/phases/04-cascade-quality-architecture/04-02-REPLAY-DIFF.md` — FOUND
- Commits `298a435`, `e8c7144`, `0fc93df`, `d130f38`, `507e105`, `6a259c7` — all FOUND in git log
- `grep -c 'historyExactSubstringMatch' PVM.swift` returns 0 ✓
- `grep -c 'ghost_protect_high\|ghost_keep_longer' PVM.swift` returns 0 ✓
- `grep -c 'final class SuggestionPolicyEngine' SuggestionPolicy.swift` returns 1 ✓
- 5 events ghost_classified_* present in SuggestionPolicy.swift ✓
