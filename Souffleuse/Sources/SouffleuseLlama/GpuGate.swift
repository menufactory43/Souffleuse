import Foundation
import os

/// Coordinateur GPU léger entre les DEUX moteurs llama.cpp du process (le ghost
/// FR et la traduction).
///
/// Les deux `LlamaEngine` ont chacun leur `llama_context` et leur cache KV, mais
/// partagent **un seul `MTLCommandQueue` Metal** : leurs `llama_decode`
/// sérialisent sur le GPU, sans priorité native (TRANSLATION-SPEC §2.9). Or le
/// ghost FR doit *sembler instantané* (valeur cœur du produit) : il ne faut donc
/// pas démarrer le décode lourd d'une traduction pendant qu'un souffle est en
/// vol.
///
/// Mécanisme volontairement minimal et SANS risque pour la correction de la
/// traduction : un compteur de souffles en vol. Le chemin ghost l'incrémente
/// autour de son `generate` ; le chemin traduction **attend** (borné) que le
/// compteur retombe à zéro avant de lancer son décode. Aucune interruption
/// mid-décode (qui risquerait une traduction tronquée) — la traduction « a le
/// droit de traîner », le ghost non.
///
/// `@unchecked Sendable` : tout l'état mutable est gardé par un
/// `OSAllocatedUnfairLock`.
public final class GpuGate: @unchecked Sendable {
    /// Instance partagée par les deux moteurs (état transverse au process —
    /// cf. « Global state » des contraintes d'archi).
    public static let shared = GpuGate()

    /// Nombre de générations ghost actuellement en vol (≥ 0).
    private let inFlight = OSAllocatedUnfairLock(initialState: 0)

    public init() {}

    /// À appeler juste avant le `generate` du ghost.
    public func ghostBegan() {
        inFlight.withLock { $0 += 1 }
    }

    /// À appeler juste après le `generate` du ghost (succès ou arrêt anticipé).
    public func ghostEnded() {
        inFlight.withLock { if $0 > 0 { $0 -= 1 } }
    }

    /// Un souffle est-il en vol ?
    public var ghostActive: Bool {
        inFlight.withLock { $0 > 0 }
    }

    /// Attend que le ghost soit au repos avant de lancer une traduction, BORNÉ
    /// par `maxWaitMillis` (au-delà, on démarre quand même : la traduction ne doit
    /// jamais être bloquée indéfiniment — le ghost est court, il va finir). Sonde
    /// toutes les `pollMillis`. Renvoie le temps attendu (ms), utile aux tests /
    /// au log.
    @discardableResult
    public func awaitGhostIdle(maxWaitMillis: Int, pollMillis: Int) async -> Int {
        guard maxWaitMillis > 0, pollMillis > 0 else { return 0 }
        var waited = 0
        while ghostActive && waited < maxWaitMillis {
            try? await Task.sleep(nanoseconds: UInt64(pollMillis) * 1_000_000)
            waited += pollMillis
        }
        return waited
    }
}
