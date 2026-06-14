import Foundation

/// Préférence de langue d'interface choisie par l'utilisateur. `.system` suit la
/// langue du Mac (résolue au lancement) ; `.fr`/`.en` forcent une langue. Persistée
/// en raw string dans `PreferencesStore` (clé `uiLanguage`). N'affecte QUE le
/// chrome de l'app (menus, fenêtres, HUD) — jamais le texte généré par le ghost
/// ni les consignes de relecture, qui suivent ce que l'utilisateur écrit.
public enum UILanguage: String, CaseIterable, Sendable {
    case system, fr, en

    /// Libellé du sélecteur, rendu dans la langue d'interface courante pour
    /// l'entrée « Système » et en nom natif pour les langues concrètes.
    public var pickerLabel: String {
        switch self {
        case .system: return tr(fr: "Système", en: "System")
        case .fr: return "Français"
        case .en: return "English"
        }
    }
}

/// Langue concrète effectivement rendue (jamais `.system` — déjà résolue).
public enum AppLanguage: String, Sendable {
    case fr, en
}

/// Résout puis mémorise la langue d'interface courante. Lu par `tr` depuis
/// n'importe quel isolement — l'UI `@MainActor` comme les `static let` non-isolés
/// des catalogues (`GGUFModelOption`, `ModelOption`) — d'où la synchro interne par
/// `NSLock` et le `@unchecked Sendable` (même pattern que `LogWriter`/`TypoDetector`).
/// La langue ne change qu'au lancement ou via le sélecteur des Préférences : la
/// contention est nulle.
public final class Localizer: @unchecked Sendable {
    public static let shared = Localizer()

    private let lock = NSLock()
    private var resolved: AppLanguage

    private init() {
        resolved = Localizer.systemLanguage()
    }

    /// Langue concrète courante. Défaut = langue du Mac tant qu'aucune préférence
    /// n'a été appliquée (l'init de `PreferencesStore` la fixe au lancement).
    public var current: AppLanguage {
        lock.lock(); defer { lock.unlock() }
        return resolved
    }

    /// Applique la préférence utilisateur (`.system` re-résout via le Mac).
    public func apply(_ preference: UILanguage) {
        let next = Localizer.resolve(preference)
        lock.lock(); resolved = next; lock.unlock()
    }

    /// Mappe une préférence sur une langue concrète.
    public static func resolve(_ preference: UILanguage) -> AppLanguage {
        switch preference {
        case .fr: return .fr
        case .en: return .en
        case .system: return systemLanguage()
        }
    }

    /// Langue du Mac : `.fr` si la première langue préférée est une variante de
    /// français, sinon `.en` (l'anglais sert de cible « tout le reste »).
    public static func systemLanguage() -> AppLanguage {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return preferred.hasPrefix("fr") ? .fr : .en
    }
}

/// Sélectionne la variante de chaîne selon la langue d'interface courante.
/// Convention « français-first inline » conservée : le texte reste au point
/// d'appel, aucun `.strings`/`NSLocalizedString`. Non-isolé exprès — appelable
/// depuis les statics de catalogue comme depuis l'UI `@MainActor`.
public func tr(fr: String, en: String) -> String {
    Localizer.shared.current == .fr ? fr : en
}
