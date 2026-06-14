import Foundation
import SouffleuseCore
import SouffleuseLog

// MARK: - GenerationPlanner

/// Lifecycle owner for the predict loop. Single responsibility :
///   - bumper le generation counter à chaque `beginGeneration()` / `cancel()`
///   - posséder la `currentTask` (in-flight LLM `Task<Void, Never>`)
///
/// Plan 04-03 extrait la lifecycle hors de `PredictorViewModel` :
///   - PVM ne déclare plus `private var generation: UInt64`
///   - PVM ne déclare plus `private var currentTask: Task<Void, Never>?`
///   - Les guards `self.generation == myGeneration` deviennent
///     `self.planner.isCurrent(myGeneration)`.
///
/// **Pitfall 1 (RESEARCH §Common Pitfalls)** : la token est capturée par
/// VALEUR dans les closures onChunk, donc une fois que `beginGeneration()`
/// retourne un token #N, les chunks "in-flight" de l'ancien token #N-1
/// sont silencieusement droppés par `isCurrent(_:)`. C'est l'invariant
/// cancel-on-keystroke verrouillé par les tests `GenerationPlannerTests`.
@MainActor
final class GenerationPlanner {
    /// Bumped on every beginGeneration() and cancel(). Closures capture the token at
    /// request creation time — stale chunks are silently dropped by `isCurrent(_:)`.
    private(set) var currentGeneration: GenerationToken = GenerationToken(value: 0)

    /// The Task currently driving the LLM generation (or nil if idle).
    /// Plan 04-03 : ownership migré depuis `PredictorViewModel.currentTask`.
    private var currentTask: Task<Void, Never>?

    init() {}

    /// Cancels in-flight Task and bumps generation. Returns the new token to
    /// capture in the new request (in closure form by value — Sendable safe).
    ///
    /// Idempotent vis-à-vis de l'état : appelée 2 fois consécutivement, bump 2
    /// fois ; aucune closure ne peut survivre car la première cancel a déjà
    /// invalidé son token.
    @discardableResult
    func beginGeneration() -> GenerationToken {
        currentTask?.cancel()
        currentTask = nil
        currentGeneration = GenerationToken(value: currentGeneration.value &+ 1)
        return currentGeneration
    }

    /// Variante de `beginGeneration()` qui retourne ÉGALEMENT la Task
    /// précédente (déjà cancelled, déjà nilée chez le Planner) pour que le
    /// caller puisse `await previousTask?.value` et garantir l'ordre des
    /// finalisations cross-stream (pre-existing PVM contract — la nouvelle
    /// Task attend que l'ancienne se termine avant de lancer son corps).
    ///
    /// Préserve verbatim la sémantique de PVM:768-771 pre-04-03 :
    ///     let previousTask = currentTask
    ///     previousTask?.cancel()
    ///     generation &+= 1
    ///     let myGeneration = generation
    func beginGenerationDetachingPrevious() -> (token: GenerationToken, previousTask: Task<Void, Never>?) {
        let previous = currentTask
        previous?.cancel()
        currentTask = nil
        currentGeneration = GenerationToken(value: currentGeneration.value &+ 1)
        return (currentGeneration, previous)
    }

    /// True if `token` is still the active generation. Use in stream chunk
    /// closures to drop stale chunks deterministically.
    func isCurrent(_ token: GenerationToken) -> Bool {
        token == currentGeneration
    }

    /// Sets the current Task — the Task created by the caller for the request
    /// lifecycle. Appelé juste après que le caller a construit son `Task { … }`
    /// pour que le prochain `beginGeneration()` puisse le cancel.
    func setCurrentTask(_ task: Task<Void, Never>) {
        currentTask = task
    }

    /// Cancels the current Task + bumps generation. Idempotent.
    ///
    /// NOTE: NE PAS clear predictCache ici. `cancel()` est appelé depuis
    /// plusieurs paths qui NE SONT PAS des context breaks (live-consume,
    /// Tab accept, typo). Les vrais context breaks appellent
    /// `CompletionCache.clearPredictCache()` explicitement (cf. Plan 04-04).
    /// Préserver verbatim la note de `PredictorViewModel.cancel()`
    /// (PVM:1492-1499 pre-04-03).
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        currentGeneration = GenerationToken(value: currentGeneration.value &+ 1)
    }
}
