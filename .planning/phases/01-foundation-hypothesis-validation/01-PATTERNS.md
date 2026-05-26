# Phase 1: Foundation + Hypothesis Validation - Pattern Map

**Mapped:** 2026-05-24
**Files analyzed:** 11 (8 new, 4 modified — counting Package.swift + audit.sh + PredictorViewModel.swift + SouffleuseCoherence/main.swift; 1 data file outside pattern scope)
**Analogs found:** 10 / 10 Swift files (the 1 JSON data file is schema-only)

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `Souffleuse/Sources/SouffleusePrompt/PromptSlot.swift` | enum-of-identifiers | n/a (value taxonomy) | `Souffleuse/Sources/SouffleuseLog/Log.swift` (`LogModule`) | exact |
| `Souffleuse/Sources/SouffleusePrompt/SlotConfig.swift` (aka `PromptBudget.swift`) | config value type | n/a (static config) | `Souffleuse/Sources/SouffleuseContext/ContextEnricher.swift` (`EnrichedContext` + `clipboardCap`/`visibleCap`) | exact (Sendable value + static constants) |
| `Souffleuse/Sources/SouffleusePrompt/BuiltPrompt.swift` | value-type result | transform output | `Souffleuse/Sources/SouffleuseAX/AXClient.swift` (`AXSnapshot`) | exact (Sendable, Equatable, public initializer) |
| `Souffleuse/Sources/SouffleusePrompt/TokenCounting.swift` | protocol seam (test boundary) | pure compute | `Souffleuse/Sources/SouffleuseContext/OCRCaretLocator.swift` (`OCRCaretLocating`) | exact (Sendable protocol with `-ing` suffix; test mock pattern identical) |
| `Souffleuse/Sources/SouffleusePrompt/PromptBuilder.swift` | builder (pure transform) | request-response (input slots → BuiltPrompt) | `Souffleuse/Sources/SouffleuseContext/ContextEnricher.swift` (`EnrichedContext.prefix` assembly) + `Souffleuse/Sources/SouffleusePersonalization/SimilarHistoryRetrieval.swift` (`buildExamplesBlock`) | role-match (pure assembly; not an actor like ContextEnricher) |
| `Souffleuse/Sources/Souffleuse/MLXTokenCounter.swift` | adapter (production protocol impl) | pass-through to MLX tokenizer | `Souffleuse/Sources/SouffleuseContext/OCRCaretLocator.swift` (concrete `OCRCaretLocator: OCRCaretLocating`) | role-match (adapter wraps an opaque framework dep behind a protocol) |
| `Souffleuse/Tests/SouffleuseTests/PromptBuilderTests.swift` | test (snapshot + table) | sync `#expect` | `Souffleuse/Tests/SouffleuseTests/ChunkSplitterTests.swift` | exact (Swift Testing + `@Test` + literal-input pure-function suite) |
| `Souffleuse/Package.swift` (modify) | SPM manifest | declarative config | existing `.target` and `.library` declarations in the same file (lines 9-22, 27-110) | exact (self-precedent) |
| `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` (modify) | controller (orchestrator) | event-driven (debounce + cancel-on-keystroke) | itself; specifically the existing `PredictDebug` env-gated seam at lines 15-36 | exact (in-file self-precedent for env-var dev flag) |
| `Souffleuse/Sources/SouffleuseCoherence/main.swift` (modify) | executable (CLI harness) | request-response (each scenario → ghost) | itself; existing `@main struct Coherence` at line 211 + `rawGhost` at line 181 | exact (extension via sub-command) |
| `Souffleuse/audit.sh` (modify) | bash config | declarative (SHIPPING_DIRS array) | self (lines 7-15) | exact |
| `.planning/.../replay-scenarios.json` | data file (schema = `version: Int = 1` + array) | static config | `Souffleuse/Sources/Souffleuse/AllowlistConfig.swift` (`AllowlistFile` with `version: Int = 1`) | role-match (versioned JSON) |
| `.planning/.../REPLAY-RESULTS.md` | generated markdown | output template | no analog (new artifact); template defined inline in RESEARCH.md §6 | n/a |

---

## Pattern Assignments

### `Souffleuse/Sources/SouffleusePrompt/PromptSlot.swift` (enum of identifiers)

**Analog:** `Souffleuse/Sources/SouffleuseLog/Log.swift` (`LogModule` enum)

**Imports pattern** (Log.swift:1):
```swift
import Foundation
```

**Enum-of-identifiers pattern** (Log.swift:3-9):
```swift
public enum LogLevel: String, Sendable {
    case info, warn, error
}

public enum LogModule: String, Sendable {
    case ax, overlay, input, context, predictor, ui, log
}
```

**Apply to PromptSlot:** Public enum, `String` raw value, `Sendable`. Add `CaseIterable` + `Hashable` since the builder iterates and keys dictionaries by slot. Comment-divide active (Phase 1) vs reserved (Phase 2/3) slots so the comment carries the deferred-slot intent (precedent: `// ── ` section dividers used throughout PredictorViewModel.swift).

**Doc-comment style** (Log.swift:11-13):
```swift
/// Privacy invariant: ONLY these 5 fields are ever written. The struct (not a
/// dictionary) enforces it at the type level — no path of code can sneak a
/// user-supplied string into the file.
```
Triple-slash with rationale, not just description. Apply same to `PromptSlot` (explain Phase 1 vs Phase 2/3 reservation).

---

### `Souffleuse/Sources/SouffleusePrompt/SlotConfig.swift` / `PromptBudget.swift` (config value type)

**Analog:** `Souffleuse/Sources/SouffleuseContext/ContextEnricher.swift` (`EnrichedContext`)

**Sendable + Equatable value type with static caps** (ContextEnricher.swift:3-20):
```swift
public struct EnrichedContext: Sendable, Equatable {
    public let app: String?
    public let windowTitle: String?
    public let clipboard: String?
    public let visible: String?

    /// Caps per source — kept short on purpose. Cotypist-style: a 1B base model
    /// can't integrate 500-char blocks intelligently, and labelled blocks make
    /// the model imitate the label syntax in its output.
    public static let clipboardCap = 200
    public static let visibleCap = 240

    public init(app: String?, windowTitle: String?, clipboard: String?, visible: String?) {
        self.app = app
        self.windowTitle = windowTitle
        self.clipboard = clipboard
        self.visible = visible
    }
```

**Apply to PromptBudget:** Public `struct: Sendable, Equatable`. Stored properties are `public let`. Static defaults (e.g. `phase1Default`) declared on the type, mirroring the `clipboardCap=200`/`visibleCap=240` precedent. Explicit `public init(...)` (the project consistently writes one rather than relying on the synthesized memberwise init being internal).

**Static threshold-as-constant precedent** (`TypoDetector.swift:23-27`):
```swift
public final class TypoDetector: @unchecked Sendable {
    private let checker = NSSpellChecker.shared
    public static let maxLevenshtein = 2
    /// Don't flag very short typos (≤2 chars), too noisy.
    public static let minWordLength = 3
```
Same pattern: numeric thresholds live as `public static let` on the owning type.

---

### `Souffleuse/Sources/SouffleusePrompt/BuiltPrompt.swift` (value-type result)

**Analog:** `Souffleuse/Sources/SouffleuseAX/AXSnapshot` (in `AXClient.swift:10-54`)

**Imports pattern** (AXClient.swift:1-3):
```swift
import ApplicationServices
import AppKit
import Foundation
```

**Sendable value-type result pattern** (AXClient.swift:10-44):
```swift
public struct AXSnapshot: Sendable, Equatable {
    public let bundleID: String?
    public let role: String?
    public let subrole: String?
    public let text: String?
    public let caretIndex: Int?
    public let caretRect: CGRect?
    public let caretFont: AXFontInfo?
    public let windowTitle: String?
    /// Frame of the focused text element itself (Quartz coordinates). Used by
    /// the presence indicator so the badge sticks to the field instead of
    /// chasing the caret as the user types.
    public let elementRect: CGRect?

    public init(
        bundleID: String?,
        role: String?,
        ...
    ) {
        self.bundleID = bundleID
        ...
    }
}
```

**Apply to BuiltPrompt:** Public `struct: Sendable, Equatable`. All stored properties `public let`. Multi-line `public init(...)` with one parameter per line, matching the AXSnapshot style. Doc-comments on non-obvious fields (rationale, not just description — `truncatedSlots: Set<PromptSlot>` deserves a "post-eviction slots; replay tool surfaces these in REPLAY-RESULTS.md" line).

**Derived predicates precedent** (AXSnapshot.isTextElement, lines 46-53):
```swift
public var isTextElement: Bool {
    guard let role else { return false }
    return AXClient.textRoles.contains(role)
}
```
Apply if `BuiltPrompt` needs convenience like `var didEvict: Bool { !truncatedSlots.isEmpty }`.

---

### `Souffleuse/Sources/SouffleusePrompt/TokenCounting.swift` (protocol seam)

**Analog:** `Souffleuse/Sources/SouffleuseContext/OCRCaretLocator.swift` (`OCRCaretLocating` protocol + `OCRCaretLocator` concrete; `MockOCRCaretLocator` in `CaretResolverTests.swift`)

**Protocol-with-`-ing`-suffix + Sendable** (OCRCaretLocator.swift:30-41):
```swift
/// Type the implementation has access to without leaking SouffleuseOverlay
/// types here. Mirrors `CalibratedMetrics` exactly; the resolver translates
/// at the boundary. Kept internal to this module's surface so tests can mock
/// the locator without depending on AppKit-side types.
public protocol OCRCaretLocating: Sendable {
    /// Returns the caret rect derived from OCR-ing `elementRect` on screen,
    /// or nil if the screen could not be captured, OCR yielded nothing
    /// useful, or the prefix `text[0..<caretIndex]` could not be aligned
    /// with the OCR observations.
    func locate(
        elementRect: CGRect,
        bundleID: String,
        text: String,
        caretIndex: Int
    ) async -> OCRCaretResult?
}
```

**Apply to TokenCounting:** Protocol named with `-ing` suffix, `public`, `Sendable`. Methods are sync (not `async`) since tokenization is in-process. Doc-comment explains WHY the seam exists ("Production: thin wrapper over MLX `Tokenizer.encode(text:).count`. Tests: deterministic mock so snapshot assertions don't depend on a loaded MLX model.") — same rationale-first style as `OCRCaretLocating`.

**Concrete `actor` vs `struct`:** OCRCaretLocator is an `actor` because it serialises capture/Vision dispatch. The tokenizer adapter has no internal state to serialise — make `MLXTokenCounter` a `Sendable struct`, matching `EnrichedContext`/`AXSnapshot` precedent for stateless value types.

---

### `Souffleuse/Sources/SouffleusePrompt/PromptBuilder.swift` (pure assembly builder)

**Analog:** `Souffleuse/Sources/SouffleuseContext/ContextEnricher.swift` (`EnrichedContext.prefix` computed property — the closest existing "assemble strings into a single prompt prefix with per-source caps" pattern)

**String assembly with per-source caps** (ContextEnricher.swift:22-46):
```swift
/// Compact inline prose. No `[Label:]` syntax — those make a base model
/// imitate the structure. Returns "" if no signal at all.
public var prefix: String {
    var bits: [String] = []
    if let app, !app.isEmpty {
        if let title = windowTitle, !title.isEmpty {
            bits.append("App \(app), window \"\(title)\".")
        } else {
            bits.append("App \(app).")
        }
    }
    if let clipboard, !clipboard.isEmpty {
        bits.append("Clipboard: \(truncate(clipboard, to: Self.clipboardCap)).")
    }
    if let visible, !visible.isEmpty {
        bits.append("On screen: \(truncate(visible, to: Self.visibleCap)).")
    }
    guard !bits.isEmpty else { return "" }
    return bits.joined(separator: " ") + "\n\n"
}

private func truncate(_ s: String, to cap: Int) -> String {
    s.count <= cap ? s : String(s.prefix(cap)) + "…"
}
```

**Apply to PromptBuilder.build(...):** Same `var bits: [String] = []; if !slot.isEmpty { bits.append(...) }; bits.joined(separator: "\n\n")` shape. Crucial differences from EnrichedContext: the cap is in *tokens* not chars, and overflow triggers head-truncation (not tail-`prefix`+`…`). The "empty slots contribute nothing" rule is shared (no extra blank lines).

**Pure-static helper precedent** (`Souffleuse/Sources/SouffleuseTyping/ChunkSplitter.swift`, the entire module is a pure-static API exercised in `ChunkSplitterTests.swift:7-89`):
- `public static func nextChunk(...) -> String` style. No instance state, no `init`.
- Apply: the head-truncation helper (`truncateHead`) on the `TokenCounting` protocol IS instance, but ancillary helpers like sentence-boundary detection should be `static` private functions on `PromptBuilder` so tests can exercise them directly via `@testable import`.

**Sentence-terminator list reuse precedent** (PredictorViewModel.swift:569 + Coherence main.swift:103):
```swift
for terminator in [". ", "? ", "! ", "… "] {
```
Reuse this exact list inside `truncateHead` for sentence boundaries. Add `"\n\n"` for paragraph break (head-truncation case, not present in the existing tail-truncation use).

**Sendability + isolation:** `public struct PromptBuilder: Sendable`. No `@MainActor`, no `actor`. Stateless after init. Same as `EnrichedContext` (value, no isolation).

---

### `Souffleuse/Sources/Souffleuse/MLXTokenCounter.swift` (production protocol impl)

**Analog:** `Souffleuse/Sources/SouffleuseContext/OCRCaretLocator.swift` (concrete `actor OCRCaretLocator: OCRCaretLocating`)

**Production adapter shape** (OCRCaretLocator.swift:43-56):
```swift
public actor OCRCaretLocator: OCRCaretLocating {
    /// Vision needs the accurate recogniser to honour per-character
    /// `boundingBox(for:)` queries; the fast recogniser collapses to
    /// whole-line bounding boxes.
    private let capturer: ScreenCapturer
    private let languages: [String]

    public init(
        capturer: ScreenCapturer = ScreenCapturer(),
        languages: [String] = ["fr-FR", "en-US"]
    ) {
        self.capturer = capturer
        self.languages = languages
    }
```

**Apply to MLXTokenCounter:** `struct MLXTokenCounter: TokenCounting` (NOT actor — stateless wrapper around an already-Sendable tokenizer reference; OCRCaretLocator is an actor only because it serialises capture). Single stored property `let tokenizer: any Tokenizer` (matching the MLX `context.tokenizer` type already in use at `PredictorViewModel.swift:693`).

**Existing tokenizer call-site** (PredictorViewModel.swift roughly line 693-702, format confirmed in RESEARCH §2):
```swift
let promptTokens = context.tokenizer.encode(text: basePromptText)
```
Apply: inside `MLXTokenCounter.countTokens(_:)`, body is `tokenizer.encode(text: text).count`. No retry, no caching — matches the existing direct-call pattern.

**File location decision:** `Souffleuse/Sources/Souffleuse/` (app target) per CONTEXT.md hint — keeps `SouffleusePrompt` library agnostic to MLX for tests. Note: RESEARCH §1 Q4 leaves this open; the planner may opt to co-locate inside `SouffleusePrompt` since that target already depends on `MLXLMCommon` per D-10. Pattern works the same in either location.

---

### `Souffleuse/Tests/SouffleuseTests/PromptBuilderTests.swift` (snapshot test suite)

**Analog:** `Souffleuse/Tests/SouffleuseTests/ChunkSplitterTests.swift` (closest match: pure-function table-driven `@Test` suite)

**Imports + module under test** (ChunkSplitterTests.swift:1-2):
```swift
import Testing
@testable import SouffleuseTyping
```

**Apply:** `import Testing` + `@testable import SouffleusePrompt`. NO XCTest. No class.

**Test-function pattern** (ChunkSplitterTests.swift:7-13):
```swift
@Test func chunkSplitsFirstWordWithTrailingSpace() {
    #expect(ChunkSplitter.nextChunk("Je m'appelle Gabriel", trailingSpace: true) == "Je ")
}

@Test func chunkSplitsFirstWordWithoutTrailingSpace() {
    #expect(ChunkSplitter.nextChunk("Je m'appelle Gabriel", trailingSpace: false) == "Je")
}
```
- Top-level `@Test func ...()`, NO `test_` prefix.
- Function name reads as a descriptive sentence.
- `#expect(actual == expected)` — no XCTAssert.

**Apply to PromptBuilderTests:** `@Test func builderAssemblesAllSlotsInOrder() { ... }`, `@Test func builderTruncatesBeforeCursorHeadAtSentenceBoundary()`, `@Test func builderNeverCutsMidWord()`, `@Test func builderHandlesEmptySlots()`, etc. (full set in RESEARCH §8.) All sync — no `async` since the builder is pure.

**Mock pattern (test-only collaborator)** (`CaretResolverTests.swift:13-44`, MockOCRCaretLocator):
```swift
actor MockOCRCaretLocator: OCRCaretLocating {
    private(set) var callCount: Int = 0
    var nextResult: OCRCaretResult? = nil
    ...
}
```

**Apply to WordCountTokenCounter:** Test-private `struct WordCountTokenCounter: TokenCounting { ... }` co-located in `PromptBuilderTests.swift` (NOT a separate mocks file — project precedent is mocks-in-test-file). `struct` not `actor` because TokenCounting is sync (the protocol seam itself is `Sendable` but not isolated). Whitespace-split body per RESEARCH §8.

**Helpers pattern** (`SimilarHistoryRetrievalTests.swift:6-24` and `ChunkSplitterTests.swift` has none): private file-scope helpers grouped under `// MARK: - Helpers`. For PromptBuilderTests, the mock counter goes under a `// MARK: - Test doubles` divider matching `CaretResolverTests.swift`.

**No fixture cleanup needed** (PromptBuilder is pure, no IO) — distinct from `PersonalizationTests.swift` which uses `tempStoreURL` + `await store.clear()`.

---

### `Souffleuse/Package.swift` (modify — add `SouffleusePrompt` target)

**Analog:** `Souffleuse/Package.swift` itself — the existing `SouffleusePersonalization` declaration at lines 48-54 is the closest precedent (library target that depends on `SouffleuseLog` + `MLXLMCommon`).

**Product declaration pattern** (Package.swift:16-22):
```swift
.library(name: "SouffleuseAX", targets: ["SouffleuseAX"]),
.library(name: "SouffleuseOverlay", targets: ["SouffleuseOverlay"]),
.library(name: "SouffleuseInput", targets: ["SouffleuseInput"]),
.library(name: "SouffleuseContext", targets: ["SouffleuseContext"]),
.library(name: "SouffleuseLog", targets: ["SouffleuseLog"]),
.library(name: "SouffleuseTyping", targets: ["SouffleuseTyping"]),
.library(name: "SouffleusePersonalization", targets: ["SouffleusePersonalization"]),
```

**Apply:** Add `.library(name: "SouffleusePrompt", targets: ["SouffleusePrompt"]),` after the `SouffleusePersonalization` line (alphabetical near-position).

**Target declaration pattern** (Package.swift:48-54):
```swift
.target(
    name: "SouffleusePersonalization",
    dependencies: [
        "SouffleuseLog",
        .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
    ]
),
```

**Apply:** Same shape for `SouffleusePrompt` — dependencies `["SouffleuseLog", .product(name: "MLXLMCommon", package: "mlx-swift-examples")]`. NOTE: RESEARCH §9 explicitly recommends NOT depending on `SouffleuseContext` or `SouffleusePersonalization` at Phase 1 (builder treats their outputs as opaque strings) — keeps the dependency graph minimal.

**App-target wiring** (Package.swift:55-76 for `Souffleuse` executable) — add `"SouffleusePrompt"` to the `dependencies` list.
**Coherence-target wiring** (Package.swift:84-90) — add `"SouffleusePrompt"` to `SouffleuseCoherence` dependencies.
**Test-target wiring** (Package.swift:99-110) — add `"SouffleusePrompt"` to `SouffleuseTests` dependencies.

---

### `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` (modify — feature-flag integration)

**Analog:** itself; specifically the `PredictDebug` env-gated dev pattern at lines 15-36, which is the project's single in-file precedent for env-var-controlled dev paths.

**Env-var gate pattern** (PredictorViewModel.swift:15-16):
```swift
private enum PredictDebug {
    static let enabled: Bool = ProcessInfo.processInfo.environment["SOUFFLEUSE_PREDICT_LOG"]?.isEmpty == false
```

**Apply to feature flag:** Mirror the exact form:
```swift
private enum PromptBuilderFlag {
    /// Dev-only: route predict() through the new SouffleusePrompt PromptBuilder
    /// instead of the legacy flat-string concat. Removed at end of Phase 1
    /// once the replay verdict is positive and snapshot tests are green.
    static let enabled: Bool = ProcessInfo.processInfo.environment["SOUFFLEUSE_PROMPT_BUILDER"]?.isEmpty == false
}
```
Place near `PredictDebug` at top of file (file-scope `private enum`). Doc-comment explicitly marks it dev-only (matches the `// NEVER use in production builds` tone of PredictDebug).

**Call-site insertion point** (PredictorViewModel.swift:478-513 + 632-664) — gate the swap inside the `container.perform { context in ... }` block where `context.tokenizer` is reachable. Both legacy AND builder paths produce a `promptTokens: [Int]` ready for the existing generation loop (RESEARCH §5 has the full code skeleton).

**Logging the build result** (existing precedent — PredictorViewModel.swift:648):
```swift
Log.info(.predictor, "fewshot_injected", count: similar.count)
```
**Apply:** After building, `Log.info(.predictor, "prompt_built", count: built.totalTokens)`. StaticString event literal + numeric count only — the StaticString constraint enforces this at compile time (Log.swift:23 `_ event: StaticString`). NEVER log `built.text`, `built.slotTexts[.beforeCursor]`, or any other user-derived string.

---

### `Souffleuse/Sources/SouffleuseCoherence/main.swift` (modify — add `--replay` subcommand)

**Analog:** itself; specifically the existing `@main struct Coherence` orchestration at lines 211-281 and the `rawGhost` async helper at lines 181-194.

**`@main` entry shape** (Coherence main.swift:211-230):
```swift
@main
struct Coherence {
    static func main() async {
        setbuf(stdout, nil); setbuf(stderr, nil)
        let modelId = ProcessInfo.processInfo.environment["SOUFFLEUSE_MODEL"]
            ?? "mlx-community/gemma-3-1b-pt-8bit"
        ...
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
        let cfg = ModelConfiguration(id: modelId, defaultPrompt: "")
        emit("Chargement…")
        let container: ModelContainer
        do { container = try await LLMModelFactory.shared.loadContainer(configuration: cfg) { _ in } }
        catch { emit("ERREUR chargement: \(error)"); return }
        emit("  prêt.\n")
```

**Apply:** Branch on `CommandLine.arguments` BEFORE the existing default-coherence loop. Both branches reuse the model-load (factor it into a shared `loadModel() async -> ModelContainer?` helper, or duplicate the 5 lines and accept the duplication — Phase 1 simplicity favors duplication, consistent with the `// TODO Phase 2: dedupe` posture from RESEARCH §6).

**Existing `rawGhost` for reuse** (Coherence main.swift:181-194):
```swift
func rawGhost(prefix: String, on container: ModelContainer) async -> String {
    let result = try? await container.perform { ctx -> String in
        let toks = ctx.tokenizer.encode(text: prefix)
        let input = LMInput(tokens: MLXArray(toks))
        let params = GenerateParameters(
            maxTokens: Prod.maxTokens, temperature: 0, topP: 0.9,
            repetitionPenalty: penalty, repetitionContextSize: 32)
        let stream = try MLXLMCommon.generate(input: input, parameters: params, context: ctx)
        var out = ""
        for await ev in stream { if case .chunk(let t) = ev { out += t } }
        return out
    }
    return result ?? ""
}
```

**Apply for replay path:** Wrap the same `container.perform { ctx -> ... }` body but build the prompt via `PromptBuilder` (see RESEARCH §6). Generation params (`maxTokens: Prod.maxTokens, temperature: 0, topP: 0.9, repetitionPenalty: penalty, repetitionContextSize: 32`) stay identical — keeps the replay faithful to the production pipeline.

**Stdout emit pattern** (Coherence main.swift:207-209):
```swift
@Sendable func emit(_ s: String) {
    FileHandle.standardOutput.write(Data((s + "\n").utf8))
}
```
**Apply:** Use `emit(...)` for the condensed per-scenario stdout line (per RESEARCH §12 Q8 default). Markdown is written via `FileManager`/`Data.write(to: .planning/.../REPLAY-RESULTS.md, options: .atomic)` — matching the `AllowlistStore.save` precedent at `Sources/Souffleuse/AllowlistConfig.swift:76-78` (`data.write(to: fileURL, options: .atomic)`).

**Scenario decoding** (Codable struct precedent — `AllowlistFile` in `Sources/Souffleuse/AllowlistConfig.swift:40`):
```swift
// AllowlistFile carries `version: Int = 1`
```
**Apply:** `struct ScenarioFile: Codable, Sendable { let version: Int; let scenarios: [Scenario] }`. Top-level versioning matches the project's persisted-config convention. Use `JSONDecoder().decode(...)`. No need for `[.prettyPrinted, .sortedKeys]` on encoding (the file is hand-edited, not generated).

---

### `Souffleuse/audit.sh` (modify — SHIPPING_DIRS extension)

**Analog:** the same file at lines 7-15.

**Existing SHIPPING_DIRS array** (audit.sh:7-15):
```bash
SHIPPING_DIRS=(
  "Sources/Souffleuse"
  "Sources/SouffleuseAX"
  "Sources/SouffleuseContext"
  "Sources/SouffleuseInput"
  "Sources/SouffleuseLog"
  "Sources/SouffleuseOverlay"
  "Sources/SouffleusePersonalization"
)
```

**Apply:** Insert `  "Sources/SouffleusePrompt"` (alphabetical near `SouffleusePersonalization`). One-line surgical edit. Re-running `./audit.sh` after the edit must show all 6 checks PASS for the new target.

---

### `.planning/phases/01-foundation-hypothesis-validation/replay-scenarios.json` (new data file)

**Analog:** `Souffleuse/Sources/Souffleuse/AllowlistConfig.swift` (`AllowlistFile` — versioned JSON config pattern)

**Versioning precedent** (AllowlistConfig.swift:40, summarized in CONVENTIONS.md):
> Top-level on-disk struct carries an explicit `version: Int = 1`.

**Apply:** Root JSON object has `"version": 1` + `"scenarios": [...]`. Full schema + 12-scenario seed already specified in RESEARCH §7. No code analog needed — the file is hand-authored and consumed via `JSONDecoder().decode(ScenarioFile.self, from: data)` in `SouffleuseCoherence/main.swift`.

---

### `.planning/phases/01-foundation-hypothesis-validation/REPLAY-RESULTS.md` (generated)

**No analog.** New artifact. Template + writer code defined in RESEARCH §6 (`renderReplayResults(...)`). One section per scenario, side-by-side `WITHOUT context` vs `WITH context` table, plus checkbox verdict line. AUDIT-02 tally block at end (planner-set threshold). Overwrites on each run (no merge logic at Phase 1).

---

## Shared Patterns

### Concurrency / Isolation
**Source:** CONVENTIONS.md §Concurrency + `EnrichedContext` (value type) vs `ContextEnricher` (actor) split.

**Apply to all new types:**
- `PromptBuilder`, `BuiltPrompt`, `PromptBudget`, `MLXTokenCounter` → `Sendable struct` (no isolation, pure value).
- `PromptSlot` → `Sendable enum`.
- `TokenCounting` → `Sendable protocol`.
- NO `@MainActor`. NO `actor`. The builder runs inside the existing `container.perform` actor-isolated closure; it doesn't add its own isolation boundary.
- Test mocks (`WordCountTokenCounter`) → `Sendable struct` (NOT actor — tokenizer is sync, unlike `MockOCRCaretLocator` which mocks an async API).

### Sendability invariant
**Source:** CONVENTIONS.md §Sendability — "Every cross-module value type is explicitly `Sendable`."

**Apply:** Mark every public type in `SouffleusePrompt` with explicit `Sendable` conformance. Equatable on value types that need snapshot-equality (`BuiltPrompt`, `PromptBudget`). Hashable on enums used as dictionary keys (`PromptSlot`).

### Privacy / Logging
**Source:** `Souffleuse/Sources/SouffleuseLog/Log.swift:22-46` — Log API takes `StaticString` events ONLY.

```swift
public static func info(_ module: LogModule, _ event: StaticString, count: Int? = nil) {
    write(.info, module, event, count: count)
}
```

**Apply to all new code (PromptBuilder + MLXTokenCounter + integration site):**
- ONLY `Log.info(.predictor, "literal_event_name", count: optionalInt)`. NEVER interpolate any builder input/output.
- Use existing `.predictor` LogModule case for builder events from `PredictorViewModel` integration site.
- `SouffleusePrompt` itself should issue zero `Log.*` calls — keep the library pure, log only at the call site in `PredictorViewModel`. This matches the design rule from RESEARCH §10 "Builder API never accepts a logger."
- NO `print(...)` in `SouffleusePrompt` (audit.sh check #1).
- NO `os_log` (audit.sh check #2-3).

### File naming / one-type-per-file
**Source:** CONVENTIONS.md §Naming Patterns — "One primary type per file, file name matches the type."

**Apply:** 5 new files in `Souffleuse/Sources/SouffleusePrompt/`:
- `PromptSlot.swift` → `PromptSlot` enum
- `PromptBudget.swift` → `PromptBudget` struct
- `BuiltPrompt.swift` → `BuiltPrompt` struct
- `TokenCounting.swift` → `TokenCounting` protocol
- `PromptBuilder.swift` → `PromptBuilder` struct

Test file: `PromptBuilderTests.swift` (mirrors `ChunkSplitterTests.swift` naming for the unit type under test).

### Import order
**Source:** CONVENTIONS.md §Import Organization — Apple frameworks first (alphabetical), then local modules.

**Apply:**
- `SouffleusePrompt` Swift files: `import Foundation` (most) + `import MLXLMCommon` (only `MLXTokenCounter` if co-located in this target).
- `Souffleuse/MLXTokenCounter.swift` (app target): `import Foundation` + `import MLXLMCommon` + `import SouffleusePrompt`.
- Tests: `import Testing` + `@testable import SouffleusePrompt` (matching ChunkSplitterTests).

### Doc-comment style
**Source:** CONVENTIONS.md §Documentation Comments + `Log.swift:11-13` exemplar.

**Apply:** Triple-slash on every public type/method. Multi-line includes rationale ("Why a struct, not actor", "Why protocol seam", "Why per-slot budgets") not just signature description. Inline `//` comments explain *why* not *what* — especially around the Phase 1/Phase 2/Phase 3 slot reservation in `PromptSlot.swift`.

### Atomic file writes (REPLAY-RESULTS.md)
**Source:** CONVENTIONS.md §Persistence Patterns — `data.write(to: fileURL, options: .atomic)`.

**Apply:** REPLAY-RESULTS.md writer uses `.atomic` write to avoid leaving a half-written file if the process is killed mid-render.

---

## No Analog Found

| File | Role | Data Flow | Reason |
|------|------|-----------|--------|
| `.planning/.../REPLAY-RESULTS.md` | generated markdown artifact | new output template | First markdown artifact generated by a CLI in this project. Template defined in RESEARCH §6 inline `renderReplayResults(...)`. No existing precedent because no other CLI emits markdown — `SouffleuseBench`/`SouffleuseCoherence`/`SouffleuseEnrichmentBench` all emit to stdout / JSONL. Phase 1 introduces the pattern. |

(Note: `replay-scenarios.json` itself has a partial analog in `AllowlistConfig.swift`'s `version: Int = 1` versioned-JSON pattern, listed above.)

---

## Metadata

**Analog search scope:**
- `Souffleuse/Sources/Souffleuse/` (PredictorViewModel, PreferencesStore, AllowlistConfig)
- `Souffleuse/Sources/SouffleuseContext/` (ContextEnricher, OCRCaretLocator)
- `Souffleuse/Sources/SouffleuseAX/` (AXClient, AXSnapshot)
- `Souffleuse/Sources/SouffleuseLog/` (Log, LogModule)
- `Souffleuse/Sources/SouffleusePersonalization/` (cross-referenced via RESEARCH)
- `Souffleuse/Sources/SouffleuseTyping/` (TypoDetector, ChunkSplitter — static utility precedent)
- `Souffleuse/Sources/SouffleuseCoherence/main.swift` (executable harness)
- `Souffleuse/Tests/SouffleuseTests/` (ChunkSplitterTests, SimilarHistoryRetrievalTests)
- `Souffleuse/Package.swift`, `Souffleuse/audit.sh`
- `.planning/codebase/{STRUCTURE,CONVENTIONS,TESTING}.md`

**Files scanned:** ~12 Swift sources + 2 test files + Package.swift + audit.sh + 3 codebase intel docs + CONTEXT.md + RESEARCH.md (full)

**Pattern extraction date:** 2026-05-24

---

*Phase 1 Pattern Map: 2026-05-24*
