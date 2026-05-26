import AppKit
import Foundation
import SouffleuseAX
import SouffleuseContext
import SouffleuseLog
import SouffleuseOverlay

/// Owns the 4-layer caret resolution strategy for hosts where AX refuses
/// to expose per-character bounds (Chromium-based browsers, contenteditable
/// surfaces, many Electron apps).
///
/// Layers, tried in order:
///   1. AX caret rect — instant. Bypassed entirely by the caller before
///      we get here.
///   2. `CaretEstimator` with OCR-derived calibrated metrics — instant.
///   3. `CaretEstimator` with built-in defaults — instant.
///   4. OCR refinement — async, fires at most once per `ocrCooldown` per
///      bundle, NEVER blocks the tick loop.
///
/// The OCR step is the only one that can update `calibrations`; layer 2 is
/// the steady state once we've seen the field at least once. Calibration
/// stays per-bundle (not per-field) on purpose — the cost of a stale
/// calibration when the user jumps between two fields in the same Brave
/// window is a few pixels of ghost drift on one frame, after which the
/// invalidation-on-rect-shift path replaces it.
@MainActor
public final class CaretResolver {
    /// Bundles where AX is known to return degenerate caret bounds for web
    /// content. Mutable so tests (and future heuristics) can extend it.
    public static var ocrRequiredBundles: Set<String> = [
        "com.brave.Browser",
        "com.google.Chrome",
        "com.microsoft.edgemac",
    ]

    /// Global kill-switch for the OCR-driven calibration. The OCR locator
    /// crops the screen capture to `elementRect` before recognising, so the
    /// matcher only ever sees pixels inside the focused field — false
    /// matches against surrounding chrome (Intercom conversation history,
    /// previous emails, …) are no longer possible. Leave on; flip off if
    /// some host turns out to feed elementRect values we can't trust.
    public static var isOCREnabled: Bool = true

    /// Re-fire interval. Below this we trust the cached calibration even
    /// across keystrokes; above it we re-OCR opportunistically to catch
    /// font-size / zoom changes.
    public static let ocrCooldown: TimeInterval = 2.0

    /// Distance threshold (in points) at which we consider the element to
    /// have moved enough that any cached calibration is suspect.
    public static let calibrationShiftThreshold: CGFloat = 20

    /// Slack around `elementRect` when sanity-checking an OCR result.
    /// The OCR matcher can align against text *outside* the focused field
    /// when the field's content is short and there's similar text on the
    /// page (e.g. matching "Bonjour," against conversation history above
    /// the reply box in Intercom). We use `elementRect` — the same
    /// ground-truth the presence badge anchors to — as the authoritative
    /// bound; any OCR-derived caret outside this expanded rect is rejected.
    public static let ocrInBoundsSlack: CGFloat = 12

    private let locator: OCRCaretLocating

    /// Per-bundle calibration record. We keep the element rect we saw it on
    /// so we can spot when the user has switched fields and the metrics
    /// no longer apply.
    private struct Calibration {
        let metrics: CalibratedMetrics
        let observedElementRect: CGRect
        let observedAt: Date
    }

    private var calibrations: [String: Calibration] = [:]
    private(set) public var pendingOCRBundles: Set<String> = []
    private var lastOCRTimestamps: [String: Date] = [:]

    public init(locator: OCRCaretLocating = OCRCaretLocator()) {
        self.locator = locator
    }

    /// Test hook: inject a calibration without going through OCR.
    func setCalibration(
        bundleID: String,
        metrics: CalibratedMetrics,
        elementRect: CGRect,
        observedAt: Date = Date()
    ) {
        calibrations[bundleID] = Calibration(
            metrics: metrics,
            observedElementRect: elementRect,
            observedAt: observedAt
        )
        lastOCRTimestamps[bundleID] = observedAt
    }

    /// Test hook: inspect the calibration for a bundle.
    func calibration(for bundleID: String) -> CalibratedMetrics? {
        calibrations[bundleID]?.metrics
    }

    /// Best-effort synchronous caret rect for the given AX snapshot.
    ///
    /// Side effect: when the bundle is OCR-required and the cached
    /// calibration is missing, stale, or for a meaningfully different
    /// element rect, we kick off an async OCR task. When that task
    /// completes successfully and updates the cache, `onRefined` is
    /// invoked back on the main actor so the caller can redraw.
    public func resolve(
        snapshot: AXSnapshot,
        onRefined: @escaping @MainActor () -> Void
    ) -> CGRect? {
        // Layer 1: AX caret rect short-circuits everything.
        if let rect = snapshot.caretRect {
            return rect
        }
        guard let text = snapshot.text,
              let caretIndex = snapshot.caretIndex,
              let elementRect = snapshot.elementRect,
              let bundleID = snapshot.bundleID
        else {
            return nil
        }

        let fontHint: NSFont? = snapshot.caretFont.flatMap {
            NSFont(name: $0.familyName, size: CGFloat($0.pointSize))
                ?? .systemFont(ofSize: CGFloat($0.pointSize))
        }

        // Layer 2 / 3: estimate using calibrated metrics when fresh, else defaults.
        let calibration = calibrations[bundleID]
        let metricsForEstimate: CalibratedMetrics? = {
            guard let calibration else { return nil }
            // We don't gate the estimate itself on staleness — a slightly old
            // calibration is still vastly better than the defaults. Staleness
            // only drives whether we re-fire OCR.
            return calibration.metrics
        }()

        let immediate = CaretEstimator.estimateRect(
            in: elementRect,
            text: text,
            caretIndex: caretIndex,
            font: fontHint,
            metrics: metricsForEstimate
        )

        // Layer 4: queue OCR when appropriate.
        if Self.isOCREnabled,
           Self.ocrRequiredBundles.contains(bundleID),
           shouldFireOCR(bundleID: bundleID, elementRect: elementRect, now: Date()) {
            pendingOCRBundles.insert(bundleID)
            lastOCRTimestamps[bundleID] = Date()
            let locator = self.locator
            Task { [weak self] in
                let result = await locator.locate(
                    elementRect: elementRect,
                    bundleID: bundleID,
                    text: text,
                    caretIndex: caretIndex
                )
                await MainActor.run {
                    guard let self else { return }
                    self.pendingOCRBundles.remove(bundleID)
                    guard let result else { return }
                    // Sanity check: the OCR matcher can align the AX prefix
                    // against text *outside* the field (e.g. conversation
                    // history above a chat reply box). Reject any caret rect
                    // that doesn't sit inside the badge's anchor — that
                    // would only poison the calibration cache and float the
                    // ghost far from the field.
                    let bounds = elementRect.insetBy(
                        dx: -Self.ocrInBoundsSlack,
                        dy: -Self.ocrInBoundsSlack
                    )
                    let caretCentre = CGPoint(
                        x: result.caretRect.midX,
                        y: result.caretRect.midY
                    )
                    guard bounds.contains(caretCentre) else {
                        Log.warn(.context, "ocr_caret_outside_field")
                        return
                    }
                    self.calibrations[bundleID] = Calibration(
                        metrics: result.calibratedMetrics,
                        observedElementRect: elementRect,
                        observedAt: Date()
                    )
                    onRefined()
                }
            }
        }

        return immediate
    }

    /// Decision matrix for re-firing OCR:
    ///   - never if a task is already in flight for this bundle,
    ///   - always if there's no calibration at all,
    ///   - always if the element rect shifted by > threshold (new field),
    ///   - otherwise only when the last OCR was more than `ocrCooldown` ago.
    private func shouldFireOCR(bundleID: String, elementRect: CGRect, now: Date) -> Bool {
        if pendingOCRBundles.contains(bundleID) { return false }
        guard let calibration = calibrations[bundleID] else { return true }
        let dx = abs(calibration.observedElementRect.minX - elementRect.minX)
        let dy = abs(calibration.observedElementRect.minY - elementRect.minY)
        if dx > Self.calibrationShiftThreshold || dy > Self.calibrationShiftThreshold {
            return true
        }
        if let lastFire = lastOCRTimestamps[bundleID] {
            return now.timeIntervalSince(lastFire) > Self.ocrCooldown
        }
        return true
    }
}
