import Testing
import Foundation
@testable import Souffleuse

/// Validates the invariants that the env-var bypass path in PredictorViewModel
/// relies on (D-KV-06 / KV-06). KVCacheBypassFlag itself is `private` to
/// PredictorViewModel — we cannot import it directly. Instead we test the
/// holder contract that the bypass branch uses:
///
///   if envBypass {
///       chosenCache = makePromptCache(...)
///       // NO holder mutation — holder must stay cold.
///   }
///
/// The tests below assert that:
///   1. A freshly-constructed holder is cold (and stays cold without `install`).
///   2. Every `InvalidationReason` returns the holder to a cold state.
@Suite("KVCacheBypass — holder contract under bypass")
struct KVCacheBypassTests {

    @MainActor
    @Test func bypassPath_holderStaysCold() {
        let h = KVCacheHolder()
        // Bypass branch never calls install. Holder must be cold:
        #expect(h.caches == nil)
        #expect(h.fingerprint == nil)
        #expect(h.beforeCursorTokens == 0)
        // Even after a stray (non-install) interaction, it stays cold for caches:
        h.updateBeforeCursorTokens(42)
        #expect(h.caches == nil)
        #expect(h.fingerprint == nil)
    }

    @MainActor
    @Test func invalidate_cold_returnsCold() {
        let h = KVCacheHolder()
        h.updateBeforeCursorTokens(5)
        h.invalidate(reason: .cold)
        #expect(h.caches == nil)
        #expect(h.fingerprint == nil)
        #expect(h.beforeCursorTokens == 0)
    }

    @MainActor
    @Test func invalidate_fingerprintChanged_returnsCold() {
        let h = KVCacheHolder()
        h.updateBeforeCursorTokens(5)
        h.invalidate(reason: .fingerprintChanged)
        #expect(h.caches == nil)
        #expect(h.beforeCursorTokens == 0)
    }

    @MainActor
    @Test func invalidate_beforeCursorDiverged_returnsCold() {
        let h = KVCacheHolder()
        h.updateBeforeCursorTokens(5)
        h.invalidate(reason: .beforeCursorDiverged)
        #expect(h.caches == nil)
        #expect(h.beforeCursorTokens == 0)
    }

    @MainActor
    @Test func invalidate_explicit_returnsCold() {
        let h = KVCacheHolder()
        h.updateBeforeCursorTokens(5)
        h.invalidate(reason: .explicit)
        #expect(h.caches == nil)
        #expect(h.beforeCursorTokens == 0)
    }
}
