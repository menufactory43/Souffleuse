import Foundation
import SouffleusePersonalization

/// Sélection de la prose de démonstration few-shot, **scopée par registre**
/// (P1.2 / P1.3).
///
/// Point unique partagé par `predict()` (long-ghost initial) et `extendGhost`
/// (refill glissant) : tous deux n'injectent comme exemples de style QUE la prose
/// de l'utilisateur écrite dans une app du **même `DomainCluster`** que l'app
/// focus — pour qu'aucun autre registre (le privé `.chat`, le `.code`) ne fuite
/// comme démonstration de style, et que la continuation reste cohérente.
///
/// `activeDomain == .other` (app inconnue / nil) ⇒ **aucun scope** : toute la
/// prose est éligible (comportement historique préservé, garde-fou tests).
public enum FewShotScoping {
    /// Filtre `entries` aux seules entrées éligibles comme exemples few-shot :
    /// `.prose` (jamais les fragments `.accept`), non-salutation (les « Bonjour »
    /// polluaient par cross-pollinisation), et — si `activeDomain != .other` — du
    /// même cluster de registre que l'app focus.
    public static func scopedExamplesPool(
        _ entries: [TypingHistoryEntry],
        activeDomain: DomainCluster
    ) -> [TypingHistoryEntry] {
        // Le scope `.prose` + cluster de registre est partagé avec le recall L1
        // (`SuggestionPolicy.routeInstant`) via `DomainCluster.scopedProse` — un
        // seul endroit définit l'invariant privacy. On ne fait COMPOSER ici que
        // les filtres propres à la DÉMONSTRATION de style : pas de salutation
        // (cross-pollinisation), pas d'URL/chemin (dilue la « voix »).
        DomainCluster.scopedProse(entries, to: activeDomain).filter {
            !SuggestionPolicy.isGreetingLike($0.accepted)
                && !isUrlOrPathHeavy($0.accepted)
        }
    }

    /// Exclut les entrées dominées par une URL / un chemin / un hash — du bruit
    /// pour la DÉMONSTRATION de style (le navigateur capte beaucoup de liens
    /// collés, ce qui dilue le signal « voix » : mesuré, ~moitié du pool `.web`).
    /// On ne les retire QUE du few-shot ; elles restent disponibles pour le
    /// recall/n-gram. Heuristique conservatrice (ne touche pas la prose FR
    /// normale) : schéma d'URL, préfixe de chemin, ≥3 « / », ou un token ≥30
    /// caractères sans espace (hash / URL / chemin long).
    static func isUrlOrPathHeavy(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        let lower = t.lowercased()
        if lower.contains("http://") || lower.contains("https://")
            || lower.contains("file://") || lower.contains("www.")
            || lower.contains("/users/") { return true }
        if t.hasPrefix("/") || t.hasPrefix("~/") { return true }
        if t.filter({ $0 == "/" }).count >= 3 { return true }
        let longestToken = t.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(\.count).max() ?? 0
        if longestToken >= 30 { return true }
        return false
    }
}
