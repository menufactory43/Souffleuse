import Testing
import Foundation
import SouffleusePersonalization

/// Couvre le lexique personnel L0 : un terme distinctif appris (« Binance ») doit
/// se compléter depuis son préfixe capitalisé, et les gates (majuscule, freq,
/// longueur, distinctivité) doivent écarter les faux positifs.
@Suite("LearnedLexicon — complétion de termes distinctifs appris")
struct LearnedLexiconTests {

    /// Le 1ᵉʳ mot du contexte fait ≥2 lettres → le terme n'est PAS vu comme
    /// début de phrase, donc sa majuscule compte comme « milieu de phrase ».
    private func entry(_ ctx: String, _ acc: String) -> TypingHistoryEntry {
        TypingHistoryEntry(
            timestamp: Date(timeIntervalSince1970: 0),
            contextBefore: ctx, accepted: acc, bundleID: nil
        )
    }

    @Test("« Bin » → « ance » quand Binance a été appris (≥2×, milieu de phrase)")
    func surfacesLearnedTerm() {
        let lex = LearnedLexicon.build(from: [
            entry("je passe par", "Binance"),
            entry("mon compte", "Binance"),
            entry("transféré vers", "Binance"),
        ])
        #expect(lex.completion(for: "Bin") == "ance")
        #expect(lex.completion(for: "Bina") == "nce")
    }

    @Test("préfixe minuscule rejeté (garde-fou nom propre)")
    func lowercasePrefixRejected() {
        let lex = LearnedLexicon.build(from: [
            entry("je passe par", "Binance"), entry("mon compte", "Binance"),
        ])
        #expect(lex.completion(for: "bin") == nil)
    }

    @Test("une seule occurrence (freq<2) ne suffit pas")
    func belowMinFreqRejected() {
        let lex = LearnedLexicon.build(from: [entry("je passe par", "Binance")])
        #expect(lex.completion(for: "Bin") == nil)
    }

    @Test("préfixe < 3 lettres rejeté")
    func shortPrefixRejected() {
        let lex = LearnedLexicon.build(from: [
            entry("je paye en", "Binance"), entry("je vends sur", "Binance"),
        ])
        #expect(lex.completion(for: "Bi") == nil)
    }

    @Test("mot courant minuscule jamais appris (pas distinctif)")
    func commonLowercaseWordNotLearned() {
        let lex = LearnedLexicon.build(from: [
            entry("je dis", "merci beaucoup"), entry("vraiment", "merci encore"),
        ])
        #expect(lex.completion(for: "Mer") == nil)
        #expect(lex.completion(for: "mer") == nil)
    }

    @Test("majuscule uniquement en début de phrase → pas distinctif")
    func sentenceInitialCapitalNotLearned() {
        let lex = LearnedLexicon.build(from: [
            entry("", "Bonjour comment allez vous"),
            entry("", "Bonjour monsieur le directeur"),
        ])
        #expect(lex.completion(for: "Bon") == nil)
    }

    @Test("stoplist : un mot courant capitalisé (Monsieur) n'est pas appris, Binance oui")
    func stoplistExcludesCommonWords() {
        let lex = LearnedLexicon.build(from: [
            entry("je passe par", "Binance"), entry("mon compte", "Binance"),
            entry("réponse à", "Monsieur Dupont"), entry("écrit à", "Monsieur Martin"),
        ])
        #expect(lex.completion(for: "Bin") == "ance")   // distinctif → gardé
        #expect(lex.completion(for: "Mon") == nil)        // « Monsieur » en stoplist → écarté
    }

    @Test("lexique vide → aucune complétion")
    func emptyLexicon() {
        #expect(LearnedLexicon().completion(for: "Bin") == nil)
        #expect(LearnedLexicon.build(from: []).completion(for: "Bin") == nil)
    }
}
