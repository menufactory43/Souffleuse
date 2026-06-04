<!-- GSD:project-start source:PROJECT.md -->
## Project

**Cocotypist / Souffleuse** — assistant de frappe local-LLM pour macOS (menu-bar accessory app, `LSUIElement`). Affiche un *ghost text* au caret dans n'importe quelle app via l'API d'accessibilité ; l'utilisateur accepte (Tab) ou rejette (Esc). 100% on-device, pas de réseau au runtime. Cible : parité subjective avec Cotypist.

**Core Value :** le ghost doit *sembler* aussi instantané ET pertinent que Cotypist en usage quotidien. Ghost rapide mais générique ("Coucou !") = échec. La qualité contextuelle prime sur la vitesse brute.

Au-delà du ghost, l'app fait aussi : **traduction** (HUD, langue cible par conversation), **relecture par ton** (reformulation FR→FR selon l'app), et un **carnet d'usage** (frappes épargnées · temps gagné).

### Constraints
- **Stack figée** : Swift 6 strict concurrency, AppKit/SwiftUI. Le ghost est généré par **llama.cpp** (GGUF Metal vendoré, `SouffleuseLlama`/`CLlama`) — moteur de génération unique. **MLX** (`MLXLLM`/`MLXLMCommon`) est conservé en support (tokenizer n-gram / personalisation), plus optionnel. Pas de changement de stack.
- **Privacy invariants** : `audit.sh` doit passer — no `print`/`NSLog`, no `os_log` interpolant des champs user, log fields whitelistés `{ts,level,module,event,count}`, store chiffré (`history.db`) référencé hors `TypingHistoryStore`/`HistoryViewerWindow` interdit. Toute source de contexte reste in-process.
- **Performance** : la baseline TTFT du commit `6ad70df` est le plancher ; dégradation tolérée seulement si la qualité le justifie et qu'une voie de récupération existe.
- **Compatibility** : macOS 14+ Apple Silicon uniquement. Pas d'Intel, pas de macOS 13.
- **No breakage** : la suite (~640 `@Test`) reste verte.
- **Pas de réseau** au runtime, sauf téléchargement initial des modèles (HF / in-app `ModelDownloadManager`).
<!-- GSD:project-end -->

<!-- GSD:stack-start source:codebase/STACK.md -->
## Technology Stack

- **Langage** : Swift 6 (tools-version `6.3`, `swiftLanguageModes: [.v6]`) partout. Bash pour `Souffleuse/make-app.sh` + `Souffleuse/audit.sh`.
- **Runtime** : macOS 14+ Apple Silicon. SPM (`Souffleuse/Package.swift`), lockfile présent (`Package.resolved`). Version app : **0.3.0** (`Resources/Info.plist`, `LSUIElement = true`, bundle `app.cocotypist.Souffleuse`).
- **Inférence** :
  - **llama.cpp** = **seule voie de génération du ghost** (Metal GGUF). Lib vendorée sous `Souffleuse/vendor/llama/` (headers `CLlama` systemLibrary ; dylibs `libllama`/`libggml*` Metal/CPU/BLAS liés via rpath, copiés dans `Contents/Frameworks` par `make-app.sh`). Wrappée par `SouffleuseLlama` (`LlamaEngine`, `GpuGate`). GGUF par défaut : `GGUFModelOption.defaultID` (Gemma 3 1B **base/pt**, continuation brute gauche→droite — **PAS un modèle FIM** : aucun token `<|fim_*|>`, le souffle est une simple continuation du préfixe ; le texte après le curseur n'est pas injecté dans le prompt. Le sampler FIM de llama.cpp existe dans la lib vendorée mais n'est pas utilisé).
  - **MLX** (`MLX`/`MLXLLM`/`MLXLMCommon`) — via `mlx-swift-examples` (≥ 2.0.0, seule dépendance SPM directe). Container désormais **optionnel** : sert le tokenizer n-gram / `rebuildPersonalization`, pas le ghost.
  - Orchestré par `ModelRuntime` (`Sources/Souffleuse/ModelRuntime.swift`) : possède `llamaEngine` (génération) + container MLX optionnel ; `canGenerate == llamaReady`.
- **Frameworks Apple** : AppKit, SwiftUI, Observation (`@Observable`), CoreGraphics (`CGEventTap`), ApplicationServices (`AXUIElement*`), ScreenCaptureKit, Vision (OCR), NaturalLanguage (détection langue), CryptoKit + Security/Keychain, IOKit.hid, Foundation.
- **Chiffrement au repos** : `CSQLCipher` (SQLCipher + CommonCrypto, sans OpenSSL) → `history.db`. Clé AES-256 en Keychain via `KeychainKey`.
- **Tests** : Swift Testing / XCTest, target `SouffleuseTests` (`Tests/SouffleuseTests/`).
- **Build/sign** : `make-app.sh` → `.app` ; `codesign` cert hard-codé `A798891AB1B0A8C0B46AFADBD95094BABF680037` (overridable `SIGN_IDENTITY`), stable pour préserver le TCC entre rebuilds.

### Configuration & fichiers
- `Package.swift` — 11 libs + 14 exécutables + 1 test target.
- `~/Library/Application Support/Souffleuse/` : `history.db` (SQLCipher, ring buffer accepts), `allowlist.json` (overrides par app), `clipboard-blocklist.txt`.
- `~/Library/Logs/Souffleuse.log` — JSONL, rotation à 1 MB ×3.
- `UserDefaults.standard` — clés typées dans `PreferencesStore.K` (modèle, langues OCR, longueur, perso, ton, langue cible, partial-accept…).
- Env (dev) : `SOUFFLEUSE_PREDICT_LOG` (trace `/tmp`, exclu de l'audit), `SOUFFLEUSE_MODEL`, `SOUFFLEUSE_PENALTY`, `SOUFFLEUSE_CONTEXT`, `SIGN_IDENTITY`.

### Platform requirements
- Xcode toolchain Swift 6.3 ; cert Apple Development (ou `SIGN_IDENTITY=-`) ; `jq` optionnel pour `audit.sh`.
- TCC : Accessibility, Apple Events, Screen Recording (capture OCR opt-in, off par défaut).
- ~0.4–1.5 GB disque par modèle (Gemma 3 1B, Qwen 2.5 0.5B/1.5B ; GGUF + `mlx-community/*`).
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

### Naming
- Un type principal par fichier, nom = type. Tests en miroir avec suffixe `Tests`.
- `UpperCamelCase` types, `lowerCamelCase` membres, booléens en prédicats (`isEmpty`, `holdUntilComplete`).
- Seuils/constantes en `static` sur le type (`TypoDetector.maxLevenshtein`, `EnrichedContext.clipboardCap`).
- Chaque concern = un target SPM préfixé `Souffleuse*` ; le target app est `Souffleuse`. Probes/benches préfixés aussi.
- Clés string centralisées dans un `private enum K` (jamais inline). Protocoles-rôles en `-ing` (`OCRCaretLocating`).

### Code style
- Indentation 4 espaces, trailing commas multi-lignes, accolade sur la même ligne, pas de double ligne vide.
- `public` réservé à l'API cross-module ; sinon package-default/`internal`. `private`/`fileprivate`/`private(set)` agressifs.
- Tout type-frontière est explicitement `Sendable`. `@unchecked Sendable` seulement avec synchro interne (`TypoDetector`, `LogWriter`). Closures cross-isolation `@Sendable`.
- `@ObservationIgnored` sur le stored state qui ne doit pas déclencher la vue.

### Concurrency
- `@MainActor` pour tout ce qui touche AppKit (`SouffleuseAppDelegate`, `PredictorViewModel`, overlays, stores `@Observable`).
- `actor` pour les services stateful de fond (`NgramModel`, `TypingHistoryStore`, `ContextEnricher`).
- `nonisolated` pour lookups purs. `await` chaîné ; pas de `DispatchQueue` neuf (sauf `LogWriter`/`AXClient`, intentionnels). `Task {}` fire-and-forget tracké explicitement. `CheckedContinuation` réservé aux test doubles.

### Documentation & logging
- `///` sur tout public + propriétés non-évidentes ; le rationale, pas la signature. `//` inline dense, explique le *pourquoi*, cite souvent l'app qui a motivé le code (Brave, Notes, Intercom, Cotypist). `// MARK: -` pour découper.
- **Log privacy-by-typesystem** : `Log.info/warn/error` prennent un event `StaticString` (littéral compile-time) — aucun string user ne peut atteindre le writer. Seuls 5 champs sérialisés.

### Error handling
- Throw seulement à la frontière IO basse (Keychain, ScreenCapture, SQLCipher). Couches hautes : optionnels ou fallback silencieux. Enums `Error` par sous-système.
- Erreurs non re-levées à travers les actors → log event + nil/défaut. IO non-critique en `try?`. Décryptage corrompu → reset à vide. Jamais de force-unwrap sur retour AX.

### Persistence
- JSON `[.prettyPrinted, .sortedKeys]` pour config lisible (allowlist). SQLCipher pour l'historique sensible. `UserDefaults` pour les prefs. Struct on-disk top-level avec `version: Int`.

### Module & test design
- Graphe de dépendances explicite par target ; pas de barrel/re-export ; resources seulement dans `SouffleuseOverlay`.
- Init prod par défaut + overload test seam (`TypingHistoryStore(testKey:)`). Test doubles à côté des tests.

### Function design & localisation
- Fonctions ~< 30 lignes, split en helpers `private`/`static` testables. Labels descriptifs, valeurs par défaut, tuples nommés.
- UI **français-first** inline (pas de `.strings`/`NSLocalizedString`).
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

### Patterns clés
- **Polling debouncé** : `Timer` 80 ms dans `SouffleuseAppDelegate.tick()` ; predict gaté par debounce (~50 ms) après stabilisation du préfixe.
- **Cancel-on-keystroke streaming** : chaque préfixe incrémente un generation counter et annule le `Task` en vol → chunks périmés droppés.
- **MainActor-centré + actors sérialisés** ailleurs. Inférence sur `Task` détaché, annulable.
- **Caches** : `CompletionCache`/`predictCache` (FIFO) absorbent le cycle "espace → backspace" ; **KV cache** réutilisé entre frappes (`KVCacheHolder`, voir tests `KVCacheReuse/Bypass`).
- **Per-bundle calibration** : caret rect, font, OCR fallback, enregistrement perso — tout keyé sur le bundle ID de l'app focus.
- **Moteur déchargé à l'idle** (chaud pendant la session, libéré sinon).

### Layers (`Souffleuse/Sources/`)
- **`Souffleuse`** (exécutable) — orchestration AppKit, toutes les UI SwiftUI/NSWindow, prefs. Dépend de tous les autres + MLX + Llama.
- **`SouffleuseCore`** — cœur décisionnel : `SuggestionPolicy`(+Tuning), `Tone`, `ChunkFilter`, `OutputFilter`, `TermSurvivalGuard`, `CurtnessHeuristic`, `LlamaPromptBuilder`, `GemmaChatPrompt`, `DownloadableModel`, `PredictRequest`, `GenerationToken`. Dépend de Log/Typing/Personalization.
- **`SouffleusePrompt`** — construction de prompt sous budget de tokens : `PromptBuilder`, `PromptBudget`, `PromptSlot`, `BuiltPrompt`, `TokenCounting`/`MemoizingTokenCounter`.
- **`SouffleuseLlama`** — wrapper llama.cpp (`LlamaEngine`, `GpuGate`) sur `CLlama` ; moteur de génération du ghost.
- **`SouffleuseAX`** — toutes les interactions `AXUIElement` (`AXClient` sur queue privée, `AXSnapshot`, `AXFontInfo`), observers Chromium.
- **`SouffleuseContext`** — assemble le préfixe : `ContextEnricher` (actor, TTL-cache par bundle), `AppContextProbe`, `ClipboardReader` (gated par blocklist), `ScreenCapturer`, `VisionOCR`, `OCRCaretLocator`.
- **`SouffleuseInput`** — `KeyInterceptor` (`CGEventTap` Tab/Esc, actif seulement quand une suggestion s'affiche).
- **`SouffleuseOverlay`** — `OverlayWindow` (ghost gris), `PresenceIndicatorWindow`, `CaretEstimator` (NSPanel non-activants).
- **`SouffleusePersonalization`** — `TypingHistoryStore` (actor, SQLCipher), `KeychainKey`, n-gram (`NgramModel/Builder/Snapshot`, `NgramLogitBias`, `ChainLogitProcessor`), `SimilarHistoryRetrieval`.
- **`SouffleuseTyping`** — utilitaires non-LLM : `EmojiExpander`, `TypoDetector`, `WordCompleter`, `ChunkSplitter`.
- **`SouffleuseLog`** — `Log` facade + `LogWriter` (JSONL, rotation). Utilisé partout.
- **`CSQLCipher`** — SQLCipher embarqué (CommonCrypto).

### Composants app (`Sources/Souffleuse/`)
- `SouffleuseAppDelegate` — orchestrateur : poll timer, AX → enricher → predictor → overlay, Tab/Esc, onboarding, hotkeys, menu-bar (icône vivante).
- `PredictorViewModel` — cycle de vie modèle, debounce, génération streaming, cache, n-gram bias, troncature phrase/mot.
- `ModelRuntime` — possède le `LlamaEngine` (génération) + container MLX optionnel (support n-gram). `ModelDownloadManager` (download in-app), `GGUFModelOption`.
- `GenerationPlanner` — planification de la requête de génération.
- `ToneStore` + relecture de ton ; `TranslationRuntime` + `ConversationTargetStore` (langue cible par conversation) ; `UsageLedger` (carnet d'usage).
- `GhostInspector`/`GhostInspectorWindow` — observabilité live du Relevance Gate (dev).
- `CaretResolver`, `CompletionCache`, `KVCacheHolder`, `HUDAnchorStore`, `MLXTokenCounter`, `AllowlistConfig`, `PreferencesStore`, fenêtres (Preferences/Onboarding/CustomInstructions/HistoryViewer).

### Probes & evals (exécutables dev)
`SouffleuseAXProbe`, `SouffleuseContextProbe`, `SouffleuseLlamaProbe`, `SouffleuseBench` (TTFT MLX), `SouffleuseCoherence`, `SouffleuseEnrichmentBench`, `SouffleuseOCRAblation`, `SouffleuseMidwordEval`, `SouffleuseRecallEval`, `SouffleuseInjectionEval`, `SouffleuseToneBench`, `SouffleuseTranslateBench`, `SouffleuseReplay`, `SouffleuseCorpusSeed`. (Benches `print`-heavy → hors `SHIPPING_DIRS` de `audit.sh`.)

### Abstractions clés
- `AXSnapshot` — snapshot read-only immuable de "ce qui est focus" ; seul type à franchir la frontière AX (`Sendable`, `Equatable`, prédicats `isTextElement`/`isSecureField`).
- `EnrichedContext` — préfixe contextuel optionnel en prose simple (pas de `[Label:]` que les base models imiteraient), caps par source.
- `PredictorViewModel` — toutes les concerns LLM derrière une frontière `@MainActor @Observable`.
- `TypingHistoryStore` — ring buffer chiffré (SQLCipher), API `load/append/allEntries/clear`, seam `init(testKey:)`.
- `Log` — facade enum + event `StaticString` (invariant privacy par le type system).

### Contraintes architecturales
- **Threading** : main thread = AppKit/AppDelegate/overlays/`PredictorViewModel`/`PreferencesStore`. `AXClient` sérialise sur queue privée. `ContextEnricher`/`TypingHistoryStore` = actors. Inférence sur `Task` détaché, annulée par frappe.
- **Swift 6 strict concurrency** ; tous les types-frontière `Sendable`.
- **Sandbox : aucune** (l'API Accessibility l'exige) → distribution hors MAS, Developer ID + notarisé.
- **Réseau** : restreint au download des modèles ; ni télémétrie, ni ping, ni Sparkle (v1). `audit.sh` l'enforce sur les `SHIPPING_DIRS`.
- **Mono-processus** pour l'instant ; le split 3-process (UI/AXAgent/InferenceAgent) reste un objectif (`ARCHITECTURE.md` §5.bis).

### Anti-patterns (interdits)
Logger un string user · lire `history.db`/`history.aes` hors `TypingHistoryStore`+`HistoryViewerWindow` · générer sans cancel-on-keystroke · toucher `NSPanel`/overlay hors main · enregistrer dans l'historique depuis un bundle bloqué.
<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->
## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->



<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
