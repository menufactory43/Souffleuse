import Foundation
import Testing
import SouffleuseCore
@testable import Souffleuse

/// Un seul GGUF à la fois : ces tests couvrent la garde d'exclusion mutuelle et
/// l'annulation ajoutées pour éviter deux téléchargements de modèles en
/// parallèle depuis les réglages (bouton « Annuler » manquant, cf. bug rapporté).
/// Reste dans le synchrone volontairement — dès que `.resume()` est appelé, la
/// suite ne doit pas dépendre du réseau réel ni de sa complétion.
@MainActor
@Suite("ModelDownloadManager")
struct ModelDownloadManagerTests {
    private func model(_ name: String) -> DownloadableModel {
        DownloadableModel(
            id: name, displayName: name, filename: "\(name).gguf",
            url: URL(string: "https://example.invalid/\(name).gguf")!,
            approxSizeMB: 100
        )
    }

    @Test("download() démarre le téléchargement d'un modèle absent")
    func downloadStartsAbsentModel() {
        let manager = ModelDownloadManager()
        let m = model("alpha")
        manager.download(m)
        #expect(manager.status(for: m) == .downloading(0))
        #expect(manager.isDownloadingAny)
    }

    @Test("download() sur un second modèle est un no-op tant qu'un premier télécharge")
    func secondDownloadIsBlockedWhileFirstActive() {
        let manager = ModelDownloadManager()
        let first = model("alpha")
        let second = model("beta")

        manager.download(first)
        manager.download(second)

        #expect(manager.status(for: first) == .downloading(0))
        #expect(manager.status(for: second) == .absent)
    }

    @Test("cancel() remet le modèle à absent et libère l'exclusion")
    func cancelResetsStatusAndUnblocksOthers() {
        let manager = ModelDownloadManager()
        let first = model("alpha")
        let second = model("beta")

        manager.download(first)
        manager.cancel(first)

        #expect(manager.status(for: first) == .absent)
        #expect(!manager.isDownloadingAny)

        manager.download(second)
        #expect(manager.status(for: second) == .downloading(0))
    }

    @Test("cancel() sur un modèle non actif est un no-op")
    func cancelOnInactiveModelIsNoOp() {
        let manager = ModelDownloadManager()
        let m = model("alpha")
        manager.cancel(m)
        #expect(manager.status(for: m) == .absent)
        #expect(!manager.isDownloadingAny)
    }
}
