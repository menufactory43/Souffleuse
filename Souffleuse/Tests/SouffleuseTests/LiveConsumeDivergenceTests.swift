import Testing
@testable import Souffleuse

/// Divergence-clear regression — the "applielle" bug.
///
/// Repro: the ghost "elle" was generated for an earlier prefix. The user keeps
/// typing and the typed characters DIVERGE from the ghost (they don't match its
/// start). Before the fix, the divergence fall-through paths in
/// `SouffleuseAppDelegate.tick()` reset their partial state but never hid the
/// on-screen ghost, so the stale "elle" lingered (rendering "applielle") while
/// the re-prediction ran — and if that re-prediction was gated/empty, it never
/// disappeared.
///
/// `SouffleuseAppDelegate.isLiveConsumeMatch(ghost:typedSince:)` is the pure
/// decision the three divergence paths share: `true` = smooth live-consume
/// (keep shrinking the ghost), `false` = divergence (hide stale ghost + re-
/// predict). These tests pin that boundary; the AppDelegate's overlay side
/// effects (`clearStaleGhostOnDivergence`) are not unit-testable in isolation
/// because they touch the live `NSPanel` overlay and the MLX predictor, so the
/// decision is extracted and tested here while the side effect is verified by
/// build + manual GUI typing.
@MainActor
@Suite("Live-consume vs divergence decision")
struct LiveConsumeDivergenceTests {

    /// Typed chars are a case-insensitive prefix of the ghost → consume.
    @Test("typed prefix of ghost → match (consume)")
    func matchesWhenTypedIsPrefix() {
        #expect(SouffleuseAppDelegate.isLiveConsumeMatch(ghost: "elle continue", typedSince: "elle") == true)
    }

    /// Typed chars diverge from the ghost start → divergence (clear stale ghost).
    @Test("typed diverges from ghost → divergence (clear)")
    func divergesWhenTypedMismatches() {
        // Ghost "elle" lingering; user typed "appli" — no shared prefix.
        #expect(SouffleuseAppDelegate.isLiveConsumeMatch(ghost: "elle", typedSince: "appli") == false)
    }

    /// Single divergent character is enough to break the consume.
    @Test("one divergent char → divergence")
    func divergesOnSingleChar() {
        #expect(SouffleuseAppDelegate.isLiveConsumeMatch(ghost: "elle", typedSince: "x") == false)
    }

    /// Case-insensitive: typed "ELLE" still consumes ghost "elle…" (AX writes
    /// the user's verbatim casing; only matching ignores case).
    @Test("case-insensitive match")
    func matchesCaseInsensitively() {
        #expect(SouffleuseAppDelegate.isLiveConsumeMatch(ghost: "elle continue", typedSince: "ELLE") == true)
    }

    /// Empty typedSince is a degenerate consume — never a spurious divergence.
    @Test("empty typed → not a divergence")
    func emptyTypedIsMatch() {
        #expect(SouffleuseAppDelegate.isLiveConsumeMatch(ghost: "elle", typedSince: "") == true)
    }

    /// Typing past the end of the ghost (longer than ghost) → divergence.
    @Test("typed longer than ghost → divergence")
    func divergesWhenTypedExceedsGhost() {
        #expect(SouffleuseAppDelegate.isLiveConsumeMatch(ghost: "el", typedSince: "elle") == false)
    }

    // MARK: - Stale mid-word completion guard (the "envies de" bug)

    /// The exact repro: ghost "es de manger" was generated at "J'ai envi"
    /// (mid-word). It completes the word ("envies") AND continues (" de
    /// manger"). It is a stale word-completion guess — must NOT be live-consumed
    /// (re-predict on the fuller word instead).
    @Test("mid-word completion that continues past the word → stale")
    func staleWhenCompletionContinuesPastWord() {
        #expect(SouffleuseAppDelegate.isStaleMidWordCompletion(basePrefix: "J'ai envi", ghost: "es de manger") == true)
    }

    /// A PURE word completion with nothing after it ("Bonj" → "our") just
    /// finishes the obvious word — safe to live-consume, NOT stale.
    @Test("pure word completion (nothing after) → not stale")
    func notStaleForPureWordCompletion() {
        #expect(SouffleuseAppDelegate.isStaleMidWordCompletion(basePrefix: "Bonj", ghost: "our") == false)
    }

    /// A space/punctuation-led next-word ghost ("J'ai envie" → " de manger")
    /// does NOT continue the current word (its first char isn't a word char) —
    /// NOT stale, consume freely.
    @Test("next-word (space-led) ghost → not stale")
    func notStaleForNextWordGhost() {
        #expect(SouffleuseAppDelegate.isStaleMidWordCompletion(basePrefix: "J'ai envie", ghost: " de manger") == false)
    }

    /// When the caret was NOT mid-word (basePrefix ends in a space), the ghost
    /// can't be a mid-word completion regardless of its shape — NOT stale.
    @Test("caret after a space → not stale")
    func notStaleWhenBasePrefixEndsWithSpace() {
        #expect(SouffleuseAppDelegate.isStaleMidWordCompletion(basePrefix: "J'ai ", ghost: "envie de manger") == false)
    }

    /// Empty inputs are degenerate — never stale (defensive).
    @Test("empty inputs → not stale")
    func notStaleForEmptyInputs() {
        #expect(SouffleuseAppDelegate.isStaleMidWordCompletion(basePrefix: "", ghost: "abc") == false)
        #expect(SouffleuseAppDelegate.isStaleMidWordCompletion(basePrefix: "abc", ghost: "") == false)
    }
}
