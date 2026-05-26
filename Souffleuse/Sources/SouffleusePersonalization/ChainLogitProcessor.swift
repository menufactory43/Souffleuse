import Foundation
import MLX
import MLXLMCommon

/// Composes two `LogitProcessor`s. `first.process` runs before `second.process`;
/// `prompt` and `didSample` are forwarded to both in order. Used so we can keep
/// the existing repetition penalty alongside the n-gram personalization bias.
public struct ChainLogitProcessor: LogitProcessor {
    public var first: any LogitProcessor
    public var second: any LogitProcessor

    public init(first: any LogitProcessor, second: any LogitProcessor) {
        self.first = first
        self.second = second
    }

    public mutating func prompt(_ prompt: MLXArray) {
        first.prompt(prompt)
        second.prompt(prompt)
    }

    public func process(logits: MLXArray) -> MLXArray {
        let intermediate = first.process(logits: logits)
        return second.process(logits: intermediate)
    }

    public mutating func didSample(token: MLXArray) {
        first.didSample(token: token)
        second.didSample(token: token)
    }
}
