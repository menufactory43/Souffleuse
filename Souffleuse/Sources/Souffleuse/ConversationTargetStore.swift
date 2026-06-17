import Foundation
import Observation
import SouffleuseCore
import SouffleuseLog

/// Cible de traduction mémorisée pour UNE conversation.
///
/// La clé d'identité est un **proxy** `bundleID + titre de fenêtre nettoyé` :
/// il n'existe pas d'identifiant de conversation fiable côté web (Intercom,
/// Gmail…), donc le titre de fenêtre (nom du contact / sujet du thread) sert de
/// substitut. Une nouvelle conversation = nouvelle clé = retour à AUTO, ce qui
/// est le comportement voulu (re-détecter la langue du nouveau correspondant).
struct ConversationTarget: Codable, Sendable {
    var key: String
    var selection: TargetSelection
}

/// Enveloppe versionnée sur disque (`conversation-targets.json`).
private struct ConversationTargetsFile: Codable {
    var version: Int = 1
    var entries: [ConversationTarget] = []
}

/// Mémorise la cible de traduction **par conversation** (bundleID + titre de
/// fenêtre nettoyé), dans `~/Library/Application Support/Souffleuse/conversation-targets.json`.
///
/// Clone du patron `HUDAnchorStore` / `AllowlistStore` (triade valeur / enveloppe
/// versionnée / store `@MainActor @Observable`). Le seam testable est la
/// `nonisolated static func` de construction de clé + de lookup, exerçable sans
/// disque ni MainActor.
@MainActor
@Observable
final class ConversationTargetStore {
    private(set) var entries: [ConversationTarget] = []
    @ObservationIgnored private let fileURL: URL

    convenience init() {
        let support = FileManager.souffleuseSupportDirectory()
        self.init(fileURL: support.appendingPathComponent("conversation-targets.json"))
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let file = try JSONDecoder().decode(ConversationTargetsFile.self, from: data)
            entries = file.entries
        } catch {
            Log.warn(.ui, "conversation_target_load_corrupt_reset")
            entries = []
        }
    }

    func save() {
        let file = ConversationTargetsFile(entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else {
            Log.error(.ui, "conversation_target_encode_failed")
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error(.ui, "conversation_target_write_failed")
        }
    }

    /// Sélection mémorisée pour cette conversation, `.auto` par défaut (jamais
    /// touchée → on suit la détection / on retombe sur EN).
    func selection(forBundle bundleID: String?, windowTitle: String?) -> TargetSelection {
        let key = Self.key(forBundle: bundleID, windowTitle: windowTitle)
        return Self.selection(forKey: key, entries: entries)
    }

    /// Pose une sélection explicite pour la conversation courante et persiste.
    func setSelection(_ selection: TargetSelection, forBundle bundleID: String?, windowTitle: String?) {
        let key = Self.key(forBundle: bundleID, windowTitle: windowTitle)
        if let i = entries.firstIndex(where: { $0.key == key }) {
            entries[i].selection = selection
        } else {
            entries.append(ConversationTarget(key: key, selection: selection))
        }
        save()
    }

    /// Fait défiler la cible de la conversation courante (EN→ES→DE→IT→AUTO→…),
    /// persiste, et renvoie la NOUVELLE sélection pour l'affichage immédiat.
    @discardableResult
    func cycle(forBundle bundleID: String?, windowTitle: String?) -> TargetSelection {
        let next = selection(forBundle: bundleID, windowTitle: windowTitle).cycleNext()
        setSelection(next, forBundle: bundleID, windowTitle: windowTitle)
        return next
    }

    /// Construit la clé proxy. Pur, testable. Le titre est borné en longueur
    /// (les titres web embarquent parfois des compteurs « (3) Slack | … » qui
    /// font dériver la clé ; on garde un préfixe stable et on neutralise les
    /// blancs superflus).
    nonisolated static func key(forBundle bundleID: String?, windowTitle: String?) -> String {
        let bid = bundleID ?? "?"
        let normalized = normalizedTitle(windowTitle ?? "")
        let collapsed = normalized.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let title = String(collapsed.prefix(80))
        return bid + "\u{1}" + title
    }

    /// Retire les **décorations volatiles** d'un titre de fenêtre AVANT d'en faire
    /// une clé : compteur de non-lus en tête (« (3) Sujet ») ou en queue
    /// (« Signal (1) »), puce de non-lu (« • », « ● », « ▸ », « · »). Sans ça, le
    /// MÊME thread produit une clé différente à chaque message reçu (le compteur
    /// bouge), donc la cible mémorisée dérive et se perd au commit — d'où des
    /// doublons observés type `Signal` vs `Signal (1)`. Appliqué en boucle pour
    /// gérer les décorations combinées (« (3) • Sujet »). Pur, testable, sans
    /// réseau. Un changement de SUJET reste une clé différente (= nouvelle
    /// conversation, comportement voulu) ; on ne neutralise que les compteurs/puces.
    nonisolated static func normalizedTitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var previous: String
        repeat {
            previous = s
            s = s.replacing(/^[•●▸·*]\s*/, with: "")          // puce de non-lu en tête
            s = s.replacing(/^[(\[]\d+[)\]]\s*/, with: "")      // compteur « (3) » / « [3] » en tête
            s = s.replacing(/\s*[(\[]\d+[)\]]$/, with: "")      // compteur « (1) » en queue
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        } while s != previous
        return s
    }

    /// Lookup pur, testable sans disque ni MainActor. `.auto` si la clé est
    /// inconnue.
    nonisolated static func selection(forKey key: String, entries: [ConversationTarget]) -> TargetSelection {
        entries.first(where: { $0.key == key })?.selection ?? .auto
    }
}
