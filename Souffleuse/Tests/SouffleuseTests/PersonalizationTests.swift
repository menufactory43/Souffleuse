import CryptoKit
import Foundation
import Testing
@testable import SouffleusePersonalization

// MARK: - Helpers

private func tempStoreURL(_ tag: String = UUID().uuidString) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("souffleuse-tests-\(tag)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("history.aes")
}

private func makeStore(_ tag: String = UUID().uuidString) -> (TypingHistoryStore, URL, SymmetricKey) {
    let url = tempStoreURL(tag)
    try? FileManager.default.removeItem(at: url)
    let key = SymmetricKey(size: .bits256)
    return (TypingHistoryStore(fileURL: url, testKey: key), url, key)
}

private func makeEntry(_ accepted: String, _ ctx: String = "ctx") -> TypingHistoryEntry {
    TypingHistoryEntry(timestamp: Date(), contextBefore: ctx, accepted: accepted, bundleID: "com.test")
}

// MARK: - SecretHeuristic

@Test func secretHeuristicFlagsLongTokens() {
    #expect(SecretHeuristic.looksLikeSecret("aXz9Kpq7vBnM2Lqw4Rt6"))
    #expect(SecretHeuristic.looksLikeSecret("ghp_1234567890abcdefghij"))
}

@Test func secretHeuristicAcceptsHumanText() {
    #expect(!SecretHeuristic.looksLikeSecret("Bonjour Gabriel"))
    #expect(!SecretHeuristic.looksLikeSecret("À bientôt et bonne journée"))
    #expect(!SecretHeuristic.looksLikeSecret("hello world"))
}

@Test func secretHeuristicContextTailTrimsToLastSentence() {
    let tail = SecretHeuristic.contextTail(prefix: "Hello. World goes on")
    #expect(tail == "World goes on")
}

@Test func secretHeuristicContextTailFallsBackToSuffix() {
    let prefix = String(repeating: "a", count: 200)
    let tail = SecretHeuristic.contextTail(prefix: prefix, maxChars: 50)
    #expect(tail.count == 50)
}

// MARK: - TypingHistoryStore

@Test func historyEncryptedRoundTrip() async throws {
    let (store, url, key) = makeStore("rt")
    await store.append(makeEntry("Bonjour"))
    await store.append(makeEntry("À bientôt"))
    await store.append(makeEntry("Merci"))

    let reloaded = TypingHistoryStore(fileURL: url, testKey: key)
    let entries = await reloaded.allEntries()
    #expect(entries.count == 3)
    #expect(entries.map(\.accepted) == ["Bonjour", "À bientôt", "Merci"])

    // File must not be plaintext-readable.
    let raw = try Data(contentsOf: url)
    let asString = String(data: raw, encoding: .utf8) ?? ""
    #expect(!asString.contains("Bonjour"))

    await reloaded.clear()
}

@Test func historyRingBufferRotatesAtMax() async throws {
    let (store, _, _) = makeStore("ring")
    for i in 0..<(TypingHistoryStore.maxEntries + 50) {
        await store.append(makeEntry("phrase numéro \(i)"))
    }
    let count = await store.count()
    #expect(count == TypingHistoryStore.maxEntries)
    let entries = await store.allEntries()
    // First 50 should have been dropped (FIFO).
    #expect(entries.first?.accepted == "phrase numéro 50")
    #expect(entries.last?.accepted == "phrase numéro \(TypingHistoryStore.maxEntries + 49)")
    await store.clear()
}

@Test func historyBlocksHighEntropyAcceptances() async throws {
    let (store, _, _) = makeStore("entropy")
    await store.append(makeEntry("aXz9Kpq7vBnM2Lqw4Rt6"))
    await store.append(makeEntry("Bonjour"))
    let entries = await store.allEntries()
    #expect(entries.count == 1)
    #expect(entries.first?.accepted == "Bonjour")
    await store.clear()
}

@Test func historyDecryptCorruptFileResetsToEmpty() async throws {
    let url = tempStoreURL("corrupt")
    try? FileManager.default.removeItem(at: url)
    // Write garbage that won't decrypt.
    try Data((0..<256).map { _ in UInt8.random(in: 0...255) }).write(to: url)
    let store = TypingHistoryStore(fileURL: url, testKey: SymmetricKey(size: .bits256))
    let count = await store.count()
    #expect(count == 0)
    // Subsequent appends still work (file is rewritten).
    await store.append(makeEntry("after recovery"))
    let entries = await store.allEntries()
    #expect(entries.map(\.accepted) == ["after recovery"])
    await store.clear()
}

@Test func historyRejectsTooShortAcceptance() async throws {
    let (store, _, _) = makeStore("short")
    await store.append(makeEntry("ok"))   // len 2 → rejected
    await store.append(makeEntry("oui"))  // len 3 → kept
    let entries = await store.allEntries()
    #expect(entries.map(\.accepted) == ["oui"])
    await store.clear()
}
