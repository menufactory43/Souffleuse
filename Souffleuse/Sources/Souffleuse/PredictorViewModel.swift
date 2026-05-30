import Foundation
import MLXLLM
import MLXLMCommon
import SouffleuseAX
import SouffleuseCore
import SouffleuseLog
import SouffleusePersonalization
import SouffleusePrompt
import SouffleuseTyping

/// Opt-in debug trace for predict() decisions. Gated on env var
/// `SOUFFLEUSE_PREDICT_LOG` (any non-empty value enables). Writes raw user
/// text to `/tmp/souffleuse-predict.log` — NEVER use in production builds
/// or check audit.sh's privacy rules; /tmp is acceptable for active debug.
/// Launch with: `SOUFFLEUSE_PREDICT_LOG=1 open .../Souffleuse.app`
private enum PredictDebug {
    static let enabled: Bool = ProcessInfo.processInfo.environment["SOUFFLEUSE_PREDICT_LOG"]?.isEmpty == false
    static let path = "/tmp/souffleuse-predict.log"
    static let lock = NSLock()

    static func log(_ tag: String, _ payload: String = "") {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(tag) \(payload)\n"
        if let data = line.data(using: .utf8) {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
    }
}

/// Mutable @MainActor-only flag recording whether the in-flight generation has
/// ever set a ghost for the current prefix (a valid LLM chunk, or an empty-chunk
/// fallback to a valid instant ghost). Captured by both the `onChunk` closure
/// and the completion block — both run on @MainActor, so a plain reference box
/// is race-free. Drives the stale-ghost clear in `predict(...)`.
@MainActor
private final class GhostEmissionTracker {
    var emitted = false
}

/// Phase 4 D-03 (plan 04-07) — Final façade form of the predictor view model.
///
/// PVM is now a thin observable surface over `ModelRuntime` (which owns the
/// MLX container + the verbatim `container.perform` body) and the four
/// extracted modules : `SuggestionPolicyEngine`, `GenerationPlanner`,
/// `CompletionCache`. The cascade (L0 word completion + L1 history exact-
/// substring + L2 LLM stream) lives directly in `predict(...)` below.
///
/// Pre-04-07 the model dispatched between a pre-split body and the cascade
/// wiring via an env-flag (see 04-06 SUMMARY for the historical dispatcher
/// shape). Per the 04-07-EMPIRICAL-VALIDATION verdict (PASS, runtime path
/// subjectively equivalent to legacy), the flag and the legacy body have
/// been removed. `predict(...)` IS the cascade wiring.
@MainActor
@Observable
final class PredictorViewModel {
    enum LoadState: Equatable {
        case idle
        case loading(progress: Double)
        case ready
        case failed(String)
    }

    var loadState: LoadState = .idle
    var suggestion: String = ""
    /// The exact `prefix` (text before the caret) that the current `suggestion`
    /// was generated for. The render boundary MUST refuse to paint `suggestion`
    /// unless this equals the live prefix — otherwise a ghost produced for an
    /// earlier keystroke (kept alive in `suggestion` through one of the many
    /// gating paths while a fresh stream is pending) gets painted at the new
    /// caret. That is the "Bonjour" repro: a stale start-of-message ghost shown
    /// far downstream at "…autre chose pou". Empty until the first suggestion is
    /// produced; reset on `cancel()` and on the stale-clear path.
    private(set) var predictedForPrefix: String = ""
    var ttftMillis: Int?
    var tokensPerSecond: Double?
    var lastError: String?

    /// Provenance of the current `suggestion`. Drives the anti-churn rule in
    /// the LLM `onChunk` path: high-confidence sources (history, cache hit)
    /// are protected from being REPLACED by a different-direction LLM
    /// stream — the LLM may only EXTEND them. Low-confidence sources
    /// (word completion, none) can be freely replaced when the LLM
    /// produces a strictly longer output.
    ///
    /// Phase 4 D-03 : le type `SuggestionSource` est désormais défini au
    /// top-level dans `SuggestionPolicy.swift`. Les références internes
    /// continuent de résoudre via global lookup.
    private(set) var suggestionSource: SuggestionSource = .none

    /// Phase 4 D-03 (plan 04-05/06/07) : tout le runtime MLX (container,
    /// modelId, loadModel, swap, generate) vit dans `ModelRuntime`. PVM
    /// délègue son lifecycle modèle exclusivement à ce sous-système.
    @ObservationIgnored
    private let runtime: ModelRuntime

    /// Phase 4 — lifecycle (generation counter + currentTask + debounce)
    /// extrait dans `GenerationPlanner`. PVM délègue : `planner.beginGeneration()`
    /// remplace `generation &+= 1` + `currentTask?.cancel()` ; les closures
    /// onChunk capturent un `GenerationToken` (value-type Sendable) et
    /// utilisent `planner.isCurrent(token)` au lieu de `self.generation == myGeneration`.
    /// Pitfall 1 du RESEARCH §"Common Pitfalls" — Token comparé par valeur,
    /// pas de risque de capture stale d'une référence.
    private let planner = GenerationPlanner()

    /// Phase 4 D-03 (plan 04-04) : tous les caches cross-keystroke (predict
    /// memo FIFO, tokenCountCache, KVCacheHolder, lastContextFingerprint) sont
    /// consolidés dans `CompletionCache`. PVM délègue via `cache.lookup` /
    /// `cache.store` / `cache.kvCacheHolder` / `cache.decideExtendTrimInvalidate`.
    /// Le `KVCacheBypassFlag` vit désormais dans `CompletionCache.swift` —
    /// l'env var de bypass D-KV-06 y est byte-identique (single source of truth).
    internal let cache = CompletionCache()

    private var modelId: String
    /// Last language `detectLanguage` resolved *with confidence* (English name,
    /// e.g. "French"). Short or low-confidence prefixes make `detectLanguage`
    /// return nil mid-typing — exactly the autocomplete case — which would drop
    /// the language-steering header and let the 1B model drift to English. We
    /// keep the last confident detection and reuse it when the current prefix is
    /// undetectable; a *new* confident detection always wins and overwrites it.
    private var lastDetectedLanguage: String?
    /// Driven by Preferences > Général > "Longueur des suggestions".
    /// Combined with sentence-end truncation in onChunk for snappy output.
    var maxTokens: Int = 10
    /// Hard cap on whole words shown to the user, mirroring CompletionLength.maxWords.
    /// Phase 4 : sync'd into `policy.updateMaxWords(...)` via `didSet` so the
    /// SuggestionPolicyEngine's routeInstant cap matches the LLM stream cap.
    var maxWords: Int = 6 {
        didSet { policy.updateMaxWords(maxWords) }
    }
    /// Personalization knob. 0 disables the n-gram bias entirely (fast path,
    /// existing behaviour). When > 0 we route generation through a custom
    /// `TokenIterator` that chains the repetition penalty with `NgramLogitBias`.
    var personalizationStrength: Float = 0
    /// When true, completed-word typos in the prefix are corrected *only in the
    /// model input* (Volet 1). The user's displayed text and `userTail`
    /// (anti-repeat / cache key) are never altered. Default on; mirrored from
    /// `PreferencesStore.prefixCorrectionEnabled` by the AppDelegate.
    var prefixCorrectionEnabled: Bool = true
    /// Silent prefix typo corrector (pure wrapper over NSSpellChecker). Only
    /// rewrites the `llmTail` fed into the llama prompt's `beforeCursor`.
    private let prefixCorrector = PrefixCorrector()
    /// Historique chiffré on-device. Source de l'apprentissage n-gram (via
    /// `rebuildPersonalization` / `ingestAccepted`). Wiré depuis
    /// `SouffleuseAppDelegate` au démarrage. Quand nil, le n-gram bias reste
    /// inactif (cas tests / startup).
    ///
    /// Note (2026-05-26): la propriété est conservée car `ingestAccepted` et
    /// `rebuildPersonalization` continuent d'alimenter l'historique pour le
    /// n-gram. Le retrieval few-shot a été dropé (cf. drop fewshot commit) —
    /// la personnalisation passe désormais exclusivement par le logit bias.
    var history: TypingHistoryStore?
    private let ngramModel = NgramModel()
    /// System-API word completion. Runs synchronously on the main actor so
    /// the ghost can show up before the LLM has even started — matches the
    /// instant-feedback feel of Cotypist on partial words.
    private let wordCompleter = WordCompleter()

    /// Phase 4 — Ghost Relevance Gate engine. Owns currentGhost/currentSource/
    /// currentScore/shownAt + the 5 classification events. PVM delegates cascade
    /// routing (L0/L1) and LLM chunk replacement-bar to this engine ; partial-
    /// accept + typedDiverged hooks will land in 04-04+ when TypingSession
    /// is extracted (D-03).
    private let policy = SuggestionPolicyEngine(maxWords: 6)

    /// Synchronous snapshot of typing history for Instant Ghost Path Layer 1.
    /// `TypingHistoryStore` is an actor (async); the predict() hot path runs
    /// on the main actor and needs immediate access. We mirror the actor's
    /// state into this main-actor-owned array, refreshed on rebuild + on
    /// every new acceptance. Capped at 200 entries × ~80 chars context =
    /// ~16KB peak, well within budget for a linear scan in <1ms.
    private(set) var historySnapshot: [TypingHistoryEntry] = []

    /// Active GGUF model id (the real ghost engine). Mirrored from
    /// `PreferencesStore.ggufModelID` at startup ; changed via `swapGGUF(to:)`.
    private var ggufModelID: String = GGUFModelOption.defaultID

    init(ggufModelID: String = GGUFModelOption.defaultID) {
        let initialModelId = "mlx-community/gemma-3-1b-pt-4bit"
        self.modelId = initialModelId
        self.ggufModelID = ggufModelID
        self.runtime = ModelRuntime(initialModelId: initialModelId, ggufModelID: ggufModelID)
    }

    /// Swaps the active **GGUF (llama.cpp)** model — the model that actually
    /// produces the ghost. Cancels any in-flight generation, reloads the llama
    /// engine on the new GGUF (which resets KV state), then re-feeds the
    /// personalization corpus so the token-id n-gram + suffix array are rebuilt
    /// for the reloaded engine. Surfaces `loadState = .loading` during the load
    /// (the 4B model is ~2.5 GB, noticeably slower than the 1B). No-op when the
    /// id already matches. Does NOT touch the legacy MLX container.
    /// Sets the GGUF selection BEFORE the initial `loadModel()` so the engine
    /// loads the persisted model from disk on launch (no reload). Must be called
    /// before `loadModel()`. A no-op once a model is loaded — use `swapGGUF`.
    func configureInitialGGUF(_ id: String) {
        ggufModelID = id
        runtime.configureInitialGGUF(id)
    }

    func swapGGUF(to id: String) async {
        guard id != ggufModelID else { return }
        cancel(reason: .modelSwap)
        ggufModelID = id
        loadState = .loading(progress: 0)
        cache.invalidateAll()
        let ok = await runtime.swapGGUF(to: id)
        if !ok {
            let err = runtime.lastError ?? "load_failed: gguf"
            loadState = .failed(err)
            lastError = err
            return
        }
        // Re-feed the corpus : the reloaded engine has fresh (empty) n-gram /
        // suffix-array state, so rebuild it from the current history snapshot.
        let corpus = historySnapshot.map { Self.corpusString(for: $0) }
        await runtime.setCorpus(corpus)
        loadState = .ready
    }

    /// Swap the active model. Cancels in-flight generation, drops the container,
    /// and triggers a fresh load with the new ID. Called when the user picks a
    /// different model in Preferences. No-op if `id` matches the active one.
    func swapModel(to id: String) async {
        guard id != modelId else { return }
        // Phase 4 — classification grid : model swap ends any visible ghost
        // lifecycle silently (D-09 — silent category). cancel(reason:) appelle
        // policy.endLifecycle(.modelSwap) en interne.
        cancel(reason: .modelSwap)
        modelId = id
        loadState = .idle
        // ModelRuntime.swap drops its container, updates its modelId, invalidates
        // the shared CompletionCache (predictCache + KV holder + tokenCountCache),
        // and reloads. The kv_cache_invalidate count:3 event is emitted by
        // `cache.invalidateAll()` inside runtime.swap.
        await runtime.swap(to: id, completionCache: cache)
        loadState = runtime.lastError.map(LoadState.failed) ?? .ready
        if let err = runtime.lastError { lastError = err }
    }

    /// Phase 4 D-03 shim — AppDelegate (toggle off, focus → different bundle)
    /// déclare un context break en appelant directement `clearPredictCache()`.
    /// La sémantique est : drop le predictCache memo ; le KV holder et le
    /// tokenCountCache sont préservés (ils dépendent du model et du tokenizer,
    /// pas du contexte UI).
    func clearPredictCache() {
        cache.clearPredictCache()
    }

    func loadModel() async {
        guard case .idle = loadState else { return }
        loadState = .loading(progress: 0)
        // ModelRuntime.loadModel owns container + lastError. We surface its
        // outcome through the PVM LoadState observable. Progress reporting is
        // currently swallowed inside ModelRuntime (per 04-05 doc-comment) ;
        // when reintroduced it will be a closure injected here.
        await runtime.loadModel()
        if let err = runtime.lastError {
            loadState = .failed(err)
            lastError = err
        } else {
            loadState = .ready
        }
    }

    /// Predict — Final façade form (04-07).
    ///
    /// Cascade :
    /// 1. Source decay (HIGH → .llm so a fresh layer can reclaim).
    /// 2. Routing instant (L0 word completion / L1 history exact-substring)
    ///    via `policy.routeInstant`. Narrow stability gate guards against
    ///    spell-checker flip-flop.
    /// 3. Cache lookup + undo-as-ghost short-circuit.
    /// 4. Field-hint gate when `userTail` is empty without AX hints.
    /// 5. Build slot bodies (system prompt, customInstr, ctxPrefix,
    ///    fieldContext, afterCursor) and assemble a `PredictRequest`.
    /// 6. Detached Task : await previous generation, precompute n-gram
    ///    snapshot + few-shot block off the main actor, call
    ///    `runtime.generate(...)`, mirror filtered chunks into observables
    ///    through the @MainActor onChunk closure.
    func predict(
        prefix: String,
        contextPrefix: String = "",
        customInstructions: String = "",
        axSnapshot: AXSnapshot? = nil
    ) {
        let userTail = String(prefix.suffix(2048))
        // The exact prefix this invocation produces a suggestion for. Stamped
        // onto `predictedForPrefix` at every site that assigns `suggestion`, so
        // the render boundary can prove freshness. Matches the AppDelegate's
        // `prefix` (text before caret) verbatim — same value flows in here.
        let forPrefix = prefix
        // Context-aware invalidation: predictCache is keyed on userTail
        // only, so a hit returns the same suggestion regardless of which
        // app/field the user is currently in. fieldContext + afterCursor
        // slots depend on axSnapshot — typing the same userTail in two
        // different apps now produces two different prompts but the cache
        // would still return the first one. We invalidate whenever the
        // slow-changing AX fingerprint (bundle/role/subrole/placeholder/
        // help) shifts. textAfterCaret and windowTitle are intentionally
        // NOT in the fingerprint: textAfterCaret moves with the caret
        // (every keystroke would invalidate), and windowTitle changes too
        // often to be useful.
        let contextFingerprint: String = [
            axSnapshot?.bundleID ?? "",
            axSnapshot?.role ?? "",
            axSnapshot?.subrole ?? "",
            axSnapshot?.placeholder ?? "",
            axSnapshot?.help ?? "",
        ].joined(separator: "|")
        cache.updateContextFingerprint(contextFingerprint)
        PredictDebug.log("predict_called", "userTail=\(userTail.debugDescription)")

        // Source decay : a HIGH-confidence source set by a PREVIOUS predict
        // no longer reflects reality. Demote stale HIGH sources to .llm so
        // this predict can either re-confirm them via a fresh layer hit
        // (snapping back to HIGH) or accept legitimate updates from Layer 0
        // / LLM stream without being locked out.
        policy.beginPredict()
        suggestionSource = policy.currentSource == .none ? suggestionSource : policy.currentSource
        switch suggestionSource {
        case .history, .cache, .undoCache:
            suggestionSource = .llm
        case .wordComplete, .llm, .none:
            break
        }
        let maxWords = self.maxWords

        // Instant Ghost Path Layers 0 + 1 — delegated to SuggestionPolicy.
        // routeInstant emits ghost_history_match / ghost_word_complete in
        // its internals ; applies D-08 matrix (mid-word = L0 only ;
        // after-space = L1 first behind afterSpaceL1Bar 0.4 ; else nil).
        let routeResult = policy.routeInstant(
            userTail: userTail,
            historySnapshot: historySnapshot,
            wordCompleter: wordCompleter
        )
        // `singleLine` here is the single chokepoint for the instant path:
        // corpus / `.history` entries captured from prose can carry a trailing
        // "\n" (e.g. "achète du Bitcoin.\n"). Sanitising at the source means
        // every downstream use — the stability comparison below, the displayed
        // `suggestion`, and the drop-guard fallback in the LLM stream — sees a
        // clean single line, so the ghost never floats above the caret and a
        // Tab-accept never injects a line break.
        let instantGhost: String = ModelRuntime.OutputFilter.singleLine(routeResult?.text ?? "")
        let instantSource: SuggestionSource = routeResult?.source ?? .none
        if !instantGhost.isEmpty, let route = routeResult {
            // Narrow stability gate : only block when this predict and the
            // previous one BOTH produced a Layer 0 word completion AND the
            // new one doesn't extend the old (the spell-checker-changes-
            // its-mind case that produces visible flip-flop). Other
            // transitions replace freely.
            let bothLayer0 = suggestionSource == .wordComplete && instantSource == .wordComplete
            let extendsCurrent = instantGhost.count > suggestion.count
                && instantGhost.lowercased().hasPrefix(suggestion.lowercased())
            if !bothLayer0 || extendsCurrent {
                policy.applyGhost(route.text, source: route.source, score: route.score)
                suggestion = ModelRuntime.OutputFilter.normalizeFrenchTypography(instantGhost)
                suggestionSource = instantSource
            } else {
                Log.info(.predictor, "ghost_keep_stable", count: suggestion.count)
                PredictDebug.log("ghost_keep_stable", "current=\(suggestion.debugDescription) candidate=\(instantGhost.debugDescription)")
            }
            // Either we applied the instant ghost, or we kept the existing one
            // because the fresh L0 candidate didn't extend it — in both cases a
            // valid ghost for THIS prefix is on screen, so it is fresh.
            predictedForPrefix = forPrefix
        }

        // LLM gate : need at least 3 chars of trimmed userTail AND a
        // loaded runtime container.
        guard userTail.trimmingCharacters(in: .whitespaces).count >= 3,
              runtime.canGenerate else {
            return
        }

        // Cache hit : greedy decoding makes the same userTail produce the
        // same ghost. Restore the stabilised LLM suggestion instantly and
        // skip the 200ms-1s regen cycle.
        //
        // Tightening pass 2026-05-26 (post 04-07 empirical validation): cache
        // hits must now pass a Relevance Gate score check before being shown.
        // Before this, any non-empty cache entry was displayed unconditionally
        // — that's how stale LLM fragments from a prior context kept polluting
        // the ghost ("Je reviens " → "Je suis…" from earlier session). Cache
        // is high-prior (0.70) so a well-formed continuation easily clears
        // `cacheFloor=0.55` ; the gate only blocks malformed or off-shape
        // cached results.
        if let cached = cache.lookup(userTail: userTail) {
            if !cached.isEmpty {
                let capped = ModelRuntime.OutputFilter.capToWords(cached, max: maxWords)
                let score = SuggestionPolicy.score(source: .cache, ghost: capped, userTail: userTail)
                if score.value >= SuggestionPolicy.Tuning.cacheFloor {
                    suggestion = ModelRuntime.OutputFilter.normalizeFrenchTypography(
                        ModelRuntime.OutputFilter.singleLine(capped))
                    predictedForPrefix = forPrefix
                    suggestionSource = .cache
                    planner.cancel()
                    Log.info(.predictor, "cache_hit", count: Int(score.value * 100))
                    PredictDebug.log("cache_hit", "cached=\(cached.debugDescription) score=\(score.value)")
                    return
                } else {
                    // Cache hit but score under floor — log and fall through
                    // to L1/L2 (do not cancel planner, do not overwrite ghost).
                    Log.info(.predictor, "cache_gate_block", count: Int(score.value * 100))
                    PredictDebug.log("cache_gate_block", "cached=\(cached.debugDescription) score=\(score.value)")
                }
            } else {
                // Empty cache entry — known-sterile prefix. Skip but do not
                // cancel planner (let the cascade continue).
                Log.info(.predictor, "cache_hit", count: 0)
                PredictDebug.log("cache_hit", "cached=empty")
                return
            }
        }

        // Undo-as-ghost : when the user backspaces over chars they had
        // already typed, propose to restore the deleted suffix as the
        // ghost. Find the longest cache key starting with userTail ; the
        // delta is the deleted suffix, delta + cachedSuggestion is the
        // proposed ghost. The user can Tab to instantly un-do their
        // deletion.
        //
        // Tightening 2026-05-26: same Gate treatment as cache hits, with a
        // slightly lower bar (`undoCacheFloor=0.45`) since the semantic
        // signal is strong (the suffix was literally typed before backspace).
        if let (key, cached) = cache.longestExtendingKey(userTail: userTail) {
            let delta = String(key.dropFirst(userTail.count))
            if !delta.isEmpty {
                let capped = ModelRuntime.OutputFilter.capToWords(delta + cached, max: maxWords)
                let score = SuggestionPolicy.score(source: .undoCache, ghost: capped, userTail: userTail)
                if score.value >= SuggestionPolicy.Tuning.undoCacheFloor {
                    planner.cancel()
                    suggestion = ModelRuntime.OutputFilter.singleLine(capped)
                    predictedForPrefix = forPrefix
                    suggestionSource = .undoCache
                    Log.info(.predictor, "cache_undo_hit", count: Int(score.value * 100))
                    PredictDebug.log("cache_undo_hit", "key=\(key.debugDescription) delta=\(delta.debugDescription) cached=\(cached.debugDescription) shown=\(suggestion.debugDescription) score=\(score.value)")
                    return
                } else {
                    Log.info(.predictor, "cache_undo_gate_block", count: Int(score.value * 100))
                    PredictDebug.log("cache_undo_gate_block", "key=\(key.debugDescription) score=\(score.value)")
                }
            }
        }

        // Field-hint gate : only block when userTail is truly empty AND
        // we have no AX field metadata to fall back on. With a placeholder/
        // role hint, the model has enough to propose something specific
        // (a subject line, a search query, a code stub) rather than fortune
        // cookies.
        let hasFieldHint = (axSnapshot?.placeholder?.isEmpty == false)
            || (axSnapshot?.help?.isEmpty == false)
            || (axSnapshot?.role != nil)
        if userTail.isEmpty && !hasFieldHint {
            PredictDebug.log("gate_empty_no_context", "")
            return
        }

        // Build the system prompt + slot bodies. Language steering : detect
        // the prefix's language and prepend an explicit "you must reply in
        // {language}" header. Counters the English-drift bias on
        // multilingual models.
        // Sticky language: a confident detection updates the remembered value;
        // an undetectable (short / low-confidence) prefix falls back to it so
        // the steering header survives mid-typing instead of vanishing.
        if let confident = ModelRuntime.detectLanguage(in: userTail) {
            lastDetectedLanguage = confident
        }
        let detectedLanguage = lastDetectedLanguage
        // ── Volet 1 : silent prefix correction (model input only) ──────────
        // Correct completed-word typos in the MODEL's view of the prefix so the
        // ghost continues from clean text. `userTail` (display / anti-repeat /
        // cache key) is intentionally NOT touched — only `correctedTail` flows
        // into the llama prompt's `beforeCursor`. Captured here on @MainActor
        // (PrefixCorrector is main-actor state); the detached Task receives the
        // already-corrected value as a plain Sendable string.
        let correctedTail: String = prefixCorrectionEnabled
            ? prefixCorrector.correctedPrefix(userTail, detectedLanguage: detectedLanguage)
            : userTail
        let baseSystemPrompt = ModelRuntime.buildSystemPrompt(detectedLanguage: detectedLanguage)
        var systemParts: [String] = [baseSystemPrompt]
        if !customInstructions.isEmpty {
            systemParts.append("Style and persona:\n\(customInstructions.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if !contextPrefix.isEmpty {
            systemParts.append("Context:\n\(contextPrefix.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let systemMessage = systemParts.joined(separator: "\n\n")

        var parts: [String] = []
        if !customInstructions.isEmpty {
            parts.append(customInstructions.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !contextPrefix.isEmpty {
            parts.append(contextPrefix.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let basePreamble = parts.isEmpty ? "" : parts.joined(separator: "\n\n") + "\n\n"

        // Dump the assembled prompt skeleton the LLM will actually receive.
        // `|||SYS|||` / `|||PREAMBLE|||` / `|||TAIL|||` separators keep the
        // payload single-line and grep-friendly while preserving the three
        // slots distinctly — lets us cross-reference what's in /tmp/souffleuse-ocr.log
        // against what actually reaches the model.
        PredictDebug.log(
            "final_prompt",
            "sys=\(systemMessage.debugDescription) |||PREAMBLE||| \(basePreamble.debugDescription) |||TAIL||| \(correctedTail.debugDescription)"
        )

        let maxTokens = self.maxTokens
        let isInstructModel = modelId.range(of: "-it", options: .caseInsensitive) != nil
            || modelId.range(of: "instruct", options: .caseInsensitive) != nil

        // Phase 4 — lifecycle owned by GenerationPlanner. The variant
        // `beginGenerationDetachingPrevious()` cancels the previous Task,
        // bumps the counter, AND returns the previousTask so the new Task
        // below can `await previousTask?.value` (preserves cross-stream
        // finalisation ordering).
        let (myGeneration, previousTask) = planner.beginGenerationDetachingPrevious()

        // Snapshot personalisation inputs to satisfy the Sendable closure
        // boundary. Strength + history + ngramModel are read here so the
        // detached Task can `await` them without touching @MainActor state
        // inside the runtime.generate closure.
        let personalizationStrength = self.personalizationStrength
        let ngramModel = self.ngramModel
        // Hoisted on the @MainActor side (self is strong here) so the detached
        // generation Task can use it without touching @MainActor state. Filtered
        // to `.prose` now (never accept-fragments) — this is the few-shot
        // injection pool (B-prompt).
        let proseExamplesPool = self.historySnapshot.filter { $0.source == .prose }

        let baseSystem = baseSystemPrompt
        let customInstr = customInstructions
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ctxPrefix = contextPrefix
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // ── Phase 2: fieldContext slot body (D-15c French annotation) ──
        let fieldContextSlot: String = {
            guard let snap = axSnapshot else { return "" }
            var lines: [String] = []
            if let label = PromptBuilder.roleLabelFR(role: snap.role, subrole: snap.subrole) {
                lines.append("Champ : \(label).")
            }
            if let placeholder = snap.placeholder?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !placeholder.isEmpty {
                lines.append("Placeholder : « \(placeholder) ».")
            }
            if let help = snap.help?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !help.isEmpty {
                lines.append("Aide : « \(help) ».")
            }
            return lines.joined(separator: "\n")
        }()
        // ── Phase 2: afterCursor slot body (D-14 prose-FR delimiter) ──
        let afterCursorSlot: String = {
            guard let snap = axSnapshot,
                  let after = snap.textAfterCaret?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !after.isEmpty else { return "" }
            return "Suite du texte (à ne pas répéter) : « \(after) »."
        }()

        let runtime = self.runtime
        let completionCache = self.cache

        // If a previous LLM Task was running, its cancellation may have left
        // the KV cache in a state inconsistent with what the holder records
        // (Swift offset advanced but MLX GPU update interrupted mid-step).
        // Force-invalidate before the next generation reads the cache to
        // avoid a MLX assertion in `KVCacheSimple.update` (race observed
        // 2026-05-26 after partial-accept Tab: two back-to-back kv_cache_extend
        // events triggered a slice update assert in MLX).
        //
        // Cost: re-prefill on the next predict only if a cancellation
        // occurred. Normal predict-after-typing keeps cache extend.
        let hadInFlightCancellation = (previousTask != nil)
        if hadInFlightCancellation {
            cache.invalidate(reason: .explicit)
            Log.info(.predictor, "kv_cache_invalidate_on_cancel")
        }

        // Stale-ghost guard : track whether THIS generation ever produced a
        // ghost the user should see (a valid non-empty LLM chunk, OR an empty
        // chunk that legitimately fell back to a valid instant ghost). When a
        // generation drops EVERY token (all guards in `generateLlama` fire and
        // `acc.lastEmitted` stays "" so `onChunk("")` is never called), this
        // box stays false. The completion block below then clears any leftover
        // ghost from a PREVIOUS keystroke — UNLESS the current prefix has a
        // valid instant ghost (L0 word-completion or strong corpus fast-path),
        // which must be preserved (anti-churn). `emittedGhost` is mutated only
        // on @MainActor (the onChunk closure and the completion block).
        let emitTracker = GhostEmissionTracker()

        let task = Task { [weak self] in
            _ = await previousTask?.value
            if Task.isCancelled { return }

            // Personalization : n-gram logit bias only (post 04-07 + tightening).
            //
            // Drop few-shot retrieval — the "PT base model + raw-concat
            // examples" combo polluted ghost output via in-context learning
            // (e.g. "Coucou, ceci est un test " → "Bonjour, c" because a
            // history entry started with "Bonjour, c…"). The LLM read
            // concatenated examples as document context, not as labelled
            // demonstrations, and continued the apparent "multi-greeting"
            // pattern.
            //
            // The right architectural place for user personalization is the
            // sampler — `NgramLogitBias` + `ChainLogitProcessor` apply user-
            // typed token frequencies as per-token bias during generation,
            // without ever injecting demonstration text into the prompt.
            // This eliminates cross-pollination by construction.
            //
            // LLM input window : feed the last `llmContextWindowChars` of the
            // CORRECTED prefix to the model as `beforeCursor`. The full 2048-char
            // userTail still drives memoisation / anti-repeat below; only the
            // bytes the LLM SEES are corrected and windowed. Sized by the
            // 2026-05-29 window A/B (see Tuning.llmContextWindowChars): 512 was
            // the worst window (a mid-sentence cut severs the discourse thread →
            // generic filler); 1024 recovers far-antecedent coherence with no
            // within-window regression, ~+60ms warm prefill paid once per cold
            // field. The old "more context dilutes a 1B model" rationale was
            // measured and refuted.
            let llmTail = String(correctedTail.suffix(SuggestionPolicy.Tuning.llmContextWindowChars))
            let basePromptText = basePreamble + llmTail
            let snapshot: NgramSnapshot? = personalizationStrength > 0
                ? await ngramModel.snapshot()
                : nil

            // Few-shot prose injection (B-prompt, 2026-05-30). Retrieve the user's
            // own past PROSE (never accept-fragments) most relevant to the current
            // tail, topped up with recent prose so injection fires whenever the
            // corpus holds prose. Deliberately NOT hard-filtered by bundleID: the
            // corpus-import tags seeded Intercom prose `com.intercom.conversations`
            // while the live browser is `com.brave.Browser`, so an exact-bundle
            // filter would silently inject NOTHING despite a full corpus. The
            // injected count is logged so that "full corpus / empty prompt" failure
            // mode is visible. Synchronous in-memory scan over historySnapshot
            // (≤200 entries, <5ms) — no TTFT impact.
            var examplesBlock = ""
            if personalizationStrength > 0 && SuggestionPolicy.Tuning.examplesInjectionEnabled {
                let prose = proseExamplesPool
                var examples = SimilarHistoryRetrieval.rank(
                    entries: prose, userTail: userTail, limit: SimilarHistoryRetrieval.defaultK
                )
                if examples.count < SimilarHistoryRetrieval.defaultK {
                    for e in prose where !examples.contains(e) {
                        examples.append(e)
                        if examples.count >= SimilarHistoryRetrieval.defaultK { break }
                    }
                }
                examplesBlock = SimilarHistoryRetrieval.buildExamplesBlock(from: examples)
                if !examples.isEmpty {
                    Log.info(.predictor, "ghost_examples_injected", count: examples.count)
                }
            }

            if Task.isCancelled { return }

            let request = PredictRequest(
                prefix: prefix,
                contextPrefix: contextPrefix,
                customInstructions: customInstructions,
                axSnapshotPlaceholder: axSnapshot?.placeholder,
                axSnapshotHelp: axSnapshot?.help,
                axSnapshotRole: axSnapshot?.role,
                axSnapshotSubrole: axSnapshot?.subrole,
                axTextAfterCaret: axSnapshot?.textAfterCaret,
                personalizationStrength: Double(personalizationStrength),
                maxTokens: maxTokens,
                maxWords: maxWords,
                detectedLanguage: detectedLanguage,
                token: myGeneration,
                userTail: userTail,
                llmTail: llmTail,
                isInstructModel: isInstructModel,
                systemMessage: systemMessage,
                baseSystem: baseSystem,
                customInstr: customInstr,
                ctxPrefix: ctxPrefix,
                fieldContextSlot: fieldContextSlot,
                afterCursorSlot: afterCursorSlot,
                basePreamble: basePreamble,
                examplesBlock: examplesBlock,
                basePromptText: basePromptText,
                ngramSnapshot: snapshot
            )

            // Chunk callback : Relevance Gate apply + observable update.
            // Empty chunks are the anti-repeat drop signal — fall back to
            // whichever instant-path ghost was set (history hit beats word
            // completion, both beat empty).
            let metrics = await runtime.generate(request: request, cache: completionCache) { @MainActor chunk in
                guard let self else { return }
                guard self.planner.isCurrent(myGeneration) else { return }
                if chunk.isEmpty {
                    // A drop guard in `generateLlama` reset its previously-
                    // emitted ghost. Fall back to whichever instant-path ghost
                    // was computed for the CURRENT prefix (history beats word-
                    // completion, both beat empty). This IS a deliberate ghost
                    // state for the current prefix — mark emitted so the
                    // completion block doesn't treat it as a no-output stale case.
                    emitTracker.emitted = true
                    Log.info(.predictor, "ghost_dropped_repeat")
                    PredictDebug.log("ghost_dropped_repeat", "fallback_to_instant=\(instantGhost.debugDescription)")
                    self.suggestion = instantGhost
                    self.predictedForPrefix = forPrefix
                    self.suggestionSource = instantSource
                    return
                }
                // Phase 4 D-07 : Relevance Gate replaces the old anti-churn
                // rule. `policy.onLLMChunk` applies :
                //   1. Mid-word ALLOWED (D-08 unblocked) — coherence already
                //      enforced upstream in generateLlama's coherence guard
                //   2. passesGate floor (0.25) — ghost_gate_block
                //   3. Replacement bar (1.15) OR L2-upgrades-L1 delta (0.15)
                //      — ghost_keep_under_bar
                //   4. Parasite detection si remplacement < parasiteWindow
                //      — ghost_classified_parasite
                guard let update = self.policy.onLLMChunk(chunk, userTail: userTail) else {
                    PredictDebug.log("chunk_gated", "oneLine=\(chunk.debugDescription) current=\(self.suggestion.debugDescription) source=\(self.suggestionSource)")
                    return
                }
                // Stub guard : a fresh NEXT-WORD ghost (caret at a word
                // boundary — userTail ends in space/punct/empty) that is just a
                // single character ("m") is noise. The user can't read intent
                // from one letter, and it's almost always a streaming stub whose
                // continuation got gated out (base-model junk like repeated
                // "fraises"/`<strong>` tags, or an over-eager corpus bias that
                // flips only the first token). Skip it and wait for ≥2 chars —
                // nothing beats a lone "m". Mid-word completions (caret inside a
                // word, finishing it: "Bonjou" → "r") are exempt: there the last
                // userTail char is a letter, so this never fires.
                if Self.isNextWordStub(userTail: userTail, ghost: update.text)
                    || Self.isMidWordStub(userTail: userTail, ghost: update.text) {
                    PredictDebug.log("chunk_stub_skip", "text=\(update.text.debugDescription) userTail=\(userTail.debugDescription)")
                    return
                }
                let fromHigh = (self.suggestionSource == .history
                             || self.suggestionSource == .cache
                             || self.suggestionSource == .undoCache)
                Log.info(.predictor,
                         fromHigh ? "ghost_swap_to_llm_from_high" : "ghost_apply_llm",
                         count: update.text.count)
                PredictDebug.log("chunk_applied", "oneLine=\(update.text.debugDescription) prev_source=\(self.suggestionSource)")
                emitTracker.emitted = true
                self.policy.applyGhost(update.text, source: .llm, score: update.score)
                self.suggestion = ModelRuntime.OutputFilter.normalizeFrenchTypography(update.text)
                self.predictedForPrefix = forPrefix
                self.suggestionSource = .llm
            }

            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                guard self.planner.isCurrent(myGeneration) else { return }

                // Stale-ghost clear : this generation finished without ever
                // emitting a ghost for the current prefix (every token dropped
                // by the coherence / degenerate / instruction-echo / repeat
                // guards, and the all-dropped case never reaches the
                // `onChunk("")` reset inside generateLlama). Whatever is still
                // displayed therefore belongs to an OLD keystroke's prefix — it
                // is stale (the "faique" repro : prefix "…fai", leftover ghost
                // "que"). Clear it so the user sees nothing rather than a
                // mismatched ghost.
                //
                // Anti-churn : we ONLY clear when the current prefix produced no
                // valid instant ghost (`instantGhost.isEmpty`). A fresh L0
                // word-completion or a strong corpus `.history` fast-path for
                // the CURRENT prefix yields a non-empty `instantGhost`, is still
                // displayed, and is protected here — an empty LLM stream never
                // wipes a valid current-prefix ghost. Cache / undo-cache hits
                // return before generation and never reach this path.
                if Self.shouldClearStaleGhost(
                    emittedGhost: emitTracker.emitted,
                    instantGhost: instantGhost,
                    displayedSuggestion: self.suggestion
                ) {
                    Log.info(.predictor, "ghost_cleared_stale", count: self.suggestion.count)
                    PredictDebug.log("ghost_cleared_stale", "userTail=\(userTail.debugDescription) cleared=\(self.suggestion.debugDescription)")
                    self.suggestion = ""
                    self.predictedForPrefix = ""
                    self.suggestionSource = .none
                    self.policy.reset()
                }

                if let m = metrics {
                    self.ttftMillis = m.ttftMillis
                    self.tokensPerSecond = m.tokensPerSecond
                    // Coarse proxy : char/4 ≈ SentencePiece BPE for Latin
                    // script. The absolute value is only useful for
                    // debugging ; the gate metric is the RATIO of this
                    // event to `predict_called`. KV-07.
                    let producedTokens = self.suggestion.isEmpty ? 0 : max(1, self.suggestion.count / 4)
                    if let ttft = m.ttftMillis {
                        Log.info(.predictor, "predict_ttft", count: ttft)
                    }
                    Log.info(.predictor, "llm_done_stored", count: producedTokens)
                    PredictDebug.log("llm_done_stored", "userTail=\(userTail.debugDescription) final=\(self.suggestion.debugDescription) ttft=\(m.ttftMillis ?? -1)ms")
                    self.cache.store(prefix: userTail, suggestion: self.suggestion)
                }
            }
        }
        planner.setCurrentTask(task)
    }

    /// Rebuilds the in-memory n-gram model from a list of accepted entries.
    /// Called at startup (with everything from `TypingHistoryStore`) and after
    /// "Tout supprimer". Tokenises via the active model's tokenizer.
    func rebuildPersonalization(from entries: [TypingHistoryEntry]) async {
        // Layer 1 snapshot refresh — done first so the instant path becomes
        // operational even if the n-gram tokenisation below takes its time.
        // TypingHistoryStore.entries is oldest-first; we reverse so the
        // linear scan in SuggestionPolicy's exact-substring helper hits
        // freshest first (matches ingestAccepted's insert-at-0 ordering).
        self.historySnapshot = Array(entries.reversed())

        // Phase 1 personalization : rebuild the llama-token-id corpus n-gram
        // inside the engine. This is the path that biases the llama.cpp
        // decoder (the MLX-tokenizer n-gram below is now decoupled from the
        // active llama generation). Strings are the accepted text, prefixed by
        // their context when present — same join shape as the MLX n-gram.
        let corpus = entries.map { Self.corpusString(for: $0) }
        await runtime.setCorpus(corpus)

        guard let container = runtime.container else { return }
        let tokenizerTag = modelId
        await container.perform { context in
            await ngramModel.clear()
            await ngramModel.setTokenizerTag(tokenizerTag)
            for entry in entries {
                let joined: String
                if entry.contextBefore.isEmpty {
                    joined = entry.accepted
                } else {
                    joined = entry.contextBefore + " " + entry.accepted
                }
                let tokens = context.tokenizer.encode(text: joined)
                await ngramModel.ingest(tokens: tokens)
            }
        }
    }

    /// Builds the corpus training string for one accepted entry — the accepted
    /// text, prefixed by its preceding context when present. Shared by both the
    /// full rebuild and the incremental accept path so the llama-token-id
    /// n-gram sees the same shape as the MLX-tokenizer n-gram.
    static func corpusString(for entry: TypingHistoryEntry) -> String {
        entry.contextBefore.isEmpty
            ? entry.accepted
            : entry.contextBefore + " " + entry.accepted
    }

    /// Streams a single newly-accepted entry into the n-gram model.
    func ingestAccepted(_ entry: TypingHistoryEntry) async {
        // Layer 1 snapshot append — keep most-recent-first ordering so the
        // linear scan in SuggestionPolicy's exact-substring helper hits
        // fresh entries first. Cap mirrors TypingHistoryStore.maxEntries (200).
        self.historySnapshot.insert(entry, at: 0)
        if self.historySnapshot.count > 200 {
            self.historySnapshot.removeLast(self.historySnapshot.count - 200)
        }

        // Refresh the llama corpus n-gram so the just-accepted continuation is
        // immediately available to bias the decoder. The corpus is small, so a
        // full rebuild from the (capped) snapshot is cheap and avoids tracking
        // incremental n-gram deltas inside the engine.
        let corpus = self.historySnapshot.map { Self.corpusString(for: $0) }
        await runtime.setCorpus(corpus)

        guard let container = runtime.container else { return }
        await container.perform { context in
            let joined: String
            if entry.contextBefore.isEmpty {
                joined = entry.accepted
            } else {
                joined = entry.contextBefore + " " + entry.accepted
            }
            let tokens = context.tokenizer.encode(text: joined)
            await ngramModel.ingest(tokens: tokens)
        }
    }

    /// Pure decision for the stale-ghost clear (extracted for unit testing).
    ///
    /// Returns `true` when the just-finished generation left the displayed
    /// ghost in a stale state that must be cleared :
    ///   - `emittedGhost == false` : this generation never set a ghost for the
    ///     current prefix (every token dropped by the coherence / degenerate /
    ///     instruction-echo / repeat guards, and the all-dropped case never
    ///     fired the `onChunk("")` reset inside `generateLlama`).
    ///   - `instantGhost.isEmpty` : the current prefix's instant cascade (L0
    ///     word-completion / strong corpus fast-path) produced nothing either,
    ///     so no valid current-prefix ghost is being shown.
    ///   - `displayedSuggestion` non-empty : there IS a leftover ghost on screen.
    ///
    /// When all three hold, the on-screen ghost belongs to an OLD/diverged
    /// prefix (the "faique" repro) → clear. Conversely, a non-empty
    /// `instantGhost` means a valid current-prefix L0/corpus ghost is displayed
    /// and MUST be preserved (anti-churn) — an empty LLM stream never wipes it.
    static func shouldClearStaleGhost(
        emittedGhost: Bool,
        instantGhost: String,
        displayedSuggestion: String
    ) -> Bool {
        !emittedGhost && instantGhost.isEmpty && !displayedSuggestion.isEmpty
    }

    /// A fresh NEXT-WORD ghost reduced to a single character ("m" after "envie
    /// de ") is noise — one letter conveys no intent and is almost always a
    /// streaming stub whose continuation got gated out (base-model junk, or a
    /// corpus bias that flips only the first token). Skip it and wait for ≥2
    /// chars; nothing beats a lone letter.
    ///
    /// Fires ONLY when the caret sits at a word boundary — `userTail` is empty
    /// or ends in a non-alphanumeric char (space/punctuation). A MID-WORD
    /// completion that finishes the current word ("Bonjou" → "r") ends in a
    /// letter, so this never suppresses it. The ghost's leading space (next-word
    /// continuation marker) is ignored when measuring length.
    static func isNextWordStub(userTail: String, ghost: String) -> Bool {
        // The ghost begins a NEW word when EITHER the caret sits at a word
        // boundary (userTail empty / ends in space or punctuation) OR the ghost
        // itself starts with a space (a next-word continuation after a complete
        // word: "envie" → " manger"). A mid-word completion ("Bonjou" → "r")
        // satisfies neither and is exempt.
        let caretAtWordBoundary = userTail.last.map {
            !($0.isLetter || $0.isNumber)
        } ?? true
        let ghostStartsNewWord = caretAtWordBoundary || ghost.first == " "
        guard ghostStartsNewWord else { return false }
        return ghost.drop(while: { $0 == " " }).count < 2
    }

    /// A MID-WORD ghost reduced to a single character ("opé" → "r", "dp" → "n")
    /// is noise: it's the LLM's first streamed token shown before the rest
    /// arrives, or a confused short output on a word the base model doesn't
    /// recognise (typos, abbreviations). One letter spliced mid-word is
    /// unreadable as intent and flickers. Fires when the caret sits INSIDE a word
    /// (`userTail` ends in a letter/number) AND the ghost is a single,
    /// non-space-led char — i.e. it continues the current word but says almost
    /// nothing yet.
    ///
    /// Complement of `isNextWordStub` (which covers the word-boundary case). The
    /// accepted cost: a genuine 1-letter completion ("Bonjou" → "r") is withheld
    /// until the stream produces ≥2 chars — a lone mid-word letter is always
    /// visual noise, never a useful ghost, so the trade is worth it.
    static func isMidWordStub(userTail: String, ghost: String) -> Bool {
        let caretMidWord = userTail.last.map { $0.isLetter || $0.isNumber } ?? false
        guard caretMidWord else { return false }
        // Next-word ghosts (leading space) are isNextWordStub's job.
        guard ghost.first != " " else { return false }
        return ghost.count < 2
    }

    /// Phase 4 — cancel avec discriminator pour la classification grid.
    /// `cancel(reason:)` permet aux call-sites externes (AppDelegate handleKey
    /// Esc → `.dismissedByEsc`) de différencier les raisons de fin de vie.
    /// Le default `.focusChange` est silencieux (D-09) — utilisé pour les
    /// cancellations internes (live-consume, Tab accept, typo, swap).
    func cancel(reason: LifecycleEndReason) {
        policy.endLifecycle(reason: reason)
        // Phase 4 — lifecycle owned by GenerationPlanner. `planner.cancel()`
        // cancelle la Task in-flight + bump le counter (invalide les onChunk
        // updates par closure isCurrent(token) check).
        planner.cancel()
        suggestion = ""
        predictedForPrefix = ""
        suggestionSource = .none
        policy.reset()
        // IMPORTANT: cache is preserved. `cancel()` is called from many paths
        // that are NOT context breaks — live-consume promotion, Tab full/
        // partial accept, typo flag, hide-on-typo. Clearing the cache there
        // would defeat undo-as-ghost. True context breaks (model swap, Esc
        // dismissal, app disabled, focus → different bundle) must call
        // `clearPredictCache()` explicitly at the call site.
    }

    /// Backward-compat shim — defaults to `.focusChange` (silent classification
    /// category D-09). Call-sites internes (live-consume, partial accept) gardent
    /// la signature originale. Les call-sites externes qui veulent discriminer
    /// (Esc dismiss) doivent appeler `cancel(reason:)` directement.
    func cancel() {
        cancel(reason: .focusChange)
    }
}
