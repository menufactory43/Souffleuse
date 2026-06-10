import AppKit

/// Une application candidate pour les règles « par application » (ton,
/// allowlist…). L'utilisateur la choisit par son NOM et son icône — le bundle
/// ID (que personne ne connaît) redevient un détail d'implémentation.
struct AppEntry: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let path: String

    var id: String { bundleID }

    /// Icône résolue à la demande — `NSWorkspace.icon(forFile:)` est caché par
    /// le système, pas besoin de la stocker.
    @MainActor var icon: NSImage { NSWorkspace.shared.icon(forFile: path) }
}

/// Catalogue des applications visibles de la machine : dossiers Applications
/// (système, local, utilisateur — profondeur 2 pour Utilities & co) + les apps
/// en cours d'exécution. Dédupliqué par bundle ID, trié par nom localisé.
@MainActor
enum AppCatalog {
    /// Scan complet (~quelques dizaines de ms pour ~100 apps) — appelé à
    /// l'ouverture de la feuille d'édition, pas en continu.
    static func entries() -> [AppEntry] {
        var byBundleID: [String: AppEntry] = [:]
        let fm = FileManager.default

        let roots = [
            "/Applications",
            "/System/Applications",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications"),
        ]
        for root in roots {
            guard let children = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for child in children {
                let path = (root as NSString).appendingPathComponent(child)
                if child.hasSuffix(".app") {
                    addApp(atPath: path, into: &byBundleID)
                } else if (try? fm.contentsOfDirectory(atPath: path)) != nil {
                    // Sous-dossier (Utilities, Setapp…) : un niveau de plus.
                    for nested in (try? fm.contentsOfDirectory(atPath: path)) ?? []
                    where nested.hasSuffix(".app") {
                        addApp(atPath: (path as NSString).appendingPathComponent(nested),
                               into: &byBundleID)
                    }
                }
            }
        }

        // Les apps qui TOURNENT : couvre celles installées ailleurs (DMG lancé
        // direct, brew Cask hors /Applications…). C'est souvent l'app que
        // l'utilisateur veut régler — elle est ouverte devant lui.
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular {
            guard let bid = app.bundleIdentifier, byBundleID[bid] == nil,
                  let url = app.bundleURL else { continue }
            byBundleID[bid] = AppEntry(
                bundleID: bid,
                name: app.localizedName ?? displayName(forPath: url.path),
                path: url.path
            )
        }

        return byBundleID.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Résolution inverse pour l'affichage des règles existantes : bundle ID →
    /// app installée (nil si introuvable — la règle reste affichée en ID brut).
    static func entry(forBundleID bundleID: String) -> AppEntry? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return AppEntry(bundleID: bundleID, name: displayName(forPath: url.path), path: url.path)
    }

    private static func addApp(atPath path: String, into dict: inout [String: AppEntry]) {
        guard let bundle = Bundle(path: path), let bid = bundle.bundleIdentifier,
              dict[bid] == nil else { return }
        dict[bid] = AppEntry(bundleID: bid, name: displayName(forPath: path), path: path)
    }

    /// Nom localisé Finder, « .app » retiré.
    private static func displayName(forPath path: String) -> String {
        let name = FileManager.default.displayName(atPath: path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
