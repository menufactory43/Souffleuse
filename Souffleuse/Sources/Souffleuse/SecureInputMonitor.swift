import Carbon.HIToolbox
import Foundation

/// Accès à l'état GLOBAL macOS « Secure Input » (saisie sécurisée). Quand une app
/// (souvent un gestionnaire de mots de passe, un terminal, ou une fenêtre de
/// connexion) l'active et oublie de la relâcher, le `CGEventTap` de session ne
/// reçoit plus AUCUN keyDown — nos accepts Tab/Échap deviennent silencieusement
/// inertes et l'utilisateur croit l'app cassée. On détecte cet état pour le lui
/// expliquer (Cotypist 2026.2 fait pareil).
enum SecureInput {
    /// True quand macOS est en saisie sécurisée. `IsSecureEventInputEnabled()` est
    /// importée en `Bool` par le SDK macOS courant — on la renvoie telle quelle.
    ///
    /// MUST be called on the main thread : `IsSecureEventInputEnabled` n'est pas
    /// thread-safe. Ne jamais l'appeler depuis un callback IOKit ni un Task détaché.
    static func isEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }
}

/// Décision PURE (testable sans système) du « faut-il prévenir l'utilisateur que
/// la saisie sécurisée bloque nos raccourcis ? ». Un *épisode* = une plage continue
/// où la saisie sécurisée est ON ; on ne prévient qu'UNE fois par épisode et
/// seulement pendant qu'un souffle est à l'écran (sinon le blocage n'a aucun effet
/// visible). Le passage ON→OFF réarme pour le prochain épisode légitime.
struct SecureInputWatcher {
    /// True tant que l'épisode courant (saisie sécurisée ON) a déjà déclenché une
    /// alerte. Remis à false dès que la saisie sécurisée repasse OFF — c'est ce
    /// passage à OFF qui clôt l'épisode et réarme pour le suivant.
    private(set) var warnedThisEpisode = false

    /// Évalue l'état courant et renvoie `true` SI une alerte doit être présentée
    /// MAINTENANT (saisie sécurisée ON + un souffle visible + pas déjà prévenu cet
    /// épisode). Doit être appelée régulièrement (depuis `tick()`), pas seulement au
    /// moment du peint, pour capter le passage ON→OFF même sans nouvelle frappe.
    mutating func evaluate(secureInputOn: Bool, ghostActive: Bool) -> Bool {
        if !secureInputOn {
            warnedThisEpisode = false   // fin d'épisode → réarme
            return false
        }
        guard ghostActive, !warnedThisEpisode else { return false }
        warnedThisEpisode = true
        return true
    }
}
