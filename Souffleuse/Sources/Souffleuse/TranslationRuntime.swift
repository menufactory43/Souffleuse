import Foundation
import SouffleuseCore
import SouffleuseLlama
import SouffleuseLog

/// Moteur instruct **paresseux** pour le HUD de traduction (Phase 1).
///
/// Un SECOND `LlamaEngine`, distinct de `ModelRuntime.llamaEngine` (le moteur
/// base du ghost). Chargé au 1er usage (1er commit ⌘↩ / 1er rendu HUD), PAS au
/// lancement de l'app — le coût de démarrage du chemin ghost reste inchangé.
/// Les deux moteurs cohabitent (gate Phase 0 : coût *dirty* marginal ~70 Mo ;
/// poids mmap évictables). Fallback « moteur unique + swap `modelPath` »
/// documenté dans `TRANSLATION-SPEC.md §1bis` si le thrash disque devient
/// pénalisant sur 8 Go.
///
/// **Périmètre Phase 1 : aucun consommateur UI.** Ce type existe « alongside »,
/// compile proprement, et n'est exercé que par le bench dev + les tests jusqu'à
/// ce que le câblage HUD arrive (phases suivantes). Même schéma que
/// `ModelRuntime`, ajouté sans consommateur à l'origine.
@MainActor
final class TranslationRuntime {
    private let engine = LlamaEngine()

    /// Vrai une fois le GGUF instruct chargé dans le moteur.
    private(set) var ready = false

    /// Résout le chemin du GGUF instruct. Override via `SOUFFLEUSE_IT_GGUF` ;
    /// sinon le dossier `Souffleuse/Models`. Pas de réseau — le fichier doit
    /// déjà exister localement (téléchargé une fois).
    static func resolveInstructPath() -> String {
        if let override = ProcessInfo.processInfo.environment["SOUFFLEUSE_IT_GGUF"], !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        return ("~/Library/Application Support/Souffleuse/Models/gemma-3-1b-it-Q4_K_M.gguf" as NSString)
            .expandingTildeInPath
    }

    /// Charge le modèle instruct au 1er appel. Idempotent. Renvoie `false` quand
    /// le GGUF est introuvable (l'UI surfacera un état « modèle absent »).
    @discardableResult
    func ensureLoaded() async -> Bool {
        if ready { return true }
        let ok = await engine.load(modelPath: Self.resolveInstructPath(), contextTokens: 1024)
        ready = ok
        if !ok { Log.error(.predictor, "translate_model_load_failed") }
        return ok
    }

    /// Traduit `frenchText` vers `target`, en streamant les morceaux de la langue
    /// cible via `onToken`. Charge le modèle au 1er usage. Renvoie les métriques
    /// moteur (TTFT / tok-s) ou `nil` si le modèle est indisponible / annulé.
    ///
    /// `onToken` est `@Sendable` (il franchit la frontière de l'acteur moteur) ;
    /// l'appelant fait lui-même le hop MainActor pour mettre à jour le HUD.
    /// Retourne `true` pour continuer la génération, `false` pour l'arrêter.
    @discardableResult
    func translate(
        _ frenchText: String,
        into target: TranslationTarget,
        examples: [String] = [],
        maxTokens: Int = 160,
        onToken: @escaping @Sendable (String) -> Bool
    ) async -> LlamaMetrics? {
        guard await ensureLoaded() else { return nil }
        let prompt = GemmaChatPrompt.translation(of: frenchText, into: target, examples: examples)
        return await engine.generate(
            prompt: prompt,
            maxTokens: maxTokens,
            sampling: LlamaSampling(temperature: 0, repeatPenalty: 1.1, repeatLastN: 64),
            onToken: onToken
        )
    }

    /// Libère le modèle instruct (unload à l'idle — stratégie mémoire de repli /
    /// Phase 7).
    func unload() async {
        await engine.unload()
        ready = false
    }
}
