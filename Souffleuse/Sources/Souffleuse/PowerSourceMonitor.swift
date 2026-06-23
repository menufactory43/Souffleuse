import Foundation
import IOKit.ps
import SouffleuseLog

/// Callback C top-level (`@convention(c)`) du notifieur IOKit power-source. Il
/// s'exécute NONISOLÉ et ne peut capturer aucun contexte Swift — l'instance est
/// récupérée via le pointeur opaque passé à `IOPSNotificationCreateRunLoopSource`.
/// La source est ajoutée à la run-loop PRINCIPALE (`CFRunLoopGetMain`) → le
/// callback arrive sur le main thread, d'où le `MainActor.assumeIsolated`.
private func powerSourceChanged(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { monitor.refresh() }
}

/// Surveille la source d'alimentation (secteur ↔ batterie) et notifie au
/// branchement/débranchement. Alimente le mode « économie batterie » : le ghost
/// peut alors passer sur un modèle plus léger, des complétions plus courtes, ou se
/// suspendre — uniquement sur batterie. Lecture one-shot sûre + souscription notif.
@MainActor
final class PowerSourceMonitor {
    /// État courant, mis à jour par la notif. Lu en synchrone par la politique.
    private(set) var isOnBattery: Bool
    /// Appelé sur le main thread à chaque vrai changement d'alimentation.
    var onChange: (() -> Void)?

    /// `nonisolated(unsafe)` : écrite UNE fois dans `start()` (main), relue dans le
    /// `deinit` nonisolé pour le teardown. Sûr ici — les fonctions CFRunLoop sont
    /// thread-safe et l'écriture précède tout deinit (durée de vie = celle de l'app).
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?

    init() {
        isOnBattery = Self.currentIsOnBattery()
    }

    /// Crée et arme la source de notification sur la run-loop principale en
    /// `.commonModes` (pour rester vivante pendant une NSAlert modale). Idempotent.
    func start() {
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource(powerSourceChanged, context)?
            .takeRetainedValue() else {
            Log.warn(.input, "power_monitor_source_failed")
            return
        }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    /// Recalcule l'état et notifie SI il a changé (les notifs IOKit peuvent
    /// arriver sur des événements voisins — % batterie, etc. — sans bascule réelle).
    func refresh() {
        let now = Self.currentIsOnBattery()
        guard now != isOnBattery else { return }
        isOnBattery = now
        onChange?()
    }

    /// Lecture synchrone one-shot de la source qui alimente la machine.
    /// Mémoire CoreFoundation :
    ///  - `IOPSCopyPowerSourcesInfo()` suit la *Copy rule* → `takeRetainedValue()`.
    ///  - `IOPSGetProvidingPowerSourceType()` suit la *Get rule* → `takeUnretainedValue()`
    ///    (la CFString appartient au snapshot, gardé vivant le temps de la lecture).
    /// Le type retourné vaut `kIOPMACPowerKey` / `kIOPMBatteryPowerKey` / `kIOPMUPSPowerKey`.
    /// `nonisolated` : lecture pure (que des appels CF/IOKit, aucun état d'instance) →
    /// appelable depuis n'importe quel contexte, y compris une vue SwiftUI.
    nonisolated static func currentIsOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo() else { return false }
        let snapshot = info.takeRetainedValue()
        guard let typeRef = IOPSGetProvidingPowerSourceType(snapshot) else { return false }
        let type = typeRef.takeUnretainedValue() as String
        return type == kIOPMBatteryPowerKey
    }

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
    }
}

/// Décision PURE (testable) du mode économie batterie. Toutes les options sont OFF
/// par défaut et ne prennent effet QUE sur batterie : tout-OFF (ou secteur) ⇒
/// `effective == base` et `suppressGeneration == false` (zéro changement de comportement).
struct BatterySaverPolicy {
    var isOnBattery: Bool
    /// Complétions plus courtes sur batterie.
    var shorter: Bool
    /// Modèle plus léger sur batterie.
    var lighterModel: Bool
    /// Suspendre la génération du souffle sur batterie.
    var pause: Bool

    /// Longueur effective du souffle.
    func effectiveLength(base: CompletionLength) -> CompletionLength {
        (isOnBattery && shorter) ? .short : base
    }

    /// Id de modèle GGUF effectif. On ne bascule sur le léger que s'il est
    /// RÉSOLVABLE (téléchargé) — sinon on garderait le choix de l'utilisateur
    /// plutôt que de rendre le souffle muet sur batterie.
    func effectiveModelID(base: String, lightestID: String, lightestResolvable: Bool) -> String {
        (isOnBattery && lighterModel && lightestResolvable) ? lightestID : base
    }

    /// True quand la génération du souffle doit être suspendue.
    var suppressGeneration: Bool { isOnBattery && pause }
}
