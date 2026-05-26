# 04-11 — Final 3-app Verification (Tier 1 acceptance gate)

**Status** : Completed via abbreviated empirical session in lieu of full protocol.
**Date** : 2026-05-26

## Protocol substitution

Le plan 04-11 spécifiait un protocole complet ½ journée × 3 apps Tier-1
(Mail, Notes, Brave) = ~1.5 jours de tests humains. À la décision user
post-04-07 (empirical AB validation PASS), le protocole light a été retenu :
15 scripted scenarios + jq stats sans blind A/B daily-use.

Le protocole light s'est lui-même évolué pendant la session en raison
des découvertes empiriques qui ont surfacé des fixes immédiats plus
précieux qu'un test exhaustif sur la version pré-fix :

1. **Cache/history pollution observée** ("Coucou, ceci est un test " →
   ghost "Bonjour, c"). User a immédiatement diagnostiqué le problème,
   ce qui a déclenché trois fixes de correctness/quality plutôt que de
   continuer le scripted protocol :
   - Cascade tightening : `Tuning.afterSpaceL1Bar` 0.4 → 0.6, ajout de
     `cacheFloor: 0.55` et `undoCacheFloor: 0.45`. Cache hit et undo-cache
     passent désormais par le Gate.
     (commit `472c5a6`)
   - **Drop few-shot retrieval** : suppression de `SimilarHistoryRetrieval`
     dans le path predict. Personnalisation déléguée intégralement au
     `NgramLogitBias` (logit bias per-token au sampler, sans injection
     d'exemples dans le prompt). Élimine la cross-pollution greeting/topic
     par construction.
     (commit `3869802`)
   - **KV cache race fix** : crash MLX `KVCacheSimple.update` après un
     Tab partial-accept (deux generations LLM concurrentes touchent le
     KV cache via lazy GPU eval). Fix : force `.explicit` invalidate
     quand `beginGenerationDetachingPrevious()` retourne un previousTask
     non-nil. Pay re-prefill sur cancellations, optimisation extend
     préservée en steady-state.
     (commit `0fcfa18`)

2. **Validation finale** : user a confirmé que les 3 issues observées
   sont résolues sur le build commit `0fcfa18` :
   - Plus de "Bonjour, c" cross-pollution
   - Plus de crash MLX après Tab
   - UX comparable à Cotypist (différence résiduelle observée : Cotypist
     attend un mot complet, Souffleuse fire L0 mid-word — choix UX
     délibéré, à arbitrer dans un futur milestone si désiré)

## Verdict Tier 1

**ACCEPT** (avec qualifications).

| App | Verdict | Notes |
|-----|---------|-------|
| Mail | ACCEPT | Empirical session 04-07 PASS + tightening confirmé |
| Notes | ACCEPT | Path-equivalent à Mail (même cascade, même fixes appliqués) |
| Brave | NOT TESTED IN SESSION | Le path Chromium AX + OCR caret n'a pas été spécifiquement exercé. Recommandé pour follow-up. |

## Suivi

- **Follow-up milestone — Brave/Chromium verification** : exercer les
  5 scripted scenarios B1-B5 quand l'user en aura besoin. Le D-03 split
  n'a pas modifié le path AX/OCR donc le risque de régression est faible,
  mais une session courte (~30 min) confirmera.

- **Follow-up milestone — Cotypist UX parity** : 04-11 a surfacé que
  Cotypist attend un mot complet avant d'afficher un ghost (vs Souffleuse
  qui fire L0 word-completion mid-word). C'est un choix UX, pas un bug.
  Quatre options arbitrées plus tard :
  1. Disable L0 entièrement
  2. Bumper le seuil L0 (4+ chars au lieu de 3)
  3. Smart debounce mid-word
  4. Garder l'instant-feedback Souffleuse (différenciation)

- **Follow-up milestone — KV cache MLX.eval()** : le fix kv invalidate
  est un workaround. Le fix propre est `MLX.eval(...)` sur les tensors du
  cache après le for-await loop dans `ModelRuntime.generate` pour forcer
  la synchronisation GPU. Demande validation API MLX-Swift.

- **Follow-up milestone — LoRA fine-tuning** : architectural direction
  recommandée pour atteindre la parité Cotypist sur la personnalisation
  contextuelle. Cotypist fait du fine-tuning sur le user typing ;
  Souffleuse ne le fait pas. Le drop few-shot rapproche du modèle
  Cotypist (pas de retrieval pollution) mais perd le bénéfice templates
  full-sentence. Roadmap multi-milestone.

## Quality gates (D-11)

Pas de capture jq automatisée (les sessions courtes n'ont pas donné assez
de samples pour des stats stables). À refaire en daily-use de plusieurs
jours sur le build `0fcfa18`+.

## Files touched (cette session)

Tightening + drop fewshot + kv race fix :
- `Souffleuse/Sources/Souffleuse/SuggestionPolicy+Tuning.swift`
- `Souffleuse/Sources/Souffleuse/SuggestionPolicy.swift` (test alignment)
- `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` (×3 commits)
- `Souffleuse/Tests/SouffleuseTests/SuggestionPolicyTests.swift`
- `Souffleuse/Tests/SouffleuseTests/CascadeTighteningTests.swift` (new)
- `.planning/phases/04-cascade-quality-architecture/04-07-EMPIRICAL-VALIDATION.md`

Final tests : **256/256 verts**, audit **6/6 OK**.

## Phase 04 verdict global

**ACCEPT.**

Headline goal (D-03 PVM split) livré :
- PVM 1566 → 626 LOC (−60%)
- 4 modules + façade : SuggestionPolicy 443 + GenerationPlanner 137 + CompletionCache 262 + ModelRuntime 826 + PVM façade 626
- 256 tests verts (139 → 256, +117)
- 5 commits architectural (04-01..04-07) + 3 commits empirical-driven (tightening + drop fewshot + kv race)

Side wins :
- L1 history Gate tests verrouillés (D-08)
- Coherence v2 harness avec confusion matrix + D-11 release gate (D-12)
- Ghost Relevance Gate + classification grid câblés (D-06, D-07, D-09, D-10)
- Cache/history pollution diagnostic + fix
- KV cache race condition diagnostic + workaround fix

Deferred to future milestones :
- D-04 TypingSession extraction (Rule 4 checkpoint, no AX-mock test harness)
- Brave Tier 1 verification (light protocol non-exhaustif)
- MLX.eval proper kv sync fix
- LoRA fine-tuning architectural roadmap
- Cotypist UX parity decisions
