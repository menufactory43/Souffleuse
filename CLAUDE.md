<!-- GSD:project-start source:PROJECT.md -->
## Project

**Cocotypist / Souffleuse**

Souffleuse est un assistant de frappe local-LLM pour macOS (menu-bar accessory app, MLX, Gemma 3 1B). Il affiche un *ghost text* au caret dans n'importe quelle app via l'API d'accessibilité, et l'utilisateur peut accepter (Tab) ou rejeter (Esc). 100% on-device, pas de réseau au runtime. Cible : parité subjective avec Cotypist.

**Core Value:** **Le ghost doit *sembler* aussi instantané et pertinent que Cotypist en usage quotidien.** Si le ghost arrive vite mais propose du générique ("Coucou !"), c'est un échec — la qualité contextuelle prime sur la vitesse brute.

### Constraints

- **Tech stack** : Swift 6 strict concurrency, MLX (`MLXLLM` / `MLXLMCommon`), AppKit. Pas de changement de stack acceptable dans ce milestone.
- **Privacy invariants** : `audit.sh` doit continuer à passer (no print, no os_log interpolating user fields, log fields whitelisted). Toute nouvelle source de contexte ne franchit pas l'overlay process → AppContextProbe/Clipboard/AX restent in-process.
- **Performance** : la baseline TTFT du commit `6ad70df` est le plancher. Dégradation acceptable seulement si la qualité justifie ET si une voie de récupération existe (KV cache milestone suivant).
- **Compatibility** : macOS 14+ Apple Silicon. Pas de support Intel, pas de macOS 13.
- **No breakage** : 94 tests doivent rester verts. La pipeline existante (predict path) continue de fonctionner pendant la construction.
- **Migration strategy** : à décider en plan-phase 1 (feature flag vs in-place refactor). Question ouverte volontaire — dépend de combien le PromptBuilder peut être introduit graduellement.
- **MLX API dépendance** : `MLXLMCommon` impose son tokenizer et son interface de génération. Le PromptBuilder reste *au-dessus* — il produit le string final passé à `container.perform`. Pas de descente dans le runtime MLX ce milestone.
- **Pas de réseau** au runtime (sauf premier téléchargement du modèle). Le Context Builder n'introduit aucune nouvelle source réseau.
<!-- GSD:project-end -->

<!-- GSD:stack-start source:codebase/STACK.md -->
## Technology Stack

## Languages
- Swift 6 (tools-version `6.3`, `swiftLanguageModes: [.v6]`) — entire application, libraries, and benches
- Bash — build/audit scripts (`Souffleuse/make-app.sh`, `Souffleuse/audit.sh`)
## Runtime
- macOS 14+ (`platforms: [.macOS(.v14)]` in `Souffleuse/Package.swift`; `LSMinimumSystemVersion = 14.0` in `Souffleuse/Resources/Info.plist`)
- Apple Silicon required (MLX uses Metal kernels; `mlx-swift_Cmlx.bundle` shipped as metallib in `make-app.sh`)
- Swift Package Manager (SPM) — `Souffleuse/Package.swift`
- Lockfile: present (`Souffleuse/Package.resolved`)
## Frameworks
- AppKit — app lifecycle, windows, pasteboard
- SwiftUI — preferences and onboarding windows
- Observation (`@Observable`) — view-model reactivity (e.g. `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift`)
- CoreGraphics — `CGEventTap` for Tab/Esc interception (`Souffleuse/Sources/SouffleuseInput/KeyInterceptor.swift`)
- ApplicationServices — Accessibility API (`AXUIElement*`) in `Souffleuse/Sources/SouffleuseAX/AXClient.swift`
- ScreenCaptureKit — frontmost window capture in `Souffleuse/Sources/SouffleuseContext/ScreenCapturer.swift`
- Vision — OCR (`VNRecognizeTextRequest`) in `Souffleuse/Sources/SouffleuseContext/VisionOCR.swift` and `OCRCaretLocator.swift`
- NaturalLanguage — language detection (`NLLanguageRecognizer`) in `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift`
- CryptoKit — AES-GCM sealing of typing history (`Souffleuse/Sources/SouffleusePersonalization/TypingHistoryStore.swift`)
- Security — Keychain Services for AES key storage (`Souffleuse/Sources/SouffleusePersonalization/KeychainKey.swift`)
- IOKit.hid — used in `Souffleuse/Sources/Souffleuse/OnboardingWindow.swift`
- Foundation — pervasive
- MLX (`MLX`, `MLXLLM`, `MLXLMCommon`) — Apple-silicon-native LLM runtime; loaded via `LLMModelFactory.shared.loadContainer` in `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift:158`
- Swift Testing / XCTest target `SouffleuseTests` (`Souffleuse/Tests/SouffleuseTests/`)
- `xcodebuild` (invoked by `Souffleuse/make-app.sh`) — produces `.app` bundle for code-signing
- `codesign` with Apple Developer cert (overridable via `SIGN_IDENTITY` env var) — required for stable TCC entries across rebuilds
## Key Dependencies
- `mlx-swift-examples` 2.29.1 (`https://github.com/ml-explore/mlx-swift-examples`) — provides `MLXLLM`, `MLXLMCommon` (the library Souffleuse links). Only direct package dependency.
- `mlx-swift` 0.29.1 (transitive) — provides `MLX` array/runtime primitives
- `swift-transformers` 1.0.0 (HuggingFace, transitive) — tokenizers + Hub model download
- `swift-jinja` 2.3.6 (HuggingFace, transitive) — chat-template rendering
- `swift-collections` 1.5.1 (Apple, transitive)
- `swift-numerics` 1.1.1 (Apple, transitive)
- `GzipSwift` 6.0.1 (transitive)
- None beyond the above — no networking SDKs, no analytics, no crash reporting
## Configuration
- `Souffleuse/Package.swift` — SPM package manifest (8 executables, 7 libraries, 1 test target)
- `Souffleuse/Resources/Info.plist` — bundle identifier `app.cocotypist.Souffleuse`, version `0.2.0`, `LSUIElement = true` (menu-bar app, no Dock icon), TCC usage descriptions for Accessibility / AppleEvents / ScreenCapture
- `Souffleuse/Resources/AppIcon.icns` — app icon
- Code-signing identity hard-coded in `make-app.sh`: `A798891AB1B0A8C0B46AFADBD95094BABF680037` (Apple Development), overridable via `SIGN_IDENTITY` env var. Stable cert intentional so TCC permissions persist across rebuilds.
- `UserDefaults.standard` — typed keys in `Souffleuse/Sources/Souffleuse/PreferencesStore.swift` (model ID, OCR languages, completion length, personalization strength, partial-accept toggles, etc.)
- `~/Library/Application Support/Souffleuse/allowlist.json` — per-app behaviour overrides
- `~/Library/Application Support/Souffleuse/history.aes` — AES-GCM-sealed typing history (ring buffer, 200 entries, capped at 1 MB)
- `~/Library/Application Support/Souffleuse/clipboard-blocklist.txt` — user-supplied clipboard blocklist additions
- `~/Library/Logs/Souffleuse.log` — JSONL structured log, rotated at 1 MB with 3 backups (`Souffleuse/Sources/SouffleuseLog/Log.swift`)
- Keychain (`kSecClassGenericPassword`, service `dev.cocotypist.Souffleuse.history`, account `TypingHistoryStore.aesgcm`) — 256-bit AES key for history file
- `SOUFFLEUSE_PREDICT_LOG` — when non-empty, writes user-text debug trace to `/tmp/souffleuse-predict.log` (dev only; explicitly excluded from production audit)
- `SOUFFLEUSE_MODEL` — overrides default model in `SouffleuseCoherence` bench
- `SOUFFLEUSE_PENALTY` — repetition penalty in coherence bench
- `SOUFFLEUSE_CONTEXT` — enables realistic upstream context in coherence bench
- `SIGN_IDENTITY` — overrides code-sign identity in `make-app.sh`
## Platform Requirements
- macOS 14+ with Xcode toolchain providing Swift 6.3
- Apple Development signing certificate (or override `SIGN_IDENTITY=-` for ad-hoc)
- `jq` (optional) for `audit.sh` log-field check
- Granted TCC permissions for the dev bundle: Accessibility, Apple Events, Screen Recording (Screen Recording is opt-in; OCR capture is disabled by default)
- macOS 14+ on Apple Silicon (MLX inference runs on the GPU/ANE via Metal kernels shipped in `mlx-swift_Cmlx.bundle`)
- ~0.4 GB to ~1.3 GB free disk per LLM (model catalog: Gemma 3 1B variants, Qwen 2.5 0.5B/1.5B; downloaded from `mlx-community/*` HF repos on first use via `LLMModelFactory`)
- Network access on first model download only; no runtime network calls
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

## Language & Tooling
## Naming Patterns
- One primary type per file, file name matches the type. Examples: `Sources/SouffleuseTyping/ChunkSplitter.swift`, `Sources/SouffleuseAX/AXClient.swift`, `Sources/Souffleuse/AllowlistConfig.swift`.
- Test files mirror the type name with a `Tests` suffix: `Tests/SouffleuseTests/ChunkSplitterTests.swift`, `Tests/SouffleuseTests/CaretResolverTests.swift`.
- Loose grouping when several related types share a file (e.g. `AllowlistConfig.swift` holds `AllowlistMode`, `AllowlistRule`, `AllowlistFile`, `AllowlistStore`).
- `UpperCamelCase` for `struct`, `class`, `actor`, `enum`, `protocol`. Examples: `TypoDetector`, `NgramModel`, `OverlayWindow`, `CaretResolver`.
- Probe/Bench executables prefixed with `Souffleuse`: `SouffleuseAXProbe`, `SouffleuseCoherence`, `SouffleuseEnrichmentBench`.
- Protocols use `-ing` suffix when describing a role: `OCRCaretLocating` (see `Sources/SouffleuseContext/OCRCaretLocator.swift`).
- `lowerCamelCase`. Examples: `nextChunk`, `lastWord`, `checkLastWord`, `currentWordLooksSuspect`, `setActive`.
- Boolean properties read as predicates: `isEmpty`, `holdUntilComplete`, `automaticallyIdentifiesLanguages`.
- Static constants for thresholds live on the type: `TypoDetector.maxLevenshtein`, `TypoDetector.minWordLength`, `EnrichedContext.clipboardCap`, `TypingHistoryStore.maxEntries`.
- Every reusable concern is a SPM library target prefixed with `Souffleuse`: `SouffleuseAX`, `SouffleuseOverlay`, `SouffleuseInput`, `SouffleuseContext`, `SouffleuseLog`, `SouffleuseTyping`, `SouffleusePersonalization`. The app target itself is `Souffleuse`. Each maps to a directory under `Sources/`.
- Centralised in a nested `private enum K` (string constants), see `Sources/Souffleuse/PreferencesStore.swift`. Never inline string keys at call sites.
## Code Style
- 4-space indentation, no tabs.
- Trailing commas in multi-line collection literals (`[`, `.bits256`, `]`).
- One blank line between logical sections; no double blank lines.
- Braces on the same line as the declaration (`func foo() {`).
- `public` for cross-module API only. Types/methods used inside the same module stay package-default (no keyword) or `internal`.
- `private`, `fileprivate`, `private(set)` used aggressively to lock down state (e.g. `LogEntry` is `fileprivate struct` in `Sources/SouffleuseLog/Log.swift`).
- `@ObservationIgnored` on stored properties that shouldn't trigger view updates (see `AllowlistStore.fileURL`).
- Every cross-module value type is explicitly `Sendable`. Examples: `TypoSuggestion: Sendable, Equatable`, `EmojiExpansion: Sendable, Equatable`, `EnrichedContext: Sendable, Equatable`, `LogLevel: String, Sendable`.
- Reference types that cross threads use `@unchecked Sendable` only when the implementation provides its own synchronization, e.g. `final class TypoDetector: @unchecked Sendable` (`Sources/SouffleuseTyping/TypoDetector.swift`) and `final class LogWriter: @unchecked Sendable` (`Sources/SouffleuseLog/Log.swift`, serialised through `DispatchQueue`).
- `@Sendable` closures for callbacks crossing isolation boundaries: `public typealias Handler = @Sendable (Key) -> Bool` in `Sources/SouffleuseInput/KeyInterceptor.swift`.
## Concurrency
- `@MainActor` for AppKit-touching state: `OverlayWindow`, `PresenceIndicatorWindow`, `SouffleuseAppDelegate`, `AllowlistStore`, `PreferencesStore`, `OnboardingWindow`, etc.
- Plain `actor` for stateful background services: `NgramModel`, `TypingHistoryStore`, `ContextEnricher`. They expose `async` functions and serialise their own mutable state.
- `nonisolated` escape hatches for pure lookups callable from any context: `AllowlistStore.mode(forBundle:windowTitle:rules:)` (`Sources/Souffleuse/AllowlistConfig.swift`).
- `await` chained through actors; no manual `DispatchQueue` calls for new code (only `LogWriter` uses one, intentionally).
- `Task { ... }` spawned from `@MainActor` for fire-and-forget work; pending tasks tracked explicitly (see `CaretResolver.pendingOCRBundles`).
- `CheckedContinuation` only used inside test doubles to deterministically stall an async call (`MockOCRCaretLocator` in `CaretResolverTests.swift`).
## Import Organization
## Documentation Comments
- Triple-slash `///` for every public type, function, and non-obvious property.
- Multi-line doc comments include rationale, not just signature description. Example from `Sources/SouffleuseLog/Log.swift:14`:
- Inline `//` comments are dense and explain *why*, not *what*. They frequently reference specific apps that motivated the code path (Brave, Notes, Intercom, Cotypist).
- Examples in doc-comments use indented code blocks (no triple-backtick) — see `ChunkSplitter.nextChunk`.
- `// MARK: - Section Name` to chunk long files and test suites. See `Tests/SouffleuseTests/PersonalizationTests.swift` (`// MARK: - SecretHeuristic`, `// MARK: - TypingHistoryStore`).
## Error Handling
- Throwing functions only at the lowest IO boundary (Keychain, ScreenCapture). Higher layers return optionals or fall back silently.
- Dedicated `Error` enums per subsystem: `KeychainError` in `Sources/SouffleusePersonalization/KeychainKey.swift`, `ScreenCaptureError` in `Sources/SouffleuseContext/ScreenCapturer.swift`.
- Errors are not re-raised across actor boundaries; instead, the actor logs an event and returns nil/default.
- Used liberally for non-critical IO: log appends, allowlist persistence, file rotation (`Sources/SouffleuseLog/Log.swift:73-101`). Failure to write a log line must never crash the app.
- Decryption failures of `history.aes` reset the store to empty rather than propagating (see `historyDecryptCorruptFileResetsToEmpty` test).
- Standard Swift idiom, used throughout. Example: `Sources/SouffleuseTyping/TypoDetector.swift:39-43`.
## Logging
- The event argument is `StaticString` so it MUST be a compile-time literal. No path can interpolate a user-supplied string.
- Only five fields are ever serialised: `ts`, `level`, `module`, `event`, optional `count`.
- `Souffleuse/audit.sh` greps the shipping targets to forbid `print(`, `NSLog(`, `os_log(...%@...userText)`, and any `Log.*` call that interpolates `accepted`, `contextBefore`, `entry.`, or `prefix`.
- `print(...)` and `NSLog(...)` — fail the audit.
- `os_log` interpolating user text — fail the audit.
- Reading `history.aes` outside `TypingHistoryStore.swift` and `HistoryViewerWindow.swift` — fail the audit.
## Persistence Patterns
- JSON via `JSONEncoder` with `[.prettyPrinted, .sortedKeys]` for human-readable config (`AllowlistStore.save` in `Sources/Souffleuse/AllowlistConfig.swift:76-78`).
- AES-GCM via `CryptoKit.SymmetricKey` for sensitive history (`Sources/SouffleusePersonalization/TypingHistoryStore.swift`). Key is generated once and stored in Keychain via `KeychainKey`.
- `UserDefaults.standard` for preferences, with typed key constants in `PreferencesStore.K`.
- Top-level on-disk struct carries an explicit `version: Int = 1`. See `AllowlistFile` in `Sources/Souffleuse/AllowlistConfig.swift:40`.
## Function Design
- Most functions stay under ~30 lines. Long bodies (e.g. `OverlayWindow.show`, `SouffleuseAppDelegate.tick`) split into small private helpers (`Self.estimatedFont`, `Self.correctCaretRect`, `Self.appKitFrame`).
- Pure utilities live on the type as `static` functions so they're testable without instantiating: `ChunkSplitter.nextChunk`, `TypoDetector.lastWord`, `TypoDetector.levenshtein`, `CaretEstimator.estimateRect`, `OverlayWindow.estimatedFont`.
- Named labels are descriptive — no abbreviations. `func locate(elementRect:bundleID:text:caretIndex:)` not `func locate(_ r:_ b:_ t:_ i:)`.
- Default values used to keep call sites short and to allow incremental API extension (e.g. `caretFont: AXFontInfo? = nil`).
- Optionals to signal "nothing to do" (typo detection, caret resolution, OCR locator). Callers `if let`/`guard let`.
- Tuples returned with named fields when more than one value: `(range: Range<String.Index>, word: String)` from `TypoDetector.lastWord`.
## Module Design
- Each capability is its own SPM target so the dependency graph stays explicit (see `Souffleuse/Package.swift:9-22`). The shipping executable `Souffleuse` depends on every library; CLI probes pull only the targets they need.
- No barrel files / re-exports. Consumers import the specific module.
- Only `SouffleuseOverlay` declares resources (`.process("Resources")`). Other targets keep their data inline (e.g. `EmojiTable.map` in `Sources/SouffleuseTyping/EmojiExpander.swift:22`).
## Test-Only Hooks
- Production initialisers default to real dependencies; an overload accepts a test seam. Example: `TypingHistoryStore` exposes `init(fileURL: URL, testKey: SymmetricKey)` so tests bypass Keychain, while production uses the convenience `init()`.
- Test doubles live alongside the tests (e.g. `MockOCRCaretLocator` is defined inside `CaretResolverTests.swift` rather than in a separate Mocks/ target).
## Localisation
- UI strings (window titles, labels, menu items) are written in French inline. Examples: `case .active: return "Actif"` (`Sources/Souffleuse/AllowlistConfig.swift:14`). No `.strings` files or `NSLocalizedString` calls — the app is French-first.
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

## System Overview
```text
```
## Component Responsibilities
| Component | Responsibility | File |
|-----------|----------------|------|
| `SouffleuseAppDelegate` | Orchestrator. Owns 80 ms poll timer, wires AX → enricher → predictor → overlay, handles Tab/Esc, manages onboarding/hotkeys/menubar | `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift` |
| `PredictorViewModel` | MLX model lifecycle, debounce, streaming generation, prefix cache, n-gram bias chaining, sentence/word truncation | `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` |
| `PreferencesStore` | `@Observable` settings: model choice, completion length, capture toggle, OCR langs, personalization knob | `Souffleuse/Sources/Souffleuse/PreferencesStore.swift` |
| `CaretResolver` | OCR fallback + per-bundle layout calibration when AX hides per-character bounds (Chromium/Edge/Brave) | `Souffleuse/Sources/Souffleuse/CaretResolver.swift` |
| `AllowlistConfig` | Allowlist/blocklist of bundle IDs for AX read and personalization recording | `Souffleuse/Sources/Souffleuse/AllowlistConfig.swift` |
| `AXClient` | All `AXUIElement` reads/writes: focused element, text, caret index, caret rect, font, AX observers for Chromium activation | `Souffleuse/Sources/SouffleuseAX/AXClient.swift` |
| `ContextEnricher` | Assembles AppContext + Clipboard + ScreenCapture+OCR into prompt prefix, TTL-cached per bundleID | `Souffleuse/Sources/SouffleuseContext/ContextEnricher.swift` |
| `AppContextProbe` | Reads frontmost app bundle ID + window title via NSWorkspace | `Souffleuse/Sources/SouffleuseContext/AppContextProbe.swift` |
| `ClipboardReader` | NSPasteboard reads, gated by per-app blocklist (1Password, banks, …) | `Souffleuse/Sources/SouffleuseContext/ClipboardReader.swift` |
| `ScreenCapturer` | ScreenCaptureKit wrapper for frontmost window snapshot | `Souffleuse/Sources/SouffleuseContext/ScreenCapturer.swift` |
| `VisionOCR` | `VNRecognizeTextRequest` over captured image, capped output | `Souffleuse/Sources/SouffleuseContext/VisionOCR.swift` |
| `OCRCaretLocator` | OCR-based caret position estimation when AX caret rect is missing/unreliable | `Souffleuse/Sources/SouffleuseContext/OCRCaretLocator.swift` |
| `KeyInterceptor` | Session `CGEventTap` for Tab/Esc, enabled only while a suggestion is showing | `Souffleuse/Sources/SouffleuseInput/KeyInterceptor.swift` |
| `OverlayWindow` | Borderless non-activating `NSPanel` rendering gray ghost text aligned to caret rect | `Souffleuse/Sources/SouffleuseOverlay/OverlayWindow.swift` |
| `PresenceIndicatorWindow` | Small floating badge anchored to focused text element rect | `Souffleuse/Sources/SouffleuseOverlay/PresenceIndicatorWindow.swift` |
| `CaretEstimator` | Geometric caret-rect refinement helpers for overlay positioning | `Souffleuse/Sources/SouffleuseOverlay/CaretEstimator.swift` |
| `Log` / `LogWriter` | Structured event-only JSONL logger (5 whitelisted fields, no user text) with size-based rotation | `Souffleuse/Sources/SouffleuseLog/Log.swift` |
| `TypingHistoryStore` | Encrypted ring buffer (200 entries) of accepted suggestions, AES-GCM sealed blob | `Souffleuse/Sources/SouffleusePersonalization/TypingHistoryStore.swift` |
| `KeychainKey` | Loads/creates AES-256 symmetric key from login Keychain (`AfterFirstUnlockThisDeviceOnly`) | `Souffleuse/Sources/SouffleusePersonalization/KeychainKey.swift` |
| `NgramModel` / `NgramBuilder` / `NgramSnapshot` | Local n-gram model built from history, used to bias LLM logits | `Souffleuse/Sources/SouffleusePersonalization/Ngram*.swift` |
| `NgramLogitBias` / `ChainLogitProcessor` | MLX logit-processor plumbing: chains repetition penalty + n-gram bias | `Souffleuse/Sources/SouffleusePersonalization/{NgramLogitBias,ChainLogitProcessor}.swift` |
| `SimilarHistoryRetrieval` | Few-shot retrieval over `TypingHistoryStore` keyed on userTail similarity | `Souffleuse/Sources/SouffleusePersonalization/SimilarHistoryRetrieval.swift` |
| `EmojiExpander` | `:shortcode:` → emoji expansion (≈150 GitHub-flavored entries) | `Souffleuse/Sources/SouffleuseTyping/EmojiExpander.swift` |
| `TypoDetector` | `NSSpellChecker` multilingual single-word typo detection at caret | `Souffleuse/Sources/SouffleuseTyping/TypoDetector.swift` |
| `WordCompleter` | System-API word completion for instant partial-word ghost | `Souffleuse/Sources/SouffleuseTyping/WordCompleter.swift` |
| `ChunkSplitter` | Splits a suggestion into Tab-by-Tab partial accept chunks | `Souffleuse/Sources/SouffleuseTyping/ChunkSplitter.swift` |
## Pattern Overview
- **Polling-driven, debounced.** A `Timer` every 80 ms in `SouffleuseAppDelegate.tick()` is the heartbeat; LLM predict is gated by a 50 ms debounce (`predictDebounceNanos`) after the prefix last changed.
- **Cancel-on-keystroke streaming.** Each new prefix bumps a generation counter in `PredictorViewModel` and cancels the in-flight `Task` so stale stream chunks are dropped.
- **MainActor-centric UI + serial actors elsewhere.** `SouffleuseAppDelegate`, `PredictorViewModel`, and overlay windows are `@MainActor`. `ContextEnricher`, `TypingHistoryStore`, and `AXClient`'s internal dispatch queue serialize per-component state.
- **Privacy-by-typesystem.** `Log.info/warn/error` take only `StaticString` event names — no user-supplied string can reach the log writer by construction.
- **Memo + sentence-truncation cache.** `PredictorViewModel.predictCache` (FIFO, 32 entries) memoizes greedy-decoded suggestions per prefix to absorb the "type space → backspace" cycle without a regen.
- **Per-bundle calibration.** Caret rect, font, OCR fallback, and personalization recording are all keyed on the focused app's bundle ID.
## Layers
- Purpose: AppKit lifecycle, orchestration, all SwiftUI/NSWindow UIs (preferences, onboarding, custom instructions, history viewer), preferences persistence.
- Location: `Souffleuse/Sources/Souffleuse/`
- Contains: AppDelegate, `main.swift`, ViewModels, windows, `PreferencesStore`, `AllowlistConfig`, `CaretResolver`.
- Depends on: every other library target + `MLXLLM` + `MLXLMCommon`.
- Used by: nothing (it is the executable).
- Purpose: All `AXUIElement` interactions, observer lifecycle, Chromium AX activation.
- Location: `Souffleuse/Sources/SouffleuseAX/`
- Contains: `AXClient`, `AXSnapshot`, `AXFontInfo`.
- Depends on: AppKit / ApplicationServices only.
- Used by: `Souffleuse`, `SouffleuseContext`, `SouffleuseAXProbe`, `SouffleuseContextProbe`.
- Purpose: Build the prompt prefix from app metadata, clipboard, screen capture, OCR.
- Location: `Souffleuse/Sources/SouffleuseContext/`
- Contains: `ContextEnricher` (actor), `AppContextProbe`, `ClipboardReader`, `ScreenCapturer`, `VisionOCR`, `OCRCaretLocator`.
- Depends on: `SouffleuseAX`, `SouffleuseLog`, `SouffleuseOverlay`.
- Used by: `Souffleuse`, `SouffleuseContextProbe`.
- Purpose: `CGEventTap` plumbing for Tab/Esc consumption.
- Location: `Souffleuse/Sources/SouffleuseInput/`
- Contains: `KeyInterceptor`.
- Depends on: CoreGraphics only.
- Used by: `Souffleuse`, `SouffleuseAXProbe`.
- Purpose: Render the ghost suggestion and presence indicator as floating `NSPanel`s.
- Location: `Souffleuse/Sources/SouffleuseOverlay/`
- Contains: `OverlayWindow`, `PresenceIndicatorWindow`, `CaretEstimator`, embedded `Resources/` (PresenceMark.png).
- Depends on: AppKit only.
- Used by: `Souffleuse`, `SouffleuseAXProbe`, `SouffleuseContext` (for OCR caret geometry types).
- Purpose: Append-only structured event log with rotation.
- Location: `Souffleuse/Sources/SouffleuseLog/`
- Contains: `Log` facade, `LogWriter`, `LogLevel`, `LogModule`.
- Depends on: Foundation only.
- Used by: every other module.
- Purpose: On-device acceptance history (encrypted at rest), n-gram model, MLX logit bias, few-shot retrieval.
- Location: `Souffleuse/Sources/SouffleusePersonalization/`
- Contains: `TypingHistoryStore` (actor), `TypingHistoryEntry`, `KeychainKey`, `NgramModel`, `NgramBuilder`, `NgramSnapshot`, `NgramLogitBias`, `ChainLogitProcessor`, `SimilarHistoryRetrieval`.
- Depends on: `SouffleuseLog`, `MLXLMCommon`, CryptoKit.
- Used by: `Souffleuse`, `SouffleuseEnrichmentBench`.
- Purpose: Non-LLM text utilities the orchestrator composes around the LLM ghost.
- Location: `Souffleuse/Sources/SouffleuseTyping/`
- Contains: `EmojiExpander`, `TypoDetector`, `WordCompleter`, `ChunkSplitter`.
- Depends on: AppKit only.
- Used by: `Souffleuse`.
- `SouffleuseAXProbe` — interactive AX read/inject/overlay tester (`Sources/SouffleuseAXProbe/main.swift`).
- `SouffleuseContextProbe` — exercises the enrichment pipeline (`Sources/SouffleuseContextProbe/main.swift`).
- `SouffleuseBench` — MLX model TTFT/throughput benchmark (`Sources/SouffleuseBench/Bench.swift`).
- `SouffleuseCoherence` — LLM coherence harness (`Sources/SouffleuseCoherence/main.swift`).
- `SouffleuseEnrichmentBench` — A/B over personalization (`Sources/SouffleuseEnrichmentBench/main.swift`).
## Data Flow
### Primary suggestion path (typing → ghost)
### Acceptance path (Tab)
### Dismissal path (Esc / divergence)
- `@Observable PreferencesStore` drives UI + drives behavior changes via `withObservationTracking { … } onChange:` (one-shot, re-subscribed on every fire — `SouffleuseAppDelegate.swift:269`).
- Per-bundle caches (`lastCaretRectByApp`, `textAtFocusByBundle`, `lastEnrichedBundleID`, `cachedEnrichmentPrefix`) live on the AppDelegate.
- LLM cache (`predictCache`, FIFO 32) and generation counter live on `PredictorViewModel`.
- Persistent state: `UserDefaults` (toggles, shortcuts, model ID), `TypingHistoryStore` (encrypted history), MLX model cache on disk.
## Key Abstractions
- Purpose: Immutable read-only snapshot of "what is currently focused" — the single value type that crosses the AX boundary.
- Examples: produced by `AXClient.snapshot()`, consumed everywhere in `SouffleuseAppDelegate.tick()`.
- Pattern: Value type, `Sendable`, `Equatable`, with `isTextElement` / `isSecureField` derived predicates.
- Purpose: Optional contextual prefix appended to the LLM prompt; provides `.prefix` as plain prose (no `[Label:]` syntax that base models would imitate).
- Examples: `Souffleuse/Sources/SouffleuseContext/ContextEnricher.swift`.
- Pattern: Immutable struct with per-source caps (`clipboardCap = 200`, `visibleCap = 240`).
- Purpose: All LLM concerns behind one `@Observable` `@MainActor` boundary.
- Examples: `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift`.
- Pattern: Generation counter + cancellable `Task`; FIFO memoization keyed on prefix; pluggable logit-processor chain.
- Purpose: Encrypted, capped ring buffer abstraction over `history.aes` so callers never touch CryptoKit directly.
- Examples: `Souffleuse/Sources/SouffleusePersonalization/TypingHistoryStore.swift`.
- Pattern: Swift `actor` with `load()`, `append()`, `allEntries()`, `clear()`; testable via `internal init(testKey:)` seam.
- Purpose: Compile-time-safe event log facade.
- Examples: every `Log.info(.predictor, "predict_start", count: 1)` call site.
- Pattern: Enum facade + `StaticString` event names — privacy invariant enforced by the type system, not by convention.
## Entry Points
- Location: `Souffleuse/Sources/Souffleuse/main.swift` (5 lines — sets `NSApplication.shared.delegate = SouffleuseAppDelegate()` and runs).
- Triggers: `open Souffleuse.app` (built by `make-app.sh`) or Xcode Cmd+R.
- Responsibilities: bootstrap AppKit accessory app (`LSUIElement = true`), wire delegate.
- Location: `Souffleuse/Resources/Info.plist` (also mirrored at `Souffleuse/Souffleuse/Resources/Info.plist`).
- Bundle ID: `app.cocotypist.Souffleuse`, version 0.2.0, `LSMinimumSystemVersion 14.0`, `LSUIElement true`.
- Required usage strings: `NSAccessibilityUsageDescription`, `NSAppleEventsUsageDescription`, `NSScreenCaptureUsageDescription`.
- `Souffleuse/Sources/SouffleuseAXProbe/main.swift`
- `Souffleuse/Sources/SouffleuseContextProbe/main.swift`
- `Souffleuse/Sources/SouffleuseBench/Bench.swift`
- `Souffleuse/Sources/SouffleuseCoherence/main.swift`
- `Souffleuse/Sources/SouffleuseEnrichmentBench/main.swift`
## Architectural Constraints
- **Threading:** Main thread owns AppKit, AppDelegate, overlay windows, `PredictorViewModel`, `PreferencesStore`. `AXClient` serializes raw AX calls on a private `cocotypist.ax.client` `DispatchQueue` (`SouffleuseAX/AXClient.swift:63`). `ContextEnricher` and `TypingHistoryStore` are Swift `actor`s. MLX inference runs on a detached `Task` (cooperative thread pool), cancelled per keystroke.
- **Swift 6 strict concurrency** enabled (`swiftLanguageModes: [.v6]` in `Souffleuse/Package.swift:112`). All boundary types are `Sendable`.
- **Global state:**
- **Sandbox:** None. Accessibility API requires sandbox exit → distribution is hors Mac App Store, signed Developer ID + notarized.
- **Network:** Direct network use is restricted to MLX model downloads via `mlx-swift-examples` (Hugging Face). No telemetry, no update pings, no Sparkle in v1 (planned). The `audit.sh` script enforces this in shipping targets.
- **Privacy invariants enforced by `audit.sh`:** no `print(`, no `NSLog`, no `os_log` interpolating user fields, log file fields restricted to `{ts, level, module, event, count}`, `history.aes` only referenced from `TypingHistoryStore` + `HistoryViewerWindow`, no `Log.*` call interpolating `accepted` / `contextBefore` / `entry.` / `prefix`.
- **No XPC isolation yet.** The architecture doc (`ARCHITECTURE.md` §5.bis) targets a 3-process split (UI / AXAgent / InferenceAgent) but the current codebase ships as a single process.
## Anti-Patterns
### Logging user-supplied strings
### Reading `history.aes` outside the personalization module
### Generating without cancel-on-keystroke
### Touching `NSPanel` / overlay off main
### Recording into history from a blocked bundle
## Error Handling
- `do { … } catch { Log.warn(.module, "event_failed") }` — most non-fatal failures.
- `PredictorViewModel.LoadState = .failed(String)` surfaces model load errors to UI without throwing into the run loop.
- `TypingHistoryStore` resets to an empty in-memory state on key/file failures and sets `writeFailedThisSession = true` to avoid retry storms (`Sources/SouffleusePersonalization/TypingHistoryStore.swift`).
- Optional chaining for nullable AX attributes — never force-unwrap AX returns.
- `Task` cancellation via `Task.isCancelled` checks inside MLX streaming closures.
## Cross-Cutting Concerns
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
