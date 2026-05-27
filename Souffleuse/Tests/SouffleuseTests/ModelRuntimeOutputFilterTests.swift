import Testing
import Foundation
import SouffleuseCore
@testable import Souffleuse

/// Phase 4 / 04-05 — pure-function lock-in pour `ModelRuntime.OutputFilter`.
///
/// Ces tests verrouillent la sémantique des 6 helpers TELLE QU'ELLE EST
/// DANS PVM aujourd'hui (copies verbatim depuis PVM:247-375). Si un test
/// échoue, c'est soit que la copie OutputFilter diverge du verbatim PVM
/// (bug 04-05 Task 1), soit que le legacy a évolué entre temps et la copie
/// est restée — dans ce cas, harmoniser AVANT de toucher l'attendu.
///
/// **Couverture** : ≥1 cas nominal + ≥1 edge case par fonction (6 fonctions
/// × 2 = ≥12 tests).
@Suite("Phase 4 — ModelRuntime.OutputFilter pure functions")
struct ModelRuntimeOutputFilterTests {

    typealias Filter = ModelRuntime.OutputFilter

    // MARK: - stripPrefixOverlap

    @Test func stripPrefixOverlapBasic() {
        // prefix tail "Coucou," matches start of snapshot → drop 7 chars
        let r = Filter.stripPrefixOverlap("Coucou,bravo", prefix: "Coucou,")
        #expect(r == "bravo")
    }

    @Test func stripPrefixOverlapNoOverlap() {
        // Aucune correspondance ≥ 2 chars → snapshot retourné inchangé
        let r = Filter.stripPrefixOverlap("Salut", prefix: "Bonjour ")
        #expect(r == "Salut")
    }

    @Test func stripPrefixOverlapEmptyGhost() {
        // maxLen == 0 → retour direct
        let r = Filter.stripPrefixOverlap("", prefix: "abc")
        #expect(r == "")
    }

    @Test func stripPrefixOverlapEmptyPrefix() {
        // maxLen == 0 → snapshot inchangé
        let r = Filter.stripPrefixOverlap("hello", prefix: "")
        #expect(r == "hello")
    }

    // MARK: - ghostIsRepeatingPrefix

    @Test func ghostIsRepeatingPrefixTrueOnEcho() {
        // prefix se termine par "votre commande", ghost commence par
        // "votre commande" → echo détecté après stripTrailingPartialWord
        // qui retire le "ge" courant ; normalizeForRepeatCheck égalise les
        // espaces.
        let r = Filter.ghostIsRepeatingPrefix(
            "votre commande arrive bientôt",
            prefix: "...je vais traiter votre commande ge"
        )
        #expect(r == true)
    }

    @Test func ghostIsRepeatingPrefixFalseOnContinuation() {
        // ghost = "monde aujourd'hui", prefix = "Bonjour " → pas d'echo
        let r = Filter.ghostIsRepeatingPrefix(
            "monde aujourd'hui",
            prefix: "Bonjour "
        )
        #expect(r == false)
    }

    @Test func ghostIsRepeatingPrefixFalseTooShort() {
        // ghost normalisé < 5 chars → guard renvoie false
        let r = Filter.ghostIsRepeatingPrefix("hi", prefix: "Coucou,")
        #expect(r == false)
    }

    // MARK: - hasCompletedFirstWord

    @Test func hasCompletedFirstWordTrueOnSpace() {
        // "Bonjour " : word→separator transition après "Bonjour"
        #expect(Filter.hasCompletedFirstWord("Bonjour ") == true)
    }

    @Test func hasCompletedFirstWordTrueOnPunctuation() {
        // "Bonjour," : virgule = séparateur
        #expect(Filter.hasCompletedFirstWord("Bonjour,") == true)
    }

    @Test func hasCompletedFirstWordFalseMidWord() {
        // "Bonjou" : aucune transition word→separator
        #expect(Filter.hasCompletedFirstWord("Bonjou") == false)
    }

    @Test func hasCompletedFirstWordFalseEmptyString() {
        // Pas de char → pas de transition
        #expect(Filter.hasCompletedFirstWord("") == false)
    }

    @Test func hasCompletedFirstWordApostropheStaysInWord() {
        // "l'app" : ' compte comme word-char → aucune transition
        #expect(Filter.hasCompletedFirstWord("l'app") == false)
    }

    // MARK: - stripTrailingPartialWord

    @Test func stripTrailingPartialWordBasic() {
        // "Bonjour mond" : drop "mond" → "Bonjour "
        #expect(Filter.stripTrailingPartialWord("Bonjour mond") == "Bonjour ")
    }

    @Test func stripTrailingPartialWordOnPunctuation() {
        // "Bonjour, " : trailing space n'est pas word-char → inchangé
        #expect(Filter.stripTrailingPartialWord("Bonjour, ") == "Bonjour, ")
    }

    @Test func stripTrailingPartialWordEmptyString() {
        #expect(Filter.stripTrailingPartialWord("") == "")
    }

    @Test func stripTrailingPartialWordSingleWord() {
        // "hello" : tout le mot est word-char → drop tout
        #expect(Filter.stripTrailingPartialWord("hello") == "")
    }

    // MARK: - normalizeForRepeatCheck

    @Test func normalizeForRepeatCheckLowercasesAndCollapses() {
        // "Bonjour, Je" → "bonjour je"
        #expect(Filter.normalizeForRepeatCheck("Bonjour, Je") == "bonjour je")
    }

    @Test func normalizeForRepeatCheckCollapsesMultiplePunctuation() {
        // "Bonjour,,, je" : 3 virgules → 1 espace
        #expect(Filter.normalizeForRepeatCheck("Bonjour,,, je") == "bonjour je")
    }

    @Test func normalizeForRepeatCheckTrimsEdges() {
        // Espace en début/fin → trimmé
        #expect(Filter.normalizeForRepeatCheck("  hello  ") == "hello")
    }

    @Test func normalizeForRepeatCheckEmptyString() {
        #expect(Filter.normalizeForRepeatCheck("") == "")
    }

    // MARK: - capToWords

    @Test func capToWordsRespectsWordLimit() {
        // 6 mots → cap à 3
        #expect(Filter.capToWords("a b c d e f", max: 3) == "a b c")
    }

    @Test func capToWordsBelowLimitUnchanged() {
        // 2 mots, cap 5 → inchangé (pas de terminator, pas de virgule)
        #expect(Filter.capToWords("a b", max: 5) == "a b")
    }

    @Test func capToWordsCutsOnSentenceTerminator() {
        // Le terminator ". " coupe avant le word-cap.
        // Input length > 3, terminator ". " détecté → coupe après le point.
        let r = Filter.capToWords("Bonjour. Comment ça va aujourd'hui", max: 20)
        #expect(r == "Bonjour.")
    }

    @Test func capToWordsKeepsCommaForNaturalGhost() {
        // Cotypist parity : punctuation is KEPT — the comma no longer truncates.
        // No sentence terminator, 6 words ≤ cap 20 → unchanged, comma preserved.
        let r = Filter.capToWords("Bonjour cher ami, comment ça va", max: 20)
        #expect(r == "Bonjour cher ami, comment ça va")
    }

    @Test func capToWordsKeepsCommaThenCapsByWordCount() {
        // Comma kept, but the word cap still bounds length: "de manger, je
        // crois bien que oui" capped to 4 words → "de manger, je crois".
        let r = Filter.capToWords("de manger, je crois bien que oui", max: 4)
        #expect(r == "de manger, je crois")
    }

    @Test func capToWordsPreservesLeadingSpaceAcrossTerminatorCut() {
        // Next-word continuation after a complete word keeps its leading space:
        // " de port. Mais" → " de port." (NOT "de port."), so the ghost renders
        // "frais de port." not "fraisde port.".
        let r = Filter.capToWords(" de port. Mais il", max: 20)
        #expect(r == " de port.")
    }

    @Test func capToWordsShortStringIgnoresTerminator() {
        // length <= 3 → la branche terminator est skipée.
        // "a. b" length=4 > 3 → terminator-branch s'applique : coupe après "a."
        // Edge case du PVM verbatim (length > 3 strict).
        let short = Filter.capToWords("hi.", max: 5)
        // length=3, branch terminator skipée, pas de virgule, 1 word → inchangé
        #expect(short == "hi.")
    }

    // MARK: - normalizeFrenchTypography

    @Test func frenchTypographyInsertsSpaceBeforeMarks() {
        #expect(Filter.normalizeFrenchTypography("produit:") == "produit :")
        #expect(Filter.normalizeFrenchTypography("comment?") == "comment ?")
        #expect(Filter.normalizeFrenchTypography("vraiment!") == "vraiment !")
        #expect(Filter.normalizeFrenchTypography("attention;suite") == "attention ;suite")
    }

    @Test func frenchTypographyIsIdempotent() {
        // Already-spaced marks are left untouched (no double space).
        #expect(Filter.normalizeFrenchTypography("produit :") == "produit :")
        #expect(Filter.normalizeFrenchTypography("forts de ce produit :") == "forts de ce produit :")
    }

    @Test func frenchTypographyLeavesLeadingMarkUntouched() {
        // A ghost that STARTS with a mark has no preceding char → out of scope
        // (the boundary case depends on upstream user text, handled elsewhere).
        #expect(Filter.normalizeFrenchTypography("?") == "?")
        #expect(Filter.normalizeFrenchTypography(": voici") == ": voici")
    }

    @Test func frenchTypographySkipsTimesRatiosURLs() {
        // Digit-adjacent and URL/ratio colons must NOT gain a space.
        #expect(Filter.normalizeFrenchTypography("14:30") == "14:30")
        #expect(Filter.normalizeFrenchTypography("http://site") == "http://site")
        #expect(Filter.normalizeFrenchTypography("ratio 3:1") == "ratio 3:1")
    }

    @Test func frenchTypographyEmptyAndNoMarks() {
        #expect(Filter.normalizeFrenchTypography("") == "")
        #expect(Filter.normalizeFrenchTypography("bonjour tout le monde") == "bonjour tout le monde")
    }
}
