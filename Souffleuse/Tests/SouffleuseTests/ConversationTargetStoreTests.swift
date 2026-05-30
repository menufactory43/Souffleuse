import Foundation
import Testing
@testable import Souffleuse
import SouffleuseCore

// MARK: - ConversationTargetStoreTests

/// Garde la persistance par-conversation de la cible de traduction (P5) :
/// construction de clé proxy (bundleID + titre nettoyé), round-trip disque,
/// cycle persistant, reset-sur-fichier-corrompu, et le lookup pur. Même style
/// que `HUDAnchorStoreTests` (fichier temp + `defer` cleanup, `@MainActor`).
@Suite("ConversationTargetStore persistence (by conversation)")
struct ConversationTargetStoreTests {

    private static func tempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConvTargetStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("conversation-targets.json")
    }

    // MARK: - Clé proxy (pur)

    @Test("la clé combine bundleID + titre nettoyé (blancs collapsés, borné)")
    func keyComposition() {
        let k = ConversationTargetStore.key(forBundle: "com.brave.Browser", windowTitle: "  Inbox   ·  Intercom  ")
        #expect(k == "com.brave.Browser\u{1}Inbox · Intercom")
    }

    @Test("titre nil/absent → clé stable sur le seul bundleID")
    func keyWithoutTitle() {
        let a = ConversationTargetStore.key(forBundle: "com.tinyspeck.slackmacgap", windowTitle: nil)
        let b = ConversationTargetStore.key(forBundle: "com.tinyspeck.slackmacgap", windowTitle: "")
        #expect(a == b)
        #expect(a == "com.tinyspeck.slackmacgap\u{1}")
    }

    @Test("des conversations différentes ne partagent pas de clé")
    func distinctConversationsDistinctKeys() {
        let mike = ConversationTargetStore.key(forBundle: "app.intercom", windowTitle: "Mike — Conversation")
        let lena = ConversationTargetStore.key(forBundle: "app.intercom", windowTitle: "Lena — Conversation")
        #expect(mike != lena)
    }

    // MARK: - Lookup pur

    @Test("lookup pur : clé inconnue → AUTO par défaut")
    func lookupDefaultsToAuto() {
        #expect(ConversationTargetStore.selection(forKey: "absent", entries: []) == .auto)
    }

    @Test("lookup pur : retrouve la sélection mémorisée")
    func lookupFindsStored() {
        let entries = [ConversationTarget(key: "k", selection: .fixed(.de))]
        #expect(ConversationTargetStore.selection(forKey: "k", entries: entries) == .fixed(.de))
    }

    // MARK: - Persistance disque

    @MainActor
    @Test("setSelection puis relecture disque : la cible survit")
    func roundTripToDisk() {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ConversationTargetStore(fileURL: url)
        store.setSelection(.fixed(.es), forBundle: "app.intercom", windowTitle: "Mike — Conversation")

        let reloaded = ConversationTargetStore(fileURL: url)
        #expect(reloaded.selection(forBundle: "app.intercom", windowTitle: "Mike — Conversation") == .fixed(.es))
        // Une autre conversation reste à AUTO.
        #expect(reloaded.selection(forBundle: "app.intercom", windowTitle: "Lena — Conversation") == .auto)
    }

    @MainActor
    @Test("cycle fait défiler et persiste (AUTO→EN→ES)")
    func cyclePersists() {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ConversationTargetStore(fileURL: url)
        #expect(store.cycle(forBundle: "b", windowTitle: "t") == .fixed(.en))
        #expect(store.cycle(forBundle: "b", windowTitle: "t") == .fixed(.es))

        let reloaded = ConversationTargetStore(fileURL: url)
        #expect(reloaded.selection(forBundle: "b", windowTitle: "t") == .fixed(.es))
    }

    @MainActor
    @Test("setSelection idempotent par clé (pas de doublon)")
    func setSelectionReplacesByKey() {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ConversationTargetStore(fileURL: url)
        store.setSelection(.fixed(.en), forBundle: "b", windowTitle: "t")
        store.setSelection(.fixed(.it), forBundle: "b", windowTitle: "t")

        let key = ConversationTargetStore.key(forBundle: "b", windowTitle: "t")
        #expect(store.entries.filter { $0.key == key }.count == 1)
        #expect(store.selection(forBundle: "b", windowTitle: "t") == .fixed(.it))
    }

    @MainActor
    @Test("fichier corrompu → reset à vide (jamais de crash)")
    func corruptFileResetsToEmpty() {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try? Data("{ not json".utf8).write(to: url)

        let store = ConversationTargetStore(fileURL: url)
        #expect(store.entries.isEmpty)
        #expect(store.selection(forBundle: "b", windowTitle: "t") == .auto)
    }
}
