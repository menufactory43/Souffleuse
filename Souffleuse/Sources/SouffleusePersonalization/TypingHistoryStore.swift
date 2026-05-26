import CryptoKit
import Foundation
import SouffleuseLog
import CSQLCipher

/// Persistent corpus of accepted suggestions, stored in an **encrypted-at-rest
/// SQLite database** (SQLCipher) at
/// `~/Library/Application Support/Souffleuse/history.db`.
///
/// The database page contents — including the SQLite header magic — are
/// transparently encrypted by SQLCipher using a passphrase derived from the
/// 256-bit AES key in `KeychainKey` (single key source for the whole app). A
/// raw `head -c 16` on the file therefore does NOT reveal `SQLite format 3\0`.
///
/// This replaces the former 200-entry AES-GCM JSON blob (`history.aes`). On
/// first launch the old blob, if present, is decrypted via the legacy code
/// path, bulk-inserted, then renamed to `history.aes.migrated` (idempotent —
/// the rename means a second launch finds nothing to migrate).
///
/// The actor API (`append`, `allEntries`, `recentEntries`, `count`,
/// `sizeBytes`, `clear`, `load`, `init(fileURL:testKey:)`) is unchanged so all
/// existing callers and tests keep working. `fileLocation` now points at the
/// `.db` file.
public actor TypingHistoryStore {
    /// Hard cap on stored entries. Raised from the legacy 200 to 50k now that
    /// the corpus lives in a queryable, indexed database. Oldest rows are
    /// purged once this is exceeded (FIFO by `ts`/`id`).
    public static let maxEntries: Int = 50_000

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
        return dir.appendingPathComponent("history.db")
    }

    private let fileURL: URL
    private let injectedKey: SymmetricKey?

    private var db: OpaquePointer?
    private var loaded: Bool = false
    private var openFailedThisSession: Bool = false

    public init(fileURL: URL = TypingHistoryStore.defaultFileURL()) {
        self.fileURL = fileURL
        self.injectedKey = nil
    }

    /// Test seam: skip the keychain and derive the SQLCipher passphrase from the
    /// supplied key. Production code never uses this initialiser.
    internal init(fileURL: URL, testKey: SymmetricKey) {
        self.fileURL = fileURL
        self.injectedKey = testKey
    }

    public var fileLocation: URL { fileURL }

    // MARK: - Open / schema

    /// Opens (creating if needed) the encrypted database, applies the schema,
    /// and runs the one-shot migration from the legacy AES blob. Idempotent.
    /// Silently resets to an empty (recreated) database on any failure such as
    /// a corrupt file or a missing key.
    public func load() {
        if loaded { return }
        loaded = true

        let key: SymmetricKey?
        if let injectedKey {
            key = injectedKey
        } else {
            do {
                key = try KeychainKey.loadOrCreate()
            } catch {
                key = nil
                Log.warn(.context, "history_keychain_unavailable")
                return
            }
        }
        guard let key else { return }

        if !openEncrypted(key: key) {
            // Could not open as an encrypted DB (e.g. legacy/garbage bytes at
            // this path). Quarantine the unreadable file and start fresh.
            Log.warn(.context, "history_db_unreadable_reset")
            try? FileManager.default.removeItem(at: fileURL)
            if !openEncrypted(key: key) {
                openFailedThisSession = true
                return
            }
        }

        createSchema()
        migrateLegacyBlobIfNeeded(key: key)
    }

    private func passphrase(from key: SymmetricKey) -> String {
        // Derive a stable hex passphrase from the raw key material. SQLCipher
        // accepts a passphrase string and runs its own KDF over it.
        let bytes = key.withUnsafeBytes { Data($0) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Opens the DB and supplies the key; returns true when a real read of the
    /// schema succeeds (proves the key/file are valid).
    private func openEncrypted(key: SymmetricKey) -> Bool {
        if let db { sqlite3_close(db); self.db = nil }
        var handle: OpaquePointer?
        guard sqlite3_open(fileURL.path, &handle) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return false
        }
        let pass = passphrase(from: key)
        if sqlite3_key(handle, pass, Int32(pass.utf8.count)) != SQLITE_OK {
            sqlite3_close(handle)
            return false
        }
        // Touch the schema to force SQLCipher to decrypt page 1. If the key is
        // wrong or the file is not a SQLCipher db, this fails.
        if sqlite3_exec(handle, "SELECT count(*) FROM sqlite_master;", nil, nil, nil) != SQLITE_OK {
            sqlite3_close(handle)
            return false
        }
        self.db = handle
        return true
    }

    private func createSchema() {
        guard let db else { return }
        let ddl = """
        CREATE TABLE IF NOT EXISTS entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts REAL NOT NULL,
            context_before TEXT NOT NULL,
            accepted TEXT NOT NULL,
            bundle_id TEXT,
            ctx_norm TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX IF NOT EXISTS idx_entries_ctx_norm ON entries(ctx_norm);
        CREATE INDEX IF NOT EXISTS idx_entries_ts ON entries(ts);
        """
        if sqlite3_exec(db, ddl, nil, nil, nil) != SQLITE_OK {
            Log.warn(.context, "history_schema_failed")
        }
    }

    /// Normalised prefix key used by the `ctx_norm` index for prefix lookups:
    /// lowercased, whitespace-collapsed tail of `contextBefore`.
    static func normalize(_ s: String) -> String {
        let collapsed = s.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.suffix(64))
    }

    // MARK: - Migration

    private func legacyBlobURL() -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("history.aes")
    }

    /// Decrypts the legacy `history.aes` (if present), bulk-inserts its entries,
    /// then renames it to `history.aes.migrated`. Idempotent: the rename means a
    /// later launch finds no source file. Uses the SAME key (AES-GCM) the legacy
    /// store used.
    private func migrateLegacyBlobIfNeeded(key: SymmetricKey) {
        let src = legacyBlobURL()
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        let migrated = src.appendingPathExtension("migrated")
        do {
            let data = try Data(contentsOf: src)
            let box = try AES.GCM.SealedBox(combined: data)
            let plaintext = try AES.GCM.open(box, using: key)
            let legacy = try JSONDecoder().decode([TypingHistoryEntry].self, from: plaintext)
            for e in legacy { insert(e) }
            try? FileManager.default.removeItem(at: migrated)
            try FileManager.default.moveItem(at: src, to: migrated)
            Log.info(.context, "history_migrated_from_aes", count: legacy.count)
        } catch {
            // Could not decrypt (different key / corrupt). Quarantine anyway so
            // we don't retry every launch.
            try? FileManager.default.moveItem(at: src, to: migrated)
            Log.warn(.context, "history_migration_failed")
        }
    }

    // MARK: - Mutations

    /// Appends one entry, applying the secret heuristic and FIFO purge.
    public func append(_ entry: TypingHistoryEntry) {
        load()
        guard db != nil else { return }
        guard !entry.accepted.isEmpty, entry.accepted.count >= 3 else { return }
        if SecretHeuristic.looksLikeSecret(entry.accepted) {
            Log.info(.context, "history_skipped_secretlike")
            return
        }
        insert(entry)
        purgeIfNeeded()
    }

    private func insert(_ entry: TypingHistoryEntry) {
        guard let db else { return }
        let sql = "INSERT INTO entries (ts, context_before, accepted, bundle_id, ctx_norm) VALUES (?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Log.warn(.context, "history_insert_prepare_failed")
            return
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, entry.timestamp.timeIntervalSince1970)
        bindText(stmt, 2, entry.contextBefore)
        bindText(stmt, 3, entry.accepted)
        if let b = entry.bundleID { bindText(stmt, 4, b) } else { sqlite3_bind_null(stmt, 4) }
        bindText(stmt, 5, Self.normalize(entry.contextBefore))
        if sqlite3_step(stmt) != SQLITE_DONE {
            Log.warn(.context, "history_insert_failed")
        }
    }

    private func purgeIfNeeded() {
        guard let db else { return }
        let n = rowCount()
        if n <= Self.maxEntries { return }
        let toDrop = n - Self.maxEntries
        let sql = "DELETE FROM entries WHERE id IN (SELECT id FROM entries ORDER BY id ASC LIMIT ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(toDrop))
        _ = sqlite3_step(stmt)
    }

    // MARK: - Queries

    public func recentEntries(limit: Int) -> [TypingHistoryEntry] {
        load()
        let n = max(0, limit)
        let sql = "SELECT ts, context_before, accepted, bundle_id FROM entries ORDER BY id DESC LIMIT ?;"
        let rows = query(sql) { stmt in sqlite3_bind_int(stmt, 1, Int32(n)) }
        // Caller historically receives oldest-first; reverse the DESC result.
        return rows.reversed()
    }

    public func allEntries() -> [TypingHistoryEntry] {
        load()
        return query("SELECT ts, context_before, accepted, bundle_id FROM entries ORDER BY id ASC;", bind: nil)
    }

    /// Prefix-keyed lookup over the `ctx_norm` index — accepted continuations
    /// whose recorded context shares the normalized prefix tail. Enables the
    /// queryable-by-prefix corpus that motivated this phase.
    public func entriesMatchingContext(_ context: String, limit: Int = 50) -> [TypingHistoryEntry] {
        load()
        let norm = Self.normalize(context)
        guard !norm.isEmpty else { return [] }
        let sql = "SELECT ts, context_before, accepted, bundle_id FROM entries WHERE ctx_norm = ? ORDER BY id DESC LIMIT ?;"
        return query(sql) { stmt in
            bindText(stmt, 1, norm)
            sqlite3_bind_int(stmt, 2, Int32(max(0, limit)))
        }
    }

    public func count() -> Int {
        load()
        return rowCount()
    }

    public func sizeBytes() -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attrs?[.size] as? Int) ?? 0
    }

    /// Drops every entry, removes the database files, and deletes the Keychain key.
    public func clear() {
        if let db { sqlite3_close(db); self.db = nil }
        let fm = FileManager.default
        try? fm.removeItem(at: fileURL)
        try? fm.removeItem(at: fileURL.appendingPathExtension("wal"))
        try? fm.removeItem(at: fileURL.appendingPathExtension("shm"))
        try? fm.removeItem(at: URL(fileURLWithPath: fileURL.path + "-wal"))
        try? fm.removeItem(at: URL(fileURLWithPath: fileURL.path + "-shm"))
        if injectedKey == nil {
            _ = KeychainKey.delete()
        }
        loaded = false
        openFailedThisSession = false
        Log.info(.context, "history_cleared")
    }

    // MARK: - SQLite helpers

    private func rowCount() -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM entries;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func query(_ sql: String, bind: ((OpaquePointer?) -> Void)?) -> [TypingHistoryEntry] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind?(stmt)
        var out: [TypingHistoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = sqlite3_column_double(stmt, 0)
            let ctx = columnText(stmt, 1)
            let acc = columnText(stmt, 2)
            let bundle = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : columnText(stmt, 3)
            out.append(TypingHistoryEntry(
                timestamp: Date(timeIntervalSince1970: ts),
                contextBefore: ctx,
                accepted: acc,
                bundleID: bundle
            ))
        }
        return out
    }
}

// SQLite C-string lifetime: SQLITE_TRANSIENT tells SQLite to copy the bytes.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
    sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT)
}

private func columnText(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
    guard let c = sqlite3_column_text(stmt, idx) else { return "" }
    return String(cString: c)
}
