import Testing
import Foundation
import NaturalLanguage
import SouffleuseCore
import SouffleuseTyping
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

    @Test func flagsOnByDefaultShipped() {
        // Shippé ON par défaut (env absente) ; kill-switch DEV via *_OFF.
        #expect(SuggestionPolicy.Tuning.midWordEscalationEnabled == true)
        #expect(SuggestionPolicy.Tuning.midWordL0Fallback == true)
    }

    // MARK: - F3 — préfixe commun des complétions dico (longestCommonPrefix)

    @Test func commonPrefixUniqueCandidateFull() {
        // Un seul candidat → le suffixe entier est « commun » : « pingou »→« in ».
        #expect(WordCompleter.longestCommonPrefix(["in"]) == "in")
    }

    @Test func commonPrefixSharedStemKept() {
        // Pluriel + singulier partagent la racine : « uète »/« uètes » → « uète ».
        #expect(WordCompleter.longestCommonPrefix(["uète", "uètes"]) == "uète")
    }

    @Test func commonPrefixDivergentCollapsesToStub() {
        // Candidats qui divergent tôt (« teur »/« tion ») → commun minuscule « t »,
        // que le caller jette via escL0MinCompletion. C'est la garde anti-ambiguïté.
        #expect(WordCompleter.longestCommonPrefix(["teur", "tion"]) == "t")
    }

    @Test func commonPrefixNoOverlapEmpty() {
        #expect(WordCompleter.longestCommonPrefix(["uète", "ouète"]).isEmpty)
    }

    // MARK: - midWordBranchDecision (F2 — accord inter-branches)

    @Test func branchConvergentShows() {
        // Toutes les branches d'accord avec le greedy → accord 1.0 → montre.
        let d = SuggestionPolicy.midWordBranchDecision(
            partial: "cacahu", greedyModal: "cacahuète",
            branchLeads: ["cacahuète", "cacahuète", "cacahuète"])
        #expect(d.show)
        #expect(d.word == "cacahuète")
        #expect(d.agreement == 1.0)
    }

    @Test func branchPartialConvergenceShows() {
        // 3 voix sur 4 pour "fiscal" (le greedy + 2 branches) → 0.75 ≥ 0.6 → montre.
        let d = SuggestionPolicy.midWordBranchDecision(
            partial: "fis", greedyModal: "fiscal",
            branchLeads: ["fiscal", "fissa", "fiscal"])
        #expect(d.show)
        #expect(d.word == "fiscal")
    }

    @Test func branchDivergentHides() {
        // Fragment ambigu : les branches partent dans tous les sens → accord bas → cache.
        let d = SuggestionPolicy.midWordBranchDecision(
            partial: "co", greedyModal: "comme",
            branchLeads: ["cocus", "cormier", "comble"])
        #expect(!d.show)
        #expect(d.agreement < SuggestionPolicy.Tuning.escAgreeThresh)
    }

    // MARK: - midWordLeadWordDefrag (dé-fragmentation du mot éclaté)

    @Test func defragMergesFragmentedWordWhenValid() {
        // « caca huète » éclaté → collapsé en « cacahuète » (vrai mot, prolonge).
        #expect(SuggestionPolicy.midWordLeadWordDefrag("caca huète, beurre", partial: "cacah") == "cacahuète")
    }

    @Test func defragLeavesCleanLeadUntouched() {
        // Sortie non fragmentée : le run simple prolonge déjà → renvoyé tel quel.
        #expect(SuggestionPolicy.midWordLeadWordDefrag(" cacahuète et", partial: "cacah") == "cacahuète")
    }

    @Test func defragRefusesToMergeTwoDistinctWords() {
        // « je vais » → « jevais » invalide → on NE fusionne PAS, on retombe sur
        // le run simple (« je ») que le gate aval rejettera s'il ne prolonge pas.
        #expect(SuggestionPolicy.midWordLeadWordDefrag("je vais manger", partial: "jev") == "je")
    }

    @Test func defragKeepsHealingGarbageRejectable() {
        // « pingo u is » : aucun collapse ne forme un mot valide prolongeant
        // « pingou » (« pingou »/« pingouis » invalides) → run simple « pingo »,
        // que `validExtends` rejette → garbage toujours caché.
        let lead = SuggestionPolicy.midWordLeadWordDefrag("pingo u is", partial: "pingou")
        #expect(!SuggestionPolicy.midWordValidExtends(partial: "pingou", modal: lead))
    }

    @Test func branchHealingFailureHiddenDespiteHighAgreement() {
        // L'axe que l'accord SEUL manque : toutes les branches convergent sur le
        // garbage "pingo" (accord 1.0) MAIS il ne prolonge pas "pingou" → la garde
        // dico le cache quand même. C'est tout l'intérêt de la double garde.
        let d = SuggestionPolicy.midWordBranchDecision(
            partial: "pingou", greedyModal: "pingo",
            branchLeads: ["pingo", "pingo", "pingo"])
        #expect(d.agreement == 1.0)
        #expect(!d.show)
    }
}

/// C1 — gardes de sortie de la CONTINUATION mid-mot (mot + suite en greedy).
/// Verrouille les deux helpers purs (`echoScore`, `languageMismatch`) ainsi que
/// la dérivation de la langue attendue. La continuation N'est montrée QUE si le
/// segment APRÈS le mot passe les gardes ; sinon on retombe sur le mot seul (C0).
@Suite("C1 — continuation exit guards (echo / language)")
struct MidWordContinuationGuardTests {

    // MARK: - echoScore

    @Test func echoScoreHighWhenContinuationCopiesLastSentence() {
        // Le segment recopie intégralement la dernière phrase du tail → score 1.0.
        let s = OutputFilter.echoScore(ghost: "la vérité est belle",
                                       tail: "Bonjour. la vérité est belle")
        #expect(s >= OutputFilter.continuationEchoThreshold)
        #expect(s == 1.0)
    }

    @Test func echoScoreLowWhenContinuationIsFresh() {
        // Suite distincte → quasi aucun mot commun → sous le seuil.
        let s = OutputFilter.echoScore(ghost: ", la vérité est première",
                                       tail: "Dans la philo on cherche")
        #expect(s < OutputFilter.continuationEchoThreshold)
    }

    @Test func echoScoreZeroForEmptyGhost() {
        #expect(OutputFilter.echoScore(ghost: "", tail: "quoi que ce soit") == 0)
    }

    @Test func echoScoreUsesOnlyLastSentence() {
        // Le recouvrement ne porte que sur la DERNIÈRE phrase : un mot répété dans
        // une phrase ANTÉRIEURE ne compte pas.
        let s = OutputFilter.echoScore(ghost: "fraises rouges",
                                       tail: "Les fraises sont mûres. on mange")
        #expect(s < OutputFilter.continuationEchoThreshold)
    }

    // MARK: - languageMismatch

    @Test func languageMismatchFalseWhenFrenchGhostFrenchExpected() {
        #expect(!OutputFilter.languageMismatch(ghost: ", la vérité est première", expected: "fr"))
    }

    @Test func languageMismatchTrueWhenEnglishGhostFrenchExpected() {
        #expect(OutputFilter.languageMismatch(ghost: ", the truth is always first", expected: "fr"))
    }

    @Test func languageMismatchFailOpenOnShortFragment() {
        // Trop court (< languageGuardMinChars) → fail-open, jamais de mismatch.
        #expect(!OutputFilter.languageMismatch(ghost: "is", expected: "fr"))
    }

    @Test func languageMismatchFailOpenWhenExpectedNil() {
        #expect(!OutputFilter.languageMismatch(ghost: "the truth is first", expected: nil))
    }

}
