import CryptoKit
import Foundation
import Testing
@testable import SouffleusePersonalization

// MARK: - Helpers

private func tempStoreURL(_ tag: String = UUID().uuidString) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("souffleuse-fewshot-\(tag)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("history.aes")
}

private func makeStore(_ tag: String = UUID().uuidString) -> (TypingHistoryStore, URL) {
    let url = tempStoreURL(tag)
    try? FileManager.default.removeItem(at: url)
    let key = SymmetricKey(size: .bits256)
    return (TypingHistoryStore(fileURL: url, testKey: key), url)
}

private func makeEntry(_ accepted: String, ctx: String = "") -> TypingHistoryEntry {
    TypingHistoryEntry(timestamp: Date(), contextBefore: ctx, accepted: accepted, bundleID: "com.test")
}

// MARK: - tokenize

@Test func tokenizeFiltersStopWordsAndShortTokens() {
    let tokens = SimilarHistoryRetrieval.tokenize("J'ai besoin de l'aide pour mon app")
    // Apostrophe = séparateur : « j'ai » → « j » (filtré, 1 char) + « ai ».
    // « l'aide » → « l » (filtré) + « aide » (gardé).
    // Stop-words « de » filtrés.
    #expect(tokens.contains("ai"))
    #expect(tokens.contains("besoin"))
    #expect(tokens.contains("aide"))
    #expect(tokens.contains("pour"))
    #expect(tokens.contains("mon"))
    #expect(tokens.contains("app"))
    #expect(!tokens.contains("de"))
    #expect(!tokens.contains("l"))
    #expect(!tokens.contains("j"))
}

@Test func tokenizeLowercasesEverything() {
    let tokens = SimilarHistoryRetrieval.tokenize("Bonjour MONDE")
    #expect(tokens.contains("bonjour"))
    #expect(tokens.contains("monde"))
    #expect(!tokens.contains("Bonjour"))
}

// MARK: - jaccard

@Test func jaccardReturnsZeroForEmpty() {
    #expect(SimilarHistoryRetrieval.jaccard([], ["a", "b"]) == 0)
    #expect(SimilarHistoryRetrieval.jaccard(["a"], []) == 0)
}

@Test func jaccardMatchesExpectedFormula() {
    let a: Set<String> = ["bonjour", "app", "autocomplete"]
    let b: Set<String> = ["bonjour", "app", "vélo"]
    // |∩| = 2 (bonjour, app), |∪| = 4 → 0.5
    let score = SimilarHistoryRetrieval.jaccard(a, b)
    #expect(score == 0.5)
}

// MARK: - rank (similarEntries logic)

@Test func similarEntriesReturnsEmptyWhenHistoryEmpty() async throws {
    let (store, _) = makeStore("empty")
    let result = await store.similarEntries(to: "bonjour j'ai besoin", limit: 3)
    #expect(result.isEmpty)
    await store.clear()
}

@Test func similarEntriesReturnsEmptyWhenUserTailEmpty() async throws {
    let (store, _) = makeStore("emptyTail")
    await store.append(makeEntry("bonjour mon ami"))
    let result = await store.similarEntries(to: "", limit: 3)
    #expect(result.isEmpty)
    await store.clear()
}

@Test func similarEntriesReturnsTopKByJaccardOverlap() async throws {
    let (store, _) = makeStore("topk")
    // 5 entries, ordre d'insertion. Le retrieval doit re-trier par similarité,
    // pas par récence.
    await store.append(makeEntry("recette de tarte aux pommes"))            // no overlap
    await store.append(makeEntry("autocomplétage et suggestions inline"))   // strong overlap
    await store.append(makeEntry("aller faire les courses au marché"))      // no overlap
    await store.append(makeEntry("besoin d'aide pour mon application"))     // strong overlap
    await store.append(makeEntry("développement mobile avec swift"))        // weak overlap (mobile/app)

    let userTail = "bonjour j'ai besoin d'aide pour mon app d'autocomplétage"
    let top = await store.similarEntries(to: userTail, limit: 2)
    #expect(top.count == 2)
    let accepted = top.map(\.accepted)
    // Les deux entrées avec le plus grand overlap doivent gagner.
    #expect(accepted.contains("autocomplétage et suggestions inline"))
    #expect(accepted.contains("besoin d'aide pour mon application"))
    await store.clear()
}

@Test func similarEntriesFiltersStopWordsFromUserTail() async throws {
    let (store, _) = makeStore("stop")
    // Entry contient seulement des mots de l'historique pas dans userTail
    await store.append(makeEntry("recette gâteau chocolat"))
    // userTail composé exclusivement de stop-words → aucun token gardé → rank
    // renvoie [] (tailTokens vide après filtrage).
    let result = await store.similarEntries(to: "de la le les et à du", limit: 3)
    #expect(result.isEmpty)
    await store.clear()
}

@Test func similarEntriesMinTokenLengthSkipsSingleChars() async throws {
    let (store, _) = makeStore("minlen")
    await store.append(makeEntry("vraiment intéressant aujourd'hui"))
    // Tous tokens 1-char → filtrés → result vide
    let result = await store.similarEntries(to: "j l a", limit: 3)
    #expect(result.isEmpty)
    await store.clear()
}

@Test func similarEntriesUsesContextBeforeForMatching() async throws {
    let (store, _) = makeStore("ctx")
    // L'overlap est dans `contextBefore`, pas dans `accepted`. Le retrieval
    // doit quand même retrouver l'entrée parce qu'on tokenize (contextBefore
    // + accepted) ensemble (cf. NgramBuilder.rebuild).
    await store.append(makeEntry("rapidement", ctx: "autocomplétage application développement"))
    await store.append(makeEntry("nuage", ctx: "recette pomme tarte"))

    let result = await store.similarEntries(
        to: "mon application d'autocomplétage avance", limit: 1
    )
    #expect(result.count == 1)
    #expect(result.first?.accepted == "rapidement")
    await store.clear()
}

// MARK: - buildExamplesBlock

@Test func fewShotPromptCapsAt400Chars() {
    // 10 entrées longues : chacune ~100 chars → 4-5 devraient tenir, pas plus.
    var entries: [TypingHistoryEntry] = []
    let longText = String(repeating: "lorem ipsum dolor sit amet ", count: 4) // ~108 chars
    for i in 0..<10 {
        entries.append(TypingHistoryEntry(
            timestamp: Date(), contextBefore: "ctx \(i)", accepted: longText,
            bundleID: nil
        ))
    }
    let block = SimilarHistoryRetrieval.buildExamplesBlock(from: entries)
    #expect(block.count <= SimilarHistoryRetrieval.maxConcatenatedExamplesChars)
    // Sanity : on doit avoir AU MOINS une entrée (la première fit)
    #expect(!block.isEmpty)
}

@Test func buildExamplesBlockEmptyWhenNoEntries() {
    let block = SimilarHistoryRetrieval.buildExamplesBlock(from: [])
    #expect(block.isEmpty)
}

@Test func buildExamplesBlockKeepsOrder() {
    let entries: [TypingHistoryEntry] = [
        TypingHistoryEntry(timestamp: Date(), contextBefore: "", accepted: "alpha", bundleID: nil),
        TypingHistoryEntry(timestamp: Date(), contextBefore: "", accepted: "beta", bundleID: nil),
        TypingHistoryEntry(timestamp: Date(), contextBefore: "", accepted: "gamma", bundleID: nil),
    ]
    let block = SimilarHistoryRetrieval.buildExamplesBlock(from: entries)
    #expect(block == "alpha\nbeta\ngamma")
}

@Test func buildExamplesBlockIncludesContextBefore() {
    let entries: [TypingHistoryEntry] = [
        TypingHistoryEntry(
            timestamp: Date(),
            contextBefore: "Bonjour",
            accepted: "Gabriel",
            bundleID: nil
        ),
    ]
    let block = SimilarHistoryRetrieval.buildExamplesBlock(from: entries)
    #expect(block == "Bonjour Gabriel")
}
