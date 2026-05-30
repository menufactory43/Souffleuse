import Foundation
import Observation
import SouffleuseLog

/// Bord du cadre du champ auquel le HUD de traduction est ancré.
enum HUDEdge: String, Codable, Sendable {
    case right, left, top, bottom
}

/// Position mémorisée du HUD pour UNE app, exprimée comme ancrage **relatif** au
/// cadre du champ focus (`{bord, écart}`), jamais en coordonnées d'écran
/// absolues — ainsi le HUD se replace correctement même si la fenêtre bouge ou
/// change d'écran. Tous les champs ont un défaut → décodage tolérant aux
/// versions futures du schéma.
struct HUDAnchor: Codable, Sendable {
    /// Clé d'identité : une ancre par bundleID (Brave, Slack, Mail…).
    var bundleID: String
    var edge: HUDEdge = .right
    var offsetX: Double = 0
    var offsetY: Double = 0
}

/// Enveloppe versionnée sur disque (`hud-anchors.json`).
private struct HUDAnchorFile: Codable {
    var version: Int = 1
    var anchors: [HUDAnchor] = []
}

/// Mémorise la position du HUD de traduction **par app** (bundleID), dans
/// `~/Library/Application Support/Souffleuse/hud-anchors.json`.
///
/// Clone fidèle du patron `AllowlistStore` (triade valeur / enveloppe versionnée
/// / store `@MainActor @Observable`), avec une simplification : la clé d'identité
/// EST le `bundleID` (une ancre par app), donc pas d'UUID séparé. Le seam
/// testable est la `nonisolated static func anchor(forBundle:anchors:)`.
@MainActor
@Observable
final class HUDAnchorStore {
    private(set) var anchors: [HUDAnchor] = []
    @ObservationIgnored private let fileURL: URL

    convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Souffleuse", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.init(fileURL: support.appendingPathComponent("hud-anchors.json"))
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let file = try JSONDecoder().decode(HUDAnchorFile.self, from: data)
            anchors = file.anchors
        } catch {
            Log.warn(.ui, "hud_anchor_load_corrupt_reset")
            anchors = []
        }
    }

    func save() {
        let file = HUDAnchorFile(anchors: anchors)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else {
            Log.error(.ui, "hud_anchor_encode_failed")
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error(.ui, "hud_anchor_write_failed")
        }
    }

    /// Position mémorisée pour cette app, `nil` si jamais déplacée → l'appelant
    /// retombe sur le défaut (dock à droite du champ).
    func anchor(forBundle bundleID: String) -> HUDAnchor? {
        Self.anchor(forBundle: bundleID, anchors: anchors)
    }

    /// Upsert par `bundleID` (une seule ancre par app). Persiste immédiatement.
    func upsert(_ anchor: HUDAnchor) {
        if let i = anchors.firstIndex(where: { $0.bundleID == anchor.bundleID }) {
            anchors[i] = anchor
        } else {
            anchors.append(anchor)
        }
        save()
    }

    /// Oublie la position d'une app → elle revient au défaut au prochain affichage.
    func reset(bundleID: String) {
        anchors.removeAll(where: { $0.bundleID == bundleID })
        save()
    }

    /// Lookup pur, testable sans disque ni MainActor.
    nonisolated static func anchor(forBundle bundleID: String, anchors: [HUDAnchor]) -> HUDAnchor? {
        anchors.first(where: { $0.bundleID == bundleID })
    }
}
