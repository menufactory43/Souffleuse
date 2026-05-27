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
        let ok = await llamaEngine.load(modelPath: ggufPath, contextTokens: 4096)
        llamaReady = ok
        if !ok {
            Log.error(.predictor, "model_load_failed")
            self.lastError = "load_failed: gguf"
        } else {
            self.lastError = nil
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
        cache: CompletionCache,
        onChunk: @escaping @Sendable @MainActor (String) -> Void
    ) async -> StreamMetrics? {
        guard llamaReady else { return nil }
        return await generateLlama(request: request, onChunk: onChunk)
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
            beforeCursor: llmTail
        )
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

        // Accumulator + last-emitted tracker, isolated behind a class so the
        // @Sendable onToken closure can mutate it without crossing the actor
        // boundary back to @MainActor on every token.
        final class Acc: @unchecked Sendable {
            var generated = ""
            var lastEmitted = ""
        }
        let acc = Acc()

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
                minFirstTokenProb: minFirstTokenProb
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
            let (verdict, dropReason) = ChunkFilter.filterChunk(
                accumulated: acc.generated,
                userTail: userTail,
                caretAfterSpace: caretAfterSpace,
                maxWords: maxWords
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
                }
                if !acc.lastEmitted.isEmpty {
                    acc.lastEmitted = ""
                    Task { @MainActor in onChunk("") }
                }
                return true
            case .emit(let oneLine):
                // Only emit when the filtered one-line ghost actually changed.
                guard oneLine != acc.lastEmitted else { return true }
                acc.lastEmitted = oneLine
                let chunkOut = oneLine
                Task { @MainActor in onChunk(chunkOut) }
                // Stop once we hit a sentence terminator (the truncation above
                // already trimmed at it) — no value generating further tokens.
                return true
            }
        }

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
        beforeCursor: String
    ) -> String {
        LlamaPromptBuilder.buildLlamaPrompt(
            system: system,
            customInstr: customInstr,
            ctxPrefix: ctxPrefix,
            fieldContext: fieldContext,
            afterCursor: afterCursor,
            beforeCursor: beforeCursor
        )
    }

    /// Verbatim MLX generation body — retained dead for reference; no longer
    /// called now that `generate` routes through llama.cpp.
    private func generateMLX(
        request: PredictRequest,
        cache: CompletionCache,
        onChunk: @escaping @Sendable @MainActor (String) -> Void
    ) async -> StreamMetrics? {
        guard let container = self.container else { return nil }

        // Hoist all values from request into local Sendable lets so the
        // container.perform closure captures pure-value bindings.
        let userTail = request.userTail
        let llmTail = request.llmTail
        let isInstructModel = request.isInstructModel
        let systemMessage = request.systemMessage
        let baseSystem = request.baseSystem
        let customInstr = request.customInstr
        let ctxPrefix = request.ctxPrefix
        let fieldContextSlot = request.fieldContextSlot
        let afterCursorSlot = request.afterCursorSlot
        let examplesBlock = request.examplesBlock
        let basePromptText = request.basePromptText
        let maxTokens = request.maxTokens
        let maxWords = request.maxWords
        let personalizationStrength = Float(request.personalizationStrength)
        let ngramSnapshot = request.ngramSnapshot
        let token = request.token

        // Local references to cache sub-objects (captured by the
        // Sendable closure without touching `self`).
        let tokenCountCache = cache.tokenCountCache
        let sessionCacheHolder = cache.kvCacheHolder
        let completionCache = cache

        do {
            let metrics = try await container.perform { context -> StreamMetrics in
                let promptTokens: [Int]
                // PromptBuilderFlag.enabled is fileprivate to PVM. For 04-06
                // we adopt the same env-var check inline here — single source
                // of truth lives in PVM, but this duplicate is unavoidable
                // because PromptBuilderFlag is type-private. Dédup en 04-07
                // (move PromptBuilderFlag to SouffleusePrompt or here).
                let promptBuilderEnabled = ProcessInfo.processInfo
                    .environment["SOUFFLEUSE_PROMPT_BUILDER"]?.isEmpty == false
                if promptBuilderEnabled {
                    let mlxCounter = MLXTokenCounter(tokenizer: context.tokenizer)
                    let counter = MemoizingTokenCounter(inner: mlxCounter, cache: tokenCountCache)
                    let builder = PromptBuilder(counter: counter, budget: .phase2Default)
                    let buildT0 = Date()
                    let built = builder.build(
                        system: baseSystem,
                        customInstructions: customInstr,
                        contextPrefix: ctxPrefix,
                        fieldContext: fieldContextSlot,
                        afterCursor: afterCursorSlot,
                        previousUserInputs: examplesBlock,
                        beforeCursor: userTail
                    )
                    let buildMs = Int(Date().timeIntervalSince(buildT0) * 1000)
                    Log.info(.predictor, "prompt_built", count: built.totalTokens)
                    Log.info(.predictor, "prompt_build_ms", count: buildMs)

                    if isInstructModel {
                        let userContent = built.slotTexts[.beforeCursor] ?? ""
                        let systemContent = [
                            built.slotTexts[.system],
                            built.slotTexts[.customInstructions],
                            built.slotTexts[.contextPrefix],
                            built.slotTexts[.fieldContext],
                            built.slotTexts[.afterCursor],
                            built.slotTexts[.previousUserInputs],
                        ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
                        let messages: [[String: String]] = [
                            ["role": "system", "content": systemContent],
                            ["role": "user", "content": userContent],
                        ]
                        if let templated = try? context.tokenizer.applyChatTemplate(messages: messages) {
                            promptTokens = templated
                        } else {
                            promptTokens = context.tokenizer.encode(text: built.text)
                        }
                    } else {
                        promptTokens = context.tokenizer.encode(text: built.text)
                    }
                } else if isInstructModel {
                    let messages: [[String: String]] = [
                        ["role": "system", "content": systemMessage],
                        ["role": "user", "content": llmTail],
                    ]
                    if let templated = try? context.tokenizer.applyChatTemplate(messages: messages) {
                        promptTokens = templated
                    } else {
                        promptTokens = context.tokenizer.encode(text: basePromptText)
                    }
                } else {
                    promptTokens = context.tokenizer.encode(text: basePromptText)
                }

                let params = GenerateParameters(
                    maxTokens: maxTokens,
                    temperature: 0,
                    topP: 0.9,
                    repetitionPenalty: 1.0,
                    repetitionContextSize: 32
                )

                // ── KV-cache decision tree (verbatim PVM:1048-1204) ────────
                let canonicalExamplesBlock = InvariancePrefix.canonicalizePreviousUserInputs(examplesBlock)
                let invariance = InvariancePrefix(
                    system: baseSystem,
                    customInstructions: customInstr,
                    contextPrefix: ctxPrefix,
                    fieldContext: fieldContextSlot,
                    afterCursor: afterCursorSlot,
                    previousUserInputs: canonicalExamplesBlock
                )
                let newFingerprint = invariance.fingerprint

                let kvMlxCounter = MLXTokenCounter(tokenizer: context.tokenizer)
                let kvCounter = MemoizingTokenCounter(inner: kvMlxCounter, cache: tokenCountCache)
                let userTailTokenCount = kvCounter.countTokens(userTail)
                let invariantPrefixTokenCount = max(0, promptTokens.count - userTailTokenCount)

                struct DecisionSnapshot: @unchecked Sendable {
                    let purelDecision: KVDecision
                    let existingCaches: CacheBox?
                    let priorBeforeCursorTokens: Int
                }
                let snap: DecisionSnapshot = await MainActor.run {
                    let dec = completionCache.decideExtendTrimInvalidate(
                        invariance: invariance,
                        userTailTokenCount: userTailTokenCount,
                        promptTokens: promptTokens.count
                    )
                    let existing = (sessionCacheHolder.caches as? [KVCache])
                        .map(CacheBox.init(caches:))
                    return DecisionSnapshot(
                        purelDecision: dec,
                        existingCaches: existing,
                        priorBeforeCursorTokens: sessionCacheHolder.beforeCursorTokens
                    )
                }
                let envBypass = (snap.purelDecision == .bypass)

                var chosenCache: [KVCache]
                var iteratorInputTokens: [Int] = promptTokens
                let decision: KVDecision

                switch snap.purelDecision {
                case .bypass:
                    chosenCache = makePromptCache(model: context.model, parameters: params)
                    decision = .bypass
                case .cold:
                    chosenCache = makePromptCache(model: context.model, parameters: params)
                    decision = .cold
                case .fingerprintChanged:
                    chosenCache = makePromptCache(model: context.model, parameters: params)
                    decision = .fingerprintChanged
                case .extend(let addedTokens):
                    let existing = snap.existingCaches!.caches
                    chosenCache = existing
                    let newCount = userTailTokenCount
                    let beforeCursorTokens = Array(promptTokens.suffix(newCount))
                    let deltaTokens = Array(beforeCursorTokens.dropFirst(snap.priorBeforeCursorTokens))
                    iteratorInputTokens = deltaTokens
                    decision = .extend(addedTokens: addedTokens)
                case .trim(let removedTokens):
                    let existing = snap.existingCaches!.caches
                    if canTrimPromptCache(existing) {
                        _ = trimPromptCache(existing, numTokens: removedTokens)
                        chosenCache = existing
                        iteratorInputTokens = []
                        decision = .trim(removedTokens: removedTokens)
                    } else {
                        chosenCache = makePromptCache(model: context.model, parameters: params)
                        iteratorInputTokens = promptTokens
                        decision = .diverged
                    }
                case .diverged:
                    chosenCache = makePromptCache(model: context.model, parameters: params)
                    iteratorInputTokens = promptTokens
                    decision = .diverged
                case .identical:
                    let existing = snap.existingCaches!.caches
                    chosenCache = existing
                    iteratorInputTokens = []
                    decision = .identical
                }

                if iteratorInputTokens.isEmpty, !promptTokens.isEmpty {
                    iteratorInputTokens = [promptTokens.last!]
                }

                let input = LMInput(tokens: MLXArray(iteratorInputTokens))

                // Mapping verdict → log count (verbatim PVM:1188-1203 + plan
                // Task 1 documentation) :
                //   .extend(n) → kv_cache_extend count: n
                //   .trim(n)   → kv_cache_trim   count: n
                //   .cold      → kv_cache_invalidate count: 0
                //   .fingerprintChanged → kv_cache_invalidate count: 1
                //   .diverged  → kv_cache_invalidate count: 2
                //   .bypass / .identical → no log
                switch decision {
                case .bypass:
                    break
                case .cold:
                    Log.info(.predictor, "kv_cache_invalidate", count: 0)
                case .fingerprintChanged:
                    Log.info(.predictor, "kv_cache_invalidate", count: 1)
                case .extend(let n):
                    Log.info(.predictor, "kv_cache_extend", count: n)
                case .trim(let n):
                    Log.info(.predictor, "kv_cache_trim", count: n)
                case .diverged:
                    Log.info(.predictor, "kv_cache_invalidate", count: 2)
                case .identical:
                    break
                }
                _ = envBypass

                // Personalization path : ngramSnapshot is precomputed by caller.
                let stream: AsyncStream<Generation>
                if let snapshot = ngramSnapshot, !snapshot.isEmpty, personalizationStrength > 0 {
                    let repetition = RepetitionContext(
                        repetitionPenalty: 1.0, repetitionContextSize: 32
                    )
                    let bias = NgramLogitBias(
                        snapshot: snapshot, strength: personalizationStrength
                    )
                    let chain = ChainLogitProcessor(first: repetition, second: bias)
                    let iterator = try TokenIterator(
                        input: input,
                        model: context.model,
                        cache: chosenCache,
                        processor: chain,
                        sampler: params.sampler(),
                        maxTokens: maxTokens
                    )
                    stream = MLXLMCommon.generate(
                        input: input, context: context, iterator: iterator
                    )
                } else {
                    let iterator = try TokenIterator(
                        input: input,
                        model: context.model,
                        cache: chosenCache,
                        processor: nil,
                        sampler: params.sampler(),
                        maxTokens: maxTokens
                    )
                    stream = MLXLMCommon.generate(
                        input: input, context: context, iterator: iterator
                    )
                }

                // Commit holder state for the next predict (verbatim PVM:1247-1274).
                if !envBypass {
                    let installBox = CacheBox(caches: chosenCache)
                    let finalBeforeCursor = userTailTokenCount
                    let fpToInstall = newFingerprint
                    let shouldInstall: Bool
                    switch decision {
                    case .cold, .fingerprintChanged, .diverged:
                        shouldInstall = true
                    case .extend, .trim, .identical:
                        shouldInstall = false
                    case .bypass:
                        shouldInstall = false
                    }
                    await MainActor.run {
                        if shouldInstall {
                            sessionCacheHolder.install(
                                caches: installBox.caches,
                                fingerprint: fpToInstall,
                                beforeCursorTokens: finalBeforeCursor
                            )
                        } else {
                            sessionCacheHolder.updateBeforeCursorTokens(finalBeforeCursor)
                        }
                    }
                }
                _ = invariantPrefixTokenCount

                var firstTokenAt: Date?
                var generated = ""
                var tokenCount = 0
                let start = Date()
                _ = token // token is consumed by the caller's onChunk closure for
                          // `planner.isCurrent(token)` checks — kept in signature
                          // for symmetry / future use.

                for await event in stream {
                    if Task.isCancelled { break }
                    if case .chunk(let text) = event {
                        if firstTokenAt == nil { firstTokenAt = Date() }
                        tokenCount += 1
                        generated += text

                        // ── Filter pipeline (verbatim PVM:702-749 onChunk
                        // closure body, MINUS the @MainActor side-effects
                        // which are delegated to the caller via onChunk).
                        let snapshot = OutputFilter.stripPrefixOverlap(generated, prefix: userTail)
                        let stripped = snapshot.drop(while: { $0 == "\n" || $0 == "\r" })
                        var oneLine: String
                        if let nl = stripped.firstIndex(of: "\n") {
                            oneLine = String(stripped[..<nl])
                        } else {
                            oneLine = String(stripped)
                        }
                        oneLine = oneLine.replacingOccurrences(
                            of: "<[/!?]?[A-Za-z][A-Za-z0-9]{0,15}\\s*[^>]{0,32}>",
                            with: "",
                            options: .regularExpression
                        )
                        oneLine = oneLine.replacingOccurrences(of: "**", with: "")
                        oneLine = oneLine.replacingOccurrences(of: "__", with: "")
                        oneLine = oneLine.replacingOccurrences(of: "`", with: "")
                        if oneLine.count > 3 {
                            // Preserve a single LEADING space (next-word
                            // continuation after a complete word: "…les frais" →
                            // " de port. Mais" must render "frais de port.").
                            let hadLeadingSpace = oneLine.first == " "
                            for terminator in [". ", "? ", "! ", "… "] {
                                if let r = oneLine.range(of: terminator) {
                                    var cut = String(oneLine[..<r.upperBound]).trimmingCharacters(in: .whitespaces)
                                    if hadLeadingSpace { cut = " " + cut }
                                    oneLine = cut
                                    break
                                }
                            }
                        }
                        if oneLine.count > 12, let r = oneLine.range(of: ", ") {
                            oneLine = String(oneLine[..<r.lowerBound])
                        }
                        let words = oneLine.split(whereSeparator: { $0.isWhitespace })
                        if words.count > maxWords {
                            oneLine = words.prefix(maxWords).joined(separator: " ")
                        }
                        // Anti-repeat safety net : if the ghost starts by
                        // restating the prefix, drop. We signal the drop
                        // by emitting an EMPTY chunk so the caller can
                        // decide to fall back to its instant ghost — same
                        // semantic as PVM:755-766 but cleaner across the
                        // actor boundary.
                        if OutputFilter.ghostIsRepeatingPrefix(oneLine, prefix: userTail) {
                            Log.info(.predictor, "ghost_dropped_repeat")
                            let chunkOut = ""
                            Task { @MainActor in
                                onChunk(chunkOut)
                            }
                            continue
                        }
                        let chunkOut = oneLine
                        Task { @MainActor in
                            onChunk(chunkOut)
                        }
                    }
                }

                var m = StreamMetrics()
                if let first = firstTokenAt {
                    m.ttftMillis = Int(first.timeIntervalSince(start) * 1000)
                    let elapsed = Date().timeIntervalSince(first)
                    if elapsed > 0 {
                        m.tokensPerSecond = Double(tokenCount) / elapsed
                    }
                }
                return m
            }
            return metrics
        } catch {
            if !Task.isCancelled {
                let msg = error.localizedDescription
                Log.error(.predictor, "predict_failed")
                await MainActor.run {
                    self.lastError = msg
                }
            }
            return nil
        }
    }
}
