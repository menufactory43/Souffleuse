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

    /// Internal gain calibration (Phase 3). The user-facing Preferences slider
    /// is `0.0…2.0` (default `1.0`), but the additive logit boost needs to be
    /// roughly an order of magnitude larger to actually steer greedy decoding
    /// (Phase 1 probe needed an effective strength ≈ 8 on a bare bigram). The
    /// caller multiplies the slider value by this constant before constructing
    /// `LlamaSampling`, so the DEFAULT preference (1.0) maps to an effective
    /// base gain of `6.0` — noticeable but not overpowering — and the
    /// suffix-array `matchLength` sharpening inside the decode loop boosts
    /// longer (more predictive) matches further. A pure multiplier keeps the
    /// behaviour easy to reason about and avoids overfitting.
    public static let personalizationGainScale: Float = 6.0

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

/// Phase 3 — variable-length-context corpus model backed by a **suffix array**
/// over the concatenated corpus token-id sequence.
///
/// Strictly richer than `LlamaCorpusNgram` : instead of a fixed bigram/trigram
/// backoff it finds, at each decode step, the **longest suffix of the current
/// context window that also occurs in the corpus**, then returns the observed
/// next-token distribution for that match plus the matched length. The matched
/// length lets the caller sharpen the boost (longer context ⇒ stronger,
/// peakier bias) — replicating Cotypist's suffix-array corpus use.
///
/// Layout :
/// - `tokens` : every corpus entry's token ids concatenated, each entry
///   terminated by a unique negative sentinel (`-1, -2, …`) so a suffix never
///   matches across an entry boundary.
/// - `sa` : suffix-array indices into `tokens`, sorted by the suffix that
///   starts at each index (sentinels compare as their negative values, so they
///   never equal a real positive token id).
///
/// All lookups are pure reads on immutable storage — the struct is built once
/// per corpus refresh (off the hot decode path) and only read during decode.
/// Lives inside the actor, never crosses an isolation boundary.
public struct LlamaCorpusSuffixArray {
    /// Concatenated corpus tokens with per-entry negative sentinels.
    private var tokens: [Int32] = []
    /// Suffix-array : indices into `tokens`, sorted lexicographically by suffix.
    private var sa: [Int] = []

    /// Longest context suffix (in tokens) we bother matching. Beyond this the
    /// distribution is already maximally sharp and the extra comparisons cost
    /// more than they buy. Also bounds the per-step comparison work.
    public static let maxMatchLen = 16

    public init() {}

    public var isEmpty: Bool { sa.isEmpty }

    /// Rebuilds the suffix array from the per-entry tokenised corpus. Each
    /// inner array is one accepted-text entry's llama token ids. A unique
    /// negative sentinel terminates every entry so matches cannot cross
    /// entries. Full rebuild — cheap for the corpus sizes we carry, and run
    /// off the hot path by the caller.
    public mutating func build(entries: [[Int32]]) {
        tokens.removeAll(keepingCapacity: true)
        sa.removeAll(keepingCapacity: true)
        var sentinel: Int32 = -1
        for entry in entries where entry.count >= 2 {
            tokens.append(contentsOf: entry)
            tokens.append(sentinel)
            sentinel -= 1
        }
        guard !tokens.isEmpty else { return }
        sa = Array(0..<tokens.count)
        let toks = tokens
        sa.sort { a, b in
            var i = a, j = b
            while i < toks.count && j < toks.count {
                if toks[i] != toks[j] { return toks[i] < toks[j] }
                i += 1; j += 1
            }
            // Shorter suffix (hit end of array first) sorts first.
            return i >= toks.count
        }
    }

    public mutating func clear() {
        tokens.removeAll(keepingCapacity: true)
        sa.removeAll(keepingCapacity: true)
    }

    /// Result of a longest-match query : the observed next-token counts for the
    /// longest matched context suffix, and that match length (in tokens).
    public struct Match {
        public let candidates: [Int32: Int]
        public let matchLength: Int
    }

    /// Finds the longest suffix of `context` that occurs in the corpus (not at
    /// an entry boundary) and returns the distribution of tokens observed
    /// immediately after it. Empty `candidates` when no suffix of length ≥1
    /// matches. Tries the longest suffix first and backs off one token at a
    /// time — the first length that yields at least one continuation wins.
    public func longestMatch(after context: ArraySlice<Int32>) -> Match {
        guard !sa.isEmpty, !context.isEmpty else { return Match(candidates: [:], matchLength: 0) }
        let ctx = Array(context.suffix(Self.maxMatchLen))
        // Try progressively shorter suffixes of ctx.
        for start in 0..<ctx.count {
            let pattern = Array(ctx[start...])
            let cands = continuations(matching: pattern)
            if !cands.isEmpty {
                return Match(candidates: cands, matchLength: pattern.count)
            }
        }
        return Match(candidates: [:], matchLength: 0)
    }

    /// Binary-searches the suffix array for the range of suffixes that begin
    /// with `pattern`, then collects the token that follows each occurrence
    /// (skipping occurrences where `pattern` is immediately followed by a
    /// sentinel or the end of `tokens`).
    private func continuations(matching pattern: [Int32]) -> [Int32: Int] {
        guard !pattern.isEmpty else { return [:] }
        let lo = lowerBound(pattern)
        let hi = upperBound(pattern)
        guard lo < hi else { return [:] }
        var out: [Int32: Int] = [:]
        for k in lo..<hi {
            let next = sa[k] + pattern.count
            if next >= tokens.count { continue }
            let nextTok = tokens[next]
            if nextTok < 0 { continue }  // sentinel — end of entry, no continuation
            out[nextTok, default: 0] += 1
        }
        return out
    }

    /// Compares the suffix at `tokens[saIdx...]` against `pattern` lexically.
    /// Returns negative / 0 / positive like C `memcmp` over the prefix.
    private func compareSuffix(_ saIdx: Int, _ pattern: [Int32]) -> Int {
        var i = saIdx
        var p = 0
        while p < pattern.count {
            if i >= tokens.count { return -1 }  // suffix shorter ⇒ sorts before
            let t = tokens[i]
            if t != pattern[p] { return t < pattern[p] ? -1 : 1 }
            i += 1; p += 1
        }
        return 0  // pattern is a prefix of this suffix
    }

    private func lowerBound(_ pattern: [Int32]) -> Int {
        var lo = 0, hi = sa.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if compareSuffix(sa[mid], pattern) < 0 { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func upperBound(_ pattern: [Int32]) -> Int {
        var lo = 0, hi = sa.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if compareSuffix(sa[mid], pattern) <= 0 { lo = mid + 1 } else { hi = mid }
        }
        return lo
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

    /// The EXACT token sequence currently resident in KV sequence 0. It is the
    /// last prompt that was decoded plus every token decoded during generation
    /// (each appended to KV via `llama_decode`). Maintained incrementally so a
    /// mid-stream cancellation still leaves it consistent with the real KV
    /// contents — the next `generate()` computes the longest common prefix
    /// against it and only re-decodes the diverging suffix.
    ///
    /// Invalidated (`[]`) on model load/unload. NOT touched by `setCorpus`
    /// (corpus only affects the logit bias, never the KV).
    private var kvTokens: [Int32] = []

    /// Corpus n-gram over llama token ids, rebuilt from accepted-text strings
    /// via `setCorpus(_:)`. Empty until a corpus is provided ; when empty the
    /// decode loop never touches the logits (zero overhead).
    private var corpusNgram = LlamaCorpusNgram()

    /// Phase 3 — variable-length-context corpus model over llama token ids.
    /// Built alongside `corpusNgram` in `setCorpus(_:)`. When non-empty it is
    /// the PRIMARY source of decode-step candidates (longest-match) ; the fixed
    /// n-gram remains as a guaranteed-cheap fallback. Empty until a corpus is
    /// provided ; when empty the decode loop never touches the logits.
    private var corpusSuffixArray = LlamaCorpusSuffixArray()

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

    /// Number of tokens currently resident in KV sequence 0 (test/probe seam
    /// to assert cache bookkeeping). Equals the last decoded prompt length plus
    /// the count of tokens decoded during the last (possibly cancelled)
    /// generation. `0` when the cache is cold/invalidated.
    public var cachedTokenCount: Int { kvTokens.count }

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
        // Fresh context ⇒ KV is empty. Invalidate any stale cached sequence.
        kvTokens = []
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
        // The context (and its KV) is gone — any cached sequence is invalid.
        kvTokens = []
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
        corpusSuffixArray.clear()
        guard handles != nil else { return }
        var tokenised: [[Int32]] = []
        tokenised.reserveCapacity(entries.count)
        for entry in entries {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let ids = tokenize(trimmed, addSpecial: false)
            corpusNgram.ingest(ids)
            tokenised.append(ids)
        }
        // Build the suffix array from the SAME llama token-id sequences. Full
        // rebuild — cheap for our corpus size and run off the hot decode path
        // (callers invoke setCorpus from a background Task on accept/startup).
        corpusSuffixArray.build(entries: tokenised)
        if !corpusNgram.isEmpty {
            Log.info(.predictor, "corpus_ngram_built")
        }
        if !corpusSuffixArray.isEmpty {
            Log.info(.predictor, "corpus_suffix_array_built")
        }
    }

    /// True when the corpus n-gram has at least one bigram entry.
    public var hasCorpus: Bool { !corpusNgram.isEmpty }

    /// Exposes the corpus suffix-array longest-match for the given context
    /// token ids — used by tests/probes to prove variable-length matching.
    /// Returns `(candidates, matchLength)`.
    public func suffixArrayCandidates(after context: [Int32]) -> (candidates: [Int32: Int], matchLength: Int) {
        let m = corpusSuffixArray.longestMatch(after: context[context.startIndex...])
        return (m.candidates, m.matchLength)
    }

    /// Tokenizes `text` to llama ids (no BOS) — exposed for probe/test use so
    /// callers can build context windows in token space.
    public func tokenizeForCorpus(_ text: String) -> [Int32] {
        tokenize(text, addSpecial: false)
    }

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
    /// KV/prompt cache reuse : across consecutive calls the engine keeps the
    /// KV cache for the longest common prefix between the new prompt and the
    /// previously-resident sequence (`kvTokens`), and only decodes the new
    /// suffix. Greedy output for a given FINAL prompt is identical whether the
    /// cache was cold or warm. See `kvTokens`. Falls back to a full reset +
    /// recompute (logging `kv_full_recompute`) when the prompt is head-truncated
    /// to fit the window (position-0 caching would be invalid).
    @discardableResult
    public func generate(
        prompt: String,
        maxTokens: Int,
        sampling: LlamaSampling = LlamaSampling(),
        onToken: @Sendable (String) -> Bool
    ) -> LlamaMetrics {
        guard let h = handles else { return LlamaMetrics() }

        var promptTokens = tokenize(prompt, addSpecial: true)
        if promptTokens.isEmpty { return LlamaMetrics() }
        // Guard against overflowing the context window. If we have to
        // head-truncate, the absolute positions of the remaining tokens shift,
        // so a position-0-anchored KV reuse would be incorrect. Detect this and
        // force a full recompute (invalidate the cached sequence).
        let maxPrompt = Int(h.nCtx) - maxTokens - 4
        var headTruncated = false
        if maxPrompt > 0, promptTokens.count > maxPrompt {
            promptTokens = Array(promptTokens.suffix(maxPrompt))
            headTruncated = true
        }

        // ── KV / prompt cache reuse ──────────────────────────────────────────
        // Compute the longest common prefix between the new prompt and the
        // sequence currently resident in KV seq 0, drop the diverging tail from
        // KV, and decode only the new suffix. On head-truncation we cannot
        // safely reuse (positions shifted) → full reset + recompute.
        let mem = llama_get_memory(h.context)
        var lcp = 0
        if headTruncated || kvTokens.isEmpty {
            // Full recompute path.
            if let mem { llama_memory_seq_rm(mem, 0, -1, -1) }
            if headTruncated { Log.info(.predictor, "kv_full_recompute") }
            kvTokens = []
            lcp = 0
        } else {
            let bound = min(promptTokens.count, kvTokens.count)
            while lcp < bound && promptTokens[lcp] == kvTokens[lcp] { lcp += 1 }
            // Drop everything in KV from position `lcp` onward, keeping [0, lcp).
            if let mem { llama_memory_seq_rm(mem, 0, Int32(lcp), -1) }
        }

        // The slice we still need to decode. When the entire new prompt is
        // already cached (`lcp == promptTokens.count`) the logits at the final
        // position are NOT fresh in the sampler's view, so we trim one token
        // back and re-decode it — guaranteeing at least one decode this pass and
        // valid logits at the last position before sampling.
        if lcp == promptTokens.count && lcp > 0 {
            lcp -= 1
            if let mem { llama_memory_seq_rm(mem, 0, Int32(lcp), -1) }
        }
        // KV now holds exactly promptTokens[0..<lcp]. We will decode the rest.
        kvTokens = Array(promptTokens[0..<lcp])

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

        // Decode only the new suffix (promptTokens[lcp...]) in one batch.
        // `llama_batch_get_one` assigns positions starting from the current KV
        // length (= lcp), so the suffix lands at the right absolute positions.
        // There is always ≥1 token to decode here (the lcp==count case trimmed
        // one back above), so the final-position logits are always fresh.
        var workTokens = Array(promptTokens[lcp...])
        let promptOK = workTokens.withUnsafeMutableBufferPointer { ptr -> Bool in
            let batch = llama_batch_get_one(ptr.baseAddress, Int32(ptr.count))
            return llama_decode(h.context, batch) == 0
        }
        if !promptOK {
            // Decode failed; KV state is now indeterminate for the suffix.
            // Invalidate the cache so the next call does a clean recompute.
            kvTokens = []
            return metrics
        }
        // The suffix is now resident in KV. Reflect that in kvTokens.
        kvTokens = promptTokens

        var nPast = Int32(promptTokens.count)

        // Personalization bias is active only when explicitly requested AND a
        // corpus n-gram exists. When inactive we keep the fast path completely
        // untouched — no logits fetch, no window maintenance.
        let biasActive = sampling.personalizationStrength > 0
            && (!corpusSuffixArray.isEmpty || !corpusNgram.isEmpty)
        let strength = sampling.personalizationStrength
        let useSuffixArray = !corpusSuffixArray.isEmpty
        // Sliding window of recently-decoded token ids (prompt tail + emitted)
        // used to compute the current corpus-match context. The suffix array
        // matches up to `maxMatchLen` tokens, so we keep that many ; the fixed
        // n-gram fallback only ever reads the last two.
        let windowLen = LlamaCorpusSuffixArray.maxMatchLen
        var recentIds: [Int32] = biasActive ? Array(promptTokens.suffix(windowLen)) : []

        while produced < maxTokens {
            if Task.isCancelled { break }

            // Context-dependent corpus boost : add `strength * log(1+count)`
            // to each candidate next-token's logit BEFORE sampling, so the
            // sampler chain (penalties + greedy/temp) reads the modified
            // distribution.
            if biasActive, let logits = llama_get_logits_ith(h.context, -1) {
                // Suffix-array longest match (variable-length context) is the
                // primary source ; the fixed n-gram is the cheap fallback.
                // `matchLen` sharpens the boost : a longer matched context is
                // far more predictive, so we scale the boost up with it. This
                // makes a 4-token corpus match steer much harder than a bare
                // bigram, which is the whole point of the suffix array.
                let candidates: [Int32: Int]
                let matchLen: Int
                if useSuffixArray {
                    let m = corpusSuffixArray.longestMatch(after: recentIds[recentIds.startIndex...])
                    candidates = m.candidates
                    matchLen = m.matchLength
                } else {
                    candidates = corpusNgram.candidates(after: recentIds.suffix(2))
                    matchLen = candidates.isEmpty ? 0 : min(2, recentIds.count)
                }
                if !candidates.isEmpty {
                    // Sharpening factor : ≥1, grows with matched context length.
                    // matchLen 1 → 1.0, 2 → ~1.7, 4 → ~3.0, capped at maxMatchLen.
                    let sharpen = 1.0 + 0.5 * Float(max(0, matchLen - 1))
                    let nVocab = llama_vocab_n_tokens(h.vocab)
                    for (id, count) in candidates where id >= 0 && id < nVocab {
                        logits[Int(id)] += strength * sharpen * logf(1 + Float(count))
                    }
                }
            }

            let tokenId = llama_sampler_sample(sampler, h.context, -1)
            if llama_vocab_is_eog(h.vocab, tokenId) { break }
            llama_sampler_accept(sampler, tokenId)

            if biasActive {
                recentIds.append(tokenId)
                if recentIds.count > windowLen {
                    recentIds.removeFirst(recentIds.count - windowLen)
                }
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
            if !ok {
                // Decode failed: this token never entered KV. kvTokens already
                // reflects the resident sequence, so leave it as-is and stop.
                break
            }
            // The token is now resident in KV — record it immediately so that a
            // cancellation on the NEXT iteration leaves kvTokens consistent with
            // the actual KV contents.
            kvTokens.append(tokenId)
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
