import Testing
@testable import SouffleuseCore

/// Guards `SuggestionPolicy.joinHistory` — the word-aware reconstruction of a
/// history entry's continuous text from its stored `contextBefore` + (trimmed)
/// `accepted`. Regression for the live "vend redi" / "liquida tion" bug, where
/// a forced space corrupted mid-word accepts.
@Suite("History entry join (word-aware)")
struct HistoryJoinTests {

    @Test("mid-word accept glues with no space (the bug fix)")
    func midWordGlues() {
        // "…vend" + "redi" → "vendredi", NOT "vend redi".
        #expect(SuggestionPolicy.joinHistory("ça sera corrigé vend", "redi")
                == "ça sera corrigé vendredi")
        #expect(SuggestionPolicy.joinHistory("C'est une liquida", "tion")
                == "C'est une liquidation")
        #expect(SuggestionPolicy.joinHistory("obte", "nir") == "obtenir")
    }

    @Test("next-word accept (merged is not a word) inserts a space")
    func nextWordSpaces() {
        // "…le" + "montant" → "le montant" (lemontant is not a word).
        #expect(SuggestionPolicy.joinHistory("mais le", "montant est")
                == "mais le montant est")
        #expect(SuggestionPolicy.joinHistory("Bonjour", "Madame") == "Bonjour Madame")
    }

    @Test("existing whitespace boundary is preserved (no double space)")
    func whitespaceBoundaryConcat() {
        #expect(SuggestionPolicy.joinHistory("les frais ", "de port") == "les frais de port")
        #expect(SuggestionPolicy.joinHistory("Bonjour ", "Madame") == "Bonjour Madame")
    }

    @Test("empty contextBefore returns accepted unchanged")
    func emptyContext() {
        #expect(SuggestionPolicy.joinHistory("", "bonjour") == "bonjour")
    }

    @Test("punctuation boundary before a new word gets a space")
    func punctuationBoundary() {
        #expect(SuggestionPolicy.joinHistory("corrigé.", "Bonjour") == "corrigé. Bonjour")
    }
}
