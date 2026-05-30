import Foundation

/// Registre/ton de la **relecture FR→FR** (réécriture sans traduction).
///
/// Choisi PAR APPLICATION (Slack décontracté, courriel formel…) via le
/// `ToneStore`, défaut global `.neutral`. Le fragment `registerInstruction` est
/// injecté dans la consigne instruct par `GemmaChatPrompt.reformulation` : il dit
/// COMMENT réécrire, jamais quoi dire. Pur, on-device, aucune dépendance UI.
public enum Tone: String, Sendable, Codable, CaseIterable {
    case casual
    case neutral
    case formal

    /// Libellé Préférences (FR).
    public var displayName: String {
        switch self {
        case .casual: return "Décontracté"
        case .neutral: return "Neutre"
        case .formal: return "Formel"
        }
    }

    /// Phrase de registre injectée dans la consigne de relecture : décrit le
    /// registre cible, sans changer le sens du message.
    public var registerInstruction: String {
        switch self {
        case .casual:
            return "Registre décontracté : tutoiement, ton direct et naturel, phrases courtes — mais toujours correct et poli."
        case .neutral:
            return "Registre neutre : clair, standard et professionnel, ni familier ni guindé."
        case .formal:
            return "Registre formel : vouvoiement, formulation soignée et courtoise, tournures complètes."
        }
    }
}
