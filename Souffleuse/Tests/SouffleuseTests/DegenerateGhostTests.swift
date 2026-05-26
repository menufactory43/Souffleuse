import Testing
@testable import Souffleuse

/// Guards the lone-"1" ghost fix : `OutputFilter.isDegenerateGhost` must drop
/// bare enumerators / numbers / list-markers (the instruct 1B starts numbered
/// lists in thin contexts, and sentence-truncation reduces "1. …" to "1.") —
/// WITHOUT dropping real completions that merely begin with a number.
@Suite("Degenerate ghost filter")
struct DegenerateGhostTests {

    @Test func dropsBareNumbersAndOrdinals() {
        for s in ["1", "1.", "12)", "100°", "100%", "1/2", "1er", "2nd", "3ème", "4e", " 1 ", "-", "•", "—", "...", ".", ":"] {
            #expect(ModelRuntime.OutputFilter.isDegenerateGhost(s), "should drop «\(s)»")
        }
    }

    @Test func dropsEmptyAndWhitespace() {
        #expect(ModelRuntime.OutputFilter.isDegenerateGhost(""))
        #expect(ModelRuntime.OutputFilter.isDegenerateGhost("   \n "))
    }

    @Test func keepsRealCompletionsThatStartWithANumber() {
        for s in ["1er janvier", "1/2 tasse de farine", "100% des cas", "2 heures plus tard", "1. continuer ici", "12 rue de la Paix"] {
            #expect(!ModelRuntime.OutputFilter.isDegenerateGhost(s), "should keep «\(s)»")
        }
    }

    @Test func keepsOrdinaryProse() {
        for s in ["informer que", "bonjour", "à bientôt", "dire que je suis"] {
            #expect(!ModelRuntime.OutputFilter.isDegenerateGhost(s))
        }
    }
}
