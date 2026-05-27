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

    // MARK: - midWordContinuation flag overload

    @Test("flag=true glues even when merged word is invalid")
    func flagTrueGlues() {
        // "vér" + "ifi" would be joined with space by the heuristic (vérifi invalid)
        // but flag=true forces a glue — the user KNOWS it was mid-word.
        #expect(
            SuggestionPolicy.joinHistory(
                "Merci beaucoup pour votre vér", "ifi",
                midWordContinuation: true
            ) == "Merci beaucoup pour votre vérifi"
        )
    }

    @Test("flag=false spaces even when merge would form a valid word")
    func flagFalseSpaces() {
        // "obte" + "nir" would glue (obtenir is valid) but flag=false forces a space.
        #expect(
            SuggestionPolicy.joinHistory("obte", "nir", midWordContinuation: false)
            == "obte nir"
        )
    }

    @Test("flag=nil matches the 2-arg heuristic")
    func flagNilMatchesHeuristic() {
        // nil falls back to the dictionary heuristic — same result as 2-arg form.
        let twoArg = SuggestionPolicy.joinHistory("obte", "nir")
        let nilArg = SuggestionPolicy.joinHistory("obte", "nir", midWordContinuation: nil)
        #expect(nilArg == twoArg)
        #expect(nilArg == "obtenir")
    }

    @Test("existing separator is never doubled regardless of flag")
    func existingSeparatorNeverDoubled() {
        // Even with flag=false, if a separator already exists at the boundary,
        // just concat verbatim (no double space).
        #expect(
            SuggestionPolicy.joinHistory("les frais ", "de port", midWordContinuation: false)
            == "les frais de port"
        )
    }
}
