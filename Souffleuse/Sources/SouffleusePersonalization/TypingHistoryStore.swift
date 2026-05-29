import CryptoKit
import Foundation
import SouffleuseLog
import SouffleuseTyping
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

    /// Shared `TypoDetector` instance used for the record-time fragment gate and
    /// Layer-2 sanitation. `TypoDetector` is `@unchecked Sendable`; safe here
    /// because the actor serialises all access.
    private let typoDetector = TypoDetector()

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
        sanitizeLegacyCorruption()
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
        // WAL + NORMAL sync: durable enough for an append-on-Tab corpus while
        // keeping per-insert latency low (the hot path runs off the UI thread,
        // but a large migration / bulk insert must not stall for seconds).
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
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
        // Add nullable mid_word column idempotently. Check PRAGMA first to
        // avoid the "duplicate column name" error on already-migrated DBs.
        addMidWordColumnIfNeeded()
        addSourceColumnIfNeeded()
    }

    /// Adds the `source` TEXT column (default 'accept') if it does not exist.
    /// Same idempotent pattern as `addMidWordColumnIfNeeded`.
    private func addSourceColumnIfNeeded() {
        guard let db else { return }
        var hasColumn = false
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(entries);", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let namePtr = sqlite3_column_text(stmt, 1) {
                    if String(cString: namePtr) == "source" { hasColumn = true; break }
                }
            }
            sqlite3_finalize(stmt)
        }
        guard !hasColumn else { return }
        let ddl = "ALTER TABLE entries ADD COLUMN source TEXT NOT NULL DEFAULT 'accept';"
        if sqlite3_exec(db, ddl, nil, nil, nil) == SQLITE_OK {
            Log.info(.context, "history_source_column_added")
        }
    }

    /// Adds the `mid_word` INTEGER column to `entries` if it does not exist
    /// yet. Uses `PRAGMA table_info` to check, so re-running is a no-op.
    private func addMidWordColumnIfNeeded() {
        guard let db else { return }
        // PRAGMA table_info returns one row per column; we check for "mid_word".
        var hasColumn = false
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(entries);", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                // Column 1 = name
                if let namePtr = sqlite3_column_text(stmt, 1) {
                    let name = String(cString: namePtr)
                    if name == "mid_word" { hasColumn = true; break }
                }
            }
            sqlite3_finalize(stmt)
        }
        guard !hasColumn else { return }
        if sqlite3_exec(db, "ALTER TABLE entries ADD COLUMN mid_word INTEGER;", nil, nil, nil) == SQLITE_OK {
            Log.info(.context, "history_midword_column_added")
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

    // MARK: - Layer-2 sanitation

    /// Drops corrupt legacy entries that passed the old record-time gate but
    /// are known-bad: rows where `mid_word IS NULL`, the contextBefore ends on
    /// a word-char, accepted starts on a word-char, the merged boundary word is
    /// NOT a valid dictionary word, and accepted has no further word segment
    /// (meaning the whole accepted string is a sub-word fragment, never a
    /// complete next-word continuation). Idempotent — once dropped, the SELECT
    /// returns nothing and the DELETE is a no-op.
    private func sanitizeLegacyCorruption() {
        guard let db else { return }
        // Fetch legacy rows (NULL mid_word) for the structural+dictionary test.
        // We need id, context_before, and accepted. Bundle/ts not needed.
        let selectSQL = "SELECT id, context_before, accepted FROM entries WHERE mid_word IS NULL;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &stmt, nil) == SQLITE_OK else { return }
        var corruptIDs: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(stmt, 0)
            let ctx = columnText(stmt, 1)
            let acc = columnText(stmt, 2)
            if isTruncatedFragment(contextBefore: ctx, accepted: acc) {
                corruptIDs.append(rowID)
            }
        }
        sqlite3_finalize(stmt)
        guard !corruptIDs.isEmpty else { return }
        // Build "DELETE FROM entries WHERE id IN (?,?,…)" with integer binds.
        let placeholders = corruptIDs.map { _ in "?" }.joined(separator: ",")
        let deleteSQL = "DELETE FROM entries WHERE id IN (\(placeholders));"
        var delStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, deleteSQL, -1, &delStmt, nil) == SQLITE_OK else { return }
        for (i, rowID) in corruptIDs.enumerated() {
            sqlite3_bind_int64(delStmt, Int32(i + 1), rowID)
        }
        _ = sqlite3_step(delStmt)
        sqlite3_finalize(delStmt)
        Log.info(.context, "history_sanitized_legacy", count: corruptIDs.count)
    }

    // MARK: - Mutations

    /// Appends one entry, applying the secret heuristic and FIFO purge.
    public func append(_ entry: TypingHistoryEntry) {
        load()
        guard db != nil else { return }
        // Measure the TRIMMED length: a space-padded one-letter payload ("  f")
        // would otherwise satisfy a raw count>=3 while looksLikeFragment and
        // isTruncatedFragment (which trim first) miss it. Gate the real payload.
        guard entry.accepted.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else { return }
        if SecretHeuristic.looksLikeSecret(entry.accepted) {
            Log.info(.context, "history_skipped_secretlike")
            return
        }
        // Structural junk gate : reject the live-consume residue that polluted
        // the corpus during debugging ("s de", "t es" — a lone leading letter
        // then a space). Deliberately NOT a dictionary check: that would reject
        // the user's own uncommon vocabulary (proper nouns, jargon), which is
        // exactly what personalization must learn. Only obvious fragments go.
        if Self.looksLikeFragment(entry.accepted) {
            Log.info(.context, "history_skipped_fragment")
            return
        }
        // Dictionary-aware truncated sub-word gate: if both contextBefore and
        // accepted share a word boundary (mid-word glue) AND the merged boundary
        // word is NOT valid AND accepted has no further segment, this is a
        // truncated fragment — never record it (it would corrupt joinHistory
        // reconstruction as "vér ifi" later).
        if isTruncatedFragment(contextBefore: entry.contextBefore, accepted: entry.accepted) {
            Log.info(.context, "history_skipped_truncated_fragment")
            return
        }
        insert(entry)
        purgeIfNeeded()
    }

    /// True when `accepted` looks like a live-consume FRAGMENT rather than real
    /// accepted text: it starts with a lone letter immediately followed by a
    /// space ("s de manger" — the dangling "s" of a mis-consumed "envies"). Pure
    /// structural check, no dictionary, so legitimate uncommon words are kept.
    static func looksLikeFragment(_ accepted: String) -> Bool {
        let t = accepted.trimmingCharacters(in: .whitespacesAndNewlines)
        let chars = Array(t)
        guard chars.count >= 2 else { return false }
        // "s de…" : single letter then a space. But keep genuine one-letter
        // French words (a, à, y, ô, o) — only a NON-standalone leading letter
        // (consonant residue: s, t, l, d, n, j, m, c…) signals a bad consume.
        if chars[0].isLetter, chars[1] == " " {
            let standalone: Set<Character> = ["a", "à", "y", "ô", "o", "A", "À", "Y", "Ô", "O"]
            return !standalone.contains(chars[0])
        }
        return false
    }

    /// Returns true when (contextBefore, accepted) form a truncated sub-word
    /// fragment that must NOT be stored. All four conditions must hold:
    ///  1. Both sides share a word-char boundary (mid-word glue position).
    ///  2. The merged boundary word (trailingPartialWord(cb) + leadingWordRun(acc))
    ///     is NOT a valid dictionary word (e.g. "vérifi" is invalid).
    ///  3. accepted has no further segment beyond its leading word run (i.e. the
    ///     whole accepted string is just the incomplete word fragment).
    ///  4. The accepted leading word run is itself NOT a valid standalone word.
    ///     This guards against next-word accepts where both sides happen to be
    ///     word-chars ("premiere"+"entrée"): "entrée" IS valid on its own, so it
    ///     is a complete next-word continuation, not a sub-word fragment.
    private func isTruncatedFragment(contextBefore: String, accepted: String) -> Bool {
        guard let cbLast = contextBefore.last, isWordChar(cbLast),
              let accFirst = accepted.first, isWordChar(accFirst) else {
            return false  // not a word-char boundary → not a mid-word glue
        }
        // Compute merged boundary word.
        let trailing = trailingPartialWord(contextBefore)
        let leading = leadingWordRun(accepted)
        let merged = trailing + leading
        guard !merged.isEmpty else { return false }
        // Condition 2: if the merged word IS valid, legitimate mid-word completion.
        if typoDetector.isValidWord(merged, language: nil) { return false }
        // Condition 3: accepted must have no further segment beyond the leading word.
        // "ification" → leading == accepted → bare fragment.
        // "ification complète" → leading.count < accepted.count → has more → keep.
        if leading.count < accepted.count { return false }  // more content follows → keep
        // Condition 4: accepted leading run must NOT be a valid standalone word.
        // "entrée", "montant", "Madame" — valid standalone → next-word accept, keep.
        // "ifi", "redi" (when merged is invalid) — not valid standalone → fragment.
        if !leading.isEmpty, typoDetector.isValidWord(leading, language: nil) { return false }
        return true  // all conditions met → truncated sub-word fragment
    }

    /// Whether a character is a word character (mirrors OutputFilter.isWordChar).
    private func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "'" || c == "'" || c == "-"
    }

    /// Returns the trailing run of word-chars from `s` (mirrors
    /// OutputFilter.trailingPartialWord without the SouffleuseCore import).
    private func trailingPartialWord(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            let c = s[prev]
            if isWordChar(c) { end = prev } else { break }
        }
        return String(s[end...])
    }

    /// Returns the leading run of word-chars from `s` (mirrors OutputFilter.leadingWordRun).
    private func leadingWordRun(_ s: String) -> String {
        var out = ""
        for c in s {
            if isWordChar(c) { out.append(c) } else { break }
        }
        return out
    }

    private func insert(_ entry: TypingHistoryEntry) {
        guard let db else { return }
        let sql = "INSERT INTO entries (ts, context_before, accepted, bundle_id, ctx_norm, mid_word, source) VALUES (?, ?, ?, ?, ?, ?, ?);"
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
        // Bind mid_word: nil → NULL, true → 1, false → 0
        if let flag = entry.midWordContinuation {
            sqlite3_bind_int(stmt, 6, flag ? 1 : 0)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        bindText(stmt, 7, entry.source.rawValue)
        if sqlite3_step(stmt) != SQLITE_DONE {
            Log.warn(.context, "history_insert_failed")
        }
    }

    /// Test seam: insert an entry directly (bypassing all record-time gates).
    /// Used to seed corrupt legacy entries for sanitation tests.
    internal func insertForTesting(_ entry: TypingHistoryEntry) {
        load()
        guard db != nil else { return }
        insert(entry)
    }

    /// Test seam: force a FIFO purge down to `cap` without inserting 50k rows.
    internal func purgeToCapForTesting(_ cap: Int) {
        load()
        guard let db else { return }
        let n = rowCount()
        guard n > cap else { return }
        let toDrop = n - cap
        let sql = "DELETE FROM entries WHERE id IN (SELECT id FROM entries ORDER BY id ASC LIMIT ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(toDrop))
        _ = sqlite3_step(stmt)
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
        let sql = "SELECT ts, context_before, accepted, bundle_id, mid_word, source FROM entries ORDER BY id DESC LIMIT ?;"
        let rows = query(sql) { stmt in sqlite3_bind_int(stmt, 1, Int32(n)) }
        // Caller historically receives oldest-first; reverse the DESC result.
        return rows.reversed()
    }

    public func allEntries() -> [TypingHistoryEntry] {
        load()
        return query("SELECT ts, context_before, accepted, bundle_id, mid_word, source FROM entries ORDER BY id ASC;", bind: nil)
    }

    /// Prefix-keyed lookup over the `ctx_norm` index — accepted continuations
    /// whose recorded context shares the normalized prefix tail. Enables the
    /// queryable-by-prefix corpus that motivated this phase.
    public func entriesMatchingContext(_ context: String, limit: Int = 50) -> [TypingHistoryEntry] {
        load()
        let norm = Self.normalize(context)
        guard !norm.isEmpty else { return [] }
        let sql = "SELECT ts, context_before, accepted, bundle_id, mid_word, source FROM entries WHERE ctx_norm = ? ORDER BY id DESC LIMIT ?;"
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

    /// Minimum length, in characters, below which a SINGLE-TOKEN accept is
    /// treated as context-blind word-completer residue and pruned. Multi-word
    /// accepts (the user's real phrasing) are always kept regardless of length.
    public static let pruneSingleTokenMaxChars = 5

    /// Imports messages from the staging file written by `SouffleuseCorpusSeed`.
    /// Reads `corpus-import.json` (array of plain strings) from the app support
    /// directory, appends each as a `.prose` entry through the normal gates, then
    /// deletes the file. No-op when the file is absent. Safe to call on every
    /// launch — idempotent once the file is consumed.
    @discardableResult
    public func importPendingIfNeeded() -> Int {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil, create: false)
        else { return 0 }
        let queueURL = base
            .appendingPathComponent("Souffleuse", isDirectory: true)
            .appendingPathComponent("corpus-import.json")
        guard fm.fileExists(atPath: queueURL.path),
              let data = try? Data(contentsOf: queueURL),
              let messages = try? JSONDecoder().decode([String].self, from: data)
        else { return 0 }
        load()
        var inserted = 0
        let before = rowCount()
        for body in messages {
            let entry = TypingHistoryEntry(
                timestamp: Date(),
                contextBefore: "",
                accepted: body,
                bundleID: "com.intercom.conversations",
                source: .prose
            )
            append(entry)
            inserted += 1
        }
        let after = rowCount()
        try? fm.removeItem(at: queueURL)
        Log.info(.context, "corpus_import_done", count: after - before)
        return after - before
    }

    /// V2 corpus hygiene — one-time retroactive prune that aligns the existing
    /// corpus with the new record-time rule (no Layer-0 `.wordComplete` accepts).
    /// Deletes short SINGLE-TOKEN accepts ("ton", "aux", "cal", "fis") that the
    /// context-blind word-completer used to record and that the unbeatable
    /// `strongCorpusMatch` later recalls as junk mid-word. Multi-word accepts
    /// (real continuations) are never touched. Runs IN the app, where SQLCipher
    /// decrypts with the live Keychain key. Idempotent. Returns the number of
    /// rows deleted. The caller is expected to gate it to run once.
    @discardableResult
    public func pruneLowQuality() -> Int {
        load()
        guard let db else { return 0 }
        let before = rowCount()
        // Single-token (no internal whitespace) AND short ⇒ word-completer class.
        let sql = "DELETE FROM entries WHERE instr(trim(accepted), ' ') = 0 AND length(trim(accepted)) <= ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Log.warn(.context, "corpus_prune_prepare_failed")
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(Self.pruneSingleTokenMaxChars))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            Log.warn(.context, "corpus_prune_failed")
            return 0
        }
        let deleted = before - rowCount()
        Log.info(.context, "corpus_pruned", count: deleted)
        return deleted
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
            // Column 4: mid_word — NULL → nil, 0 → false, non-zero → true
            let midWord: Bool?
            if sqlite3_column_type(stmt, 4) == SQLITE_NULL {
                midWord = nil
            } else {
                midWord = sqlite3_column_int(stmt, 4) != 0
            }
            // Column 5: source — default 'accept' for legacy rows (DEFAULT clause)
            let sourceRaw = columnText(stmt, 5)
            let source = EntrySource(rawValue: sourceRaw) ?? .accept
            out.append(TypingHistoryEntry(
                timestamp: Date(timeIntervalSince1970: ts),
                contextBefore: ctx,
                accepted: acc,
                bundleID: bundle,
                midWordContinuation: midWord,
                source: source
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
