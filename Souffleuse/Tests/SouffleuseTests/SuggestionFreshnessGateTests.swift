import Testing
@testable import Souffleuse

/// Render-freshness regression — the "Bonjour" bug.
///
/// Repro: the user starts an e-mail reply, types "Bonjour," and the ghost at
/// that point is "Bonjour". They keep typing a full sentence; by the time the
/// caret reaches "…Puis-je faire autre chose pou" the displayed ghost is STILL
/// "Bonjour" — a start-of-message suggestion painted far downstream, nonsense
/// at the new caret. The model itself is innocent: fed the full prefix it
/// returns "r vous aider ?". The leak is the render boundary in
/// `SouffleuseAppDelegate.tick()`, which painted `predictor.suggestion`
/// whenever it was non-empty — even when that suggestion was generated for an
/// earlier prefix and a fresh prediction was still pending.
///
/// `PredictorViewModel.predictedForPrefix` stamps every suggestion with the
/// prefix it was made for, and
/// `SouffleuseAppDelegate.shouldRenderSuggestion(suggestion:predictedForPrefix:currentPrefix:)`
/// is the pure decision the boundary uses: paint only when the stamp matches
/// the live prefix. These tests pin that boundary; the overlay side effects
/// (NSPanel show/hide) are verified by build + manual GUI typing.
@MainActor
@Suite("Suggestion render-freshness gate")
struct SuggestionFreshnessGateTests {

    /// Stamp matches the live prefix → paint.
    @Test("fresh suggestion (stamp == prefix) → render")
    func rendersWhenStampMatchesPrefix() {
        #expect(SouffleuseAppDelegate.shouldRenderSuggestion(
            suggestion: "r vous aider ?",
            predictedForPrefix: "Bonjour,\n\nJe vous en prie. Puis-je faire autre chose pou",
            currentPrefix: "Bonjour,\n\nJe vous en prie. Puis-je faire autre chose pou"
        ) == true)
    }

    /// The exact repro: a "Bonjour" ghost stamped for the start-of-message
    /// prefix must NOT paint once the caret has moved far downstream.
    @Test("stale ghost (stamp != prefix) → do not render")
    func doesNotRenderStaleDownstreamGhost() {
        #expect(SouffleuseAppDelegate.shouldRenderSuggestion(
            suggestion: "Bonjour",
            predictedForPrefix: "Bonjour,",
            currentPrefix: "Bonjour,\n\nJe vous en prie. Puis-je faire autre chose pou"
        ) == false)
    }

    /// Empty suggestion never paints, even if the (empty) stamp equals an empty
    /// prefix — nothing to show.
    @Test("empty suggestion → do not render")
    func doesNotRenderEmptySuggestion() {
        #expect(SouffleuseAppDelegate.shouldRenderSuggestion(
            suggestion: "",
            predictedForPrefix: "",
            currentPrefix: ""
        ) == false)
    }

    /// One extra typed character past the stamp = a different prefix → withhold
    /// until the re-prediction lands. (Forward-typing that MATCHES the ghost is
    /// handled earlier by live-consume; this gate is the "not consuming" path.)
    @Test("prefix grew by one char past stamp → withhold")
    func withholdsWhenPrefixGrewPastStamp() {
        #expect(SouffleuseAppDelegate.shouldRenderSuggestion(
            suggestion: " allez-vous ?",
            predictedForPrefix: "Bonjour, comment",
            currentPrefix: "Bonjour, comment "
        ) == false)
    }
}
