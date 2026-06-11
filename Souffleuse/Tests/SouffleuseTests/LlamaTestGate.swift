import Foundation

/// Porte de sérialisation TEST-ONLY pour les suites qui chargent un VRAI
/// contexte llama.cpp. Le backend Metal est process-global : deux décodages
/// simultanés se corrompent mutuellement (cf. doc de `KVCacheReuseTests`).
/// `.serialized` n'ordonne qu'À L'INTÉRIEUR d'une suite — Swift Testing
/// parallélise les suites entre elles, d'où des échecs flaky dès qu'il existe
/// plus d'une suite modèle-réel. Chaque test modèle enveloppe son corps dans
/// `LlamaTestGate.shared.run { … }`.
final class LlamaTestGate: @unchecked Sendable {
    static let shared = LlamaTestGate()

    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if busy {
                waiters.append(continuation)
                lock.unlock()
            } else {
                busy = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    private func release() {
        lock.lock()
        if waiters.isEmpty {
            busy = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }

    /// Exécute `body` en exclusivité vis-à-vis de tous les autres tests modèle.
    /// Le skip (`XCTSkipLikeError`) et les échecs relâchent la porte (defer).
    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }
}
