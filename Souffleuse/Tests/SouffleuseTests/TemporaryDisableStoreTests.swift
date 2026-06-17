import Testing
import Foundation
@testable import Souffleuse

/// Désactivations temporaires par app (menu « Désactiver dans <App> ») : on
/// couvre la logique PURE d'expiration (nonisolated static) + un aller-retour
/// d'instance sur un UserDefaults jetable.
@Suite("TemporaryDisableStore")
struct TemporaryDisableStoreTests {

    static let now = Date(timeIntervalSinceReferenceDate: 1000)

    @Test("isDisabled : absent → faux, futur → vrai, passé → faux")
    func isDisabledExpiry() {
        let entries: [String: Double] = ["futur": 2000, "passe": 500]
        #expect(TemporaryDisableStore.isDisabled(bundleID: "absent", now: Self.now, entries: entries) == false)
        #expect(TemporaryDisableStore.isDisabled(bundleID: "futur", now: Self.now, entries: entries) == true)
        #expect(TemporaryDisableStore.isDisabled(bundleID: "passe", now: Self.now, entries: entries) == false)
    }

    @Test("indéfiniment (distantFuture) reste désactivé")
    func indefiniteStaysDisabled() {
        let entries = ["x": TemporaryDisableStore.indefinite.timeIntervalSinceReferenceDate]
        #expect(TemporaryDisableStore.isDisabled(bundleID: "x", now: Self.now, entries: entries) == true)
        // Même très loin dans le futur.
        let far = Date(timeIntervalSinceReferenceDate: 1_000_000_000)
        #expect(TemporaryDisableStore.isDisabled(bundleID: "x", now: far, entries: entries) == true)
    }

    @Test("pruned retire les expirés, garde futur + indéfini")
    func prunedDropsExpired() {
        let entries: [String: Double] = [
            "futur": 2000,
            "passe": 500,
            "indef": TemporaryDisableStore.indefinite.timeIntervalSinceReferenceDate,
        ]
        let kept = TemporaryDisableStore.pruned(entries, now: Self.now)
        #expect(Set(kept.keys) == ["futur", "indef"])
    }

    @MainActor
    @Test("instance : disable → isDisabled, reactivate → actif, persistance")
    func instanceRoundTrip() {
        let suite = "TemporaryDisableStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = TemporaryDisableStore(defaults: defaults, key: "k")
        #expect(store.isDisabled(bundleID: "app.x") == false)

        store.disable(bundleID: "app.x", until: Date().addingTimeInterval(300))
        #expect(store.isDisabled(bundleID: "app.x") == true)

        // Rechargé depuis le MÊME UserDefaults → l'entrée survit.
        let reloaded = TemporaryDisableStore(defaults: defaults, key: "k")
        #expect(reloaded.isDisabled(bundleID: "app.x") == true)

        store.reactivate(bundleID: "app.x")
        #expect(store.isDisabled(bundleID: "app.x") == false)
    }

    @MainActor
    @Test("instance : une entrée déjà expirée est ignorée au chargement")
    func expiredEntryIgnoredOnLoad() {
        let suite = "TemporaryDisableStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Pose à la main une entrée déjà expirée.
        defaults.set(["app.old": Date().addingTimeInterval(-60).timeIntervalSinceReferenceDate], forKey: "k")
        let store = TemporaryDisableStore(defaults: defaults, key: "k")
        #expect(store.isDisabled(bundleID: "app.old") == false)
    }
}

/// Compteur compact de l'icône menu-bar (frappes épargnées du jour).
@Suite("UsageLedger.compactCount")
struct CompactCountTests {

    @Test("0 → vide, petits nombres tels quels")
    func smallNumbers() {
        #expect(UsageLedger.compactCount(0) == "")
        #expect(UsageLedger.compactCount(-5) == "")
        #expect(UsageLedger.compactCount(1) == "1")
        #expect(UsageLedger.compactCount(999) == "999")
    }

    @Test("≥ 1000 → forme « 1,2k » (virgule FR), entier au-delà de 10k")
    func thousands() {
        #expect(UsageLedger.compactCount(1000) == "1,0k")
        #expect(UsageLedger.compactCount(1200) == "1,2k")
        #expect(UsageLedger.compactCount(10_000) == "10k")
        #expect(UsageLedger.compactCount(15_400) == "15k")
    }
}
