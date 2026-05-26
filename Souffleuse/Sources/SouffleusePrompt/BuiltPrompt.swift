import Foundation

/// Result of `PromptBuilder.build(...)`. Carries the assembled text + per-slot
/// accounting so the integration site (chat-template path) and replay tool
/// can extract individual slot bodies post-truncation. Equatable for snapshot
/// testing.
public struct BuiltPrompt: Sendable, Equatable {
    /// Final assembled string fed to MLX `container.perform` /
    /// `tokenizer.encode(text:)`.
    public let text: String

    /// Post-truncation slot bodies. Empty-string entries are omitted. Used by
    /// the chat-template path to extract `beforeCursor` as the user message.
    public let slotTexts: [PromptSlot: String]

    /// Token count consumed per slot AFTER eviction. Sum == totalTokens.
    public let slotTokenCounts: [PromptSlot: Int]

    /// Slots whose input was head-truncated (Phase 1: only `.beforeCursor`).
    /// Replay tool surfaces these in REPLAY-RESULTS.md.
    public let truncatedSlots: Set<PromptSlot>

    /// Sum of slotTokenCounts. Should be ≤ budget.global post-eviction.
    public let totalTokens: Int

    public init(
        text: String,
        slotTexts: [PromptSlot: String],
        slotTokenCounts: [PromptSlot: Int],
        truncatedSlots: Set<PromptSlot>,
        totalTokens: Int
    ) {
        self.text = text
        self.slotTexts = slotTexts
        self.slotTokenCounts = slotTokenCounts
        self.truncatedSlots = truncatedSlots
        self.totalTokens = totalTokens
    }

    /// Convenience predicate. True iff at least one slot was head-truncated.
    public var didEvict: Bool { !truncatedSlots.isEmpty }
}
