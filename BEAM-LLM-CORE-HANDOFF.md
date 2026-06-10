# Handoff — Beam comme cœur de génération LLM du ghost

> **But de ce document** : permettre à une session fraîche (après `/clear`) de reprendre
> et **construire** l'intégration sans rejouer toute l'investigation. Tout le raisonnement
> et toutes les preuves chiffrées sont ici. Lis-le en entier avant de coder.

## 0. TL;DR — ce qu'on construit

Faire du **beam contraint** (`BeamGhostEngine`, déjà écrit) **le seul chemin de
génération LLM** du ghost. Tout passe par lui. La « cascade » (greedy + gradient
d'engagement + plancher dico) cesse d'être le cœur LLM ; elle ne subsiste que comme
**couche instant pré-LLM** (rappel historique, lexique, cache, perso) — « la cascade
qui arrive si elle doit arriver ».

- **Mot en cours (≥1 lettre tapée)** → beam **avec `requiredPrefix`** (la contrainte =
  le gain prouvé), largeur **K=3**.
- **Après-espace (0 lettre, graine du mot suivant)** → beam en **décode libre K=1**
  (≡ greedy d'aujourd'hui, prouvé équivalent) **OU** on laisse la couche instant/recall
  gérer. Voir §4 (décision après-espace).
- **Couche consommation/reuse par-dessus** : HIT = consommer la branche par avancée de
  pointeur (**0 décode**), MISS = re-beam (debounce **court** + **hold-stale** anti-flicker).

Le tout **flag-gaté** et **réversible** : ce worktree/branche est jetable (rollback = le
supprimer, voir §8).

## 1. Pourquoi (les preuves — ne pas re-litiguer)

Tout vient d'une série d'evals sur `feat/cotypist-beam` (corpus OFF / perso OFF = couche
LLM pure, apples-to-apples). Modèle : `gemma-3-1b base/pt i1-Q5_K_M`.

### a) Intention mid-mot — le beam écrase (le gain principal)
`SouffleuseIntentionEval` (793 items, hit exact du mot voulu) :
| bucket | cascade hit@1 | beam hit@1 | beam hit@top3 |
|---|---|---|---|
| mid-mot 2 car | 16 % | **63 %** | 72 % |
| mid-mot 3 car | 31 % | **81 %** | 83 % |
| mid-mot 4 car | 50 % | **86 %** | 90 % |
| après-espace | 15 % | 14 % | 19 % |
| **GLOBAL** | 29 % | **64 %** | 69 % |
→ Le beam double la cascade en mid-mot. **Pourquoi** : `requiredPrefix` force à compléter
le mot courant ; le greedy de la cascade dérive/blanke (en partie par abstention voulue).

### b) Accord grammatical — le beam gagne
`SouffleuseCascadeVsBeamEval` (10 pièges) : cascade **4/10**, beam **9/10**
(« fiscal » pas « fiscaux », « importante » pas « importée »). La contrainte + le ranking
log-prob tombent juste.

### c) Écho / vide — ÉGALITÉ (la cascade a rattrapé)
Avec le plancher dico + le garde écho positionnel (déjà en prod sur `feat/midword-engagement`),
la cascade ne fuit **0** boucle et n'est vide qu'1 fois. Donc pas un argument pour le beam.

### d) Largeur K — **K=3 suffit, 9 inutile**
`SouffleuseBeamWidthSweepEval` (552 items mid-mot) :
| K | hit@1 | accord | cold-lat médiane |
|---|---|---|---|
| 1 | 70 % | 8/10 | **88 ms** |
| 2 | 72 % | 9/10 | 180 ms |
| **3** | **75 %** | 9/10 | **237 ms** |
| 4 | 75 % | 9/10 | 385 ms |
| 5 | 76 % | 9/10 | 432 ms |
| 7 | 76 % | 9/10 | 589 ms |
→ Plateau dès K=3. K≥4 paie la latence pour rien. **La contrainte fait l'essentiel
(K=1 = 70 %) ; K=3 = sweet spot.** Le K=9 « inféré » de Cotypist est surdimensionné.

### e) Après-espace — le beam N'aide PAS
`SouffleuseAfterSpaceEval` (214 items, K∈{1,2,3}) :
| | hit@1 | mots corrects | cohérence | cold-lat |
|---|---|---|---|---|
| cascade | 20 % | 0,31 | **95 %** | 244 ms |
| beam K=1 | 20 % | 0,31 | 94 % | 100 ms |
| beam K=3 | 21 % | 0,33 | **91 %** | 305 ms |
→ Égalité sur le mot/continuation, le beam **perd en cohérence** quand K monte, et **K ne
sert quasi à rien** ici (pas de contrainte pour trier). Beam K=1 ≈ cascade greedy (identique).
**Donc après-espace reste à la cascade/recall** — d'autant que son vrai atout là-bas (rappel
instant + perso) est **non crédité** dans ces evals (corpus OFF) : l'écart réel favorise la
cascade encore plus.

### f) Latence — viable
- Mid-mot beam K=3 à froid = **237 ms** — **sous** le cold-paint actuel de la cascade (313 ms).
- Amorti en frappe continue (`SouffleuseBeamAmortizedEval`) : **88 % de HIT à ~0 ms**,
  12 % de MISS. Le coût se concentre sur les MISS, pas étalé comme la cascade.

### g) Confirmation DYNAMIQUE de Cotypist (preuve, pas inférence)
Observation runtime : sur le ghost « Paris. », taper **P** (match) → « aris. » **sans**
`tokenize`/`decode`/mutation KV (= notre **HIT**, avancée de pointeur). Taper **X** (mismatch)
→ suffixe obsolète bref, retiré, **puis** `tokenize`+`decode`+`get_logits_ith`+`seq_rm`
(= notre **MISS**, re-beam). Le « ~900 ms » observé = **la latence de génération** de LEUR
beam lourd (≈ notre K=9 froid 765 ms), **PAS** un debounce délibéré. Notre regen K=3 = 237 ms.
→ Notre modèle reuse est fidèle. On vole le **hold-stale-during-regen** (anti-flicker), pas
un gros debounce.

## 2. Architecture cible

```
Frappe → poll/debounce (COURT, ~existant) → AXSnapshot → prefix
   │
   ├─ 1. COUCHE INSTANT (inchangée, « la cascade qui arrive ») :
   │      routeInstant → rappel historique L1 + lexique appris L0 + CompletionCache + perso n-gram
   │      → si hit : AFFICHÉ direct, zéro LLM. (C'est notre force après-espace.)
   │
   └─ 2. CŒUR LLM = BEAM (remplace greedy + engagement + plancher dico) :
          ├─ mot en cours (partial ≥1 lettre)  → BeamGhostEngine, requiredPrefix=partial, K=3
          └─ après-espace (partial vide)        → décision §4 (beam K=1 libre  OU  pas de LLM, recall only)
   │
   └─ 3. COUCHE CONSOMMATION / REUSE (par-dessus le beam) :
          ├─ HIT  : caractère tapé == 1ʳᵉ lettre du suffixe → avance pointeur, 0 décode, ~0 ms
          ├─ MISS : divergence → hold-stale bref + debounce court + re-beam (reserve KV)
          └─ post-filtres conservés : garde écho positionnel, singleLine, clause-cut, word-cap
```

**Ce qui DISPARAÎT du chemin LLM** : la passe greedy long-ghost « one-shot », le gradient
d'engagement (K=3 branches d'accord PLEIN/PRUDENT/ZÉRO), le plancher dico orienté-greedy.
Le beam les rend **obsolètes** (il fait mieux : intention + accord). On peut les laisser
dans le code derrière leur flag, mais le chemin par défaut sous `SOUFFLEUSE_BEAM_CORE` ne
les emprunte plus.

**Ce qui RESTE** : routeInstant (recall/lexique/cache), perso n-gram (en BIAIS du beam aussi —
voir §5), garde écho positionnel + filtres de sortie, la couche AX/overlay/Tab-Esc.

## 3. Le moteur existe déjà — à lire d'abord
- `Souffleuse/Sources/SouffleuseLlama/BeamGhostEngine.swift` — l'`actor` beam :
  contexte partagé, K séquences, `seq_cp`/`seq_rm`, batch multi-seq, ranking log-prob,
  `requiredPrefix`, top-K prune, **réserve + `advance(typedChar:)` (HIT/REFILL/MISS)**,
  `BeamConfig.cotypistDefault` (régler `maxSearchWidth=maxResultWidth=3`).
- `ModelRuntime.swift` (target app `Souffleuse`) — le cœur LLM ACTUEL à remplacer :
  `midWordEscalate`, la passe greedy long-ghost, `midWordEngagementResult`, `dicoFloorResult`.
- `PredictorViewModel.swift` — l'orchestration `@MainActor` : `predict()`, `routeInstant`
  (à GARDER), le streaming, le rolling refill (à remplacer par le reuse du beam), la
  freshness gate (déjà relâchée pour le consume inline — réutiliser cet esprit).
- Tous les evals `SouffleuseBeamEval`, `…AmortizedEval`, `…CascadeVsBeamEval`,
  `…IntentionEval`, `…BeamWidthSweepEval`, `…AfterSpaceEval` — preuves + harness réutilisables.

## 4. Décisions à acter (par la session fraîche, avec l'utilisateur si besoin)
1. **Après-espace** : l'utilisateur veut « tout passe par le beam, sauf la cascade si elle
   doit arriver ». Deux lectures cohérentes avec les preuves :
   - (A) après-espace = **beam K=1 libre** (≡ greedy, prouvé équivalent) → unification totale
     du chemin LLM par le beam ; le recall instant reste devant.
   - (B) après-espace = **pas de LLM beam**, on s'appuie sur routeInstant/recall + (si rien)
     un décode libre. Plus proche de « la cascade arrive ».
   → **Reco** : (A) pour l'unification (un seul moteur LLM), car beam K=1 après-espace =
   cascade greedy (mesuré identique) — donc aucune régression, et le code est unifié. La
   « cascade » au sens recall/perso reste la couche instant devant.
2. **Sort de l'engagement/plancher dico** : sous `SOUFFLEUSE_BEAM_CORE`, on NE les appelle
   plus (le beam couvre mieux). Garder leur code (flag) pour rollback A/B.
3. **Debounce** : COURT (garder l'existant, ~15-50 ms), **pas** 900 ms. + **hold-stale** :
   ne pas blanker le ghost à la divergence ; garder l'ancien affiché jusqu'à ce que le
   re-beam (≈237 ms) livre le neuf, puis swap.

## 5. Plan d'implémentation (étapes)
0. **Régler K=3** dans `BeamGhostEngine` (`BeamConfig` width 3) — confirmer via re-run rapide
   d'un eval que K=3 reproduit ~75 % intention.
1. **Brancher le beam dans `ModelRuntime`** : ajouter un chemin `generateGhostBeam(request:)`
   (gaté `SOUFFLEUSE_BEAM_CORE`) qui appelle `BeamGhostEngine`. Mid-mot → `requiredPrefix=partial`.
   Après-espace → décode libre (décision §4A). Conserver les post-filtres (garde écho, caps).
2. **Câbler le reuse dans `PredictorViewModel.predict()`** : maintenir une **réserve** de
   branches entre frappes ; sur frappe, tenter `advance(typedChar:)` (HIT → repaint instantané
   sans LLM) ; MISS → hold-stale + re-beam. Remplace le rolling refill actuel.
3. **Couper l'ancien cœur LLM** sous le flag : quand `SOUFFLEUSE_BEAM_CORE` est ON,
   `predict()` route vers le beam, PAS vers `midWordLongGhost`/engagement/plancher.
4. **Garder routeInstant intact** (recall/lexique/cache) devant le beam.
5. **Perso** : passer le biais n-gram appris au sampler du beam (le beam doit accepter une
   `personalizationStrength` / `setCorpus`, comme `LlamaEngine`). Vérifier que `BeamGhostEngine`
   peut consommer le même biais — sinon, l'ajouter (parité avec le souffle actuel).
6. **Flag + kill-switch** : `SOUFFLEUSE_BEAM_CORE` (ON = beam ; absent = comportement actuel
   byte-identique). Réversibilité totale.
7. **Build + run** : `make-app.sh` (Debug), lancer avec `SOUFFLEUSE_BEAM_CORE=1` +
   `MW_ENGAGEMENT`/`MW_ENG_PRUDENT` n'ont plus d'effet sous beam-core. Tester à la frappe réelle.

## 6. Garde-fous (NON négociables)
- Swift 6 strict concurrency ; types-frontière `Sendable` ; `BeamGhostEngine` reste `actor`.
- **MUST compile** ; **`swift test` reste vert (711)** ; **`audit.sh` passe** (pas de `print`
  hors evals, pas de string user via `Log`).
- **Additif/flag-gaté** : sans `SOUFFLEUSE_BEAM_CORE`, le chemin actuel est byte-identique.
- Commits propres, `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **NE PAS toucher** le build de l'utilisateur (`feat/midword-engagement`, worktree
  `cocotypist-midline`) tant que ce n'est pas validé. Cette branche est jetable.

## 7. Définition de « fini »
- `SOUFFLEUSE_BEAM_CORE=1` : le ghost mid-mot vient du beam (intention/accord visiblement
  meilleurs à la frappe), les HIT sont instantanés (consume), les MISS ~237 ms avec hold-stale
  (pas de blank), après-espace inchangé/équivalent, recall/perso intacts.
- Sans le flag : comportement actuel exact.
- Tests verts, audit OK. Un eval (réutiliser `IntentionEval`/amortized) confirme la parité
  des chiffres une fois câblé en prod (pas juste en banc).

## 8. ROLLBACK (sans douleur)
Cette intégration vit **uniquement** ici : worktree `/Users/gabrielwaltio/cocotypist-beam-core`,
branche `feat/beam-llm-core` (basée sur `feat/cotypist-beam`). Rien d'autre n'est touché.
- Annuler tout : `git worktree remove /Users/gabrielwaltio/cocotypist-beam-core --force` puis
  `git branch -D feat/beam-llm-core`. Le build de l'utilisateur (`feat/midword-engagement`)
  est intact.
- Le flag `SOUFFLEUSE_BEAM_CORE` rend aussi le rollback runtime trivial (ne pas le poser).

## 9. Reprise après /clear
Dans la session fraîche, dire :
> « Lis `/Users/gabrielwaltio/cocotypist-beam-core/BEAM-LLM-CORE-HANDOFF.md` et exécute le plan §5. »
Puis commencer par §5.0 (régler K=3) et §3 (lire `BeamGhostEngine.swift` + `ModelRuntime.swift`
+ `PredictorViewModel.swift`). Acter la décision §4 (après-espace = A, beam K=1 libre) avec
l'utilisateur si doute. Travailler dans CE worktree, sur CETTE branche.

---
*État au moment du handoff : moteur beam + reuse + 6 evals écrits et committés sur
`feat/cotypist-beam` (base de cette branche). Rien n'est câblé en prod. Le build live de
l'utilisateur (plancher dico + garde écho + engagement) est sur `feat/midword-engagement`,
intact.*
