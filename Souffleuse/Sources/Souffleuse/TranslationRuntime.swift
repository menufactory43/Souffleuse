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
    /// Modèle effectivement résident (pour détecter un changement de modèle).
    private var loadedModel: InstructModel?

    /// Modèle instruct courant. Le changer (via `setModel`) force un rechargement
    /// au prochain `ensureLoaded` (GGUF + chat-template différents).
    private(set) var model: InstructModel = TranslationRuntime.defaultModel()

    /// Défaut : override `SOUFFLEUSE_IT_MODEL` (pour tests rapides), sinon
    /// **Qwen2.5 1.5B** — nettement meilleur en DE/IT (validé en usage réel), le
    /// surcoût RAM étant rendu acceptable par le déchargement-idle (Phase 7).
    static func defaultModel() -> InstructModel {
        if let raw = ProcessInfo.processInfo.environment["SOUFFLEUSE_IT_MODEL"],
           let m = InstructModel(rawValue: raw) { return m }
        return .qwen1_5b
    }

    /// Résout le chemin du GGUF pour `model`. Override TOTAL via `SOUFFLEUSE_IT_GGUF`
    /// (chemin direct) ; sinon le dossier `Souffleuse/Models` + le fichier du
    /// modèle. Pas de réseau — le fichier doit déjà exister localement.
    static func resolveInstructPath(for model: InstructModel) -> String {
        if let override = ProcessInfo.processInfo.environment["SOUFFLEUSE_IT_GGUF"], !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        return ("~/Library/Application Support/Souffleuse/Models/" + model.ggufFilename as NSString)
            .expandingTildeInPath
    }

    /// Change le modèle de traduction. Décharge l'éventuel moteur résident afin
    /// que le prochain `translate` recharge le nouveau GGUF paresseusement.
    func setModel(_ m: InstructModel) async {
        guard m != model else { return }
        model = m
        if ready { await engine.unload(); ready = false; loadedModel = nil }
    }

    /// Charge le modèle instruct courant au 1er appel (ou recharge si le modèle a
    /// changé). Idempotent. `false` quand le GGUF est introuvable.
    @discardableResult
    func ensureLoaded() async -> Bool {
        if ready, loadedModel == model { return true }
        if ready, loadedModel != model { await engine.unload(); ready = false; loadedModel = nil }
        // Moteur SECONDAIRE : moins de threads que le ghost pour ne pas
        // sur-souscrire le CPU (§2.9), et un contexte large pour ne jamais
        // tronquer la consigne + un long message (§2.9, traduction fidèle).
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let reducedThreads = Int32(max(1, cores / 2))
        let ok = await engine.load(
            modelPath: Self.resolveInstructPath(for: model),
            contextTokens: SuggestionPolicy.Tuning.translationContextTokens,
            threads: reducedThreads
        )
        ready = ok
        loadedModel = ok ? model : nil
        if !ok { Log.error(.predictor, "translate_model_load_failed") }
        return ok
    }

    /// Traduit `frenchText` vers `target`, en streamant les morceaux de la langue
    /// cible via `onToken`. Charge le modèle au 1er usage. Renvoie les métriques
    /// moteur du 1er segment (TTFT / tok-s) ou `nil` si le modèle est
    /// indisponible / annulé avant le 1er token.
    ///
    /// Au-delà de `TranslationChunker.maxWholeChars`, le message est traduit
    /// PHRASE PAR PHRASE et réassemblé avec ses séparateurs d'origine (UAT
    /// 11/06 : sur un texte long, Qwen 1.5B « échote » le français à greedy au
    /// lieu de traduire — chaque phrase isolée se traduit proprement). Le
    /// préfixe système + few-shot étant identique entre segments, le KV-LCP
    /// rend les prefills suivants quasi gratuits.
    ///
    /// `onToken` est `@Sendable` (il franchit la frontière de l'acteur moteur) ;
    /// l'appelant fait lui-même le hop MainActor pour mettre à jour le HUD.
    /// Retourne `true` pour continuer la génération, `false` pour l'arrêter.
    /// `maxTokens == nil` → adapté à la longueur de chaque segment
    /// (anti-troncature) ; passer une valeur ne sert qu'aux bench/tests.
    @discardableResult
    func translate(
        _ frenchText: String,
        into target: TranslationTarget,
        examples: [String] = [],
        maxTokens: Int? = nil,
        onToken: @escaping @Sendable (String) -> Bool
    ) async -> LlamaMetrics? {
        guard await ensureLoaded() else { return nil }
        // Priorité au ghost FR : on attend (borné) qu'il se taise avant de lancer
        // le décode lourd de la traduction, pour qu'il reste *instantané* (§2.9).
        await GpuGate.shared.awaitGhostIdle(
            maxWaitMillis: SuggestionPolicy.Tuning.translationGhostWaitMaxMillis,
            pollMillis: SuggestionPolicy.Tuning.translationGhostWaitPollMillis
        )
        let segments = TranslationChunker.segments(of: frenchText)
        // L'arrêt demandé par l'APPELANT (frappe, annulation) stoppe tout ; une
        // balise de fin de tour émise par le moteur ne clôt que SON segment.
        final class Stop: @unchecked Sendable { var byCaller = false }
        let stop = Stop()
        var firstMetrics: LlamaMetrics?
        for (i, segment) in segments.enumerated() {
            let prompt = GemmaChatPrompt.translation(
                of: segment.text, into: target, examples: examples, model: model)
            let budget = maxTokens
                ?? SuggestionPolicy.Tuning.translationMaxNewTokens(sourceChars: segment.text.count)
            let metrics = await engine.generate(
                prompt: prompt,
                maxTokens: budget,
                sampling: LlamaSampling(
                    temperature: 0, repeatPenalty: 1.1, repeatLastN: 64,
                    primePenaltiesWithPrompt: true)
            ) { piece in
                if piece.contains("<|im_end|>") || piece.contains("<end_of_turn>")
                    || piece.contains("<|endoftext|>") {
                    return false   // fin de CE segment seulement
                }
                let keep = onToken(piece)
                if !keep { stop.byCaller = true }
                return keep
            }
            if firstMetrics == nil { firstMetrics = metrics }
            if stop.byCaller { return firstMetrics }
            // Réinjecte le séparateur d'origine (espace / saut de ligne) entre
            // les segments — jamais après le dernier.
            if i < segments.count - 1, !segment.suffix.isEmpty {
                if !onToken(segment.suffix) { return firstMetrics }
            }
        }
        return firstMetrics
    }

    /// Relit/réécrit `frenchText` EN FRANÇAIS selon `tone` (FR→FR), en streamant
    /// via `onToken`. Même tuyau que `translate` : lazy-load du moteur, attente
    /// bornée du ghost (`GpuGate`), budget de tokens adaptatif, sampling déterministe.
    @discardableResult
    func reformulate(
        _ frenchText: String,
        tone: Tone,
        examples: [String] = [],
        maxTokens: Int? = nil,
        onToken: @escaping @Sendable (String) -> Bool
    ) async -> LlamaMetrics? {
        guard await ensureLoaded() else { return nil }
        let prompt = GemmaChatPrompt.reformulation(of: frenchText, tone: tone, examples: examples, model: model)
        let budget = maxTokens ?? SuggestionPolicy.Tuning.translationMaxNewTokens(sourceChars: frenchText.count)
        await GpuGate.shared.awaitGhostIdle(
            maxWaitMillis: SuggestionPolicy.Tuning.translationGhostWaitMaxMillis,
            pollMillis: SuggestionPolicy.Tuning.translationGhostWaitPollMillis
        )
        return await engine.generate(
            prompt: prompt,
            maxTokens: budget,
            sampling: LlamaSampling(temperature: 0, repeatPenalty: 1.1, repeatLastN: 64, primePenaltiesWithPrompt: true),
            onToken: onToken
        )
    }

    /// Génère depuis un prompt instruct DÉJÀ assemblé — voie générique des
    /// transformations « // » (corriger / raccourcir / reformuler / instruction
    /// libre, prompts de `GemmaChatPrompt+Transformation`). Même tuyau exact que
    /// `translate`/`reformulate` : lazy-load, attente bornée du ghost (GpuGate),
    /// budget adaptatif sur `sourceChars`, sampling déterministe (T=0,
    /// penalty 1.1, lastN 64). L'appelant assemble le prompt avec le
    /// chat-template du `model` courant (exposé en lecture).
    @discardableResult
    func transform(
        prompt: String,
        sourceChars: Int,
        maxTokens: Int? = nil,
        onToken: @escaping @Sendable (String) -> Bool
    ) async -> LlamaMetrics? {
        guard await ensureLoaded() else { return nil }
        let budget = maxTokens ?? SuggestionPolicy.Tuning.transformMaxNewTokens(sourceChars: sourceChars)
        await GpuGate.shared.awaitGhostIdle(
            maxWaitMillis: SuggestionPolicy.Tuning.translationGhostWaitMaxMillis,
            pollMillis: SuggestionPolicy.Tuning.translationGhostWaitPollMillis
        )
        return await engine.generate(
            prompt: prompt,
            maxTokens: budget,
            sampling: LlamaSampling(temperature: 0, repeatPenalty: 1.1, repeatLastN: 64, primePenaltiesWithPrompt: true),
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
