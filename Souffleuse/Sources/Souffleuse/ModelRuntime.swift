import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import NaturalLanguage
import SouffleuseCore
import SouffleuseLlama
import SouffleuseLog
import SouffleusePersonalization
import SouffleusePrompt
import SouffleuseTyping

// MARK: - Value types (Phase 4 / 04-05 — extracted alongside PVM, no callers yet)

/// Sendable transfer box for `[KVCache]` across the actor boundary between
/// `@MainActor` callers (PVM, future ModelRuntime) and the
/// `ModelContainer.perform` closure (off-MainActor). `KVCache` is a
/// non-Sendable protocol, but the caches are reference-typed and accessed
/// sequentially per predict; the box's `@unchecked Sendable` is safe because
/// we own the access pattern end-to-end (no concurrent reads/writes by
/// construction).
///
/// **04-05 note** : copié verbatim depuis `PredictorViewModel.swift:50-58`.
/// La copie est volontaire — la dédup PVM-side viendra en 04-07 quand le
/// wiring sera complet. Tant qu'aucun caller PVM ne route via ModelRuntime,
/// les deux structs co-existent (visibilité `private` / fileprivate côté
/// PVM ; type interne au module côté ModelRuntime). Aucun risque de
/// collision symbolique avec `PVM.CacheBox` (qui est `private struct` au
/// niveau fichier mais résolu sans préfixe par les autres types nested) :
/// on déclare CETTE copie comme `fileprivate` aussi. La promotion à
/// `internal` (avec drop simultané de PVM.CacheBox) vit en 04-07.
fileprivate struct CacheBox: @unchecked Sendable {
    let caches: [KVCache]
}

/// Metrics captured during a single LLM stream. `ttftMillis` est null tant
/// que le premier token n'est pas arrivé ; `tokensPerSecond` est null tant
/// que `MLXLMCommon` n'a pas terminé son aggregation finale.
///
/// **04-05 note** : copié verbatim depuis la nested struct `PredictorViewModel.StreamMetrics`
/// (PVM:70-73). Déplacée au niveau top-level ici pour permettre l'usage par
/// le futur `ModelRuntime.generate(...)` (04-06) sans dépendance circulaire
/// au type PVM.
struct StreamMetrics: Sendable {
    var ttftMillis: Int?
    var tokensPerSecond: Double?
}

// `PredictRequest` — extracted VERBATIM to `SouffleuseCore.PredictRequest`
// (Phase 5). Re-exported here is unnecessary: ModelRuntime imports
// SouffleuseCore, so `PredictRequest` resolves unqualified at every call-site.

// MARK: - ModelRuntime

/// MLX model lifecycle owner — extraction step 1 of D-03 (Phase 4 wave 4).
///
/// **Scope du plan 04-05** :
/// - Owns `container: ModelContainer?` + `modelId: String` + `lastError`.
/// - Implémente `loadModel()` et `swap(to:completionCache:)` — copies
///   verbatim des bodies PVM.
/// - Héberge les pure-function helpers (OutputFilter sub-namespace,
///   `buildSystemPrompt`, `detectLanguage`) qui seront partagés avec PVM
///   en 04-07.
/// - **PAS de `generate(...)`** : cette méthode (le body de
///   `container.perform`) est migrée en 04-06 derrière un env flag
///   `SOUFFLEUSE_USE_MODEL_RUNTIME`.
///
/// **Important** : en 04-05, **aucun caller ne référence ModelRuntime**.
/// PVM continue d'appeler ses propres `Self.stripPrefixOverlap`,
/// `Self.buildSystemPrompt`, son propre `loadModel()`. ModelRuntime existe
/// alongside sans consommateur, ce qui permet :
/// 1. Compile clean immédiatement (les types co-existent).
/// 2. Tests OutputFilter peuvent tourner sans rien casser dans PVM.
/// 3. Revert propre si 04-06 ou 04-07 échouent.
@MainActor
final class ModelRuntime {
    /// Modèle MLX courant. Initialement nil ; renseigné par `loadModel()`.
    private(set) var container: ModelContainer?

    /// Identifiant HuggingFace du modèle (ex. `mlx-community/gemma-3-1b-pt-4bit`).
    private(set) var modelId: String

    /// Dernière erreur de chargement, surfacée à l'UI via la façade PVM en 04-07.
    /// Forme `"load_failed: <localizedDescription>"`.
    private(set) var lastError: String?

    /// llama.cpp engine — now the SOLE generation path (Metal GGUF). The MLX
    /// container above is kept only for the n-gram tokenizer
    /// (`rebuildPersonalization`) ; all ghost text comes from `llamaEngine`.
    let llamaEngine = LlamaEngine()

    /// Moteur **beam contraint** — le cœur LLM unifié sous `SOUFFLEUSE_BEAM_CORE`
    /// (K=3, `requiredPrefix` mid-mot). Chargé À CÔTÉ du `llamaEngine` (contexte
    /// dédié `n_seq_max = K+1`, cf. BeamGhostEngine §POURQUOI) UNIQUEMENT quand le
    /// flag est posé — sinon jamais touché, RAM intacte, chemin byte-identique.
    /// COÛT connu (spike) : un 2ᵉ chargement du même GGUF (poids ~1 Go dupliqués) ;
    /// acceptable derrière le flag, optimisable plus tard en partageant le model
    /// handle (un seul `llama_model`, deux contextes).
    let beamEngine = BeamGhostEngine(config: .ghostCore())

    /// Largeur K effective du beam (env-aware via `ghostCore()`), pour le mid-mot.
    private let beamWidth = BeamConfig.ghostCore().maxSearchWidth

    /// True once the GGUF is loaded into the beam engine (only attempted when
    /// `beamCoreEnabled`). Gates `generateGhostBeam`.
    private(set) var beamReady = false

    /// Plancher dico mid-mot (flag `MW_DICO_FLOOR`). `NSSpellChecker` via
    /// `WordCompleter` : complète le mot EN COURS quand le gradient d'engagement
    /// s'abstient, pour qu'un ghost valide apparaisse à chaque lettre. Tenu ici
    /// (pas recréé par souffle) ; `@unchecked Sendable`, appelé sur le MainActor
    /// (ModelRuntime) comme dans PVM, donc sûr.
    private let dicoFloorCompleter = WordCompleter()

    /// NSSpellChecker wrapper, reused for the mid-word coherence guard
    /// (`OutputFilter.midWordCandidate` + `isValidWord`). Process-wide and
    /// thread-safe behind its own `@unchecked Sendable` declaration, so it can
    /// be captured by the `@Sendable` onToken closure without crossing back to
    /// the actor on every token.

    /// True once the GGUF is loaded into the llama engine.
    private(set) var llamaReady = false

    /// Currently-selected GGUF model id (from `GGUFModelOption.catalogue`).
    /// Drives `resolveGGUFPath()` — the file the llama engine loads. Defaults
    /// to the fast 1B Q5 entry ; updated by `swapGGUF(to:)`.
    private(set) var ggufModelID: String = GGUFModelOption.defaultID

    /// True when the runtime can produce ghost text — i.e. the llama engine
    /// has a GGUF loaded. Replaces the old `container != nil` gate in PVM,
    /// since the MLX container is now optional (n-gram tokenizer only).
    var canGenerate: Bool { llamaReady }

    init(initialModelId: String, ggufModelID: String = GGUFModelOption.defaultID) {
        self.modelId = initialModelId
        self.ggufModelID = ggufModelID
    }

    /// Resolves the local GGUF path used by the llama engine, derived from the
    /// currently-selected `ggufModelID`. Overridable globally via
    /// `SOUFFLEUSE_GGUF` (debug). Falls back to the default 1B Q5 entry when the
    /// selected entry's file can't be found. No network : the file must already
    /// exist locally.
    func resolveGGUFPath() -> String {
        let option = GGUFModelOption.option(forID: ggufModelID)
        if let path = option.resolvePath() {
            return path
        }
        // Selected entry unresolved → fall back to the default 1B entry so the
        // ghost still works ; the UI flags the missing file separately.
        if let fallback = GGUFModelOption.option(forID: GGUFModelOption.defaultID).resolvePath() {
            return fallback
        }
        // Last-resort literal (mirrors the historical hardcoded path).
        return (("~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf") as NSString)
            .expandingTildeInPath
    }

    // MARK: Lifecycle

    /// Charge le modèle courant via `LLMModelFactory.shared.loadContainer`.
    /// Body copié depuis `PVM.loadModel()` (PVM:184-211), avec deux
    /// simplifications acceptables pour le scope 04-05 :
    /// - Pas de publication `LoadState` UI (façade UI vit en 04-07).
    /// - Pas de progress callback — la façade UI le branchera quand
    ///   elle wrappera ModelRuntime.
    ///
    /// L'événement `model_load_failed` reste byte-identique au legacy
    /// (StaticString, count nil) pour preserver la signature audit.sh.
    func loadModel() async {
        // Primary generation engine : llama.cpp + local GGUF (Metal). This is
        // the path that produces ghost text now ; MLX is only kept for the
        // n-gram tokenizer below.
        let ggufPath = resolveGGUFPath()
        let ok = await llamaEngine.load(modelPath: ggufPath, contextTokens: 4096)
        llamaReady = ok
        if !ok {
            Log.error(.predictor, "model_load_failed")
            self.lastError = "load_failed: gguf"
            return
        }

        // Beam core (flag `SOUFFLEUSE_BEAM_CORE`) : crée le contexte multi-séquences
        // du beam sur le MÊME `llama_model` que le ghost greedy (poids EMPRUNTÉS via
        // `borrowModel()` — pas de 2ᵉ Go en RAM). Hors flag, jamais chargé.
        if SuggestionPolicy.Tuning.beamCoreEnabled {
            if let borrowed = await llamaEngine.borrowModel() {
                beamReady = await beamEngine.load(borrowedModel: borrowed, contextTokens: 4096)
            } else {
                beamReady = false
            }
            if !beamReady { Log.error(.predictor, "model_load_failed") }
        }

        // Best-effort MLX container load — used solely by
        // `rebuildPersonalization` for tokenizing history into the n-gram
        // model. Personalization defaults to off (strength 0), so a failure
        // here (e.g. offline first-run) must NOT block the llama ghost path.
        do {
            MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
            let configuration = ModelConfiguration(id: modelId, defaultPrompt: "")
            let container = try await LLMModelFactory.shared.loadContainer(
                configuration: configuration
            ) { _ in }
            self.container = container
        } catch {
            // Non-fatal : n-gram personalization stays inert without it.
            self.container = nil
        }
        self.lastError = nil
    }

    /// Swap vers un nouveau modèle. Idempotent si `id == modelId`.
    ///
    /// Body aligné sur `PVM.swapModel(to:)` (PVM:157-173) :
    /// 1. drop container,
    /// 2. update modelId,
    /// 3. invalidate completionCache (predictCache + KV holder + tokenCountCache),
    /// 4. reload.
    ///
    /// **NOTE** : la cancellation de la generate en cours est l'affaire du
    /// caller (PVM/GenerationPlanner) AVANT d'appeler `runtime.swap(...)`.
    /// ModelRuntime n'a pas accès au planner — cf. comment Task 2 du plan.
    ///
    /// **NOTE log parity** : PVM legacy n'émet PAS `kv_cache_invalidate count:3`
    /// dans swapModel — c'est `cache.invalidateAll()` qui l'émet en interne
    /// (cf. CompletionCache:214 area). Donc on n'ajoute pas de log ici.
    func swap(to id: String, completionCache: CompletionCache) async {
        guard id != modelId else { return }
        container = nil
        modelId = id
        completionCache.invalidateAll()
        // The llama GGUF path is independent of the MLX modelId in v1 (single
        // local GGUF). loadModel reloads both ; llama.load is idempotent on an
        // already-loaded path, so a model swap just refreshes the MLX
        // tokenizer container.
        await loadModel()
    }

    /// Swaps the active **GGUF** model (the real ghost engine). Reloads ONLY
    /// the llama engine on the newly-resolved path — the MLX container is NOT
    /// touched (it is decoupled from the user's choice now). `LlamaEngine.load`
    /// tears down the prior model and resets KV state (kvTokens=[]). Idempotent
    /// when `id == ggufModelID`.
    ///
    /// Returns true when the new GGUF loaded successfully. The caller is
    /// responsible for re-feeding the personalization corpus afterwards
    /// (token-id n-gram + suffix array must be rebuilt for the reloaded engine).
    /// Sets the GGUF selection before the first `loadModel()`. No reload — the
    /// next `loadModel()` will resolve and load this entry's path.
    func configureInitialGGUF(_ id: String) {
        guard !llamaReady else { return }
        ggufModelID = id
    }

    @discardableResult
    func swapGGUF(to id: String) async -> Bool {
        guard id != ggufModelID else { return llamaReady }
        ggufModelID = id
        let ggufPath = resolveGGUFPath()
        // ORDRE CRITIQUE : le beam emprunte le `llama_model` de `LlamaEngine`. Le
        // reload ci-dessous va libérer l'ANCIEN modèle ; on décharge donc d'abord
        // le contexte du beam (sinon il référencerait un modèle libéré), puis on
        // le recrée sur le NOUVEAU modèle emprunté après le reload.
        if beamReady {
            await beamEngine.unload()
            beamReady = false
        }
        let ok = await llamaEngine.load(modelPath: ggufPath, contextTokens: 4096)
        llamaReady = ok
        if !ok {
            Log.error(.predictor, "model_load_failed")
            self.lastError = "load_failed: gguf"
        } else {
            self.lastError = nil
        }
        // Recrée le contexte beam sur le nouveau modèle emprunté (flag uniquement).
        if SuggestionPolicy.Tuning.beamCoreEnabled, ok {
            if let borrowed = await llamaEngine.borrowModel() {
                beamReady = await beamEngine.load(borrowedModel: borrowed, contextTokens: 4096)
            }
        }
        return ok
    }

    /// Feeds the personalization corpus (accepted-text strings) into the
    /// llama engine, which rebuilds its llama-token-id n-gram. Called at
    /// startup once the GGUF is loaded and after each acceptance / clear.
    /// Cheap full rebuild — the corpus is small (ring buffer ≤ 200 entries).
    func setCorpus(_ entries: [String]) async {
        await llamaEngine.setCorpus(entries)
    }

    /// Cancellation hook. No-op : `GenerationPlanner` owns Task cancellation,
    /// container teardown happens in `swap(to:)` when modelId changes. Cette
    /// méthode existe pour symétrie d'API (la façade 04-07 voudra peut-être
    /// appeler `runtime.cancel()` après `planner.cancel()` pour des raisons
    /// de lisibilité).
    func cancel() {
        // No-op by design. Voir doc-comment.
    }

    /// Décharge le moteur ghost (GGUF llama.cpp) ET le container MLX (tokenizer
    /// du n-gram) pour rendre la RAM quand l'utilisateur ne compose pas. Après
    /// ça `canGenerate` est faux → `predict()` baille proprement sur son gate.
    /// Un `loadModel()` ultérieur recharge les deux (le GGUF est idempotent sur
    /// un chemin déjà chargé, mais `LlamaEngine.unload()` a libéré le model +
    /// context, donc il recharge réellement). L'appelant DOIT avoir annulé la
    /// génération en cours avant (cf. `cancel()` côté PVM/AppDelegate) ; l'acteur
    /// `LlamaEngine` sérialise de toute façon `unload` après tout `generate` en
    /// vol.
    func unloadGhost() async {
        // ORDRE CRITIQUE : le beam emprunte le modèle de `LlamaEngine`. On libère
        // d'abord le contexte du beam, PUIS le modèle (via llamaEngine.unload) —
        // sinon le contexte beam pointerait un modèle déjà libéré.
        await beamEngine.unload()
        beamReady = false
        await llamaEngine.unload()
        llamaReady = false
        // Drop le container MLX : seul son tokenizer sert (au rebuild n-gram /
        // personnalisation), jamais la génération du ghost — celle-ci passe
        // exclusivement par llama.cpp. Rechargé au prochain loadModel(). Rendre
        // la référence permet à l'OS de récupérer ce qui était matérialisé.
        container = nil
    }

    // MARK: - OutputFilter / prompt helpers (extracted to SouffleuseCore)

    /// `OutputFilter` was moved VERBATIM to `SouffleuseCore.OutputFilter`
    /// (Phase 5). This typealias keeps every `ModelRuntime.OutputFilter.*`
    /// call-site (PVM, AppDelegate, tests) compiling unchanged.
    typealias OutputFilter = SouffleuseCore.OutputFilter

    /// Mid-word confidence gate threshold — forwarding shim to
    /// `LlamaPromptBuilder.midWordMinFirstTokenProb` (extracted Phase 5).
    static var midWordMinFirstTokenProb: Float { LlamaPromptBuilder.midWordMinFirstTokenProb }

    /// Forwarding shim — see `LlamaPromptBuilder.autocompleteSystemPrompt`.
    static var autocompleteSystemPrompt: String { LlamaPromptBuilder.autocompleteSystemPrompt }

    /// Forwarding shim — see `LlamaPromptBuilder.buildSystemPrompt`.
    static func buildSystemPrompt(detectedLanguage: String?) -> String {
        LlamaPromptBuilder.buildSystemPrompt(detectedLanguage: detectedLanguage)
    }

    /// Forwarding shim — see `LlamaPromptBuilder.detectLanguage`.
    static func detectLanguage(in text: String) -> String? {
        LlamaPromptBuilder.detectLanguage(in: text)
    }

    // MARK: - generate (04-06 — verbatim port of PVM container.perform body)

    /// Runs the LLM generation pipeline for one predict.
    ///
    /// **Verbatim port** of `PredictorViewModel.predict(...)` container.perform
    /// closure body (PVM:894-1305). Adaptations from the legacy version :
    ///
    /// 1. Inputs come from `request: PredictRequest` (Sendable value) instead
    ///    of `self`-captured locals. The caller (PVM.predict_new) precomputes
    ///    every actor-isolated field (n-gram snapshot, examplesBlock, system
    ///    message, etc.) before calling.
    /// 2. The chunk side-effect (UI update) is delegated to the `onChunk`
    ///    closure — `@Sendable @MainActor`. ModelRuntime never touches PVM
    ///    observables. The filter pipeline (`stripPrefixOverlap`, regex strip,
    ///    `ghostIsRepeatingPrefix`, `capToWords`, …) runs INSIDE the closure
    ///    here and the caller's `onChunk` receives the already-filtered text
    ///    via this body's local-state machine.
    /// 3. KV-cache decision tree calls `cache.decideExtendTrimInvalidate(...)`
    ///    via `MainActor.run` (CompletionCache lives on @MainActor).
    /// 4. Cancel-on-keystroke : `Task.isCancelled` checks preserved verbatim
    ///    around `for await event in stream`. The caller passes `token` so
    ///    `onChunk` can additionally drop chunks via `planner.isCurrent(token)`.
    /// 5. `llm_done_stored` log + cache.store(...) live in the caller's
    ///    post-generate MainActor.run block (PVM.predict_new) — NOT here —
    ///    because `self.suggestion` is the source of truth and PVM owns it.
    ///
    /// Returns `StreamMetrics` (ttft + tokens/sec) on success ; nil on
    /// container/MLX failure (logged via `predict_failed`). Note the legacy
    /// PVM didn't have an explicit predict_failed event ; it would publish
    /// `lastError` via the `catch` block. We preserve that semantic : return
    /// `nil` and let the caller surface lastError if desired.
    func generate(
        request: PredictRequest,
        onChunk: @escaping @Sendable @MainActor (String) -> Void
    ) async -> StreamMetrics? {
        guard llamaReady else { return nil }
        return await generateLlama(request: request, onChunk: onChunk)
    }

    /// Résultat d'une escalade mid-mot (Frame C). `show` ⇒ le caller affiche
    /// `word` (le mot greedy/modal, déterministe) ; sinon il cache (retombe sur le
    /// ghost instant). `word` + `reason` exposés même caché pour l'inspecteur DEV.
    struct MidWordEscalationResult: Sendable {
        let show: Bool
        let word: String
        let reason: String     // "fast-accept" / "fast-reject" / "branch agree=0.75"
        /// Niveau d'engagement quand le gradient `MW_ENGAGEMENT` est actif (sinon
        /// `.plein` par défaut — comportement long-ghost statique inchangé, le
        /// rolling reste autorisé comme aujourd'hui hors flag).
        let engagement: SuggestionPolicy.MidWordEngagement
        /// Le rolling refill est-il autorisé pour ce souffle ? Hors gradient =
        /// toujours `true` (byte-identique). Sous gradient = vrai en PLEIN seulement.
        var rollingAllowed: Bool { engagement.rollingAllowed }

        init(show: Bool, word: String, reason: String,
             engagement: SuggestionPolicy.MidWordEngagement = .plein) {
            self.show = show
            self.word = word
            self.reason = reason
            self.engagement = engagement
        }
    }

    /// **Frame C — escalade mid-mot.** Appelée par `PredictorViewModel.predict`
    /// UNIQUEMENT quand le caret est mid-mot sur un fragment INCOMPLET (le cas qui
    /// fait aujourd'hui `midword_block`) ET que `midWordEscalationEnabled` est ON.
    /// Hors flag, jamais appelée → comportement byte-identique.
    ///
    /// **Étage 1 (greedy + dico)** : 1 passe greedy (profil prod : bans +
    /// repeatPenalty + token healing), `minFirstTokenProb` à un epsilon pour capter
    /// la confiance top-1. `midWordFastDecision` → fast-accept (montre) / fast-reject
    /// (cache) / uncertain (→ étage 2).
    ///
    /// **Étage 2 (branches, F2)** : sur `uncertain`, K branches stochastiques
    /// (même prompt healed, seeds distincts), early-exit dès la majorité, puis
    /// `midWordBranchDecision`. L'accord récupère les bons mots à P1 bas (le 1B
    /// est souvent juste mais peu confiant sous le prompt de prod), la garde dico
    /// rejette les échecs de healing même convergents. Le texte MONTRÉ est le mot
    /// MODAL (vote), jamais un échantillon brut → déterministe à l'affichage.
    ///
    /// Personnalisation n-gram DÉSACTIVÉE (`personalizationStrength: 0`) : seuils
    /// calibrés sans biais sur `SouffleuseMidwordEval`.
    /// Langue attendue pour la garde `languageMismatch` de la continuation C1 :
    /// le `detectedLanguage` de la requête s'il est présent, sinon dérivée du texte
    /// déjà tapé (`userTail`, fallback `llmTail`) via `NLLanguageRecognizer` aux
    /// mêmes seuils que les autres gardes de langue. `nil` ⇒ garde fail-open.
    nonisolated static func expectedLanguage(for request: PredictRequest) -> String? {
        if let lang = request.detectedLanguage, !lang.isEmpty { return lang }
        let source = request.userTail.isEmpty ? request.llmTail : request.userTail
        let trimmed = String(source.suffix(512)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= OutputFilter.languageGuardMinChars else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let lang = recognizer.dominantLanguage else { return nil }
        if let confidence = recognizer.languageHypotheses(withMaximum: 1)[lang],
           confidence < OutputFilter.languageGuardMinConfidence {
            return nil
        }
        return lang.rawValue
    }

    func midWordEscalate(request: PredictRequest) async -> MidWordEscalationResult? {
        guard llamaReady else { return nil }
        let partial = OutputFilter.trailingPartialWord(request.userTail)
        let prompt = ModelRuntime.buildLlamaPrompt(
            system: request.systemMessage,
            customInstr: request.customInstr,
            ctxPrefix: request.ctxPrefix,
            fieldContext: request.fieldContextSlot,
            afterCursor: request.afterCursorSlot,
            beforeCursor: request.llmTail,
            examples: request.examplesBlock
        )
        // C1 : la passe GREEDY tourne sur le budget NORMAL (≈ maxTokens, ~12) pour
        // capturer la CONTINUATION mot+suite ("losophie, la vérité est"), pas juste
        // le mot. Les BRANCHES gardent leur cap court (`escBranchMaxTokens`) — elles
        // ne servent qu'à VOTER le mot de tête, pas à produire de la suite.
        let cap = max(request.maxTokens, SuggestionPolicy.Tuning.escGreedyMaxTokens)

        // Le ghost affiché = ce qu'il RESTE à taper (le mot MODAL moins le partiel
        // déjà tapé), jamais le mot entier : "cacahu" + ghost "ète", pas
        // "cacahuète" (qui doublonnerait à l'écran). `midWordValidExtends` a déjà
        // garanti que le mot prolonge le partiel, donc `dropFirst(partial.count)`
        // est sûr et positionnel (insensible à la casse du préfixe tapé).
        func remaining(_ word: String) -> String {
            word.count > partial.count ? String(word.dropFirst(partial.count)) : ""
        }

        // Langue attendue pour la garde de mismatch : le champ `detectedLanguage` de
        // la requête s'il existe, sinon dérivée du texte tapé (tail) en taguant avec
        // NLLanguageRecognizer (même seuils que les autres gardes de langue).
        let expectedLang = ModelRuntime.expectedLanguage(for: request)

        // C1 — depuis le mot CONFIRMÉ + la ligne greedy complète, calcule le ghost à
        // montrer : la continuation mot+suite MOINS le partiel déjà tapé, gardée par
        // les exit-guards. Si une garde échoue (écho fort / mauvaise langue), retombe
        // sur `remaining(word)` = le MOT SEUL (C0, prouvé bon). On ne perd jamais le mot.
        func continuation(confirmedWord word: String, fullLine: String) -> String {
            let wordRest = remaining(word)
            // Defrag du mot puis splice sur la ligne complète : on retire de `fullLine`
            // le partiel déjà tapé via le même chevauchement de préfixe que le stream.
            let stripped = OutputFilter.stripPrefixOverlap(
                OutputFilter.singleLine(fullLine), prefix: partial)
            let cont = OutputFilter.singleLine(stripped)
            // La continuation doit au moins contenir le reste du mot ; sinon le greedy
            // a produit autre chose que le mot confirmé → mot seul (sûr).
            guard !cont.isEmpty, cont.lowercased().hasPrefix(wordRest.lowercased()) else { return wordRest }
            // Le SEGMENT après le mot (ce que C1 ajoute) : c'est lui qu'on garde.
            let segment = String(cont.dropFirst(wordRest.count))
            guard !segment.isEmpty else { return wordRest }
            // Exit-guards SUR LA CONTINUATION (le segment), pas sur le mot.
            if OutputFilter.echoScore(ghost: segment, tail: request.userTail)
                >= OutputFilter.continuationEchoThreshold { return wordRest }
            if OutputFilter.languageMismatch(ghost: segment, expected: expectedLang) { return wordRest }
            return cont
        }

        // GPU gate UNE fois autour de toute l'escalade (greedy + branches), pour que
        // la traduction ne s'interleave pas au milieu (TRANSLATION-SPEC §2.9).
        GpuGate.shared.ghostBegan()
        defer { GpuGate.shared.ghostEnded() }

        // ── Étage 1 — greedy (capte P1 via epsilon).
        let greedy = await runEscalationPass(prompt: prompt, partial: partial, cap: cap,
                                             temperature: 0, seed: 0, captureP1: true)
        if Task.isCancelled { return nil }
        switch SuggestionPolicy.midWordFastDecision(
            partial: partial, greedyModal: greedy.lead, firstTokenProb: greedy.p1
        ) {
        case .fastAccept(let word):
            // C1 : mot confirmé → montre mot+continuation (gardée), pas que le mot.
            let shown = continuation(confirmedWord: word, fullLine: greedy.fullLine)
            return MidWordEscalationResult(show: !shown.isEmpty, word: shown.isEmpty ? word : shown,
                                           reason: "fast-accept")
        case .fastReject:
            return MidWordEscalationResult(show: false, word: greedy.lead, reason: "fast-reject")
        case .uncertain:
            break   // → étage 2
        }

        // ── Étage 2 — branches (F2). Le greedy compte comme 1 vote ; early-exit
        // dès qu'un mot atteint la majorité requise.
        let k = SuggestionPolicy.Tuning.escBranchKRuntime
        guard k > 0 else {
            return MidWordEscalationResult(show: false, word: greedy.lead, reason: "uncertain (k=0)")
        }
        var leads = [greedy.lead]
        // Cap tokens des branches SÉPARÉ du greedy (mesuré : 3 suffit, −300 ms vs 8).
        let branchCap = min(request.maxTokens, SuggestionPolicy.Tuning.escBranchMaxTokens)
        let needed = Int((SuggestionPolicy.Tuning.escAgreeThreshRuntime * Double(k + 1)).rounded(.up))
        for i in 0..<k {
            if Task.isCancelled { return nil }
            let b = await runEscalationPass(prompt: prompt, partial: partial, cap: branchCap,
                                            temperature: SuggestionPolicy.Tuning.escBranchTempRuntime,
                                            seed: UInt32(i + 1), captureP1: false)
            leads.append(b.lead)
            let counts = Dictionary(leads.map { ($0.lowercased(), 1) }, uniquingKeysWith: +)
            if let top = counts.values.max(), top >= needed { break }   // early-exit
        }
        let d = SuggestionPolicy.midWordBranchDecision(
            partial: partial, greedyModal: greedy.lead, branchLeads: Array(leads.dropFirst()))
        let reason = "branch agree=\(String(format: "%.2f", d.agreement)) (\(leads.count - 1)br)"
        // C1 : mot CONFIRMÉ par le vote (`d.show`) → mot+continuation (gardée). On
        // ne CONTINUE que si `d.show==true` ; sinon comportement caché inchangé.
        // La continuation part de la ligne greedy COMPLÈTE (pas du lead-word defrag).
        guard d.show else {
            return MidWordEscalationResult(show: false, word: d.word, reason: reason)
        }
        let shown = continuation(confirmedWord: d.word, fullLine: greedy.fullLine)
        return MidWordEscalationResult(show: !shown.isEmpty,
                                       word: shown.isEmpty ? d.word : shown,
                                       reason: reason)
    }

    /// **Long-ghost mid-mot SIMPLIFIÉ (A/B).** Version dépouillée de
    /// `midWordEscalate` : UNE seule passe greedy healed, AUCUN vote de branches
    /// (F2), AUCUN gating fast-accept/fast-reject (F1), AUCUN fallback dico (F3).
    /// Réutilise le MÊME prompt, le MÊME splice de continuation (echo-strip +
    /// exit-guard de langue) et la MÊME struct `MidWordEscalationResult` que
    /// l'escalade, pour un call-site drop-in. Appelée à la place de
    /// `midWordEscalate` quand `midWordLongGhostEnabled` est ON. Le bracketing
    /// `GpuGate` est identique (la traduction ne s'interleave pas).
    /// Nettoyage de TÊTE du ghost (splice partiel + séparateur d'espace v0.4 + dedup
    /// de mot répété + anti-dup mid-mot). MIROIR de la première moitié du post-traitement
    /// de finalisation ci-dessous (lignes « Splice » → anti-dup) ; gardé séparé pour
    /// servir le STREAMING (partiel par token) sans payer les gates lourds (écho, clause,
    /// word-cap) à chaque token. Si tu changes la logique d'espace ici, change-la aussi
    /// dans la finalisation — les deux DOIVENT rester d'accord.
    nonisolated static func leadingCleanLongGhost(
        rawText: String, isBoundary: Bool, partial: String, userTail: String
    ) -> String {
        let fullLine = OutputFilter.singleLine(rawText)
        var stripped = OutputFilter.singleLine(
            OutputFilter.stripPrefixOverlap(fullLine, prefix: isBoundary ? "" : partial))
        if isBoundary, !stripped.isEmpty {
            let body = String(stripped.drop(while: { $0 == " " || $0 == "\t" }))
            let tailEndsWithSpace = userTail.last.map(\.isWhitespace) ?? true
            let modelGlued = fullLine.first.map { !$0.isWhitespace } ?? false
            if body.isEmpty { stripped = "" }
            else if tailEndsWithSpace { stripped = body }
            else if partial.isEmpty { stripped = " " + body }
            else { stripped = modelGlued ? body : " " + body }
        }
        var result = SuggestionPolicy.dedupLeadingRepeat(ghost: stripped, userTail: userTail)
        if !isBoundary, !partial.isEmpty, let f = result.first, f == " " || f == "\t" {
            let body = result.drop(while: { $0 == " " || $0 == "\t" })
            let firstWord = body.prefix(while: { $0.isLetter || $0.isNumber })
            if firstWord.count > partial.count,
               firstWord.lowercased().hasPrefix(partial.lowercased()) {
                result = String(body.dropFirst(partial.count))
            }
        }
        return result
    }

    /// `onPartial` (flag `SOUFFLEUSE_GHOST_STREAM`) : appelé sur le thread du moteur à
    /// CHAQUE token avec le ghost partiel nettoyé (tête seulement). Permet de peindre
    /// au fil de l'eau (~TTFT 20 ms) au lieu d'attendre la génération complète (~300 ms),
    /// que la frappe suivante annulerait. `nil` ⇒ comportement one-shot d'origine.
    func midWordLongGhost(
        request: PredictRequest,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async -> MidWordEscalationResult? {
        guard llamaReady else { return nil }
        let partial = OutputFilter.trailingPartialWord(request.userTail)
        // FRONTIÈRE de mot : tail vide/blanc/ponctuation, OU mot courant complet
        // du dictionnaire (« C'est une| » → « une » complet → on génère le mot
        // SUIVANT, pas une extension de « une »). Le mid-mot INCOMPLET (fragment
        // « un| ») n'est PAS une frontière → on heale et on complète le fragment.
        let isBoundary = partial.isEmpty
            || SuggestionPolicy.defaultPartialWordIsComplete(request.userTail)
        let prompt = ModelRuntime.buildLlamaPrompt(
            system: request.systemMessage,
            customInstr: request.customInstr,
            ctxPrefix: request.ctxPrefix,
            fieldContext: request.fieldContextSlot,
            afterCursor: request.afterCursorSlot,
            beforeCursor: request.llmTail,
            examples: request.examplesBlock
        )
        let expectedLang = ModelRuntime.expectedLanguage(for: request)
        // Budget UNIFIÉ = la préférence « Longueur du souffle » (CompletionLength),
        // portée par `request.maxTokens`/`request.maxWords`. PLUS de budget séparé
        // hardcodé : Court/Moyen/Long dans les Préférences pilote le ghost partout
        // (mid-mot, après-espace, refill). Les env MW_LG_* restent des overrides DEV
        // optionnels pour l'A/B ; par défaut on suit la préférence utilisateur.
        let lgEnv = ProcessInfo.processInfo.environment
        let cap = lgEnv["MW_LG_MAXTOKENS"].flatMap { Int($0) }.map { max(1, $0) } ?? request.maxTokens
        let ghostMaxWords = lgEnv["MW_LG_MAXWORDS"].flatMap { Int($0) }.map { max(1, $0) } ?? request.maxWords
        let streamMinTokens = SuggestionPolicy.Tuning.ghostStreamMinTokens

        GpuGate.shared.ghostBegan()
        defer { GpuGate.shared.ghostEnded() }

        // Gradient d'engagement (flag MW_ENGAGEMENT) : sous le flag on capte la
        // confiance top-1 du greedy (epsilon, n'aborte jamais → sortie inchangée)
        // pour pouvoir trancher le niveau PLEIN/PRUDENT/ZÉRO en aval. Hors flag,
        // `minFirstTokenProb: 0` → chemin et sortie byte-identiques à aujourd'hui.
        let engagementOn = SuggestionPolicy.Tuning.midWordEngagementEnabled

        // ── UNE passe greedy healed (même profil de bans que l'escalade, mais
        // SANS minFirstTokenProb : pas de gating de confiance, on montre la sortie).
        final class Acc: @unchecked Sendable {
            var text = ""
            var tokens = 0
        }
        let acc = Acc()
        let greedyMetrics = await llamaEngine.generate(
            prompt: prompt,
            maxTokens: cap,
            sampling: LlamaSampling(
                temperature: 0,
                repeatPenalty: 1.3,
                repeatLastN: 64,
                seed: 0,
                personalizationStrength: 0,
                banMarkup: true,
                banDigitsLeading: true,
                banEmoji: true,
                minFirstTokenProb: engagementOn
                    ? Float(SuggestionPolicy.Tuning.escFirstTokenProbEpsilon) : 0,
                // À une frontière on NE heale PAS (on veut le mot SUIVANT, pas une
                // extension du mot complet « une ») ; mid-mot incomplet → on heale le partiel.
                healPrefix: isBoundary ? nil : (partial.isEmpty ? nil : partial)
            )
        ) { piece in
            if Task.isCancelled { return false }
            acc.tokens += 1
            acc.text += piece
            // STREAMING : émet le ghost partiel (tête nettoyée) pour peindre dès ~TTFT
            // au lieu d'attendre la fin. On attend `streamMinTokens` tokens avant le
            // PREMIER partiel (chunk consistant, pas 1-2 tokens qui flashent), puis on
            // stream chaque token. Gates lourds (écho, clause, word-cap) en finalisation.
            // `onPartial == nil` ⇒ aucun surcoût.
            if let onPartial, acc.tokens >= streamMinTokens {
                let p = ModelRuntime.leadingCleanLongGhost(
                    rawText: acc.text, isBoundary: isBoundary, partial: partial,
                    userTail: request.userTail)
                if !p.isEmpty { onPartial(p) }
            }
            return true
        }
        if Task.isCancelled { return nil }

        // Splice : retire de la ligne greedy le partiel déjà tapé (même chevauchement
        // de préfixe que le stream), garde la continuation MOINS le partiel. À une
        // FRONTIÈRE la continuation est un mot NEUF (pas une complétion) → on NE
        // strip PAS le partiel.
        let fullLine = OutputFilter.singleLine(acc.text)
        var stripped = OutputFilter.singleLine(
            OutputFilter.stripPrefixOverlap(fullLine, prefix: isBoundary ? "" : partial))
        // Séparateur d'espace de tête. Un ghost ne doit JAMAIS coller deux mots
        // (« une » + « bonne » → « unebonne ») NI casser un mot en cours
        // (« dé » + « cevant » → « dé cevant »). On NE peut PAS se fier au verdict
        // dico : « dé », « gal », « tap » sont des mots valides mais l'utilisateur
        // tape « décevant », « galère », « tapais ». On décide d'après deux signaux
        // FACTUELS plutôt qu'un verdict lexical :
        //   1. la fin réelle de `userTail` (déjà un espace ? → ne pas en rajouter,
        //      sinon « Donc ici  je » en double),
        //   2. le CHOIX du modèle : sa sortie BRUTE commence-t-elle par un espace ?
        //      Le modèle a vu « …dé » et a produit « cevant » (collé) = complétion ;
        //      pour « …une » il produit «  bonne » (espacé) = mot neuf. On respecte
        //      ce choix au lieu de forcer un espace.
        if isBoundary, !stripped.isEmpty {
            let body = String(stripped.drop(while: { $0 == " " || $0 == "\t" }))
            let tailEndsWithSpace = request.userTail.last.map(\.isWhitespace) ?? true
            let modelGlued = fullLine.first.map { !$0.isWhitespace } ?? false
            if body.isEmpty {
                stripped = ""
            } else if tailEndsWithSpace {
                // Le séparateur est déjà dans le tail → ghost collé (pas de double espace).
                stripped = body
            } else if partial.isEmpty {
                // Frontière après ponctuation sans espace (« message.| ») → un séparateur.
                stripped = " " + body
            } else {
                // Mot-fragment jugé « complet » par le dico : on suit le modèle.
                // Collé → complétion de mot (« décevant ») ; espacé → mot neuf (« une bonne »).
                stripped = modelGlued ? body : " " + body
            }
        }
        // Dédup d'un MOT entier répété en tête à une frontière de mot : le modèle
        // re-émet le dernier mot déjà tapé (« de »/« le »/« des »…) → « …de de
        // faire ». `stripPrefixOverlap` ne gère que le partiel mid-mot ;
        // `dedupLeadingRepeat` (même garde que le stream) retire le mot complet.
        var result = SuggestionPolicy.dedupLeadingRepeat(ghost: stripped, userTail: request.userTail)
        // Anti-duplication MID-MOT : quand le modèle rate le healing, il saute en
        // NEXT-WORD en RE-tapant le mot courant (« lo » → «  lors de la » → rendu
        // « lo lors »). `stripPrefixOverlap` ne matche pas (le ghost commence par
        // un espace) ni `dedupLeadingRepeat` (« lors » ≠ « lo »). Ici : si on est
        // mid-mot ET le ghost démarre par un espace suivi d'un mot dont le partiel
        // est préfixe, on retire l'espace + le partiel → vraie complétion (« rs de la »).
        // `!isBoundary` : à une frontière (mot complet), un mot suivant qui débute
        // par les mêmes lettres (« une » → «  unanime ») est LÉGITIME — ne pas le rogner.
        if !isBoundary, !partial.isEmpty, let f = result.first, f == " " || f == "\t" {
            let body = result.drop(while: { $0 == " " || $0 == "\t" })
            let firstWord = body.prefix(while: { $0.isLetter || $0.isNumber })
            if firstWord.count > partial.count,
               firstWord.lowercased().hasPrefix(partial.lowercased()) {
                result = String(body.dropFirst(partial.count))
            }
        }
        // Raison granulaire du gate (visible dans l'inspecteur) : pourquoi rien affiché.
        var why = result.isEmpty ? "emptygen" : "ok"

        // Exit-guard ÉCHO POSITIONNEL (le modèle ne doit pas RECRACHER ta phrase —
        // mais il a le droit de réutiliser du vocabulaire). Le sac-de-mots
        // `echoScore` seul tuait ~50% de bons ghosts (« lancer le serveur »,
        // « m'organiser ») : il confond « répéter verbatim » et « réutiliser des
        // mots ». On exige donc AUSSI un run VERBATIM ≥ `echoMinVerbatimRunWords`
        // mots recopié du tail — seules les vraies boucles (« à savoir si la
        // radioactivité » recrachée) le franchissent. Calibré + validé par
        // `SouffleuseEchoEval` (récupère 3/6 gatés, garde 3/3 boucles).
        if !result.isEmpty {
            let echo = OutputFilter.echoScore(ghost: result, tail: request.userTail)
            if echo >= OutputFilter.continuationEchoThreshold {
                let run = OutputFilter.longestVerbatimRunWords(ghost: result, tail: request.userTail)
                if run >= SuggestionPolicy.Tuning.echoMinVerbatimRunWords {
                    why = "echo(s=\(Self.fmt2(echo)) run=\(run))"
                    result = ""
                }
            }
        }
        // Garde LANGUE : DÉSACTIVÉE par défaut sur le chemin simple. La détection
        // de langue est peu fiable sur 2-3 mots et vidait la majorité des ghosts
        // français légitimes (40/44 gated). Réactivable pour A/B via MW_LG_LANGGUARD=1.
        if !result.isEmpty,
           ProcessInfo.processInfo.environment["MW_LG_LANGGUARD"] != nil,
           OutputFilter.languageMismatch(ghost: result, expected: expectedLang) {
            result = ""; why = "lang"
        }

        // Coupe à la première frontière de clause (newline . ! ? ; :), bornes incluses.
        if let idx = result.firstIndex(where: { "\n.!?;:".contains($0) }) {
            result = String(result[...idx])
        }
        // Cap à N mots entiers, en préservant l'éventuel espace de tête (séparateur).
        let words = result.split(whereSeparator: { $0.isWhitespace })
        if words.count > ghostMaxWords {
            let hadLeadingSpace = result.first == " "
            result = words.prefix(ghostMaxWords)
                .joined(separator: " ")
            if hadLeadingSpace, result.first != " ", !result.isEmpty { result = " " + result }
        }
        result = OutputFilter.singleLine(result)
        if result.isEmpty, why == "ok" { why = "trim" }

        // ── Gradient d'engagement (flag MW_ENGAGEMENT). Hors flag → return d'origine
        // (byte-identique : engagement = .plein par défaut, rolling autorisé comme
        // aujourd'hui). Sous flag, on module la PROFONDEUR du souffle selon
        // l'incertitude de la cascade escalate EXISTANTE (P1 fast-accept + accord
        // des k branches), SANS nouveau signal moteur.
        // Le gradient ne s'applique QU'AU MID-MOT incomplet GLUÉ (complétion du mot
        // courant). À une FRONTIÈRE, ou si le modèle produit un mot NEUF (ghost à
        // espace de tête, ex. « Elon » → «  Musk »), la garde « prolonge le partiel »
        // n'a aucun sens → on garde le long-ghost plein + rolling (living ghost).
        if engagementOn, !isBoundary, result.first != " " {
            return await midWordEngagementResult(
                prompt: prompt, partial: partial, request: request,
                greedyFullLine: acc.text, greedyP1: greedyMetrics.firstTokenProb,
                fullContinuation: result, why: why)
        }

        return MidWordEscalationResult(show: !result.isEmpty, word: result,
                                       reason: result.isEmpty ? "longghost-\(why)" : "longghost")
    }

    /// **Cœur LLM beam (flag `SOUFFLEUSE_BEAM_CORE`).** Génère le ghost via le
    /// `BeamGhostEngine` contraint — le SEUL chemin LLM sous le flag, en
    /// remplacement du greedy long-ghost / engagement / plancher dico.
    ///
    /// - **Mid-mot incomplet** (`partial` non vide, pas un mot complet du dico)
    ///   → beam avec `requiredPrefix = partial`, largeur K=3. La contrainte force
    ///   à compléter le mot tapé ; le ranking log-prob tranche l'accord (handoff
    ///   §a/§b : intention 64 % vs 29 %, accord 9/10 vs 4/10).
    /// - **Frontière / après-espace** (`partial` vide ou mot complet) → décode
    ///   LIBRE à K=1 (≡ greedy, §4A : le beam n'aide pas après-espace et K>1 y
    ///   perd en cohérence). Le `routeInstant` reste DEVANT pour le rappel.
    ///
    /// Post-filtré par `beamPostFilter` (singleLine, dédup, séparateur, écho
    /// positionnel, word-cap) puis par les deux gardes de phrase. Réutilise
    /// `MidWordEscalationResult` pour un call-site PVM commun (show/word/reason).
    ///
    /// **Génération fraîche glissante** (décision UX) : chaque frappe (débouncée)
    /// régénère une fenêtre de `maxWords` mots DEPUIS tout le texte tapé — pas de
    /// réserve pré-calculée. La fenêtre glisse en avant et reste TOUJOURS
    /// conditionnée sur ce que l'utilisateur a réellement tapé. (Le reuse
    /// HIT/REFILL/MISS de la réserve n'amortissait quasi pas en frappe libre — 13 %
    /// de HIT — et n'allongeait pas le ghost ni ne re-conditionnait sur le tapé ;
    /// abandonné ici, le code moteur reste dormant sous le flag.)
    ///
    /// Deux gardes de PHRASE :
    ///  • **G1 (fin de phrase)** : si le ghost contient un `.` `!` `?`, on NE
    ///    propose RIEN — on ne met pas la fin de phrase dans la bouche de
    ///    l'utilisateur (géré dans `beamPostFilter`).
    ///  • **G2 (reprise après le point)** : tant que la PHRASE EN COURS (texte
    ///    après le dernier `.!?`) a moins de `beamMinSentenceLetters` lettres, on
    ///    se tait. Juste après un point ⇒ silence ; on reprend dès que l'utilisateur
    ///    a amorcé la nouvelle phrase (le modèle a alors un vrai contexte).
    func generateGhostBeam(request: PredictRequest) async -> MidWordEscalationResult? {
        guard beamReady else { return nil }
        let userTail = request.userTail

        // G2 — reprise après le point : pas de proposition tant que la phrase en
        // cours n'est pas amorcée (≥ beamMinSentenceLetters lettres après le dernier
        // terminateur). Couvre « on reprend quand l'utilisateur a retapé quelques
        // lettres après le point » SANS coût LLM.
        guard Self.currentSentenceLetterCount(userTail) >= Self.beamMinSentenceLetters else {
            return MidWordEscalationResult(show: false, word: "", reason: "beam-newsentence")
        }

        let partial = OutputFilter.trailingPartialWord(userTail)
        let isBoundary = partial.isEmpty
            || SuggestionPolicy.defaultPartialWordIsComplete(userTail)
        let requiredPrefix = isBoundary ? "" : partial
        // Mid-mot → K plein (la contrainte trie) ; frontière → K=1 (≡ greedy).
        let width = isBoundary ? 1 : beamWidth

        // Prompt = contexte PROSE (« Contexte: » persona + ctxPrefix app/fenêtre/OCR,
        // prose que le base/PT CONTINUE bien) + tout le texte avant curseur. EXCLUS :
        // exemples few-shot (pollueur prouvé), annotation `Champ:`, FIM. `system` /
        // `afterCursor` sont ignorés par le builder.
        let prompt = ModelRuntime.buildLlamaPrompt(
            system: "", customInstr: request.customInstr, ctxPrefix: request.ctxPrefix,
            fieldContext: "", afterCursor: "", beforeCursor: request.llmTail
        )

        // GPU gate (parité translation, TRANSLATION-SPEC §2.9) autour du beam.
        GpuGate.shared.ghostBegan()
        let result = await beamEngine.ghost(prompt: prompt, requiredPrefix: requiredPrefix, maxWidth: width)
        GpuGate.shared.ghostEnded()
        if Task.isCancelled { return nil }
        Log.info(.predictor, "ghost_beam_seed_ms", count: result.elapsedMillis)

        let caretAfterSpace = request.llmTail.last == " " || request.llmTail.last == "\t"
        let ghost = Self.beamPostFilter(
            rawGhost: result.best?.ghost ?? "", isBoundary: isBoundary, caretAfterSpace: caretAfterSpace,
            userTail: userTail, maxWords: request.maxWords)
        Log.info(.predictor, "ghost_beam_words",
                 count: ghost.split(whereSeparator: { $0.isWhitespace }).count)
        return MidWordEscalationResult(show: !ghost.isEmpty, word: ghost,
                                       reason: ghost.isEmpty ? "beam-gated" : "beam")
    }

    /// Nombre de lettres de la PHRASE EN COURS = depuis le dernier terminateur de
    /// phrase (`.` `!` `?`) jusqu'à la fin du texte. Pilote G2 : juste après un
    /// point ⇒ 0 ⇒ silence ; on reprend dès quelques lettres de la nouvelle phrase.
    nonisolated static func currentSentenceLetterCount(_ text: String) -> Int {
        var count = 0
        for ch in text.reversed() {
            if ".!?".contains(ch) { break }
            if ch.isLetter { count += 1 }
        }
        return count
    }

    /// « Quelques lettres » de G2 — seuil d'amorce d'une nouvelle phrase.
    nonisolated static let beamMinSentenceLetters = 3

    /// Garde de sortie du ghost beam — MIROIR des post-filtres du long-ghost
    /// (singleLine, dédup mot répété, séparateur d'espace, écho positionnel,
    /// coupe-clause, word-cap), appliquée au suffixe brut renvoyé par le beam.
    /// `nonisolated static` (pures fonctions OutputFilter/SuggestionPolicy).
    nonisolated static func beamPostFilter(
        rawGhost: String, isBoundary: Bool, caretAfterSpace: Bool,
        userTail: String, maxWords: Int
    ) -> String {
        var result = OutputFilter.singleLine(rawGhost)
        if result.isEmpty { return "" }
        // Dédup d'un mot répété en tête (le beam peut re-émettre le dernier mot tapé).
        result = SuggestionPolicy.dedupLeadingRepeat(ghost: result, userTail: userTail)
        if result.isEmpty { return "" }
        // Séparateur : le beam strippe déjà l'espace de tête après-espace
        // (ghostText, requiredPrefixLen==0). À une frontière NON précédée d'un
        // espace (« message.| »), on rétablit un séparateur ; le mid-mot reste
        // collé (complétion de mot, pas de séparateur).
        if isBoundary, !caretAfterSpace, let f = result.first, f != " ", f != "\t" {
            result = " " + result
        }
        // Écho positionnel : tue les vraies boucles (run verbatim ≥ seuil), garde
        // la réutilisation de vocabulaire — même garde que midWordLongGhost.
        let echo = OutputFilter.echoScore(ghost: result, tail: userTail)
        if echo >= OutputFilter.continuationEchoThreshold {
            let run = OutputFilter.longestVerbatimRunWords(ghost: result, tail: userTail)
            if run >= SuggestionPolicy.Tuning.echoMinVerbatimRunWords { return "" }
        }
        // Coupe à la 1ʳᵉ frontière de clause/phrase (newline . ! ? ; :), bornes
        // INCLUSES — exactement « comme d'hab » (long-ghost) : on montre la suite
        // jusqu'à la fin de phrase comprise, on ne va pas AU-DELÀ. Ne pas proposer
        // la phrase SUIVANTE est le rôle de G2 (reprise après le point), pas de
        // supprimer la complétion en cours.
        if let idx = result.firstIndex(where: { "\n.!?;:".contains($0) }) {
            result = String(result[...idx])
        }
        // Cap à maxWords mots entiers, espace de tête préservé.
        let words = result.split(whereSeparator: { $0.isWhitespace })
        if words.count > max(1, maxWords) {
            let hadLeadingSpace = result.first == " "
            result = words.prefix(max(1, maxWords)).joined(separator: " ")
            if hadLeadingSpace, result.first != " ", !result.isEmpty { result = " " + result }
        }
        return OutputFilter.singleLine(result)
    }

    /// **Gradient d'engagement mi-mot (flag MW_ENGAGEMENT).** À partir du greedy
    /// long-ghost DÉJÀ généré (`fullContinuation` = la continuation pleinement
    /// gatée, `greedyP1` = sa confiance top-1), décide un niveau PLEIN/PRUDENT/ZÉRO
    /// en RÉUTILISANT la cascade escalate existante (mêmes branches `runEscalationPass`
    /// + `midWordBranchDecision` + `midWordEngagementLevel`, mêmes seuils que F1/F2).
    ///
    /// - **PLEIN**   : on garde la continuation greedy complète (~maxWords) ;
    ///   rolling refill autorisé (living ghost).
    /// - **PRUDENT** : on RÉDUIT à 1 mot (le modal greedy défragmenté, FIGÉ) ;
    ///   rolling INTERDIT.
    /// - **ZÉRO**    : abstention (`show: false`).
    ///
    /// DECISION : pour obtenir l'accord des branches sur le chemin long-ghost SANS
    /// dupliquer le vote, on relance les MÊMES branches que l'escalade via le helper
    /// `runEscalationPass` existant (cap court `escBranchMaxTokens`), puis on passe
    /// par `midWordBranchDecision` pour l'accord [0,1]. Le greedy déjà généré compte
    /// comme 1 vote (mot de tête défragmenté). On ne régénère JAMAIS la continuation —
    /// PLEIN réutilise `fullContinuation`, PRUDENT n'en garde que le 1ᵉʳ mot.
    private func midWordEngagementResult(
        prompt: String, partial: String, request: PredictRequest,
        greedyFullLine: String, greedyP1: Double?, fullContinuation: String, why: String
    ) async -> MidWordEscalationResult {
        // Mot de tête défragmenté du greedy (le modal greedy, gardien du vote).
        let greedyLead = SuggestionPolicy.midWordLeadWordDefrag(
            OutputFilter.singleLine(greedyFullLine), partial: partial)

        // Dégénéré STRUCTUREL (le mot de tête ne prolonge pas le partiel) ⇒ ZÉRO
        // direct, on évite le coût des branches. Garde structurelle, PAS dico : ne
        // recale plus les OOV légitimes (marques, noms, anglais, jargon).
        guard SuggestionPolicy.midWordExtendsStructurally(partial: partial, modal: greedyLead) else {
            // Le LLM ne prolonge même pas le mot tapé (« docu » → dérive) : c'est
            // PRÉCISÉMENT là que le dico est le plus utile. Plancher avant de rendre
            // le vide.
            return dicoFloorResult(partial: partial, greedyLead: greedyLead, why: "structdegen")
                ?? MidWordEscalationResult(show: false, word: fullContinuation,
                                           reason: "longghost-engage:zero(\(why))",
                                           engagement: .zero)
        }

        // Fast-accept (mêmes seuils que `midWordFastDecision`) ⇒ PLEIN sans brancher.
        let isFastAccept = (greedyP1 ?? 0) >= SuggestionPolicy.Tuning.escFastP1
            && partial.count >= SuggestionPolicy.Tuning.escMinFastLen

        var agreement = 1.0   // fast-accept : accord implicite (pas de branches lancées)
        if !isFastAccept {
            // Branches stochastiques EXISTANTES (mêmes seeds/cap/temp que l'escalade),
            // pour mesurer l'accord. Early-exit dès la majorité (comme `midWordEscalate`).
            let k = SuggestionPolicy.Tuning.escBranchKRuntime
            if k > 0 {
                let branchCap = min(request.maxTokens, SuggestionPolicy.Tuning.escBranchMaxTokens)
                var leads = [greedyLead]
                let needed = Int((SuggestionPolicy.Tuning.escAgreeThreshRuntime
                                  * Double(k + 1)).rounded(.up))
                for i in 0..<k {
                    if Task.isCancelled {
                        return MidWordEscalationResult(show: false, word: fullContinuation,
                                                       reason: "longghost-engage:zero(cancel)",
                                                       engagement: .zero)
                    }
                    let b = await runEscalationPass(
                        prompt: prompt, partial: partial, cap: branchCap,
                        temperature: SuggestionPolicy.Tuning.escBranchTempRuntime,
                        seed: UInt32(i + 1), captureP1: false)
                    leads.append(b.lead)
                    let counts = Dictionary(leads.map { ($0.lowercased(), 1) }, uniquingKeysWith: +)
                    if let top = counts.values.max(), top >= needed { break }
                }
                agreement = SuggestionPolicy.midWordBranchDecision(
                    partial: partial, greedyModal: greedyLead,
                    branchLeads: Array(leads.dropFirst())).agreement
            } else {
                agreement = 0   // k=0 (override DEV) → pas de signal d'accord → PRUDENT/ZÉRO
            }
        }

        let level = SuggestionPolicy.midWordEngagementLevel(
            partial: partial, greedyLeadWord: greedyLead,
            firstTokenProb: greedyP1, agreement: agreement)
        let agreeStr = String(format: "%.2f", agreement)

        switch level {
        case .zero:
            // Branches lancées, accord trop faible (fin de phrase divergente) :
            // le LLM s'abstient, mais on complète quand même le mot EN COURS via le
            // dico → un mot valide à chaque lettre, plutôt que du vide.
            return dicoFloorResult(partial: partial, greedyLead: greedyLead, why: "agree=\(agreeStr)")
                ?? MidWordEscalationResult(show: false, word: fullContinuation,
                                           reason: "longghost-engage:zero(agree=\(agreeStr))",
                                           engagement: .zero)
        case .prudent:
            // 1 mot (le modal greedy), FIGÉ : on réduit la continuation à son
            // PREMIER mot entier, en préservant l'éventuel espace de tête.
            let prudent = Self.firstWholeWord(of: fullContinuation)
            return MidWordEscalationResult(show: !prudent.isEmpty, word: prudent,
                                           reason: "longghost-engage:prudent(agree=\(agreeStr))",
                                           engagement: .prudent)
        case .plein:
            return MidWordEscalationResult(show: !fullContinuation.isEmpty, word: fullContinuation,
                                           reason: "longghost-engage:plein(agree=\(agreeStr))",
                                           engagement: .plein)
        }
    }

    /// **Plancher dico mid-mot (flag `MW_DICO_FLOOR`, ON par défaut).** Renvoie un
    /// souffle FIGÉ qui complète le mot EN COURS quand le gradient d'engagement
    /// allait rendre du vide (`.zero`). La complétion vient de `NSSpellChecker`
    /// (`WordCompleter.completion`) : le meilleur candidat qui PROLONGE réellement
    /// le préfixe tapé (jamais un mot qui obligerait à reculer). Comme la complétion
    /// se ré-évalue à chaque frappe, une approximation à 3 lettres se précise en
    /// avançant — d'où « un mot valide à chaque lettre tant que le mot n'est pas
    /// fini ». `engagement: .prudent` ⇒ ghost figé, rolling interdit : le plancher
    /// REMPLIT le vide, il ne déclenche jamais le living ghost. `nil` (→ abstention
    /// d'origine) si le flag est coupé, le mot trop court (< 3, `minPartialLength`),
    /// ou aucun candidat ne prolonge. À une frontière (fin de phrase) on n'arrive
    /// jamais ici (chemin gardé par `!isBoundary` + mot partiel en amont).
    private func dicoFloorResult(partial: String, greedyLead: String, why: String) -> MidWordEscalationResult? {
        guard SuggestionPolicy.Tuning.midWordDicoFloorEnabled else { return nil }
        // Orienté par le greedy : NSSpellChecker est context-blind (« mange » →
        // « manger »), mais le mot que le LLM penchait à produire (« mangeons »
        // après « nous ») désambiguïse la conjugaison/forme sans qu'on régénère
        // rien. Si le greedy est vide / parti en vrille (cas dégénéré structurel),
        // la surcharge retombe d'elle-même sur le 1ᵉʳ candidat aveugle.
        guard let suffix = dicoFloorCompleter.completion(for: partial, preferring: greedyLead),
              !suffix.isEmpty else { return nil }
        return MidWordEscalationResult(show: true, word: suffix,
                                       reason: "longghost-engage:floor-dico(\(why))",
                                       engagement: .prudent)
    }

    /// Format court 2 décimales sans `String(format:)` localisé ( for logs/inspecteur).
    nonisolated static func fmt2(_ x: Double) -> String {
        let n = Int((x * 100).rounded())
        return "\(n / 100).\(String(format: "%02d", n % 100))"
    }

    /// Réduit un ghost à son PREMIER mot entier (niveau PRUDENT), en préservant
    /// l'éventuel espace de tête (séparateur) — miroir du word-cap de `midWordLongGhost`.
    nonisolated static func firstWholeWord(of ghost: String) -> String {
        let hadLeadingSpace = ghost.first == " "
        let words = ghost.split(whereSeparator: { $0.isWhitespace })
        guard let first = words.first else { return ghost }
        let one = String(first)
        return hadLeadingSpace ? " " + one : one
    }

    /// **Rolling-refill : prolonge le ghost affiché** (mode sliding-window,
    /// parité Cotypist). Continue depuis une frontière PROPRE — la fin du texte
    /// visible = ce que l'utilisateur a tapé/validé PLUS le reste encore non
    /// consommé (`beforeCursor` est déjà le texte complet visible). Donc PAS de
    /// `healPrefix` ici (on n'est pas mid-mot, on enchaîne après le reste).
    ///
    /// UNE passe greedy, post-traitée par les MÊMES helpers que `midWordLongGhost`
    /// (singleLine, coupe à la 1ʳᵉ frontière de clause, cap à `maxWords` mots
    /// entiers, espace de tête préservé pour se concaténer proprement sur le
    /// reste). Renvoie `nil`/vide si rien d'exploitable.
    func extendGhost(request: PredictRequest, maxWords: Int) async -> String? {
        guard llamaReady else { return nil }
        let prompt = ModelRuntime.buildLlamaPrompt(
            system: request.systemMessage,
            customInstr: request.customInstr,
            ctxPrefix: request.ctxPrefix,
            fieldContext: request.fieldContextSlot,
            afterCursor: request.afterCursorSlot,
            beforeCursor: request.llmTail,
            examples: request.examplesBlock
        )
        // Assez de tokens pour ~maxWords mots, borné par le maxTokens de la requête.
        let cap = min(request.maxTokens, max(1, maxWords) * 4 + 2)

        GpuGate.shared.ghostBegan()
        defer { GpuGate.shared.ghostEnded() }

        final class Acc: @unchecked Sendable { var text = "" }
        let acc = Acc()
        _ = await llamaEngine.generate(
            prompt: prompt,
            maxTokens: cap,
            sampling: LlamaSampling(
                temperature: 0,
                repeatPenalty: 1.3,
                repeatLastN: 64,
                seed: 0,
                personalizationStrength: 0,
                banMarkup: true,
                banDigitsLeading: true,
                banEmoji: true,
                minFirstTokenProb: 0,
                healPrefix: nil  // frontière propre après le reste : pas de healing.
            )
        ) { piece in
            if Task.isCancelled { return false }
            acc.text += piece
            return true
        }
        if Task.isCancelled { return nil }

        var result = OutputFilter.singleLine(acc.text)
        if result.isEmpty { return nil }
        // Dédup d'un mot répété en tête : le refill ne doit pas re-émettre le
        // dernier mot déjà visible (« …de » + « de faire » → « de faire »).
        result = SuggestionPolicy.dedupLeadingRepeat(ghost: result, userTail: request.userTail)
        if result.isEmpty { return nil }

        // Exit-guard ÉCHO : le refill ne doit pas répéter le texte déjà visible.
        if OutputFilter.echoScore(ghost: result, tail: request.userTail)
            >= OutputFilter.continuationEchoThreshold {
            return nil
        }
        // Coupe à la première frontière de clause (newline . ! ? ; :), bornes incluses.
        if let idx = result.firstIndex(where: { "\n.!?;:".contains($0) }) {
            result = String(result[...idx])
        }
        // Cap à `maxWords` mots entiers, en préservant l'éventuel espace de tête.
        let words = result.split(whereSeparator: { $0.isWhitespace })
        if words.count > max(1, maxWords) {
            let hadLeadingSpace = result.first == " "
            result = words.prefix(max(1, maxWords)).joined(separator: " ")
            if hadLeadingSpace, result.first != " ", !result.isEmpty { result = " " + result }
        }
        result = OutputFilter.singleLine(result)
        // Garde un UNIQUE espace de tête pour se concaténer proprement sur le reste.
        if !result.isEmpty, result.first != " " { result = " " + result }
        return result.isEmpty ? nil : result
    }

    /// Une passe d'escalade (greedy ou branche) : génère, renvoie le mot de tête +
    /// la confiance top-1 si demandée. Pas de `GpuGate` ici — le bracketing est
    /// fait UNE fois par `midWordEscalate`. `temperature 0` = greedy déterministe ;
    /// `> 0` = branche stochastique seedée (`topP 0.9`).
    private func runEscalationPass(
        prompt: String, partial: String, cap: Int,
        temperature: Float, seed: UInt32, captureP1: Bool
    ) async -> (lead: String, p1: Double?, fullLine: String) {
        final class Acc: @unchecked Sendable { var text = "" }
        let acc = Acc()
        let metrics = await llamaEngine.generate(
            prompt: prompt,
            maxTokens: cap,
            sampling: LlamaSampling(
                temperature: temperature,
                repeatPenalty: 1.3,
                repeatLastN: 64,
                seed: seed,
                personalizationStrength: 0,
                topP: temperature > 0 ? 0.9 : 0,
                banMarkup: true,
                banDigitsLeading: true,
                banEmoji: true,
                minFirstTokenProb: captureP1 ? Float(SuggestionPolicy.Tuning.escFirstTokenProbEpsilon) : 0,
                healPrefix: partial.isEmpty ? nil : partial
            )
        ) { piece in
            if Task.isCancelled { return false }
            acc.text += piece
            return true
        }
        let oneLine = acc.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? acc.text
        // `lead` = mot de tête dé-fragmenté (gardien du vote, inchangé) ; `fullLine`
        // = le texte greedy complet d'une ligne (C1 : sert la CONTINUATION mot+suite
        // quand le mot est confirmé). Les branches ne lisent que `lead` pour voter.
        return (SuggestionPolicy.midWordLeadWordDefrag(oneLine, partial: partial),
                metrics.firstTokenProb, oneLine)
    }

    /// Builds a Gemma-3 instruct prompt (FIM-style : pre + afterCursor) and
    /// streams the completion through `LlamaEngine`, running the existing
    /// `OutputFilter` pipeline on the cumulative output and pushing filtered
    /// one-line ghost text to `onChunk`.
    private func generateLlama(
        request: PredictRequest,
        onChunk: @escaping @Sendable @MainActor (String) -> Void
    ) async -> StreamMetrics? {
        let userTail = request.userTail
        let llmTail = request.llmTail
        let maxTokens = request.maxTokens
        let maxWords = request.maxWords

        let prompt = ModelRuntime.buildLlamaPrompt(
            system: request.systemMessage,
            customInstr: request.customInstr,
            ctxPrefix: request.ctxPrefix,
            fieldContext: request.fieldContextSlot,
            afterCursor: request.afterCursorSlot,
            beforeCursor: llmTail,
            examples: request.examplesBlock
        )
        // Context-echo guard input : the ACTUAL injected context block (app/
        // window/clipboard/OCR prose + the FR field annotation). NOT the user's
        // own text (customInstr / examples / beforeCursor are excluded) — only
        // the framing whose reproduction by the base model is meaningless and a
        // clipboard/OCR leak. Empty when context is thin → guard is a no-op.
        let contextPreamble = [request.ctxPrefix, request.fieldContextSlot]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        // `buildLlamaPrompt` stripped the caret's trailing space before feeding
        // the model, so the model emits the next token WITH its own leading
        // space (" arriver"). When the caret sits AFTER a space, that space is
        // already typed — drop the ghost's leading space so we render
        // "on va y arriver.", not "on va y  arriver.". When the caret is NOT
        // after a space (mid/after-word), keep the leading space (next-word
        // continuation "frais" → " de port").
        let caretAfterSpace = llmTail.last == " " || llmTail.last == "\t"

        // Confidence gate (Cotypist `minBranchProbability` parity). Mid-word —
        // the caret sits inside a word (last typed char is a letter/number) —
        // is exactly where the LLM guesses the WRONG word ("co"→colette,
        // "c"→aca, "Po"→issons): the live overlay_shown log showed 80% of ghosts
        // are mid-word and that is where the incoherence concentrates. We demand
        // a high first-token probability there so the model only completes a
        // word it is confident about, and stays silent (empty ghost) otherwise.
        // At a word boundary several continuations are all legitimate, so we
        // leave the gate off (0) — the LLM is reliable there.
        let caretMidWord = userTail.last.map { $0.isLetter || $0.isNumber } ?? false
        let minFirstTokenProb: Float = caretMidWord ? Self.midWordMinFirstTokenProb : 0

        // Token healing (Task 1). When the caret sits mid-word, hand the engine
        // the trailing partial word as `healPrefix`: it drops the partial token
        // and masks the first generated tokens so the WHOLE word is re-derived
        // from a clean boundary ("Rapport fis" → " fiscal annuel 2019", not the
        // broken "fiscaal"). The prompt's `beforeCursor` (llmTail) ends with the
        // SAME partial as `userTail` — mid-word means no trailing space, and
        // `llmTail` is just the (corrected) suffix of `userTail` — so the partial
        // computed from `userTail` is exactly what sits at the end of the prompt.
        // Gated behind `midWordHealingEnabled` so it is reversible (default nil →
        // engine output byte-identical to the un-healed path).
        var healPrefix: String? = nil
        if SuggestionPolicy.Tuning.midWordHealingEnabled && caretMidWord {
            let partial = OutputFilter.trailingPartialWord(userTail)
            if !partial.isEmpty { healPrefix = partial }
        }

        // Accumulator + last-emitted tracker, isolated behind a class so the
        // @Sendable onToken closure can mutate it without crossing the actor
        // boundary back to @MainActor on every token.
        final class Acc: @unchecked Sendable {
            var generated = ""
            var lastEmitted = ""
        }
        let acc = Acc()

        // Le ghost réclame le GPU : la traduction (2e moteur) retarde son décode
        // tant que ce compteur n'est pas retombé à zéro (TRANSLATION-SPEC §2.9).
        GpuGate.shared.ghostBegan()
        let metrics = await llamaEngine.generate(
            prompt: prompt,
            maxTokens: maxTokens,
            sampling: LlamaSampling(
                temperature: 0,
                // Relevance profile (validated by the 7-experiment probe sweep):
                // the base/pt Gemma derails into web markup (<strong>), a "web
                // number" prior ("Des " → "20 ans"), and emoji fallbacks. Banning
                // those at the sampler — greedy, deterministic, KV-cache-safe —
                // moves output from "2017 du Festival" to "de transport sont à la
                // charge du client" / "erreur de syntaxe" / "fruits, des légumes".
                // Digits banned ONLY on the first token (the prior is strongest
                // there) so legitimate numbers later ("à 14 heures") survive. A
                // slightly higher repetition penalty (1.3) curbs the loops.
                repeatPenalty: 1.3,
                repeatLastN: 64,
                // Gain calibration (Phase 3) : the Preferences slider is
                // 0.0…2.0 (default 1.0), but the raw logit boost needs to be
                // an order of magnitude larger to actually steer (Phase 1
                // probe required strength≈8 on a bare bigram). We map the
                // preference through a fixed internal multiplier so that the
                // DEFAULT preference (1.0) lands near the proven-steering
                // base gain, while the suffix-array `matchLength` sharpening
                // (applied inside the engine) does the rest for longer
                // matches. Slider Max (2.0) ⇒ 2× base. See
                // `LlamaSampling.personalizationGainScale`.
                personalizationStrength: Float(request.personalizationStrength)
                    * LlamaSampling.personalizationGainScale,
                banMarkup: true,
                banDigitsLeading: true,
                banEmoji: true,
                minFirstTokenProb: minFirstTokenProb,
                healPrefix: healPrefix
            )
        ) { piece in
            if Task.isCancelled { return false }
            acc.generated += piece

            // ── Filter pipeline (extracted VERBATIM to ChunkFilter, Phase 5) ──
            // `ChunkFilter.filterChunk` reproduces the full snapshot→oneLine
            // computation (stripPrefixOverlap, leading-whitespace drop gated on
            // caretAfterSpace, first-line, markup/`**`/`__`/backtick/U+FFFD
            // strip, sentence-terminator truncation preserving a single leading
            // space, word cap). The verdict maps the three drop/emit branches.
            // The `acc.lastEmitted` "emit only when changed" rule and the
            // `acc.lastEmitted=""` resets + `onChunk(...)` / `Log.*` side
            // effects stay HERE so the observable sequence is identical.
            //
            // NOTE — mid-word coherence guard REMOVED (2026-05-27). The probe
            // proved fresh greedy mid-word output is coherent; the spell-check
            // only produced false positives. `OutputFilter.midWordCandidate` is
            // retained (pure helper + tests) but no longer gates emission.
            let (verdict, dropReason, sentenceComplete, reachedWordCap) = ChunkFilter.filterChunk(
                accumulated: acc.generated,
                userTail: userTail,
                caretAfterSpace: caretAfterSpace,
                maxWords: maxWords,
                contextPreamble: contextPreamble
            )
            switch verdict {
            case .reset:
                Log.info(.predictor, "ghost_dropped_repeat")
                let chunkOut = ""
                Task { @MainActor in onChunk(chunkOut) }
                return true
            case .dropKeepGenerating:
                if dropReason == .instructionEcho {
                    Log.info(.predictor, "ghost_dropped_instruction_echo")
                } else if dropReason == .contextEcho {
                    Log.info(.predictor, "ghost_dropped_context_echo")
                }
                if !acc.lastEmitted.isEmpty {
                    acc.lastEmitted = ""
                    Task { @MainActor in onChunk("") }
                }
                return true
            case .emit(let oneLine):
                // Emit only when the filtered one-line ghost actually changed.
                if oneLine != acc.lastEmitted {
                    acc.lastEmitted = oneLine
                    let chunkOut = oneLine
                    Task { @MainActor in onChunk(chunkOut) }
                }
                // Stop generating once the ghost is done. Two conditions, both
                // evaluated even when the displayed text is unchanged:
                //   • sentenceComplete — truncated at a sentence terminator;
                //     everything past the cut is discarded by the display anyway.
                //   • reachedWordCap — the budget (expressed in COMPLETE words,
                //     not raw tokens) is full. Stopping here lands on a word
                //     boundary, never mid-word: a trailing in-progress word (e.g.
                //     a dangling "l'") is not counted, so decoding keeps going
                //     until it completes into a real word ("l'arbre"). The raw
                //     maxTokens cap is only a generous backstop above this.
                return !sentenceComplete && !reachedWordCap
            }
        }
        GpuGate.shared.ghostEnded()

        if Task.isCancelled { return nil }
        var m = StreamMetrics()
        m.ttftMillis = metrics.ttftMillis
        m.tokensPerSecond = metrics.tokensPerSecond
        return m
    }

    /// Assembles the prompt for **raw text continuation**.
    ///
    /// The shipped GGUF is the **base / pretrained** Gemma 3 (`finetune = pt`),
    /// NOT the instruct model — same file Cotypist uses. A base model has never
    /// seen the `<start_of_turn>` chat template or instruction framing; wrapping
    /// it in one produces generic/off-topic words and English drift. So we feed
    /// it the way a base model expects: plain text it simply continues, ending
    /// in `beforeCursor`. Cotypist does the same (its `basePromptPrefix` + raw
    /// text). Any contextual prose (app/field context) is prepended as a light
    /// prefix; `beforeCursor` is always last so the continuation extends it.
    ///
    /// `system` / `afterCursor` are intentionally NOT injected as instructions —
    /// a base model can't follow imperative directives and they only pollute the
    /// continuation. Language steering is unnecessary: the base model continues
    /// in whatever language the input text is already in.
    ///
    /// `customInstr` (the user's personalisation) IS injected — but as a French
    /// `Contexte :` PROSE block, never as a command. A base/PT model can't obey
    /// "your name is X", yet it readily CONTINUES from a stated fact: prepending
    /// "Contexte : Je m'appelle Gabriel." makes "Je m'appelle " complete to
    /// "Gabriel" instead of a random name. Proven at the probe (VOLET PERSONA):
    /// every framing fixed the name; the French `Contexte :` label specifically
    /// did so WITHOUT bleeding the persona into unrelated text (an English "My
    /// writing:" label dragged "Cocotypist" into a delivery sentence — avoided).
    /// This mirrors Cotypist, which injects the same kind of labelled block
    /// (`PromptTemplates` / "My writing:") rather than a chat-template system
    /// message.
    ///
    /// **Phase 5** : forwarding shim to `LlamaPromptBuilder.buildLlamaPrompt`
    /// (extracted to SouffleuseCore). Kept so `ModelRuntime.buildLlamaPrompt`
    /// call-sites (generateLlama, BuildLlamaPromptTests) compile unchanged.
    static func buildLlamaPrompt(
        system: String,
        customInstr: String,
        ctxPrefix: String,
        fieldContext: String,
        afterCursor: String,
        beforeCursor: String,
        examples: String = ""
    ) -> String {
        LlamaPromptBuilder.buildLlamaPrompt(
            system: system,
            customInstr: customInstr,
            ctxPrefix: ctxPrefix,
            fieldContext: fieldContext,
            afterCursor: afterCursor,
            beforeCursor: beforeCursor,
            examples: examples
        )
    }
}
