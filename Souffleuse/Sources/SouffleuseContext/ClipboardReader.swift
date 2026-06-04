import AppKit
import Foundation

/// Reads the system clipboard as a context source for the prompt prefix.
/// Opt-in via the global Enrichment toggle, refused on blocklisted frontmost apps.
public actor ClipboardReader {
    public static let maxChars = 500

    /// Bundle ID prefixes that must never have their clipboard contents read.
    /// Hard-coded baseline per ARCHITECTURE.md §3.2 "Privacy hard rules".
    public static let defaultBlocklist: [String] = [
        "com.1password.",
        "com.agilebits.onepassword",
        "com.apple.keychainaccess",
        "com.lastpass.",
        "com.dashlane.",
        "com.bitwarden.",
        "com.boursorama.",
        "com.bnpparibas.",
        "com.lcl.",
        "com.sg.",
        "com.creditmutuel.",
        "com.revolut.",
    ]

    private let pasteboard: NSPasteboard
    private let blocklist: [String]
    private var lastChangeCount: Int = -1
    private var lastValue: String?

    public init(pasteboard: NSPasteboard = .general, blocklist: [String] = ClipboardReader.defaultBlocklist) {
        self.pasteboard = pasteboard
        self.blocklist = blocklist
    }

    /// Returns the union of the default blocklist and any user-supplied entries
    /// from `~/Library/Application Support/Souffleuse/clipboard-blocklist.txt`.
    /// Lines starting with `#` or empty are ignored.
    public static func mergedBlocklist() -> [String] {
        Array(Set(defaultBlocklist + loadUserBlocklist()))
    }

    public static func loadUserBlocklist() -> [String] {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return [] }
        let path = appSupport
            .appendingPathComponent("Souffleuse", isDirectory: true)
            .appendingPathComponent("clipboard-blocklist.txt")
        guard let data = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        return data.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }
            return trimmed
        }
    }

    /// Returns the clipboard text suitable for a context prefix, or nil if
    /// blocked, empty, or not a string payload.
    /// `frontmostBundleID` is the currently focused app — used to enforce
    /// the per-app blocklist (we never want to leak a password manager's copy).
    public func read(frontmostBundleID: String?) -> String? {
        // Fail-closed sur bundleID inconnu : si `AppContextProbe` n'a pas pu
        // identifier l'app focus (`nil`, rare mais possible — transition Mission
        // Control, glitch au lancement), on NE SAIT PAS si c'est un gestionnaire
        // de mots de passe ou une app bancaire blocklistée. Plutôt que de lire le
        // presse-papier sans pouvoir appliquer la blocklist (fail-open = fuite
        // possible), on s'abstient. Aligne la posture du clipboard sur celle de
        // l'OCR (`ContextEnricher.snapshot` exige déjà `let bid = ctx.bundleID`).
        guard let bid = frontmostBundleID else { return nil }
        if isBlocked(bundleID: bid) {
            return nil
        }
        let count = pasteboard.changeCount
        if count == lastChangeCount {
            return lastValue
        }
        lastChangeCount = count

        guard let raw = pasteboard.string(forType: .string), !raw.isEmpty else {
            lastValue = nil
            return nil
        }
        let cleaned = sanitize(raw)
        // Drop low-signal payloads (pure numbers, hashes, addresses, UUIDs).
        // These eat clipboard-budget chars in the prompt without giving the
        // LLM anything to lock onto — observed 2026-05-28: "0,02486238" leaked
        // a crypto amount into every keystroke's Context block.
        if Self.isLowSignalNoise(cleaned) {
            lastValue = nil
            return nil
        }
        lastValue = cleaned
        return cleaned
    }

    /// True when the clipboard payload is structurally meaningful but
    /// semantically empty for the LLM: pure numbers, hex hashes, hash-prefixed
    /// addresses, UUIDs. Real prose (even short — "Bonjour", "OK") falls
    /// through. Mixed payloads with at least one letter-word are kept.
    static func isLowSignalNoise(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        let patterns = [
            // Pure number with optional decimal/thousands separators and sign.
            #"^[+\-]?\d{1,3}([.,\s]\d{3})*([.,]\d+)?\s*[%‰$€£¥]?$"#,
            // Bare decimal/integer (covers "0,02486238", "1234.56", "42").
            #"^[+\-]?\d+([.,]\d+)?$"#,
            // Hex hash or hex-prefixed value, ≥16 chars.
            #"^(0x)?[0-9a-fA-F]{16,}$"#,
            // UUID.
            #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#,
            // Bitcoin address (legacy/segwit) and Ethereum address.
            #"^(bc1|[13])[a-zA-HJ-NP-Z0-9]{25,62}$"#,
            #"^0x[0-9a-fA-F]{40}$"#,
        ]
        for p in patterns {
            if trimmed.range(of: p, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    public func isBlocked(bundleID: String) -> Bool {
        blocklist.contains { prefix in
            if prefix.hasSuffix(".") {
                return bundleID.hasPrefix(prefix) || bundleID == String(prefix.dropLast())
            }
            return bundleID == prefix || bundleID.hasPrefix(prefix + ".")
        }
    }

    /// Collapses newlines and whitespace runs, truncates to `maxChars`.
    private func sanitize(_ s: String) -> String {
        let collapsed = s
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
        if trimmed.count <= Self.maxChars { return trimmed }
        return String(trimmed.prefix(Self.maxChars)) + "…"
    }
}
