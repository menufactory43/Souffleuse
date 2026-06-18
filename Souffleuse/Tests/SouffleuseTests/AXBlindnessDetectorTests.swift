import Foundation
import Testing
@testable import Souffleuse

// MARK: - AXBlindnessDetectorTests

/// Verrouille la logique pure du détecteur « autorisé mais aveugle » : isTrusted
/// vrai mais lectures AX mortes (grant TCC périmé). Aucun AppKit ni AX réel — tout
/// est dérivé d'entrées explicites (bundleID, role-nil, horloge injectée).
@Suite("AX blindness detector")
struct AXBlindnessDetectorTests {

    /// Avance l'horloge depuis une base fixe (déterministe, pas de Date() ambiant).
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    @Test("un élément focus lisible ne déclenche jamais et réarme")
    func readableNeverFires() {
        var d = AXBlindnessDetector()
        for s in stride(from: 0.0, through: 60, by: 1) {
            #expect(d.observe(bundleID: "com.apple.TextEdit", focusedRoleIsNil: false, now: at(s)) == false)
        }
        #expect(d.firstBlindAt == nil)
        #expect(d.noticed == false)
    }

    @Test("aveugle sur UNE SEULE app ne déclenche pas (garde anti-Chromium)")
    func singleAppNeverFires() {
        var d = AXBlindnessDetector()
        var fired = false
        for s in stride(from: 0.0, through: 120, by: 1) {
            if d.observe(bundleID: "com.brave.Browser", focusedRoleIsNil: true, now: at(s)) { fired = true }
        }
        #expect(fired == false)
        #expect(d.blindApps == ["com.brave.Browser"])
    }

    @Test("aveugle soutenu sur ≥2 apps déclenche une fois passé le seuil de durée")
    func multiAppSustainedFires() {
        var d = AXBlindnessDetector()
        // Deux apps distinctes dès le début, mais avant 20 s → pas encore.
        #expect(d.observe(bundleID: "com.apple.TextEdit", focusedRoleIsNil: true, now: at(0)) == false)
        #expect(d.observe(bundleID: "com.brave.Browser", focusedRoleIsNil: true, now: at(5)) == false)
        #expect(d.observe(bundleID: "com.brave.Browser", focusedRoleIsNil: true, now: at(19)) == false)
        // Passé 20 s, deux apps vues → déclenche.
        #expect(d.observe(bundleID: "com.brave.Browser", focusedRoleIsNil: true, now: at(20)) == true)
    }

    @Test("durée atteinte mais une seule app → ne déclenche pas")
    func durationWithoutDistinctApps() {
        var d = AXBlindnessDetector()
        #expect(d.observe(bundleID: "com.apple.Notes", focusedRoleIsNil: true, now: at(0)) == false)
        #expect(d.observe(bundleID: "com.apple.Notes", focusedRoleIsNil: true, now: at(30)) == false)
    }

    @Test("ne déclenche qu'une fois par épisode (pas de re-spam)")
    func firesOncePerEpisode() {
        var d = AXBlindnessDetector()
        _ = d.observe(bundleID: "com.apple.TextEdit", focusedRoleIsNil: true, now: at(0))
        _ = d.observe(bundleID: "com.brave.Browser", focusedRoleIsNil: true, now: at(10))
        #expect(d.observe(bundleID: "com.brave.Browser", focusedRoleIsNil: true, now: at(25)) == true)
        // Encore aveugle, mais déjà prévenu → silence.
        #expect(d.observe(bundleID: "com.brave.Browser", focusedRoleIsNil: true, now: at(40)) == false)
        #expect(d.observe(bundleID: "com.apple.Mail", focusedRoleIsNil: true, now: at(99)) == false)
    }

    @Test("un retour de l'AX réarme : un nouvel épisode peut re-déclencher")
    func recoveryRearms() {
        var d = AXBlindnessDetector()
        _ = d.observe(bundleID: "com.apple.TextEdit", focusedRoleIsNil: true, now: at(0))
        #expect(d.observe(bundleID: "com.brave.Browser", focusedRoleIsNil: true, now: at(25)) == true)
        // L'AX répond une fois → reset complet.
        #expect(d.observe(bundleID: "com.apple.TextEdit", focusedRoleIsNil: false, now: at(26)) == false)
        #expect(d.firstBlindAt == nil)
        #expect(d.noticed == false)
        // Nouvel épisode aveugle → peut re-déclencher.
        _ = d.observe(bundleID: "com.apple.TextEdit", focusedRoleIsNil: true, now: at(30))
        #expect(d.observe(bundleID: "com.brave.Browser", focusedRoleIsNil: true, now: at(55)) == true)
    }

    @Test("bundleID nil (pas d'app au premier plan) réarme, ne compte pas")
    func nilBundleResets() {
        var d = AXBlindnessDetector()
        _ = d.observe(bundleID: "com.apple.TextEdit", focusedRoleIsNil: true, now: at(0))
        #expect(d.observe(bundleID: nil, focusedRoleIsNil: true, now: at(5)) == false)
        #expect(d.firstBlindAt == nil)
        #expect(d.blindApps.isEmpty)
    }
}
