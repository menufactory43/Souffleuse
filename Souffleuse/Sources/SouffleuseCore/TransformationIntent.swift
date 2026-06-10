import Foundation

/// Intention de transformation déclenchée par « // ». Les cinq premières sont
/// les rangées fixes du picker (① corriger … ⑤ traduire) ; `.libre` porte
/// l'instruction tapée par l'utilisateur quand le filtre ne matche rien (⏎).
/// `ton` et `traduire` ne portent PAS leurs paramètres : le registre (ToneStore)
/// et la cible (ConversationTargetStore) sont résolus par l'appelant à la
/// sélection — ce type reste pur et sans dépendance store.
public enum TransformationIntent: Sendable, Equatable {
    case corriger
    case raccourcir
    case reformuler
    case ton
    case traduire
    case libre(String)

    /// Ordre des rangées du picker — la position visuelle (badge ①–⑤) = index + 1.
    public static let pickerOrder: [TransformationIntent] =
        [.corriger, .raccourcir, .reformuler, .ton, .traduire]

    /// Libellé français du picker. `.libre` n'a pas de rangée fixe.
    public var displayName: String {
        switch self {
        case .corriger: return "corriger"
        case .raccourcir: return "raccourcir"
        case .reformuler: return "reformuler"
        case .ton: return "ton"
        case .traduire: return "traduire"
        case .libre: return "instruction libre"
        }
    }

    /// Rangées du picker correspondant au filtre tapé après « // ».
    /// Prefix-match insensible à la casse et aux accents (« RAC » → raccourcir,
    /// « réf »/« ref » → reformuler). Filtre vide → les 5 rangées dans l'ordre.
    /// Aucun match → tableau vide : l'appelant traite l'entrée en `.libre` au ⏎.
    /// Pur, testable sans UI.
    public static func matches(filter: String) -> [TransformationIntent] {
        let f = Self.folded(filter)
        guard !f.isEmpty else { return pickerOrder }
        return pickerOrder.filter { Self.folded($0.displayName).hasPrefix(f) }
    }

    /// Pliage accents/casse partagé (fr) — « RÉF » et « ref » doivent matcher la
    /// même rangée, l'utilisateur tape vite et sans accents au clavier.
    static func folded(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive],
                  locale: Locale(identifier: "fr_FR"))
            .trimmingCharacters(in: .whitespaces)
    }
}
