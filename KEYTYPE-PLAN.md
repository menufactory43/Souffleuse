# Plan — Moteur de ghost « KeyType » pour Souffleuse

> Branche : `feat/keytype-ghost-engine`
> Objectif : meilleure personnalisation + **2× moins** de ghosts faux (mid-word) ou hors-contexte.
> Méthode : intégrer les bonnes idées de **KeyType** (clone open-source de Cotypist, archi quasi-jumelle), **épurer** le code existant, valider par **tests autonomes**, livrer **exécutable en live** derrière un flag.

---

## 0. État réel du code (point de départ, vérifié)

Ce qui existe DÉJÀ (à garder/améliorer, pas réinventer) :
- **Continuation base model** : `LlamaPromptBuilder.buildLlamaPrompt` — préface + `beforeCursor` trimmé en dernier. ✅ bon.
- **Few-shot perso ACTIF** (B-prompt 2026-05-30) : `PredictorViewModel.swift:774-808` injecte `SimilarHistoryRetrieval.rank` (Jaccard, top-3, scopé cluster). Le commentaire 744-759 (« n-gram only ») est périmé.
- **N-gram logit bias** : corpus accepté → `runtime.setCorpus` → biais par token (`LlamaEngine.swift`). ✅
- **Masque de healing mid-word** : `remainingHeal`/`healPieces`, scan full-vocab O(nVocab) (`LlamaEngine.swift:1192-1233`). ✅ (≈ `requiredPrefix` de KeyType).
- **KV reuse cross-frappe** : décode seulement le delta `promptTokens[lcp...]` (`LlamaEngine.swift:1115`). ✅
- **Génération** : greedy (`temperature 0`, `llama_sampler_init_greedy`), single-stream.
- **Gates** : field-hint gate (`PVM:591-597`), min-3-chars (`PVM:511`).
- **Filtres sortie** : `ChunkFilter` (markup, sentence-cut, word cap, anti-écho).

Écarts vs KeyType (ce qu'on va combler) :
1. **Pas de raison de suppression typée** → on optimise à l'aveugle (KeyType : `CompletionSuppressionReason`).
2. **Gate hors-contexte trop laxiste** : un simple placeholder laisse générer → fortune cookies.
3. **Pas de garde-fous mid-word POST-génération** : le healing produit des mots confidemment faux (`"informations pe"→"peinardes"`) sans dead-end/typo guard.
4. **Retrieval perso = Jaccard pur** : pas de mix récence/longueur, pas de pondération par acceptation (KeyType : 4 récents + 2 longs + 2 cross-app, budget tokens).
5. **Greedy single-stream** : pas de beam → le mid-word ne peut pas « hésiter » (`confirme`/`confirmer`/`confirmation`).

---

## 1. Métriques de succès (mesurables, sinon « 2× » est invérifiable)

Harness offline (Phase 0) qui mesure sur un corpus de cas figés :
- **`midword_wrong_rate`** : % de complétions mid-word qui ne matchent pas le mot cible.
- **`nocontext_generic_rate`** : % de ghosts émis sur préfixe pauvre qui sont génériques (fortune cookie).
- **`perso_hit_rate`** : % de cas où le ghost reprend un terme/registre du corpus user attendu.
- **`suppression_breakdown`** : ventilation par `CompletionSuppressionReason`.

Cible : `midword_wrong_rate` et `nocontext_generic_rate` **÷2** vs baseline, `perso_hit_rate` en hausse, **0 régression** sur les ~640 `@Test` + `audit.sh` vert.

### Baseline mesurée (2026-06-06, base Gemma 3 1B Q5_K_M, `MW_MEASURE MW_NO_HISTORY`)
- **Décision mid-word correcte** : greedy seul **11/23** · greedy+3 branches **16/23** (plafond prod actuel).
- **Justesse mot de tête** (18 déterminables, cap 8) : **14/18**. Les 4 échecs :
  - `pingo` (pingouin), `s` (sandwich) → healing collapse → **déjà cachés** par garde dico.
  - `imposa` (imposable) → arrêt prématuré (incomplet).
  - `aspiration` (aspirateur) → **mot valide mais FAUX, passe toutes les gardes** = le cas dur, n'est attrapable que par beam/désaccord.
- Latence : greedy ~265 ms · branche ~77-190 ms selon cap tokens.
- *Lecture* : le levier « ÷2 faux mid-word » est (a) durcir la suppression sur incomplet/ambigu (Phase 2) et (b) le beam déterministe scoré contexte (Phase 4). Les collapses sont déjà gérés.

---

## 2. Phases (chacune : buildable, tests verts, exécutable en live)

### Phase 0 — Harness & baseline *(préalable, bloquant)*
- Étendre `SouffleuseInjectionEval` / `SouffleuseCoherence` / `SouffleuseReplay` en un eval unifié `SouffleuseGhostEval` qui sort les 4 métriques ci-dessus sur un corpus versionné (`Tests/fixtures/ghost-cases.json` : préfixe, suffixe, contexte, mot/phrase cible, corpus perso simulé).
- Introduire l'enum **`CompletionSuppressionReason`** (typé : `emptyPrefix`, `noLexicalContext`, `midWordDeadEnd`, `midWordTypo`, `echoesPrefix`, `duplicatesSuffix`, `lowRelevance`, `unsafe`) loggé (compteur uniquement, audit-safe) + remonté à `GhostInspector`.
- **Capturer la BASELINE** (chiffres committés dans `KEYTYPE-PLAN.md`).
- *Tests autonomes* : workflow génère les fixtures + asserte que l'eval tourne.

### Phase 1 — Suppression hors-contexte (KeyType empty-prefix gate)
- Remplacer le field-hint gate (`PVM:591-597`) par un gate KeyType : **suppression si `beforeCursor` corrigé+trimmé n'a pas de signal lexical réel** (≥ N tokens non-stopword), *indépendamment* des hints faibles. Un placeholder seul ne déclenche plus de génération libre.
- Omettre l'app/window name du prompt sur contextes `code`/`terminal` (KeyType : biaise base model vers code/chiffres).
- *Cible* : `nocontext_generic_rate` ÷2.
- *Tests autonomes* : workflow → cas préfixe-vide / placeholder-seul / 1-mot.

### Phase 2 — Correctness mid-word (KeyType guard stack)
- Garder le masque de healing (déjà bon). **Ajouter les gardes POST-génération** de KeyType :
  - **dead-end stem guard** : un stem healé qui ne peut commencer aucun mot du dico (NSSpellChecker) → drop.
  - **typo guard** : healing qui produit un mot inconnu du dico user+système → drop.
  - **suffix-overlap salvage** : si la complétion percute le texte après-curseur, tronquer au chevauchement (≥3 chars réels) au lieu de jeter.
  - **sentence-boundary classifier** durci (décimales, abréviations, initiales) — cf. `DecodeStopPolicy`/`SentenceBoundaryClassifier`.
- *Cible* : `midword_wrong_rate` ÷2.
- *Tests autonomes* : workflow → corpus mid-word ambigu (`confir`, `inform`, `pe…`).

### Baseline perso (2026-06-06, synthétique, base Gemma 3 1B)
- `LLM hits` base **1/25** · bias **11/25** · **promo 21/25** · over-injection **0/33** · instant **25/25**.
- *Lecture* : la promotion n-gram est excellente MAIS exige `count ≥ 3` (chaque terme répété ×3 ici).
  En usage réel non-répétitif elle s'arme rarement → perso « morte » ressentie. La **retrieval few-shot
  marche dès count=1** → c'est le levier KeyType à renforcer (Phase 3), complémentaire à la promotion.
- *À valider* : `SouffleuseRealPersoEval` (récurrence sur vrai `history.db`) — confirme l'hypothèse count≥3.

### Phase 3 — Personnalisation (KeyType retrieval mix)
- Remplacer le retrieval Jaccard-pur par le **mix KeyType** dans `SimilarHistoryRetrieval` :
  `N récents même-cluster + M longs même-cluster + K récents cross-cluster`, dédupliqués, **budget en tokens** (pas en chars), **pondérés par `hasAcceptedCompletion`**.
- Garder le n-gram logit bias (complémentaire).
- (Optionnel) `ThresholdTuner` : nudge borné de la config de decode selon le taux d'acceptation local.
- *Cible* : `perso_hit_rate` en hausse, pas de pollution (vérif anti-greeting).
- *Tests autonomes* : workflow → corpus perso simulé + assert reprise de registre.

### Phase 4 — SÉLECTEUR mid-word log-prob (re-scopé après spike — PAS de KV-fork)

**SPIKE JETABLE (`MW_BEAM`, validé au modèle avant toute réécriture) :** le beam KV-fork
n'est **PAS nécessaire**. Avec candidats = `{greedy} ∪ {dico NSSpellChecker}` (k=0, zéro branche
stochastique) rerankés par `sequenceLogProb` per-token + stem-dedup + hide fragment-court :
**20/23** vs vote stochastique actuel **16/23** vs greedy **14/23**. Le cas dur `aspirateur`
(-3.68) vs `aspiration` (-16.43) est résolu DÉTERMINISTIQUEMENT. La diversité vient du DICO,
pas d'un beam. → On REMPLACE l'escalade stochastique-K par un sélecteur log-prob déterministe,
réutilisant `generate`/`WordCompleter`/`sequenceLogProb` (zéro nouveau primitif C, zéro fork KV).
Résidu : `imposable` (mauvais candidat dico gagne) + `gerard` (nom propre) — non-régressions.

Build prod = porter l'algo k=0 du spike dans `midWordEscalate` derrière `SOUFFLEUSE_GHOST_ENGINE=keytype`,
re-mesurer (cible 20/23), puis épurer l'escalade stochastique une fois confiant.

**SPIKE MARQUES (`MW_BRAND`, 20 cas mid-word, corpus seedé ×3) — le routage final :**
- OFF 7/20 · **PROMO (n-gram) 20/20** · LOGSEL (log-prob) **5/20** · **HYBRIDE 20/20**.
- Le log-prob DÉMOTE les termes appris (`Bina→Binaire`, `Fisc→Fiscalité`, `Géra→Gérald`) : toxique pour les marques.
- **Deux régimes, deux leviers** : mots communs → sélecteur log-prob (20/23) ; marques/noms propres → promotion n-gram (20/20).
- **Routage** : `si promotion atteste un terme appris → montrer le terme (ne PAS re-démoter par log-prob) ; sinon → sélecteur log-prob`. Déterministe, zéro fork KV.
- Bémol : PROMO 20/20 suppose le corpus seedé ×3 (récurrence). Marque tapée 1× → **Phase 3 (retrieval blendée count=1)** prend le relais. Leviers complémentaires.

---

#### (Archive) Hypothèse initiale — beam KV-fork, RÉFUTÉE par le spike

**Découverte (vérifiée dans le code) :** la prod fait DÉJÀ une escalade par branches pour le
mid-word (`ModelRuntime.midWordEscalate`, gaté par `midWordEscalationEnabled`) :
greedy → `midWordFastDecision` → K branches **stochastiques** (seeds distincts, `runEscalationPass`)
→ `midWordBranchDecision` (**vote d'accord** + garde dico `midWordValidExtends`). Donc l'idée
« plusieurs hypothèses » existe — mais en version coûteuse et heuristique.

**L'intégration KeyType = REMPLACER, pas ajouter** (c'est l'« épuration ») :
- Substituer les `K` appels `generate()` indépendants + vote par un **beam déterministe** scoré
  par **log-prob cumulé** + **rerank suffix-likelihood**, exécuté via **fork KV multi-séquences**
  (`llama_state_seq_get_data`/`set_data`, PAS `seq_cp`) → 1 prefill + decodes courts batchés au lieu
  de K re-prefills.
- Conserver tels quels : la garde dico (`midWordValidExtends`), le splice de continuation C1
  (`continuation(confirmedWord:fullLine:)`), les exit-guards (écho/langue). Le `requiredPrefix`
  par branche = ton masque de healing existant, porté dans le beam.
- Baseline mid-word à battre (mesurée, `MW_MEASURE`, base Gemma 3 1B, 23 cas) :
  **greedy seul 11/23 · +3 branches 16/23** décisions correctes. Cible beam : **≥ 16/23 avec ≤ 1
  branche de coût** (déterminisme + moins de decodes).
- Derrière `SOUFFLEUSE_GHOST_ENGINE=keytype` (escalade stochastique reste le défaut tant que l'A/B n'a pas tranché).
- *Tests autonomes* : `MW_MEASURE` (justesse) + déterminisme (même contexte → même ghost) + parité TTFT.

### Phase 5 — Build live & bascule A/B
- Flag d'env + toggle Preferences pour basculer ancien/nouveau moteur sans rebuild.
- `make-app.sh` → `.app` signé ; `GhostInspector` affiche les `SuppressionReason` en live.
- *Livrable* : tu lances l'app, tu tapes, tu compares.

---

## 3. Orchestration par workflows

Chaque phase = un workflow multi-agents :
- **implement** (1 agent par fichier-cible, isolés) → **test-gen** (génère les `@Test`) → **verify** (agent adverse : relit le diff, cherche les régressions concurrence/privacy/audit) → **build+test** (`swift build` + `swift test` ciblé).
- Phase 0 d'abord (baseline), puis 1→2→3 (gains sûrs, peu risqués), Phase 4 en dernier (moteur), Phase 5 = packaging.

## 4. Garde-fous (invariants projet)
- `audit.sh` vert (pas de `print`/`NSLog`, log 5 champs, store chiffré non lu hors store).
- Swift 6 strict concurrency : types-frontière `Sendable`, inférence sur `Task` détaché annulable.
- Pas de réseau runtime. TTFT : baseline `6ad70df` = plancher (Phase 4 derrière flag, donc plancher préservé par défaut).
- ~640 `@Test` verts à chaque phase.

## 5. Ce que je NE fais PAS sans ton feu vert
- Toucher au moteur d'inférence (Phase 4) avant que Phases 0-3 soient vertes et que tu aies vu le gain en live.
- Supprimer du code « épuré » sans l'avoir mis derrière flag d'abord.
