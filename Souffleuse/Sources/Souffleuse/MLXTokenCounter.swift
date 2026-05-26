import Foundation
import MLXLMCommon
import SouffleusePrompt
import Tokenizers

/// Production adapter wrapping an MLX `Tokenizer` reference behind the
/// `TokenCounting` protocol. Constructed inside the `container.perform`
/// closure where `context.tokenizer` is reachable (per R2 in RESEARCH §11:
/// the tokenizer is `Sendable` but capturing it outside the actor-isolated
/// closure is undocumented — fresh allocation per predict avoids the issue).
///
/// Stateless `struct: Sendable` — same precedent as `EnrichedContext` /
/// `AXSnapshot`. Not an `actor` (unlike `OCRCaretLocator`) because tokenizer
/// calls are sync and the struct holds no mutable state.
///
/// TODO Phase 2: dedupe via shared SouffleusePrompt.MLXTokenCounter
/// (see RESEARCH §11 R4) — Phase 1 keeps the adapter local to the app target
/// so SouffleusePrompt remains testable without pulling MLX.
struct MLXTokenCounter: TokenCounting {
    /// Reference to the loaded MLX tokenizer. Held as `any Tokenizer` to match
    /// the `MLXLMCommon` API exposed at `context.tokenizer`.
    let tokenizer: any Tokenizer

    func countTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return tokenizer.encode(text: text).count
    }

    /// Head-truncate `text` to ≤ budget tokens, preferring sentence boundary
    /// then word boundary. D-11 invariant: NEVER cut mid-word. Returns "" if
    /// budget < 1 or no boundary fits (defensive — caller logs a counter-only
    /// warn event).
    ///
    /// Algorithm: split into words (whitespace boundary), then walk from the
    /// head dropping words until the remaining suffix tokenizes to ≤ budget.
    /// Among candidate cut points, prefer those that land RIGHT AFTER a
    /// sentence terminator (`.`, `?`, `!`, `…`). If none fit, fall back to
    /// the smallest word-boundary cut that fits.
    func truncateHead(_ text: String, toBudget budget: Int) -> String {
        guard budget >= 1 else { return "" }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }

        // Quick path: if it already fits, return unchanged.
        let totalTokens = countTokens(trimmed)
        if totalTokens <= budget { return trimmed }

        // Split on whitespace, keep word strings (no leading/trailing spaces).
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return "" }

        // Sentence terminators reused from PredictorViewModel.swift truncation
        // pass (": ", ". ", "? ", "! ", "… "). Per-word last-char check since
        // we lose the trailing space context after split.
        let sentenceEnds: Set<Character> = [".", "?", "!", "…"]

        // Helper: try a specific cutWordIdx, return the suffix string and its
        // token count.
        func tryCut(_ cutWordIdx: Int) -> (text: String, tokens: Int) {
            let suffix = words[cutWordIdx...].joined(separator: " ")
            return (suffix, countTokens(suffix))
        }

        // First pass: walk cutWordIdx from SMALLEST (most retained) to largest.
        // Prefer the smallest cut that lands on a sentence boundary AND fits.
        for cutWordIdx in 1..<words.count {
            // Sentence boundary: the previous word's last char is a terminator.
            let prevWord = words[cutWordIdx - 1]
            guard let last = prevWord.last, sentenceEnds.contains(last) else { continue }
            let (txt, count) = tryCut(cutWordIdx)
            if count <= budget {
                return txt
            }
        }

        // Second pass: fallback to word boundary. Walk smallest-cut first.
        for cutWordIdx in 1..<words.count {
            let (txt, count) = tryCut(cutWordIdx)
            if count <= budget {
                return txt
            }
        }

        // Defensive: even keeping the last word alone doesn't fit (single
        // giant token blob). Per RESEARCH §3 edge case: return "" — caller
        // (PromptBuilder) flags the slot as truncated.
        return ""
    }
}
