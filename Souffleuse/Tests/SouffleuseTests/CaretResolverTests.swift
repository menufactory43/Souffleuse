import AppKit
import Foundation
import Testing
@testable import Souffleuse
@testable import SouffleuseAX
@testable import SouffleuseContext
@testable import SouffleuseOverlay

// MARK: - Test doubles

/// Deterministic stand-in for the real Vision-backed locator. Records every
/// invocation so tests can assert on call count and arguments.
actor MockOCRCaretLocator: OCRCaretLocating {
    private(set) var callCount: Int = 0
    private var pending: [(CheckedContinuation<OCRCaretResult?, Never>)] = []
    var nextResult: OCRCaretResult? = nil
    /// When true, the locator deliberately stalls until `complete()` is
    /// called so a test can prove the OCR is in-flight.
    var holdUntilComplete: Bool = false

    func setNextResult(_ result: OCRCaretResult?) { self.nextResult = result }
    func setHoldUntilComplete(_ hold: Bool) { self.holdUntilComplete = hold }

    func locate(
        elementRect: CGRect,
        bundleID: String,
        text: String,
        caretIndex: Int
    ) async -> OCRCaretResult? {
        callCount += 1
        if !holdUntilComplete { return nextResult }
        return await withCheckedContinuation { (cont: CheckedContinuation<OCRCaretResult?, Never>) in
            pending.append(cont)
        }
    }

    /// Release every queued `locate(...)` with the current `nextResult`.
    func complete() {
        let result = nextResult
        let conts = pending
        pending.removeAll()
        for c in conts { c.resume(returning: result) }
    }
}

// MARK: - Fixtures

private func snapshot(
    bundleID: String? = "com.brave.Browser",
    text: String? = "Bonjour ",
    caretIndex: Int? = 8,
    elementRect: CGRect? = CGRect(x: 100, y: 200, width: 400, height: 30),
    caretRect: CGRect? = nil,
    caretFont: AXFontInfo? = nil
) -> AXSnapshot {
    AXSnapshot(
        bundleID: bundleID,
        role: "AXTextArea",
        subrole: nil,
        text: text,
        caretIndex: caretIndex,
        caretRect: caretRect,
        caretFont: caretFont,
        windowTitle: nil,
        elementRect: elementRect
    )
}

private func wait(_ ms: UInt64) async {
    try? await Task.sleep(nanoseconds: ms * 1_000_000)
}

/// Attente-condition bornée (pas de délai fixe) : les tâches OCR de fond
/// prennent > 100 ms quand la machine est chargée (les suites modèle-réel
/// saturent les cœurs) — un sleep fixe flake, un poll borné non.
@MainActor
private func waitUntil(
    timeoutMs: UInt64 = 3_000, _ condition: @MainActor () -> Bool
) async {
    var elapsed: UInt64 = 0
    while !condition(), elapsed < timeoutMs {
        await wait(10)
        elapsed += 10
    }
}

// MARK: - Tests

@MainActor
@Test func resolverReturnsAXRectUnchangedAndDoesNotFireOCR() async {
    let mock = MockOCRCaretLocator()
    let resolver = CaretResolver(locator: mock)
    let axRect = CGRect(x: 42, y: 84, width: 1, height: 18)
    let snap = snapshot(caretRect: axRect)

    let result = resolver.resolve(snapshot: snap) {}
    #expect(result == axRect)
    // Give the runloop a beat — no Task should have been spawned.
    await wait(50)
    let count = await mock.callCount
    #expect(count == 0)
    #expect(resolver.pendingOCRBundles.isEmpty)
}

@MainActor
@Test func resolverReturnsNilWhenAXSnapshotIsInsufficient() async {
    let mock = MockOCRCaretLocator()
    let resolver = CaretResolver(locator: mock)
    let snap = snapshot(text: nil, caretIndex: nil, elementRect: nil)
    let result = resolver.resolve(snapshot: snap) {}
    #expect(result == nil)
    await wait(50)
    let count = await mock.callCount
    #expect(count == 0)
}

@MainActor
@Test func resolverEstimatesAndQueuesOCRWhenBundleIsBrave() async {
    let mock = MockOCRCaretLocator()
    await mock.setHoldUntilComplete(true)
    let resolver = CaretResolver(locator: mock)
    let snap = snapshot()

    let estimate = resolver.resolve(snapshot: snap) {}
    #expect(estimate != nil)
    // Yield so the queued Task actually runs into `locate(...)`.
    await wait(100)
    #expect(resolver.pendingOCRBundles.contains("com.brave.Browser"))
    let count = await mock.callCount
    #expect(count == 1)
    // Cleanup so the dangling Task doesn't keep the test hanging.
    await mock.complete()
}

@MainActor
@Test func resolverDoesNotFireForNonOCRBundles() async {
    let mock = MockOCRCaretLocator()
    let resolver = CaretResolver(locator: mock)
    let snap = snapshot(bundleID: "com.apple.Notes")
    let estimate = resolver.resolve(snapshot: snap) {}
    #expect(estimate != nil)  // estimator still produces a result
    await wait(50)
    let count = await mock.callCount
    #expect(count == 0)
    #expect(resolver.pendingOCRBundles.isEmpty)
}

@MainActor
@Test func resolverHonoursCooldownWhenCalibrationIsFresh() async {
    let mock = MockOCRCaretLocator()
    let resolver = CaretResolver(locator: mock)
    let bundleID = "com.brave.Browser"
    let elementRect = CGRect(x: 100, y: 200, width: 400, height: 30)
    let metrics = CalibratedMetrics(fontPointSize: 16, leftPadding: 8, lineHeight: 22)
    // Plant a fresh calibration.
    resolver.setCalibration(bundleID: bundleID, metrics: metrics, elementRect: elementRect)

    let snap = snapshot(bundleID: bundleID, elementRect: elementRect)
    _ = resolver.resolve(snapshot: snap) {}
    await wait(50)
    let count = await mock.callCount
    #expect(count == 0)
    #expect(resolver.pendingOCRBundles.isEmpty)
}

@MainActor
@Test func resolverRefiresOCRWhenCalibrationIsStale() async {
    let mock = MockOCRCaretLocator()
    await mock.setHoldUntilComplete(true)
    let resolver = CaretResolver(locator: mock)
    let bundleID = "com.brave.Browser"
    let elementRect = CGRect(x: 100, y: 200, width: 400, height: 30)
    let metrics = CalibratedMetrics(fontPointSize: 16, leftPadding: 8, lineHeight: 22)
    // Pretend the last OCR ran 5 s ago (cooldown is 2 s).
    resolver.setCalibration(
        bundleID: bundleID,
        metrics: metrics,
        elementRect: elementRect,
        observedAt: Date().addingTimeInterval(-5)
    )

    let snap = snapshot(bundleID: bundleID, elementRect: elementRect)
    _ = resolver.resolve(snapshot: snap) {}
    await wait(100)
    let count = await mock.callCount
    #expect(count == 1)
    await mock.complete()
}

@MainActor
@Test func resolverRefiresWhenElementMovesPastShiftThreshold() async {
    let mock = MockOCRCaretLocator()
    await mock.setHoldUntilComplete(true)
    let resolver = CaretResolver(locator: mock)
    let bundleID = "com.brave.Browser"
    let calibrationRect = CGRect(x: 100, y: 200, width: 400, height: 30)
    let metrics = CalibratedMetrics(fontPointSize: 16, leftPadding: 8, lineHeight: 22)
    resolver.setCalibration(bundleID: bundleID, metrics: metrics, elementRect: calibrationRect)
    // Element jumped 200 pt — well past the 20 pt threshold.
    let movedRect = calibrationRect.offsetBy(dx: 0, dy: 200)
    let snap = snapshot(bundleID: bundleID, elementRect: movedRect)
    _ = resolver.resolve(snapshot: snap) {}
    await wait(100)
    let count = await mock.callCount
    #expect(count == 1)
    await mock.complete()
}

@MainActor
@Test func resolverInvokesOnRefinedAfterOCRSucceeds() async {
    let mock = MockOCRCaretLocator()
    await mock.setHoldUntilComplete(true)
    // refinedRect must sit inside the fixture's elementRect (100,200,400×30)
    // — the resolver now rejects OCR results that fall outside the field.
    let refinedRect = CGRect(x: 240, y: 210, width: 1, height: 20)
    await mock.setNextResult(OCRCaretResult(
        caretRect: refinedRect,
        calibratedMetrics: CalibratedMetrics(fontPointSize: 16, leftPadding: 8, lineHeight: 22)
    ))
    let resolver = CaretResolver(locator: mock)
    let snap = snapshot()

    // Use a class-wrapped flag so the @Sendable closure can mutate it.
    final class Flag: @unchecked Sendable { var value = false }
    let flag = Flag()

    _ = resolver.resolve(snapshot: snap) {
        flag.value = true
    }
    await wait(100)
    let count = await mock.callCount
    #expect(count == 1)
    #expect(flag.value == false)

    await mock.complete()
    // Let the awaiting Task hop back to the main actor.
    await wait(100)
    #expect(flag.value == true)
    #expect(resolver.pendingOCRBundles.isEmpty)
    #expect(resolver.calibration(for: "com.brave.Browser") != nil)
}

@MainActor
@Test func resolverDoesNotQueueDuplicateOCRWhileInFlight() async {
    let mock = MockOCRCaretLocator()
    await mock.setHoldUntilComplete(true)
    let resolver = CaretResolver(locator: mock)
    let snap = snapshot()

    _ = resolver.resolve(snapshot: snap) {}
    _ = resolver.resolve(snapshot: snap) {}
    _ = resolver.resolve(snapshot: snap) {}
    await wait(100)
    // Three calls, one in-flight task — duplicates suppressed.
    let count = await mock.callCount
    #expect(count == 1)
    await mock.complete()
}

@MainActor
@Test func resolverRejectsOCRResultOutsideElementRect() async {
    // The OCR matcher can align the AX prefix against text *outside* the
    // focused field (e.g. matching "Bonjour," against history above an
    // Intercom reply box). Such results must not poison the calibration —
    // otherwise the ghost floats far from the actual field.
    let mock = MockOCRCaretLocator()
    let resolver = CaretResolver(locator: mock)
    let element = CGRect(x: 100, y: 800, width: 400, height: 30)
    // OCR claims the caret is near the top of the screen — clearly outside
    // the field which sits at y=800.
    let farCaret = CGRect(x: 200, y: 50, width: 1, height: 16)
    await mock.setNextResult(OCRCaretResult(
        caretRect: farCaret,
        calibratedMetrics: CalibratedMetrics(fontPointSize: 16, leftPadding: 8, lineHeight: 22)
    ))
    let snap = snapshot(elementRect: element)
    _ = resolver.resolve(snapshot: snap) {}
    await waitUntil { resolver.pendingOCRBundles.isEmpty }
    // OCR completed but result was discarded → no calibration cached.
    #expect(resolver.calibration(for: "com.brave.Browser") == nil)
    #expect(resolver.pendingOCRBundles.isEmpty)
}

@MainActor
@Test func resolverAcceptsOCRResultJustOutsideWithSlack() async {
    // Within the slack window — should still be accepted. Guards against
    // off-by-one in the boundary check.
    let mock = MockOCRCaretLocator()
    let resolver = CaretResolver(locator: mock)
    let element = CGRect(x: 100, y: 200, width: 400, height: 30)
    // Caret rect sits a few pixels above the field's top edge — inside
    // the 12-pt slack window.
    let nearCaret = CGRect(x: 200, y: 192, width: 1, height: 16)
    await mock.setNextResult(OCRCaretResult(
        caretRect: nearCaret,
        calibratedMetrics: CalibratedMetrics(fontPointSize: 14, leftPadding: 6, lineHeight: 20)
    ))
    let snap = snapshot(elementRect: element)
    _ = resolver.resolve(snapshot: snap) {}
    await waitUntil { resolver.calibration(for: "com.brave.Browser") != nil }
    #expect(resolver.calibration(for: "com.brave.Browser") != nil)
}

@MainActor
@Test func resolverOCRRequiredBundleListIsMutable() async {
    let mock = MockOCRCaretLocator()
    await mock.setHoldUntilComplete(true)
    let resolver = CaretResolver(locator: mock)
    let bundleID = "com.example.custom"
    // Default: not in the list → no OCR.
    let snap = snapshot(bundleID: bundleID)
    _ = resolver.resolve(snapshot: snap) {}
    await wait(50)
    let count0 = await mock.callCount
    #expect(count0 == 0)

    // Add and re-resolve.
    let original = CaretResolver.ocrRequiredBundles
    CaretResolver.ocrRequiredBundles.insert(bundleID)
    defer { CaretResolver.ocrRequiredBundles = original }
    _ = resolver.resolve(snapshot: snap) {}
    await wait(100)
    let count1 = await mock.callCount
    #expect(count1 == 1)
    await mock.complete()
}
