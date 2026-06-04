import Testing
import Foundation
import SouffleuseTyping
import SouffleuseCore

/// Verrouille `WordBoundary` — la primitive de frontière de mot désormais UNIQUE.
/// Avant, `isWordChar` était redéfini dans 6 modules et avait drifté :
/// `TypingHistoryStore` avait perdu l'apostrophe courbe `’` (U+2019). Ces tests
/// fixent la définition de référence ET la cohérence inter-modules.
@Suite("WordBoundary — primitive unique de frontière de mot")
struct WordBoundaryTests {

    @Test("isWordChar : lettres, chiffres, et les 3 joiners intra-mot")
    func wordChars() {
        #expect(WordBoundary.isWordChar("a"))
        #expect(WordBoundary.isWordChar("é"))
        #expect(WordBoundary.isWordChar("7"))
        #expect(WordBoundary.isWordChar("'"))          // apostrophe droite U+0027
        #expect(WordBoundary.isWordChar("\u{2019}"))   // apostrophe courbe U+2019 ’ — le bug
        #expect(WordBoundary.isWordChar("-"))
    }

    @Test("isWordChar : espaces et ponctuation = frontières")
    func nonWordChars() {
        #expect(!WordBoundary.isWordChar(" "))
        #expect(!WordBoundary.isWordChar("."))
        #expect(!WordBoundary.isWordChar(","))
        #expect(!WordBoundary.isWordChar("\n"))
    }

    @Test("l'apostrophe courbe ne coupe PAS le mot (régression du bug `’`)")
    func curlyApostropheKeepsWordTogether() {
        // Mot à élision avec apostrophe typographique macOS : doit rester d'un bloc.
        #expect(WordBoundary.trailingPartialWord("je suis d\u{2019}accord") == "d\u{2019}accord")
        #expect(WordBoundary.leadingWordRun("d\u{2019}accord, oui") == "d\u{2019}accord")
        // Apostrophe droite : même résultat.
        #expect(WordBoundary.trailingPartialWord("je suis d'accord") == "d'accord")
    }

    @Test("trailing/leading vides au bord d'un espace")
    func emptyAtBoundary() {
        #expect(WordBoundary.trailingPartialWord("bonjour ") == "")
        #expect(WordBoundary.leadingWordRun(" bonjour") == "")
    }

    @Test("cohérence inter-modules : OutputFilter délègue à la même primitive")
    func crossModuleConsistency() {
        // OutputFilter.isWordChar partage désormais WordBoundary → ne peut plus
        // diverger. On le vérifie sur le caractère qui avait justement drifté.
        for c: Character in ["a", "é", "7", "'", "\u{2019}", "-", " ", ".", "\n"] {
            #expect(OutputFilter.isWordChar(c) == WordBoundary.isWordChar(c))
        }
        // Et la primitive partagée préserve bien l'apostrophe courbe à travers
        // l'API publique d'OutputFilter (mêmes helpers que le store consomme).
        #expect(OutputFilter.trailingPartialWord("c\u{2019}est d\u{2019}accord") == "d\u{2019}accord")
    }
}
