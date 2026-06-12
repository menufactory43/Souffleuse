import Foundation
import Testing

@testable import SouffleuseCore

/// Garde le contrat de réversibilité du bias corpus beam : OPT-IN strict.
/// Le runner de tests ne pose pas `SOUFFLEUSE_BEAM_BIAS` → le flag DOIT être
/// faux, donc `ModelRuntime.generateGhostBeam` pose un gain 0 et l'expansion
/// beam reste byte-identique au chemin d'avant le portage.
@Suite("Beam bias — flag opt-in")
struct BeamBiasTuningTests {
    @Test func flagOffParDefaut() {
        #expect(ProcessInfo.processInfo.environment["SOUFFLEUSE_BEAM_BIAS"] == nil,
                "ce test ne vaut que sans la variable d'env posée")
        #expect(!SuggestionPolicy.Tuning.beamBiasEnabled)
    }
}
