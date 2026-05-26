import Foundation

public struct NgramEntry: Sendable {
    public var next: UInt32
    public var count: UInt32
    public init(next: UInt32, count: UInt32) { self.next = next; self.count = count }
}

/// Synchronously-readable view over an `NgramModel`'s count tables. Used by
/// the MLX logit processor which can't await an actor on the sampler thread.
public struct NgramSnapshot: Sendable {
    public let bigramRowEntries: [UInt32: [NgramEntry]]
    public let bigramRowTotal: [UInt32: UInt32]
    public let trigramRowEntries: [UInt64: [NgramEntry]]
    public let trigramRowTotal: [UInt64: UInt32]
    public let laplace: Float

    public var isEmpty: Bool {
        bigramRowTotal.isEmpty && trigramRowTotal.isEmpty
    }

    public init(
        bigramRowEntries: [UInt32: [NgramEntry]],
        bigramRowTotal: [UInt32: UInt32],
        trigramRowEntries: [UInt64: [NgramEntry]],
        trigramRowTotal: [UInt64: UInt32],
        laplace: Float
    ) {
        self.bigramRowEntries = bigramRowEntries
        self.bigramRowTotal = bigramRowTotal
        self.trigramRowEntries = trigramRowEntries
        self.trigramRowTotal = trigramRowTotal
        self.laplace = laplace
    }

    /// Candidates with their non-negative bonus, given the last 1-2 tokens.
    public func candidates(given context: [Int]) -> [(token: Int, bonus: Float)] {
        var result: [Int: Float] = [:]
        if context.count >= 2 {
            let prevprev = UInt32(truncatingIfNeeded: context[context.count - 2])
            let prev = UInt32(truncatingIfNeeded: context[context.count - 1])
            let rowKey = (UInt64(prevprev) << 32) | UInt64(prev)
            if let denom = trigramRowTotal[rowKey], denom > 0,
               let entries = trigramRowEntries[rowKey]
            {
                for entry in entries {
                    let p = (Float(entry.count) + laplace) / (Float(denom) + laplace)
                    let bonus = logf(1.0 + Float(entry.count)) * p
                    result[Int(entry.next)] = bonus
                }
            }
        }
        if let last = context.last {
            let prev = UInt32(truncatingIfNeeded: last)
            if let denom = bigramRowTotal[prev], denom > 0,
               let entries = bigramRowEntries[prev]
            {
                for entry in entries {
                    let p = (Float(entry.count) + laplace) / (Float(denom) + laplace)
                    let bonus = logf(1.0 + Float(entry.count)) * p * 0.5
                    let nt = Int(entry.next)
                    if let existing = result[nt] {
                        result[nt] = max(existing, bonus)
                    } else {
                        result[nt] = bonus
                    }
                }
            }
        }
        return result.map { (token: $0.key, bonus: $0.value) }
    }
}
