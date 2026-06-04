import AppKit
import Sparkle

/// Contrôleur de mise à jour MANUELLE uniquement.
///
/// Encapsule `SPUStandardUpdaterController` et désactive explicitement
/// tout check automatique (zéro poll passif — ARCHITECTURE.md §339 :
/// "pas de Sparkle auto-check en v1 ; l'utilisateur clique pour vérifier").
/// La vérification ne se déclenche qu'à l'appel explicite de `checkForUpdates()`.
@MainActor final class UpdaterController {
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // Défense en profondeur : SUEnableAutomaticChecks=false dans Info.plist
        // est la source de vérité, mais on désactive aussi ici par cohérence
        // (ARCHITECTURE.md:339 zero-leak, pas de poll passif).
        controller.updater.automaticallyChecksForUpdates = false
    }

    /// Déclenche la vérification des mises à jour (UI Sparkle standard).
    /// À appeler uniquement sur action explicite de l'utilisateur (clic menu).
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
