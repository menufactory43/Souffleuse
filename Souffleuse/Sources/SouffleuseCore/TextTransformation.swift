import Foundation

/// Transformation prête à générer : la portée résolue par le détecteur + l'intention
/// choisie au picker. Franchit la frontière AppDelegate → runtime → commit, donc
/// `Sendable` immuable.
public struct TextTransformation: Sendable, Equatable {
    /// Texte (trimé) envoyé au modèle.
    public let scopeText: String
    public let intent: TransformationIntent
    /// Vrai si la portée a été réduite au dernier paragraphe (> 1500 chars) —
    /// le header du HUD l'indique (« dernier paragraphe »).
    public let isScopeTruncated: Bool
    /// Caractères avant le caret supprimés au Tab (portée + « // » + filtre).
    public let deleteCharsOnAccept: Int

    public init(
        scopeText: String,
        intent: TransformationIntent,
        isScopeTruncated: Bool,
        deleteCharsOnAccept: Int
    ) {
        self.scopeText = scopeText
        self.intent = intent
        self.isScopeTruncated = isScopeTruncated
        self.deleteCharsOnAccept = deleteCharsOnAccept
    }
}
