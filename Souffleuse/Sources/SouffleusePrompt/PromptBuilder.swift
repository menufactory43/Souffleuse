import Foundation

/// Token-budgeted prompt assembly. Pure value-type. Build is deterministic for
/// a given (counter, budget, inputs) triple.
///
/// Slots in fixed assembly order (head -> tail) — Phase 2 layout per D-14b:
///   1. system               (framing)
///   2. customInstructions
///   3. contextPrefix
///   4. fieldContext         (focused-field metadata: role label, placeholder)
///   5. afterCursor          (text right of the caret, do-not-repeat hint)
///   6. previousUserInputs   (few-shot retrieval)
///   7. beforeCursor         (RIGHT before model continues)
///
/// D-04: each slot is independently truncated to its per-slot budget. No
/// cross-slot stealing. If sum of slot tokens exceeds `budget.global`, slots
/// are dropped/truncated in `evictionPriority` order until total fits.
///
/// D-11: `beforeCursor` uses head-truncation (preserves the tail = closest to
/// caret = most signal-rich) via `counter.truncateHead`. Other slots that
/// overflow are dropped from the back via tail-truncation at word boundary
/// (rare in practice — system/customInstructions/contextPrefix are short).
///
/// Eviction order (Phase 2): drop replaceables first (previousUserInputs,
/// customInstructions), then contextPrefix (Phase 1 verdict: low signal),
/// then squeeze high-signal slots (afterCursor before fieldContext —
/// fieldContext is more structurally diagnostic). beforeCursor is
/// head-truncate (squeeze-only, never dropped). system is last-resort.
public struct PromptBuilder: Sendable {
    public let counter: TokenCounting
    public let budget: PromptBudget

    /// Phase 2 eviction priority per 02-CONTEXT.md "Claude's Discretion" +
    /// principle stated in 02-PATTERNS.md. Drop replaceables first
    /// (previousUserInputs, customInstructions), then contextPrefix (Phase 1
    /// verdict: low signal), then squeeze high-signal slots (afterCursor
    /// before fieldContext — fieldContext is more structurally diagnostic).
    /// beforeCursor is head-truncate (squeeze-only, never dropped). system
    /// is last-resort.
    public static let evictionPriority: [PromptSlot] = [
        .previousUserInputs,
        .customInstructions,
        .contextPrefix,
        .afterCursor,
        .fieldContext,
        .beforeCursor,
        .system,
    ]

    public init(counter: TokenCounting, budget: PromptBudget = .phase1Default) {
        self.counter = counter
        self.budget = budget
    }

    /// Primary entry point. Each parameter is the raw slot text (may be empty).
    /// Returns BuiltPrompt with `text`, `slotTexts`, `slotTokenCounts`,
    /// `truncatedSlots`, `totalTokens`.
    public func build(
        system: String,
        customInstructions: String,
        contextPrefix: String,
        fieldContext: String = "",
        afterCursor: String = "",
        previousUserInputs: String,
        beforeCursor: String
    ) -> BuiltPrompt {
        // 1. Map of (slot -> raw input)
        let inputs: [(PromptSlot, String)] = [
            (.system, system),
            (.customInstructions, customInstructions),
            (.contextPrefix, contextPrefix),
            (.fieldContext, fieldContext),
            (.afterCursor, afterCursor),
            (.previousUserInputs, previousUserInputs),
            (.beforeCursor, beforeCursor),
        ]

        // 2. Per-slot truncation (independent — D-04)
        var truncated: Set<PromptSlot> = []
        var slotTexts: [PromptSlot: String] = [:]
        var slotCounts: [PromptSlot: Int] = [:]

        for (slot, raw) in inputs {
            guard !raw.isEmpty else { continue }
            let perSlotBudget = budget.perSlot[slot] ?? Int.max
            let tokenCount = counter.countTokens(raw)
            if tokenCount <= perSlotBudget {
                slotTexts[slot] = raw
                slotCounts[slot] = tokenCount
            } else {
                let cut: String
                if slot == .beforeCursor {
                    // D-11: head-truncate (preserve tail)
                    cut = counter.truncateHead(raw, toBudget: perSlotBudget)
                } else {
                    // Tail-truncate at word boundary for non-beforeCursor slots
                    cut = Self.tailTruncateToWordBoundary(raw, budget: perSlotBudget)
                }
                if !cut.isEmpty {
                    slotTexts[slot] = cut
                    slotCounts[slot] = counter.countTokens(cut)
                    truncated.insert(slot)
                }
            }
        }

        // 3. Global cap enforcement via eviction priority
        var total = slotCounts.values.reduce(0, +)
        for victim in Self.evictionPriority where total > budget.global {
            guard let victimCount = slotCounts[victim], victimCount > 0 else { continue }
            // Drop this slot entirely (Phase 1: simple drop, not partial squeeze;
            // beforeCursor is special-cased: further head-truncate instead of drop).
            if victim == .beforeCursor, let txt = slotTexts[victim] {
                // Squeeze beforeCursor: budget = current - (total - global)
                let remaining = max(0, victimCount - (total - budget.global))
                let shrunk = counter.truncateHead(txt, toBudget: remaining)
                let newCount = shrunk.isEmpty ? 0 : counter.countTokens(shrunk)
                if shrunk.isEmpty {
                    slotTexts.removeValue(forKey: victim)
                    slotCounts.removeValue(forKey: victim)
                } else {
                    slotTexts[victim] = shrunk
                    slotCounts[victim] = newCount
                }
                truncated.insert(victim)
                total = total - victimCount + newCount
            } else {
                slotTexts.removeValue(forKey: victim)
                slotCounts.removeValue(forKey: victim)
                truncated.insert(victim)
                total -= victimCount
            }
        }

        // 4. Assemble in fixed order, joining non-empty slots with "\n\n" (D-14b)
        let assemblyOrder: [PromptSlot] = [
            .system,
            .customInstructions,
            .contextPrefix,
            .fieldContext,
            .afterCursor,
            .previousUserInputs,
            .beforeCursor,
        ]
        var bits: [String] = []
        for slot in assemblyOrder {
            if let text = slotTexts[slot], !text.isEmpty {
                bits.append(text)
            }
        }
        let assembled = bits.joined(separator: "\n\n")

        return BuiltPrompt(
            text: assembled,
            slotTexts: slotTexts,
            slotTokenCounts: slotCounts,
            truncatedSlots: truncated,
            totalTokens: total
        )
    }

    // Tail-truncate at the last whitespace boundary that fits budget tokens.
    // Pure helper, exposed `internal` for tests (@testable import).
    static func tailTruncateToWordBoundary(_ text: String, budget: Int) -> String {
        // Quick path: split words, accumulate from head until budget exceeded.
        // Approximate; the counter is the source of truth, so we re-measure.
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty, budget >= 1 else { return "" }
        var kept: [String] = []
        for w in words {
            kept.append(w)
            // No counter here to avoid recursion; assume word count ~= token
            // count proxy. The caller re-measures and may iterate. Phase 1
            // accepts this approximation because non-beforeCursor slots
            // rarely overflow.
            if kept.count >= budget { break }
        }
        return kept.joined(separator: " ")
    }

    /// Static FR-label table for AX role / subrole. Non-exhaustive by design
    /// (D-15d) — extend at each app tested. Sendable by construction (literal
    /// dictionary of String:String).
    private static let roleLabelsFR: [String: String] = [
        "AXSearchField": "recherche",
        "AXTextArea": "zone de texte",
        "AXTextField": "champ texte",
        "AXComboBox": "menu déroulant",
    ]

    /// Resolves a FR label for the focused AX role / subrole. Prefers subrole
    /// (more specific: `AXSearchField` > `AXTextField`). Returns nil if neither
    /// is mapped — the caller (PredictorViewModel slot body) skips the
    /// "Champ : X." line in that case (D-15c).
    ///
    /// Public so the symbol is reachable from PredictorViewModel (which lives
    /// in a separate SPM target — `Souffleuse`) and from tests.
    public static func roleLabelFR(role: String?, subrole: String?) -> String? {
        if let subrole, let label = roleLabelsFR[subrole] { return label }
        if let role, let label = roleLabelsFR[role] { return label }
        return nil
    }
}
