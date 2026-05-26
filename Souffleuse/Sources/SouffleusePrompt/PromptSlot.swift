import Foundation

/// Named slot in the assembled prompt. Slot identity is fixed at Phase 1 to
/// what's active today + reserved Phase 2/3 names so the builder's API doesn't
/// shift between phases. Active in Phase 2: system, customInstructions,
/// contextPrefix, previousUserInputs, beforeCursor. Reserved for later phases
/// (declared but never filled at runtime): afterCursor, fieldContext,
/// clipboardContext, screenContext.
public enum PromptSlot: String, Sendable, CaseIterable, Hashable {
    // ── Active in Phase 2 ────────────────────────────────────
    case system
    case customInstructions
    case contextPrefix
    case previousUserInputs
    case beforeCursor

    // ── Reserved for Phase 3 (declared, never filled at Phase 1) ────
    case afterCursor
    case fieldContext
    case clipboardContext
    case screenContext
}
