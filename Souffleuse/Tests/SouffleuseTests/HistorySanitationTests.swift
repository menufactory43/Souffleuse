import CryptoKit
import Foundation
import Testing
@testable import SouffleusePersonalization

// MARK: - HistorySanitationTests

/// Guards the Layer-2 load-time sanitation that purges corrupt legacy entries
/// (mid_word IS NULL, contextBefore ends in word char, accepted starts in word
/// char, merged word is NOT valid, accepted has no further segment).
@Suite("TypingHistoryStore Layer-2 sanitation")
struct HistorySanitationTests {

    private static let testKey: SymmetricKey = SymmetricKey(size: .bits256)

    private static func tempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistorySanitationTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.db")
    }

    // MARK: - Drop corrupt + keep valid

    @Test("sanitation drops corrupt legacy fragment, keeps valid legacy entry")
    func sanitationDropsCorruptKeepsValid() async {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TypingHistoryStore(fileURL: url, testKey: Self.testKey)

        // Corrupt legacy: contextBefore ends in word char "vér", accepted is "ifi"
        // → merged "vérifi" is NOT a valid word; accepted has no further segment
        // → this should be dropped by Layer-2 sanitation.
        // We must bypass the record-time gate (which now ALSO blocks this) by using
        // the test seam insertForTesting.
        let corruptEntry = TypingHistoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_000),
            contextBefore: "Merci beaucoup pour votre vér",
            accepted: "ifi",
            bundleID: nil,
            midWordContinuation: nil  // legacy: NULL in DB
        )
        // Valid legacy: "…le" + "montant" → "lemontant" is not a word, so it's
        // NOT a mid-word fragment (no word-char boundary on both sides? actually
        // "le" ends in 'e' (word char) and "montant" starts in 'm' (word char),
        // merged is "lemontant" which is not valid — BUT "montant" is a multi-
        // segment word (just one word, no further segment). However, "montant" IS
        // a valid French word in isolation, but it is NOT a sub-word fragment
        // because "montant" ≥ 3 chars, starts a word boundary, and IS a valid
        // word. Actually the issue: "le" + "montant" — merged is "lemontant"
        // which is invalid. The record-time gate checks: is it a mid-word glue?
        // cb "…le" last char 'e' = word char, accepted "montant" first char 'm' =
        // word char → yes, it IS a mid-word position. merged = trailingPartialWord("…le")
        // + leadingWordRun("montant") = "le" + "montant" = "lemontant" → NOT valid.
        // AND accepted "montant" has no further segment (leadingWordRun == full accepted).
        // → This would ALSO be dropped by the sanitation if not for being a
        // "valid standalone word" check. Wait, the plan says: "accepted has no
        // further segment" AND "merged is NOT valid" → BOTH must hold.
        // "lemontant" is NOT valid → first condition met.
        // "montant" has no trailing separator → second condition met.
        // So "le" + "montant" would also be dropped. Let's use a clearer valid case.
        // Use: contextBefore ending in SPACE (not word char) → NOT a mid-word join
        // → sanitation does NOT apply → entry is kept.
        let validEntry = TypingHistoryEntry(
            timestamp: Date(timeIntervalSince1970: 2_000),
            contextBefore: "Bonjour ",  // ends in space → not a word-char boundary
            accepted: "Madame",
            bundleID: nil,
            midWordContinuation: nil
        )

        await store.insertForTesting(corruptEntry)
        await store.insertForTesting(validEntry)

        // Re-open the SAME DB — load() triggers sanitizeLegacyCorruption()
        let store2 = TypingHistoryStore(fileURL: url, testKey: Self.testKey)
        let all = await store2.allEntries()

        #expect(!all.contains { $0.accepted == "ifi" },
                "Corrupt 'ifi' fragment must be dropped by Layer-2 sanitation")
        #expect(all.contains { $0.accepted == "Madame" },
                "Valid entry must survive sanitation")
    }

    // MARK: - Idempotency

    @Test("sanitation is idempotent: re-opening again does not drop more entries")
    func sanitationIdempotent() async {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TypingHistoryStore(fileURL: url, testKey: Self.testKey)

        let corruptEntry = TypingHistoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_000),
            contextBefore: "pour votre vér",
            accepted: "ifi",
            bundleID: nil,
            midWordContinuation: nil
        )
        let validEntry = TypingHistoryEntry(
            timestamp: Date(timeIntervalSince1970: 2_000),
            contextBefore: "les frais ",
            accepted: "de port",
            bundleID: nil,
            midWordContinuation: nil
        )
        await store.insertForTesting(corruptEntry)
        await store.insertForTesting(validEntry)

        // First open + sanitation
        let store2 = TypingHistoryStore(fileURL: url, testKey: Self.testKey)
        let all2 = await store2.allEntries()
        let countAfterFirst = all2.count

        // Second open — sanitation runs again, must be a no-op
        let store3 = TypingHistoryStore(fileURL: url, testKey: Self.testKey)
        let all3 = await store3.allEntries()
        #expect(all3.count == countAfterFirst,
                "Second sanitation pass must not drop additional entries (idempotent)")
        #expect(!all3.contains { $0.accepted == "ifi" })
        #expect(all3.contains { $0.accepted == "de port" })
    }

    // MARK: - Valid mid-word completion NOT dropped

    @Test("valid mid-word completion (vérification) is NOT dropped by sanitation")
    func validMidWordNotDropped() async {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TypingHistoryStore(fileURL: url, testKey: Self.testKey)

        // "vér" + "ification" → merged "vérification" IS a valid French word
        // → sanitation must NOT drop it.
        let goodEntry = TypingHistoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_000),
            contextBefore: "pour votre vér",
            accepted: "ification",
            bundleID: nil,
            midWordContinuation: nil
        )
        await store.insertForTesting(goodEntry)

        let store2 = TypingHistoryStore(fileURL: url, testKey: Self.testKey)
        let all = await store2.allEntries()
        #expect(all.contains { $0.accepted == "ification" },
                "Valid mid-word completion 'vérification' must survive sanitation")
    }
}
