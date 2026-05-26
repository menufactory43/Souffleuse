import Foundation

/// Abstraction over a tokenizer that maps strings to token counts.
/// Production: thin wrapper over MLX `Tokenizer.encode(text:).count`
/// (`MLXTokenCounter`, plan 01-03). Tests: deterministic mock (word-count
/// based, plan 01-02) so snapshot assertions don't depend on a loaded MLX
/// model. Pattern mirrors `OCRCaretLocating` (SouffleuseContext).
public protocol TokenCounting: Sendable {
    /// Returns the number of tokens `text` would produce. MUST be deterministic
    /// for a given (tokenizer, text) pair so eviction is reproducible across
    /// builder invocations.
    func countTokens(_ text: String) -> Int

    /// Returns the head-truncated form of `text` whose token count is `≤ budget`,
    /// preferring boundaries (sentence terminator, then whitespace). MUST NOT
    /// cut mid-word — invariant for D-11. Returns "" if budget < 1 or no
    /// boundary fits.
    func truncateHead(_ text: String, toBudget budget: Int) -> String
}
