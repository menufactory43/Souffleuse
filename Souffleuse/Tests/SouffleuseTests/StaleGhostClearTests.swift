import Testing
import Foundation
import SouffleuseCorpus
import SouffleusePersonalization
import SouffleuseTyping
import SouffleuseCore
@testable import Souffleuse

/// Stale-ghost regression — the "faique" bug.
///
/// Repro : typing "…Je ne sais pas quoi fai" while a previous keystroke had
/// shown the ghost "que". Mid-word at "fai" the instant cascade returns nil
/// (WordCompleter "s" < 3 chars), so no fresh ghost is set. The LLM then runs
/// and `generateLlama` drops EVERY token via the mid-word coherence guard
/// ("fai"+"que" = "faique", a non-word). Because the all-dropped case never
/// fires `onChunk("")` (acc.lastEmitted stays ""), the PVM's onChunk closure
/// never runs and the stale "que" survives on screen.
///
/// The fix : `PredictorViewModel.shouldClearStaleGhost(...)` — on a generation
/// that emitted nothing AND with no valid instant ghost for the current
/// prefix, the displayed ghost is stale and must be cleared. A valid
/// current-prefix instant ghost (non-empty `instantGhost`) is preserved
/// (anti-churn).
@MainActor
@Suite("Stale-ghost clear — faique regression")
struct StaleGhostClearTests {

    // MARK: - Pure decision (PredictorViewModel.shouldClearStaleGhost)

    /// The exact "faique" repro : LLM dropped all tokens (emitted=false), the
    /// current prefix "…fai" produced no instant ghost (instantGhost=""), and a
    /// stale "que" is still displayed → MUST clear.
    @Test("faique repro — all-dropped + no instant ghost + stale displayed → clear")
    func clearsStaleGhostWhenNothingEmitted() {
        #expect(PredictorViewModel.shouldClearStaleGhost(
            emittedGhost: false,
            instantGhost: "",
            displayedSuggestion: "que"
        ) == true)
    }

    /// Anti-churn : the current prefix DID produce a valid instant ghost (L0
    /// word-completion or strong corpus fast-path). Even though the LLM stream
    /// emitted nothing, the valid current-prefix ghost MUST survive.
    @Test("valid instant ghost present → NOT cleared by an empty LLM stream")
    func keepsValidInstantGhostUnderEmptyLLM() {
        #expect(PredictorViewModel.shouldClearStaleGhost(
            emittedGhost: false,
            instantGhost: "rrespondance",  // fresh L0 completion for current prefix
            displayedSuggestion: "rrespondance"
        ) == false)
    }

    /// The generation DID emit a ghost for the current prefix — nothing stale,
    /// never clear (even if instantGhost happens to be empty).
    @Test("generation emitted a ghost → not cleared")
    func keepsEmittedGhost() {
        #expect(PredictorViewModel.shouldClearStaleGhost(
            emittedGhost: true,
            instantGhost: "",
            displayedSuggestion: "que continuer"
        ) == false)
    }

    /// Nothing displayed → nothing to clear (no-op).
    @Test("empty display → no clear")
    func noClearWhenNothingDisplayed() {
        #expect(PredictorViewModel.shouldClearStaleGhost(
            emittedGhost: false,
            instantGhost: "",
            displayedSuggestion: ""
        ) == false)
    }

    // MARK: - Engine-level invariant (anti-churn boundary)

    /// A strong corpus `.history` fast-path is high-prior — once applied, an
    /// empty/under-bar LLM chunk cannot replace it. This documents WHY the
    /// `instantGhost.isEmpty` guard in `shouldClearStaleGhost` is the right
    /// staleness signal : when a corpus ghost is live, `instantGhost` is
    /// non-empty for the current prefix, so the stale-clear never triggers.
    @Test("corpus fast-path ghost stays under an under-bar LLM chunk")
    func corpusFastPathSurvivesWeakLLMChunk() {
        let engine = SuggestionPolicyEngine(maxWords: 16)
        let userTail = "Bien cordialement, "
        let snapshot = [
            TypingHistoryEntry(
                timestamp: Date(),
                contextBefore: "",
                accepted: "Bien cordialement, Jean Dupont",
                bundleID: nil,
                source: .prose
            ),
        ]
        let route = engine.routeInstant(
            userTail: userTail,
            historySnapshot: snapshot,
            wordCompleter: WordCompleter()
        )
        #expect(route != nil)
        if let route { engine.applyGhost(route.text, source: route.source, score: route.score) }
        #expect(!engine.currentGhost.isEmpty)

        // A weak LLM chunk arrives — it should NOT replace the corpus ghost
        // (replacement bar from a [0,1] score can't beat the strong prior).
        let update = engine.onLLMChunk("autre chose", userTail: userTail)
        #expect(update == nil)
        #expect(!engine.currentGhost.isEmpty)
    }
}
