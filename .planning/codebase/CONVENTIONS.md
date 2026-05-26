# Coding Conventions

**Analysis Date:** 2026-05-24

## Language & Tooling

**Language:** Swift 6.3 in language mode `.v6` (strict concurrency enforced).
**Build system:** Swift Package Manager (`Souffleuse/Package.swift`).
**Platform:** macOS 14+ exclusively.
**Linter/Formatter:** None configured — no `.swift-format`, `.swiftlint.yml`, or equivalent at the repo root. Style is enforced informally and via code review.

## Naming Patterns

**Files:**
- One primary type per file, file name matches the type. Examples: `Sources/SouffleuseTyping/ChunkSplitter.swift`, `Sources/SouffleuseAX/AXClient.swift`, `Sources/Souffleuse/AllowlistConfig.swift`.
- Test files mirror the type name with a `Tests` suffix: `Tests/SouffleuseTests/ChunkSplitterTests.swift`, `Tests/SouffleuseTests/CaretResolverTests.swift`.
- Loose grouping when several related types share a file (e.g. `AllowlistConfig.swift` holds `AllowlistMode`, `AllowlistRule`, `AllowlistFile`, `AllowlistStore`).

**Types:**
- `UpperCamelCase` for `struct`, `class`, `actor`, `enum`, `protocol`. Examples: `TypoDetector`, `NgramModel`, `OverlayWindow`, `CaretResolver`.
- Probe/Bench executables prefixed with `Souffleuse`: `SouffleuseAXProbe`, `SouffleuseCoherence`, `SouffleuseEnrichmentBench`.
- Protocols use `-ing` suffix when describing a role: `OCRCaretLocating` (see `Sources/SouffleuseContext/OCRCaretLocator.swift`).

**Functions / Properties:**
- `lowerCamelCase`. Examples: `nextChunk`, `lastWord`, `checkLastWord`, `currentWordLooksSuspect`, `setActive`.
- Boolean properties read as predicates: `isEmpty`, `holdUntilComplete`, `automaticallyIdentifiesLanguages`.
- Static constants for thresholds live on the type: `TypoDetector.maxLevenshtein`, `TypoDetector.minWordLength`, `EnrichedContext.clipboardCap`, `TypingHistoryStore.maxEntries`.

**Modules / Targets:**
- Every reusable concern is a SPM library target prefixed with `Souffleuse`: `SouffleuseAX`, `SouffleuseOverlay`, `SouffleuseInput`, `SouffleuseContext`, `SouffleuseLog`, `SouffleuseTyping`, `SouffleusePersonalization`. The app target itself is `Souffleuse`. Each maps to a directory under `Sources/`.

**UserDefaults keys:**
- Centralised in a nested `private enum K` (string constants), see `Sources/Souffleuse/PreferencesStore.swift`. Never inline string keys at call sites.

## Code Style

**Formatting:**
- 4-space indentation, no tabs.
- Trailing commas in multi-line collection literals (`[`, `.bits256`, `]`).
- One blank line between logical sections; no double blank lines.
- Braces on the same line as the declaration (`func foo() {`).

**Access control:**
- `public` for cross-module API only. Types/methods used inside the same module stay package-default (no keyword) or `internal`.
- `private`, `fileprivate`, `private(set)` used aggressively to lock down state (e.g. `LogEntry` is `fileprivate struct` in `Sources/SouffleuseLog/Log.swift`).
- `@ObservationIgnored` on stored properties that shouldn't trigger view updates (see `AllowlistStore.fileURL`).

**Sendability:**
- Every cross-module value type is explicitly `Sendable`. Examples: `TypoSuggestion: Sendable, Equatable`, `EmojiExpansion: Sendable, Equatable`, `EnrichedContext: Sendable, Equatable`, `LogLevel: String, Sendable`.
- Reference types that cross threads use `@unchecked Sendable` only when the implementation provides its own synchronization, e.g. `final class TypoDetector: @unchecked Sendable` (`Sources/SouffleuseTyping/TypoDetector.swift`) and `final class LogWriter: @unchecked Sendable` (`Sources/SouffleuseLog/Log.swift`, serialised through `DispatchQueue`).
- `@Sendable` closures for callbacks crossing isolation boundaries: `public typealias Handler = @Sendable (Key) -> Bool` in `Sources/SouffleuseInput/KeyInterceptor.swift`.

## Concurrency

**Actor isolation:**
- `@MainActor` for AppKit-touching state: `OverlayWindow`, `PresenceIndicatorWindow`, `SouffleuseAppDelegate`, `AllowlistStore`, `PreferencesStore`, `OnboardingWindow`, etc.
- Plain `actor` for stateful background services: `NgramModel`, `TypingHistoryStore`, `ContextEnricher`. They expose `async` functions and serialise their own mutable state.
- `nonisolated` escape hatches for pure lookups callable from any context: `AllowlistStore.mode(forBundle:windowTitle:rules:)` (`Sources/Souffleuse/AllowlistConfig.swift`).

**Async patterns:**
- `await` chained through actors; no manual `DispatchQueue` calls for new code (only `LogWriter` uses one, intentionally).
- `Task { ... }` spawned from `@MainActor` for fire-and-forget work; pending tasks tracked explicitly (see `CaretResolver.pendingOCRBundles`).
- `CheckedContinuation` only used inside test doubles to deterministically stall an async call (`MockOCRCaretLocator` in `CaretResolverTests.swift`).

## Import Organization

**Order (observed pattern, alphabetical within group):**
1. Apple frameworks: `import AppKit`, `import CoreGraphics`, `import Foundation`, `import CryptoKit`, `import Observation`, `import Testing`.
2. Local modules: `import SouffleuseAX`, `import SouffleuseLog`, `import SouffleusePersonalization`, etc.
3. `@testable import ...` last (test files only).

**Example header** (`Tests/SouffleuseTests/PersonalizationTests.swift:1-4`):
```swift
import CryptoKit
import Foundation
import Testing
@testable import SouffleusePersonalization
```

**No path aliases** — Swift's module system is the only import abstraction.

## Documentation Comments

**Style:**
- Triple-slash `///` for every public type, function, and non-obvious property.
- Multi-line doc comments include rationale, not just signature description. Example from `Sources/SouffleuseLog/Log.swift:14`:
  ```swift
  /// Privacy invariant: ONLY these 5 fields are ever written. The struct (not a
  /// dictionary) enforces it at the type level — no path of code can sneak a
  /// user-supplied string into the file.
  ```
- Inline `//` comments are dense and explain *why*, not *what*. They frequently reference specific apps that motivated the code path (Brave, Notes, Intercom, Cotypist).
- Examples in doc-comments use indented code blocks (no triple-backtick) — see `ChunkSplitter.nextChunk`.

**Section markers:**
- `// MARK: - Section Name` to chunk long files and test suites. See `Tests/SouffleuseTests/PersonalizationTests.swift` (`// MARK: - SecretHeuristic`, `// MARK: - TypingHistoryStore`).

## Error Handling

**Strategy:**
- Throwing functions only at the lowest IO boundary (Keychain, ScreenCapture). Higher layers return optionals or fall back silently.
- Dedicated `Error` enums per subsystem: `KeychainError` in `Sources/SouffleusePersonalization/KeychainKey.swift`, `ScreenCaptureError` in `Sources/SouffleuseContext/ScreenCapturer.swift`.
- Errors are not re-raised across actor boundaries; instead, the actor logs an event and returns nil/default.

**`try?` and silent recovery:**
- Used liberally for non-critical IO: log appends, allowlist persistence, file rotation (`Sources/SouffleuseLog/Log.swift:73-101`). Failure to write a log line must never crash the app.
- Decryption failures of `history.aes` reset the store to empty rather than propagating (see `historyDecryptCorruptFileResetsToEmpty` test).

**Guard-let early returns:**
- Standard Swift idiom, used throughout. Example: `Sources/SouffleuseTyping/TypoDetector.swift:39-43`.

## Logging

**Framework:** Custom `Log` enum in `Sources/SouffleuseLog/Log.swift`. Three levels (`info`, `warn`, `error`), enumerated modules (`ax`, `overlay`, `input`, `context`, `predictor`, `ui`, `log`).

**Privacy invariant (enforced by API + audit script):**
- The event argument is `StaticString` so it MUST be a compile-time literal. No path can interpolate a user-supplied string.
- Only five fields are ever serialised: `ts`, `level`, `module`, `event`, optional `count`.
- `Souffleuse/audit.sh` greps the shipping targets to forbid `print(`, `NSLog(`, `os_log(...%@...userText)`, and any `Log.*` call that interpolates `accepted`, `contextBefore`, `entry.`, or `prefix`.

**Call pattern:**
```swift
Log.warn(.ui, "allowlist_load_corrupt_reset")
Log.error(.ui, "allowlist_write_failed")
Log.info(.predictor, "model_swap_complete", count: 1)
```

**Log destination:** `~/Library/Logs/Souffleuse.log`, rotated at 1 MB, 3 backups.

**Forbidden in shipping targets** (`SHIPPING_DIRS` in `audit.sh`):
- `print(...)` and `NSLog(...)` — fail the audit.
- `os_log` interpolating user text — fail the audit.
- Reading `history.aes` outside `TypingHistoryStore.swift` and `HistoryViewerWindow.swift` — fail the audit.

## Persistence Patterns

**On-disk formats:**
- JSON via `JSONEncoder` with `[.prettyPrinted, .sortedKeys]` for human-readable config (`AllowlistStore.save` in `Sources/Souffleuse/AllowlistConfig.swift:76-78`).
- AES-GCM via `CryptoKit.SymmetricKey` for sensitive history (`Sources/SouffleusePersonalization/TypingHistoryStore.swift`). Key is generated once and stored in Keychain via `KeychainKey`.
- `UserDefaults.standard` for preferences, with typed key constants in `PreferencesStore.K`.

**Versioning:**
- Top-level on-disk struct carries an explicit `version: Int = 1`. See `AllowlistFile` in `Sources/Souffleuse/AllowlistConfig.swift:40`.

**Atomic writes:** `data.write(to: fileURL, options: .atomic)`.

## Function Design

**Size:**
- Most functions stay under ~30 lines. Long bodies (e.g. `OverlayWindow.show`, `SouffleuseAppDelegate.tick`) split into small private helpers (`Self.estimatedFont`, `Self.correctCaretRect`, `Self.appKitFrame`).
- Pure utilities live on the type as `static` functions so they're testable without instantiating: `ChunkSplitter.nextChunk`, `TypoDetector.lastWord`, `TypoDetector.levenshtein`, `CaretEstimator.estimateRect`, `OverlayWindow.estimatedFont`.

**Parameters:**
- Named labels are descriptive — no abbreviations. `func locate(elementRect:bundleID:text:caretIndex:)` not `func locate(_ r:_ b:_ t:_ i:)`.
- Default values used to keep call sites short and to allow incremental API extension (e.g. `caretFont: AXFontInfo? = nil`).

**Return values:**
- Optionals to signal "nothing to do" (typo detection, caret resolution, OCR locator). Callers `if let`/`guard let`.
- Tuples returned with named fields when more than one value: `(range: Range<String.Index>, word: String)` from `TypoDetector.lastWord`.

## Module Design

**Granular targets:**
- Each capability is its own SPM target so the dependency graph stays explicit (see `Souffleuse/Package.swift:9-22`). The shipping executable `Souffleuse` depends on every library; CLI probes pull only the targets they need.
- No barrel files / re-exports. Consumers import the specific module.

**Resource handling:**
- Only `SouffleuseOverlay` declares resources (`.process("Resources")`). Other targets keep their data inline (e.g. `EmojiTable.map` in `Sources/SouffleuseTyping/EmojiExpander.swift:22`).

## Test-Only Hooks

- Production initialisers default to real dependencies; an overload accepts a test seam. Example: `TypingHistoryStore` exposes `init(fileURL: URL, testKey: SymmetricKey)` so tests bypass Keychain, while production uses the convenience `init()`.
- Test doubles live alongside the tests (e.g. `MockOCRCaretLocator` is defined inside `CaretResolverTests.swift` rather than in a separate Mocks/ target).

## Localisation

- UI strings (window titles, labels, menu items) are written in French inline. Examples: `case .active: return "Actif"` (`Sources/Souffleuse/AllowlistConfig.swift:14`). No `.strings` files or `NSLocalizedString` calls — the app is French-first.

---

*Convention analysis: 2026-05-24*
