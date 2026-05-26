import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import NaturalLanguage
import SouffleuseLog
import SouffleusePersonalization
import SouffleusePrompt

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

/// Predict request — value-type capture of all inputs flowing from PVM into
/// the LLM pipeline. Sera consommé par `ModelRuntime.generate(...)` en
/// 04-06. **Non utilisé encore en 04-05** : déclaré pour figer le shape
/// avant la migration container.perform.
///
/// Champs (alignés sur `PredictorViewModel.predict(prefix:contextPrefix:customInstructions:axSnapshot:)`
/// plus les internes calculés au début de cette méthode) :
/// - `prefix` : texte utilisateur brut (avant suffix-2048 trim).
/// - `contextPrefix` : prose contextuelle injectée avant `prefix` dans
///   le user-message.
/// - `customInstructions` : instructions user-defined.
/// - `axSnapshotPlaceholder/help/role/subrole/textAfterCaret` : AX context
///   slots utilisés par PromptBuilder.
/// - `personalizationStrength` : 0..1 — pondère le n-gram logit bias.
/// - `maxTokens` / `maxWords` : caps sur la génération.
/// - `detectedLanguage` : output de `ModelRuntime.detectLanguage(in:)`,
///   string anglais ("French", "English", …). Aligné sur le retour réel
///   de `PVM.detectLanguage`.
/// - `token` : `GenerationToken` (cf. `GenerationPlanner.swift`) — permet
///   au callback `onChunk` de drop les chunks d'une génération obsolète.
struct PredictRequest: Sendable {
    let prefix: String
    let contextPrefix: String
    let customInstructions: String
    let axSnapshotPlaceholder: String?
    let axSnapshotHelp: String?
    let axSnapshotRole: String?
    let axSnapshotSubrole: String?
    let axTextAfterCaret: String?
    let personalizationStrength: Double
    let maxTokens: Int
    let maxWords: Int
    let detectedLanguage: String?
    let token: GenerationToken

    // ── 04-06 additions : precomputed inputs that PVM legacy assembles
    // BEFORE entering `container.perform`. We carry them across the
    // Sendable boundary as pure values so ModelRuntime.generate (which
    // runs inside the off-actor closure) never has to touch `self` /
    // any actor. The caller (PVM.predict_new) precomputes these from
    // its actor-isolated state (ngramModel, history, modelId, …).

    /// Trimmed user text actually fed to the LLM (suffix 2048 cap).
    /// Identical to the legacy `userTail`.
    let userTail: String
    /// Cap-512 suffix of `userTail` — the textual content actually
    /// included in the user-message of the chat template.
    let llmTail: String
    /// True if the active model id contains `-it` or `instruct`.
    let isInstructModel: Bool
    /// Full legacy system message (base + customInstructions + contextPrefix).
    let systemMessage: String
    /// Base framing only, used by the new PromptBuilder path.
    let baseSystem: String
    /// Trimmed custom instructions slot body.
    let customInstr: String
    /// Trimmed context prefix slot body.
    let ctxPrefix: String
    /// Field context slot body assembled from AX snapshot (FR prose).
    let fieldContextSlot: String
    /// After-cursor slot body assembled from AX snapshot (FR prose).
    let afterCursorSlot: String
    /// Soft preamble fed into base/PT prompt (customInstr + ctxPrefix
    /// joined by blank lines, with trailing "\n\n" if non-empty).
    let basePreamble: String
    /// Few-shot examples block (similarity-ranked, prebuilt by caller
    /// via `await TypingHistoryStore.similarEntries(...)`).
    let examplesBlock: String
    /// Full assembled prompt text for the base/PT path
    /// (`basePreamble + examplesBlock + llmTail`).
    let basePromptText: String
    /// N-gram snapshot — `nil` when personalization is disabled or
    /// caller has no model. Precomputed off-actor by caller.
    let ngramSnapshot: NgramSnapshot?
}

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

    init(initialModelId: String) {
        self.modelId = initialModelId
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
        do {
            MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)

            let configuration = ModelConfiguration(
                id: modelId,
                defaultPrompt: ""
            )

            let container = try await LLMModelFactory.shared.loadContainer(
                configuration: configuration
            ) { _ in
                // Progress reporting intentionally swallowed in ModelRuntime —
                // la façade UI (04-07) ré-implémentera le hook progress via
                // un closure injecté.
            }

            self.container = container
            self.lastError = nil
        } catch {
            Log.error(.predictor, "model_load_failed")
            self.lastError = "load_failed: \(error.localizedDescription)"
        }
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
        await loadModel()
    }

    /// Cancellation hook. No-op : `GenerationPlanner` owns Task cancellation,
    /// container teardown happens in `swap(to:)` when modelId changes. Cette
    /// méthode existe pour symétrie d'API (la façade 04-07 voudra peut-être
    /// appeler `runtime.cancel()` après `planner.cancel()` pour des raisons
    /// de lisibilité).
    func cancel() {
        // No-op by design. Voir doc-comment.
    }

    // MARK: - OutputFilter (pure-function namespace)

    /// Pure-function helpers qui filtrent / normalisent le ghost text avant
    /// affichage. **Copies verbatim depuis PVM** (cf. PVM:247-375). La dédup
    /// PVM-side viendra en 04-07 ; en 04-05 les deux copies co-existent
    /// pour ne pas perturber le pipeline ghost actif.
    ///
    /// Toutes les fonctions sont `nonisolated static` → appelables depuis
    /// n'importe quel actor sans `await`, facilement testables.
    enum OutputFilter {

        /// Finds the largest suffix of `prefix` that is also a leading
        /// substring of `ghost`, and strips it. Recovers the actually-new
        /// chunk when the PT model decides to re-emit what the user just
        /// typed before continuing.
        ///
        /// **Verbatim** PVM:247-259 (`stripPrefixOverlap(_:prefix:)`).
        /// Note : signature ré-arrangée en (prefix:ghost:) côté docstring
        /// mais l'argument-label PVM est `(_:prefix:)` — on RESPECTE la
        /// shape PVM exacte pour rester testable contre la sémantique
        /// existante.
        nonisolated static func stripPrefixOverlap(_ snapshot: String, prefix: String) -> String {
            let maxLen = min(prefix.count, snapshot.count)
            if maxLen == 0 { return snapshot }
            var len = maxLen
            while len >= 2 {
                let suffix = prefix.suffix(len)
                if snapshot.hasPrefix(suffix) {
                    return String(snapshot.dropFirst(len))
                }
                len -= 1
            }
            return snapshot
        }

        /// Returns true when the START of the ghost matches the END of the
        /// prefix — i.e. the model is restating what the user just typed
        /// before (maybe) continuing.
        ///
        /// **Verbatim** PVM:285-297 (`ghostIsRepeatingPrefix(_:prefix:)`).
        nonisolated static func ghostIsRepeatingPrefix(_ ghost: String, prefix: String) -> Bool {
            let g = normalizeForRepeatCheck(String(ghost.prefix(60)))
            guard g.count >= 5 else { return false }
            let trimmed = stripTrailingPartialWord(prefix)
            let p = normalizeForRepeatCheck(String(trimmed.suffix(120)))
            var k = min(g.count, 60)
            while k >= 5 {
                let candidate = String(g.prefix(k))
                if p.hasSuffix(candidate) { return true }
                k -= 1
            }
            return false
        }

        /// True once `s` contains at least one word→separator transition.
        ///
        /// **Verbatim** PVM:303-313.
        nonisolated static func hasCompletedFirstWord(_ s: String) -> Bool {
            var sawWord = false
            for c in s {
                if c.isLetter || c.isNumber || c == "'" || c == "’" || c == "-" {
                    sawWord = true
                } else if sawWord {
                    return true
                }
            }
            return false
        }

        /// Drops the trailing word characters from `s`.
        ///
        /// **Verbatim** PVM:318-330.
        nonisolated static func stripTrailingPartialWord(_ s: String) -> String {
            var end = s.endIndex
            while end > s.startIndex {
                let prev = s.index(before: end)
                let c = s[prev]
                if c.isLetter || c.isNumber || c == "'" || c == "’" || c == "-" {
                    end = prev
                } else {
                    break
                }
            }
            return String(s[..<end])
        }

        /// Lowercases, keeps only letters/digits/space, collapses runs of
        /// non-word chars to a single space.
        ///
        /// **Verbatim** PVM:336-350.
        nonisolated static func normalizeForRepeatCheck(_ s: String) -> String {
            let lowered = s.lowercased()
            var out = ""
            var lastWasSpace = false
            for ch in lowered {
                if ch.isLetter || ch.isNumber {
                    out.append(ch)
                    lastWasSpace = false
                } else if !lastWasSpace {
                    out.append(" ")
                    lastWasSpace = true
                }
            }
            return out.trimmingCharacters(in: .whitespaces)
        }

        /// Truncates `text` to at most `max` whole words, respecting the
        /// same natural break points as the LLM-stream truncation
        /// (sentence terminators, then a soft comma break, then word cap).
        ///
        /// **Verbatim** PVM:357-375. Signature exacte : label externe `max`.
        nonisolated static func capToWords(_ text: String, max: Int) -> String {
            var s = text
            if s.count > 3 {
                for terminator in [". ", "? ", "! ", "… "] {
                    if let r = s.range(of: terminator) {
                        s = String(s[..<r.upperBound]).trimmingCharacters(in: .whitespaces)
                        break
                    }
                }
            }
            if s.count > 12, let r = s.range(of: ", ") {
                s = String(s[..<r.lowerBound])
            }
            let words = s.split(whereSeparator: { $0.isWhitespace })
            if words.count > max {
                s = words.prefix(max).joined(separator: " ")
            }
            return s
        }
    }

    // MARK: - System prompt + language detection

    /// Default autocomplete framing used in the system message of chat-template
    /// models.
    ///
    /// **Verbatim** PVM:218-220 (`autocompleteSystemPrompt`).
    static let autocompleteSystemPrompt = """
    You are an inline autocomplete inside the user's text field. Continue the user's text exactly where it stops, in the SAME language and style as the user. Output ONLY the continuation — never repeat the user's text, never add greetings, explanations, or quotes. Keep it short: a few words, one short sentence at most. If the text ends mid-word, complete that word first. If it ends after a space, predict the next words. Output plain text only: NEVER use Markdown, HTML, XML, bold, italics, code fences, or any formatting tags like <b>, **, _, ``. Just the raw characters the user would have typed themselves.
    """

    /// Builds a system prompt with an explicit language-steering header
    /// when we confidently detected the prefix's language.
    ///
    /// **Verbatim** PVM:228-235. Signature: `detectedLanguage: String?`
    /// (pas `NLLanguage?`) — aligné sur le retour réel de `detectLanguage`.
    static func buildSystemPrompt(detectedLanguage: String?) -> String {
        guard let lang = detectedLanguage else { return autocompleteSystemPrompt }
        return """
        The user is currently writing in \(lang). You MUST output the continuation in \(lang) only — never switch languages, never translate, never output English when the user is writing in \(lang).

        \(autocompleteSystemPrompt)
        """
    }

    /// Detects the dominant language of the last ~512 chars of the prefix.
    /// Returns the language as an English name ("French", "Spanish", …).
    ///
    /// **Verbatim** PVM:383-414. Le switch sur `NLLanguage` est conservé
    /// tel quel ; retour `String?` parce que la chaîne anglaise est ce que
    /// `buildSystemPrompt` consomme directement.
    static func detectLanguage(in text: String) -> String? {
        let tail = String(text.suffix(512))
        let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let lang = recognizer.dominantLanguage else { return nil }
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        if let confidence = hypotheses[lang], confidence < 0.5 { return nil }

        switch lang {
        case .french: return "French"
        case .english: return "English"
        case .spanish: return "Spanish"
        case .german: return "German"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .dutch: return "Dutch"
        case .polish: return "Polish"
        case .russian: return "Russian"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .simplifiedChinese, .traditionalChinese: return "Chinese"
        case .arabic: return "Arabic"
        case .turkish: return "Turkish"
        default:
            return Locale(identifier: "en").localizedString(forLanguageCode: lang.rawValue)
        }
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
                            for terminator in [". ", "? ", "! ", "… "] {
                                if let r = oneLine.range(of: terminator) {
                                    oneLine = String(oneLine[..<r.upperBound]).trimmingCharacters(in: .whitespaces)
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
