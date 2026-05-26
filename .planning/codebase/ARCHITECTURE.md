<!-- refreshed: 2026-05-24 -->
# Architecture

**Analysis Date:** 2026-05-24

## System Overview

```text
┌─────────────────────────────────────────────────────────────────┐
│                       macOS user session                         │
│                                                                  │
│  Host apps (Mail, Safari, Notes, …)                              │
│       │                                                          │
│       │ AX read / write / CGEvent                                │
│       ▼                                                          │
│  ┌───────────────────────────────────────────────────────────┐   │
│  │            Souffleuse.app (single process, accessory)      │   │
│  │                                                            │   │
│  │  ┌─────────────────────────────────────────────────────┐   │   │
│  │  │  SouffleuseAppDelegate (orchestrator, 80 ms tick)   │   │   │
│  │  │  `Sources/Souffleuse/SouffleuseAppDelegate.swift`   │   │   │
│  │  └──┬──────────────┬──────────────┬─────────────────┬──┘   │   │
│  │     │ AX snapshot  │ enrichment   │ predict()       │ Tab  │   │
│  │     ▼              ▼              ▼                 ▼ /Esc │   │
│  │  ┌─────────┐  ┌─────────────┐  ┌──────────────┐  ┌──────┐  │   │
│  │  │SouffAX  │  │SouffContext │  │ Predictor    │  │Input │  │   │
│  │  │AXClient │  │Enricher     │  │ViewModel +   │  │Key   │  │   │
│  │  │CaretRes.│  │ScreenCap+OCR│  │MLX + Ngram   │  │Inter.│  │   │
│  │  └────┬────┘  └─────────────┘  └──────┬───────┘  └───┬──┘  │   │
│  │       │ caretRect, text, font         │ tokens stream │     │   │
│  │       ▼                                ▼               │     │   │
│  │  ┌─────────────────────────────────────────────┐      │     │   │
│  │  │ SouffleuseOverlay (NSPanel ghost + presence)│      │     │   │
│  │  │ `Sources/SouffleuseOverlay/`                │      │     │   │
│  │  └─────────────────────────────────────────────┘      │     │   │
│  │                                                        │     │   │
│  │  ┌──────────────────────────────────────────────────┐ │     │   │
│  │  │ SouffleusePersonalization                        │◄┘     │   │
│  │  │ TypingHistoryStore (AES-GCM) + NgramModel        │       │   │
│  │  │ `Sources/SouffleusePersonalization/`             │       │   │
│  │  └──────────────────────────────────────────────────┘       │   │
│  │                                                              │   │
│  │  SouffleuseLog (structured event-only logging)               │   │
│  │  SouffleuseTyping (emoji, typo, word completion, chunking)   │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  Persistence: `~/Library/Application Support/Souffleuse/`            │
│   - `history.aes`   (AES-256-GCM, key in Keychain)                   │
│   - `models/…`      (downloaded MLX weights via mlx-swift-examples)  │
│   - `~/Library/Logs/Souffleuse.log` (JSONL, no user text)            │
└──────────────────────────────────────────────────────────────────────┘
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

**Overall:** Single-process modular monolith. AppKit `NSApplicationDelegate` orchestrator drives a fixed 80 ms tick that pulls a fresh AX snapshot, fans out to enrichment + prediction, and pushes results into an `NSPanel` overlay. Internally split into seven SwiftPM library targets to enforce dependency direction and allow per-module testing.

**Key Characteristics:**
- **Polling-driven, debounced.** A `Timer` every 80 ms in `SouffleuseAppDelegate.tick()` is the heartbeat; LLM predict is gated by a 50 ms debounce (`predictDebounceNanos`) after the prefix last changed.
- **Cancel-on-keystroke streaming.** Each new prefix bumps a generation counter in `PredictorViewModel` and cancels the in-flight `Task` so stale stream chunks are dropped.
- **MainActor-centric UI + serial actors elsewhere.** `SouffleuseAppDelegate`, `PredictorViewModel`, and overlay windows are `@MainActor`. `ContextEnricher`, `TypingHistoryStore`, and `AXClient`'s internal dispatch queue serialize per-component state.
- **Privacy-by-typesystem.** `Log.info/warn/error` take only `StaticString` event names — no user-supplied string can reach the log writer by construction.
- **Memo + sentence-truncation cache.** `PredictorViewModel.predictCache` (FIFO, 32 entries) memoizes greedy-decoded suggestions per prefix to absorb the "type space → backspace" cycle without a regen.
- **Per-bundle calibration.** Caret rect, font, OCR fallback, and personalization recording are all keyed on the focused app's bundle ID.

## Layers

**Entry / app shell (`Sources/Souffleuse/`):**
- Purpose: AppKit lifecycle, orchestration, all SwiftUI/NSWindow UIs (preferences, onboarding, custom instructions, history viewer), preferences persistence.
- Location: `Souffleuse/Sources/Souffleuse/`
- Contains: AppDelegate, `main.swift`, ViewModels, windows, `PreferencesStore`, `AllowlistConfig`, `CaretResolver`.
- Depends on: every other library target + `MLXLLM` + `MLXLMCommon`.
- Used by: nothing (it is the executable).

**Accessibility (`Sources/SouffleuseAX/`):**
- Purpose: All `AXUIElement` interactions, observer lifecycle, Chromium AX activation.
- Location: `Souffleuse/Sources/SouffleuseAX/`
- Contains: `AXClient`, `AXSnapshot`, `AXFontInfo`.
- Depends on: AppKit / ApplicationServices only.
- Used by: `Souffleuse`, `SouffleuseContext`, `SouffleuseAXProbe`, `SouffleuseContextProbe`.

**Context enrichment (`Sources/SouffleuseContext/`):**
- Purpose: Build the prompt prefix from app metadata, clipboard, screen capture, OCR.
- Location: `Souffleuse/Sources/SouffleuseContext/`
- Contains: `ContextEnricher` (actor), `AppContextProbe`, `ClipboardReader`, `ScreenCapturer`, `VisionOCR`, `OCRCaretLocator`.
- Depends on: `SouffleuseAX`, `SouffleuseLog`, `SouffleuseOverlay`.
- Used by: `Souffleuse`, `SouffleuseContextProbe`.

**Input (`Sources/SouffleuseInput/`):**
- Purpose: `CGEventTap` plumbing for Tab/Esc consumption.
- Location: `Souffleuse/Sources/SouffleuseInput/`
- Contains: `KeyInterceptor`.
- Depends on: CoreGraphics only.
- Used by: `Souffleuse`, `SouffleuseAXProbe`.

**Overlay (`Sources/SouffleuseOverlay/`):**
- Purpose: Render the ghost suggestion and presence indicator as floating `NSPanel`s.
- Location: `Souffleuse/Sources/SouffleuseOverlay/`
- Contains: `OverlayWindow`, `PresenceIndicatorWindow`, `CaretEstimator`, embedded `Resources/` (PresenceMark.png).
- Depends on: AppKit only.
- Used by: `Souffleuse`, `SouffleuseAXProbe`, `SouffleuseContext` (for OCR caret geometry types).

**Logging (`Sources/SouffleuseLog/`):**
- Purpose: Append-only structured event log with rotation.
- Location: `Souffleuse/Sources/SouffleuseLog/`
- Contains: `Log` facade, `LogWriter`, `LogLevel`, `LogModule`.
- Depends on: Foundation only.
- Used by: every other module.

**Personalization (`Sources/SouffleusePersonalization/`):**
- Purpose: On-device acceptance history (encrypted at rest), n-gram model, MLX logit bias, few-shot retrieval.
- Location: `Souffleuse/Sources/SouffleusePersonalization/`
- Contains: `TypingHistoryStore` (actor), `TypingHistoryEntry`, `KeychainKey`, `NgramModel`, `NgramBuilder`, `NgramSnapshot`, `NgramLogitBias`, `ChainLogitProcessor`, `SimilarHistoryRetrieval`.
- Depends on: `SouffleuseLog`, `MLXLMCommon`, CryptoKit.
- Used by: `Souffleuse`, `SouffleuseEnrichmentBench`.

**Typing helpers (`Sources/SouffleuseTyping/`):**
- Purpose: Non-LLM text utilities the orchestrator composes around the LLM ghost.
- Location: `Souffleuse/Sources/SouffleuseTyping/`
- Contains: `EmojiExpander`, `TypoDetector`, `WordCompleter`, `ChunkSplitter`.
- Depends on: AppKit only.
- Used by: `Souffleuse`.

**CLI executables (probes + benches):**
- `SouffleuseAXProbe` — interactive AX read/inject/overlay tester (`Sources/SouffleuseAXProbe/main.swift`).
- `SouffleuseContextProbe` — exercises the enrichment pipeline (`Sources/SouffleuseContextProbe/main.swift`).
- `SouffleuseBench` — MLX model TTFT/throughput benchmark (`Sources/SouffleuseBench/Bench.swift`).
- `SouffleuseCoherence` — LLM coherence harness (`Sources/SouffleuseCoherence/main.swift`).
- `SouffleuseEnrichmentBench` — A/B over personalization (`Sources/SouffleuseEnrichmentBench/main.swift`).

## Data Flow

### Primary suggestion path (typing → ghost)

1. **Timer fire** every 80 ms (`SouffleuseAppDelegate.applicationDidFinishLaunching` → `tick()` at `SouffleuseAppDelegate.swift:208`).
2. **AX snapshot** read via `AXClient.snapshot()` — returns bundleID, role/subrole, text, caretIndex, caretRect, caretFont, windowTitle, elementRect (`SouffleuseAX/AXClient.swift`).
3. **Gate** on bundle blocklist (`personalizationBundleBlocklist`, `bundleBlocklist` in `SouffleuseAppDelegate.swift:19-44`), text role, secure-field subrole.
4. **Caret-rect refinement** via `CaretResolver` when AX bounds are missing (Chromium/Edge) — may schedule async OCR (`Sources/Souffleuse/CaretResolver.swift`).
5. **Enrichment** (async, focus-change triggered): `ContextEnricher.prefix(for:)` builds `App X, window "…". Clipboard: …. On screen: ….` from `AppContextProbe` + `ClipboardReader` + `ScreenCapturer` + `VisionOCR`, cached for 5 s (`SouffleuseContext/ContextEnricher.swift:51`).
6. **Debounced predict** — `predictDebounceTask` waits 50 ms after the last prefix change, then calls `PredictorViewModel.predict(prefix:enrichment:)` (`SouffleuseAppDelegate.swift:111`).
7. **MLX generation** on a detached `Task`: `ModelContainer` + `MLXLMCommon.generate` stream tokens; `ChainLogitProcessor` composes repetition penalty with `NgramLogitBias` when `personalizationStrength > 0` (`Sources/Souffleuse/PredictorViewModel.swift`, `Sources/SouffleusePersonalization/ChainLogitProcessor.swift`).
8. **onChunk callback** appends to `suggestion`, guarded by the captured `generation` counter; truncates on sentence end and at `maxWords`.
9. **Overlay render** — `OverlayWindow.show(text:at:hostText:caretIndex:hostFont:)` positions the `NSPanel` at the caret rect with matching font (`SouffleuseOverlay/OverlayWindow.swift:50`).
10. **`KeyInterceptor.setActive(true)`** enables the Tab/Esc tap once a suggestion is visible (`SouffleuseInput/KeyInterceptor.swift`).

### Acceptance path (Tab)

1. CGEventTap callback in `KeyInterceptor.handle(type:event:)` consumes the keyDown and invokes the handler.
2. `SouffleuseAppDelegate.handleKey(.tab)` decides between typo replacement (`currentTypo`), partial chunk accept (`partialRemainder`), or full LLM accept.
3. Text injected via `AXClient.insertText(_:)` (preferred, `kAXSelectedTextAttribute`) or simulated key events as fallback.
4. Accepted text recorded into `TypingHistoryStore` (subject to `personalizationBundleBlocklist`); n-gram model rebuilt asynchronously via `PredictorViewModel.rebuildPersonalization(from:)` (`SouffleuseAppDelegate.swift:182`).
5. Overlay cleared, KeyInterceptor disabled until the next suggestion.

### Dismissal path (Esc / divergence)

1. Esc consumed by `KeyInterceptor`, `dismissedForText` set to the current host text in the delegate.
2. Next `tick()` sees the same text and refuses to repaint the ghost; cleared when host text mutates.

**State Management:**
- `@Observable PreferencesStore` drives UI + drives behavior changes via `withObservationTracking { … } onChange:` (one-shot, re-subscribed on every fire — `SouffleuseAppDelegate.swift:269`).
- Per-bundle caches (`lastCaretRectByApp`, `textAtFocusByBundle`, `lastEnrichedBundleID`, `cachedEnrichmentPrefix`) live on the AppDelegate.
- LLM cache (`predictCache`, FIFO 32) and generation counter live on `PredictorViewModel`.
- Persistent state: `UserDefaults` (toggles, shortcuts, model ID), `TypingHistoryStore` (encrypted history), MLX model cache on disk.

## Key Abstractions

**`AXSnapshot`:**
- Purpose: Immutable read-only snapshot of "what is currently focused" — the single value type that crosses the AX boundary.
- Examples: produced by `AXClient.snapshot()`, consumed everywhere in `SouffleuseAppDelegate.tick()`.
- Pattern: Value type, `Sendable`, `Equatable`, with `isTextElement` / `isSecureField` derived predicates.

**`EnrichedContext`:**
- Purpose: Optional contextual prefix appended to the LLM prompt; provides `.prefix` as plain prose (no `[Label:]` syntax that base models would imitate).
- Examples: `Souffleuse/Sources/SouffleuseContext/ContextEnricher.swift`.
- Pattern: Immutable struct with per-source caps (`clipboardCap = 200`, `visibleCap = 240`).

**`PredictorViewModel`:**
- Purpose: All LLM concerns behind one `@Observable` `@MainActor` boundary.
- Examples: `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift`.
- Pattern: Generation counter + cancellable `Task`; FIFO memoization keyed on prefix; pluggable logit-processor chain.

**`TypingHistoryStore`:**
- Purpose: Encrypted, capped ring buffer abstraction over `history.aes` so callers never touch CryptoKit directly.
- Examples: `Souffleuse/Sources/SouffleusePersonalization/TypingHistoryStore.swift`.
- Pattern: Swift `actor` with `load()`, `append()`, `allEntries()`, `clear()`; testable via `internal init(testKey:)` seam.

**`Log`:**
- Purpose: Compile-time-safe event log facade.
- Examples: every `Log.info(.predictor, "predict_start", count: 1)` call site.
- Pattern: Enum facade + `StaticString` event names — privacy invariant enforced by the type system, not by convention.

## Entry Points

**`Souffleuse` executable target:**
- Location: `Souffleuse/Sources/Souffleuse/main.swift` (5 lines — sets `NSApplication.shared.delegate = SouffleuseAppDelegate()` and runs).
- Triggers: `open Souffleuse.app` (built by `make-app.sh`) or Xcode Cmd+R.
- Responsibilities: bootstrap AppKit accessory app (`LSUIElement = true`), wire delegate.

**Bundle / Info.plist:**
- Location: `Souffleuse/Resources/Info.plist` (also mirrored at `Souffleuse/Souffleuse/Resources/Info.plist`).
- Bundle ID: `app.cocotypist.Souffleuse`, version 0.2.0, `LSMinimumSystemVersion 14.0`, `LSUIElement true`.
- Required usage strings: `NSAccessibilityUsageDescription`, `NSAppleEventsUsageDescription`, `NSScreenCaptureUsageDescription`.

**Probe / bench entry points** (not user-facing):
- `Souffleuse/Sources/SouffleuseAXProbe/main.swift`
- `Souffleuse/Sources/SouffleuseContextProbe/main.swift`
- `Souffleuse/Sources/SouffleuseBench/Bench.swift`
- `Souffleuse/Sources/SouffleuseCoherence/main.swift`
- `Souffleuse/Sources/SouffleuseEnrichmentBench/main.swift`

## Architectural Constraints

- **Threading:** Main thread owns AppKit, AppDelegate, overlay windows, `PredictorViewModel`, `PreferencesStore`. `AXClient` serializes raw AX calls on a private `cocotypist.ax.client` `DispatchQueue` (`SouffleuseAX/AXClient.swift:63`). `ContextEnricher` and `TypingHistoryStore` are Swift `actor`s. MLX inference runs on a detached `Task` (cooperative thread pool), cancelled per keystroke.
- **Swift 6 strict concurrency** enabled (`swiftLanguageModes: [.v6]` in `Souffleuse/Package.swift:112`). All boundary types are `Sendable`.
- **Global state:**
  - `LogWriter.shared` singleton with private serial queue (`SouffleuseLog/Log.swift:51`).
  - `NSSpellChecker.shared` inside `TypoDetector` (process-wide).
  - `MainActor` singletons: the delegate holds `axClient`, `predictor`, `overlay`, `presence`, `interceptor`, `enricher`, `typoDetector`, `caretResolver`, `store`.
- **Sandbox:** None. Accessibility API requires sandbox exit → distribution is hors Mac App Store, signed Developer ID + notarized.
- **Network:** Direct network use is restricted to MLX model downloads via `mlx-swift-examples` (Hugging Face). No telemetry, no update pings, no Sparkle in v1 (planned). The `audit.sh` script enforces this in shipping targets.
- **Privacy invariants enforced by `audit.sh`:** no `print(`, no `NSLog`, no `os_log` interpolating user fields, log file fields restricted to `{ts, level, module, event, count}`, `history.aes` only referenced from `TypingHistoryStore` + `HistoryViewerWindow`, no `Log.*` call interpolating `accepted` / `contextBefore` / `entry.` / `prefix`.
- **No XPC isolation yet.** The architecture doc (`ARCHITECTURE.md` §5.bis) targets a 3-process split (UI / AXAgent / InferenceAgent) but the current codebase ships as a single process.

## Anti-Patterns

### Logging user-supplied strings

**What happens:** Calling `Log.info(.context, "clipboard_read_\(text)")` or `print("\(suggestion)")`.
**Why it's wrong:** Violates the "no user text on disk" privacy invariant; would be caught by `audit.sh` checks #1, #3, #6.
**Do this instead:** Use `Log.info(.module, "event_name", count: optionalInt)` with a `StaticString` literal event name and only an integer count payload (`Souffleuse/Sources/SouffleuseLog/Log.swift:23`).

### Reading `history.aes` outside the personalization module

**What happens:** Any file outside `TypingHistoryStore.swift` or `HistoryViewerWindow.swift` opening, decoding, or referencing `history.aes`.
**Why it's wrong:** Bypasses the actor's invariants (keychain key load, capacity cap, zeroing on clear) and breaks `audit.sh` check #5.
**Do this instead:** Inject a `TypingHistoryStore` and call `await store.allEntries()` / `await store.append(_:)` (`Souffleuse/Sources/SouffleusePersonalization/TypingHistoryStore.swift`).

### Generating without cancel-on-keystroke

**What happens:** Kicking off `MLXLMCommon.generate(...)` without bumping the generation counter or capturing it in the stream closure.
**Why it's wrong:** Stale chunks from an older prefix overwrite the current ghost; produces visibly out-of-sync suggestions.
**Do this instead:** Bump `generation`, cancel `currentTask`, capture the new generation in the `onChunk` closure, drop chunks where `generation != captured` (`Souffleuse/Sources/Souffleuse/PredictorViewModel.swift`).

### Touching `NSPanel` / overlay off main

**What happens:** Mutating `OverlayWindow` from `Task.detached` or an `actor` method without hopping to `MainActor`.
**Why it's wrong:** Swift 6 strict concurrency will refuse to compile; AppKit will crash at runtime if forced.
**Do this instead:** Keep overlay calls behind the `@MainActor`-annotated `OverlayWindow` (`Souffleuse/Sources/SouffleuseOverlay/OverlayWindow.swift:7`).

### Recording into history from a blocked bundle

**What happens:** Appending a `TypingHistoryEntry` while focused in 1Password, Keychain, a bank, or a terminal.
**Why it's wrong:** Persists user secrets to disk in defiance of the threat model.
**Do this instead:** Gate the call with `personalizationBundleBlocklist.contains(where: bundleID.hasPrefix)` (`Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift:19`).

## Error Handling

**Strategy:** Swallow + warn at module boundaries; never crash the app. Keychain misses, AX nils, OCR failures, model load errors all collapse into either a `.failed(message)` `LoadState`, an empty `AXSnapshot`, or an empty enrichment prefix.

**Patterns:**
- `do { … } catch { Log.warn(.module, "event_failed") }` — most non-fatal failures.
- `PredictorViewModel.LoadState = .failed(String)` surfaces model load errors to UI without throwing into the run loop.
- `TypingHistoryStore` resets to an empty in-memory state on key/file failures and sets `writeFailedThisSession = true` to avoid retry storms (`Sources/SouffleusePersonalization/TypingHistoryStore.swift`).
- Optional chaining for nullable AX attributes — never force-unwrap AX returns.
- `Task` cancellation via `Task.isCancelled` checks inside MLX streaming closures.

## Cross-Cutting Concerns

**Logging:** All modules import `SouffleuseLog` and call `Log.info/warn/error` with `StaticString` event names. File at `~/Library/Logs/Souffleuse.log`, size-rotated at 1 MB with 3 backups (`Sources/SouffleuseLog/Log.swift:58`).

**Validation:** Bundle ID prefix matching against `personalizationBundleBlocklist` and `bundleBlocklist` (`Sources/Souffleuse/SouffleuseAppDelegate.swift:19-44`); AX role/subrole filtering via `AXClient.textRoles`; OCR/clipboard caps in `EnrichedContext`; word-length floor + Levenshtein cap in `TypoDetector`.

**Authentication / Permissions:** `AXClient.ensureTrusted(prompt:)` for Accessibility, `ScreenCapturer.hasPermission()` + `forcePermissionPrompt()` for Screen Recording, Keychain `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` for the personalization key.

**Privacy enforcement:** `audit.sh` script at `Souffleuse/audit.sh` (6 checks) gates shipping targets.

---

*Architecture analysis: 2026-05-24*
