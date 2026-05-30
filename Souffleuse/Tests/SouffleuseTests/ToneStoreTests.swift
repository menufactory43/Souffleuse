import Testing
import Foundation
@testable import Souffleuse
import SouffleuseCore

/// Couvre le `ToneStore` : défaut global Neutre, surcharge par application, lookup
/// pur (sans disque ni MainActor) et aller-retour de persistance JSON.
@Suite("ToneStore — ton de relecture par app")
struct ToneStoreTests {

    // MARK: - Lookup pur (nonisolated static)

    @Test("aucune règle → défaut global")
    func emptyFallsBackToDefault() {
        #expect(ToneStore.tone(forBundle: "com.apple.mail", rules: [], defaultTone: .neutral) == .neutral)
        #expect(ToneStore.tone(forBundle: "com.apple.mail", rules: [], defaultTone: .formal) == .formal)
    }

    @Test("bundleID inconnu (ou nil) → défaut global")
    func unknownBundleFallsBack() {
        let rules = [ToneRule(bundleID: "com.tinyspeck.slackmacgap", tone: .casual)]
        #expect(ToneStore.tone(forBundle: "com.apple.mail", rules: rules, defaultTone: .neutral) == .neutral)
        #expect(ToneStore.tone(forBundle: nil, rules: rules, defaultTone: .formal) == .formal)
    }

    @Test("une règle par app l'emporte sur le défaut")
    func ruleOverridesDefault() {
        let rules = [
            ToneRule(bundleID: "com.tinyspeck.slackmacgap", tone: .casual),
            ToneRule(bundleID: "com.apple.mail", tone: .formal),
        ]
        #expect(ToneStore.tone(forBundle: "com.tinyspeck.slackmacgap", rules: rules, defaultTone: .neutral) == .casual)
        #expect(ToneStore.tone(forBundle: "com.apple.mail", rules: rules, defaultTone: .neutral) == .formal)
    }

    // MARK: - Persistance (round-trip disque)

    @MainActor
    @Test("le défaut global et les règles survivent à un rechargement")
    func persistenceRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tones-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ToneStore(fileURL: url)
        #expect(store.defaultTone == .neutral)  // défaut à froid
        store.setDefaultTone(.formal)
        store.upsert(ToneRule(bundleID: "com.tinyspeck.slackmacgap", tone: .casual))

        // Un « redémarrage » relit le fichier.
        let reloaded = ToneStore(fileURL: url)
        #expect(reloaded.defaultTone == .formal)
        #expect(reloaded.tone(forBundle: "com.tinyspeck.slackmacgap") == .casual)
        #expect(reloaded.tone(forBundle: "com.apple.mail") == .formal)  // défaut conservé
    }

    @MainActor
    @Test("supprimer une règle restitue le ton par défaut pour cette app")
    func deleteRestoresDefault() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tones-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ToneStore(fileURL: url)
        let rule = ToneRule(bundleID: "com.apple.mail", tone: .casual)
        store.upsert(rule)
        #expect(store.tone(forBundle: "com.apple.mail") == .casual)
        store.delete(rule.id)
        #expect(store.tone(forBundle: "com.apple.mail") == .neutral)
    }
}
