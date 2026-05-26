# Codebase Structure

**Analysis Date:** 2026-05-24

## Directory Layout

```
cocotypist/
├── ARCHITECTURE.md             # Long-form product/architecture doc (FR)
├── NEXT-MILESTONE-NOTES.md     # WIP next-milestone scratchpad
├── benchmarks/                 # Top-level bench artefacts
│   └── bench-personalization-AB-2026-05-22.jsonl
├── Souffleuse/                 # The macOS app (SwiftPM project root)
│   ├── Package.swift           # SPM manifest, Swift 6, macOS 14+
│   ├── Package.resolved
│   ├── audit.sh                # Privacy invariants gate (6 checks)
│   ├── make-app.sh             # Build + bundle + codesign script
│   ├── default.profraw         # Coverage artefact (build leftover)
│   ├── BENCHMARKS.md           # Bench protocol + results
│   ├── JALON1.md               # Milestone 1 notes
│   ├── JALON2-PLAN.md
│   ├── JALON2.5-PLAN.md
│   ├── JALON3-PLAN.md
│   ├── JALON3X-PARTIAL-ACCEPT-PLAN.md
│   ├── JALON3X-PERSONALIZATION-PLAN.md
│   ├── Resources/              # Bundle resources packaged by make-app.sh
│   │   ├── Info.plist
│   │   └── AppIcon.icns
│   ├── Souffleuse/             # Mirror of Resources/ (Xcode bundle layout)
│   │   └── Resources/
│   │       ├── Info.plist
│   │       └── AppIcon.icns
│   ├── benchmarks/
│   │   └── bench-results/
│   ├── Sources/                # All Swift sources (per SPM target)
│   │   ├── Souffleuse/         # Main executable target
│   │   ├── SouffleuseAX/       # Library: AX wrapper
│   │   ├── SouffleuseContext/  # Library: enrichment + OCR
│   │   ├── SouffleuseInput/    # Library: CGEventTap
│   │   ├── SouffleuseLog/      # Library: structured logging
│   │   ├── SouffleuseOverlay/  # Library: ghost / presence NSPanels
│   │   ├── SouffleusePersonalization/  # Library: encrypted history + ngram
│   │   ├── SouffleuseTyping/   # Library: emoji / typo / word complete
│   │   ├── SouffleuseAXProbe/  # CLI: interactive AX/overlay tester
│   │   ├── SouffleuseContextProbe/  # CLI: enrichment harness
│   │   ├── SouffleuseBench/    # CLI: MLX TTFT/throughput bench
│   │   ├── SouffleuseCoherence/  # CLI: LLM coherence harness
│   │   └── SouffleuseEnrichmentBench/  # CLI: A/B personalization
│   └── Tests/
│       └── SouffleuseTests/    # XCTest target
└── .planning/
    └── codebase/               # Generated codebase maps (this folder)
```

## Directory Purposes

**`Souffleuse/` (SwiftPM project root):**
- Purpose: The entire shipping app + tests + probes + benches as one Swift package.
- Contains: `Package.swift`, build scripts, milestone plans, resources, sources, tests.
- Key files: `Package.swift`, `audit.sh`, `make-app.sh`, `Resources/Info.plist`.

**`Souffleuse/Sources/Souffleuse/`:**
- Purpose: The `Souffleuse` executable target — AppKit shell, orchestrator, all SwiftUI/NSWindow UIs, preferences, model picker.
- Contains: Delegate, ViewModels, Window classes, preferences store.
- Key files: `main.swift`, `SouffleuseAppDelegate.swift` (1188 lines, the orchestrator), `PredictorViewModel.swift` (870 lines, MLX + personalization plumbing), `PreferencesStore.swift`, `PreferencesWindow.swift`, `CaretResolver.swift`, `AllowlistConfig.swift`, `OnboardingWindow.swift`, `CustomInstructionsWindow.swift`, `HistoryViewerWindow.swift`.

**`Souffleuse/Sources/SouffleuseAX/`:**
- Purpose: All `AXUIElement` interaction — focused element, text, caret index, caret rect, font, AX observers.
- Contains: One file: `AXClient.swift` (662 lines) defining `AXFontInfo`, `AXSnapshot`, `AXClient`.

**`Souffleuse/Sources/SouffleuseContext/`:**
- Purpose: Build LLM prompt prefix from app metadata, clipboard, screen capture, OCR. Plus OCR-based caret fallback.
- Contains: `ContextEnricher.swift` (actor), `AppContextProbe.swift`, `ClipboardReader.swift`, `ScreenCapturer.swift`, `VisionOCR.swift`, `OCRCaretLocator.swift`.

**`Souffleuse/Sources/SouffleuseInput/`:**
- Purpose: `CGEventTap` for Tab/Esc consumption while a suggestion is showing.
- Contains: `KeyInterceptor.swift` (92 lines).

**`Souffleuse/Sources/SouffleuseOverlay/`:**
- Purpose: Floating gray ghost text + presence indicator badge as `NSPanel`s.
- Contains: `OverlayWindow.swift`, `PresenceIndicatorWindow.swift`, `CaretEstimator.swift`, embedded `Resources/PresenceMark.png` (declared via `resources: [.process("Resources")]` in `Package.swift`).

**`Souffleuse/Sources/SouffleuseLog/`:**
- Purpose: Append-only event-only logging with rotation.
- Contains: `Log.swift` (Log facade, LogWriter, LogLevel, LogModule).

**`Souffleuse/Sources/SouffleusePersonalization/`:**
- Purpose: Encrypted typing history (AES-GCM at rest, key in Keychain), n-gram model + MLX logit bias, few-shot retrieval.
- Contains: `TypingHistoryStore.swift`, `TypingHistoryEntry.swift`, `KeychainKey.swift`, `NgramModel.swift`, `NgramBuilder.swift`, `NgramSnapshot.swift`, `NgramLogitBias.swift`, `ChainLogitProcessor.swift`, `SimilarHistoryRetrieval.swift`.

**`Souffleuse/Sources/SouffleuseTyping/`:**
- Purpose: Non-LLM text helpers (orchestrator composes these around the ghost).
- Contains: `EmojiExpander.swift`, `TypoDetector.swift`, `WordCompleter.swift`, `ChunkSplitter.swift`.

**`Souffleuse/Sources/Souffleuse{AXProbe,ContextProbe,Bench,Coherence,EnrichmentBench}/`:**
- Purpose: Standalone CLI executables for development, probing, and benchmarking. Each has a single `main.swift` (or `Bench.swift`).
- Not shipped to end users.

**`Souffleuse/Tests/SouffleuseTests/`:**
- Purpose: XCTest target covering the main executable + shipping libraries.
- Contains: `SouffleuseTests.swift`, `CaretResolverTests.swift`, `ChunkSplitterTests.swift`, `NgramTests.swift`, `PersonalizationTests.swift`, `SimilarHistoryRetrievalTests.swift`.

**`Souffleuse/Resources/` and `Souffleuse/Souffleuse/Resources/`:**
- Purpose: Bundle resources — `Info.plist`, `AppIcon.icns`. The duplicated layout mirrors what Xcode and `make-app.sh` each expect.
- Generated: No.
- Committed: Yes.

**`Souffleuse/benchmarks/bench-results/` and `benchmarks/`:**
- Purpose: Bench output JSONL.
- Generated: Yes (by the bench executables).
- Committed: Partially — the A/B bench result is tracked.

**`.planning/codebase/`:**
- Purpose: Generated codebase maps consumed by GSD planning/execution commands.
- Generated: Yes.
- Committed: Yes (project workflow convention).

## Key File Locations

**Entry Points:**
- `Souffleuse/Sources/Souffleuse/main.swift`: AppKit bootstrap (5 lines) — installs `SouffleuseAppDelegate`.
- `Souffleuse/Sources/SouffleuseAXProbe/main.swift`: CLI probe for AX + overlay + injection.
- `Souffleuse/Sources/SouffleuseContextProbe/main.swift`: CLI probe for the enrichment pipeline.
- `Souffleuse/Sources/SouffleuseBench/Bench.swift`: TTFT/throughput benchmark.
- `Souffleuse/Sources/SouffleuseCoherence/main.swift`: LLM coherence harness.
- `Souffleuse/Sources/SouffleuseEnrichmentBench/main.swift`: A/B personalization bench.

**Configuration:**
- `Souffleuse/Package.swift`: SPM manifest. Swift 6, macOS 14+, declares 7 libraries + 5 executables + 1 test target. Single external dependency: `mlx-swift-examples` `>= 2.0.0`.
- `Souffleuse/Resources/Info.plist`: Bundle ID `app.cocotypist.Souffleuse`, version 0.2.0, `LSUIElement true`, accessibility/AppleEvents/screen-capture usage strings.
- `Souffleuse/audit.sh`: Privacy invariants gate (run before release).
- `Souffleuse/make-app.sh`: Xcode build + bundle + codesign.
- `Souffleuse/.gitignore`: SwiftPM/Xcode standard ignores.
- `Souffleuse/Package.resolved`: Pinned dependency versions.

**Core Logic:**
- `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift`: Orchestrator (80 ms tick, debounce, key handling, focus changes, preferences observation).
- `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift`: MLX lifecycle + streaming generation + caching + n-gram bias.
- `Souffleuse/Sources/SouffleuseAX/AXClient.swift`: All AX reads/writes.
- `Souffleuse/Sources/SouffleuseContext/ContextEnricher.swift`: Prompt-prefix builder.
- `Souffleuse/Sources/SouffleuseOverlay/OverlayWindow.swift`: Ghost text panel.
- `Souffleuse/Sources/SouffleuseInput/KeyInterceptor.swift`: Tab/Esc event tap.
- `Souffleuse/Sources/SouffleusePersonalization/TypingHistoryStore.swift`: Encrypted history actor.

**Testing:**
- `Souffleuse/Tests/SouffleuseTests/`: All XCTest cases (~6 files).

**Documentation:**
- `ARCHITECTURE.md` (repo root): Long-form FR product/architecture doc — north star.
- `Souffleuse/JALON*.md`: Milestone-by-milestone plans + retrospectives.
- `Souffleuse/BENCHMARKS.md`: Bench protocol + readings.
- `NEXT-MILESTONE-NOTES.md` (repo root): WIP scratchpad.

## Naming Conventions

**Files:**
- Swift source files: `PascalCase.swift` — one primary type per file, file name matches the type (e.g. `AXClient.swift`, `OverlayWindow.swift`, `PredictorViewModel.swift`).
- Executable target entry points: `main.swift` (or `Bench.swift` for SouffleuseBench).
- Test files: `<TypeUnderTest>Tests.swift` (`CaretResolverTests.swift`).
- Markdown plans: `UPPERCASE.md` or `JALON<n>[-<slug>].md`.

**Directories:**
- SPM target name = directory name = product name, all in `Souffleuse*` PascalCase (e.g. `SouffleuseContext/`).
- Library target prefix `Souffleuse<Domain>`, executable probe/bench prefix follows the same scheme (`SouffleuseAXProbe`, `SouffleuseBench`).
- Resources live in a `Resources/` subdirectory of the target that owns them (`Souffleuse/Sources/SouffleuseOverlay/Resources/`).

**Code identifiers:**
- Types: `PascalCase` (`AXSnapshot`, `OverlayWindow`).
- Methods / vars: `camelCase` (`caretRect`, `handleKey`).
- Constants: `camelCase`, often `static let` on the owning type (e.g. `TypingHistoryStore.maxEntries`).
- Bundle ID convention: `app.cocotypist.Souffleuse`. Reverse-DNS prefix `dev.cocotypist.*` used internally for dispatch queue labels (`dev.cocotypist.Souffleuse.log`).
- Log event names: `snake_case` `StaticString` literals (`"history_keychain_unavailable"`, `"key_interceptor_install_failed"`, `"screen_recording_permission_missing"`).
- Threat-modelled blocklists: bundle-ID prefixes (`com.1password`, `com.apple.keychainaccess`) defined as module-level `private let` arrays in `SouffleuseAppDelegate.swift`.

## Where to Add New Code

**New feature spanning AX + UI + LLM:**
- Orchestration glue: extend `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift` (consider extracting if it crosses 1300 lines).
- AX read/write helpers: add to `Souffleuse/Sources/SouffleuseAX/AXClient.swift`.
- Prompt prefix change: extend `Souffleuse/Sources/SouffleuseContext/ContextEnricher.swift` (add new source, plumb caps into `EnrichedContext`).
- LLM behavior change: `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` (mind the `generation` counter + `predictCache` key).
- Tests: add a new file `Souffleuse/Tests/SouffleuseTests/<Feature>Tests.swift`.

**New library module:**
1. Create `Souffleuse/Sources/Souffleuse<Domain>/` with at least one `.swift` file.
2. In `Souffleuse/Package.swift`: add a `.library(name:targets:)` product, a `.target(name:dependencies:)` entry, and add the new target name to `Souffleuse` executable's `dependencies`.
3. If you ship into the audit set, append the path to `SHIPPING_DIRS` in `Souffleuse/audit.sh`.
4. If the module has resources, mirror the `SouffleuseOverlay` pattern (`resources: [.process("Resources")]`).

**New CLI probe or bench:**
1. Create `Souffleuse/Sources/Souffleuse<Name>/main.swift` (one file is enough).
2. In `Package.swift`: add `.executable(name:targets:)` product and `.executableTarget(name:dependencies:)`.
3. Do NOT add to `audit.sh` shipping dirs — probes/benches are dev-only and may use `print`.

**New persisted state:**
- UI toggle / scalar: extend `PreferencesStore` (`Souffleuse/Sources/Souffleuse/PreferencesStore.swift`) — uses `UserDefaults` under the hood. Wire to `observePreferences()` if behavior must react.
- Encrypted user-text-adjacent data: it MUST go through an actor like `TypingHistoryStore`. Update `audit.sh` rule #5 if introducing a new sealed file path.
- Plain JSON config (allowlist, snippets): place under `~/Library/Application Support/Souffleuse/<name>.json`; pattern in `AllowlistConfig.swift`.

**New shared helper / utility:**
- Cross-cutting and pure: `Souffleuse/Sources/SouffleuseTyping/` if it operates on user-typed text.
- Crypto / personalization-adjacent: `Souffleuse/Sources/SouffleusePersonalization/`.
- Tiny constants used by the orchestrator only: keep inside `Souffleuse/Sources/Souffleuse/` as a `private let` at file scope.

**New UI window:**
- Add `<Name>Window.swift` in `Souffleuse/Sources/Souffleuse/` following the existing pattern (`PreferencesWindow.swift`, `OnboardingWindow.swift`, `HistoryViewerWindow.swift`, `CustomInstructionsWindow.swift`).
- Hold the window via an optional property on `SouffleuseAppDelegate` so it survives a single show/hide cycle.
- For sensitive content windows, set `panel.sharingType = .none` (per the threat model in repo-root `ARCHITECTURE.md` §5.bis).

**New log event:**
- Use `Log.info/warn/error(.module, "snake_case_event_literal", count: optionalInt)` from any module.
- NEVER interpolate user-supplied text into the event string — `audit.sh` check #6 will fail and the compiler will refuse a non-`StaticString` literal.

## Special Directories

**`Souffleuse/.build/`:**
- Purpose: SwiftPM build cache.
- Generated: Yes.
- Committed: No (`.gitignore`).

**`Souffleuse/.swiftpm/`:**
- Purpose: SwiftPM/Xcode local config (schemes, etc.).
- Generated: Yes.
- Committed: No.

**`Souffleuse/build/`:**
- Purpose: `xcodebuild -derivedDataPath ./build` output (used by `make-app.sh`).
- Generated: Yes.
- Committed: No.

**`Souffleuse/benchmarks/bench-results/`:**
- Purpose: Bench executable JSONL output.
- Generated: Yes.
- Committed: Selectively (only meaningful A/B runs).

**Runtime user-data locations (not in repo):**
- `~/Library/Application Support/Souffleuse/` — `history.aes`, `models/`, JSON profiles.
- `~/Library/Logs/Souffleuse.log` (+ `.1`, `.2`, `.3` rotated backups) — structured event log.
- `~/Library/Preferences/app.cocotypist.Souffleuse.plist` — `UserDefaults`-backed prefs.
- `~/Library/Keychains/login.keychain-db` — AES-256 history key (service tied to bundle ID).

---

*Structure analysis: 2026-05-24*
