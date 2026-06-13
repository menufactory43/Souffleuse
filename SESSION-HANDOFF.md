# Souffleuse — Handoff de session (2026-05-30)

## Projet
Assistant de frappe local-LLM macOS (menu-bar, French-first). Métaphore : la
**souffleuse de théâtre** qui glisse les répliques depuis l'ombre. Ghost inline
au caret via Accessibility, Tab/→/Esc. 100% on-device. Cible : parité Cotypist.
**Utilisateur = Gabriel, support client Waltio dans Intercom via Brave.**

## Stack & fichiers clés
- **Moteur ghost** : `Sources/SouffleuseLlama/LlamaEngine.swift` (llama.cpp + Metal), modèle **base/pt Gemma 3 1B GGUF**, continuation brute (pas de chat-template).
- `Sources/Souffleuse/ModelRuntime.swift` : `generate()`→`generateLlama()` (LIVE). `generateMLX()` = MORT. MLX gardé seulement pour le tokenizer n-gram.
- `Sources/Souffleuse/PredictorViewModel.swift` : cascade `predict()`, construit `PredictRequest`. `@MainActor`, le predict tourne dans un `Task { [weak self] }` (hoister les valeurs avant — voir `proseExamplesPool`).
- `Sources/SouffleuseCore/SuggestionPolicy.swift` : `routeInstant` (routage L0/L1/L2), `onLLMChunk` (gate de sortie). `SuggestionPolicy+Tuning.swift` = tous les seuils/flags.
- `Sources/SouffleuseCore/LlamaPromptBuilder.swift` : `buildLlamaPrompt(...)` (assemble le prompt brut).
- `Sources/SouffleusePersonalization/SimilarHistoryRetrieval.swift` : retrieval few-shot Jaccard (`rank`, `buildExamplesBlock`).
- `Sources/SouffleusePersonalization/TypingHistoryStore.swift` : corpus SQLCipher chiffré (`~/Library/Application Support/Souffleuse/history.db`), enum `EntrySource{.prose,.accept}`, `importPendingIfNeeded()` (lit `corpus-import.json`).
- `Sources/SouffleuseInput/KeyInterceptor.swift` : CGEventTap, enum `Key{tab,esc,acceptAll}` + `AcceptAllKey` (presets) + `setAcceptAllKey`.
- `Sources/Souffleuse/{PreferencesWindow,PreferencesStore,SouffleuseAppDelegate}.swift`.
- **Benches dev** (cibles SwiftPM, utilisent `print()`, hors audit) : `SouffleuseMidwordEval`, `SouffleuseRecallEval`, `SouffleuseInjectionEval`, `SouffleuseOCRAblation`, `SouffleuseCorpusSeed` (import exports Intercom), `SouffleuseReplay`.

## Build / run / test
```
cd Souffleuse
swift build --product Souffleuse          # build app
swift test                                # 427 tests doivent rester verts
bash audit.sh                             # invariant privacy — DOIT passer
./make-app.sh                             # construit le .app (xcodebuild + codesign)
open build/Build/Products/Debug/Souffleuse.app
```
GGUF partagé avec Cotypist : `~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf` (env `SOUFFLEUSE_GGUF` pour les benches).

## Invariants à NE PAS casser
- **`audit.sh`** : pas de `print(`/`NSLog`/`os_log` interpolant du texte user dans les cibles SHIPPING ; champs de log whitelistés `{ts,level,module,event,count}` ; `history.db` lu seulement dans Personalization + HistoryViewer. (Les benches dev échappent à l'audit.)
- **427 tests verts** (le CLAUDE.md dit 94 = périmé).
- Tout `Log.info(.x, "event", count: n)` : event = `StaticString` littéral, jamais de texte user.

## Ce qui a été fait cette session (branche `feat/ghost-v2`, poussée sur github.com/meffysto/cocotypist-llama)
- **83b7003 + tag v0.2.0** — Injection few-shot (B-prompt) + capture prose + override mid-word.
- **48b41d0** — Touche "tout accepter" configurable.
- **88d23b4** — UI voix théâtre + dé-jargonisée.

Détails :
- **Solution A (capture prose)** : `recordRawInputIfAllowed` découplé (gate `personalizationEnabled` seul, plus `storeWithoutAccepted`). Champ `EntrySource` ajouté au schéma. Outil `SouffleuseCorpusSeed` importe les exports Intercom de "Gabriel from Waltio" → `corpus-import.json` → l'app importe au lancement en `.prose` (bundleID tagué `com.intercom.conversations`).
- **Solution C (mid-word)** : WordCompleter mid-word OFF par défaut (`wordCompleterEnabledRuntime`) ; `Tuning.midWordL2OverridesWordComplete=true` + branche `replacesMidWordWordComplete` dans `onLLMChunk` (un L2 healed correct écrase un L0 faux affiché).
- **B-prompt injection** : `SimilarHistoryRetrieval.rank(.prose)` → `buildExamplesBlock` → `buildLlamaPrompt(examples:)`. PVM hoiste `proseExamplesPool` (self faible dans le Task), logue `ghost_examples_injected count:N`. **PAS de filtre bundleID** (seed=intercom-natif vs live=brave → un filtre dur n'injecterait rien). `Tuning.examplesInjectionEnabled=true`.
- **Touche accept-all** : `AcceptAllKey` presets (→ défaut, ⌘→, ↩, ⇧⇥, désactivé), `PreferencesStore.acceptAllKey`, `AppDelegate.performFullAccept()`, Picker dans Préférences. Vérifie les modificateurs (⇧⇥ ≠ Tab).
- **UI** : voix "théâtre subtil", zéro jargon (souffle/voix/plume/en scène), carte À propos refaite (titre serif). Onglets : Enrichissement→Contexte, Allowlist→Par application.

## Findings mesurés (importants)
- **Le rappel L1 ne généralise PAS** : 0% sur held-out de la vraie prose (phrases support sur mesure). Il ne sert qu'au quasi-verbatim.
- **La pertinence "comme Cotypist" sur une phrase neuve = LLM stylé par l'injection**, pas le recall.
- **Cotypist = RAG, zéro fine-tuning** (table `user_inputs`, suffix array, `previousUserInputs`, scopé par domaine). Preuve binaire.
- Corpus = bouts de mots (confirmé par l'utilisateur dans l'UI) car les chemins d'accept stockaient des suffixes de ghost ; corrigé par la capture prose.

## Caveats ouverts
- **Latence de l'injection non mesurée** : elle ajoute des tokens au prompt + change le préfixe par retrieval → risque de casser la réutilisation KV-cache (LCP) de llama.cpp → TTFT. À mesurer (le core value veut "instantané").
- Injection prouvée sur **3 cas de bench seulement** (sous-dimensionné).
- **B-scope (scope par domaine/bundleID)** pas fait — nécessaire avant que le corpus devienne gros/cross-domaine.
- `feat/ghost-v2` pas mergée dans `main`.

## PROCHAINE FEATURE décidée : "autre chose" que le ghost
**Cible = #2 Brouillon de réponse depuis le contexte** (rédige une réponse support complète en lisant le message à l'écran, dans le style de l'utilisateur), **en démarrant par la fondation partagée qui EST déjà #1 (reformuler la sélection)**.

### Plan court
**Phase 0 — Fondation : modèle instruct à la demande**
- Charger un GGUF **instruct** (`gemma-3-1b-it`) en plus du base (le ghost garde son base). Option : 2e instance `LlamaEngine` dédiée aux actions, OU lazy-load + déchargement à l'idle. *Décision : 2e LlamaEngine paresseux, chargé au 1er usage.*
- Prompting instruct = **chat-template Gemma** (`<start_of_turn>user … <end_of_turn><start_of_turn>model`). `LlamaEngine.generate` prend un prompt brut → construire la string chat-template côté appelant.

**Phase 1 — #1 Reformuler la sélection (foundation testable, faible risque)**
- Nouveau raccourci configurable (réutiliser le pattern `AcceptAllKey`/KeyInterceptor).
- Lire la **sélection** via AX (ajouter une lecture de texte sélectionné à `AXClient` — aujourd'hui il lit l'élément focus + caret).
- Petit panneau flottant (NSPanel) près de la sélection : actions **Raccourcir / Formaliser / Corriger / Traduire / Adoucir** → stream instruct → **remplace la sélection** via AX inject. Accepter/Annuler.
- "La souffleuse reprend la réplique."

**Phase 2 — #2 Brouillon de réponse**
- Raccourci → `ContextEnricher` capture le message à l'écran (OCR/clipboard, déjà bâti) + `SimilarHistoryRetrieval` (style).
- Prompt instruct : *"Message reçu : <OCR>. Mon style : <exemples corpus>. Rédige une réponse."*
- Stream le brouillon dans un **panneau éditable** → "Insérer" (AX) ou "Copier". Réutilise le panneau de Phase 1.
- "La tirade."

### Risques/nouveautés à prévoir
- **AX** : lire la sélection + remplacer la sélection (nouvelle capacité, à ajouter proprement à `AXClient`).
- **UI** : un panneau flottant streaming (nouveau, mais l'overlay existe comme référence).
- **Mémoire** : 2 modèles 1B chargés — mesurer ; sinon lazy-load/unload de l'instruct.
- Tout le reste (contexte, corpus, retrieval, key interceptor, prompt) se réutilise.

### Démarrage conseillé
Commencer Phase 0 + Phase 1 (donne un #1 utilisable vite), via une nouvelle branche `feat/instruct-actions` à partir de `feat/ghost-v2`. Garder `audit.sh` vert + 427 tests.
