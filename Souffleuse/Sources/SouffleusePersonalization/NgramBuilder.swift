import Foundation

/// Bridges a `TypingHistoryStore` (text entries) and a `NgramModel`
/// (token-id counts). The tokenizer is injected as a closure so this
/// module stays MLX-free — the Souffleuse executable wires the real
/// tokenizer from `PredictorViewModel`.
public enum NgramBuilder {
    public typealias Tokenize = @Sendable (String) -> [Int]

    /// Rebuilds `model` from every entry currently held by `history`,
    /// using `tokenize` to turn each (contextBefore + accepted) into a
    /// token stream. The model is cleared first, then the tokenizer tag
    /// is set, then entries are replayed in chronological order.
    public static func rebuild(
        model: NgramModel,
        history: TypingHistoryStore,
        tokenizerTag: String,
        tokenize: Tokenize
    ) async {
        await model.clear()
        await model.setTokenizerTag(tokenizerTag)
        let entries = await history.allEntries()
        for entry in entries {
            // Concatenating contextBefore and accepted gives us the boundary
            // between "what preceded" and "what the user picked" — the LLM
            // bias should care about that join.
            let joined: String
            if entry.contextBefore.isEmpty {
                joined = entry.accepted
            } else {
                joined = entry.contextBefore + " " + entry.accepted
            }
            let tokens = tokenize(joined)
            await model.ingest(tokens: tokens)
        }
    }

    /// Streams a single accepted entry into an already-built model. Cheap —
    /// avoids rebuilding from history when the user accepts a new suggestion.
    public static func ingest(
        entry: TypingHistoryEntry,
        into model: NgramModel,
        tokenize: Tokenize
    ) async {
        let joined: String
        if entry.contextBefore.isEmpty {
            joined = entry.accepted
        } else {
            joined = entry.contextBefore + " " + entry.accepted
        }
        let tokens = tokenize(joined)
        await model.ingest(tokens: tokens)
    }
}
