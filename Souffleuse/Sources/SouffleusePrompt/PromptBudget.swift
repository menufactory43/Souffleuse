import Foundation

/// Per-slot token allocation + global cap. Indicative Phase 1 defaults — final
/// numbers tuned at SouffleuseBench reading (plan 01-05).
///
/// D-04: allocation is per-slot independent (no cross-slot stealing). The
/// global cap is a safety net; if every per-slot budget fills simultaneously
/// their sum (550) exceeds global (512), and the builder squeezes per the
/// fixed priority (see PromptBuilder.swift `evictionPriority`).
public struct PromptBudget: Sendable, Equatable {
    public let global: Int
    public let perSlot: [PromptSlot: Int]

    public init(global: Int, perSlot: [PromptSlot: Int]) {
        self.global = global
        self.perSlot = perSlot
    }

    /// Phase 1 default per RESEARCH §4. system=80 + customInstructions=40
    /// + contextPrefix=150 + previousUserInputs=80 + beforeCursor=200 = 550.
    /// Global cap 512 enforces "if all slots fill, lowest-priority slots get
    /// squeezed".
    public static let phase1Default = PromptBudget(
        global: 512,
        perSlot: [
            .system: 80,
            .customInstructions: 40,
            .contextPrefix: 150,
            .previousUserInputs: 80,
            .beforeCursor: 200,
        ]
    )

    /// Phase 2 default per D-14d / D-15e / D-16b / Claude's Discretion in
    /// 02-CONTEXT.md. Adds fieldContext=60 and afterCursor=120 to the Phase 1
    /// allocation; previousUserInputs inherits the Phase 1 fewShot budget
    /// (80). Sum perSlot = 80+40+150+60+120+80+200 = 730. Global bumped from
    /// 512 to 1024 so the typical case does not squeeze the structural slots
    /// — gemma-3-1b context = 8192, plenty of headroom. Eviction still fires
    /// when an exceptionally long contextPrefix + previousUserInputs combine
    /// to push the total over 1024.
    public static let phase2Default = PromptBudget(
        global: 1024,
        perSlot: [
            .system: 80,
            .customInstructions: 40,
            .contextPrefix: 150,
            .fieldContext: 60,
            .afterCursor: 120,
            .previousUserInputs: 80,
            .beforeCursor: 200,
        ]
    )
}
