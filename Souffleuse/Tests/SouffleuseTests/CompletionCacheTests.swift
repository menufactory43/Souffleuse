import Testing
import Foundation
import MLXLMCommon
@testable import Souffleuse

// NOTE: bypass behavior (`KVCacheBypassFlag.enabled` path) is covered by the
// existing `KVCacheBypassTests.swift`. The decideBypassWhenEnvVarSet case is
// intentionally omitted here — env var stubbing inside Swift Testing would
// require subprocess-level isolation since `KVCacheBypassFlag.enabled` is
// resolved once at static init.

@MainActor
@Suite("Phase 4 — CompletionCache FIFO + fingerprint + KV decision")
struct CompletionCacheTests {

    // MARK: - Fixture helpers

    private func makeInvariance(fingerprintMarker: String = "default") -> InvariancePrefix {
        InvariancePrefix(
            system: "sys-\(fingerprintMarker)",
            customInstructions: "ci",
            contextPrefix: "ctx",
            fieldContext: "fc",
            afterCursor: "ac",
            previousUserInputs: "pui"
        )
    }

    // MARK: - predictCache FIFO

    @Test func fifoEvictionAtCapacity32() {
        let cache = CompletionCache()
        let capacity = CompletionCache.predictCacheCapacity
        for i in 0..<capacity {
            cache.store(prefix: "key\(i)", suggestion: "v\(i)")
        }
        #expect(cache.predictCacheSnapshot.count == capacity)
        // Insert one more → oldest (key0) evicts.
        cache.store(prefix: "new", suggestion: "x")
        #expect(cache.predictCacheSnapshot.count == capacity)
        #expect(cache.lookup(userTail: "key0") == nil)
        #expect(cache.lookup(userTail: "new") == "x")
        #expect(cache.predictCacheOrderSnapshot.first == "key1")
        #expect(cache.predictCacheOrderSnapshot.last == "new")
    }

    @Test func storeIsIdempotentOnExistingKey_preservesOrder() {
        // Re-store on an existing key must overwrite the value WITHOUT
        // bumping its order position — preserves predictable FIFO ageing.
        let cache = CompletionCache()
        cache.store(prefix: "a", suggestion: "1")
        cache.store(prefix: "b", suggestion: "2")
        cache.store(prefix: "a", suggestion: "1-updated")
        #expect(cache.lookup(userTail: "a") == "1-updated")
        #expect(cache.predictCacheOrderSnapshot == ["a", "b"])
    }

    @Test func clearPredictCacheEmptiesAll() {
        let cache = CompletionCache()
        cache.store(prefix: "a", suggestion: "1")
        cache.store(prefix: "b", suggestion: "2")
        cache.clearPredictCache()
        #expect(cache.predictCacheSnapshot.isEmpty)
        #expect(cache.predictCacheOrderSnapshot.isEmpty)
    }

    // MARK: - Undo-as-ghost longest-extending-key

    @Test func longestExtendingKeyFindsLongest() {
        let cache = CompletionCache()
        cache.store(prefix: "abc", suggestion: "x")
        cache.store(prefix: "abcdef", suggestion: "y")
        let found = cache.longestExtendingKey(userTail: "ab")
        #expect(found?.key == "abcdef")
        #expect(found?.suggestion == "y")
    }

    @Test func longestExtendingKeyReturnsNilWhenNoStrictExtension() {
        let cache = CompletionCache()
        cache.store(prefix: "Bonjour", suggestion: "monde")
        // userTail equal to a stored key — not strictly longer ⇒ no candidate
        #expect(cache.longestExtendingKey(userTail: "Bonjour") == nil)
        // userTail not matched by any key
        #expect(cache.longestExtendingKey(userTail: "Salut") == nil)
        // Empty cache returns nil
        let empty = CompletionCache()
        #expect(empty.longestExtendingKey(userTail: "anything") == nil)
    }

    // MARK: - Context fingerprint

    @Test func updateContextFingerprint_firstCallSilentReturnsFalse() {
        let cache = CompletionCache()
        cache.store(prefix: "k", suggestion: "v")
        // First call records the fingerprint without invalidating (legacy
        // PVM:512-516 behaviour — `if let last = lastContextFingerprint, …`).
        let changed = cache.updateContextFingerprint("fp-A")
        #expect(changed == false)
        #expect(cache.lookup(userTail: "k") == "v")
        #expect(cache.lastContextFingerprintSnapshot == "fp-A")
    }

    @Test func updateContextFingerprintNoChangeReturnsFalse() {
        let cache = CompletionCache()
        cache.updateContextFingerprint("fp-A") // record
        cache.store(prefix: "k", suggestion: "v")
        let changed = cache.updateContextFingerprint("fp-A")
        #expect(changed == false)
        #expect(cache.lookup(userTail: "k") == "v")
    }

    @Test func updateContextFingerprintChangeClearsAndReturnsTrue() {
        let cache = CompletionCache()
        cache.updateContextFingerprint("fp-A") // record
        cache.store(prefix: "k", suggestion: "v")
        let changed = cache.updateContextFingerprint("fp-B")
        #expect(changed == true)
        #expect(cache.predictCacheSnapshot.isEmpty)
        #expect(cache.lastContextFingerprintSnapshot == "fp-B")
    }

    // MARK: - KV decision tree

    @Test func decideColdWhenHolderEmpty() {
        let cache = CompletionCache()
        let inv = makeInvariance()
        let d = cache.decideExtendTrimInvalidate(
            invariance: inv,
            userTailTokenCount: 10,
            promptTokens: 100
        )
        #expect(d == .cold)
    }

    @Test func decideFingerprintChangedWhenMismatch() {
        let cache = CompletionCache()
        let invA = makeInvariance(fingerprintMarker: "A")
        // Install with a DIFFERENT fingerprint than what we'll query with.
        cache.storeCaches([], fingerprint: "totally-other-fp", beforeCursorTokens: 50)
        let d = cache.decideExtendTrimInvalidate(
            invariance: invA,
            userTailTokenCount: 50,
            promptTokens: 100
        )
        #expect(d == .fingerprintChanged)
    }

    @Test func decideIdenticalWhenZeroDelta() {
        let cache = CompletionCache()
        let inv = makeInvariance()
        cache.storeCaches([], fingerprint: inv.fingerprint, beforeCursorTokens: 50)
        let d = cache.decideExtendTrimInvalidate(
            invariance: inv,
            userTailTokenCount: 50,
            promptTokens: 100
        )
        #expect(d == .identical)
    }

    @Test func decideExtendWhenPositiveDelta() {
        let cache = CompletionCache()
        let inv = makeInvariance()
        cache.storeCaches([], fingerprint: inv.fingerprint, beforeCursorTokens: 50)
        let d = cache.decideExtendTrimInvalidate(
            invariance: inv,
            userTailTokenCount: 55,
            promptTokens: 200
        )
        #expect(d == .extend(addedTokens: 5))
    }

    @Test func decideTrimWhenNegativeDelta() {
        let cache = CompletionCache()
        let inv = makeInvariance()
        cache.storeCaches([], fingerprint: inv.fingerprint, beforeCursorTokens: 50)
        let d = cache.decideExtendTrimInvalidate(
            invariance: inv,
            userTailTokenCount: 47,
            promptTokens: 100
        )
        // Decision is .trim(3) — caller (PVM/ModelRuntime) is responsible
        // for the canTrimPromptCache capability check and the downgrade to
        // .diverged when unsupported (PVM:1224 legacy gate).
        #expect(d == .trim(removedTokens: 3))
    }

    // MARK: - Holder delegation

    @Test func invalidateAllReturnsHolderToCold() {
        let cache = CompletionCache()
        cache.store(prefix: "k", suggestion: "v")
        let inv = makeInvariance()
        cache.storeCaches([], fingerprint: inv.fingerprint, beforeCursorTokens: 12)
        cache.invalidateAll()
        // FIFO cleared.
        #expect(cache.predictCacheSnapshot.isEmpty)
        // KV holder cold.
        #expect(cache.kvCacheHolder.caches == nil)
        #expect(cache.kvCacheHolder.fingerprint == nil)
        #expect(cache.kvCacheHolder.beforeCursorTokens == 0)
    }
}
