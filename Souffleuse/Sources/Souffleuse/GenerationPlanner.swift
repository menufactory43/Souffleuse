import Foundation
import SouffleuseCore
import SouffleuseLog

// MARK: - GenerationPlanner

/// Lifecycle owner for the predict loop. Single responsibility :
///   - bumper le generation counter à chaque `beginGeneration()` / `cancel()`
///   - posséder la `currentTask` (in-flight LLM `Task<Void, Never>`)
///   - exposer un debounce coalescing utility (`scheduleDebounced`) qui
///     centralise les `predictDebounceNanos = 30 ms` historiquement vivant
///     dans `SouffleuseAppDelegate`.
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

    /// The debounce coalescing Task — cancelled & replaced on each `scheduleDebounced`.
    /// Réservé pour la migration AppDelegate → TypingSession (Plan 04-07).
    private var debounceTask: Task<Void, Never>?

    /// 30 ms debounce — extracted from `SouffleuseAppDelegate:130`
    /// (`predictDebounceNanos`). Centralisé ici pour que les call-sites futurs
    /// (TypingSession) puissent référencer la même constante.
    static let predictDebounceNanos: UInt64 = 30 * 1_000_000

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

    /// Debounce a piece of work by `predictDebounceNanos`. Cancels any pending
    /// debounce. Le `work` s'exécute sur le MainActor après la fenêtre.
    ///
    /// Réservé Plan 04-07 (TypingSession) — exposé dès maintenant pour figer
    /// le contrat. Pas de call-site actif dans le PVM (le debounce vit encore
    /// dans `SouffleuseAppDelegate.predictDebounceTask`).
    func scheduleDebounced(_ work: @escaping @Sendable @MainActor () async -> Void) {
        debounceTask?.cancel()
        let nanos = Self.predictDebounceNanos
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            if Task.isCancelled { return }
            guard self != nil else { return }
            await work()
        }
    }
}
