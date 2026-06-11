import Testing
import Foundation
@testable import Souffleuse

// NOTE 11/06/2026 : la section « KV decision tree » (decideExtendTrimInvalidate,
// storeCaches, KVCacheHolder) a été retirée avec le chemin KV MLX mort — la
// réutilisation KV réelle vit dans LlamaEngine et est couverte par
// KVCacheReuseTests.

@MainActor
@Suite("Phase 4 — CompletionCache FIFO + fingerprint")
struct CompletionCacheTests {

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

    // MARK: - invalidateAll

    @Test func invalidateAllClearsEverything() {
        let cache = CompletionCache()
        cache.store(prefix: "k", suggestion: "v")
        cache.invalidateAll()
        // FIFO cleared.
        #expect(cache.predictCacheSnapshot.isEmpty)
    }
}
