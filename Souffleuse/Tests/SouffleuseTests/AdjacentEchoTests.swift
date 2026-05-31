import Testing
import Foundation
import SouffleuseCore

/// Anti-répétition streaming — `OutputFilter.ghostEchoesAdjacent`.
///
/// Attrape les échos que `ghostIsRepeatingPrefix` (strippe le mot partiel) et
/// `dedupLeadingRepeat` (égalité exacte) laissent passer, SANS tuer une
/// continuation légitime. Cas observés en live (J'adore les fraises…).
@Suite("Anti-répétition streaming — écho adjacent")
struct AdjacentEchoTests {

    // MARK: - Échos à DROPPER

    @Test func phraseEchoWithCommaAndPlural() {
        // « …les fraise » + « , les fraises » → « les fraise, les fraises ».
        #expect(OutputFilter.ghostEchoesAdjacent(prefix: "J'adore les fraise", ghost: ", les fraises"))
    }

    @Test func singleWordEchoPluralDefeated() {
        // « …les fraises » + « fraise » → « les fraises fraise » (pluriel défait).
        #expect(OutputFilter.ghostEchoesAdjacent(prefix: "J'adore les fraises", ghost: " fraise"))
    }

    @Test func twoWordExactEcho() {
        #expect(OutputFilter.ghostEchoesAdjacent(prefix: "je pense", ghost: " je pense que"))
    }

    // MARK: - Continuations LÉGITIMES (doivent SURVIVRE)

    @Test func reflexiveDoublingSurvives() {
        // « vous vous souvenez » est correct : un seul mot EXACT répété n'est PAS
        // un écho (sinon on casse les réfléchis).
        #expect(!OutputFilter.ghostEchoesAdjacent(prefix: "vous", ghost: " vous souvenez"))
        #expect(!OutputFilter.ghostEchoesAdjacent(prefix: "nous", ghost: " nous appelons"))
    }

    @Test func shortArticleRepeatSurvives() {
        // « le chat » + « le noir » : pas d'écho adjacent (« chat » ≠ « le »).
        #expect(!OutputFilter.ghostEchoesAdjacent(prefix: "le chat", ghost: " le noir"))
    }

    @Test func noOverlapSurvives() {
        #expect(!OutputFilter.ghostEchoesAdjacent(prefix: "merci de votre", ghost: " patience"))
    }

    @Test func midWordCompletionSurvives() {
        // Complétion mid-mot « les frai » → « ses » : le ghost ne re-dit rien.
        #expect(!OutputFilter.ghostEchoesAdjacent(prefix: "les frai", ghost: "ses"))
    }

    @Test func distinctListItemsSurvive() {
        // « des pommes » + « des poires » : « des » répété mais « pommes »≠« poires ».
        #expect(!OutputFilter.ghostEchoesAdjacent(prefix: "j'achète des pommes", ghost: " des poires"))
    }

    @Test func emptyGhostOrPrefixSurvives() {
        #expect(!OutputFilter.ghostEchoesAdjacent(prefix: "", ghost: " bonjour"))
        #expect(!OutputFilter.ghostEchoesAdjacent(prefix: "bonjour", ghost: ""))
    }
}
