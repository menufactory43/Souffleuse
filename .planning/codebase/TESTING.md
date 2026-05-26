# Testing Patterns

**Analysis Date:** 2026-05-24

## Test Framework

**Runner:** Swift Testing (the `Testing` module, Apple's modern replacement for XCTest). All test files `import Testing` and decorate functions with `@Test`.

**Assertion macro:** `#expect(...)` from `Testing`. No XCTest `XCTAssert*` calls anywhere in the suite.

**Test target:** `SouffleuseTests` declared in `Souffleuse/Package.swift:99-110`. It depends on every shipping library and on the executable target `Souffleuse` (using `@testable import`).

**Config file:** None — Swift Testing requires no separate config. Test discovery is automatic via `@Test` annotations.

**Run commands:**
```bash
cd Souffleuse
swift test                                              # Run all tests
swift test --filter SouffleuseTests.chunkSplitsFirstWord  # Filter by name substring
swift test --enable-code-coverage                       # With coverage
xcrun llvm-cov report .build/debug/SouffleusePackageTests.xctest/Contents/MacOS/SouffleusePackageTests \
  -instr-profile=.build/debug/codecov/default.profdata  # View coverage
./audit.sh                                              # Privacy / logging audit (not a unit test, run alongside)
```

## Test File Organization

**Location:** `Souffleuse/Tests/SouffleuseTests/`. A single test target groups every module's tests — no per-module test target.

**Naming:**
- File: `{TypeUnderTest}Tests.swift`. Examples: `ChunkSplitterTests.swift`, `CaretResolverTests.swift`, `NgramTests.swift`, `PersonalizationTests.swift`, `SimilarHistoryRetrievalTests.swift`.
- The catch-all `SouffleuseTests.swift` (~39 tests) holds tests that span multiple small types (`TypoDetector`, `OverlayWindow` geometry, `CaretEstimator`, allowlist matching).
- Test functions read as full sentences describing the behaviour, no `test_` prefix: `chunkSplitsFirstWordWithTrailingSpace`, `caretEstimatorClampsOverflowToFieldBounds`, `historyEncryptedRoundTrip`, `resolverDoesNotQueueDuplicateOCRWhileInFlight`.

**Suite count (snapshot):**
- `ChunkSplitterTests.swift` — 15 tests
- `CaretResolverTests.swift` — 12 tests
- `NgramTests.swift` — 5 tests
- `PersonalizationTests.swift` — 9 tests
- `SimilarHistoryRetrievalTests.swift` — 14 tests
- `SouffleuseTests.swift` — 39 tests
- **Total:** ~94 tests.

## Test Structure

**Free-function tests** — Swift Testing's preferred style. No `XCTestCase` subclasses; tests live as top-level functions.

```swift
import Testing
@testable import SouffleuseTyping

@Test func chunkSplitsFirstWordWithTrailingSpace() {
    #expect(ChunkSplitter.nextChunk("Je m'appelle Gabriel", trailingSpace: true) == "Je ")
}
```

**MainActor isolation:**
- Tests touching AppKit / `@MainActor` types are annotated individually:
  ```swift
  @MainActor
  @Test func overlayEstimatedFontReturnsNilForZeroHeight() {
      #expect(OverlayWindow.estimatedFont(forCaretRectHeight: 0) == nil)
  }
  ```
- See every overlay/caret test in `Tests/SouffleuseTests/SouffleuseTests.swift` and `CaretResolverTests.swift`.

**Async tests:**
- `@Test func ngramReturnsHigherProbForSeenSequence() async` — actor-bound code awaited directly inside the test body.
- `@Test func historyEncryptedRoundTrip() async throws` — `throws` declared when calls inside (e.g. `try Data(contentsOf:)`) can throw.

**Section markers:**
- `// MARK: - GroupName` separates feature groups within a file. See `Tests/SouffleuseTests/PersonalizationTests.swift` (`// MARK: - SecretHeuristic`, `// MARK: - TypingHistoryStore`) and `Tests/SouffleuseTests/CaretResolverTests.swift` (`// MARK: - Test doubles`, `// MARK: - Fixtures`, `// MARK: - Tests`).

**Assertion patterns:**
- Equality: `#expect(result == expected)`.
- Optional present: `#expect(result != nil)` followed by `#expect(result!.field == ...)`.
- Bool with a message: `#expect(Bool(false), "expected to find a word")` — used inside `guard ... else { ... return }` to fail explicitly without unwrapping.
- Floating-point tolerance: `#expect(abs(r!.minX - expectedX) < 0.5)` — never `==` for `CGFloat` math (see `caretEstimatorAfterSingleLineText` in `SouffleuseTests.swift:101-113`).

## Mocking

**No mocking framework** — test doubles are hand-written, typically as nested `actor` types inside the test file.

**Protocol-driven seams:**
- Production code defines a small protocol that the actor under test depends on. The real implementation and the mock both conform.
- Example (`Sources/SouffleuseContext/OCRCaretLocator.swift` defines `OCRCaretLocating`; `Tests/SouffleuseTests/CaretResolverTests.swift:13-44` implements `MockOCRCaretLocator: OCRCaretLocating`):
  ```swift
  actor MockOCRCaretLocator: OCRCaretLocating {
      private(set) var callCount: Int = 0
      var nextResult: OCRCaretResult? = nil
      var holdUntilComplete: Bool = false
      // ... `setNextResult`, `setHoldUntilComplete`, `complete()` helpers
  }
  ```

**Deterministic stalling for async code:**
- `MockOCRCaretLocator` uses `CheckedContinuation` to suspend the call until the test explicitly invokes `complete()`. This lets a test assert that an async op is in-flight before any result lands. See `resolverEstimatesAndQueuesOCRWhenBundleIsBrave` (`CaretResolverTests.swift:104-119`).

**Test-only constructors:**
- `TypingHistoryStore` exposes `init(fileURL: URL, testKey: SymmetricKey)` so tests inject their own URL + symmetric key, bypassing the Keychain. See `Sources/SouffleusePersonalization/TypingHistoryStore.swift` and the `makeStore` helper in `Tests/SouffleuseTests/PersonalizationTests.swift:15-20`.
- `AllowlistStore` accepts a `fileURL:` overload for the same reason.

**What to mock:**
- External or expensive collaborators: OCR (`OCRCaretLocating`), filesystem (via test URLs), Keychain (via injected key).

**What NOT to mock:**
- Pure value types and pure functions — exercised directly with literal inputs (`ChunkSplitter.nextChunk(...)`, `TypoDetector.lastWord(...)`, `SimilarHistoryRetrieval.tokenize(...)`).
- `NgramModel`, `TypingHistoryStore` — real actor instances are used in tests; the actor itself is the unit under test.
- `NSSpellChecker`, AppKit types — used live (some tests are `@MainActor` for this reason).

## Fixtures and Factories

**Inline helpers at the top of each test file:**
- `Tests/SouffleuseTests/CaretResolverTests.swift:48-67` — `snapshot(bundleID:text:caretIndex:elementRect:caretRect:caretFont:)` factory with sensible defaults so each test overrides only the field it cares about.
- `Tests/SouffleuseTests/PersonalizationTests.swift:8-23` — `tempStoreURL`, `makeStore`, `makeEntry` helpers.
- `Tests/SouffleuseTests/SimilarHistoryRetrievalTests.swift:8-24` — same pattern with a different namespace (`souffleuse-fewshot-...` temp dir).

**Temp directory pattern for IO tests:**
```swift
private func tempStoreURL(_ tag: String = UUID().uuidString) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("souffleuse-tests-\(tag)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("history.aes")
}
```
Each test passes a unique tag (or relies on UUID) so parallel runs don't collide.

**Cleanup:**
- IO tests end with `await store.clear()` to remove the temp file.
- `try? FileManager.default.removeItem(at: url)` is used before creating a store to reset any prior state.

**Wait helper:**
- `private func wait(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }` in `CaretResolverTests.swift:69-71`. Used to yield the runloop briefly so spawned `Task`s have a chance to enter `await`.

## Coverage

**No enforced threshold.** Coverage is generated on-demand via `swift test --enable-code-coverage` and inspected with `xcrun llvm-cov`. A `default.profraw` artifact lives at `Souffleuse/default.profraw` (regenerable, listed in `Souffleuse/.gitignore:14` as `*.profraw`).

**Implicit coverage strategy:**
- Pure functions get exhaustive table-driven tests (every branch of `ChunkSplitter.nextChunk`, every edge case of `TypoDetector.lastWord`).
- Actors get behaviour tests through their public API.
- AppKit-heavy code (`SouffleuseAppDelegate`, `PredictorViewModel`) is sparsely unit-tested; correctness there is validated through CLI probes (`SouffleuseAXProbe`, `SouffleuseContextProbe`) and benches (`SouffleuseBench`, `SouffleuseCoherence`, `SouffleuseEnrichmentBench`).

## Test Types

**Unit tests:**
- Pure-function suites: `ChunkSplitterTests.swift`, parts of `SouffleuseTests.swift` (TypoDetector, OverlayWindow geometry, CaretEstimator).
- Actor behaviour: `NgramTests.swift`, `PersonalizationTests.swift`, `SimilarHistoryRetrievalTests.swift`.

**Integration tests:**
- `CaretResolverTests.swift` — exercises `CaretResolver` (a `@MainActor` orchestrator) together with a mock OCR locator, asserting on Task lifecycle and cooldown logic.
- `PersonalizationTests.swift` — round-trips the real AES-GCM encryption layer through the filesystem.

**End-to-end / benchmarks (not via `swift test`):**
- Separate executable targets run head-to-head measurements: `SouffleuseBench`, `SouffleuseCoherence`, `SouffleuseEnrichmentBench`. Their results are tracked in `Souffleuse/BENCHMARKS.md` and `Souffleuse/benchmarks/`.
- Probes (`SouffleuseAXProbe`, `SouffleuseContextProbe`) are interactive diagnostic tools, not regression tests.

**Privacy / linting audit:**
- `Souffleuse/audit.sh` is the closest thing to a CI lint. It enforces:
  1. No `print(` in shipping targets.
  2. No `NSLog(` in shipping targets.
  3. No `os_log(...%@...userText)` interpolation.
  4. Log file fields constrained to `ts level module event count`.
  5. `history.aes` only read inside `TypingHistoryStore.swift` and `HistoryViewerWindow.swift`.
  6. No `Log.*` call interpolating `accepted`, `contextBefore`, `entry.*`, or `prefix`.

## Common Patterns

**Async actor testing:**
```swift
@Test func ngramReturnsHigherProbForSeenSequence() async {
    let model = NgramModel()
    await model.ingest(tokens: [1, 2, 3, 4])
    await model.ingest(tokens: [1, 2, 3, 4])
    await model.ingest(tokens: [1, 2, 3, 5])
    let seen = await model.bonus(nextToken: 4, given: [2, 3])
    let unseen = await model.bonus(nextToken: 99, given: [2, 3])
    #expect(seen > unseen)
    #expect(seen > 0)
    #expect(unseen == 0)
}
```

**MainActor + async coordination with a mock:**
```swift
@MainActor
@Test func resolverEstimatesAndQueuesOCRWhenBundleIsBrave() async {
    let mock = MockOCRCaretLocator()
    await mock.setHoldUntilComplete(true)
    let resolver = CaretResolver(locator: mock)
    let snap = snapshot()

    let estimate = resolver.resolve(snapshot: snap) {}
    #expect(estimate != nil)
    await wait(100)                                    // yield so the spawned Task runs
    #expect(resolver.pendingOCRBundles.contains("com.brave.Browser"))
    let count = await mock.callCount
    #expect(count == 1)
    await mock.complete()                              // unblock the dangling Task
}
```

**Negative assertions for noisy IO:**
```swift
@Test func historyEncryptedRoundTrip() async throws {
    // ... append entries ...
    let raw = try Data(contentsOf: url)
    let asString = String(data: raw, encoding: .utf8) ?? ""
    #expect(!asString.contains("Bonjour"))             // file must NOT be plaintext
}
```

**Encryption corruption recovery:**
```swift
@Test func historyDecryptCorruptFileResetsToEmpty() async throws {
    let url = tempStoreURL("corrupt")
    try Data((0..<256).map { _ in UInt8.random(in: 0...255) }).write(to: url)
    let store = TypingHistoryStore(fileURL: url, testKey: SymmetricKey(size: .bits256))
    let count = await store.count()
    #expect(count == 0)
}
```

**Ring-buffer rotation:**
```swift
@Test func historyRingBufferRotatesAtMax() async throws {
    let (store, _, _) = makeStore("ring")
    for i in 0..<(TypingHistoryStore.maxEntries + 50) {
        await store.append(makeEntry("phrase numéro \(i)"))
    }
    let count = await store.count()
    #expect(count == TypingHistoryStore.maxEntries)
    let entries = await store.allEntries()
    #expect(entries.first?.accepted == "phrase numéro 50")  // FIFO drop
}
```

## When Writing New Tests

- Place the file under `Souffleuse/Tests/SouffleuseTests/` named `{TypeUnderTest}Tests.swift`. Add it to the same `SouffleuseTests` target by ensuring its module dependency is listed in `Package.swift:99-110`.
- Use `@Test func descriptiveSentence()` — no class, no `test_` prefix.
- Add `@MainActor` when touching AppKit / `@MainActor`-isolated types.
- Mark the function `async` (and optionally `throws`) when calling actor methods or throwing APIs.
- For dependencies, prefer extending an existing protocol seam and hand-rolling an `actor` mock in the test file. Don't add a mocking library.
- For temp-file IO, copy the `tempStoreURL` / `makeStore` helper pattern; always pass a unique tag and call `clear()` at the end.
- Assert floats with `abs(a - b) < tolerance`, not `==`.

---

*Testing analysis: 2026-05-24*
