import Testing
import Foundation
@testable import Souffleuse

/// Phase 4 — Classification grid lifecycle invariants (D-09, D-10, Pitfall 5).
///
/// L'invariant central : **1 ghost lifecycle = 1 classification event**.
/// `endLifecycle(reason:)` est l'UNIQUE call-site qui émet les 5 events
/// `ghost_classified_*`. Reset le state après émission ; second call no-op
/// via guard `!currentGhost.isEmpty`.
///
/// L'observabilité est limitée (les logs vont sur disque), donc les invariants
/// se vérifient via le state post-call (`currentGhost == ""`, `shownAt == nil`,
/// `lastReplacedSource == X`).
@MainActor
@Suite("Phase 4 — Classification grid lifecycle (D-09, D-10, Pitfall 5)")
struct ClassificationGridTests {

    static func engine() -> SuggestionPolicyEngine {
        SuggestionPolicyEngine(maxWords: 16)
    }

    static func sampleScore() -> Score {
        Score(sourcePrior: 0.6, prefixFit: 1.0, lengthFit: 1.0)
    }

    // MARK: - Invariant : 1 lifecycle = 1 event (Pitfall 5)

    @Test func applyAndEndAreIdempotentReset() {
        let p = Self.engine()
        p.applyGhost("ghost", source: .llm, score: Self.sampleScore())
        #expect(p.currentGhost == "ghost")
        #expect(p.shownAt != nil)
        p.endLifecycle(reason: .acceptedFull)
        #expect(p.currentGhost == "")
        #expect(p.currentSource == .none)
        #expect(p.shownAt == nil)
        // Second call : no-op (guard !currentGhost.isEmpty fires).
        p.endLifecycle(reason: .acceptedFull)
        #expect(p.currentGhost == "")
    }

    @Test func endLifecycleWithoutApplyIsNoOp() {
        let p = Self.engine()
        // No applyGhost → currentGhost == "" → guard fires.
        p.endLifecycle(reason: .acceptedFull)
        #expect(p.currentGhost == "")
        #expect(p.shownAt == nil)
    }

    // MARK: - Categories de fin de vie (D-09)

    @Test func acceptedFullResetsState() {
        let p = Self.engine()
        p.applyGhost("done", source: .llm, score: Self.sampleScore())
        p.endLifecycle(reason: .acceptedFull)
        #expect(p.currentGhost == "")
        #expect(p.currentSource == .none)
    }

    @Test func acceptedPartialWithChunkCountResetsState() {
        let p = Self.engine()
        p.applyGhost("multi word ghost", source: .llm, score: Self.sampleScore())
        p.endLifecycle(reason: .acceptedPartial(chunks: 2))
        #expect(p.currentGhost == "")
    }

    @Test func dismissedByEscResetsState() {
        let p = Self.engine()
        p.applyGhost("dismissed", source: .llm, score: Self.sampleScore())
        // shownAt set à Date() — visibleMs sera petit, sous uselessMinVisibleMs (200ms).
        p.endLifecycle(reason: .dismissedByEsc)
        #expect(p.currentGhost == "")
        #expect(p.shownAt == nil)
    }

    @Test func typedDivergedResetsState() {
        let p = Self.engine()
        p.applyGhost("predicted", source: .llm, score: Self.sampleScore())
        p.endLifecycle(reason: .typedDiverged)
        #expect(p.currentGhost == "")
    }

    @Test func typedPastWithoutOverlapResetsState() {
        let p = Self.engine()
        p.applyGhost("past it", source: .llm, score: Self.sampleScore())
        p.endLifecycle(reason: .typedPastWithoutOverlap)
        #expect(p.currentGhost == "")
    }

    @Test func replacedByOtherResetsState() {
        let p = Self.engine()
        p.applyGhost("first", source: .llm, score: Self.sampleScore())
        p.endLifecycle(reason: .replacedByOther)
        #expect(p.currentGhost == "")
    }

    @Test func modelSwapIsSilentAndResets() {
        let p = Self.engine()
        p.applyGhost("ghost", source: .llm, score: Self.sampleScore())
        p.endLifecycle(reason: .modelSwap)
        #expect(p.currentGhost == "")  // silent but state still reset
    }

    @Test func focusChangeIsSilentAndResets() {
        let p = Self.engine()
        p.applyGhost("ghost", source: .llm, score: Self.sampleScore())
        p.endLifecycle(reason: .focusChange)
        #expect(p.currentGhost == "")
    }

    @Test func blocklistIsSilentAndResets() {
        let p = Self.engine()
        p.applyGhost("ghost", source: .llm, score: Self.sampleScore())
        p.endLifecycle(reason: .blocklist)
        #expect(p.currentGhost == "")
    }

    @Test func replacedByOtherStableIsSilentAndResets() {
        let p = Self.engine()
        p.applyGhost("ghost", source: .llm, score: Self.sampleScore())
        p.endLifecycle(reason: .replacedByOtherStable)
        #expect(p.currentGhost == "")
    }

    // MARK: - Source tracking pour debug

    @Test func lastReplacedSourceTrackedAcrossApply() {
        let p = Self.engine()
        p.applyGhost("first", source: .history, score: Self.sampleScore())
        #expect(p.currentSource == .history)
        p.applyGhost("second", source: .llm, score: Self.sampleScore())
        #expect(p.currentSource == .llm)
        #expect(p.lastReplacedSource == .history)
    }

    // MARK: - Tuning constants invariants (D-09 windows)

    @Test func uselessMinVisibleMsConstantIsAtLeast200() {
        // Vérifie le contrat D-09 — si quelqu'un baisse le seuil sans
        // toucher RESEARCH, ce test échoue.
        #expect(SuggestionPolicy.Tuning.uselessMinVisibleMs >= 200)
    }

    @Test func badMaxDivergeMsConstantIsAtMost500() {
        #expect(SuggestionPolicy.Tuning.badMaxDivergeMs <= 500)
    }

    @Test func parasiteWindowConstantIsSubSecond() {
        #expect(SuggestionPolicy.Tuning.parasiteWindow < 1.0)
        #expect(SuggestionPolicy.Tuning.parasiteWindow > 0.0)
    }
}
