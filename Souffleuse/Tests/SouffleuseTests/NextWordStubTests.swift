import Testing
@testable import Souffleuse

/// Guards the single-letter next-word stub suppression (the "m" ghost bug).
///
/// Repro: after "J'aime les fraises, j'ai envie de " the base model produces
/// junk (repeated "fraises", `<strong>` tags). The corpus bias flips only the
/// FIRST token toward "m" (manger), the rest is gated out, leaving a lone "m"
/// ghost. One letter at a word boundary conveys no intent → suppress it and
/// wait for ≥2 chars. Mid-word completions ("Bonjou" → "r") are exempt.
@MainActor
@Suite("Next-word single-letter stub suppression")
struct NextWordStubTests {

    @Test("lone letter at a word boundary (after space) → stub")
    func stubAfterSpace() {
        #expect(PredictorViewModel.isNextWordStub(userTail: "J'ai envie de ", ghost: "m") == true)
    }

    @Test("lone letter with a leading-space marker → stub")
    func stubWithLeadingSpace() {
        // The next-word continuation marker (leading space) is ignored when
        // measuring length: " m" is still a one-letter stub.
        #expect(PredictorViewModel.isNextWordStub(userTail: "J'ai envie", ghost: " m") == true)
    }

    @Test("two or more chars at a word boundary → not a stub")
    func twoCharsKept() {
        #expect(PredictorViewModel.isNextWordStub(userTail: "J'ai envie ", ghost: "de manger") == false)
        #expect(PredictorViewModel.isNextWordStub(userTail: "J'ai envie", ghost: " de") == false)
    }

    @Test("mid-word single letter is not a NEXT-WORD stub (isMidWordStub's job)")
    func midWordSingleLetterNotNextWord() {
        // The boundary guard never fires mid-word; the mid-word single-char case
        // is handled by isMidWordStub (tested below). At the call site the two
        // are OR-ed.
        #expect(PredictorViewModel.isNextWordStub(userTail: "Bonjou", ghost: "r") == false)
    }

    @Test("empty userTail is a word boundary → lone letter is a stub")
    func emptyTailBoundary() {
        #expect(PredictorViewModel.isNextWordStub(userTail: "", ghost: "m") == true)
    }

    @Test("after punctuation (no space) → boundary, lone letter is a stub")
    func afterPunctuation() {
        #expect(PredictorViewModel.isNextWordStub(userTail: "Bonjour,", ghost: "m") == true)
    }

    // MARK: - Mid-word single-char stub (the "opé"→"r" / "dp"→"n" bug)

    @Test("lone char continuing a word → mid-word stub")
    func midWordLoneCharIsStub() {
        // "…d'opé" + "r" and "C'est un dp" + "n" — a single mid-word char is the
        // first streamed token / confused output, unreadable as intent.
        #expect(PredictorViewModel.isMidWordStub(userTail: "Pouvez-vous m'indiquer quels types d'opé", ghost: "r") == true)
        #expect(PredictorViewModel.isMidWordStub(userTail: "C'est un dp", ghost: "n") == true)
        #expect(PredictorViewModel.isMidWordStub(userTail: "Bonjou", ghost: "r") == true)
    }

    @Test("two or more mid-word chars → not a stub")
    func midWordTwoCharsKept() {
        #expect(PredictorViewModel.isMidWordStub(userTail: "d'opé", ghost: "rations") == false)
        #expect(PredictorViewModel.isMidWordStub(userTail: "Bonjou", ghost: "rs") == false)
    }

    @Test("word-boundary lone char is NOT a mid-word stub (isNextWordStub's job)")
    func boundaryNotMidWord() {
        #expect(PredictorViewModel.isMidWordStub(userTail: "J'ai envie de ", ghost: "m") == false)
        #expect(PredictorViewModel.isMidWordStub(userTail: "Bonjour,", ghost: "m") == false)
        #expect(PredictorViewModel.isMidWordStub(userTail: "", ghost: "m") == false)
    }

    @Test("next-word (leading-space) lone char is NOT a mid-word stub")
    func leadingSpaceNotMidWord() {
        // Even with a letter-ending userTail, a leading-space ghost is a
        // next-word continuation → isNextWordStub's domain, not this one.
        #expect(PredictorViewModel.isMidWordStub(userTail: "J'ai envie", ghost: " m") == false)
    }
}
