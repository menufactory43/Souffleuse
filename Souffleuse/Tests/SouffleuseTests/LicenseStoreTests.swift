import Testing
import Foundation
@testable import Souffleuse

/// Gating Studio + kill switch. La vérité du gating est testée via le statique pur
/// `isProValue` (le drapeau réel `LicenseGate.paywallEnabled` est compile-time).
@Suite("LicenseStore")
struct LicenseStoreTests {

    @Test("kill switch off → toujours débloqué (avec ou sans licence)")
    func killSwitchOffUnlocksEverything() {
        #expect(LicenseStore.isProValue(paywallEnabled: false, hasLicense: false) == true)
        #expect(LicenseStore.isProValue(paywallEnabled: false, hasLicense: true) == true)
    }

    @Test("paywall on → débloqué seulement avec une licence")
    func paywallOnRequiresLicense() {
        #expect(LicenseStore.isProValue(paywallEnabled: true, hasLicense: false) == false)
        #expect(LicenseStore.isProValue(paywallEnabled: true, hasLicense: true) == true)
    }

    @Test("le défaut shippé est kill switch OFF (rien ne change pour personne)")
    func defaultIsPaywallOff() {
        #expect(LicenseGate.paywallEnabled == false)
    }

    @Test("activateur stub : clé SOUF- valide passe, le reste throw")
    func stubActivator() async {
        let stub = StubLicenseActivator()
        await #expect(throws: Never.self) { try await stub.activate(key: "SOUF-ABCDEFG") }
        await #expect(throws: LicenseError.invalidKey) { try await stub.activate(key: "nope") }
        await #expect(throws: LicenseError.invalidKey) { try await stub.activate(key: "SOUF-1") }  // trop court
    }

    @Test("chaque erreur a un message non vide (FR)")
    func errorMessages() {
        for e in [LicenseError.empty, .invalidKey, .network, .deviceLimitReached] {
            #expect(!e.message.isEmpty)
        }
    }
}
