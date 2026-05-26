import Testing
@testable import SouffleuseTyping

// Pure-function tests for ChunkSplitter — covers the chunking rules used by
// the word-by-word Tab acceptance flow.

@Test func chunkSplitsFirstWordWithTrailingSpace() {
    #expect(ChunkSplitter.nextChunk("Je m'appelle Gabriel", trailingSpace: true) == "Je ")
}

@Test func chunkSplitsFirstWordWithoutTrailingSpace() {
    #expect(ChunkSplitter.nextChunk("Je m'appelle Gabriel", trailingSpace: false) == "Je")
}

@Test func chunkKeepsApostropheInsideWord() {
    // m'appelle is one word — apostrophe is part of word.
    #expect(ChunkSplitter.nextChunk("m'appelle Gabriel", trailingSpace: true) == "m'appelle ")
}

@Test func chunkKeepsCurlyApostropheInsideWord() {
    // Typographic apostrophe U+2019 should behave like ASCII '.
    #expect(ChunkSplitter.nextChunk("l\u{2019}été prochain", trailingSpace: true) == "l\u{2019}été ")
}

@Test func chunkKeepsHyphenInsideWord() {
    #expect(ChunkSplitter.nextChunk("peut-être demain", trailingSpace: true) == "peut-être ")
}

@Test func chunkConsumesTrailingPunctuation() {
    // The comma sticks to "Gabriel"; the space after the comma is the
    // trailing-space option.
    #expect(ChunkSplitter.nextChunk("Gabriel, ravi", trailingSpace: true) == "Gabriel, ")
    #expect(ChunkSplitter.nextChunk("Gabriel, ravi", trailingSpace: false) == "Gabriel,")
}

@Test func chunkConsumesMultiplePunctuationGreedily() {
    // !?  → keep both, plus optional trailing space.
    #expect(ChunkSplitter.nextChunk("vraiment?! demain", trailingSpace: true) == "vraiment?! ")
}

@Test func chunkPunctuationOnly() {
    // No word, just trailing punctuation — return it.
    #expect(ChunkSplitter.nextChunk(".", trailingSpace: true) == ".")
    #expect(ChunkSplitter.nextChunk("…", trailingSpace: false) == "…")
}

@Test func chunkLeadingWhitespacePreserved() {
    // A leading space is included so the caret advances past it.
    #expect(ChunkSplitter.nextChunk(" hello world", trailingSpace: true) == " hello ")
    #expect(ChunkSplitter.nextChunk(" hello world", trailingSpace: false) == " hello")
}

@Test func chunkLastWordNoTrailingSpace() {
    // Single remaining word with no trailing whitespace in the source: we
    // return the whole word (no synthetic space appended).
    #expect(ChunkSplitter.nextChunk("Gabriel", trailingSpace: true) == "Gabriel")
    #expect(ChunkSplitter.nextChunk("Gabriel", trailingSpace: false) == "Gabriel")
}

@Test func chunkEmptyString() {
    #expect(ChunkSplitter.nextChunk("", trailingSpace: true) == "")
    #expect(ChunkSplitter.nextChunk("", trailingSpace: false) == "")
}

@Test func chunkWhitespaceOnly() {
    // No word/punctuation in the suggestion — return empty so the caller
    // can fall back instead of injecting bare spaces.
    #expect(ChunkSplitter.nextChunk("   ", trailingSpace: true) == "")
    #expect(ChunkSplitter.nextChunk("   ", trailingSpace: false) == "")
}

@Test func chunkDigitsAreWordChars() {
    #expect(ChunkSplitter.nextChunk("2024 sera bien", trailingSpace: true) == "2024 ")
}

@Test func chunkMidSuggestionAfterFirstAccept() {
    // After accepting "Je " from "Je m'appelle Gabriel", the remainder is
    // "m'appelle Gabriel" — its next chunk should be "m'appelle ".
    let first = ChunkSplitter.nextChunk("Je m'appelle Gabriel", trailingSpace: true)
    let rest = String("Je m'appelle Gabriel".dropFirst(first.count))
    #expect(rest == "m'appelle Gabriel")
    #expect(ChunkSplitter.nextChunk(rest, trailingSpace: true) == "m'appelle ")
}

@Test func chunkClosingBracketAndQuote() {
    // ) ] } » are trailing punctuation — should stick to the previous word.
    #expect(ChunkSplitter.nextChunk("voilà) et puis", trailingSpace: true) == "voilà) ")
    #expect(ChunkSplitter.nextChunk("fini» enfin", trailingSpace: true) == "fini» ")
}
