import Foundation
import Observation
import SouffleuseLog

/// Désactivations TEMPORAIRES par application, posées d'un geste depuis le
/// menu-bar (« Désactiver dans <App> » : 5 / 15 / 60 min ou indéfiniment) —
/// l'équivalent du « Disable Completions in <App> » de Cotypist. Distinct de
/// l'`AllowlistStore` (règles PERMANENTES éditées dans les Préférences) : ici
/// c'est éphémère, sans surface de réglage. Persisté en UserDefaults (léger ;
/// survit au redémarrage pour « indéfiniment » et pour une fenêtre encore ouverte).
@MainActor
@Observable
final class TemporaryDisableStore {
    /// bundleID → instant d'expiration (référence epoch). Une entrée absente OU
    /// expirée = app active. « Indéfiniment » = `indefinite` (futur lointain).
    private(set) var entries: [String: Double] = [:]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String

    /// Sentinelle « jusqu'à réactivation manuelle » : JSON/plist ne savent pas
    /// encoder l'infini, donc on borne au futur lointain (toujours > maintenant).
    nonisolated static let indefinite = Date.distantFuture

    init(defaults: UserDefaults = .standard, key: String = "temporaryDisables") {
        self.defaults = defaults
        self.key = key
        load()
    }

    /// Désactive `bundleID` jusqu'à `until` (passer `indefinite` = sans limite).
    func disable(bundleID: String, until: Date) {
        entries[bundleID] = until.timeIntervalSinceReferenceDate
        save()
        Log.info(.ui, "app_temporarily_disabled")
    }

    /// Réactive `bundleID` (retire l'entrée). No-op si déjà actif.
    func reactivate(bundleID: String) {
        guard entries[bundleID] != nil else { return }
        entries[bundleID] = nil
        save()
        Log.info(.ui, "app_reactivated")
    }

    /// L'app est-elle désactivée à l'instant `now` ?
    func isDisabled(bundleID: String, now: Date = Date()) -> Bool {
        Self.isDisabled(bundleID: bundleID, now: now, entries: entries)
    }

    /// Instant d'expiration courant si l'app est désactivée et non expirée, sinon
    /// nil. `indefinite` (≈ distantFuture) signale « sans limite » à l'appelant.
    func expiry(bundleID: String) -> Date? {
        guard let raw = entries[bundleID] else { return nil }
        let date = Date(timeIntervalSinceReferenceDate: raw)
        return date > Date() ? date : nil
    }

    /// Élague les entrées expirées (à l'ouverture du menu) pour que l'état affiché
    /// soit juste et que le fichier ne gonfle pas.
    func pruneExpired(now: Date = Date()) {
        let kept = Self.pruned(entries, now: now)
        if kept.count != entries.count {
            entries = kept
            save()
        }
    }

    // MARK: - Pur (testable sans UserDefaults)

    nonisolated static func isDisabled(bundleID: String, now: Date, entries: [String: Double]) -> Bool {
        guard let raw = entries[bundleID] else { return false }
        return raw > now.timeIntervalSinceReferenceDate
    }

    nonisolated static func pruned(_ entries: [String: Double], now: Date) -> [String: Double] {
        entries.filter { $0.value > now.timeIntervalSinceReferenceDate }
    }

    // MARK: - Persistance

    private func load() {
        guard let raw = defaults.dictionary(forKey: key) else { return }
        var parsed: [String: Double] = [:]
        for (k, v) in raw {
            if let d = (v as? NSNumber)?.doubleValue { parsed[k] = d }
        }
        entries = Self.pruned(parsed, now: Date())
    }

    private func save() {
        if entries.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(entries, forKey: key)
        }
    }
}
