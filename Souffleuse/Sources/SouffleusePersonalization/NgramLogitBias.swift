import Foundation
import MLX
import MLXLMCommon

/// `LogitProcessor` that adds a non-negative bias to logits of tokens that
/// the user has historically accepted following the current context. The
/// snapshot is captured up-front at the start of generation (cheap, COW
/// dictionaries) so we can run synchronously on the sampler thread without
/// crossing the `NgramModel` actor boundary per-token.
public struct NgramLogitBias: LogitProcessor {
    public let snapshot: NgramSnapshot
    public let strength: Float
    public var context: [Int] = []

    public init(snapshot: NgramSnapshot, strength: Float) {
        self.snapshot = snapshot
        self.strength = strength
    }

    public mutating func prompt(_ prompt: MLXArray) {
        let tokens = prompt.asArray(Int.self)
        context = Array(tokens.suffix(2))
    }

    public func process(logits: MLXArray) -> MLXArray {
        if strength == 0 { return logits }
        if snapshot.isEmpty { return logits }
        let cands = snapshot.candidates(given: context)
        if cands.isEmpty { return logits }
        let indices = MLXArray(cands.map { UInt32($0.token) })
        let bonuses = MLXArray(cands.map { Float($0.bonus) * strength })
        let selected = logits[0..., indices]
        logits[0..., indices] = selected + bonuses
        return logits
    }

    public mutating func didSample(token: MLXArray) {
        let t = token.item(Int.self)
        context.append(t)
        if context.count > 2 {
            context.removeFirst(context.count - 2)
        }
    }
}
