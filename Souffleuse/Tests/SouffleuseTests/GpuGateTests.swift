import Testing
@testable import SouffleuseLlama

/// Couvre le coordinateur GPU (TRANSLATION-SPEC §2.9) : comptage des souffles en
/// vol et attente bornée côté traduction. Pur, sans GPU réel.
@Suite("GpuGate — priorité du ghost FR")
struct GpuGateTests {

    @Test("au repos par défaut")
    func idleByDefault() {
        let gate = GpuGate()
        #expect(gate.ghostActive == false)
    }

    @Test("ghostBegan/ghostEnded bascule l'état (équilibré)")
    func beganEndedToggles() {
        let gate = GpuGate()
        gate.ghostBegan()
        #expect(gate.ghostActive == true)
        gate.ghostEnded()
        #expect(gate.ghostActive == false)
    }

    @Test("compteur : reste actif tant que tous les souffles ne sont pas finis")
    func nestedCounting() {
        let gate = GpuGate()
        gate.ghostBegan()
        gate.ghostBegan()
        gate.ghostEnded()
        #expect(gate.ghostActive == true)   // un souffle encore en vol
        gate.ghostEnded()
        #expect(gate.ghostActive == false)
    }

    @Test("ghostEnded de trop ne descend pas sous zéro")
    func endedNeverNegative() {
        let gate = GpuGate()
        gate.ghostEnded()
        gate.ghostEnded()
        #expect(gate.ghostActive == false)
        gate.ghostBegan()
        #expect(gate.ghostActive == true)   // un seul began suffit à réactiver
    }

    @Test("awaitGhostIdle retourne ~tout de suite quand le ghost est au repos")
    func awaitReturnsImmediatelyWhenIdle() async {
        let gate = GpuGate()
        let waited = await gate.awaitGhostIdle(maxWaitMillis: 400, pollMillis: 30)
        #expect(waited == 0)
    }

    @Test("awaitGhostIdle est borné : il rend la main même si le ghost reste actif")
    func awaitIsBounded() async {
        let gate = GpuGate()
        gate.ghostBegan()   // jamais relâché : on vérifie la borne
        let waited = await gate.awaitGhostIdle(maxWaitMillis: 90, pollMillis: 30)
        #expect(waited >= 90)
        #expect(waited < 400)   // n'attend pas indéfiniment
    }

    @Test("awaitGhostIdle avec paramètres nuls ne boucle pas")
    func awaitZeroParams() async {
        let gate = GpuGate()
        gate.ghostBegan()
        let waited = await gate.awaitGhostIdle(maxWaitMillis: 0, pollMillis: 30)
        #expect(waited == 0)
    }
}
