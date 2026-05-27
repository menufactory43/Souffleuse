import Foundation

// MARK: - GenerationToken

/// Opaque generation identity. Bumped on every predict and cancel. The post-stream
/// commit captures the token at request creation and drops chunks if the token
/// is no longer current (Pitfall 1 in RESEARCH §"Common Pitfalls").
///
/// Value-type sur `UInt64` — Sendable de fait, Equatable structurel. Le PVM
/// avant Phase-4 utilisait directement un `UInt64` capturé dans les closures
/// onChunk ; les comparaisons `self.generation == myGeneration` étaient
/// faites par valeur. Token unifie ce contrat : `isCurrent(_:)` remplace la
/// comparaison directe pour que la propriété `currentGeneration` reste
/// `private(set)` chez le Planner.
///
/// **Phase 5 (SouffleuseCore extraction)** : déplacé ici depuis
/// `GenerationPlanner.swift` pour que `PredictRequest` (qui le porte) puisse
/// vivre dans la lib pure `SouffleuseCore`. `GenerationPlanner` reste dans le
/// target `Souffleuse` (@MainActor, lifecycle owner) et continue d'utiliser ce
/// type via l'import du module.
public struct GenerationToken: Sendable, Equatable {
    public let value: UInt64

    public init(value: UInt64) {
        self.value = value
    }
}
