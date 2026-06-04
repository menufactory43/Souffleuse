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
        entries.filter {
            $0.source == .prose
                && !SuggestionPolicy.isGreetingLike($0.accepted)
                && (activeDomain == .other || DomainCluster.cluster(for: $0.bundleID) == activeDomain)
        }
    }
}
