# Cocotypist / Souffleuse

## What This Is

Souffleuse est un assistant de frappe local-LLM pour macOS (menu-bar accessory app, MLX, Gemma 3 1B). Il affiche un *ghost text* au caret dans n'importe quelle app via l'API d'accessibilité, et l'utilisateur peut accepter (Tab) ou rejeter (Esc). 100% on-device, pas de réseau au runtime. Cible : parité subjective avec Cotypist.

## Core Value

**Le ghost doit *sembler* aussi instantané et pertinent que Cotypist en usage quotidien.** Si le ghost arrive vite mais propose du générique ("Coucou !"), c'est un échec — la qualité contextuelle prime sur la vitesse brute.

## Requirements

### Validated

<!-- Inféré du code existant (commit 11f0c4f / 6ad70df, codebase map du 2026-05-24). Ces capacités sont en prod, testées, et constituent la baseline. -->

- ✓ **Ghost text au caret** dans toute app conforme AX (Mail, Safari, Notes, Slack, Messages, etc.) — `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift`
- ✓ **Streaming MLX** avec cancel-on-keystroke (generation counter) — `PredictorViewModel.swift`
- ✓ **Tab/Esc capture** via CGEventTap, actif uniquement quand un ghost est visible — `SouffleuseInput/KeyInterceptor.swift`
- ✓ **Partial accept** par chunks (mot-à-mot via `ChunkSplitter`) — `SouffleuseTyping/`
- ✓ **Memo cache** (FIFO 32 entrées) sur résultats de predict pour éliminer le flicker space→backspace — `PredictorViewModel.predictCache`
- ✓ **Undo-as-ghost** : after backspace, restore le suffix effacé comme ghost — `PredictorViewModel.swift` (cache_undo path)
- ✓ **N-gram personalization** : history-bias des logits MLX via `NgramLogitBias` + `ChainLogitProcessor` — `SouffleusePersonalization/`
- ✓ **Few-shot dynamique** depuis l'historique via Jaccard similarity — `SimilarHistoryRetrieval.swift`
- ✓ **Historique chiffré** AES-GCM avec clé en Keychain, ring buffer 200 entrées capé à 1 MB — `TypingHistoryStore.swift`
- ✓ **ContextEnricher v1** (flat string) : combine app/window, clipboard, screen-OCR en prefix TTL-cached 5s par bundleID — `SouffleuseContext/ContextEnricher.swift`
- ✓ **Custom Instructions** persistées (style/persona injecté dans le system prompt) — `PreferencesStore.swift`
- ✓ **Caret resolver** avec fallback OCR pour Chromium/Edge/Brave — `CaretResolver.swift`
- ✓ **Allowlist/blocklist** par bundle ID pour AX read et personalization recording
- ✓ **Multi-modèles** : catalogue Gemma 3 1B (PT et IT, 4-bit/8-bit/bf16) + Qwen 2.5 0.5B/1.5B
- ✓ **Détection de langue** (NaturalLanguage) + steering "reply in {lang}" pour contrer l'English drift
- ✓ **Privacy invariants** : `audit.sh` 6 checks, log JSONL event-only (5 champs whitelisted, jamais de texte user)
- ✓ **94 tests** verts (commit `6ad70df`)
- ✓ **Tactical pipeline tuning** (2026-05-24) : tick 80ms, debounce LLM 50ms, repetitionPenalty 1.0, maxWords 3, prefix-strip smart, comma soft-break

### Active

<!-- Milestone courant : Context Builder (cadrage redéfini le 2026-05-24). Hypothèse fondatrice à valider : le ghost junk vient du PROMPT pauvre, pas du modèle. Quand le champ est vide / message neuf, on n'a rien à donner au modèle → il invente du générique. Quand le champ contient déjà du texte, le prefix porte la situation → ça marche. → Le levier dominant n'est pas la latence (KV cache reuse) mais la qualité par enrichissement contextuel. -->

**Milestone : Context Builder token-aware**

Reframe complet par rapport aux notes initiales (`NEXT-MILESTONE-NOTES.md`) qui priorisaient l'infra d'inférence (KV cache). La latence n'est pas le bottleneck perçu — c'est la pertinence sur prefix pauvre.

- [ ] **CB-01** : PromptBuilder structuré remplace la flat-string concat dans `PredictorViewModel.predict()` (slots nommés, assemblage déterministe)
- [ ] **CB-02** : Budget token *par catégorie* (pas char), avec allocation explicite et eviction-policy quand un slot dépasse
- [ ] **CB-03** : Slot `beforeCursor` mieux budgeté (remplace le truncate dumb à 512 chars actuel)
- [ ] **CB-04** : Slot `afterCursor` capté via AX (`kAXSelectedTextRangeAttribute` + `kAXStringForRangeAttribute`) et injecté dans le prompt
- [ ] **CB-05** : Slot `fieldContext` — métadonnées AX du champ focal : placeholder, role/subrole, identifier, help, typingContext (au-delà de ce que `AppContextProbe` fait déjà au niveau app/window)
- [ ] **CB-06** : Slot `previousUserInputs` — refactor du few-shot Jaccard existant pour s'aligner sur l'API du builder (déjà fonctionnel, à recabler)
- [ ] **CB-07** : Slot `clipboardContext` opt-in — réutilise `ClipboardReader` existant avec blocklist, devient opt-in par préférence utilisateur
- [ ] **CB-08** : Slot `screenContext` OCR conditional — n'invoque `ScreenCapturer + VisionOCR` que si les autres slots sont sparse ET ScreenRecording permission active (aujourd'hui always-on dans le cycle d'enrichissement)
- [ ] **CB-09** : Audit léger inclus en Phase 1 — mode test/replay sur 10-20 scénarios "champ vide" pour comparer A/B sans-contexte vs avec-contexte. Valide l'hypothèse fondatrice avant de la diffuser à travers les phases suivantes.
- [ ] **CB-10** : Métriques TTFT/throughput préservées (le prompt enrichi NE DOIT PAS dégrader la latence en deçà de la baseline tactique d'aujourd'hui). Si dégradation → décision : ship quand même (qualité prime), ou prioriser KV cache milestone d'après.
- [ ] **CB-11** : Tests de régression sur les 94 tests existants + nouveaux tests pour PromptBuilder (budget allocation, eviction, snapshot des prompts assemblés)

**Critère de complétion (subjectif + soft latency) :**
1. **Scripted typing scenarios** (5-10 cas reproductibles : email reply, code comment, Slack message, champ vide nouveau message, etc.) — verdict "feels right" par scénario, comparé à Cotypist en side-by-side.
2. **TTFT envelope** : ghost apparaît sous ~80ms après dernier keystroke en flow typique (non-cold-start). Au-dessus = dégradation à investiguer.

### Out of Scope

<!-- Boundaries pour rester focus. Tout ce qui est ici devient candidat à un milestone suivant. -->

- **KV cache reuse / TokenizationCache / SequenceManager** — gain de latence, pas de qualité. Reportés au milestone d'après une fois que le Context Builder a validé l'hypothèse qualité.
- **Multi-candidate generation + scoring** (point #4 de l'analyse Cotypist) — gain qualitatif orthogonal au Context Builder, à traiter une fois l'infra prompt stable.
- **Filtres visuels** (`completionWidthExceedsMaximum`, etc.) — rendering concern, traitement séparé.
- **Apprentissage élargi avec signal négatif** (point #6 : record dismissed/typed-instead/ignored) — feedback loop, requires history schema changes; futur milestone.
- **Activation AX Electron complète** — Signal Desktop résiste malgré AXManualAccessibility + AXObserver. Connu, frustrant, mais non-bloquant pour la majorité des apps. Reporté.
- **XPC isolation 3-process** (UI / AXAgent / InferenceAgent) — `.planning/codebase/ARCHITECTURE.md` §5.bis mentionne ce target architectural. Pas le moment.
- **Sparkle / auto-update** — déjà noté dans codebase comme planned v1, pas dans ce milestone.

## Context

**Codebase :** Brownfield, mappé le 2026-05-24 (voir `.planning/codebase/*.md`). Swift 6 strict concurrency, SPM, 8 executables + 7 libraries + 1 test target. Single-process modular monolith, AppKit accessory app (LSUIElement = true).

**Stack :** MLX (`mlx-swift-examples` 2.29.1) sur Apple Silicon, Gemma 3 1B / Qwen 2.5 via `LLMModelFactory.shared.loadContainer`. Pas de réseau au runtime sauf téléchargement initial des modèles depuis HuggingFace.

**Référence concurrente : Cotypist.** Binary inspecté par le user. Mêmes modèles de base (Gemma 3 1B PT) en GGUF Q5_K_M via llama.cpp côté Cotypist, MLX 4-bit/8-bit côté nous. Modèle identique → différences perçues = pipeline. Cotypist expose dans son binaire : `TokenizationCache`, `TokenSequence`, `kvCache`, `sequenceManager`, `tokenBudget`/`maxPromptTokens`/`contentBudget`, `afterCursor`, `typingContext`/`domain`/`windowTitle`/`placeholderValue`/`help`/`accessibilityIdentifier`, `candidates`/`normalizedLogits`, `UserInputRecord` avec stockage des dismissed.

**Reframe stratégique (2026-05-24) :** Les notes initiales priorisaient l'infra KV cache (latence). Au moment du questionnaire `/gsd-new-project`, le user a réorienté vers la qualité : *le ghost junk vient du prompt pauvre, pas du modèle*. Test mental qui le prouve : dans un champ qui contient déjà du texte, le prefix porte le contexte et ça marche; dans un champ vide, on n'a rien à donner. afterCursor n'est qu'un sous-cas (édition milieu de texte) du même problème.

**Ce qui existe déjà :** L'arbre `SouffleuseContext/` contient déjà la plomberie : `AppContextProbe` (bundle + window title), `ClipboardReader` (avec blocklist), `ScreenCapturer + VisionOCR` (visible text), `ContextEnricher` (TTL 5s par bundleID, assemble en flat string `App X, window "…". Clipboard: …. On screen: …`). Le milestone n'est PAS "tout construire" — c'est refactor cette flat-string vers un builder structuré token-aware, ajouter les slots manquants (afterCursor + AX field metadata), et rendre l'OCR conditional.

**Personalization déjà branchée :** `TypingHistoryStore` (encrypted) + `NgramModel` + `SimilarHistoryRetrieval` (few-shot Jaccard) sont opérationnels. Le slot `previousUserInputs` du builder consommera cette source existante.

## Constraints

- **Tech stack** : Swift 6 strict concurrency, MLX (`MLXLLM` / `MLXLMCommon`), AppKit. Pas de changement de stack acceptable dans ce milestone.
- **Privacy invariants** : `audit.sh` doit continuer à passer (no print, no os_log interpolating user fields, log fields whitelisted). Toute nouvelle source de contexte ne franchit pas l'overlay process → AppContextProbe/Clipboard/AX restent in-process.
- **Performance** : la baseline TTFT du commit `6ad70df` est le plancher. Dégradation acceptable seulement si la qualité justifie ET si une voie de récupération existe (KV cache milestone suivant).
- **Compatibility** : macOS 14+ Apple Silicon. Pas de support Intel, pas de macOS 13.
- **No breakage** : 94 tests doivent rester verts. La pipeline existante (predict path) continue de fonctionner pendant la construction.
- **Migration strategy** : à décider en plan-phase 1 (feature flag vs in-place refactor). Question ouverte volontaire — dépend de combien le PromptBuilder peut être introduit graduellement.
- **MLX API dépendance** : `MLXLMCommon` impose son tokenizer et son interface de génération. Le PromptBuilder reste *au-dessus* — il produit le string final passé à `container.perform`. Pas de descente dans le runtime MLX ce milestone.
- **Pas de réseau** au runtime (sauf premier téléchargement du modèle). Le Context Builder n'introduit aucune nouvelle source réseau.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Milestone = Context Builder, pas Inference Infra | Hypothèse user (validée mentalement) : le ghost junk vient du prompt pauvre quand le champ est vide. La latence n'est pas le levier perçu. KV cache report au milestone suivant. | — Pending (à valider par CB-09 audit léger) |
| Budget par token, pas par char | Sentencepiece fragmente les mots (`'aimerais` → 3 tokens). Le truncate char actuel (512) est imprécis et empêche un budget équitable entre slots. | — Pending |
| Critère de parité = subjectif + soft latency | Pas de benchmark hard. Side-by-side daily-use vs Cotypist + envelope ~80ms TTFT. "I'll know it when I see it" tempéré par scénarios reproductibles. | — Pending |
| 3 slots actifs prioritaires + afterCursor + AX field metadata + OCR conditional | Ordre user : beforeCursor budgeté, afterCursor, AX field metadata, previous inputs, clipboard opt-in, OCR fallback. Tous les 6 dans ce milestone, dans cet ordre de priorité. | — Pending |
| Audit léger en Phase 1 (pas phase dédiée) | Le builder Phase 1 embarque un mode test/replay sur 10-20 scénarios. Économise une phase d'instrumentation pure tout en gardant la validation empirique. | — Pending |
| Migration strategy déférée au plan-phase 1 | Dépend de l'invasivité du refactor. Feature flag OU in-place, à trancher quand on aura touché le code. | — Pending |
| Out-of-scope KV/multi-candidate/visuals/negative-signal lockés | Discipline de scope : un milestone, un levier. KV cache vient APRÈS validation qualité (ordre logique : pas la peine d'optimiser un prompt qui ne marche pas). | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-05-24 after initialization*
