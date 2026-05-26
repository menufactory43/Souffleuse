import CryptoKit
import Foundation
import SouffleuseLog

/// Persistent ring buffer of accepted suggestions. Stored as a single
/// AES-GCM sealed blob at `~/Library/Application Support/Souffleuse/history.aes`,
/// keyed by the symmetric key from `KeychainKey`. Append is synchronous-flush:
/// every accepted suggestion fully rewrites the file. With a 200-entry cap the
/// payload stays well under 100 KB so this is cheap.
public actor TypingHistoryStore {
    public static let maxEntries: Int = 200
    public static let hardSizeCapBytes: Int = 1_000_000   // truncate if file exceeds (corruption)

    public static func defaultFileURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Souffleuse", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.aes")
    }

    private let fileURL: URL
    private var entries: [TypingHistoryEntry] = []
    private var key: SymmetricKey?
    private let injectedKey: SymmetricKey?
    private var loaded: Bool = false
    private var writeFailedThisSession: Bool = false

    public init(fileURL: URL = TypingHistoryStore.defaultFileURL()) {
        self.fileURL = fileURL
        self.injectedKey = nil
    }

    /// Test seam: skip the keychain and use the supplied key. Production code
    /// never uses this initialiser.
    internal init(fileURL: URL, testKey: SymmetricKey) {
        self.fileURL = fileURL
        self.injectedKey = testKey
    }

    public var fileLocation: URL { fileURL }

    /// Loads the key from keychain and decrypts the file. Idempotent. Silently
    /// resets to empty state on any failure (key gone, file corrupt, etc.).
    public func load() {
        if loaded { return }
        loaded = true
        if let injectedKey {
            self.key = injectedKey
        } else {
            do {
                self.key = try KeychainKey.loadOrCreate()
            } catch {
                self.key = nil
                Log.warn(.context, "history_keychain_unavailable")
                return
            }
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            if data.count > Self.hardSizeCapBytes {
                Log.warn(.context, "history_oversized_reset")
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            entries = try decrypt(data)
        } catch {
            entries = []
            Log.warn(.context, "history_decrypt_failed")
        }
    }

    /// Appends one entry, applying ring-buffer rotation and the secret
    /// heuristic. Writes the encrypted blob synchronously.
    public func append(_ entry: TypingHistoryEntry) {
        load()
        guard !entry.accepted.isEmpty, entry.accepted.count >= 3 else { return }
        if SecretHeuristic.looksLikeSecret(entry.accepted) {
            Log.info(.context, "history_skipped_secretlike")
            return
        }
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        flush()
    }

    public func recentEntries(limit: Int) -> [TypingHistoryEntry] {
        load()
        let n = max(0, min(limit, entries.count))
        return Array(entries.suffix(n))
    }

    public func allEntries() -> [TypingHistoryEntry] {
        load()
        return entries
    }

    public func count() -> Int {
        load()
        return entries.count
    }

    public func sizeBytes() -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attrs?[.size] as? Int) ?? 0
    }

    /// Drops every entry, removes the file, and deletes the Keychain key.
    public func clear() {
        entries = []
        try? FileManager.default.removeItem(at: fileURL)
        if injectedKey == nil {
            _ = KeychainKey.delete()
        }
        key = nil
        loaded = false
        Log.info(.context, "history_cleared")
    }

    // MARK: - Crypto

    private func flush() {
        guard let key else { return }
        if writeFailedThisSession { return }
        do {
            let plaintext = try JSONEncoder().encode(entries)
            let sealed = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealed.combined else {
                Log.warn(.context, "history_seal_failed")
                return
            }
            try combined.write(to: fileURL, options: [.atomic])
        } catch {
            writeFailedThisSession = true
            Log.warn(.context, "history_write_failed")
        }
    }

    private func decrypt(_ data: Data) throws -> [TypingHistoryEntry] {
        guard let key else { return [] }
        let box = try AES.GCM.SealedBox(combined: data)
        let plaintext = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode([TypingHistoryEntry].self, from: plaintext)
    }
}
