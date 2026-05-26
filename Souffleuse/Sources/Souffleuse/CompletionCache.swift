import Foundation
import MLXLMCommon
import SouffleusePrompt
import SouffleuseLog

/// Production rollback gate (D-KV-06 / KV-06). When this flag is enabled at
/// app launch, predict() bypasses the persisted KV cache holder and builds a
/// throw-away `[KVCache]` per predict — reproducing the pre-Phase-3 behaviour
/// for emergency rollback without a rebuild. Detection mirrors
/// `PromptBuilderFlag` (read once at static load). The env-var literal below
/// is the SINGLE source of truth (Phase 4 D-03 : migré de PVM:31-34 vers
/// CompletionCache.swift sans changer la chaîne, par safety net).
///
/// The flag name and value MUST NEVER appear in `Log.*` events (T3
/// privacy invariant — keep the user's local rollback choice off disk).
private enum KVCacheBypassFlag {
    static let enabled: Bool =
        ProcessInfo.processInfo.environment["SOUFFLEUSE_DISABLE_KV_CACHE"]?.isEmpty == false
}

/// Pure decision verdict for the KV cache "extend / trim / invalidate" branch.
/// Computed by `CompletionCache.decideExtendTrimInvalidate(...)` ; the caller
/// (PVM in 04-04, ModelRuntime in 04-05) is responsible for emitting the
/// `kv_cache_extend|trim|invalidate` log event and applying the resulting
/// `iteratorInputTokens` slicing or rebuilding the cache.
///
/// Order of evaluation is FROZEN (Pitfall 4 RESEARCH §"Common Pitfalls" —
/// reorder = subtle replay regression):
///   bypass → cold → fingerprintChanged → identical / extend / trim / diverged
///
/// Note : the historical PVM region (PVM:1197-1244) keeps trim gated by a
/// capability check on the cache type (`canTrimPromptCache`). The pure
/// decision returned here is `.trim(removedTokens)` ; the caller MUST verify
/// the capability and downgrade to `.diverged` when the cache type does not
/// support trim. There is no `MAX_TRIM_TOKENS` constant in the legacy region —
/// the cap is implicit in the cache type capability.
enum KVDecision: Sendable, Equatable {
    case bypass
    case cold
    case fingerprintChanged
    case extend(addedTokens: Int)
    case trim(removedTokens: Int)
    case diverged
    case identical
}

/// Owns all cross-keystroke caches consolidated out of `PredictorViewModel`
/// (D-03 split, phase 4 wave 3). Three logical concerns under one `@MainActor`
/// boundary :
///
///   1. `predictCache` — bounded FIFO(32) memo of `userTail → suggestion`.
///   2. `tokenCountCache` — bounded FIFO(64) memo of `string → token count`,
///      consumed by `MemoizingTokenCounter` per predict.
///   3. `kvCacheHolder` — the live `[KVCache]` slot persisted between
///      keystrokes (Plan 03-02 holder).
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

    /// Shared token-count cache for the active model's tokenizer. Wrapped
    /// around `MLXTokenCounter` at each predict via `MemoizingTokenCounter`.
    /// Persists across `container.perform` invocations so byte-identical
    /// slot inputs avoid re-tokenisation each keystroke. Cleared on model
    /// swap by the owner because counts are tokenizer-specific.
    let tokenCountCache = TokenCountCache(cap: 64)

    /// Cross-keystroke KV cache holder (Plan 03-02). Persists the MLX
    /// `[KVCache]` between consecutive predicts when the InvariancePrefix
    /// fingerprint is stable, so the prefill phase of TokenIterator only
    /// processes the delta beforeCursor tokens instead of the full prompt.
    let kvCacheHolder = KVCacheHolder()

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

    // MARK: - KV cache holder delegation

    /// Install a freshly-built cache array along with the fingerprint it was
    /// built for and the token count of the initial beforeCursor prefill.
    /// Pass-through to `KVCacheHolder.install(caches:fingerprint:beforeCursorTokens:)`.
    func storeCaches(_ caches: [Any], fingerprint: String, beforeCursorTokens: Int) {
        kvCacheHolder.install(
            caches: caches,
            fingerprint: fingerprint,
            beforeCursorTokens: beforeCursorTokens
        )
    }

    /// Invalidate the KV holder. Caller is responsible for emitting the
    /// `kv_cache_invalidate` count-only log event (PVM keeps that side
    /// effect until 04-05 ModelRuntime extraction).
    func invalidate(reason: KVCacheHolder.InvalidationReason) {
        kvCacheHolder.invalidate(reason: reason)
    }

    /// Compose the three actions of PVM:swapModel(L221-225) :
    /// `clearPredictCache()` + `kvCacheHolder.invalidate(.explicit)` +
    /// `tokenCountCache.clear()`, plus the `kv_cache_invalidate count:3`
    /// signal (.explicit). The count value matches the legacy emission so
    /// downstream log readers see no regression.
    func invalidateAll() {
        clearPredictCache()
        kvCacheHolder.invalidate(reason: .explicit)
        tokenCountCache.clear()
        Log.info(.predictor, "kv_cache_invalidate", count: 3) // .explicit
    }

    // MARK: - KV decision tree (PVM:1197-1244)

    /// Pure decision : given the freshly-built `InvariancePrefix`, the
    /// `userTail` token count, and the full prompt token count, returns the
    /// verdict for this predict's KV cache branch. NO log emission — the
    /// caller is responsible for the count-only signal.
    ///
    /// Order (verbatim PVM:1200-1244) :
    ///   1. `KVCacheBypassFlag.enabled` ⇒ `.bypass`
    ///   2. `kvCacheHolder.caches == nil` ⇒ `.cold`
    ///   3. `kvCacheHolder.fingerprint != invariance.fingerprint`
    ///       ⇒ `.fingerprintChanged`
    ///   4. delta = userTailTokenCount − beforeCursorTokens :
    ///       - delta == 0 ⇒ `.identical`
    ///       - delta > 0 ⇒ `.extend(addedTokens: delta)`
    ///       - delta < 0 ⇒ `.trim(removedTokens: |delta|)` — caller MUST
    ///         verify cache-type trim capability ; if unsupported, treat as
    ///         `.diverged`. No `MAX_TRIM_TOKENS` cap exists in the legacy
    ///         region : the cap is implicit in the cache type capability
    ///         (PVM:1224 `canTrimPromptCache(existing)`).
    ///
    /// `promptTokens` is currently unused by the pure decision but is kept
    /// in the signature : future diagnostics + the empty-input guard rely on
    /// the caller knowing the full prompt size alongside `iteratorInputTokens`.
    func decideExtendTrimInvalidate(
        invariance: InvariancePrefix,
        userTailTokenCount: Int,
        promptTokens: Int
    ) -> KVDecision {
        _ = promptTokens // diagnostic seam, see doc-comment
        if KVCacheBypassFlag.enabled { return .bypass }
        guard kvCacheHolder.caches != nil else { return .cold }
        guard kvCacheHolder.fingerprint == invariance.fingerprint else {
            return .fingerprintChanged
        }
        let prior = kvCacheHolder.beforeCursorTokens
        let delta = userTailTokenCount - prior
        if delta == 0 { return .identical }
        if delta > 0 { return .extend(addedTokens: delta) }
        return .trim(removedTokens: -delta)
    }
}
