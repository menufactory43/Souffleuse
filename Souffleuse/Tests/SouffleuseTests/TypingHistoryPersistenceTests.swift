import CryptoKit
import Foundation
import Testing
import SouffleuseCorpus
@testable import SouffleusePersonalization

// MARK: - TypingHistoryPersistenceTests

/// Integration tests for `TypingHistoryStore` — covers the nullable `mid_word`
/// SQLite column, round-trip flag persistence, legacy JSON decode fallback, and
/// idempotent ALTER TABLE across re-opens.
@Suite("TypingHistoryStore persistence (mid_word column)")
struct TypingHistoryPersistenceTests {

    /// Stable 256-bit key for all test instances (never hits the Keychain).
    private static let testKey: SymmetricKey = SymmetricKey(size: .bits256)

    /// Unique temp URL per test call so tests are fully isolated.
    private static func tempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TypingHistoryPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.db")
    }

    // MARK: - Round-trip flag persistence

    @Test("round-trip: flag true / false / nil survive append + allEntries")
    func roundTripFlags() async {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TypingHistoryStore(fileURL: url, testKey: Self.testKey)

        let eTrue = TypingHistoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_000),
            contextBefore: "Merci pour votre vér",
            accepted: "ification",
            bundleID: nil,
            midWordContinuation: true
        )
        let eFalse = TypingHistoryEntry(
            timestamp: Date(timeIntervalSince1970: 2_000),
            contextBefore: "Bonjour",
            accepted: "Madame",
            bundleID: nil,
            midWordContinuation: false
        )
        let eNil = TypingHistoryEntry(
            timestamp: Date(timeIntervalSince1970: 3_000),
            contextBefore: "les frais",
            accepted: "de port",
            bundleID: nil,
            midWordContinuation: nil
        )

        await store.append(eTrue)
        await store.append(eFalse)
        await store.append(eNil)

        let all = await store.allEntries()
        // Identify by accepted string (ts comparison floats are fine but accepted is cleaner)
        let trueEntry = all.first { $0.accepted == "ification" }
        let falseEntry = all.first { $0.accepted == "Madame" }
        let nilEntry = all.first { $0.accepted == "de port" }

        #expect(trueEntry?.midWordContinuation == true,
                "mid-word flag=true must survive the round-trip")
        #expect(falseEntry?.midWordContinuation == false,
                "mid-word flag=false must survive the round-trip")
        #expect(nilEntry?.midWordContinuation == nil,
                "mid-word flag=nil must survive the round-trip")
    }

    // MARK: - Legacy JSON decode

    @Test("legacy JSON without midWordContinuation decodes to nil")
    func legacyJsonDecodeNil() throws {
        let json = """
        {
          "timestamp": 946684800.0,
          "contextBefore": "Bonjour",
          "accepted": "Madame",
          "bundleID": null
        }
        """
        let data = Data(json.utf8)
        let entry = try JSONDecoder().decode(TypingHistoryEntry.self, from: data)
        #expect(entry.midWordContinuation == nil,
                "Missing midWordContinuation key must decode as nil")
        #expect(entry.contextBefore == "Bonjour")
        #expect(entry.accepted == "Madame")
    }

    // MARK: - Idempotent ALTER TABLE

    @Test("idempotent column: re-opening the same DB does not crash and keeps entries")
    func idempotentAlter() async {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // First store — append one entry.
        let store1 = TypingHistoryStore(fileURL: url, testKey: Self.testKey)
        let entry1 = TypingHistoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_000),
            contextBefore: "premiere",
            accepted: "entrée",
            bundleID: nil,
            midWordContinuation: true
        )
        await store1.append(entry1)

        // Second store on the SAME file — exercises the idempotent ALTER TABLE.
        let store2 = TypingHistoryStore(fileURL: url, testKey: Self.testKey)
        let entry2 = TypingHistoryEntry(
            timestamp: Date(timeIntervalSince1970: 2_000),
            contextBefore: "deuxieme",
            accepted: "ligne",
            bundleID: nil,
            midWordContinuation: false
        )
        await store2.append(entry2)

        let all = await store2.allEntries()
        #expect(all.count == 2, "Both entries must be present after re-open")
        #expect(all.contains { $0.accepted == "entrée" })
        #expect(all.contains { $0.accepted == "ligne" })
    }
}
