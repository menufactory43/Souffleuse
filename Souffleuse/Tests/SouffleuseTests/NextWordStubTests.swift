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

    @Test("mid-word single letter (caret inside a word) → not a stub")
    func midWordSingleLetterExempt() {
        // "Bonjou" + "r" → finishes the word; the userTail ends in a letter so
        // the boundary guard does not fire — keep the completion.
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
}
