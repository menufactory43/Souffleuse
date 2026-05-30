import Foundation
import Testing
@testable import Souffleuse

// MARK: - HUDAnchorStoreTests

/// Garde la persistance par-bundleID de la position du HUD de traduction :
/// round-trip disque, upsert idempotent, reset, reset-sur-fichier-corrompu, et
/// le lookup pur. Clone du style `AllowlistStore`/`TypingHistoryStore` tests
/// (fichier temp + `defer` cleanup, `@MainActor` car le store l'est).
@Suite("HUDAnchorStore persistence (by bundleID)")
struct HUDAnchorStoreTests {

    private static func tempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HUDAnchorStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hud-anchors.json")
    }

    @MainActor
    @Test("upsert puis relecture disque : l'ancre relative survit")
    func roundTripToDisk() {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = HUDAnchorStore(fileURL: url)
        store.upsert(HUDAnchor(bundleID: "com.brave.Browser", edge: .left, offsetX: 12, offsetY: -8))

        let reloaded = HUDAnchorStore(fileURL: url)
        let a = reloaded.anchor(forBundle: "com.brave.Browser")
        #expect(a != nil)
        #expect(a?.edge == .left)
        #expect(a?.offsetX == 12)
        #expect(a?.offsetY == -8)
    }

    @MainActor
    @Test("upsert idempotent par bundleID (pas de doublon)")
    func upsertReplacesByBundle() {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = HUDAnchorStore(fileURL: url)
        store.upsert(HUDAnchor(bundleID: "com.apple.mail", edge: .right))
        store.upsert(HUDAnchor(bundleID: "com.apple.mail", edge: .bottom, offsetY: 5))

        #expect(store.anchors.filter { $0.bundleID == "com.apple.mail" }.count == 1)
        #expect(store.anchor(forBundle: "com.apple.mail")?.edge == .bottom)
    }

    @MainActor
    @Test("reset(bundleID:) oublie la position, et la persiste")
    func resetForgets() {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = HUDAnchorStore(fileURL: url)
        store.upsert(HUDAnchor(bundleID: "x", edge: .top))
        store.reset(bundleID: "x")
        #expect(store.anchor(forBundle: "x") == nil)
        #expect(HUDAnchorStore(fileURL: url).anchor(forBundle: "x") == nil)
    }

    @MainActor
    @Test("fichier corrompu → reset à vide (pas de crash)")
    func corruptFileResetsToEmpty() {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try? Data("{ pas du json valide ".utf8).write(to: url)
        let store = HUDAnchorStore(fileURL: url)
        #expect(store.anchors.isEmpty)
    }

    @Test("lookup pur statique, sans disque")
    func pureLookup() {
        let anchors = [
            HUDAnchor(bundleID: "a", edge: .left),
            HUDAnchor(bundleID: "b", edge: .right),
        ]
        #expect(HUDAnchorStore.anchor(forBundle: "b", anchors: anchors)?.edge == .right)
        #expect(HUDAnchorStore.anchor(forBundle: "zzz", anchors: anchors) == nil)
    }

    @Test("defaults du type valeur : bord droit, offsets nuls")
    func valueDefaults() {
        let a = HUDAnchor(bundleID: "x")
        #expect(a.edge == .right)
        #expect(a.offsetX == 0)
        #expect(a.offsetY == 0)
    }
}
