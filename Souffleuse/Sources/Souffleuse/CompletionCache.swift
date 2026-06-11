import Foundation
import SouffleusePrompt
import SouffleuseLog

/// Owns all cross-keystroke caches consolidated out of `PredictorViewModel`
/// (D-03 split, phase 4 wave 3). Deux concerns sous une frontière `@MainActor` :
///
///   1. `predictCache` — bounded FIFO(32) memo of `userTail → suggestion`.
///   2. `tokenCountCache` — bounded FIFO(64) memo of `string → token count`.
///
/// (Le `kvCacheHolder` MLX de l'ère 03-02 a été retiré le 11/06/2026 : zéro
/// caller — la réutilisation KV réelle vit DANS `LlamaEngine` (`kvTokens`),
/// prouvée par `KVCacheReuseTests`.)
///
/// Plus the cross-cutting `lastContextFingerprint` that drives `predictCache`
/// invalidation when the AX snapshot signal flips between predicts (PVM:492-503
/// migrated verbatim into `updateContextFingerprint`).
///
/// Phase 4 D-03 motivation : PVM was 1500+ LOC, mixing model lifecycle,
/// cascade routing, cache state, and stream loop. Pulling these caches out
/// reduces PVM ownership surface and concentrates the KV decision invariants
/// (order matters — Pitfall 4) in one tested unit.
@MainActor
final class CompletionCache {
    // MARK: - Capacity constants

    /// FIFO eviction capacity for `predictCache`. Mirrors the legacy PVM
    /// constant byte-identical (PVM:130).
    static let predictCacheCapacity = 32

    // MARK: - State

    private var predictCache: [String: String] = [:]
    private var predictCacheOrder: [String] = []

    /// Shared token-count cache for the active model's tokenizer, consumed via
    /// `MemoizingTokenCounter`. Persists across predicts so byte-identical
    /// slot inputs avoid re-tokenisation each keystroke. Cleared on model
    /// swap by the owner because counts are tokenizer-specific.
    let tokenCountCache = TokenCountCache(cap: 64)

    /// Fingerprint of the prompt-shaping context observed at the last
    /// predict() call. Composed of slowly-changing AX snapshot fields
    /// (bundleID, role, subrole, placeholder, help). Drives invalidation of
    /// `predictCache` whose entries are keyed on `userTail` only — without
    /// this we'd return a suggestion built for a previous app/field even
    /// though the prompt sent to the LLM differs now.
    /// `nil` ⇒ first predict of the session, nothing to compare yet.
    private var lastContextFingerprint: String?

    init() {}

    // MARK: - Test seams (internal)

    /// Test-only introspection of the FIFO memo. Production callers MUST use
    /// `lookup(userTail:)` — this snapshot is for assertion against insertion
    /// + eviction invariants.
    internal var predictCacheSnapshot: [String: String] { predictCache }

    /// Test-only introspection of the FIFO insertion order. Same caveat.
    internal var predictCacheOrderSnapshot: [String] { predictCacheOrder }

    /// Test-only fingerprint peek. Used by CompletionCacheTests to assert
    /// that updateContextFingerprint records the value before deciding to
    /// invalidate on the next call.
    internal var lastContextFingerprintSnapshot: String? { lastContextFingerprint }

    // MARK: - predictCache API

    /// Lookup a cached suggestion by `userTail`. Returns `nil` when absent.
    func lookup(userTail: String) -> String? {
        predictCache[userTail]
    }

    /// Store a `(prefix, suggestion)` pair in the FIFO cache, evicting the
    /// oldest entry when the capacity is exceeded. Idempotent on existing
    /// keys (we keep the original insertion order so the working set ages
    /// out predictably). Migrated verbatim from PVM:233-245.
    func store(prefix: String, suggestion: String) {
        if predictCache[prefix] != nil {
            predictCache[prefix] = suggestion
            return
        }
        predictCache[prefix] = suggestion
        predictCacheOrder.append(prefix)
        while predictCacheOrder.count > Self.predictCacheCapacity {
            let evicted = predictCacheOrder.removeFirst()
            predictCache.removeValue(forKey: evicted)
            Log.info(.predictor, "cache_evict")
        }
    }

    /// Drop every memoised suggestion. Called on model swap, explicit user
    /// cancel, and context fingerprint flips.
    func clearPredictCache() {
        predictCache.removeAll()
        predictCacheOrder.removeAll()
    }

    /// Undo-as-ghost lookup : find the LONGEST cached key that has
    /// `userTail` as a strict prefix. Returns `(key, suggestion)` or nil.
    /// Migrated verbatim from PVM:663-687 (strict-longer comparator).
    func longestExtendingKey(userTail: String) -> (key: String, suggestion: String)? {
        guard !predictCache.isEmpty else { return nil }
        var longestKey: String? = nil
        var longestLen = userTail.count  // strictly longer
        for key in predictCache.keys {
            if key.count > longestLen, key.hasPrefix(userTail) {
                longestKey = key
                longestLen = key.count
            }
        }
        if let key = longestKey, let cached = predictCache[key] {
            return (key, cached)
        }
        return nil
    }

    // MARK: - Context fingerprint

    /// Compare `fp` with the previously observed fingerprint. On change :
    /// clear `predictCache`, emit `cache_invalidate_context`, return true.
    /// Otherwise update + return false. Migrated verbatim from PVM:512-516.
    ///
    /// On first call (`lastContextFingerprint == nil`) the fingerprint is
    /// recorded silently and `false` is returned (matches legacy behaviour :
    /// the `if let last = lastContextFingerprint, last != fp` gate).
    @discardableResult
    func updateContextFingerprint(_ fp: String) -> Bool {
        if let last = lastContextFingerprint, last != fp {
            clearPredictCache()
            Log.info(.predictor, "cache_invalidate_context")
            lastContextFingerprint = fp
            return true
        }
        lastContextFingerprint = fp
        return false
    }

    /// Invalide tout : FIFO de suggestions + cache de comptes de tokens.
    /// L'événement `kv_cache_invalidate` est conservé pour la parité des logs
    /// historiques (les lecteurs aval s'y attendent sur un swap de modèle).
    func invalidateAll() {
        clearPredictCache()
        tokenCountCache.clear()
        Log.info(.predictor, "kv_cache_invalidate", count: 2) // .explicit
    }
}
