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

    /// Punctuation that closes a word (so the word before it counts as
    /// "complete" for the word-budget stop). Apostrophe / hyphen are
    /// deliberately EXCLUDED — they are intra-word joiners that leave the word
    /// open (a dangling élision "l'" / open compound "peut-").
    private static let wordBoundaryPunct: Set<Character> = [
        ".", ",", ";", ":", "!", "?", "\u{2026}", ")", "]", "}", "\u{00BB}",
    ]

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
    ///
    /// `reachedWordCap` is `true` once the accumulated text holds at least
    /// `maxWords` COMPLETE words (words followed by a separator). The generation
    /// budget is expressed in whole words, not raw tokens (the token cap is only
    /// a generous backstop), so the caller stops on it AT A WORD BOUNDARY — a
    /// trailing in-progress word (notably a dangling élision "l'") is NOT
    /// counted, so decoding continues until that word completes.
    public static func filterChunk(
        accumulated: String,
        userTail: String,
        caretAfterSpace: Bool,
        maxWords: Int
    ) -> (verdict: ChunkVerdict, dropReason: DropReason?, sentenceComplete: Bool, reachedWordCap: Bool) {
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
        // Word-budget stop signal — computed on the PRE-cap text so it sees the
        // separator that closes the maxWords-th word (the display cap below
        // would hide it). A word is complete when followed by a separator:
        // either the line ends on a boundary char, or there are more words
        // after it. The trailing run with no following separator is in-progress
        // and never counted, so a dangling "l'" never trips the cap.
        let endsOnBoundary = oneLine.last.map {
            $0.isWhitespace || Self.wordBoundaryPunct.contains($0)
        } ?? false
        let completeWords = endsOnBoundary ? words.count : max(0, words.count - 1)
        let reachedWordCap = completeWords >= maxWords
        if words.count > maxWords {
            // `split` discards the leading empty subsequence, so re-joining the
            // capped words drops a single LEADING space — the same next-word
            // separator the sentence-terminator cut above takes care to keep
            // ("…les balances" → " négatives dans votre …" must render
            // "balances négatives …", not "balancesnégatives …"). Restore it.
            // Guarded so it never double-spaces (no-op when the space already
            // survived) and is inert mid-word ("Bonj" → "our" has no leading
            // space) and after a space (caretAfterSpace stripped it upstream).
            let hadLeadingSpace = oneLine.first == " "
            oneLine = words.prefix(maxWords).joined(separator: " ")
            if hadLeadingSpace, oneLine.first != " ", !oneLine.isEmpty {
                oneLine = " " + oneLine
            }
        }

        if OutputFilter.ghostIsRepeatingPrefix(oneLine, prefix: userTail) {
            return (.reset, nil, false, false)
        }
        // Sentence-start echo: at a sentence boundary the pt base model often
        // "continues" by restating the sentence it just finished ("…lien ? " →
        // "Vous avez"). stripPrefixOverlap / ghostIsRepeatingPrefix only catch
        // repetition adjacent to the caret, not a jump back to the opening.
        if OutputFilter.ghostEchoesRecentSentenceStart(oneLine, prefix: userTail) {
            return (.reset, nil, false, false)
        }

        // Drop bare enumerators / lone numbers ("1", "1.", "1er") that the
        // instruct model emits when it starts a numbered list in a thin or
        // list-like context. Better to show nothing than a "1" ghost. Keep
        // generating — a later token may yield a real continuation.
        if OutputFilter.isDegenerateGhost(oneLine) {
            return (.dropKeepGenerating, .degenerate, false, false)
        }

        // Instruction-echo safety net : in degenerate cases the instruct 1B
        // restates the prompt framing ("Voici le texte à continuer :", …)
        // instead of continuing the user. The first-line + sentence
        // truncation above already cut most of it, but a leaked echo is
        // meta-text, never a real completion → drop and keep generating.
        if OutputFilter.echoesInstruction(oneLine) {
            return (.dropKeepGenerating, .instructionEcho, false, false)
        }

        // Dangling élision / open-compound trim (safety net). A trailing word
        // ending in an intra-word joiner ('/'/-) is intrinsically incomplete —
        // "l'", "d'", "qu'", "aujourd'", "peut-" always demand a continuation.
        // Frozen on screen it reads as a bug ("l'"). Strip it; if nothing
        // complete remains, drop and keep generating so the noun ("l'arbre")
        // can still arrive. The bigger token budget means this rarely fires —
        // it only catches the residual EOG / token-ban-fallback cases.
        let deElided = Self.stripTrailingDanglingElision(oneLine)
        if deElided != oneLine {
            if deElided.trimmingCharacters(in: .whitespaces).isEmpty {
                return (.dropKeepGenerating, .degenerate, false, false)
            }
            oneLine = deElided
        }

        return (.emit(oneLine), nil, sentenceComplete, reachedWordCap)
    }

    /// Strips a trailing word that ends in an intra-word joiner (`'` / `’` /
    /// `-`) — a dangling élision or open compound ("l'", "d'", "qu'",
    /// "aujourd'", "peut-"). Such a word is intrinsically incomplete (it always
    /// demands a continuation), so a settled ghost must never end on it.
    /// Repeats for back-to-back joiners ("va l' d'" → "va") and preserves a
    /// single leading separator space. Returns the input unchanged when the
    /// trailing word is complete or the line does not end on a word char.
    static func stripTrailingDanglingElision(_ s: String) -> String {
        var result = Substring(s)
        while !result.isEmpty {
            // Trailing run of word-characters (letters/digits + joiners).
            var runStart = result.endIndex
            while runStart > result.startIndex {
                let prev = result.index(before: runStart)
                if OutputFilter.isWordChar(result[prev]) { runStart = prev } else { break }
            }
            // No trailing word run (ends in space/closing punct) → nothing dangling.
            guard runStart < result.endIndex else { break }
            let last = result[result.index(before: result.endIndex)]
            guard last == "'" || last == "\u{2019}" || last == "-" else { break }
            // Drop the run plus a single separating space before it.
            var cut = runStart
            if cut > result.startIndex, result[result.index(before: cut)] == " " {
                cut = result.index(before: cut)
            }
            result = result[result.startIndex..<cut]
        }
        return String(result)
    }
}
