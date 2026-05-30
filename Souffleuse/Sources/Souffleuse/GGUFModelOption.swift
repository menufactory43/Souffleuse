import Foundation
import SouffleuseCore

/// Catalogue of selectable **GGUF (llama.cpp)** models — the real engine that
/// drives the ghost text. One model is active at a time (Cotypist-style). This
/// REPLACES the old `ModelOption.catalogue` (MLX) as the user-facing picker :
/// the MLX container is no longer tied to the user's choice (it survives only
/// as the legacy n-gram tokenizer, best-effort).
///
/// Each entry resolves a local `.gguf` file via the same precedence as the old
/// `ModelRuntime.resolveGGUFPath` :
///   1. `SOUFFLEUSE_GGUF` env override (global, debug) — wins for ALL entries.
///   2. `~/Library/Application Support/Souffleuse/Models/<file>` if it exists.
///   3. fallback `~/Library/Application Support/app.cotypist.Cotypist/Models/<file>`.
/// An entry whose file can't be found at (2) or (3) is reported unresolved so
/// the UI can grey it out with a "fichier introuvable" hint.
struct GGUFModelOption: Identifiable, Sendable, Hashable {
    /// Stable identifier persisted to UserDefaults (NOT a filename, so we can
    /// rename files later without breaking the stored preference).
    let id: String
    /// French display label shown in the picker.
    let displayName: String
    /// Quantisation subtitle (e.g. "Q5_K_M").
    let quant: String
    /// Short speed/quality hint shown under the row.
    let hint: String
    /// The on-disk filename this entry resolves.
    let fileName: String
    /// URL HF du GGUF à télécharger si absent (`nil` = non téléchargeable in-app).
    /// On télécharge la variante **base/pt** (le souffle FR est une continuation
    /// brute, pas un chat instruct) et on l'enregistre sous `fileName`.
    let downloadURL: URL?
    /// Taille approximative (Mo) pour l'affichage.
    let approxSizeMB: Int

    /// Descripteur de téléchargement unifié (`nil` si pas d'URL).
    var downloadable: DownloadableModel? {
        guard let downloadURL else { return nil }
        return DownloadableModel(
            id: "ghost-" + id,
            displayName: displayName,
            filename: fileName,
            url: downloadURL,
            approxSizeMB: approxSizeMB)
    }

    /// Resolves this entry's local GGUF path. Returns nil when the file can't be
    /// found (entry should be shown disabled). The `SOUFFLEUSE_GGUF` env var, when
    /// set, overrides resolution for every entry (debug seam).
    func resolvePath() -> String? {
        Self.resolvePath(fileName: fileName)
    }

    /// True when this entry's GGUF file is resolvable on disk (or overridden).
    var isResolvable: Bool { resolvePath() != nil }

    /// Path resolution split out as a `static` so it's testable without an
    /// instance and shareable with `ModelRuntime`.
    static func resolvePath(fileName: String) -> String? {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            .map { $0.appendingPathComponent("Souffleuse/Models").path }
        let cotypist = (("~/Library/Application Support/app.cotypist.Cotypist/Models") as NSString)
            .expandingTildeInPath
        return resolvePath(
            fileName: fileName,
            envOverride: ProcessInfo.processInfo.environment["SOUFFLEUSE_GGUF"],
            souffleuseModelsDir: appSupport,
            cotypistModelsDir: cotypist,
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    /// Pure, injectable resolution core — used directly by tests. Precedence :
    /// env override → Souffleuse dir → Cotypist dir → nil.
    static func resolvePath(
        fileName: String,
        envOverride: String?,
        souffleuseModelsDir: String?,
        cotypistModelsDir: String,
        fileExists: (String) -> Bool
    ) -> String? {
        if let override = envOverride, !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        if let dir = souffleuseModelsDir {
            let local = (dir as NSString).appendingPathComponent(fileName)
            if fileExists(local) { return local }
        }
        let fallback = (cotypistModelsDir as NSString).appendingPathComponent(fileName)
        if fileExists(fallback) { return fallback }
        return nil
    }

    /// v1 catalogue : the two Gemma 3 GGUFs already on disk via Cotypist.
    static let catalogue: [GGUFModelOption] = [
        GGUFModelOption(
            id: "gemma-3-1b-q5",
            displayName: "Gemma 3 1B · Q5_K_M",
            quant: "Q5_K_M",
            hint: "Rapide — défaut, faible RAM",
            fileName: "gemma-3-1b.i1-Q5_K_M.gguf",
            downloadURL: URL(string: "https://huggingface.co/mradermacher/gemma-3-1b-pt-i1-GGUF/resolve/main/gemma-3-1b-pt.i1-Q5_K_M.gguf"),
            approxSizeMB: 811
        ),
        GGUFModelOption(
            id: "gemma-3-4b-q4",
            displayName: "Gemma 3 4B · Q4_K_M",
            quant: "Q4_K_M",
            hint: "Qualité — plus lent, ~2.5 Go RAM",
            fileName: "gemma-3-4b.i1-Q4_K_M.gguf",
            downloadURL: URL(string: "https://huggingface.co/mradermacher/gemma-3-4b-pt-i1-GGUF/resolve/main/gemma-3-4b-pt.i1-Q4_K_M.gguf"),
            approxSizeMB: 2374
        ),
    ]

    /// Default selection : the fast 1B Q5 entry.
    static var defaultID: String { catalogue[0].id }

    /// Looks up an entry by id, falling back to the default.
    static func option(forID id: String) -> GGUFModelOption {
        catalogue.first(where: { $0.id == id }) ?? catalogue[0]
    }
}
