import Foundation

/// Descripteur unifié d'un GGUF téléchargeable in-app — qu'il s'agisse d'un
/// modèle de TRADUCTION (`InstructModel`) ou d'une VOIX du souffle FR
/// (`GGUFModelOption`). Permet à `ModelDownloadManager` de traiter les deux types
/// via une seule API, clé = `filename` (unique sur disque).
public struct DownloadableModel: Sendable, Hashable, Identifiable {
    /// Identité d'affichage (ForEach) — pas la clé de téléchargement.
    public let id: String
    public let displayName: String
    /// Nom de fichier de DESTINATION dans `Models/` (peut différer du nom distant :
    /// on télécharge un GGUF `-pt` et on l'enregistre sous le nom attendu par le
    /// catalogue).
    public let filename: String
    public let url: URL
    public let approxSizeMB: Int

    public init(id: String, displayName: String, filename: String, url: URL, approxSizeMB: Int) {
        self.id = id
        self.displayName = displayName
        self.filename = filename
        self.url = url
        self.approxSizeMB = approxSizeMB
    }
}
