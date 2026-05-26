# Phase 4: Cascade Quality + Architecture — Pattern Map

**Mapped:** 2026-05-25
**Files analyzed:** 13 (8 new, 5 modified)
**Analogs found:** 13 / 13

> All pattern excerpts are VERIFIED by direct read of cited files. Line numbers
> reference HEAD at commit `7316a8c` (the current main branch tip recorded in
> CONTEXT.md).

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `Sources/Souffleuse/SuggestionPolicy.swift` (NEW) | controller (cascade routing) | event-driven (sync L0/L1 + async LLM chunks) | `Sources/Souffleuse/PredictorViewModel.swift` (cascade region L525-913) | exact (same role today, just embedded) |
| `Sources/Souffleuse/SuggestionPolicy+Tuning.swift` (NEW) | config (single-file constants holder) | static read | `Sources/Souffleuse/PredictorViewModel.swift` `PromptBuilderFlag` (L17-20) + `KVCacheBypassFlag` (L31-34) | role-match (single-file flag holders) |
| `Sources/Souffleuse/ModelRuntime.swift` (NEW) | service (MLX I/O) | request-response (async stream) | `Sources/Souffleuse/PredictorViewModel.swift` `container.perform` block (L1009-1412) | exact |
| `Sources/Souffleuse/CompletionCache.swift` (NEW) | service (state holder) | CRUD (in-memory) | `Sources/Souffleuse/KVCacheHolder.swift` + `Sources/SouffleusePrompt/MemoizingTokenCounter.swift` | exact (composes 2 existing types) |
| `Sources/Souffleuse/GenerationPlanner.swift` (NEW) | utility (lifecycle / cancellation) | event-driven | `Sources/Souffleuse/PredictorViewModel.swift` (`generation`/`currentTask` region L111-116 + L772-776) | exact (extraction) |
| `Sources/Souffleuse/TypingSession.swift` (NEW) | controller (tick orchestrator) | event-driven (timer 80ms) | `Sources/Souffleuse/SouffleuseAppDelegate.swift` `tick()` (L548-992) | exact (extraction) |
| `Tests/SouffleuseTests/SuggestionPolicyTests.swift` (NEW) | test | request-response | `Tests/SouffleuseTests/HistoryExactMatchTests.swift` | exact |
| `Tests/SouffleuseTests/RelevanceGateTests.swift` (NEW) | test (pure function) | request-response | `Tests/SouffleuseTests/KVCacheHolderTests.swift` (pure-value fingerprint tests) | exact |
| `Tests/SouffleuseTests/ClassificationGridTests.swift` (NEW) | test (stateful) | event-driven | `Tests/SouffleuseTests/KVCacheBypassTests.swift` (stateful holder under `@MainActor`) | role-match |
| `Sources/Souffleuse/PredictorViewModel.swift` (MODIFIED) | controller (façade — shrinks 1566 → ~150 LOC) | delegating | same file pre-refactor | self-analog (façade-isation) |
| `Sources/Souffleuse/SouffleuseAppDelegate.swift` (MODIFIED) | controller (lifecycle — shrinks 1209 → ~400 LOC) | delegating | same file pre-refactor | self-analog |
| `Sources/SouffleuseCoherence/main.swift` (MODIFIED) | tool (replay harness extension) | batch | same file (`Scenario` struct L220-235, `renderReplayResults` L367-444) | self-analog |
| `Tests/SouffleuseTests/HistoryExactMatchTests.swift` (MODIFIED — extended) | test | request-response | self-analog | self-analog |

---

## Pattern Assignments

### `Sources/Souffleuse/SuggestionPolicy.swift` (controller, event-driven)

**Analog:** `Sources/Souffleuse/PredictorViewModel.swift` cascade region L525-913 — the L0/L1 instant ghost computation + the LLM `onChunk` anti-churn block.

**Imports pattern** (PVM L1-10, verbatim — same module set required):
```swift
import Foundation
import SouffleuseAX           // AXSnapshot
import SouffleuseLog          // Log
import SouffleusePersonalization  // TypingHistoryEntry
import SouffleuseTyping       // WordCompleter
```

**`@MainActor` façade declaration** (PVM L74-76 — keep verbatim):
```swift
@MainActor
@Observable
final class SuggestionPolicy {  // mirror PVM
    // …
}
```

**Suggestion source enum to migrate verbatim from PVM L95-109** (canonical type, do NOT rename — multiple cross-module references):
```swift
enum SuggestionSource: Sendable {
    case none           // suggestion is "" or stale
    case wordComplete   // Layer 0 — NSSpellChecker
    case history        // Layer 1 — TypingHistoryStore match
    case cache          // predictCache hit (previous LLM result)
    case undoCache      // undo-as-ghost restoration
    case llm            // currently streaming from the active LLM Task
}
```

**Cascade L0/L1 routing pattern** (extracted verbatim from PVM L539-609; reorganise around `routeInstant(...)` returning `GhostUpdate?`):
```swift
// Source: PVM:551-586 verbatim shape
let rawHistoryHit = Self.historyExactSubstringMatch(userTail: userTail, snapshot: historySnapshot)
let historyHit = rawHistoryHit.map { Self.capToWords($0, max: maxWords) }
let rawWordCompletion = wordCompleter.completion(for: userTail) ?? ""
let wordCompletionSuffix = rawWordCompletion.count >= 3 ? rawWordCompletion : ""
// Priority: history hit > word completion > nothing.
let instantGhost: String
let instantSource: SuggestionSource
if let h = historyHit, !h.isEmpty {
    instantGhost = h
    instantSource = .history
    Log.info(.predictor, "ghost_history_match", count: h.count)
} else if !wordCompletionSuffix.isEmpty {
    instantGhost = wordCompletionSuffix
    instantSource = .wordComplete
    Log.info(.predictor, "ghost_word_complete", count: wordCompletionSuffix.count)
} else {
    instantGhost = ""
    instantSource = .none
}
```

**LLM onChunk anti-churn pattern to REPLACE with Relevance Gate** (PVM L853-913 — the high/low confidence branch). The replacement bar (`score.beats(currentScore)`) supersedes this:
```swift
// Old (PVM:874-898) — DELETE during extraction:
let highConfidence: Bool
switch self.suggestionSource {
case .history, .cache, .undoCache: highConfidence = true
case .wordComplete, .llm, .none:   highConfidence = false
}
if highConfidence {
    let extendsCurrent = oneLine.lowercased().hasPrefix(current.lowercased())
    if !extendsCurrent || oneLine.count <= current.count {
        Log.info(.predictor, "ghost_protect_high", count: current.count)
        return
    }
} else {
    if oneLine.count <= current.count {
        Log.info(.predictor, "ghost_keep_longer", count: current.count)
        return
    }
}
// New (D-07 Relevance Gate) — replacement:
let score = SuggestionPolicy.score(source: .llm, ghost: oneLine, userTail: userTail)
guard score.passesGate else {
    Log.info(.predictor, "ghost_gate_block", count: Int(score.value * 100))
    return
}
if !currentGhost.isEmpty {
    let isHistoryFirst = currentSource == .history
    let beatsBar = score.beats(currentScore)
    let l2Upgrades = isHistoryFirst && (score.value >= currentScore.value + Tuning.l2UpgradeDelta)
    guard beatsBar || l2Upgrades else {
        Log.info(.predictor, "ghost_keep_under_bar", count: currentGhost.count)
        return
    }
}
```

**Source decay pattern** (preserve from PVM L505-521 — paste at entry of `route(...)`):
```swift
switch suggestionSource {
case .history, .cache, .undoCache:
    suggestionSource = .llm
case .wordComplete, .llm, .none:
    break
}
```

**`nonisolated static` pure helper migration** (PVM L1524-1549 — move verbatim into the new file, keep `static` so tests can call without instantiating):
```swift
nonisolated static func historyExactSubstringMatch(userTail: String, snapshot: [TypingHistoryEntry]) -> String? {
    let lookback = String(userTail.suffix(40))
    guard lookback.count >= 6 else { return nil }
    if lookback.last?.isWhitespace == true { return nil }
    for entry in snapshot {
        let full = entry.contextBefore.isEmpty
            ? entry.accepted
            : entry.contextBefore + " " + entry.accepted
        if let r = full.range(of: lookback) {
            let after = full[r.upperBound...]
            let trimmed = String(after)
            if !trimmed.isEmpty { return trimmed }
        }
    }
    return nil
}
```

**Error / no-result handling** — return `nil`/empty `GhostUpdate?` rather than throwing. Matches PVM convention (this is the AppDelegate-level "non-critical IO" pattern from CLAUDE.md).

---

### `Sources/Souffleuse/SuggestionPolicy+Tuning.swift` (config, static read)

**Analog:** `Sources/Souffleuse/PredictorViewModel.swift` `PromptBuilderFlag` L17-20 + `KVCacheBypassFlag` L31-34.

**Single-file constants holder pattern** (verbatim shape — `private enum` namespace, all `static let`):
```swift
// Source: PVM:17-20 + PVM:31-34 idiom, generalised
private enum KVCacheBypassFlag {
    static let enabled: Bool =
        ProcessInfo.processInfo.environment["SOUFFLEUSE_DISABLE_KV_CACHE"]?.isEmpty == false
}
```

**Applied to Phase 4 Tuning** (use INTERNAL not `private` because tests need `@testable` access — escalate visibility relative to the analog):
```swift
// New file: Sources/Souffleuse/SuggestionPolicy+Tuning.swift
extension SuggestionPolicy {
    enum Tuning {
        // D-07 gate
        static let gateFloor: Float = 0.25
        static let replacementBar: Float = 1.15
        // D-08 routing
        static let afterSpaceL1Bar: Float = 0.4
        static let l2UpgradeDelta: Float = 0.15
        // D-09 classification windows
        static let parasiteWindow: TimeInterval = 0.8
        static let uselessMinVisibleMs: Int = 200
        static let badMaxDivergeMs: Int = 500
        // D-06 priors
        static let sourcePrior: [SuggestionSource: Float] = [
            .wordComplete: 0.55, .history: 0.75, .llm: 0.60,
            .cache: 0.70, .undoCache: 0.65, .none: 0.0,
        ]
        // D-06 bell curve (index = word count, clamp to last for ≥10)
        static let lengthFitByWordCount: [Float] =
            [0.0, 0.6, 1.0, 1.0, 1.0, 1.0, 0.85, 0.6, 0.6, 0.3]
    }
}
```

**Convention enforcement** (per Pitfall 6 in RESEARCH §"Common Pitfalls"): no literal float thresholds anywhere except this file. Tests reference `SuggestionPolicy.Tuning.gateFloor` directly.

---

### `Sources/Souffleuse/ModelRuntime.swift` (service, request-response async stream)

**Analog:** `Sources/Souffleuse/PredictorViewModel.swift` MLX block L1009-1412 (`container.perform { context -> StreamMetrics in ... }`).

**Imports pattern** (PVM L1-4, verbatim):
```swift
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import NaturalLanguage  // for buildSystemPrompt
import SouffleusePrompt // PromptBuilder
import SouffleuseLog
```

**`CacheBox @unchecked Sendable` pattern to move verbatim from PVM L64-72** (the cross-actor transfer helper):
```swift
/// Sendable transfer box for `[KVCache]` across the actor boundary between
/// the @MainActor caller and the `ModelContainer.perform` closure (off-MainActor).
private struct CacheBox: @unchecked Sendable {
    let caches: [KVCache]
}
```

**`StreamMetrics` value type** (PVM L84-87, keep verbatim — public surface for the façade):
```swift
struct StreamMetrics: Sendable {
    var ttftMillis: Int?
    var tokensPerSecond: Double?
}
```

**`@MainActor` runtime façade declaration** (PVM L74-76 — mirror):
```swift
@MainActor
final class ModelRuntime {
    private var container: ModelContainer?
    // ... loadModel/swapModel/generate APIs
}
```

**`swapModel` chain pattern** (PVM L195-214 — keep coordination intact but delegate to injected `CompletionCache`):
```swift
// PVM:195-214 verbatim — DO NOT lose the `Log.info(.predictor, "kv_cache_invalidate", count: 3)`
// (count=3 means .explicit per KVCacheHolder.InvalidationReason mapping at PVM:209)
func swap(to id: String, completionCache: CompletionCache) async {
    guard id != modelId else { return }
    cancel()                       // delegated to GenerationPlanner
    container = nil
    modelId = id
    completionCache.invalidateAll()  // clears predictCache + KV + tokenCountCache
    Log.info(.predictor, "kv_cache_invalidate", count: 3)
    await loadModel()
}
```

**Output filter sub-namespace** (extract pure functions from PVM L295-433 — `stripPrefixOverlap`, `ghostIsRepeatingPrefix`, `hasCompletedFirstWord`, `stripTrailingPartialWord`, `normalizeForRepeatCheck`, `capToWords`. All `static` or `nonisolated static`. Test seam: tests can call them without instantiating Runtime).

**KV cache decision interaction** (PVM L1163-1311 — extracts to `CompletionCache.decideExtendTrimInvalidate(...)` returning `KVDecision`. Runtime consumes the decision):
```swift
// New surface (from CompletionCache):
enum KVDecision: Sendable {
    case bypass, cold, fingerprintChanged
    case extend(Int), trim(Int), diverged, identical
}
// Runtime applies:
switch decision {
case .extend(let n): Log.info(.predictor, "kv_cache_extend", count: n)
case .trim(let n):   Log.info(.predictor, "kv_cache_trim", count: n)
case .cold:          Log.info(.predictor, "kv_cache_invalidate", count: 0)
case .fingerprintChanged: Log.info(.predictor, "kv_cache_invalidate", count: 1)
case .diverged:      Log.info(.predictor, "kv_cache_invalidate", count: 2)
case .bypass, .identical: break
}
```

**Error handling** — `do { try await container.perform { … } } catch { Log.warn(.predictor, "predict_failed"); self?.lastError = msg }`. Match PVM L1449-1456.

---

### `Sources/Souffleuse/CompletionCache.swift` (service, CRUD in-memory)

**Analog:** `Sources/Souffleuse/KVCacheHolder.swift` (complete file, 158 LOC) + `Sources/SouffleusePrompt/MemoizingTokenCounter.swift` (98 LOC).

**Imports pattern** (composite):
```swift
import Foundation
import MLXLMCommon         // KVCache protocol
import SouffleusePrompt    // TokenCountCache + MemoizingTokenCounter
import SouffleuseLog
import CryptoKit           // SHA256 via InvariancePrefix (already imported transitively)
```

**`@MainActor final class` pattern** (KVCacheHolder.swift L97-113 — verbatim shape, just renamed):
```swift
// Source: KVCacheHolder.swift:97-113
@MainActor
public final class KVCacheHolder {
    public private(set) var caches: [Any]?
    public private(set) var fingerprint: String?
    public private(set) var beforeCursorTokens: Int = 0
    public init() {}
    // ...
}
```

**Phase 4 application:** `CompletionCache` is a `@MainActor final class` that OWNS three sub-stores:
```swift
@MainActor
final class CompletionCache {
    // From PVM:126-131
    internal var predictCache: [String: String] = [:]
    internal var predictCacheOrder: [String] = []
    internal static let predictCacheCapacity = 32
    // From PVM:139
    private let tokenCountCache = TokenCountCache(cap: 64)
    // From PVM:149-158 (move verbatim, holder type unchanged)
    private let sessionCacheHolder = KVCacheHolder()
    // From PVM:149 (context fingerprint for predictCache invalidation)
    private var lastContextFingerprint: String?

    init() {}
    // ...
}
```

**FIFO eviction pattern** — TokenCountCache.swift L34-44 verbatim shape; same pattern was used in PVM L220-240 `storeInCache`:
```swift
// Source: MemoizingTokenCounter.swift:34-44 (FIFO eviction reference)
public func put(_ key: String, _ value: Int) {
    lock.lock(); defer { lock.unlock() }
    guard cache[key] == nil else { return }
    if cache.count >= cap, let evicted = order.first {
        cache.removeValue(forKey: evicted)
        order.removeFirst()
    }
    cache[key] = value
    order.append(key)
}
```

Phase 4 application — `storeInCache(prefix:suggestion:)` migrates from PVM L220-240 mechanically (already FIFO, no rewrite needed — just move).

**Invalidation pattern** (KVCacheHolder.swift L116-134 — preserve the `InvalidationReason` enum and `count` mapping for log compatibility):
```swift
// Source: KVCacheHolder.swift:116-134 verbatim
public enum InvalidationReason: Sendable {
    case cold                      // count: 0
    case fingerprintChanged        // count: 1
    case beforeCursorDiverged      // count: 2 (mapped via .diverged)
    case explicit                  // count: 3
}
public func invalidate(reason: InvalidationReason) {
    caches = nil
    fingerprint = nil
    beforeCursorTokens = 0
    _ = reason
}
```

**KV decision tree migration** (PVM L1233-1281 — extract into `CompletionCache.decideExtendTrimInvalidate(invariance:userTailTokenCount:promptTokens:)` returning a `KVDecision`. Pure function over inputs + holder state. **Critical:** preserve the exact ordering — envBypass → cold (no caches) → fingerprintChanged → extend/trim/diverged/identical. Replay equivalence depends on this).

**Context fingerprint invalidation** (PVM L492-503 — moves verbatim):
```swift
// Source: PVM:492-503 verbatim — keep slot order, do NOT add textAfterCaret
let contextFingerprint: String = [
    axSnapshot?.bundleID ?? "",
    axSnapshot?.role ?? "",
    axSnapshot?.subrole ?? "",
    axSnapshot?.placeholder ?? "",
    axSnapshot?.help ?? "",
].joined(separator: "|")
if let last = lastContextFingerprint, last != contextFingerprint {
    clearPredictCache()
    Log.info(.predictor, "cache_invalidate_context")
}
lastContextFingerprint = contextFingerprint
```

---

### `Sources/Souffleuse/GenerationPlanner.swift` (utility, lifecycle)

**Analog:** `Sources/Souffleuse/PredictorViewModel.swift` `generation`/`currentTask` lifecycle (L111-116 + L772-776 + L967-1008 + L1551-1565).

**Imports pattern:**
```swift
import Foundation
import SouffleuseLog
```

**`@MainActor final class` shell:**
```swift
@MainActor
final class GenerationPlanner {
    private var currentTask: Task<Void, Never>?
    // Bumped on every schedule() and cancel(). onChunk closures capture the
    // generation at creation time and silently drop updates from older
    // generations — mirror PVM:113-116 comment verbatim.
    private(set) var generation: UInt64 = 0
    private static let predictDebounceNanos: UInt64 = 30 * 1_000_000  // 30ms — from AppDelegate:130
    init() {}
}
```

**Generation counter pattern (verbatim PVM L772-776):**
```swift
let previousTask = currentTask
previousTask?.cancel()
generation &+= 1
let myGeneration = generation
```

**`myGeneration` guard inside closure (verbatim PVM L853-854):**
```swift
Task { @MainActor in
    guard let self, self.generation == myGeneration else { return }
    // … apply chunk
}
```

**Cancellation API (verbatim PVM L1551-1565 — preserve the comment about NOT clearing predictCache here):**
```swift
func cancel() {
    currentTask?.cancel()
    currentTask = nil
    generation &+= 1  // invalidate any in-flight onChunk updates
    // NOTE: predictCache is NOT cleared here. cancel() is called from many
    // paths that are NOT context breaks (live-consume, Tab accept, typo).
    // True context breaks call CompletionCache.clearPredictCache() explicitly.
}
```

**Debounce pattern (extract from AppDelegate L106-130):**
```swift
// Source: AppDelegate:130 + AppDelegate:962-981
private var predictDebounceTask: Task<Void, Never>? = nil

func scheduleDebounced(_ work: @escaping @Sendable () async -> Void) {
    predictDebounceTask?.cancel()
    predictDebounceTask = Task { [debounce = Self.predictDebounceNanos] in
        try? await Task.sleep(nanoseconds: debounce)
        if Task.isCancelled { return }
        await work()
    }
}
```

**Stale chunk drop pitfall** — Per RESEARCH §"Common Pitfalls — Pitfall 1": prefer passing an explicit `Generation` token through the request struct rather than capturing `myGeneration` by closure when the GenerationPlanner reference itself could be swapped. Token type:
```swift
struct GenerationToken: Equatable, Sendable { let value: UInt64 }
func beginGeneration() -> GenerationToken { ... }
```

---

### `Sources/Souffleuse/TypingSession.swift` (controller, event-driven)

**Analog:** `Sources/Souffleuse/SouffleuseAppDelegate.swift` `tick()` (L548-992) and adjacent per-bundle caches (L65-99, L143-159).

**Imports pattern** (subset of AppDelegate L1-10):
```swift
import AppKit                  // CGRect
import Foundation
import SouffleuseAX            // AXClient, AXSnapshot
import SouffleuseContext       // ContextEnricher
import SouffleuseLog
import SouffleuseOverlay       // OverlayWindow, PresenceIndicatorWindow
import SouffleuseTyping        // TypoDetector, TypoSuggestion, ChunkSplitter
```

**`@MainActor` orchestrator shape** (AppDelegate L46-47, mirror):
```swift
@MainActor
final class TypingSession {
    // Dependencies injected by SouffleuseAppDelegate at boot:
    private let axClient: AXClient
    private let predictor: PredictorViewModel  // façade post-split
    private let overlay: OverlayWindow
    private let presence: PresenceIndicatorWindow
    private let interceptor: KeyInterceptor
    private let enricher: ContextEnricher
    private let caretResolver: CaretResolver
    private let typoDetector: TypoDetector
    init(axClient: AXClient, predictor: PredictorViewModel, /* … */) { /* … */ }
}
```

**Per-bundle cache properties migrate verbatim from AppDelegate L65-99 + L143-159:**
```swift
// Source: AppDelegate:65-99 verbatim
private var lastCaretRectByApp: [String: CGRect] = [:]
private var lastCaretRectTimestampByApp: [String: Date] = [:]
private static let caretRectTTL: TimeInterval = 1.2
private var textAtFocusByBundle: [String: String] = [:]
private var lastFocusedBundleID: String? = nil
private var caretRefinementPending: Bool = false
private var dismissedForText: String? = nil
// Source: AppDelegate:143-159 verbatim
private var partialRemainder: String = ""
private var partialAcceptedSoFar: String = ""
private var partialAcceptedAtPrefix: String = ""
private var partialAcceptedAtBundleID: String? = nil
private var lastEnrichedBundleID: String?
private var cachedEnrichmentPrefix: String = ""
private var lastOCRLangsApplied: [String] = []
```

**`tick()` method pattern** (AppDelegate L548-992 — move verbatim into TypingSession.tick(), preserve all `Log.info(.predictor, ...)` events). Critical signposts to keep intact:
- AX trust gate (L561-566)
- Blocklist + secure-field gate (L586-617)
- Per-app allowlist mode check (L621-627)
- Fresh-focus snapshot (L635-651)
- Caret rect TTL caching (L658-668)
- Partial remainder guard (AppDelegate L823-892 area) — **DO NOT** remove (Pitfall 2 in RESEARCH).

**`tickThrottled` pattern (verbatim AppDelegate L538-546):**
```swift
private func tickThrottled() {
    guard !caretRefinementPending else { return }
    caretRefinementPending = true
    DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.caretRefinementPending = false
        self.tick()
    }
}
```

**Key-handling delegation (AppDelegate L994-1184 stays in AppDelegate; TypingSession exposes helpers):**
```swift
// AppDelegate calls these from inside its nonisolated handleKey():
func handleAccept(suggestion: String, isPartial: Bool, axBundle: String?, axPrePrefix: String) { ... }
func handleEscape() { ... }
func handlePartialAccept(chunk: String, rest: String, isLast: Bool, ...) { ... }
```

**`recordPartialAcceptanceToHistoryIfAllowed()` migrates verbatim from AppDelegate L1190-1208** — uses `personalizationBundleBlocklist` + `bundleBlocklist` (these CONSTANTS stay in AppDelegate per file conventions, passed in via constructor or referenced via static).

---

### `Tests/SouffleuseTests/SuggestionPolicyTests.swift` (test, request-response)

**Analog:** `Tests/SouffleuseTests/HistoryExactMatchTests.swift` (full file, 105 LOC).

**File header pattern** (HistoryExactMatchTests.swift L1-7, verbatim):
```swift
import Testing
import Foundation
import SouffleusePersonalization
@testable import Souffleuse

@Suite("Cascade routing — SuggestionPolicy")
struct SuggestionPolicyTests {
    // ...
}
```

**Test case shape** (HistoryExactMatchTests.swift L13-25 — `@Test` attribute, `#expect`, fixture helpers):
```swift
@Test func midWordReturnsWordCompleteOnly() {
    let policy = SuggestionPolicy(/* deps */)
    let update = policy.routeInstant(userTail: "Bonjou", historySnapshot: [], wordCompleter: WordCompleter())
    #expect(update?.source == .wordComplete)
}
```

**Fixture helper pattern** (HistoryExactMatchTests.swift L9-11):
```swift
private static func entry(_ context: String, _ accepted: String) -> TypingHistoryEntry {
    TypingHistoryEntry(timestamp: Date(), contextBefore: context, accepted: accepted, bundleID: nil)
}
```

**Truth table coverage** — write one `@Test` per row of the cascade routing matrix in RESEARCH §"Cascade routing decision matrix" (9 rows = 9 tests minimum).

---

### `Tests/SouffleuseTests/RelevanceGateTests.swift` (test, pure function)

**Analog:** `Tests/SouffleuseTests/KVCacheHolderTests.swift` (full file — pure-value tests on `InvariancePrefix`).

**Pure-function test pattern** (KVCacheHolderTests.swift L26-34):
```swift
// Source: KVCacheHolderTests.swift:26-34 verbatim shape
@Test func fingerprintDeterministic() {
    #expect(make().fingerprint == make().fingerprint)
}

@Test func fingerprintLengthAndAlphabet() {
    let fp = make().fingerprint
    #expect(fp.count == 64)
}
```

**Apply to Score:**
```swift
@Test func scoreIsProductOfThreeFactors() {
    let s = SuggestionPolicy.score(source: .history, ghost: "test ghost", userTail: "te")
    #expect(s.value == s.sourcePrior * s.prefixFit * s.lengthFit)
}

@Test func gateFloorBlocksLowScores() {
    let s = Score(sourcePrior: 0.5, prefixFit: 0.5, lengthFit: 0.5)
    // 0.125 < gateFloor (0.25)
    #expect(s.passesGate == false)
}

@Test func replacementBarBeatsCurrentByMultiplier() {
    let a = Score(sourcePrior: 0.6, prefixFit: 1.0, lengthFit: 1.0)  // 0.6
    let b = Score(sourcePrior: 0.75, prefixFit: 1.0, lengthFit: 1.0) // 0.75
    // 0.75 ≥ 0.6 × 1.15 = 0.69 → true
    #expect(b.beats(a))
}
```

**Pitfall 6 convention check** — tests reference `SuggestionPolicy.Tuning.gateFloor` not literal `0.25`. Already required by D-13.

---

### `Tests/SouffleuseTests/ClassificationGridTests.swift` (test, stateful)

**Analog:** `Tests/SouffleuseTests/KVCacheBypassTests.swift` (full file — stateful holder under `@MainActor`).

**Stateful `@MainActor @Test` pattern** (KVCacheBypassTests.swift L21-32):
```swift
// Source: KVCacheBypassTests.swift:21-32 verbatim shape
@MainActor
@Test func bypassPath_holderStaysCold() {
    let h = KVCacheHolder()
    #expect(h.caches == nil)
    h.updateBeforeCursorTokens(42)
    #expect(h.caches == nil)
}
```

**Apply to classification grid:**
```swift
@MainActor
@Test func endLifecycleEmitsExactlyOneEventPerGhost() {
    let policy = SuggestionPolicy(/* deps */)
    // Simulate: ghost shown, then accepted full
    policy.applyGhost("ghost", source: .llm, score: Score(/* … */))
    policy.endLifecycle(reason: .acceptedFull)
    // After end: state reset, second end is silent
    policy.endLifecycle(reason: .acceptedFull)  // no-op
    // Assert via log inspection or via SuggestionPolicy.classificationEventCount
}
```

**Critical invariant under test** (Pitfall 5 in RESEARCH §"Common Pitfalls"): "1 ghost lifecycle = 1 classification event" — never two events for the same shown ghost.

---

### `Sources/Souffleuse/PredictorViewModel.swift` (MODIFIED — shrinks to façade)

**Analog:** self, pre-refactor.

**Pre-refactor LOC:** 1566. **Target post-refactor LOC:** ~150-200 (façade).

**What remains in the façade:**
- `LoadState` enum (PVM L77-82) + observables (`loadState`, `suggestion`, `ttftMillis`, `tokensPerSecond`, `lastError`, `suggestionSource`).
- `predict(prefix:contextPrefix:customInstructions:axSnapshot:)` public method — but body is now just: capture inputs into a `PredictRequest`, hand to `GenerationPlanner.schedule(request:)`.
- `swapModel`, `cancel`, `rebuildPersonalization`, `ingestAccepted`, `clearPredictCache` → delegate to the appropriate module.
- `PromptBuilderFlag` (L17-20) and `PredictDebug` (L41-62) STAY in this file (cross-cutting dev kill-switch + tracer).
- `KVCacheBypassFlag` (L31-34) MOVES to `CompletionCache.swift` per RESEARCH §"Concrete PVM-region mapping" L31-34 row. **Critical:** env-var literal `SOUFFLEUSE_DISABLE_KV_CACHE` MUST stay byte-identical (rollback safety net per Runtime State Inventory).

**Façade delegation pattern** (template for every remaining method):
```swift
@MainActor @Observable
final class PredictorViewModel {
    // observables exposed via getters from sub-modules:
    var suggestion: String { policy.currentGhost }
    var suggestionSource: SuggestionSource { policy.currentSource }
    // … plus ttftMillis, tokensPerSecond, lastError stored locally

    private let runtime: ModelRuntime
    private let cache: CompletionCache
    private let policy: SuggestionPolicy
    private let planner: GenerationPlanner

    func predict(prefix: String, contextPrefix: String, customInstructions: String, axSnapshot: AXSnapshot?) {
        let req = PredictRequest(/* … */)
        planner.schedule { [policy, runtime, cache] in
            await policy.route(req, cache: cache, runtime: runtime)
        }
    }
}
```

---

### `Sources/Souffleuse/SouffleuseAppDelegate.swift` (MODIFIED — shrinks)

**Pre-refactor LOC:** 1209. **Target post-refactor LOC:** ~400.

**What stays:** bundle blocklists (L19-44), `applicationDidFinishLaunching` (L164-235), onboarding (L239-249), hotkey (L254-282), `observePreferences` (L288-355), status item (L371-432), edit menu (L434-499), CGEventTap-thread `handleKey` (L994-1184 — but body delegates to `TypingSession`).

**What moves to `TypingSession`:** L65-99 + L143-159 (per-bundle caches), L532-992 (tick + tickThrottled), L1190-1208 (recordPartialAcceptanceToHistoryIfAllowed).

**`handleKey` thinning pattern:**
```swift
// AppDelegate:996-1009 verbatim — the dispatch entry stays here.
nonisolated private func handleKey(_ key: KeyInterceptor.Key) -> Bool {
    let pending: (typo: TypoSuggestion?, llm: String, isPartial: Bool) = MainActor.assumeIsolated {
        if !session.partialRemainder.isEmpty { return (session.currentTypo, session.partialRemainder, true) }
        return (session.currentTypo, predictor.suggestion, false)
    }
    if pending.typo == nil, pending.llm.isEmpty { return false }
    switch key {
    case .tab:
        return MainActor.assumeIsolated { session.handleTab(suggestion: pending.llm, isPartial: pending.isPartial) }
    case .esc:
        return MainActor.assumeIsolated { session.handleEscape() }
    }
}
```

---

### `Sources/SouffleuseCoherence/main.swift` (MODIFIED — replay extension)

**Analog:** self (`Scenario` struct L220-235, `renderReplayResults` L367-444).

**Schema bump pattern** (preserve `version: Int` field per AllowlistFile convention referenced at L238):
```swift
// Source: main.swift:239-242 — bump version 1 → 2
struct ScenarioFile: Codable, Sendable {
    let version: Int   // was 1, now accepts 1 or 2
    let scenarios: [Scenario]
}
```

**Optional field addition pattern** (Scenario L220-235 — all v1→v2 additions are `Optional` so v1 JSONs still decode):
```swift
struct Scenario: Codable, Sendable {
    // ... existing fields verbatim ...
    let textAfterCaret: String?
    // ── Phase 4 additions (optional — v1 scenarios decode unchanged) ──
    let expectedCategory: ExpectedCategory?
    let expectedGhostPrefix: String?
}

enum ExpectedCategory: String, Codable, Sendable, CaseIterable {
    case correct, acceptable, useless, bad, parasite, skip
}
```

**Markdown rendering extension pattern** (main.swift L370-443 — extend `renderReplayResults` to emit a confusion matrix BEFORE the per-scenario detail table):
```swift
// Insert after the header preamble (~L399), before the per-scenario loop:
out += """

## Confusion Matrix (D-12)

|              | actual: correct | acceptable | useless | bad | total |
|--------------|-----------------|------------|---------|-----|-------|
"""
// rows: expectedCategory × counts
for expectedCat in ExpectedCategory.allCases where expectedCat != .skip {
    let counts = matrixCounts(results: results, expected: expectedCat)
    out += "| **expected: \(expectedCat.rawValue)** | \(counts.correct) | \(counts.acceptable) | \(counts.useless) | \(counts.bad) | \(counts.total) |\n"
}
```

**Auto-classification helper** (NEW pure function — RESEARCH §"Auto-classification in replay"):
```swift
// New: classify a replay ghost against expectedGhostPrefix
func classifyReplayGhost(ghost: String, expectedPrefix: String?) -> ExpectedCategory {
    guard let expected = expectedPrefix, !expected.isEmpty else { return .skip }
    if ghost.isEmpty { return .useless }
    if ghost.lowercased().hasPrefix(expected.lowercased()) { return .correct }
    // detection of bad requires human signal — naive replay can't distinguish
    return .acceptable
}
```

---

## Shared Patterns

### Pattern A: `@MainActor` façade + `@unchecked Sendable` snapshot box

**Source:** `Sources/Souffleuse/PredictorViewModel.swift` L64-72 (`CacheBox`) + L1212-1230 (`HolderSnapshot`)
**Apply to:** Every new module that crosses the `container.perform` boundary — `ModelRuntime`, `CompletionCache`.

```swift
// Source: PVM:64-72 verbatim
private struct CacheBox: @unchecked Sendable {
    let caches: [KVCache]
}
// Source: PVM:1212-1230 verbatim shape
struct HolderSnapshot: @unchecked Sendable {
    let caches: CacheBox?
    let fingerprint: String?
    let beforeCursorTokens: Int
}
let holderSnap: HolderSnapshot = await MainActor.run {
    if let existing = sessionCacheHolder.caches as? [KVCache] {
        return HolderSnapshot(caches: CacheBox(caches: existing), /* … */)
    }
    return HolderSnapshot(caches: nil, fingerprint: nil, beforeCursorTokens: 0)
}
```

**Rationale (per CLAUDE.md §Concurrency + RESEARCH §"Anti-Patterns"):** Façade is `@MainActor` so callsites stay synchronous. Closures crossing into `container.perform` use `@unchecked Sendable` boxes — never introduce a new `actor` for the split modules (would force `await` everywhere and kill the sub-ms cascade L0/L1 path).

---

### Pattern B: Generation counter + cancel-on-keystroke

**Source:** `Sources/Souffleuse/PredictorViewModel.swift` L111-116 + L772-776 + L853-854
**Apply to:** `GenerationPlanner` (canonical owner) — and `SuggestionPolicy.onLLMChunk` via the passed-in token.

```swift
// Source: PVM:113-116 (comment) + L772-776 (increment) + L853-854 (check)
// Bumped on every predict() and cancel(). onChunk closures capture the
// generation at creation time and silently drop updates from older
// generations, so stale stream chunks can't overwrite a fresh suggestion.
private var generation: UInt64 = 0
// At schedule time:
let previousTask = currentTask
previousTask?.cancel()
generation &+= 1
let myGeneration = generation
// In onChunk:
Task { @MainActor in
    guard let self, self.generation == myGeneration else { return }
    // …
}
```

**Pitfall (RESEARCH §"Common Pitfalls — Pitfall 1"):** Prefer passing an explicit `GenerationToken` through the request struct rather than relying on closure capture of `myGeneration` when the Planner reference itself could be swapped.

---

### Pattern C: `StaticString` event + count-only `Log.info`

**Source:** `Sources/SouffleuseLog/Log.swift` L22-46 (the `Log.info(_:_:count:)` API)
**Apply to:** All 5 new `ghost_classified_*` events (D-10) + the new `ghost_gate_*` events.

```swift
// Source: SouffleuseLog/Log.swift:23 signature
public static func info(_ module: LogModule, _ event: StaticString, count: Int? = nil)

// Source: PVM:209 verbatim (existing analog — KV cache invalidate)
Log.info(.predictor, "kv_cache_invalidate", count: 3)

// Phase 4 new events:
Log.info(.predictor, "ghost_classified_correct", count: visibleMs)
Log.info(.predictor, "ghost_classified_acceptable", count: chunksAccepted)
Log.info(.predictor, "ghost_classified_useless", count: visibleMs)
Log.info(.predictor, "ghost_classified_bad", count: visibleMs)
Log.info(.predictor, "ghost_classified_parasite", count: visibleMs)
Log.info(.predictor, "ghost_gate_block", count: Int(score.value * 100))
Log.info(.predictor, "ghost_gate_block_midword", count: chunk.count)
Log.info(.predictor, "ghost_keep_under_bar", count: currentGhost.count)
```

**Privacy invariant** (`Sources/SouffleuseLog/Log.swift` L36-37 comment): `StaticString` forces compile-time literals. `audit.sh` check 6 also forbids interpolating user-supplied fields. Phase 4 is compliant by construction — never log `accepted`, `contextBefore`, `entry.`, `prefix`, or the score components individually with their raw value (only the scaled `value * 100` int).

---

### Pattern D: Sendable value-type "snapshot" for cross-actor transfer

**Source:** `Sources/Souffleuse/KVCacheHolder.swift` L12-49 (`InvariancePrefix` is `Sendable, Equatable`)
**Apply to:** `Score` struct (D-06), `GhostUpdate` struct, `PredictRequest` struct, `LifecycleEndReason` enum.

```swift
// Source: KVCacheHolder.swift:12 verbatim shape
public struct InvariancePrefix: Sendable, Equatable {
    // immutable let fields, public initialiser
}

// Phase 4 application:
struct Score: Sendable, Equatable {
    let sourcePrior: Float
    let prefixFit: Float
    let lengthFit: Float
    var value: Float { sourcePrior * prefixFit * lengthFit }
    var passesGate: Bool { value >= SuggestionPolicy.Tuning.gateFloor }
    func beats(_ other: Score) -> Bool {
        value >= other.value * SuggestionPolicy.Tuning.replacementBar
    }
}
struct GhostUpdate: Sendable, Equatable {
    let text: String
    let source: SuggestionSource
    let score: Score
}
```

**Convention (CLAUDE.md §Conventions / Concurrency):** every cross-module value type is explicitly `Sendable`.

---

### Pattern E: Pure `static`/`nonisolated static` helpers for testability

**Source:** `Sources/Souffleuse/PredictorViewModel.swift` L1524 (`nonisolated static func historyExactSubstringMatch`)
**Apply to:** `SuggestionPolicy.score(source:ghost:userTail:)`, `SuggestionPolicy.prefixFit(...)`, `SuggestionPolicy.lengthFit(...)`, all `OutputFilter` helpers in `ModelRuntime` (`stripPrefixOverlap`, `ghostIsRepeatingPrefix`, `capToWords`).

```swift
// Source: PVM:1524 verbatim attribute pattern
nonisolated static func historyExactSubstringMatch(
    userTail: String,
    snapshot: [TypingHistoryEntry]
) -> String? { /* … */ }

// Phase 4 application:
static func score(
    source: SuggestionSource,
    ghost: String,
    userTail: String
) -> Score { /* pure */ }
```

**Rationale (CLAUDE.md §Function Design):** "Pure utilities live on the type as `static` functions so they're testable without instantiating."

---

### Pattern F: Atomic-commit per boundary + replay equivalence gate

**Source:** Phase 3 commit history (per `.planning/phases/03-perf-kv-cache/03-02-SUMMARY.md` Success Criterion 5)
**Apply to:** Every commit in the Phase 4 split (D-02).

**Workflow per commit:**
1. Extract a single boundary (one of: SuggestionPolicy, GenerationPlanner, CompletionCache, ModelRuntime, TypingSession).
2. Run `swift test` (must pass 126/126).
3. Run `bash audit.sh` (must pass all 6 checks — including check 6 for the new `ghost_classified_*` events).
4. Run `SouffleuseCoherence --replay` against the baseline `REPLAY-RESULTS.md` — output must be ε-identical (no ghost diff per scenario).
5. If any of 2/3/4 fails, revert the commit and isolate further.

**Critical:** `Souffleuse/audit.sh` already greps for `Log.*` interpolation of `accepted`/`contextBefore`/`entry.`/`prefix` — new events MUST use `StaticString` literals only (already enforced by `Log.info` signature).

---

## No Analog Found

All 13 files have at least a role-match analog. The Phase 4 refactor is entirely a re-organisation + 5 new log events + 1 new scorer pure function. No new external infrastructure or unfamiliar patterns required (confirmed by RESEARCH §"Don't Hand-Roll" — "Aucune nouvelle infrastructure n'est nécessaire").

---

## Metadata

**Analog search scope:**
- `Souffleuse/Sources/Souffleuse/*.swift` (12 files — app target)
- `Souffleuse/Sources/SouffleusePrompt/*.swift` (6 files)
- `Souffleuse/Sources/SouffleuseLog/*.swift` (1 file)
- `Souffleuse/Sources/SouffleuseCoherence/main.swift` (replay harness)
- `Souffleuse/Sources/SouffleuseTyping/WordCompleter.swift`
- `Souffleuse/Tests/SouffleuseTests/*.swift` (9 files)

**Files scanned:** 30 Swift files
**Pattern extraction date:** 2026-05-25

**Confidence:** HIGH — every excerpt is anchored to a specific line range in HEAD. The Phase 3 success of the same extraction pattern (KV cache rollout) is the strongest validation that this set of patterns will compose correctly.
