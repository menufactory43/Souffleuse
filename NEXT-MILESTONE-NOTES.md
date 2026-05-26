# Notes de session — préparer le prochain milestone

Document de handoff pour reprendre le travail après un `/clear`. Lire avant de lancer `/gsd-new-project`.

---

## Contexte de session (2026-05-23 → 2026-05-24)

Comparaison rapprochée entre **Souffleuse** (nous) et **Cotypist** (référence concurrente).
Même modèle de base : Gemma 3 1B PT. Cotypist en GGUF Q5_K_M via llama.cpp, nous en MLX 4-bit/8-bit. Modèle identique → différences perçues = pipeline, pas modèle.

User a inspecté le binaire Cotypist et identifié des composants clés qu'on n'a pas.

---

## Ce qu'on a shippé aujourd'hui (commit 6ad70df)

Améliorations tactiques, déjà commitées sur main, pas encore pushées :

- **Pipeline performance** : tick 200ms→80ms, debounce LLM 150ms→50ms, LLM input cap 2048→512 chars, maxWords default 6→3
- **Qualité ghost** : repetitionPenalty 1.15→1.0 (débloque in-context word reuse), smart prefix-strip (récupère ghost quand modèle re-écho le prefix), comma soft-break dans truncation, 8-bit Gemma 3 1B PT ajouté au catalogue
- **Bug undo-as-ghost** : `cancel()` ne wipe plus le cache (préserve undo après Tab/typo/live-consume), `clearPredictCache()` ajouté aux vrais context breaks, `capToWords` helper appliqué aux paths cache_hit et cache_undo
- **Electron/Chromium AX (partiel)** : AXManualAccessibility + AXEnhancedUserInterface + AXObserver no-op enregistré par bundle. Marche partiellement : Slack répond après activation, Signal Desktop résiste. À reprendre.
- **Outillage** : SouffleuseBench refait pour benchmark A/B quantization (4bit/8bit/bf16), debug logger env-gated `SOUFFLEUSE_PREDICT_LOG` qui trace les décisions predict() et les gates AX dans /tmp/souffleuse-*.log
- **Tests** : 94/94 passent, regression coverage du bug undo (cancelPreservesPredictCache, cancelClearsActiveSuggestion)

État : appelé "parité Cotypist niveau tactique". Les vrais gaps structurels restent.

---

## Gap analysis Cotypist vs Souffleuse (analyse binaire user)

User a identifié dans le binaire Cotypist :

### 1. Infrastructure d'inférence incrémentale
- `TokenizationCache` — cache des tokens déjà calculés
- `TokenSequence` — objet structuré qui tracke ce qui est encodé
- `reuseThreshold` — décision active "reuse vs re-encode"
- `kvCache` — état KV transformeur préservé entre predicts
- `sequenceManager` — orchestrateur

→ Cotypist évite de retokeniser et recalculer tout le prompt à chaque keystroke. Nous, chaque predict re-tokenise + recalcule TOUTES les K/V de zéro.

### 2. Prompt budget par catégorie
- `tokenBudget`, `maxPromptTokens`, `contentBudget`

→ Cotypist alloue son budget de tokens (pas chars) par catégorie de contexte. Nous, on truncate dumb à 512 chars sans compter les tokens ni catégoriser.

### 3. Contexte enrichi (ce qu'on ne capture pas)
- `afterCursor` (texte après le caret) — on ne le voit même pas
- `typingContext, domain, windowTitle, placeholderValue, help, accessibilityIdentifier` — métadata du champ AX qu'on ignore
- `previousUserInputsTokens` — réinjection de textes précédents (pas juste les Tab acceptés)

### 4. Génération multi-candidats + scoring
- `candidates, normalizedLogits, averageLogprob, totalLogprob`
- `constraint, requiredPrefix` (constrained decoding)

→ Cotypist génère K candidats, les score, choisit le meilleur. Nous on est greedy top-1.

### 5. Filtres visuels
- `completionWidthExceedsMaximum, prefixWidthExceedsMaximum, maxSearchWidth, maxResultWidth`

→ Refus de ghosts trop longs en rendu visuel, pas juste word count.

### 6. Apprentissage élargi
- `UserInputRecord, hasAcceptedCompletion, Store Inputs Without Accepted Completions`

→ Cotypist apprend depuis TOUS les inputs (accepted, dismissed, typed-instead, ignored). Nous, uniquement les Tab acceptés.

---

## Scope du milestone proposé

Nom : **Infrastructure d'inférence : réutilisation KV/tokens + budget de prompt (parité Cotypist)**

Focus serré sur les points 1 et 2 de l'analyse ci-dessus, parce que :
- Ce sont les fondations qui permettent les autres améliorations (multi-candidate, etc.) sans débordement
- Sans budget propre, ajouter du contexte (afterCursor, field metadata) va déborder le modèle
- Sans KV reuse, la vitesse plafonne (~150ms TTFT incompressibles)

**Livrables candidats** :

1. **Token-aware prompt builder** avec allocation par catégorie (`currentPrefix`, `recentInputs`, `fieldContext`, `personalizationFewShot`)
2. **TokenizationCache** pour les préfixes répétés/extensions
3. **KV cache reuse** via TokenIterator custom + state passing entre predicts
4. **SequenceManager** orchestrateur qui décide reuse vs re-encode selon le delta de prefix
5. **Métriques** TTFT/throughput avant/après pour valider les gains

**Hors scope de ce milestone (pour ne pas se disperser)** :
- Multi-candidate generation (point 4) → autre milestone
- afterCursor + field metadata (point 3) → autre milestone (mais le budget en step 1 doit prévoir ces slots)
- Apprentissage élargi avec signal négatif (point 6) → autre milestone
- Filtres visuels (point 5) → autre milestone

---

## Décisions en suspens à trancher dans la phase discuss

1. **Audit d'abord ?** Faire une phase préalable d'instrumentation pour mesurer 50 cas réels et valider que les gains attendus seront effectifs, ou attaquer directement le chantier ?
   - User a oscillé. À retrancher.

2. **MLX API compatible avec KV state ?** À vérifier dès le début si MLXLMCommon expose le KVCache de manière utilisable, ou si on doit descendre encore plus bas dans la stack MLX.

3. **Bench tooling** : SouffleuseBench actuel fait du A/B inter-modèles. Adapter pour mesurer aussi TTFT incrémental (delta entre keystrokes consécutifs) ou créer un nouvel outil.

4. **Migration progressive** : le pipeline actuel doit continuer à fonctionner pendant qu'on construit la nouvelle infra. Feature flag ? Branche ? À décider en planning.

---

## Limitations connues à mentionner dans PROJECT.md

- **Signal Desktop** : refuse de s'activer en AX malgré AXManualAccessibility + AXObserver. Cotypist y arrive (mécanisme exact non identifié). Slack/autres Electron répondent une fois activés. À reprendre dans un futur milestone.
- **Cache** : aujourd'hui on a `predictCache` (suggestions output, 32 entrées FIFO). Pas de KV cache, pas de tokenization cache. C'est précisément ce que le milestone va adresser.

---

## Fichiers de référence pour `/gsd-new-project`

- `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` — cœur du pipeline LLM (predict, cache, onChunk)
- `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift` — tick loop, live-consume, debounce
- `Souffleuse/Sources/SouffleuseBench/Bench.swift` — bench tooling A/B
- `Souffleuse/Sources/SouffleuseAX/AXClient.swift` — accessibilité, activation Chromium tentée
- `Souffleuse/Sources/SouffleusePersonalization/` — NgramModel, NgramLogitBias, SimilarHistoryRetrieval
- `Souffleuse/Tests/SouffleuseTests/` — 94 tests, à jour
- Dernier commit : `6ad70df` (non poussé)

---

## Prochaine action

`/clear` puis `/gsd-new-project` (le brownfield setup détectera le code existant).
Donner ce fichier comme contexte initial au questionnaire.
Le premier milestone configuré sera celui décrit ci-dessus.
