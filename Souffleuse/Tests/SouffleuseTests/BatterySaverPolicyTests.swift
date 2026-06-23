import Testing
@testable import Souffleuse

@Suite("BatterySaverPolicy")
struct BatterySaverPolicyTests {
    private let heavyID = "qwen3-8b-q4"
    private let lightID = GGUFModelOption.lightestID

    @Test("tout OFF ⇒ no-op (longueur/modèle = base, pas de suppression)")
    func allOffIsNoOp() {
        let p = BatterySaverPolicy(isOnBattery: true, shorter: false, lighterModel: false, pause: false)
        #expect(p.effectiveLength(base: .long) == .long)
        #expect(p.effectiveModelID(base: heavyID, lightestID: lightID, lightestResolvable: true) == heavyID)
        #expect(p.suppressGeneration == false)
    }

    @Test("options actives mais SUR SECTEUR ⇒ no-op")
    func onACIsNoOp() {
        let p = BatterySaverPolicy(isOnBattery: false, shorter: true, lighterModel: true, pause: true)
        #expect(p.effectiveLength(base: .long) == .long)
        #expect(p.effectiveModelID(base: heavyID, lightestID: lightID, lightestResolvable: true) == heavyID)
        #expect(p.suppressGeneration == false)
    }

    @Test("sur batterie : complétions plus courtes ⇒ .short")
    func shorterOnBattery() {
        let p = BatterySaverPolicy(isOnBattery: true, shorter: true, lighterModel: false, pause: false)
        #expect(p.effectiveLength(base: .long) == .short)
        #expect(p.effectiveLength(base: .medium) == .short)
    }

    @Test("sur batterie : voix légère ⇒ bascule SI le léger est résolvable")
    func lighterOnBattery() {
        let p = BatterySaverPolicy(isOnBattery: true, shorter: false, lighterModel: true, pause: false)
        #expect(p.effectiveModelID(base: heavyID, lightestID: lightID, lightestResolvable: true) == lightID)
        // Léger non téléchargé ⇒ on GARDE le choix utilisateur (pas de souffle muet).
        #expect(p.effectiveModelID(base: heavyID, lightestID: lightID, lightestResolvable: false) == heavyID)
    }

    @Test("sur batterie : suspendre ⇒ suppressGeneration")
    func pauseOnBattery() {
        let p = BatterySaverPolicy(isOnBattery: true, shorter: false, lighterModel: false, pause: true)
        #expect(p.suppressGeneration == true)
    }

    @Test("lightestID est une entrée valide du catalogue, la plus légère")
    func lightestIDIsValid() {
        let lightest = GGUFModelOption.option(forID: GGUFModelOption.lightestID)
        #expect(lightest.id == GGUFModelOption.lightestID)
        let minRAM = GGUFModelOption.catalogue.map(\.approxRAMMB).min()
        #expect(lightest.approxRAMMB == minRAM)
    }
}
