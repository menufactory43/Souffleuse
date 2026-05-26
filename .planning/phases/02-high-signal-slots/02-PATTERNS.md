# Phase 2: High-Signal Slots - Pattern Map

**Mapped:** 2026-05-25
**Files analyzed:** 9 (3 modified in SouffleusePrompt, 2 modified in SouffleuseAX, 3 modified in app/coherence/tests, 0 new)
**Analogs found:** 9 / 9

Phase 2 is **majority refactor** of Phase 1 artefacts (rename + extension). Most patterns are in-file self-precedent (Phase 1 shipped the canonical shape). The genuinely new pattern is **3 additional AX reads** wired into `AXSnapshot` and surfaced through the builder.

---

## File Classification

| Modified File | Role | Data Flow | Closest Analog | Match Quality |
|---------------|------|-----------|----------------|---------------|
| `Souffleuse/Sources/SouffleusePrompt/PromptSlot.swift` | enum-of-identifiers | n/a (value taxonomy) | itself (Phase 1) | exact (rename only) |
| `Souffleuse/Sources/SouffleusePrompt/PromptBudget.swift` | config value type | n/a (static config) | itself — `phase1Default` | exact (clone & extend) |
| `Souffleuse/Sources/SouffleusePrompt/PromptBuilder.swift` | builder (pure transform) | request-response (slots → BuiltPrompt) | itself — `build(...)` signature + assembly | exact (extend signature, reorder loop, add instrumentation) |
| `Souffleuse/Sources/SouffleusePrompt/BuiltPrompt.swift` | value-type result | transform output | itself | exact (consumer of renamed `PromptSlot.previousUserInputs` — no API shape change) |
| `Souffleuse/Sources/SouffleuseAX/AXClient.swift` (`AXSnapshot` lives at lines 10-54 of this file) | adapter (AX read) | request-response (synchronous AX read) | itself — `readSnapshot()` lines 361-428 + helpers `copyStringAttr` (line 659), `boundsForRange` (line 620) | exact (add 4 new reads using existing helpers) |
| `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` | controller (orchestrator) | event-driven (debounce + cancel-on-keystroke) | itself — `if PromptBuilderFlag.enabled` branch at lines 703-779 | exact (extend builder call site) |
| `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift` | orchestrator (tick polling) | event-driven (80ms timer) | itself — `tick()` at line 548 (`let snap = axClient.snapshot()`) | exact (transparent — extension propagates automatically) |
| `Souffleuse/Sources/SouffleuseCoherence/main.swift` | executable (CLI harness) | request-response (per-scenario predict) | itself — `replayScenario(...)` at line 271 + `Scenario` Codable at line 216 | exact (extend Scenario schema + replayScenario signature) |
| `Souffleuse/Tests/SouffleuseTests/PromptBuilderTests.swift` | test (snapshot + table) | sync `#expect` | itself — `builderAssemblesAllSlotsInOrder()` line 64 + `WordCountTokenCounter` line 17 | exact (clone tests for new slots) |

**No new files in Phase 2.** All work is rename + extension on Phase 1 artefacts. The `fieldContext` role-to-FR-label table (D-15d) lives inline in `PromptBuilder.swift` (private static helper) per the `ChunkSplitter.nextChunk` static-utility precedent — not a new file.

---

## Pattern Assignments

### `Souffleuse/Sources/SouffleusePrompt/PromptSlot.swift` (enum-of-identifiers)

**Analog:** itself (Phase 1 lines 1-23).

**Current shape** (PromptSlot.swift:9-23):
```swift
public enum PromptSlot: String, Sendable, CaseIterable, Hashable {
    // ── Active in Phase 1 ────────────────────────────────────
    case system
    case customInstructions
    case contextPrefix
    case fewShot
    case beforeCursor

    // ── Reserved for Phase 2/3 (declared, never filled at Phase 1) ────
    case afterCursor
    case fieldContext
    case previousUserInputs
    case clipboardContext
    case screenContext
}
```

**Phase 2 transformation** (D-16):
1. Delete `case fewShot` from the active block.
2. Move `case previousUserInputs`, `case afterCursor`, `case fieldContext` UP into the active block (they were declared reserved Phase 1).
3. Comment dividers updated to `// ── Active in Phase 2 ──` / `// ── Reserved for Phase 3 ──`.
4. `clipboardContext` and `screenContext` STAY in the reserved block (Phase 3, per D-14 boundary).

The enum is `CaseIterable + Hashable` — both used by the builder (`evictionPriority` array iteration, `slotTexts: [PromptSlot: String]` dictionary keys). Phase 2 preserves both conformances.

**No new conformances. No new dependencies.** Pure value taxonomy rename.

---

### `Souffleuse/Sources/SouffleusePrompt/PromptBudget.swift` (config value type)

**Analog:** itself — `phase1Default` at lines 22-31.

**Existing static-default precedent** (PromptBudget.swift:19-31):
```swift
/// Phase 1 default per RESEARCH §4. system=80 + customInstructions=40
/// + contextPrefix=150 + fewShot=80 + beforeCursor=200 = 550. Global cap
/// 512 enforces "if all slots fill, lowest-priority slots get squeezed".
public static let phase1Default = PromptBudget(
    global: 512,
    perSlot: [
        .system: 80,
        .customInstructions: 40,
        .contextPrefix: 150,
        .fewShot: 80,
        .beforeCursor: 200,
    ]
)
```

**Phase 2 transformation** (D-14d, D-15e, D-16b, and Claude's Discretion on `global`):
- Replace `.fewShot: 80` with `.previousUserInputs: 80` (rename, same budget per D-16b).
- Add `.fieldContext: 60` (D-15e).
- Add `.afterCursor: 120` (D-14d).
- Sum new perSlot: 80+40+150+60+120+80+200 = **730**. Phase 1 `global=512` → severe squeeze. Per Claude's Discretion: planner decides among `global: 512` (accept frequent eviction of `previousUserInputs`/`customInstructions`), `global: 768`, or `global: 1024`. gemma-3-1b context = 8192 → plenty of headroom.
- Recommended approach: introduce a NEW constant `phase2Default` rather than mutate `phase1Default`. Keeps Phase 1 verifiability (`01-VERIFICATION.md`) intact and makes the diff readable. Phase 1's `phase1Default` becomes effectively dead code at the call site but is preserved for the snapshot tests that still reference it.

**Doc-comment update:** Multi-line `///` rationale (per CONVENTIONS.md doc-comment style — "rationale, not just signature description"). Mirror the Phase 1 comment shape but reference the new sum and the chosen `global`.

**Sendable + Equatable preserved.** No isolation. Same as Phase 1.

---

### `Souffleuse/Sources/SouffleusePrompt/PromptBuilder.swift` (pure assembly builder)

**Analog:** itself — `build(...)` signature at lines 44-50, assembly loop at lines 118-127, eviction at lines 91-115.

#### Sub-pattern A: Extended `build(...)` signature (D-14b)

**Current signature** (PromptBuilder.swift:44-50):
```swift
public func build(
    system: String,
    customInstructions: String,
    contextPrefix: String,
    fewShot: String,
    beforeCursor: String
) -> BuiltPrompt {
```

**Phase 2 target signature:**
```swift
public func build(
    system: String,
    customInstructions: String,
    contextPrefix: String,
    fieldContext: String,
    afterCursor: String,
    previousUserInputs: String,
    beforeCursor: String
) -> BuiltPrompt {
```

Rename `fewShot:` → `previousUserInputs:` (D-16). Add `fieldContext:` and `afterCursor:` as new params. **Default values `= ""`** on new params to keep the legacy replay-harness invocation viable mid-migration (later remove defaults once all callers updated — Phase 2 plan step).

#### Sub-pattern B: Assembly order (D-14b)

**Current loop** (PromptBuilder.swift:118-127):
```swift
let assemblyOrder: [PromptSlot] = [
    .system, .customInstructions, .contextPrefix, .fewShot, .beforeCursor,
]
var bits: [String] = []
for slot in assemblyOrder {
    if let text = slotTexts[slot], !text.isEmpty {
        bits.append(text)
    }
}
let assembled = bits.joined(separator: "\n\n")
```

**Phase 2 target:**
```swift
let assemblyOrder: [PromptSlot] = [
    .system,
    .customInstructions,
    .contextPrefix,
    .fieldContext,
    .afterCursor,
    .previousUserInputs,
    .beforeCursor,
]
```
Per D-14b: `system → customInstructions → contextPrefix → fieldContext → afterCursor → previousUserInputs → beforeCursor`. `beforeCursor` stays last (just before the model's continuation).

#### Sub-pattern C: Eviction priority (Claude's Discretion in CONTEXT.md)

**Current priority** (PromptBuilder.swift:28-34):
```swift
public static let evictionPriority: [PromptSlot] = [
    .fewShot,
    .customInstructions,
    .contextPrefix,
    .beforeCursor,
    .system,
]
```

**Phase 2 target** (planner-finalised; CONTEXT.md "Claude's Discretion" provides the principle):
```swift
public static let evictionPriority: [PromptSlot] = [
    .previousUserInputs,    // first to drop — replaceable quality enhancer
    .customInstructions,    // second — user-supplied global, dropping is acceptable
    .contextPrefix,         // third — Phase 1 verdict showed low signal
    .afterCursor,           // fourth — high-signal but defensive; squeeze before fieldContext
    .fieldContext,          // fifth — high-signal structural; preserve when possible
    .beforeCursor,          // sixth — head-truncate (never drop; squeeze)
    .system,                // last-resort
]
```
Principle restated from CONTEXT.md "Claude's Discretion": drop replaceables first, then `contextPrefix`, keep high-signal slots (`fieldContext`, `afterCursor`) longest, `beforeCursor` is squeeze-only, `system` is last-resort.

#### Sub-pattern D: Per-slot instrumentation (D-17)

**Existing logging precedent** in the integration site (PredictorViewModel.swift:748):
```swift
Log.info(.predictor, "prompt_built", count: built.totalTokens)
```

**Phase 2 approach** (D-17a + D-17b decided per Claude's Discretion):
- Builder ITSELF stays free of logging (Phase 1 design rule per `01-PATTERNS.md` §Privacy — "Builder API never accepts a logger; SouffleusePrompt issues zero `Log.*` calls").
- Instead: `BuiltPrompt` already carries `slotTokenCounts: [PromptSlot: Int]` — the integration site (PredictorViewModel) does the logging.
- Build-time measurement: capture `let t0 = Date()` before `builder.build(...)`, then `let buildMs = Int(Date().timeIntervalSince(t0) * 1000)` after. Log via `Log.info(.predictor, "prompt_build_ms", count: buildMs)`.
- Optional per-slot count event if diagnose-value justifies the log volume (planner decides). Format would be `Log.info(.predictor, "prompt_slot_field_context_tokens", count: built.slotTokenCounts[.fieldContext] ?? 0)` — StaticString event literal, integer count only. Audit-safe.

**Privacy invariant preserved:** All events are compile-time `StaticString` literals; `count: Int` is the only whitelisted dynamic field. No user-derived string ever crosses the log boundary.

#### Sub-pattern E: Role/subrole → FR label table (D-15d)

**Static utility precedent** — `ChunkSplitter` (`Souffleuse/Sources/SouffleuseTyping/ChunkSplitter.swift`) is the project's canonical "pure-static-function module" pattern. `TypoDetector.lastWord` (line 39-43 of TypoDetector.swift) is another exemplar.

**Phase 2 placement:** Add a `private static let roleLabelsFR: [String: String]` constant on `PromptBuilder` (or on a new tiny private helper struct co-located in `PromptBuilder.swift` if the planner prefers). Mapping example (D-15c):
```swift
private static let roleLabelsFR: [String: String] = [
    "AXSearchField": "recherche",
    "AXTextArea": "zone de texte",
    "AXTextField": "champ texte",
    "AXComboBox": "menu déroulant",
]

/// Resolves a FR label for the focused AX role/subrole, preferring subrole
/// when present (more specific). Returns nil if no mapping known — the
/// caller skips the "Champ : X." line in that case.
private static func roleLabelFR(role: String?, subrole: String?) -> String? {
    if let subrole, let label = roleLabelsFR[subrole] { return label }
    if let role, let label = roleLabelsFR[role] { return label }
    return nil
}
```
- `private static` keeps it internal to the file and trivially testable via `@testable import` (matches `tailTruncateToWordBoundary` precedent at PromptBuilder.swift:140).
- Coverage is intentionally non-exhaustive per D-15d ("extend at each app tested").
- French strings inline per CONVENTIONS.md §Localisation (FR-first, no `.strings`).

**Sendability + isolation preserved:** Still `public struct PromptBuilder: Sendable`. The role-label table is a `private static let [String: String]` literal — `Sendable` by construction.

---

### `Souffleuse/Sources/SouffleusePrompt/BuiltPrompt.swift` (value-type result)

**Analog:** itself (Phase 1, BuiltPrompt.swift:7-42).

**No API shape change.** `slotTexts: [PromptSlot: String]` and `slotTokenCounts: [PromptSlot: Int]` are dictionaries keyed by the enum — the rename `fewShot` → `previousUserInputs` flows transparently. New slots (`fieldContext`, `afterCursor`) just become additional keys.

**Mechanical update only:** anywhere consumers explicitly subscript `built.slotTexts[.fewShot]` (PredictorViewModel.swift:764), update to `.previousUserInputs`. The instruct-path reconstruction at PredictorViewModel.swift:760-765 also needs new entries for `.fieldContext` and `.afterCursor`.

---

### `Souffleuse/Sources/SouffleuseAX/AXSnapshot` + `AXClient.readSnapshot()` (AX read adapter)

**File location:** `Souffleuse/Sources/SouffleuseAX/AXClient.swift` (AXSnapshot lives at lines 10-54 of this file — NOT a separate file despite the naming convention; per CONTEXT.md `<canonical_refs>` mention of `AXSnapshot.swift` the planner should verify and may opt to extract it into its own file as a side benefit. **For Phase 2 we extend in place**, matching the existing structure).

**Analog (snapshot value type):** itself — `AXSnapshot` struct at AXClient.swift:10-54.

**Existing shape** (AXClient.swift:10-44):
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
    public let elementRect: CGRect?

    public init(
        bundleID: String?,
        role: String?,
        subrole: String?,
        text: String?,
        caretIndex: Int?,
        caretRect: CGRect?,
        caretFont: AXFontInfo?,
        windowTitle: String? = nil,
        elementRect: CGRect? = nil
    ) {
        ...
    }
```

**Phase 2 extension** — add 3 new fields (per CONTEXT.md `<canonical_refs>` "Sites de modification primaires"):
```swift
public let placeholder: String?     // kAXPlaceholderValueAttribute
public let help: String?             // kAXHelpAttribute
public let textAfterCaret: String?   // computed via kAXStringForRangeAttribute
// role + subrole already present (lines 12-13)
```
Add each to the `init(...)` with default `= nil` (existing convention at lines 32-33 already uses defaults for newer fields — `windowTitle: String? = nil`, `elementRect: CGRect? = nil`). This preserves source compatibility with any caller that constructs an AXSnapshot manually (rare — only the AXClient does).

**Sendable + Equatable preserved.** All new fields are `String?` — already Sendable. Equatable synthesises automatically.

**Test convenience predicate precedent** (AXSnapshot.isTextElement at lines 46-49):
```swift
public var isTextElement: Bool {
    guard let role else { return false }
    return AXClient.textRoles.contains(role)
}
```
**Apply if useful:** `public var hasFieldMetadata: Bool { placeholder != nil || help != nil }` — optional convenience; planner decides whether the call sites benefit.

#### AX read pattern (3 new attributes in `readSnapshot()`)

**Helper API** (AXClient.swift:652-661):
```swift
private func copyAttr(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
    var ref: AnyObject?
    let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
    guard status == .success else { return nil }
    return ref
}

private func copyStringAttr(_ element: AXUIElement, _ attribute: String) -> String? {
    copyAttr(element, attribute) as? String
}
```

**Apply for `placeholder` and `help`** — direct one-liners using the existing helper:
```swift
let placeholder = copyStringAttr(element, kAXPlaceholderValueAttribute)
let help = copyStringAttr(element, kAXHelpAttribute)
```
Place near the `text` read at AXClient.swift:405. The existing secure-field guard at line 397-399 must continue to skip these reads (the early return already excludes them — verify).

**Parameterized attribute pattern for `textAfterCaret`** — analog: `boundsForRange(_:location:length:)` at AXClient.swift:617-634:
```swift
private func boundsForRange(_ element: AXUIElement, location: Int, length: Int) -> CGRect? {
    var probe = CFRange(location: location, length: length)
    guard let axRange = AXValueCreate(.cfRange, &probe) else { return nil }
    var bounds: AnyObject?
    let status = AXUIElementCopyParameterizedAttributeValue(
        element,
        kAXBoundsForRangeParameterizedAttribute as CFString,
        axRange,
        &bounds
    )
    guard status == .success, let bounds else { return nil }
    ...
}
```

**Apply for `textAfterCaret`** — same `CFRange` + `AXValueCreate` + `AXUIElementCopyParameterizedAttributeValue` shape, but with `kAXStringForRangeParameterizedAttribute`:
```swift
private func stringForRange(_ element: AXUIElement, location: Int, length: Int) -> String? {
    var probe = CFRange(location: location, length: length)
    guard let axRange = AXValueCreate(.cfRange, &probe) else { return nil }
    var ref: AnyObject?
    let status = AXUIElementCopyParameterizedAttributeValue(
        element,
        kAXStringForRangeParameterizedAttribute as CFString,
        axRange,
        &ref
    )
    guard status == .success else { return nil }
    return ref as? String
}
```
Then in `readSnapshot()`, after `caretIndex` is resolved (around AXClient.swift:406-407) and `text` length is known:
```swift
let textAfterCaret: String? = {
    guard let text, let caretIndex, caretIndex < text.count else { return nil }
    let remaining = text.count - caretIndex
    // Cap upstream to keep AX read bounded; 500 chars ≈ 100-180 tokens, well above the 120-token afterCursor budget.
    let length = min(remaining, 500)
    let s = stringForRange(element, location: caretIndex, length: length)
    return (s?.isEmpty == false) ? s : nil
}()
```
Per D-14c: when the result is nil/empty, the slot is skipped downstream — no AX-side error handling beyond returning `nil`.

**Privacy:** No `Log.*` call inside these AX reads contains user-text. No `print(`, no `os_log` (audit.sh check #1-3). The helpers return values up to `AXSnapshot` which crosses to `PredictorViewModel` as a Sendable struct.

**Threading:** All reads happen inside `axClient.queue.sync { ... }` (the existing AXClient pattern at line 63). No isolation change. The new `stringForRange` helper is private to AXClient (no `public` keyword).

---

### `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` (controller / integration site)

**Analog:** itself — the `if PromptBuilderFlag.enabled` branch at lines 703-779.

**Existing call site** (PredictorViewModel.swift:738-744):
```swift
let built = builder.build(
    system: baseSystem,
    customInstructions: customInstr,
    contextPrefix: ctxPrefix,
    fewShot: examplesBlock,
    beforeCursor: userTail
)
```

**Phase 2 transformation:**
1. **Signature plumbing — extend `predict(...)`** (line 379):
   - Current: `func predict(prefix: String, contextPrefix: String = "", customInstructions: String = "")`
   - Phase 2: add `axSnapshot: AXSnapshot? = nil` (or 3 individual params: `placeholder`, `help`, `role`, `subrole`, `textAfterCaret`). Strong preference for the **single `AXSnapshot?` param** — it preserves the existing pattern of passing the snapshot through (`SouffleuseAppDelegate.tick()` already has `let snap = axClient.snapshot()` at line 548), and Phase 2's AX extension is precisely additive on AXSnapshot. Passing the whole snapshot also leaves room for future slots without further signature changes.

2. **Construct the new slot bodies** inside the `if PromptBuilderFlag.enabled` branch (between lines 724 and 738):
```swift
// fieldContext slot body — D-15c format (FR annotation, omit empty lines)
let fieldContextSlot: String = {
    guard let snap = axSnapshot else { return "" }
    var lines: [String] = []
    if let label = PromptBuilder.roleLabelFR(role: snap.role, subrole: snap.subrole) {
        lines.append("Champ : \(label).")
    }
    if let ph = snap.placeholder?.trimmingCharacters(in: .whitespacesAndNewlines), !ph.isEmpty {
        lines.append("Placeholder : « \(ph) ».")
    }
    if let h = snap.help?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty {
        lines.append("Aide : « \(h) ».")
    }
    return lines.joined(separator: "\n")
}()

// afterCursor slot body — D-14 format, skip if empty (D-14c)
let afterCursorSlot: String = {
    guard let snap = axSnapshot,
          let after = snap.textAfterCaret?.trimmingCharacters(in: .whitespacesAndNewlines),
          !after.isEmpty else { return "" }
    return "Suite du texte (à ne pas répéter) : « \(after) »."
}()

let built = builder.build(
    system: baseSystem,
    customInstructions: customInstr,
    contextPrefix: ctxPrefix,
    fieldContext: fieldContextSlot,
    afterCursor: afterCursorSlot,
    previousUserInputs: examplesBlock,    // renamed from `fewShot:` per D-16
    beforeCursor: userTail
)
```

3. **Update the instruct-path reconstruction** (lines 760-765):
```swift
let systemContent = [
    built.slotTexts[.system],
    built.slotTexts[.customInstructions],
    built.slotTexts[.contextPrefix],
    built.slotTexts[.fieldContext],
    built.slotTexts[.afterCursor],
    built.slotTexts[.previousUserInputs],  // renamed from .fewShot
].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
```

4. **Instrumentation** (D-17 — already present pattern at line 748):
```swift
Log.info(.predictor, "prompt_built", count: built.totalTokens)
// Optionally add:
Log.info(.predictor, "prompt_build_ms", count: buildMs)
```
StaticString event literals + integer count only. NEVER log `fieldContextSlot`, `afterCursorSlot`, `built.text`, `built.slotTexts[.beforeCursor]`, or anything derived from user input. (audit.sh enforces this.)

**Threading invariant preserved:** All builder construction stays inside the `container.perform { context in ... }` actor-isolated closure (line 690). `axSnapshot` is `Sendable` (AXSnapshot is `Sendable` per AXClient.swift:10) — crosses the closure boundary freely. `PromptBuilder` + `BuiltPrompt` are `Sendable` structs.

---

### `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift` (orchestrator)

**Analog:** itself — `tick()` at line 540+, snapshot read at line 548 (`let snap = axClient.snapshot()`).

**Phase 2 work is minimal — propagate the snapshot:**

The delegate already calls `axClient.snapshot()` every 80ms and gates the predict on `snap.isTextElement` (line 572). It already passes `snap.text`, `snap.caretIndex`, etc., down. Phase 2 needs the snapshot's NEW fields (placeholder/help/textAfterCaret) to reach `PredictorViewModel.predict(...)`.

**Two viable approaches** (planner picks):
- **A. Pass the whole `AXSnapshot` to `predict(...)`** (preferred, see PredictorViewModel section). Add `axSnapshot: snap` to every call site of `predictor.predict(...)` in the delegate. Greppable: `grep -n "predict(prefix:" SouffleuseAppDelegate.swift`.
- **B. Pass individual new fields** (more conservative — keeps `predict` signature flatter). Add `placeholder: snap.placeholder, help: snap.help, role: snap.role, subrole: snap.subrole, textAfterCaret: snap.textAfterCaret`. Verbose at call sites but no new dependency on `SouffleuseAX` types beyond what's already imported.

Recommend A — the existing `predict()` signature already grew to absorb `contextPrefix` and `customInstructions` ad-hoc; bundling new structural data behind `axSnapshot: AXSnapshot?` reverses the entropy.

**No new isolation, no new actor. tick() stays @MainActor.**

---

### `Souffleuse/Sources/SouffleuseCoherence/main.swift` (replay harness)

**Analog:** itself — `Scenario` Codable at lines 216-225, `replayScenario(...)` at lines 271-311.

**Existing Scenario schema** (Coherence main.swift:216-225):
```swift
struct Scenario: Codable, Sendable {
    let id: String
    let label: String
    let bundleID: String
    let windowTitle: String?
    let contextPrefix: String
    let userTail: String
    let notes: String?
    let customInstructions: String?
}
```

**Phase 2 extension** (Claude's Discretion in CONTEXT.md — schema-aware enrichment if scenarios are extended):
```swift
struct Scenario: Codable, Sendable {
    let id: String
    let label: String
    let bundleID: String
    let windowTitle: String?
    let contextPrefix: String
    let userTail: String
    let notes: String?
    let customInstructions: String?
    // ── Phase 2 additions (all optional — backward compat with v1 scenarios) ──
    let role: String?
    let subrole: String?
    let placeholder: String?
    let help: String?
    let textAfterCaret: String?
}
```
All new fields are `Optional` → existing 12 scenarios decode unchanged. New scenarios (the "mid-typing" cases mentioned in CONTEXT.md Claude's Discretion) can populate the new fields to exercise `afterCursor` / `fieldContext`. **ScenarioFile.version stays at 1** since the schema is backward-compatible (additive optionals only) — only bump to 2 if planner adds a breaking change. AllowlistFile (`Souffleuse/Sources/Souffleuse/AllowlistConfig.swift:40`) precedent: bump version only on schema break.

**Existing replayScenario signature** (Coherence main.swift:271-275):
```swift
func replayScenario(
    _ s: Scenario,
    contextPrefix: String,
    container: ModelContainer
) async -> String {
```

**Phase 2 target** — extend with Phase 2 slot bodies:
```swift
func replayScenario(
    _ s: Scenario,
    contextPrefix: String,
    container: ModelContainer
) async -> String {
    let result = try? await container.perform { ctx -> String in
        let counter = CoherenceTokenCounter(tokenizer: ctx.tokenizer)
        let builder = PromptBuilder(counter: counter, budget: .phase2Default)  // or .phase1Default until budget choice locked
        let system = "You are an inline autocomplete. Continue the user's text naturally."

        // Phase 2 slot bodies, reconstructed from the scenario JSON fields.
        let fieldContextSlot = Self.buildFieldContextSlot(role: s.role, subrole: s.subrole, placeholder: s.placeholder, help: s.help)
        let afterCursorSlot = Self.buildAfterCursorSlot(after: s.textAfterCaret)

        let built = builder.build(
            system: system,
            customInstructions: s.customInstructions ?? "",
            contextPrefix: contextPrefix,
            fieldContext: fieldContextSlot,
            afterCursor: afterCursorSlot,
            previousUserInputs: "",  // few-shot still not exercised in replay (Phase 1 caveat carries forward)
            beforeCursor: s.userTail
        )
        ...
    }
    ...
}
```

**Helper duplication is acceptable** for Phase 2 — same posture as Phase 1's `CoherenceTokenCounter` mirror of `MLXTokenCounter` (Coherence main.swift:234-237 `// TODO Phase 2: dedupe`). If the planner wants to dedupe, move `buildFieldContextSlot` and `buildAfterCursorSlot` to a small public helper in `SouffleusePrompt` (e.g. `PromptSlotBodies.swift`) — but the simpler path is to keep them inline here and inline-mirror in PredictorViewModel, matching Phase 1's accepted duplication.

**JSON load pattern preserved** (Coherence main.swift:313-318) — `JSONDecoder().decode(ScenarioFile.self, from: data)` works unchanged with optional new fields.

---

### `Souffleuse/Tests/SouffleuseTests/PromptBuilderTests.swift` (test suite)

**Analog:** itself — `WordCountTokenCounter` at line 17, `builderAssemblesAllSlotsInOrder()` at line 64.

**Existing baseline test** (PromptBuilderTests.swift:64-73):
```swift
@Test func builderAssemblesAllSlotsInOrder() {
    let counter = WordCountTokenCounter()
    let builder = PromptBuilder(counter: counter, budget: .phase1Default)
    let built = builder.build(
        system: "You are an inline autocomplete.",
        customInstructions: "Be concise.",
        contextPrefix: "App Slack window equipe.",
        fewShot: "Hello team how is it going",
        beforeCursor: "Bonjour, je voulais vous dire"
    )
```

**Phase 2 extensions** (mechanical updates + new test cases):

1. **Rename `fewShot:` → `previousUserInputs:`** in every existing test call site. Identical body; passes once the builder signature is updated.

2. **Update the snapshot string** expected in `builderAssemblesAllSlotsInOrder` to reflect the new assembly order (`fieldContext` + `afterCursor` slots empty → no change in output for the legacy 5-slot test, but the order DOES change relative position of `previousUserInputs`).

3. **New test: `builderEmitsFieldContextSlotWhenSupplied`**:
```swift
@Test func builderEmitsFieldContextSlotWhenSupplied() {
    let counter = WordCountTokenCounter()
    let builder = PromptBuilder(counter: counter, budget: .phase2Default)
    let built = builder.build(
        system: "Tu es un autocomplete.",
        customInstructions: "",
        contextPrefix: "",
        fieldContext: "Champ : recherche.\nPlaceholder : « Rechercher… ».",
        afterCursor: "",
        previousUserInputs: "",
        beforeCursor: "Hello"
    )
    #expect(built.text.contains("Champ : recherche."))
    #expect(built.text.contains("Placeholder : « Rechercher… »."))
}
```

4. **New test: `builderEmitsAfterCursorBeforeBeforeCursor`** (assembly order):
```swift
@Test func builderEmitsAfterCursorBeforeBeforeCursor() {
    let counter = WordCountTokenCounter()
    let builder = PromptBuilder(counter: counter, budget: .phase2Default)
    let built = builder.build(
        system: "",
        customInstructions: "",
        contextPrefix: "",
        fieldContext: "",
        afterCursor: "Suite du texte (à ne pas répéter) : « apres ».",
        previousUserInputs: "",
        beforeCursor: "avant"
    )
    let afterIdx = built.text.range(of: "Suite du texte")!.lowerBound
    let beforeIdx = built.text.range(of: "avant")!.lowerBound
    #expect(afterIdx < beforeIdx, "afterCursor must precede beforeCursor in assembly")
}
```

5. **New test: `builderSkipsSlotsWhenInputEmpty`** (D-14c, D-15):
```swift
@Test func builderSkipsSlotsWhenInputEmpty() {
    let counter = WordCountTokenCounter()
    let builder = PromptBuilder(counter: counter, budget: .phase2Default)
    let built = builder.build(
        system: "S",
        customInstructions: "",
        contextPrefix: "",
        fieldContext: "",      // empty → skipped
        afterCursor: "",       // empty → skipped
        previousUserInputs: "",
        beforeCursor: "B"
    )
    // No double-newline runs, no empty headers
    #expect(!built.text.contains("\n\n\n"))
    #expect(built.slotTokenCounts[.fieldContext] == nil)
    #expect(built.slotTokenCounts[.afterCursor] == nil)
}
```

6. **New test: `builderEvictsPreviousUserInputsFirstUnderGlobalCap`** (Phase 2 evictionPriority):
```swift
@Test func builderEvictsPreviousUserInputsFirstUnderGlobalCap() {
    // Use a tight global cap to force eviction of the lowest-priority slot first.
    let tight = PromptBudget(global: 10, perSlot: [
        .system: 4, .customInstructions: 4, .contextPrefix: 4,
        .fieldContext: 4, .afterCursor: 4,
        .previousUserInputs: 4, .beforeCursor: 4,
    ])
    let builder = PromptBuilder(counter: WordCountTokenCounter(), budget: tight)
    let built = builder.build(
        system: "a b c d",
        customInstructions: "e f g h",
        contextPrefix: "i j k l",
        fieldContext: "m n o p",
        afterCursor: "q r s t",
        previousUserInputs: "u v w x",
        beforeCursor: "y z"
    )
    // First victim per Phase 2 eviction priority = previousUserInputs.
    #expect(built.truncatedSlots.contains(.previousUserInputs))
    #expect(built.slotTokenCounts[.previousUserInputs] == nil)  // fully dropped
}
```

7. **Preserve never-mid-word invariant on `beforeCursor`** — existing tests stay valid; just update parameter names.

**Test patterns reused as-is:**
- `import Testing` + `@testable import SouffleusePrompt` (PromptBuilderTests.swift:1-3).
- Top-level `@Test func ...()` with descriptive sentence-style names (no `test_` prefix).
- `#expect(...)` (no XCTAssert).
- `WordCountTokenCounter` mock co-located in the test file under `// MARK: - Test doubles`.
- `SentenceAwareTokenCounter` (PromptBuilderTests.swift:36-60) stays as-is — sentence boundary tests on `beforeCursor` still apply.

**No async, no fixtures, no IO.** Builder is pure.

---

## Shared Patterns

### Concurrency / Isolation
**Source:** `01-PATTERNS.md` §Shared Patterns + CONVENTIONS.md §Concurrency.

**Apply to all Phase 2 changes:**
- `PromptBuilder`, `BuiltPrompt`, `PromptBudget`, `PromptSlot`, `AXSnapshot` all remain `Sendable` value types. **No new actor, no `@MainActor`.**
- `PredictorViewModel` stays `@MainActor`. New code added to `predict(...)` body inherits that isolation.
- `axClient.snapshot()` already serializes through `cocotypist.ax.client` `DispatchQueue` (AXClient.swift:63). New AX reads (`stringForRange` helper) run on the same queue automatically — no change.

### Sendability
**Source:** CONVENTIONS.md §Sendability — "Every cross-module value type is explicitly `Sendable`."

**Apply:** Every new field added to `AXSnapshot` is `String?` (already Sendable). No `@unchecked Sendable` needed anywhere in Phase 2. The PromptBuilder API surface stays `public struct ... : Sendable`.

### Privacy / Logging (TEST-03 lock — non-negociable)
**Source:** `Souffleuse/Sources/SouffleuseLog/Log.swift` + `Souffleuse/audit.sh` SHIPPING_DIRS checks.

**Apply to all Phase 2 code (PromptBuilder + AXClient + PredictorViewModel + SouffleuseAppDelegate):**
- ONLY `Log.info(.predictor, "literal_event_name", count: optionalInt)`. Event names are `StaticString` literals — the type system enforces this (Log.swift API).
- NEVER log `placeholder`, `help`, `textAfterCaret`, `fieldContextSlot`, `afterCursorSlot`, `built.text`, `built.slotTexts[*]`, `userTail`, or anything derived from user input.
- `SouffleusePrompt` library stays log-free (Phase 1 design rule preserved — see `01-PATTERNS.md`).
- NO `print(`, NO `os_log(` in `SHIPPING_DIRS` (audit.sh checks #1-3).
- `audit.sh` already has `Sources/SouffleuseAX` and `Sources/Souffleuse` in SHIPPING_DIRS (since Phase 1) — no audit.sh changes needed for Phase 2.

### File naming / one-type-per-file
**Source:** CONVENTIONS.md §Naming Patterns.

**Phase 2 has NO new files.** All extensions are in-place modifications of existing files. The `AXSnapshot` value type IS currently sharing `AXClient.swift` (lines 10-54) with the `AXClient` class — Phase 1 accepted this loose grouping (matches `AllowlistConfig.swift` precedent which carries 4 types). Phase 2 preserves it; planner may opt to extract `AXSnapshot` into its own file as a side-improvement but it's not required.

### Test mock pattern
**Source:** `01-PATTERNS.md` + CONVENTIONS.md §Test-Only Hooks.

**Apply:** Existing `WordCountTokenCounter` and `SentenceAwareTokenCounter` mocks (PromptBuilderTests.swift:17 and :36) stay co-located in the test file under `// MARK: - Test doubles`. No new mock needed for Phase 2 — the AX extension is exercised via integration (replay harness with scenarios carrying explicit `role`/`placeholder`/`textAfterCaret` JSON fields), not unit-mocked. If the planner wants a unit-level test for the `roleLabelFR` helper, add it as a `@Test func` directly invoking `PromptBuilder.roleLabelFR(role:subrole:)` (private static — uses `@testable import`).

### Doc-comment style
**Source:** CONVENTIONS.md §Documentation Comments + `Log.swift:11-13` exemplar.

**Apply:** Triple-slash `///` on every public type and method. Multi-line includes rationale: WHY the slot exists (e.g. "Captures placeholder/help/role beyond what AppContextProbe surfaces — high signal for empty-field cases per Phase 1 verdict"), not just signature description. Inline `// ` comments explain WHY (especially around D-14c skip-if-empty, D-15c lines-conditional-on-presence).

### French-first inline strings
**Source:** CONVENTIONS.md §Localisation.

**Apply:** All new slot-body text templates use FR typography inline:
- `"Champ : \(label)."`
- `"Placeholder : « \(text) »."`
- `"Aide : « \(text) »."`
- `"Suite du texte (à ne pas répéter) : « \(text) »."`

No `.strings`, no `NSLocalizedString`. The role-label table (`roleLabelsFR`) uses French values directly.

### Atomic-ish edits across the rename
**Source:** CONVENTIONS.md §Persistence — `data.write(to: url, options: .atomic)`.

**N/A directly** — no on-disk format changes. But the spiritual analog applies to the codebase change: prefer doing the `fewShot` → `previousUserInputs` rename as a single mechanical commit (enum + budget + builder signature + integration site + tests + coherence harness in one atomic step) rather than dribbled. The planner schedules this as a single early plan step so the project never sits in a half-migrated state. Phase 1 explicitly anticipated this rename (`previousUserInputs` was already declared in the reserved block at PromptSlot.swift:20).

---

## No Analog Found

None for Phase 2 — every modification reuses an in-file precedent established in Phase 1 (`PromptBuilder`, `PromptBudget`, `BuiltPrompt`, `PromptSlot`, `PromptBuilderTests`, `replayScenario`) or extends an existing AXClient helper (`copyAttr`, `copyStringAttr`, `boundsForRange`) with the same parameterized-attribute shape.

The single arguably-new pattern is the **`kAXStringForRangeParameterizedAttribute` read** for `textAfterCaret`, but its mechanical shape mirrors `kAXBoundsForRangeParameterizedAttribute` (AXClient.swift:620-634) one-for-one — just different attribute name and a different return type cast (`String` instead of `CGRect`).

---

## Metadata

**Analog search scope:**
- `Souffleuse/Sources/SouffleusePrompt/` (PromptSlot, PromptBudget, PromptBuilder, BuiltPrompt, TokenCounting — all Phase 1 artefacts)
- `Souffleuse/Sources/SouffleuseAX/AXClient.swift` (AXSnapshot struct + readSnapshot() + helper methods)
- `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` (PromptBuilderFlag branch lines 703-779, predict signature line 379)
- `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift` (tick() snapshot consumption at line 548)
- `Souffleuse/Sources/SouffleuseCoherence/main.swift` (Scenario + replayScenario lines 213-318)
- `Souffleuse/Sources/SouffleusePersonalization/SimilarHistoryRetrieval.swift` (buildExamplesBlock — feeds `previousUserInputs` slot, unchanged Phase 2)
- `Souffleuse/Tests/SouffleuseTests/PromptBuilderTests.swift` (full file, ~80 lines visible)
- `Souffleuse/audit.sh` (SHIPPING_DIRS — no change)
- `Souffleuse/Sources/SouffleuseLog/Log.swift` (StaticString event API)
- `.planning/codebase/CONVENTIONS.md` (naming, sendability, doc-style, localisation, persistence)
- `.planning/phases/01-foundation-hypothesis-validation/01-PATTERNS.md` (Phase 1 pattern carryover)
- `.planning/phases/01-foundation-hypothesis-validation/01-CONTEXT.md` (D-10..D-13 locks)
- `.planning/phases/02-high-signal-slots/02-CONTEXT.md` (D-14..D-18 decisions, canonical_refs)

**Files scanned:** 9 Swift source files + 1 test file + 2 codebase intel docs + 2 phase artefact docs + CONTEXT.md (Phase 2) + PATTERNS.md (Phase 1)

**Pattern extraction date:** 2026-05-25

---

*Phase 2 Pattern Map: 2026-05-25*
