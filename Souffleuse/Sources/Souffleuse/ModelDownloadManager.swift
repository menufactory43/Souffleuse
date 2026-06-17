import Foundation
import Observation
import SouffleuseCore
import SouffleuseLog

/// Télécharge à la demande les GGUF (traduction `InstructModel` **et** voix du
/// souffle `GGUFModelOption`) dans `~/Library/Application Support/Souffleuse/Models/`,
/// via le descripteur unifié `DownloadableModel`.
///
/// Réseau autorisé UNIQUEMENT ici (premier téléchargement du modèle). Streamé sur
/// disque par `URLSessionDownloadTask` (les GGUF font 0,8–2,4 Go), déplacé
/// atomiquement à l'arrivée sous le `filename` de destination (qui peut différer
/// du nom distant : on récupère un GGUF `-pt` enregistré sous le nom du catalogue).
/// États `@Observable` pour l'UI Préférences. Clé = `filename` (unique sur disque).
/// Aucun texte utilisateur ne touche le log (events `StaticString`).
@MainActor
@Observable
final class ModelDownloadManager: NSObject {
    enum Status: Equatable, Sendable {
        case absent
        case downloading(Double)   // fraction 0…1
        case ready
        case failed
    }

    /// État par `filename`.
    private(set) var status: [String: Status] = [:]
    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var session: URLSession!
    /// `nonisolated` : lu depuis les callbacks de délégué (hors MainActor).
    @ObservationIgnored nonisolated let modelsDir: URL

    override init() {
        let dir = FileManager.souffleuseSupportDirectory(subpath: "Models")
        modelsDir = dir
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    nonisolated func fileURL(_ filename: String) -> URL {
        modelsDir.appendingPathComponent(filename)
    }

    func isReady(_ m: DownloadableModel) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(m.filename).path)
    }

    /// État courant d'un modèle (consulte le disque si on n'a pas encore d'entrée).
    func status(for m: DownloadableModel) -> Status {
        if let s = status[m.filename] { return s }
        return isReady(m) ? .ready : .absent
    }

    /// Recalcule les états des modèles fournis depuis le disque (hors
    /// téléchargements en cours).
    func refresh(_ models: [DownloadableModel]) {
        for m in models where tasks[m.filename] == nil {
            status[m.filename] = isReady(m) ? .ready : .absent
        }
    }

    /// Démarre (ou redémarre) le téléchargement d'un modèle absent.
    func download(_ m: DownloadableModel) {
        guard tasks[m.filename] == nil, !isReady(m) else { return }
        status[m.filename] = .downloading(0)
        let task = session.downloadTask(with: m.url)
        task.taskDescription = m.filename
        tasks[m.filename] = task
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
        guard totalBytesExpectedToWrite > 0, let filename = downloadTask.taskDescription else { return }
        let frac = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in self.status[filename] = .downloading(frac) }
    }

    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let filename = downloadTask.taskDescription else { return }
        // Le fichier temporaire est supprimé au retour de ce callback → on le
        // déplace ICI, synchrone, via un `.part` puis renommage (atomique).
        let dest = modelsDir.appendingPathComponent(filename)
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
            self.tasks[filename] = nil
            self.status[filename] = success ? .ready : .failed
            if success { Log.info(.predictor, "model_download_done") }
            else { Log.error(.predictor, "model_download_failed") }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        // Succès → `error == nil` (déjà traité dans didFinishDownloadingTo). On ne
        // gère ici QUE l'échec réseau (le fichier n'est jamais arrivé).
        guard error != nil, let filename = task.taskDescription else { return }
        Task { @MainActor in
            self.tasks[filename] = nil
            if self.status[filename] != .ready { self.status[filename] = .failed }
            Log.error(.predictor, "model_download_failed")
        }
    }
}
