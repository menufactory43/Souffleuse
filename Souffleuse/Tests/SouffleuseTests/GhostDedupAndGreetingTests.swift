import Testing
import Foundation
import SouffleusePersonalization
import SouffleuseTyping
import SouffleuseCore
@testable import Souffleuse

// Trois correctifs ghost/personnalisation (2026-05-30) :
//   1. Anti-répétition de contenu (`dedupLeadingRepeat`) — le ghost ne redonne
//      plus le mot déjà tapé (« redit bonjour »).
//   2. Recall verbatim restreint à `.prose` — les fragments `.accept` ne sont
//      plus rejoués tels quels par `routeInstant` (ils restent pour le n-gram).
//   3. Filtre salutations (`isGreetingLike`) — les entrées prose « juste une
//      salutation » sont retirées du pool de démonstration few-shot.

// MARK: - dedupLeadingRepeat

@Suite("Anti-répétition — dedupLeadingRepeat")
struct DedupLeadingRepeatTests {

    /// Le repro : mot complet tapé sans séparateur, le ghost le redonne. On
    /// rogne « bonjour » et on garde le séparateur du ghost (« , comment… »).
    @Test func stripsRepeatedCompleteWordKeepingGhostSeparator() {
        let out = SuggestionPolicy.dedupLeadingRepeat(
            ghost: "bonjour, comment allez-vous",
            userTail: "Je voulais dire bonjour")
        #expect(out == ", comment allez-vous")
    }

    /// Insensible à la casse, dans les deux sens.
    @Test func caseInsensitiveBothDirections() {
        #expect(SuggestionPolicy.dedupLeadingRepeat(
            ghost: "Bonjour le monde", userTail: "salut bonjour") == " le monde")
        #expect(SuggestionPolicy.dedupLeadingRepeat(
            ghost: "bonjour ça va", userTail: "Bonjour") == " ça va")
    }

    /// Continuation mid-mot légitime : « bonj » → « our ». Le premier mot du
    /// ghost diffère du partiel ⇒ JAMAIS rogné (protège le token-healing).
    @Test func midWordContinuationIsNeverStripped() {
        #expect(SuggestionPolicy.dedupLeadingRepeat(
            ghost: "our comment", userTail: "bonj") == "our comment")
    }

    /// Healing « mot entier » : « bonj » → ghost « bonjour ». « bonjour » ≠
    /// « bonj » ⇒ pas une répétition, passe intact.
    @Test func healedWholeWordIsNotStripped() {
        #expect(SuggestionPolicy.dedupLeadingRepeat(
            ghost: "bonjour", userTail: "bonj") == "bonjour")
    }

    /// Le ghost n'est QUE la répétition ⇒ "" (le caller le saute / fallback).
    @Test func pureRepeatCollapsesToEmpty() {
        #expect(SuggestionPolicy.dedupLeadingRepeat(
            ghost: "bonjour", userTail: "dis bonjour") == "")
    }

    /// Caret après un espace : l'utilisateur a déjà tapé le séparateur, on
    /// retire celui du ghost (pas de double espace).
    @Test func afterSpaceDropsGhostSeparator() {
        #expect(SuggestionPolicy.dedupLeadingRepeat(
            ghost: "bonjour comment", userTail: "bonjour ") == "comment")
    }

    /// Caret après une ponctuation non-espace : on réinsère un espace pour ne
    /// pas coller (« bonjour, » + « comment » → « bonjour, comment »).
    @Test func afterPunctuationReinsertsSpace() {
        #expect(SuggestionPolicy.dedupLeadingRepeat(
            ghost: "bonjour comment", userTail: "bonjour,") == " comment")
    }

    /// Pas de répétition ⇒ verbatim.
    @Test func nonRepeatingGhostIsVerbatim() {
        #expect(SuggestionPolicy.dedupLeadingRepeat(
            ghost: "comment allez-vous", userTail: "bonjour") == "comment allez-vous")
    }

    /// Répétition d'un nombre (« 2024 »).
    @Test func digitWordRepeatIsStripped() {
        #expect(SuggestionPolicy.dedupLeadingRepeat(
            ghost: "2024 budget", userTail: "année 2024") == " budget")
    }

    /// Le séparateur propre au ghost (virgule) est préservé quand le caret est
    /// collé au mot.
    @Test func keepsGhostPunctuationWhenCaretGlued() {
        #expect(SuggestionPolicy.dedupLeadingRepeat(
            ghost: "bonjour, ça va ?", userTail: "bonjour") == ", ça va ?")
    }

    /// Garde-fous : ghost ou userTail vides → passthrough.
    @Test func emptyInputsPassthrough() {
        #expect(SuggestionPolicy.dedupLeadingRepeat(ghost: "", userTail: "bonjour") == "")
        #expect(SuggestionPolicy.dedupLeadingRepeat(ghost: "bonjour", userTail: "") == "bonjour")
    }

    /// #1 — Après un espace tapé, on ne retire QU'UN espace de tête : une
    /// ponctuation ouvrante signifiante (guillemets, parenthèse) est préservée.
    @Test func preservesOpeningPunctuationAfterSpace() {
        #expect(SuggestionPolicy.dedupLeadingRepeat(
            ghost: "projet « Souffleuse »", userTail: "le projet ") == "« Souffleuse »")
        #expect(SuggestionPolicy.dedupLeadingRepeat(
            ghost: "budget (révisé)", userTail: "le budget ") == "(révisé)")
    }
}

// MARK: - Re-score anti-freeze (#2)

@MainActor
@Suite("Régression — re-score du ghost dédupliqué (anti-freeze stream)")
struct DedupRescoreTests {

    /// Le score du texte dédupliqué (ce qui est AFFICHÉ) est strictement plus
    /// bas que celui du chunk brut — racine du gel : stocker le score brut
    /// gonfle `currentScore` et la barre de remplacement bloque la suite.
    @Test func dedupedGhostScoresLowerThanRawChunk() {
        let tail = "Je voulais dire bonjour"
        let raw = "bonjour comment"
        let deduped = SuggestionPolicy.dedupLeadingRepeat(ghost: raw, userTail: tail)
        #expect(deduped != raw)
        let rawScore = SuggestionPolicy.score(source: .llm, ghost: raw, userTail: tail)
        let dedupedScore = SuggestionPolicy.score(source: .llm, ghost: deduped, userTail: tail)
        #expect(dedupedScore.value < rawScore.value)
    }

    /// Avec le score CORRECT (celui du texte affiché), l'extension du stream
    /// suivant est admise — le ghost ne gèle pas sur le premier bout.
    @Test func reScoredGhostAdmitsStreamExtension() {
        let engine = SuggestionPolicyEngine(maxWords: 16)
        let tail = "Je voulais dire bonjour"
        let deduped = SuggestionPolicy.dedupLeadingRepeat(ghost: "bonjour comment", userTail: tail)
        let correctScore = SuggestionPolicy.score(source: .llm, ghost: deduped, userTail: tail)
        engine.applyGhost(deduped, source: .llm, score: correctScore)
        let ext = engine.onLLMChunk("bonjour comment allez-vous", userTail: tail)
        #expect(ext != nil)
    }
}

// MARK: - isGreetingLike

@Suite("Filtre salutations — isGreetingLike")
struct IsGreetingLikeTests {

    @Test func bareOpenersAreGreetingLike() {
        #expect(SuggestionPolicy.isGreetingLike("Coucou"))
        #expect(SuggestionPolicy.isGreetingLike("Salut !"))
        #expect(SuggestionPolicy.isGreetingLike("Bonjour"))
        #expect(SuggestionPolicy.isGreetingLike("Hello"))
        #expect(SuggestionPolicy.isGreetingLike("Hey"))
    }

    @Test func openerPlusShortNameIsGreetingLike() {
        #expect(SuggestionPolicy.isGreetingLike("Bonjour Gabriel"))
        #expect(SuggestionPolicy.isGreetingLike("Bonjour Madame,"))
    }

    @Test func openerPlusTitleIsGreetingLike() {
        #expect(SuggestionPolicy.isGreetingLike("Chère Madame"))
        #expect(SuggestionPolicy.isGreetingLike("Cher Monsieur"))
    }

    @Test func substantiveOpenerIsKept() {
        #expect(!SuggestionPolicy.isGreetingLike(
            "Bonjour Madame, je vous écris au sujet de la facture impayée"))
        #expect(!SuggestionPolicy.isGreetingLike(
            "Salut, on se voit demain pour le déjeuner à midi"))
        #expect(!SuggestionPolicy.isGreetingLike(
            "Re: votre demande de remboursement du mois dernier"))
    }

    @Test func midSentenceGreetingIsKept() {
        #expect(!SuggestionPolicy.isGreetingLike("Je voulais juste dire bonjour"))
    }

    @Test func emptyIsGreetingLike() {
        #expect(SuggestionPolicy.isGreetingLike(""))
        #expect(SuggestionPolicy.isGreetingLike("   "))
    }

    /// #4 — « Re: … » (objet d'e-mail) n'est PAS une salutation : ces réponses
    /// courtes restent dans le pool few-shot.
    @Test func replyPrefixIsKept() {
        #expect(!SuggestionPolicy.isGreetingLike("Re: ok pour demain"))
        #expect(!SuggestionPolicy.isGreetingLike("Re renvoie le fichier"))
    }
}

// MARK: - routeInstant : recall prose-only

@MainActor
@Suite("Recall verbatim — prose-only (les .accept ne sont plus rejoués)")
struct RecallProseOnlyTests {

    static func entry(_ accepted: String, source: EntrySource) -> TypingHistoryEntry {
        TypingHistoryEntry(timestamp: Date(), contextBefore: "", accepted: accepted,
                           bundleID: nil, source: source)
    }

    /// Une entrée `.accept` qui matcherait le tail n'est PAS rappelée.
    @Test func acceptFragmentIsNotRecalled() {
        let engine = SuggestionPolicyEngine(maxWords: 16)
        let snap = [Self.entry("Bien cordialement, Jean Dupont", source: .accept)]
        let r = engine.routeInstant(
            userTail: "Bien cordialement, ",
            historySnapshot: snap,
            wordCompleter: WordCompleter())
        #expect(r == nil)
    }

    /// La même entrée en `.prose` déclenche bien le fast-path.
    @Test func proseEntryIsRecalled() {
        let engine = SuggestionPolicyEngine(maxWords: 16)
        let snap = [Self.entry("Bien cordialement, Jean Dupont", source: .prose)]
        let r = engine.routeInstant(
            userTail: "Bien cordialement, ",
            historySnapshot: snap,
            wordCompleter: WordCompleter())
        #expect(r?.source == .history)
        #expect(r?.text.contains("Jean") == true)
    }

    /// Snapshot mixte : l'`.accept` est ignoré, la `.prose` gagne.
    @Test func mixedSnapshotPrefersProse() {
        let engine = SuggestionPolicyEngine(maxWords: 16)
        let snap = [
            Self.entry("Bien cordialement, Pierre Martin", source: .accept),
            Self.entry("Bien cordialement, Jean Dupont", source: .prose),
        ]
        let r = engine.routeInstant(
            userTail: "Bien cordialement, ",
            historySnapshot: snap,
            wordCompleter: WordCompleter())
        #expect(r?.text.contains("Jean") == true)
        #expect(r?.text.contains("Pierre") == false)
    }
}
