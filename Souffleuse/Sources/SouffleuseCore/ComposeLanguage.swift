import Foundation

/// Langue de sortie du **mode rédaction** (« // » en début de champ + amorce).
/// Préférence utilisateur : soit on suit la langue de la conversation
/// (`.conversation` — épingle manuelle de cible OU langue détectée du
/// correspondant, repli langue système), soit on fige une langue. Persistée en
/// raw string dans `PreferencesStore`. Défaut produit côté store : `.french`
/// (le comportement d'origine, FR neutre).
///
/// Périmètre des langues = celui de la traduction V1 (`TranslationTarget` :
/// EN/ES/DE/IT) + le français source. JA volontairement absent : la 1B
/// hallucine hors de ce périmètre (même prudence que le gate V1 traduction).
public enum ComposeLanguage: String, Sendable, Equatable, Codable, CaseIterable {
    case conversation
    case french
    case english
    case spanish
    case german
    case italian

    /// Langues CONCRÈTES offertes comme rangées du picker rédaction (sans
    /// `.conversation`, qui est une politique de résolution, pas une langue).
    /// Ordre du menu = ordre de repli quand une langue est mise en tête.
    public static let composable: [ComposeLanguage] = [.french, .english, .spanish, .german, .italian]

    /// Mappe une cible de traduction sur la langue de rédaction correspondante.
    /// JA est hors périmètre rédaction (la 1B hallucine) → français.
    public static func from(target: TranslationTarget) -> ComposeLanguage {
        switch target {
        case .en: return .english
        case .es: return .spanish
        case .de: return .german
        case .it: return .italian
        case .ja: return .french
        }
    }

    /// Libellé du menu Préférences, dans la langue d'interface courante.
    public var menuLabel: String {
        switch self {
        case .conversation: return tr(fr: "Suivre la conversation", en: "Follow the conversation")
        case .french: return tr(fr: "Français", en: "French")
        case .english: return tr(fr: "Anglais", en: "English")
        case .spanish: return tr(fr: "Espagnol", en: "Spanish")
        case .german: return tr(fr: "Allemand", en: "German")
        case .italian: return tr(fr: "Italien", en: "Italian")
        }
    }

    /// Nom de langue (en français, sans article) injecté dans la consigne de
    /// rédaction (« rédige … EN <NOM> »). `nil` pour `.conversation` : la langue
    /// est alors résolue dynamiquement par l'appelant (cible de conversation,
    /// détection, repli système).
    public var promptLanguageName: String? {
        switch self {
        case .conversation: return nil
        case .french: return "français"
        case .english: return "anglais"
        case .spanish: return "espagnol"
        case .german: return "allemand"
        case .italian: return "italien"
        }
    }

    /// Repli quand « suivre la conversation » est actif mais qu'aucune langue
    /// n'est détectable (pas de correspondant visible) : la langue préférée du
    /// système macOS, mappée sur le périmètre supporté. Impur (lit `Locale`) —
    /// la logique testable vit dans `fallbackName(systemCode:)`.
    public static func systemFallbackName() -> String {
        systemFallback().promptLanguageName ?? "français"
    }

    /// Repli système concret (pour ordonner les rangées du picker). Mappe la
    /// langue préférée du Mac sur une langue composable, sinon français.
    /// Impur (lit `Locale`) — logique testable dans `fallback(systemCode:)`.
    public static func systemFallback() -> ComposeLanguage {
        fallback(systemCode: Locale.preferredLanguages.first ?? "fr")
    }

    /// Mappe un code BCP-47 (ex. `"en-US"`) vers une langue composable concrète.
    /// Hors périmètre supporté → français. Pur, testable.
    public static func fallback(systemCode raw: String) -> ComposeLanguage {
        let base = raw.lowercased().split(separator: "-").first.map(String.init) ?? raw.lowercased()
        switch base {
        case "fr": return .french
        case "en": return .english
        case "es": return .spanish
        case "de": return .german
        case "it": return .italian
        default: return .french
        }
    }

    /// Nom de langue de rédaction pour un code système — `fallback` + son nom FR.
    /// Hors périmètre supporté (fr/en/es/de/it) → français. Pur, testable.
    public static func fallbackName(systemCode raw: String) -> String {
        fallback(systemCode: raw).promptLanguageName ?? "français"
    }
}
