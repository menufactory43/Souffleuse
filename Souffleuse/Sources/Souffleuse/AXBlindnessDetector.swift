import Foundation

// MARK: - AX "trusted but blind" detector

/// Détecteur « autorisé mais aveugle ».
///
/// `AXIsProcessTrusted()` ment parfois : il renvoie `true` (l'interrupteur paraît
/// coché, l'app se croit autorisée) alors que **toutes les lectures AX échouent**.
/// Ça arrive quand le grant TCC est périmé — après une mise à jour Sparkle (nouveau
/// binaire), un changement de signature, ou des entrées TCC empilées. Symptôme vécu :
/// le souffle ne sort jamais, sans le moindre indice → cul-de-sac silencieux, le pire
/// pour une app qui se veut irréprochable.
///
/// Signature exploitable (cf. `AXClient.readSnapshot`) : quand l'AX est aveugle,
/// `kAXFocusedUIElementAttribute` est introuvable pour **toutes** les apps → le
/// snapshot porte `role == nil`. Un état sain donne toujours un `role` (même sur un
/// bouton). Piège : la dormance AX de Chromium (`AutoDisableAccessibility`) produit
/// aussi `role == nil`, MAIS par-app et transitoire — d'où l'exigence d'un
/// aveuglement **soutenu** ET sur **plusieurs apps distinctes** avant d'alerter.
///
/// Le détecteur n'est consulté que lorsque l'AX est CENSÉE répondre (le tick a déjà
/// passé `guard AXClient.isTrusted`), ce qui est exactement la prémisse « trusted ».
struct AXBlindnessDetector {
    /// Durée minimale d'aveuglement continu avant de prévenir.
    static let minBlindSeconds: TimeInterval = 20

    /// Nombre d'apps distinctes vues aveugles avant de prévenir (garde anti-Chromium :
    /// une seule app dormante ne suffit jamais à déclencher).
    static let minDistinctApps = 2

    private(set) var firstBlindAt: Date?
    private(set) var blindApps: Set<String> = []
    /// Vrai une fois l'alerte émise — empêche le re-spam tant que l'AX ne répond pas.
    private(set) var noticed = false

    /// Observe un snapshot. Renvoie `true` **une seule fois** au moment où l'état
    /// aveugle est confirmé — au caller de réagir (guider l'utilisateur).
    ///
    /// - `bundleID` : app au premier plan (issue de NSWorkspace, lisible même aveugle).
    /// - `focusedRoleIsNil` : l'élément focus AX est-il introuvable (`snap.role == nil`).
    /// - `now` : horloge injectée pour testabilité.
    mutating func observe(bundleID: String?, focusedRoleIsNil: Bool, now: Date) -> Bool {
        // Un élément focus lisible (ou pas d'app au premier plan) ⇒ l'AX répond :
        // on réarme tout, y compris `noticed` (l'AX remarche → on pourra ré-alerter
        // si elle retombe plus tard).
        guard focusedRoleIsNil, let bundleID else {
            reset()
            return false
        }

        if firstBlindAt == nil { firstBlindAt = now }
        blindApps.insert(bundleID)

        guard !noticed,
              let first = firstBlindAt,
              now.timeIntervalSince(first) >= Self.minBlindSeconds,
              blindApps.count >= Self.minDistinctApps
        else { return false }

        noticed = true
        return true
    }

    /// Réarme le détecteur (AX a répondu, ou reset manuel).
    mutating func reset() {
        firstBlindAt = nil
        blindApps.removeAll()
        noticed = false
    }
}
