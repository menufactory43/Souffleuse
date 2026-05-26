import CryptoKit
import Foundation
import Testing
@testable import SouffleusePersonalization

// MARK: - Helpers

private func tempStoreDir(_ tag: String = UUID().uuidString) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("souffleuse-tests-\(tag)", isDirectory: true)
    try? FileManager.default.removeItem(at: dir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func tempStoreURL(_ tag: String = UUID().uuidString) -> URL {
    tempStoreDir(tag).appendingPathComponent("history.db")
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

@Test func historyFifoPurgeAtCap() async throws {
    // Validate FIFO purge against a small temporary cap rather than inserting
    // 50k rows. Uses the test-only purge seam.
    let (store, _, _) = makeStore("ring")
    let cap = 100
    let overshoot = 50
    for i in 0..<(cap + overshoot) {
        await store.append(makeEntry("phrase numéro \(i)"))
    }
    await store.purgeToCapForTesting(cap)
    let count = await store.count()
    #expect(count == cap)
    let entries = await store.allEntries()
    // First `overshoot` should have been dropped (FIFO by id).
    #expect(entries.first?.accepted == "phrase numéro \(overshoot)")
    #expect(entries.last?.accepted == "phrase numéro \(cap + overshoot - 1)")
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

@Test func historyEncryptedAtRestNoSQLiteMagic() async throws {
    let (store, url, _) = makeStore("magic")
    await store.append(makeEntry("Bonjour le monde"))
    // Force a flush/close so all pages hit disk.
    let n = await store.count()
    #expect(n == 1)

    let raw = try Data(contentsOf: url)
    #expect(raw.count >= 16)
    // A plaintext SQLite db begins with the 16-byte magic "SQLite format 3\0".
    let magic = Array("SQLite format 3\u{0}".utf8)
    let header = Array(raw.prefix(16))
    #expect(header != magic)        // encrypted: header is NOT the magic
    let asString = String(data: raw, encoding: .utf8) ?? ""
    #expect(!asString.contains("Bonjour"))  // payload not plaintext
    await store.clear()
}

@Test func historyMigratesFromLegacyAESBlob() async throws {
    let dir = tempStoreDir("migrate")
    let dbURL = dir.appendingPathComponent("history.db")
    let aesURL = dir.appendingPathComponent("history.aes")
    let key = SymmetricKey(size: .bits256)

    // Seed a legacy AES-GCM JSON blob exactly as the old store wrote it.
    let legacy = [
        TypingHistoryEntry(timestamp: Date(), contextBefore: "ctx1", accepted: "ancien un", bundleID: "com.a"),
        TypingHistoryEntry(timestamp: Date(), contextBefore: "ctx2", accepted: "ancien deux", bundleID: nil),
    ]
    let plaintext = try JSONEncoder().encode(legacy)
    let sealed = try AES.GCM.seal(plaintext, using: key)
    try sealed.combined!.write(to: aesURL)

    // New store opens the .db, sees the sibling .aes, migrates with same key.
    let store = TypingHistoryStore(fileURL: dbURL, testKey: key)
    let entries = await store.allEntries()
    #expect(entries.map(\.accepted) == ["ancien un", "ancien deux"])

    // Legacy blob renamed (not deleted), so it is no longer at the source path.
    #expect(!FileManager.default.fileExists(atPath: aesURL.path))
    #expect(FileManager.default.fileExists(atPath: aesURL.appendingPathExtension("migrated").path))

    // Idempotent: a second store sees no source file, count unchanged.
    let store2 = TypingHistoryStore(fileURL: dbURL, testKey: key)
    let count2 = await store2.count()
    #expect(count2 == 2)
    await store2.clear()
}

@Test func historyPrefixLookup() async throws {
    let (store, _, _) = makeStore("prefix")
    await store.append(TypingHistoryEntry(timestamp: Date(), contextBefore: "Bonjour ", accepted: "Gabriel", bundleID: nil))
    await store.append(TypingHistoryEntry(timestamp: Date(), contextBefore: "Bonjour ", accepted: "tout le monde", bundleID: nil))
    await store.append(TypingHistoryEntry(timestamp: Date(), contextBefore: "Au revoir ", accepted: "et merci", bundleID: nil))
    let matches = await store.entriesMatchingContext("bonjour")
    #expect(matches.count == 2)
    #expect(Set(matches.map(\.accepted)) == ["Gabriel", "tout le monde"])
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
