import Testing
import Foundation
import SouffleuseCore
@testable import Souffleuse

/// Frame C — mid-word escalation, étage 1 (greedy + dico), décision PURE.
///
/// Rejoue en synthétique les cas mesurés sur le chemin de prod réel par
/// `SouffleuseMidwordEval` : on fournit le mot greedy déjà extrait + sa
/// confiance top-1, on vérifie le verdict. Aucun MLX, aucune frappe — juste la
/// fonction de décision qui sera câblée derrière `midWordEscalationEnabled` (F1).
///
/// Les deux axes de panne validés par le bench :
///  - AMBIGUÏTÉ / fragment court → `.uncertain` (les branches trancheront en F2)
///  - ÉCHEC DE HEALING (mot fusionné invalide) → `.fastReject`
/// et le bon cas confiant → `.fastAccept`.
@Suite("Frame C — mid-word escalation (étage 1, décision pure)")
struct MidWordEscalationTests {

    // MARK: - midWordLeadWord (extraction du mot de tête)

    @Test func leadWordDropsLeadingSpaceThenTakesWordRun() {
        // La sortie healed démarre souvent par " mot".
        #expect(SuggestionPolicy.midWordLeadWord(" cacahuète et respectons") == "cacahuète")
    }

    @Test func leadWordWithoutLeadingSpace() {
        #expect(SuggestionPolicy.midWordLeadWord("personnelles, et plus") == "personnelles")
    }

    @Test func leadWordKeepsIntraWordJoiner() {
        // L'apostrophe d'élision fait partie du mot (leadingWordRun).
        #expect(SuggestionPolicy.midWordLeadWord(" d'acquisition est") == "d'acquisition")
    }

    @Test func leadWordEmptyWhenNextWordJump() {
        // Démarrage sur ponctuation/espace ⇒ pas une complétion du mot courant.
        #expect(SuggestionPolicy.midWordLeadWord(" , mais plus tard") == "")
    }

    // MARK: - midWordValidExtends (garde anti-échec-de-healing)

    @Test func validExtendsTrueForRealCompletion() {
        #expect(SuggestionPolicy.midWordValidExtends(partial: "cacahu", modal: "cacahuète"))
        #expect(SuggestionPolicy.midWordValidExtends(partial: "pati", modal: "patience"))
    }

    @Test func validExtendsFalseWhenModalDoesNotExtendPartial() {
        // Échecs de healing observés : le modèle re-tape un fragment plus court /
        // une autre lettre que le partiel réellement tapé.
        #expect(!SuggestionPolicy.midWordValidExtends(partial: "aspira", modal: "a"))
        #expect(!SuggestionPolicy.midWordValidExtends(partial: "pingou", modal: "pingo"))
        #expect(!SuggestionPolicy.midWordValidExtends(partial: "imposa", modal: "i"))
    }

    @Test func validExtendsFalseWhenModalIsNotADictionaryWord() {
        // Prolonge bien le partiel, mais n'est pas un mot → rejeté.
        #expect(!SuggestionPolicy.midWordValidExtends(partial: "cacahu", modal: "cacahuxqz"))
    }

    // MARK: - midWordFastDecision (verdict étage 1)

    @Test func fastAcceptWhenConfidentValidLongFragment() {
        let d = SuggestionPolicy.midWordFastDecision(
            partial: "cacahu", greedyModal: "cacahuète",
            firstTokenProb: SuggestionPolicy.Tuning.escFastP1)   // pile au seuil (>=)
        #expect(d == .fastAccept(word: "cacahuète"))
    }

    @Test func fastRejectOnHealingFailure() {
        // "a" ne prolonge pas "aspira" → rejet, même à confiance élevée.
        let d = SuggestionPolicy.midWordFastDecision(
            partial: "aspira", greedyModal: "a", firstTokenProb: 0.99)
        #expect(d == .fastReject)
    }

    @Test func uncertainWhenFragmentTooShort() {
        // Fragment court : même valide + confiant, il reste ambigu ("co"→"comme"
        // alors que l'intention pourrait être "comment"/"commande") → branches (F2).
        let d = SuggestionPolicy.midWordFastDecision(
            partial: "co", greedyModal: "comme",
            firstTokenProb: SuggestionPolicy.Tuning.escFastP1 + 0.1)
        #expect(d == .uncertain)
    }

    @Test func uncertainWhenLowConfidence() {
        // Mot valide + fragment assez long, mais le modèle hésite → branches (F2).
        let d = SuggestionPolicy.midWordFastDecision(
            partial: "cess", greedyModal: "cession",
            firstTokenProb: SuggestionPolicy.Tuning.escFastP1 - 0.2)
        #expect(d == .uncertain)
    }

    @Test func flagOffByDefaultKeepsCurrentBehaviour() {
        // Garde-fou de réversibilité : tant que le flag est OFF, F1 n'est pas câblé.
        #expect(SuggestionPolicy.Tuning.midWordEscalationEnabled == false)
    }
}
