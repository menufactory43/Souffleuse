import Foundation
import Observation
import SouffleuseCore
import SouffleuseLog

/// Ton de relecture FR→FR associé à UNE application (par bundleID).
struct ToneRule: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var bundleID: String
    var tone: Tone = .neutral
}

/// Enveloppe versionnée sur disque (`tones.json`). Porte le ton par défaut
/// global (appliqué à toute app sans règle) et les surcharges par application.
private struct ToneFile: Codable {
    var version: Int = 1
    var defaultTone: Tone = .neutral
    var rules: [ToneRule] = []
}

/// Mémorise le ton de relecture **par application**, avec un défaut global, dans
/// `~/Library/Application Support/Souffleuse/tones.json`.
///
/// Clone du patron `AllowlistStore` (triade valeur Codable / enveloppe versionnée
/// / store `@MainActor @Observable`). Le seam testable est la `nonisolated static
/// func` de lookup, exerçable sans disque ni MainActor.
@MainActor
@Observable
final class ToneStore {
    private(set) var rules: [ToneRule] = []
    private(set) var defaultTone: Tone = .neutral
    @ObservationIgnored private let fileURL: URL

    convenience init() {
        let support = FileManager.souffleuseSupportDirectory()
        self.init(fileURL: support.appendingPathComponent("tones.json"))
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let file = try JSONDecoder().decode(ToneFile.self, from: data)
            rules = file.rules
            defaultTone = file.defaultTone
        } catch {
            Log.warn(.ui, "tone_load_corrupt_reset")
            rules = []
            defaultTone = .neutral
        }
    }

    func save() {
        let file = ToneFile(defaultTone: defaultTone, rules: rules)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else {
            Log.error(.ui, "tone_encode_failed")
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error(.ui, "tone_write_failed")
        }
    }

    /// Change le ton appliqué partout où aucune règle ne correspond, et persiste.
    func setDefaultTone(_ t: Tone) {
        defaultTone = t
        save()
    }

    func upsert(_ rule: ToneRule) {
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

    /// Ton applicable à `bundleID` : 1re règle correspondante, sinon le défaut.
    func tone(forBundle bundleID: String?) -> Tone {
        Self.tone(forBundle: bundleID, rules: rules, defaultTone: defaultTone)
    }

    /// Lookup pur, testable sans disque ni MainActor. Le défaut s'applique à toute
    /// app sans règle (et quand le bundleID est inconnu).
    nonisolated static func tone(forBundle bundleID: String?, rules: [ToneRule], defaultTone: Tone) -> Tone {
        guard let bid = bundleID else { return defaultTone }
        return rules.first(where: { $0.bundleID == bid })?.tone ?? defaultTone
    }
}
