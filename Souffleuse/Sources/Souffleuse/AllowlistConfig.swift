import Foundation
import Observation
import SouffleuseCore
import SouffleuseLog

/// Per-app behavior overrides. Looked up at every focus change in `tick()`.
/// First matching rule wins; if no rule matches, default = .active.
enum AllowlistMode: String, Codable, CaseIterable, Sendable {
    case active            // ghost text + enrichment (default for unmatched)
    case disabled          // pipeline fully off for this app
    case suggestionOnly    // ghost text on, enrichment off
    case clipboardOnly     // ghost text + enrichment but no OCR capture

    var label: String {
        switch self {
        case .active: return tr(fr: "Actif", en: "Active")
        case .disabled: return tr(fr: "Désactivé", en: "Disabled")
        case .suggestionOnly: return tr(fr: "Suggestion seule", en: "Suggestion only")
        case .clipboardOnly: return tr(fr: "Clipboard seul", en: "Clipboard only")
        }
    }
}

struct AllowlistRule: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var bundleID: String
    /// Optional ICU regex matched against the window title. Empty → matches any title.
    var titleRegex: String = ""
    var mode: AllowlistMode = .active

    /// Pre-compiled regex if titleRegex is non-empty and valid; nil otherwise.
    var compiledRegex: NSRegularExpression? {
        let pattern = titleRegex.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}

/// On-disk JSON shape. Versioned in case we change the schema.
private struct AllowlistFile: Codable {
    var version: Int = 1
    var rules: [AllowlistRule] = []
}

@MainActor
@Observable
final class AllowlistStore {
    private(set) var rules: [AllowlistRule] = []
    @ObservationIgnored private let fileURL: URL

    /// Production init points at ~/Library/Application Support/Souffleuse/allowlist.json.
    /// Tests use the `fileURL:` overload to redirect to a temp file.
    convenience init() {
        let support = FileManager.souffleuseSupportDirectory()
        self.init(fileURL: support.appendingPathComponent("allowlist.json"))
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let file = try JSONDecoder().decode(AllowlistFile.self, from: data)
            rules = file.rules
        } catch {
            Log.warn(.ui, "allowlist_load_corrupt_reset")
            rules = []
        }
    }

    func save() {
        let file = AllowlistFile(rules: rules)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else {
            Log.error(.ui, "allowlist_encode_failed")
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error(.ui, "allowlist_write_failed")
        }
    }

    func upsert(_ rule: AllowlistRule) {
        if let i = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[i] = rule
        } else {
            rules.append(rule)
        }
        save()
    }

    func delete(_ id: UUID) {
        rules.removeAll(where: { $0.id == id })
        save()
    }

    /// Returns the mode for the given (bundleID, windowTitle). First matching rule wins.
    func mode(forBundle bundleID: String, windowTitle: String?) -> AllowlistMode {
        Self.mode(forBundle: bundleID, windowTitle: windowTitle, rules: rules)
    }

    /// Pure lookup; usable from tests without touching disk.
    nonisolated static func mode(forBundle bundleID: String, windowTitle: String?, rules: [AllowlistRule]) -> AllowlistMode {
        for rule in rules where rule.bundleID == bundleID {
            let pattern = rule.titleRegex.trimmingCharacters(in: .whitespaces)
            if pattern.isEmpty {
                return rule.mode  // bundleID-only rule
            }
            // Non-empty pattern: rule matches iff the regex compiles AND matches the title.
            // Invalid regex → rule is skipped (not a fall-through to bundleID-only).
            guard let regex = rule.compiledRegex else { continue }
            let title = windowTitle ?? ""
            let range = NSRange(title.startIndex..., in: title)
            if regex.firstMatch(in: title, options: [], range: range) != nil {
                return rule.mode
            }
        }
        return .active
    }
}
