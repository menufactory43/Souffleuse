import Foundation

/// Bounded FIFO cache of `countTokens(_:)` results. Shared by
/// `MemoizingTokenCounter` instances so the cache survives across
/// `PromptBuilder.build()` invocations (each predict creates a fresh
/// `MLXTokenCounter` per R2 RESEARCH §11 — only the cache persists).
///
/// FIFO eviction is enough for this workload: a typing session cycles through
/// ~7 slots, of which `system`, `customInstructions`, `contextPrefix`, and
/// `fieldContext` are byte-identical across consecutive keystrokes. The hot
/// set fits comfortably in `cap` entries; on cold start or app switch the
/// oldest entries roll out naturally. True LRU adds bookkeeping cost without
/// changing the steady-state hit rate.
///
/// `@unchecked Sendable` mirrors `TypoDetector` and `LogWriter`: serialised
/// through an internal `NSLock`. The lock is held only across hash-map
/// operations (microseconds), never across the inner tokenizer call.
public final class TokenCountCache: @unchecked Sendable {
    private let cap: Int
    private let lock = NSLock()
    private var cache: [String: Int] = [:]
    private var order: [String] = []

    public init(cap: Int = 64) {
        self.cap = max(1, cap)
    }

    public func get(_ key: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    public func put(_ key: String, _ value: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard cache[key] == nil else { return }
        if cache.count >= cap, let evicted = order.first {
            cache.removeValue(forKey: evicted)
            order.removeFirst()
        }
        cache[key] = value
        order.append(key)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        order.removeAll()
    }

    /// Test-only introspection. Production callers must not depend on the
    /// hit/miss counters — they're for benchmarks and reasoning.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }
}

/// `TokenCounting` decorator that consults a `TokenCountCache` before
/// delegating to its `inner` counter. Designed to wrap `MLXTokenCounter`
/// at the predict site so that consecutive `PromptBuilder.build()` calls
/// reuse token counts for byte-identical slot inputs.
///
/// Why a separate cache holder (`TokenCountCache`) instead of an inline
/// dictionary: `MLXTokenCounter` must be re-instantiated each predict (R2:
/// the MLX tokenizer reference is captured inside the actor-isolated
/// `container.perform` closure). The wrapper is therefore short-lived;
/// only the cache is persistent across predicts.
///
/// `truncateHead(_:toBudget:)` is NOT memoized — it depends on `budget`
/// (doubles the key) and almost never fires in steady-state typing (the
/// `beforeCursor` slot squeezing path). Delegating directly to `inner`
/// keeps the surface honest.
public struct MemoizingTokenCounter: TokenCounting {
    public let inner: TokenCounting
    public let cache: TokenCountCache

    public init(inner: TokenCounting, cache: TokenCountCache) {
        self.inner = inner
        self.cache = cache
    }

    public func countTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        if let hit = cache.get(text) { return hit }
        let value = inner.countTokens(text)
        cache.put(text, value)
        return value
    }

    public func truncateHead(_ text: String, toBudget budget: Int) -> String {
        inner.truncateHead(text, toBudget: budget)
    }
}
