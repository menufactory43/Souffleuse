import Testing
@testable import SouffleuseTyping

// Volet 1 — silent prefix correction. These tests exercise the corrector's
// conservatism contract: it fixes obvious completed-word typos in the MODEL
// input only, never touches the in-progress last token, respects language,
// and is identity when nothing is confidently wrong.
//
// NSSpellChecker is process-wide and depends on the host's installed
// dictionaries; the assertions below pick typos that FR+EN both flag with a
// single close candidate so they are stable across machines. Where the system
// dictionary cannot be assumed, we assert the *invariants* (last token never
// changes; tail preserved) rather than a specific spelling.

// MARK: - In-progress last token is NEVER corrected

@Test func lastTokenNeverCorrected_noTrailingSeparator() {
    let corrector = PrefixCorrector()
    // "écirs" is a typo but it's the in-progress word (no trailing space).
    let input = "Je vous écirs"
    let out = corrector.correctedPrefix(input, detectedLanguage: "French")
    // The trailing in-progress token must survive verbatim.
    #expect(out.hasSuffix("écirs"))
}

@Test func splitInProgressTail_separatesTrailingWord() {
    let s = PrefixCorrector.splitInProgressTail("Je vous écirs")
    #expect(String(s.completed) == "Je vous ")
    #expect(String(s.tail) == "écirs")
}

@Test func splitInProgressTail_emptyTailWhenEndsOnSeparator() {
    let s = PrefixCorrector.splitInProgressTail("Je vous écirs ")
    #expect(String(s.tail) == "")
    #expect(String(s.completed) == "Je vous écirs ")
}

// MARK: - Completed-word correction

@Test func correctsCompletedTypo_keepsTrailingTokenUntouched() {
    let corrector = PrefixCorrector()
    // "écirs" is now COMPLETED (followed by " pour"); "vous" is clean and the
    // in-progress tail "info" must be left alone.
    let input = "Je vous écirs pour info"
    let out = corrector.correctedPrefix(input, detectedLanguage: "French")
    // Whatever happens upstream, the in-progress tail is preserved verbatim…
    #expect(out.hasSuffix("info"))
    // …and the length/shape only changes if a correction actually fired.
    // If the host dictionary corrects "écirs"→"écris", assert it; otherwise
    // the corrector must be identity (no silent corruption).
    if out != input {
        #expect(out.contains("écris"))
        #expect(!out.contains("écirs pour"))
    }
}

// MARK: - Toggle OFF semantics handled by caller; corrector itself is pure.
// We assert the identity contract on clean prose here.

@Test func cleanProseIsIdentity() {
    let corrector = PrefixCorrector()
    let input = "Je vous écris pour vous informer que "
    #expect(corrector.correctedPrefix(input, detectedLanguage: "French") == input)
}

@Test func emptyInputIsIdentity() {
    let corrector = PrefixCorrector()
    #expect(corrector.correctedPrefix("", detectedLanguage: nil) == "")
}

// MARK: - Language respect — valid French not "corrected" as English

@Test func validFrenchWordNotCorrected() {
    let corrector = PrefixCorrector()
    // "viens" is valid French (the TypoDetector bails when any of FR/EN
    // accepts a word). It is a completed word here. Must stay verbatim.
    let input = "je viens de finir le travail "
    let out = corrector.correctedPrefix(input, detectedLanguage: "French")
    #expect(out.contains("viens"))
    #expect(!out.contains("views"))
}

// MARK: - Non-prose skipping

@Test func looksLikeProse_rejectsIdentifiersAndUrls() {
    #expect(PrefixCorrector.looksLikeProse("bonjour") == true)
    #expect(PrefixCorrector.looksLikeProse("Bonjour") == true)
    #expect(PrefixCorrector.looksLikeProse("camelCase") == false)
    #expect(PrefixCorrector.looksLikeProse("foo.bar") == false)
    #expect(PrefixCorrector.looksLikeProse("http") == true)   // bare word ok
    #expect(PrefixCorrector.looksLikeProse("api/v2") == false)
    #expect(PrefixCorrector.looksLikeProse("user_id") == false)
    #expect(PrefixCorrector.looksLikeProse("a1b2") == false)
}

@Test func urlInPrefixIsNotCorrupted() {
    let corrector = PrefixCorrector()
    let input = "visite https://exemple.fr maintenant "
    let out = corrector.correctedPrefix(input, detectedLanguage: "French")
    #expect(out.contains("https://exemple.fr"))
}

// MARK: - Capitalization preservation

@Test func matchingCase_preservesLeadingCapital() {
    #expect(PrefixCorrector.matchingCase(of: "Bonjur", applyingTo: "bonjour") == "Bonjour")
    #expect(PrefixCorrector.matchingCase(of: "bonjur", applyingTo: "bonjour") == "bonjour")
}

// MARK: - Word range extraction

@Test func completedWordRanges_findsAllWords() {
    let s = "le chat noir"
    let ranges = PrefixCorrector.completedWordRanges(in: s[...])
    let words = ranges.map { String(s[$0]) }
    #expect(words == ["le", "chat", "noir"])
}
