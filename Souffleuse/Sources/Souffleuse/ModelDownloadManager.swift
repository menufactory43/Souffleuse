import Foundation
import Observation
import SouffleuseCore
import SouffleuseLog

/// Télécharge à la demande les GGUF des modèles de traduction (`InstructModel`)
/// dans `~/Library/Application Support/Souffleuse/Models/`.
///
/// Réseau autorisé UNIQUEMENT ici (premier téléchargement du modèle) — aucune
/// autre source réseau au runtime. Streamé sur disque par `URLSessionDownloadTask`
/// (pas en mémoire : les GGUF font ~1 Go), déplacé atomiquement à l'arrivée. Les
/// états sont `@Observable` pour piloter l'UI Préférences (bouton / progression /
/// coche). Aucun texte utilisateur ne touche le log (events `StaticString`).
@MainActor
@Observable
final class ModelDownloadManager: NSObject {
    enum Status: Equatable, Sendable {
        case absent
        case downloading(Double)   // fraction 0…1
        case ready
        case failed
    }

    private(set) var status: [InstructModel: Status] = [:]
    @ObservationIgnored private var tasks: [InstructModel: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var session: URLSession!
    /// `nonisolated` : lu depuis les callbacks de délégué (hors MainActor).
    @ObservationIgnored nonisolated let modelsDir: URL

    override init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Souffleuse/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        modelsDir = dir
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        refresh()
    }

    nonisolated func fileURL(_ m: InstructModel) -> URL {
        modelsDir.appendingPathComponent(m.ggufFilename)
    }

    func isReady(_ m: InstructModel) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(m).path)
    }

    /// Recalcule les états depuis le disque (sauf téléchargements en cours).
    func refresh() {
        for m in InstructModel.allCases where tasks[m] == nil {
            status[m] = isReady(m) ? .ready : .absent
        }
    }

    /// Démarre (ou redémarre) le téléchargement d'un modèle absent.
    func download(_ m: InstructModel) {
        guard tasks[m] == nil, !isReady(m) else { return }
        status[m] = .downloading(0)
        let task = session.downloadTask(with: m.downloadURL)
        task.taskDescription = m.rawValue
        tasks[m] = task
        Log.info(.predictor, "model_download_start")
        task.resume()
    }
}

extension ModelDownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0,
              let raw = downloadTask.taskDescription, let m = InstructModel(rawValue: raw) else { return }
        let frac = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in self.status[m] = .downloading(frac) }
    }

    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let raw = downloadTask.taskDescription, let m = InstructModel(rawValue: raw) else { return }
        // Le fichier temporaire est supprimé au retour de ce callback → on le
        // déplace ICI, synchrone, via un `.part` puis renommage (atomique).
        let dest = modelsDir.appendingPathComponent(m.ggufFilename)
        let part = dest.appendingPathExtension("part")
        var ok = false
        do {
            try? FileManager.default.removeItem(at: part)
            try FileManager.default.moveItem(at: location, to: part)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: part, to: dest)
            ok = FileManager.default.fileExists(atPath: dest.path)
        } catch {
            ok = false
        }
        let success = ok
        Task { @MainActor in
            self.tasks[m] = nil
            self.status[m] = success ? .ready : .failed
            if success { Log.info(.predictor, "model_download_done") }
            else { Log.error(.predictor, "model_download_failed") }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        // Succès → `error == nil` (déjà traité dans didFinishDownloadingTo). On ne
        // gère ici QUE l'échec réseau (le fichier n'est jamais arrivé).
        guard error != nil, let raw = task.taskDescription, let m = InstructModel(rawValue: raw) else { return }
        Task { @MainActor in
            self.tasks[m] = nil
            if self.status[m] != .ready { self.status[m] = .failed }
            Log.error(.predictor, "model_download_failed")
        }
    }
}
