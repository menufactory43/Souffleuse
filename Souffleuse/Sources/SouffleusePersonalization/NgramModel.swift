import Foundation

/// In-memory bigram + trigram model keyed on tokenizer token IDs. Counts are
/// hashed into a 64-bit key so we don't carry dictionaries-of-dictionaries
/// around. Lookups are O(1). The model is intentionally not persisted: it is
/// rebuilt at app launch by replaying every `TypingHistoryStore` entry through
/// the active tokenizer.
public actor NgramModel {
    /// Identifier of the tokenizer this model is bound to. When the active
    /// model changes (Gemma → Qwen), we discard and rebuild from history.
    public private(set) var tokenizerTag: String?

    /// bigram[(prev, next)] count
    private var bigramCounts: [UInt64: UInt32] = [:]
    /// trigram[(prevprev, prev, next)] count
    private var trigramCounts: [UInt64: UInt32] = [:]
    /// total observed bigrams (for normalisation)
    private var bigramTotal: UInt64 = 0
    private var trigramTotal: UInt64 = 0
    /// per-`prev` denominators
    private var bigramRowTotal: [UInt32: UInt32] = [:]
    /// per-`(prev,prev)` denominators
    private var trigramRowTotal: [UInt64: UInt32] = [:]
    /// Reverse index: `prev` → list of (next, count) for bigrams. Lets the
    /// logit bias enumerate candidate continuations in O(distinct nexts).
    private var bigramRowEntries: [UInt32: [NgramEntry]] = [:]
    /// Reverse index: `(prevprev,prev)` → list of (next, count) for trigrams.
    private var trigramRowEntries: [UInt64: [NgramEntry]] = [:]

    private let laplace: Float = 0.01

    public init(tokenizerTag: String? = nil) {
        self.tokenizerTag = tokenizerTag
    }

    public func setTokenizerTag(_ tag: String) {
        if tokenizerTag != tag {
            tokenizerTag = tag
            clear()
        }
    }

    public func clear() {
        bigramCounts.removeAll(keepingCapacity: true)
        trigramCounts.removeAll(keepingCapacity: true)
        bigramRowTotal.removeAll(keepingCapacity: true)
        trigramRowTotal.removeAll(keepingCapacity: true)
        bigramRowEntries.removeAll(keepingCapacity: true)
        trigramRowEntries.removeAll(keepingCapacity: true)
        bigramTotal = 0
        trigramTotal = 0
    }

    public var isEmpty: Bool { bigramTotal == 0 && trigramTotal == 0 }

    /// Ingests a token stream. Counts every (t-1,t) and (t-2,t-1,t).
    public func ingest(tokens: [Int]) {
        guard tokens.count >= 2 else { return }
        for i in 1..<tokens.count {
            let prev = UInt32(truncatingIfNeeded: tokens[i - 1])
            let next = UInt32(truncatingIfNeeded: tokens[i])
            let key2 = Self.pack2(prev, next)
            let oldBi = bigramCounts[key2] ?? 0
            bigramCounts[key2] = oldBi &+ 1
            bigramRowTotal[prev, default: 0] &+= 1
            bigramTotal &+= 1
            if oldBi == 0 {
                bigramRowEntries[prev, default: []].append(NgramEntry(next: next, count: 1))
            } else {
                if var row = bigramRowEntries[prev] {
                    for idx in 0..<row.count where row[idx].next == next {
                        row[idx].count &+= 1
                        bigramRowEntries[prev] = row
                        break
                    }
                }
            }
            if i >= 2 {
                let prevprev = UInt32(truncatingIfNeeded: tokens[i - 2])
                let key3 = Self.pack3(prevprev, prev, next)
                let rowKey = Self.pack2(prevprev, prev)
                let oldTri = trigramCounts[key3] ?? 0
                trigramCounts[key3] = oldTri &+ 1
                trigramRowTotal[rowKey, default: 0] &+= 1
                trigramTotal &+= 1
                if oldTri == 0 {
                    trigramRowEntries[rowKey, default: []].append(NgramEntry(next: next, count: 1))
                } else {
                    if var row = trigramRowEntries[rowKey] {
                        for idx in 0..<row.count where row[idx].next == next {
                            row[idx].count &+= 1
                            trigramRowEntries[rowKey] = row
                            break
                        }
                    }
                }
            }
        }
    }

    /// Returns the candidate next tokens with their bonus given the last 1-2
    /// context tokens. Empty when no n-gram evidence exists. Trigram evidence
    /// is preferred over bigram for the same `next`.
    public func candidates(given context: [Int]) -> [(token: Int, bonus: Float)] {
        var result: [Int: Float] = [:]
        if context.count >= 2 {
            let prevprev = UInt32(truncatingIfNeeded: context[context.count - 2])
            let prev = UInt32(truncatingIfNeeded: context[context.count - 1])
            let rowKey = Self.pack2(prevprev, prev)
            if let denom = trigramRowTotal[rowKey], denom > 0,
               let entries = trigramRowEntries[rowKey]
            {
                for entry in entries {
                    result[Int(entry.next)] = bonusFrom(num: entry.count, denom: denom)
                }
            }
        }
        if let last = context.last {
            let prev = UInt32(truncatingIfNeeded: last)
            if let denom = bigramRowTotal[prev], denom > 0,
               let entries = bigramRowEntries[prev]
            {
                for entry in entries {
                    let nb = bonusFrom(num: entry.count, denom: denom) * 0.5
                    let nt = Int(entry.next)
                    if let existing = result[nt] {
                        result[nt] = max(existing, nb)
                    } else {
                        result[nt] = nb
                    }
                }
            }
        }
        return result.map { (token: $0.key, bonus: $0.value) }
    }

    /// Non-negative bonus for `nextToken` given the last 1-2 context tokens.
    /// 0 when the n-gram has never been seen (neutral). The value scales with
    /// both the conditional probability of the n-gram and its absolute count,
    /// so frequently-recurring suggestions get a larger boost than one-shot
    /// ones. We never return negative numbers: the bias only *boosts* the
    /// model's existing logits, it never suppresses unseen tokens.
    ///
    /// Trigram evidence wins over bigram when available.
    public func bonus(nextToken: Int, given context: [Int]) -> Float {
        if context.count >= 2 {
            let prevprev = UInt32(truncatingIfNeeded: context[context.count - 2])
            let prev = UInt32(truncatingIfNeeded: context[context.count - 1])
            let next = UInt32(truncatingIfNeeded: nextToken)
            let rowKey = Self.pack2(prevprev, prev)
            if let denom = trigramRowTotal[rowKey], denom > 0 {
                let num = trigramCounts[Self.pack3(prevprev, prev, next)] ?? 0
                if num > 0 {
                    return bonusFrom(num: num, denom: denom)
                }
            }
        }
        if let last = context.last {
            let prev = UInt32(truncatingIfNeeded: last)
            let next = UInt32(truncatingIfNeeded: nextToken)
            if let denom = bigramRowTotal[prev], denom > 0 {
                let num = bigramCounts[Self.pack2(prev, next)] ?? 0
                if num > 0 {
                    return bonusFrom(num: num, denom: denom) * 0.5  // bigram less authoritative than trigram
                }
            }
        }
        return 0
    }

    /// bonus = log(1 + count) × p   — count-aware probability boost.
    @inline(__always)
    private func bonusFrom(num: UInt32, denom: UInt32) -> Float {
        let p = (Float(num) + laplace) / (Float(denom) + laplace)
        return logf(1.0 + Float(num)) * p
    }

    /// Synchronous Sendable snapshot of the count tables — used by the logit
    /// processor which runs on the MLX sampler thread and can't cross actor
    /// boundaries per-token. Cheap thanks to Swift dictionary CoW.
    public func snapshot() -> NgramSnapshot {
        NgramSnapshot(
            bigramRowEntries: bigramRowEntries,
            bigramRowTotal: bigramRowTotal,
            trigramRowEntries: trigramRowEntries,
            trigramRowTotal: trigramRowTotal,
            laplace: laplace
        )
    }

    // MARK: - Packing

    @inline(__always)
    private static func pack2(_ a: UInt32, _ b: UInt32) -> UInt64 {
        (UInt64(a) << 32) | UInt64(b)
    }

    /// Three 21-bit slots packed into UInt64. Vocab caps fit (Qwen ≈ 152k,
    /// Gemma ≈ 256k — both < 2²¹ = 2_097_152). On debug builds we assert.
    @inline(__always)
    private static func pack3(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> UInt64 {
        #if DEBUG
        assert(a < (1 << 21) && b < (1 << 21) && c < (1 << 21), "token id exceeds 21-bit slot")
        #endif
        let mask: UInt64 = (1 << 21) - 1
        return (UInt64(a) & mask) << 42 | (UInt64(b) & mask) << 21 | (UInt64(c) & mask)
    }
}
