import CLlama
import Foundation
import SouffleuseLog

/// Metrics captured during a single llama.cpp generation pass.
///
/// `ttftMillis` is nil until the first token is produced ; `tokensPerSecond`
/// is nil until at least one token after the first has been timed.
public struct LlamaMetrics: Sendable {
    public var ttftMillis: Int?
    public var tokensPerSecond: Double?
    public init(ttftMillis: Int? = nil, tokensPerSecond: Double? = nil) {
        self.ttftMillis = ttftMillis
        self.tokensPerSecond = tokensPerSecond
    }
}

/// Sampling configuration for a single generation. Mirrors the low-temperature
/// / greedy autocomplete profile used by the previous MLX path.
public struct LlamaSampling: Sendable {
    public var temperature: Float
    public var repeatPenalty: Float
    public var repeatLastN: Int32
    public var seed: UInt32
    /// Personalization gain applied to the corpus n-gram logit bias. `0`
    /// disables the bias entirely (zero per-step overhead — the fast path is
    /// byte-identical to a build without personalization). Values > 0 scale
    /// the boost `log(1 + count)` added to each corpus-predicted next token.
    public var personalizationStrength: Float
    public init(temperature: Float = 0,
                repeatPenalty: Float = 1.1,
                repeatLastN: Int32 = 64,
                seed: UInt32 = 0,
                personalizationStrength: Float = 0) {
        self.temperature = temperature
        self.repeatPenalty = repeatPenalty
        self.repeatLastN = repeatLastN
        self.seed = seed
        self.personalizationStrength = personalizationStrength
    }
}

/// In-memory bigram + trigram model over **llama token ids**, built from the
/// user's accepted-text corpus. Independent of the MLX-tokenizer `NgramModel`
/// in `SouffleusePersonalization` (which tokenises into words, not llama
/// tokens). Lives inside the actor — never crosses an isolation boundary, so
/// its mutable dictionaries are safe without synchronisation.
///
/// Lookup keys are packed integers to avoid hashing arrays per decode step :
/// - bigram key  : `a`                          → counts of `next`
/// - trigram key : `(a << 32) | b`              → counts of `next`
struct LlamaCorpusNgram {
    /// `prevToken → (nextToken → count)`.
    private var bigram: [Int32: [Int32: Int]] = [:]
    /// `(prev2 << 32 | prev1) → (nextToken → count)`.
    private var trigram: [Int64: [Int32: Int]] = [:]

    var isEmpty: Bool { bigram.isEmpty }

    /// Accumulates bigram/trigram counts from one tokenised corpus entry.
    mutating func ingest(_ tokens: [Int32]) {
        guard tokens.count >= 2 else { return }
        for i in 1..<tokens.count {
            let prev = tokens[i - 1]
            let next = tokens[i]
            bigram[prev, default: [:]][next, default: 0] += 1
            if i >= 2 {
                let key = (Int64(tokens[i - 2]) << 32) | Int64(UInt32(bitPattern: prev))
                trigram[key, default: [:]][next, default: 0] += 1
            }
        }
    }

    /// Removes all accumulated counts.
    mutating func clear() {
        bigram.removeAll(keepingCapacity: true)
        trigram.removeAll(keepingCapacity: true)
    }

    /// Returns candidate next tokens for the context `recentIds`, trying the
    /// trigram (last two ids) first and backing off to the bigram (last id).
    /// Empty when no match — caller skips the bias for that step.
    func candidates(after recentIds: ArraySlice<Int32>) -> [Int32: Int] {
        if recentIds.count >= 2 {
            let a = recentIds[recentIds.index(recentIds.endIndex, offsetBy: -2)]
            let b = recentIds[recentIds.index(recentIds.endIndex, offsetBy: -1)]
            let key = (Int64(a) << 32) | Int64(UInt32(bitPattern: b))
            if let tri = trigram[key], !tri.isEmpty { return tri }
        }
        if let last = recentIds.last, let bi = bigram[last] {
            return bi
        }
        return [:]
    }
}

/// On-device llama.cpp inference engine.
///
/// Owns one `llama_model` + `llama_context` for the lifetime of the actor.
/// Loads a GGUF from a local file path (no network). Generation is
/// token-by-token streaming with cooperative cancellation : the `onToken`
/// callback returns `false` to stop early (used by the caller to drop a
/// superseded generation when a new keystroke arrives).
///
/// All public boundary types are `Sendable`. The underlying llama.cpp
/// pointers never escape the actor.
public actor LlamaEngine {
    /// Opaque model + context handles. `@unchecked Sendable` is safe : these
    /// pointers are only ever touched from inside the actor's serialised
    /// execution context.
    private struct Handles: @unchecked Sendable {
        let model: OpaquePointer
        let context: OpaquePointer
        let vocab: OpaquePointer
        let nCtx: Int32
    }

    private var handles: Handles?
    private var loadedPath: String?

    /// Corpus n-gram over llama token ids, rebuilt from accepted-text strings
    /// via `setCorpus(_:)`. Empty until a corpus is provided ; when empty the
    /// decode loop never touches the logits (zero overhead).
    private var corpusNgram = LlamaCorpusNgram()

    /// One-time global backend init, guarded so it runs at most once per
    /// process even across multiple engine instances.
    private static let backendOnce: Void = {
        // Silence llama.cpp/ggml's own stdout/stderr logging. We route nothing
        // through it ; our structured Log is the only sanctioned sink.
        llama_log_set({ _, _, _ in }, nil)
        ggml_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    public init() {}

    /// True once a model is loaded and ready to generate.
    public var isReady: Bool { handles != nil }

    /// The path of the currently-loaded GGUF, or nil.
    public var modelPath: String? { loadedPath }

    // MARK: - Lifecycle

    /// Loads a GGUF model from a local file path. Idempotent if the same path
    /// is already loaded. Tears down any previously-loaded model first.
    ///
    /// Returns true on success. On failure logs `llama_load_failed` and leaves
    /// the engine in an unloaded state.
    @discardableResult
    public func load(modelPath path: String, contextTokens: UInt32 = 4096) -> Bool {
        if loadedPath == path, handles != nil { return true }
        _ = LlamaEngine.backendOnce
        unload()

        guard FileManager.default.fileExists(atPath: path) else {
            Log.error(.predictor, "llama_load_failed")
            return false
        }

        var modelParams = llama_model_default_params()
        // Offload all layers to Metal GPU (n_gpu_layers default may be 0 on
        // some builds — force a large value so the Metal backend is used).
        modelParams.n_gpu_layers = 999

        guard let model = path.withCString({ cpath in
            llama_model_load_from_file(cpath, modelParams)
        }) else {
            Log.error(.predictor, "llama_load_failed")
            return false
        }

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = contextTokens
        ctxParams.n_batch = contextTokens
        let cores = ProcessInfo.processInfo.activeProcessorCount
        ctxParams.n_threads = Int32(max(1, cores - 1))
        ctxParams.n_threads_batch = Int32(max(1, cores - 1))

        guard let context = llama_init_from_model(model, ctxParams) else {
            llama_model_free(model)
            Log.error(.predictor, "llama_load_failed")
            return false
        }

        guard let vocab = llama_model_get_vocab(model) else {
            llama_free(context)
            llama_model_free(model)
            Log.error(.predictor, "llama_load_failed")
            return false
        }

        handles = Handles(
            model: model,
            context: context,
            vocab: vocab,
            nCtx: Int32(llama_n_ctx(context))
        )
        loadedPath = path
        Log.info(.predictor, "llama_loaded")
        return true
    }

    /// Tears down the current model + context.
    public func unload() {
        if let h = handles {
            llama_free(h.context)
            llama_model_free(h.model)
        }
        handles = nil
        loadedPath = nil
    }

    deinit {
        if let h = handles {
            llama_free(h.context)
            llama_model_free(h.model)
        }
    }

    // MARK: - Personalization corpus

    /// Rebuilds the corpus n-gram from `entries` (accepted-text strings, or
    /// `contextBefore + " " + accepted`). Each entry is tokenised with the
    /// loaded vocabulary (no BOS) and folded into bigram/trigram counts.
    /// No-op (clears) when the engine is not loaded. Cheap full rebuild —
    /// the corpus is small (≤ a few hundred short entries).
    public func setCorpus(_ entries: [String]) {
        corpusNgram.clear()
        guard handles != nil else { return }
        for entry in entries {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            corpusNgram.ingest(tokenize(trimmed, addSpecial: false))
        }
        if !corpusNgram.isEmpty {
            Log.info(.predictor, "corpus_ngram_built")
        }
    }

    /// True when the corpus n-gram has at least one bigram entry.
    public var hasCorpus: Bool { !corpusNgram.isEmpty }

    // MARK: - Tokenization

    /// Tokenizes `text` using the loaded vocabulary. `addSpecial` controls
    /// whether BOS/special tokens are prepended (true for a fresh prompt).
    private func tokenize(_ text: String, addSpecial: Bool) -> [Int32] {
        guard let h = handles else { return [] }
        let utf8 = Array(text.utf8)
        if utf8.isEmpty && !addSpecial { return [] }
        // First call with a generous buffer; llama_tokenize returns the
        // negative required count if the buffer was too small.
        let capacity = utf8.count + 16
        var tokens = [Int32](repeating: 0, count: capacity)
        let n = utf8.withUnsafeBufferPointer { textPtr -> Int32 in
            tokens.withUnsafeMutableBufferPointer { tokPtr in
                llama_tokenize(
                    h.vocab,
                    textPtr.baseAddress.map { $0.withMemoryRebound(to: CChar.self, capacity: utf8.count) { $0 } },
                    Int32(utf8.count),
                    tokPtr.baseAddress,
                    Int32(capacity),
                    addSpecial,
                    true
                )
            }
        }
        if n < 0 {
            let needed = Int(-n)
            tokens = [Int32](repeating: 0, count: needed)
            _ = utf8.withUnsafeBufferPointer { textPtr in
                tokens.withUnsafeMutableBufferPointer { tokPtr in
                    llama_tokenize(
                        h.vocab,
                        textPtr.baseAddress.map { $0.withMemoryRebound(to: CChar.self, capacity: utf8.count) { $0 } },
                        Int32(utf8.count),
                        tokPtr.baseAddress,
                        Int32(needed),
                        addSpecial,
                        true
                    )
                }
            }
            return tokens
        }
        return Array(tokens.prefix(Int(n)))
    }

    /// Converts a single token id into its UTF-8 piece.
    private func piece(_ token: Int32) -> String {
        guard let h = handles else { return "" }
        var buf = [CChar](repeating: 0, count: 256)
        let n = llama_token_to_piece(h.vocab, token, &buf, Int32(buf.count), 0, false)
        if n < 0 {
            let needed = Int(-n)
            buf = [CChar](repeating: 0, count: needed)
            let n2 = llama_token_to_piece(h.vocab, token, &buf, Int32(needed), 0, false)
            guard n2 > 0 else { return "" }
            return String(decoding: buf[0..<Int(n2)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        guard n > 0 else { return "" }
        return String(decoding: buf[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Counts tokens for a piece of text (used for coarse budgeting). Cheap
    /// wrapper over `tokenize`.
    public func countTokens(_ text: String) -> Int {
        tokenize(text, addSpecial: false).count
    }

    // MARK: - Generation

    /// Streams a completion for `prompt`. Calls `onToken` for each decoded
    /// piece ; if `onToken` returns `false`, generation stops cleanly.
    /// Stops on EOG, on `maxTokens`, or on cooperative `Task` cancellation.
    ///
    /// The KV cache is cleared at the start of every call (stateless per
    /// generation) — the caller handles its own memoisation upstream.
    @discardableResult
    public func generate(
        prompt: String,
        maxTokens: Int,
        sampling: LlamaSampling = LlamaSampling(),
        onToken: @Sendable (String) -> Bool
    ) -> LlamaMetrics {
        guard let h = handles else { return LlamaMetrics() }

        // Reset the KV cache for sequence 0 — stateless per generation.
        if let mem = llama_get_memory(h.context) {
            llama_memory_seq_rm(mem, 0, -1, -1)
        }

        var promptTokens = tokenize(prompt, addSpecial: true)
        if promptTokens.isEmpty { return LlamaMetrics() }
        // Guard against overflowing the context window.
        let maxPrompt = Int(h.nCtx) - maxTokens - 4
        if maxPrompt > 0, promptTokens.count > maxPrompt {
            promptTokens = Array(promptTokens.suffix(maxPrompt))
        }

        // Build the sampler chain : penalties → temp/greedy.
        let chainParams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(chainParams) else {
            return LlamaMetrics()
        }
        defer { llama_sampler_free(sampler) }

        if sampling.repeatPenalty != 1.0 {
            llama_sampler_chain_add(
                sampler,
                llama_sampler_init_penalties(sampling.repeatLastN, sampling.repeatPenalty, 0.0, 0.0)
            )
        }
        if sampling.temperature <= 0 {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(sampling.temperature))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(sampling.seed))
        }

        var metrics = LlamaMetrics()
        let start = Date()
        var firstTokenAt: Date?
        var produced = 0

        // Decode the prompt in one batch.
        var workTokens = promptTokens
        let promptOK = workTokens.withUnsafeMutableBufferPointer { ptr -> Bool in
            let batch = llama_batch_get_one(ptr.baseAddress, Int32(ptr.count))
            return llama_decode(h.context, batch) == 0
        }
        if !promptOK { return metrics }

        var nPast = Int32(promptTokens.count)

        // Personalization bias is active only when explicitly requested AND a
        // corpus n-gram exists. When inactive we keep the fast path completely
        // untouched — no logits fetch, no window maintenance.
        let biasActive = sampling.personalizationStrength > 0 && !corpusNgram.isEmpty
        let strength = sampling.personalizationStrength
        // Sliding window of recently-decoded token ids (prompt tail + emitted)
        // used to compute the current n-gram context. Only the last two ids
        // matter (trigram), so a tiny tail is enough.
        var recentIds: [Int32] = biasActive ? Array(promptTokens.suffix(2)) : []

        while produced < maxTokens {
            if Task.isCancelled { break }

            // Context-dependent corpus boost : add `strength * log(1+count)`
            // to each candidate next-token's logit BEFORE sampling, so the
            // sampler chain (penalties + greedy/temp) reads the modified
            // distribution.
            if biasActive, let logits = llama_get_logits_ith(h.context, -1) {
                let candidates = corpusNgram.candidates(after: recentIds[recentIds.startIndex...])
                if !candidates.isEmpty {
                    let nVocab = llama_vocab_n_tokens(h.vocab)
                    for (id, count) in candidates where id >= 0 && id < nVocab {
                        logits[Int(id)] += strength * logf(1 + Float(count))
                    }
                }
            }

            let tokenId = llama_sampler_sample(sampler, h.context, -1)
            if llama_vocab_is_eog(h.vocab, tokenId) { break }
            llama_sampler_accept(sampler, tokenId)

            if biasActive {
                recentIds.append(tokenId)
                if recentIds.count > 2 { recentIds.removeFirst(recentIds.count - 2) }
            }

            if firstTokenAt == nil { firstTokenAt = Date() }
            produced += 1

            let text = piece(tokenId)
            if !onToken(text) { break }

            if nPast >= h.nCtx { break }
            var one = [Int32](repeating: tokenId, count: 1)
            let ok = one.withUnsafeMutableBufferPointer { ptr -> Bool in
                let batch = llama_batch_get_one(ptr.baseAddress, 1)
                return llama_decode(h.context, batch) == 0
            }
            if !ok { break }
            nPast += 1
        }

        if let first = firstTokenAt {
            metrics.ttftMillis = Int(first.timeIntervalSince(start) * 1000)
            let elapsed = Date().timeIntervalSince(first)
            if elapsed > 0, produced > 1 {
                metrics.tokensPerSecond = Double(produced) / elapsed
            }
        }
        return metrics
    }
}
