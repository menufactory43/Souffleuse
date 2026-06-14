import Testing
import Foundation
import SouffleuseCore
@testable import Souffleuse

/// Plan 04-03 — verrouille les invariants de `GenerationPlanner` :
///   - counter monotone (chaque beginGeneration() bump strictement)
///   - GenerationToken Equatable + Sendable
///   - cancel-on-keystroke : la Task in-flight est cancellée + le token devient stale
///   - cancel() idempotent (le state reste cohérent après N appels)
///
/// Pitfall 1 (RESEARCH §"Common Pitfalls") : la token est capturée par VALEUR
/// dans les closures onChunk, donc une fois `beginGeneration` rappelée le token
/// précédent ne matche plus `isCurrent(_:)` — les chunks stale sont droppés.
@MainActor
@Suite("Phase 4 — GenerationPlanner lifecycle")
struct GenerationPlannerTests {

    // MARK: - Counter monotonicity

    @Test func beginGenerationIncrementsCounter() {
        let p = GenerationPlanner()
        #expect(p.currentGeneration.value == 0)
        let t1 = p.beginGeneration()
        #expect(t1.value == 1)
        let t2 = p.beginGeneration()
        #expect(t2.value == 2)
        let t3 = p.beginGeneration()
        #expect(t3.value == 3)
        #expect(t1 != t2)
        #expect(t2 != t3)
    }

    // MARK: - isCurrent guard

    @Test func isCurrentTrueForLatestToken() {
        let p = GenerationPlanner()
        let t1 = p.beginGeneration()
        #expect(p.isCurrent(t1))
        let t2 = p.beginGeneration()
        #expect(!p.isCurrent(t1))
        #expect(p.isCurrent(t2))
    }

    // MARK: - Cancel-on-keystroke discipline

    @Test func beginGenerationCancelsPriorTask() async {
        let p = GenerationPlanner()
        // Long-running task that would observe Task.isCancelled.
        let task = Task<Void, Never> { @MainActor in
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
        }
        p.setCurrentTask(task)
        let _ = p.beginGeneration()
        // Yield once so the cancellation reaches the task.
        try? await Task.sleep(nanoseconds: 10 * 1_000_000)
        #expect(task.isCancelled)
    }

    @Test func cancelBumpsGeneration() {
        let p = GenerationPlanner()
        let t1 = p.beginGeneration()
        p.cancel()
        // After cancel(), the previous token is no longer current.
        #expect(!p.isCurrent(t1))
        // Counter is strictly greater than the prior token.
        #expect(p.currentGeneration.value > t1.value)
    }

    @Test func cancelIsIdempotent() {
        let p = GenerationPlanner()
        _ = p.beginGeneration()
        let before = p.currentGeneration.value
        p.cancel()
        p.cancel()
        p.cancel()
        // Each cancel bumps by 1 (idempotency = "no crash, state coherent")
        // but the counter strictly increases — that's the contract.
        #expect(p.currentGeneration.value == before + 3)
    }

    // MARK: - Detaching previous task (predict() contract)

    @Test func beginGenerationDetachingPreviousReturnsCancelledPrior() async {
        let p = GenerationPlanner()
        let task = Task<Void, Never> { @MainActor in
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
        }
        p.setCurrentTask(task)
        let (token, previous) = p.beginGenerationDetachingPrevious()
        #expect(token.value == 1)
        #expect(previous != nil)
        // Yield so cancellation propagates.
        try? await Task.sleep(nanoseconds: 10 * 1_000_000)
        #expect(previous?.isCancelled == true)
    }

    @Test func beginGenerationDetachingPreviousNilWhenIdle() {
        let p = GenerationPlanner()
        let (_, previous) = p.beginGenerationDetachingPrevious()
        #expect(previous == nil)
    }

    // MARK: - Token type properties

    @Test func tokenEquatable() {
        let a = GenerationToken(value: 7)
        let b = GenerationToken(value: 7)
        let c = GenerationToken(value: 8)
        #expect(a == b)
        #expect(a != c)
    }

    @Test func tokenIsSendable() {
        // Compile-time test : si ce code compile en @MainActor @Test avec
        // le closure marqué @Sendable, GenerationToken IS Sendable.
        let token = GenerationToken(value: 42)
        Task { @Sendable in
            let _ = token
        }
    }

}
