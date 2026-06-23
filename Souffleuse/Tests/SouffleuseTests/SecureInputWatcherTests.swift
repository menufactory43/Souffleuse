import Testing
@testable import Souffleuse

@Suite("SecureInputWatcher")
struct SecureInputWatcherTests {
    @Test("aucune alerte quand la saisie sécurisée est OFF")
    func noWarnWhenOff() {
        var w = SecureInputWatcher()
        #expect(w.evaluate(secureInputOn: false, ghostActive: true) == false)
    }

    @Test("aucune alerte sans souffle visible, même si la saisie sécurisée est ON")
    func noWarnWithoutGhost() {
        var w = SecureInputWatcher()
        #expect(w.evaluate(secureInputOn: true, ghostActive: false) == false)
    }

    @Test("une seule alerte par épisode")
    func warnsOncePerEpisode() {
        var w = SecureInputWatcher()
        #expect(w.evaluate(secureInputOn: true, ghostActive: true) == true)
        // Ticks suivants du MÊME épisode : plus d'alerte.
        #expect(w.evaluate(secureInputOn: true, ghostActive: true) == false)
        #expect(w.evaluate(secureInputOn: true, ghostActive: true) == false)
    }

    @Test("la transition ON→OFF réarme pour le prochain épisode")
    func resetsAfterUnlock() {
        var w = SecureInputWatcher()
        #expect(w.evaluate(secureInputOn: true, ghostActive: true) == true)
        // Déverrouillage (même sans souffle) → fin d'épisode, réarme.
        #expect(w.evaluate(secureInputOn: false, ghostActive: false) == false)
        // Nouvel épisode → ré-alerte.
        #expect(w.evaluate(secureInputOn: true, ghostActive: true) == true)
    }

    @Test("première évaluation avec un souffle déjà visible alerte")
    func warnsWhenGhostAlreadyVisible() {
        var w = SecureInputWatcher()
        // Le souffle était déjà à l'écran (peint au tick précédent) quand la saisie
        // sécurisée passe ON — on doit quand même alerter (cas réel du blocage).
        #expect(w.evaluate(secureInputOn: true, ghostActive: true) == true)
    }
}
