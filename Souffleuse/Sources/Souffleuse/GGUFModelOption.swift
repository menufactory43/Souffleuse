import Foundation
import SouffleuseCore

/// La langue d'écriture principale de l'utilisateur — demandée à l'onboarding,
/// modifiable dans l'onglet Souffle. Pilote la voix « Conseillée » : en français,
/// la plus petite voix suffit (plus rapide, moins de RAM) ; pour plusieurs
/// langues, il faut une voix multilingue.
enum PrimaryLanguage: String, Sendable, CaseIterable, Codable {
    /// Surtout du français (et de l'anglais).
    case french
    /// Plusieurs langues (allemand, italien, espagnol, chinois, japonais…).
    case multilingual

    /// Libellé court pour le sélecteur.
    var label: String {
        switch self {
        case .french: return tr(fr: "Surtout le français", en: "Mostly French")
        case .multilingual: return tr(fr: "Plusieurs langues", en: "Several languages")
        }
    }
}

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
    /// On télécharge la variante **base/pt** (le souffle est une continuation
    /// brute, pas un chat instruct) et on l'enregistre sous `fileName`.
    let downloadURL: URL?
    /// Taille approximative (Mo) du fichier à télécharger, pour l'affichage.
    let approxSizeMB: Int

    // MARK: - Métadonnées de choix (langue / RAM / vitesse)
    // Ce qui permet à l'utilisateur de savoir tout de suite quoi choisir pour
    // sa machine et sa langue, sans jargon.

    /// Empreinte mémoire approximative *en usage* (Mo) : poids du modèle + cache
    /// KV à 4096 tokens + marge moteur. Sert à dire « ~X Go en mémoire ».
    let approxRAMMB: Int
    /// RAM totale minimale conseillée sur le Mac (Go) pour que la voix tourne
    /// sans gêner le reste. En dessous, l'entrée est marquée « trop lourde ».
    let recommendedMinRAMGB: Int
    /// Les langues, en mots simples (jamais de liste technique imbuvable).
    let languagesLabel: String
    /// Vitesse ressentie du souffle : "Rapide" · "Posé" · "Lent".
    let speedLabel: String
    /// Éligible comme « Conseillé pour ton Mac » ? Les très gros modèles, qui
    /// peuvent traîner derrière la frappe, ne sont jamais auto-conseillés même
    /// s'ils tiennent en mémoire (l'aveu de Cotypist : plus gros ≠ mieux).
    let autoRecommend: Bool
    /// Vraie voix multilingue (forte hors français : DE/IT/ES/中文/日本語). Les
    /// voix français-only ne sont conseillées qu'à qui écrit surtout en français.
    let isMultilingual: Bool

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

    /// Libellé de vitesse LOCALISÉ, pour l'affichage. `speedLabel` reste la clé
    /// brute FR ("Rapide"/"Posé"/"Lent") — stable, comparée par `speedTint` côté
    /// Préférences ; on ne la traduit donc pas en place. C'est cette dérivée qui
    /// est montrée à l'utilisateur.
    var speedDisplay: String {
        switch speedLabel {
        case "Rapide": return tr(fr: "Rapide", en: "Fast")
        case "Posé": return tr(fr: "Posé", en: "Steady")
        case "Lent": return tr(fr: "Lent", en: "Slow")
        default: return speedLabel
        }
    }

    // MARK: - Adéquation au Mac

    /// Verdict d'adéquation d'une voix à la RAM réelle de la machine.
    enum Fit: Sendable {
        /// Le meilleur choix pour ce Mac (mis en avant en vert).
        case recommended
        /// Tient sans souci, de la marge à revendre.
        case comfortable
        /// Tient, mais le Mac est un peu juste — peut ralentir le reste.
        case tight
        /// Demande plus de mémoire que ce Mac n'en a.
        case tooHeavy
    }

    /// Part de la RAM du Mac au-delà de laquelle une voix est jugée « un peu
    /// juste » : elle tient, mais laisse peu de place aux autres apps.
    static let tightShare = 0.30

    /// Classe cette voix par rapport à la RAM du Mac. Le « conseillé » est
    /// décidé globalement (`recommendedID`) ; ici on situe la charge d'après
    /// l'empreinte *réelle* du modèle (pas un seuil grossier), pour que le
    /// verdict reste cohérent — une petite voix n'est jamais « juste » quand la
    /// voix conseillée, plus lourde, passe « à l'aise ».
    func fit(machineRAMGB: Int, recommendedID: String) -> Fit {
        if id == recommendedID { return .recommended }
        // Trop lourd : demande plus que le minimum vital pour tourner sans peiner.
        if recommendedMinRAMGB > machineRAMGB { return .tooHeavy }
        let share = Double(approxRAMMB) / Double(machineRAMGB * 1024)
        if share >= Self.tightShare { return .tight }
        return .comfortable
    }

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

    // MARK: - RAM machine & recommandation

    /// RAM physique totale du Mac, arrondie au Go inférieur. Lue « en live » à
    /// l'ouverture des préférences pour conseiller la bonne voix.
    static func machineRAMGB() -> Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    }

    /// La voix conseillée pour une RAM ET une langue données : la **plus légère**
    /// voix qui couvre la langue et tient sur ce Mac. Plus léger = plus rapide à
    /// suivre la frappe (le souffle doit rester instantané — plus gros ≠ mieux).
    /// En français, la petite Gemma 1B suffit ; en multilingue, la plus petite
    /// voix vraiment multilingue (Qwen3 1.7B).
    static func recommendedID(machineRAMGB: Int, language: PrimaryLanguage) -> String {
        let eligible = catalogue.filter {
            $0.autoRecommend
                && $0.recommendedMinRAMGB <= machineRAMGB
                && (language == .french || $0.isMultilingual)
        }
        let lightest = eligible.min(by: { $0.approxRAMMB < $1.approxRAMMB })
        return lightest?.id ?? defaultID
    }

    // MARK: - Catalogue

    /// Catalogue v2 : modèles **base/pré-entraînés** (continuation, pas chat),
    /// rangés du plus léger au plus lourd. Le souffle exige du base — un GGUF
    /// instruct (`-it`) rendrait la suggestion bavarde. Tous les liens pointent
    /// une variante base vérifiée (Gemma `-pt`, Qwen `-Base`).
    // Catalogue COMPUTED (et non `static let`) : `hint`/`languagesLabel` portent
    // des `tr(...)` qui doivent suivre la langue d'interface COURANTE à chaque
    // lecture. Un `static let` les gèlerait à la première évaluation, bloquant le
    // basculement live des cartes modèle. Coût négligeable (config, hors hot-path).
    static var catalogue: [GGUFModelOption] {
        [
        GGUFModelOption(
            id: "gemma-3-1b-q5",
            displayName: "Gemma 3 1B",
            quant: "Q5_K_M",
            hint: tr(fr: "Léger et rapide, parfait pour le français et l'anglais.", en: "Light and fast, perfect for French and English."),
            fileName: "gemma-3-1b.i1-Q5_K_M.gguf",
            downloadURL: URL(string: "https://huggingface.co/mradermacher/gemma-3-1b-pt-i1-GGUF/resolve/main/gemma-3-1b-pt.i1-Q5_K_M.gguf"),
            approxSizeMB: 811,
            approxRAMMB: 1000,
            recommendedMinRAMGB: 8,
            languagesLabel: tr(fr: "Français · anglais", en: "French · English"),
            speedLabel: "Rapide",
            autoRecommend: true,
            isMultilingual: false
        ),
        GGUFModelOption(
            id: "qwen3-1.7b-q4",
            displayName: "Qwen3 1.7B",
            quant: "Q4_K_M",
            hint: tr(fr: "Léger, rapide et très multilingue — le meilleur compromis.", en: "Light, fast and very multilingual — the best compromise."),
            fileName: "Qwen3-1.7B-Base.Q4_K_M.gguf",
            downloadURL: URL(string: "https://huggingface.co/mradermacher/Qwen3-1.7B-Base-GGUF/resolve/main/Qwen3-1.7B-Base.Q4_K_M.gguf"),
            approxSizeMB: 1110,
            approxRAMMB: 1400,
            recommendedMinRAMGB: 8,
            languagesLabel: tr(fr: "Français + beaucoup d'autres (DE · IT · ES · 中文 · 日本語)", en: "French + many others (DE · IT · ES · 中文 · 日本語)"),
            speedLabel: "Rapide",
            autoRecommend: true,
            isMultilingual: true
        ),
        GGUFModelOption(
            id: "gemma-3-4b-q4",
            displayName: "Gemma 3 4B",
            quant: "Q4_K_M",
            hint: tr(fr: "Plus juste sur les phrases longues, un peu plus lent.", en: "More accurate on long sentences, a bit slower."),
            fileName: "gemma-3-4b.i1-Q4_K_M.gguf",
            downloadURL: URL(string: "https://huggingface.co/mradermacher/gemma-3-4b-pt-i1-GGUF/resolve/main/gemma-3-4b-pt.i1-Q4_K_M.gguf"),
            approxSizeMB: 2374,
            approxRAMMB: 2900,
            recommendedMinRAMGB: 8,
            languagesLabel: tr(fr: "Français · anglais", en: "French · English"),
            speedLabel: "Posé",
            autoRecommend: true,
            isMultilingual: false
        ),
        GGUFModelOption(
            id: "qwen3-4b-q4",
            displayName: "Qwen3 4B",
            quant: "Q4_K_M",
            hint: tr(fr: "La meilleure justesse multilingue, un peu plus lent.", en: "The best multilingual accuracy, a bit slower."),
            fileName: "Qwen3-4B-Base.i1-Q4_K_M.gguf",
            downloadURL: URL(string: "https://huggingface.co/mradermacher/Qwen3-4B-Base-i1-GGUF/resolve/main/Qwen3-4B-Base.i1-Q4_K_M.gguf"),
            approxSizeMB: 2500,
            approxRAMMB: 3000,
            recommendedMinRAMGB: 8,
            languagesLabel: tr(fr: "Français + beaucoup d'autres (DE · IT · ES · 中文 · 日本語)", en: "French + many others (DE · IT · ES · 中文 · 日本語)"),
            speedLabel: "Posé",
            autoRecommend: true,
            isMultilingual: true
        ),
        GGUFModelOption(
            id: "qwen3-8b-q4",
            displayName: "Qwen3 8B",
            quant: "Q4_K_M",
            hint: tr(fr: "La plus fine, mais réservée aux gros Macs — peut traîner derrière la frappe.", en: "The finest, but only for powerful Macs — may lag behind your typing."),
            fileName: "Qwen3-8B-Base.i1-Q4_K_M.gguf",
            downloadURL: URL(string: "https://huggingface.co/mradermacher/Qwen3-8B-Base-i1-GGUF/resolve/main/Qwen3-8B-Base.i1-Q4_K_M.gguf"),
            approxSizeMB: 5030,
            approxRAMMB: 5800,
            recommendedMinRAMGB: 16,
            languagesLabel: tr(fr: "Français + beaucoup d'autres (DE · IT · ES · 中文 · 日本語)", en: "French + many others (DE · IT · ES · 中文 · 日本語)"),
            speedLabel: "Lent",
            autoRecommend: false,
            isMultilingual: true
        ),
        ]
    }

    /// Default selection : the fast 1B Q5 entry (FR/EN par défaut ; la voix
    /// conseillée selon la RAM est calculée à part par `recommendedID`).
    static var defaultID: String { catalogue[0].id }

    /// La voix la plus légère du catalogue (empreinte mémoire minimale) — cible du
    /// mode « économie batterie › modèle plus léger ». Calculée, pas figée, pour
    /// suivre le catalogue.
    static var lightestID: String {
        catalogue.min(by: { $0.approxRAMMB < $1.approxRAMMB })?.id ?? defaultID
    }

    /// Looks up an entry by id, falling back to the default.
    static func option(forID id: String) -> GGUFModelOption {
        catalogue.first(where: { $0.id == id }) ?? catalogue[0]
    }
}
