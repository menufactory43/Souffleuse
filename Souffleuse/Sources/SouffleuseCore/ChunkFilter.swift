import Foundation

// MARK: - ChunkFilter (pure per-token ghost filter pipeline)

/// Verdict returned by `ChunkFilter.filterChunk(...)`.
///
/// - `.emit(line)`  : the computed one-line ghost. The CALLER still applies its
///                    own "emit only when changed" rule (`guard line != lastEmitted`)
///                    and updates `lastEmitted` — see the call-site mapping below.
/// - `.reset`       : the ghost repeats the prefix (`ghostIsRepeatingPrefix`).
///                    Caller logs `ghost_dropped_repeat`, calls `onChunk("")`,
///                    and STOPS this token (return true upstream).
/// - `.dropKeepGenerating` : a degenerate ghost (bare enumerator) OR an
///                    instruction echo. Caller resets `lastEmitted` to "" +
///                    `onChunk("")` ONLY when `lastEmitted` was non-empty,
///                    then keeps generating. The echo case additionally logs
///                    `ghost_dropped_instruction_echo`.
public enum ChunkVerdict: Sendable, Equatable {
    case emit(String)
    case reset
    case dropKeepGenerating
}

/// Pure extraction of the inline filter pipeline inside
/// `ModelRuntime.generateLlama`'s `{ piece in … }` closure (verbatim
/// semantics). Given the cumulative generated text, the user tail, whether the
/// caret sits right after a space, and the word cap, it produces the verdict.
///
/// **Phase 5 (SouffleuseCore extraction)** : the body is a byte-faithful move
/// of the closure logic that computed `oneLine` and branched on
/// `ghostIsRepeatingPrefix` / `isDegenerateGhost` / `echoesInstruction`. The
/// `acc.lastEmitted` bookkeeping and the `onChunk(...)` / `Log.*` side effects
/// STAY in the caller (`generateLlama`) so the observable sequence of emitted
/// strings and log events is identical. SouffleuseReplay reproduces the same
/// caller-side rules.
public enum ChunkFilter {

    /// Distinguishes the two `.dropKeepGenerating` sub-cases so the caller can
    /// reproduce the (only) extra log event for the instruction-echo branch.
    public enum DropReason: Sendable, Equatable {
        case degenerate
        case instructionEcho
    }

    /// Computes the verdict for one accumulated snapshot. See `ChunkVerdict`
    /// for the caller-side contract. `dropReason` is `nil` unless the verdict
    /// is `.dropKeepGenerating`.
    ///
    /// `sentenceComplete` is `true` only when the sentence-terminator truncation
    /// below actually fired — i.e. the one-line ghost was cut at a `. `/`? `/
    /// `! `/`… ` boundary, so there was discarded content AFTER a completed
    /// sentence. The caller uses it to STOP generating (everything past the cut
    /// is thrown away by the display anyway). Clause boundaries (commas) never
    /// set it, so a wanted second clause keeps generating.
    public static func filterChunk(
        accumulated: String,
        userTail: String,
        caretAfterSpace: Bool,
        maxWords: Int
    ) -> (verdict: ChunkVerdict, dropReason: DropReason?, sentenceComplete: Bool) {
        // ── Filter pipeline (verbatim semantics of the generateLlama onChunk body) ──
        let snapshot = OutputFilter.stripPrefixOverlap(accumulated, prefix: userTail)
        // Caret after a space: the model's leading space is redundant (the
        // space is already typed) → drop ALL leading whitespace. Otherwise
        // keep it (next-word continuation marker).
        let stripped = caretAfterSpace
            ? snapshot.drop(while: { $0 == "\n" || $0 == "\r" || $0 == " " || $0 == "\t" })
            : snapshot.drop(while: { $0 == "\n" || $0 == "\r" })
        var oneLine: String
        if let nl = stripped.firstIndex(of: "\n") {
            oneLine = String(stripped[..<nl])
        } else {
            oneLine = String(stripped)
        }
        oneLine = oneLine.replacingOccurrences(
            of: "<[/!?]?[A-Za-z][A-Za-z0-9]{0,15}\\s*[^>]{0,32}>",
            with: "",
            options: .regularExpression
        )
        oneLine = oneLine.replacingOccurrences(of: "**", with: "")
        oneLine = oneLine.replacingOccurrences(of: "__", with: "")
        oneLine = oneLine.replacingOccurrences(of: "`", with: "")
        // Strip U+FFFD replacement chars: when the sampler bans a token,
        // greedy can fall back to a byte-fallback token that decodes mid
        // UTF-8 sequence and renders as "" — never show it.
        oneLine = oneLine.replacingOccurrences(of: "\u{FFFD}", with: "")
        // Set when the sentence-terminator cut below fires (a completed sentence
        // with discarded content after it) — the caller stops generating on it.
        var sentenceComplete = false
        if oneLine.count > 3 {
            // Preserve a single LEADING space: a next-word continuation after
            // a complete word ("…les frais" → " de port. Mais") must keep its
            // leading space so the ghost renders "frais de port." (not
            // "fraisde port."). trimmingCharacters would otherwise eat it.
            let hadLeadingSpace = oneLine.first == " "
            for terminator in [". ", "? ", "! ", "… "] {
                if let r = oneLine.range(of: terminator) {
                    var cut = String(oneLine[..<r.upperBound]).trimmingCharacters(in: .whitespaces)
                    if hadLeadingSpace { cut = " " + cut }
                    oneLine = cut
                    sentenceComplete = true
                    break
                }
            }
        }
        // Punctuation KEPT (Cotypist parity) — no comma truncation. The
        // sentence-terminator cut above + word cap below bound the length.
        let words = oneLine.split(whereSeparator: { $0.isWhitespace })
        if words.count > maxWords {
            oneLine = words.prefix(maxWords).joined(separator: " ")
        }

        if OutputFilter.ghostIsRepeatingPrefix(oneLine, prefix: userTail) {
            return (.reset, nil, false)
        }
        // Sentence-start echo: at a sentence boundary the pt base model often
        // "continues" by restating the sentence it just finished ("…lien ? " →
        // "Vous avez"). stripPrefixOverlap / ghostIsRepeatingPrefix only catch
        // repetition adjacent to the caret, not a jump back to the opening.
        if OutputFilter.ghostEchoesRecentSentenceStart(oneLine, prefix: userTail) {
            return (.reset, nil, false)
        }

        // Drop bare enumerators / lone numbers ("1", "1.", "1er") that the
        // instruct model emits when it starts a numbered list in a thin or
        // list-like context. Better to show nothing than a "1" ghost. Keep
        // generating — a later token may yield a real continuation.
        if OutputFilter.isDegenerateGhost(oneLine) {
            return (.dropKeepGenerating, .degenerate, false)
        }

        // Instruction-echo safety net : in degenerate cases the instruct 1B
        // restates the prompt framing ("Voici le texte à continuer :", …)
        // instead of continuing the user. The first-line + sentence
        // truncation above already cut most of it, but a leaked echo is
        // meta-text, never a real completion → drop and keep generating.
        if OutputFilter.echoesInstruction(oneLine) {
            return (.dropKeepGenerating, .instructionEcho, false)
        }

        return (.emit(oneLine), nil, sentenceComplete)
    }
}
