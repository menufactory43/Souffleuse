import Accelerate
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
    /// Softmax probability the model assigned to the FIRST sampled token, on
    /// the (ban/bias-adjusted) distribution actually used for sampling. This is
    /// the model's confidence in how it starts the completion — low when it is
    /// guessing which word you mean mid-word ("co" → colette? comment?). nil
    /// when no token was produced. Used by the confidence gate (Cotypist
    /// `minBranchProbability` parity) and read by the probe to calibrate it.
    public var firstTokenProb: Double?
    public init(ttftMillis: Int? = nil, tokensPerSecond: Double? = nil, firstTokenProb: Double? = nil) {
        self.ttftMillis = ttftMillis
        self.tokensPerSecond = tokensPerSecond
        self.firstTokenProb = firstTokenProb
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

    /// Nucleus / tail trimming knobs (experiment levers). All default to
    /// "disabled" so the shipped greedy profile is byte-identical. They only
    /// affect output when `temperature > 0` (greedy ignores the distribution
    /// shape). `topK`/`topP`/`minP == 0` ⇒ that stage is not added to the chain.
    public var topK: Int32
    public var topP: Float
    public var minP: Float

    /// When true, tokens whose decoded piece contains web-markup characters
    /// (`<` `>` `` ` `` `*` `#`) are forced to `-inf` before sampling — the base
    /// (pt) Gemma was trained on scraped HTML/markdown and emits `<strong>…`,
    /// fenced code, etc. Banning the markup tokens at the source stops the
    /// derailment that the post-hoc regex only papered over. Built once per
    /// model load (vocab scan), then free per step.
    public var banMarkup: Bool

    /// Experiment lever : force tokens whose piece contains an ASCII digit to
    /// `-inf`. The base (pt) model has a strong "web text" prior and loves to
    /// continue a short casual fragment with a number ("Des 20 ans…", "2019.").
    /// Banning digits tests whether suppressing that prior pushes it back to
    /// prose. NOT necessarily a shipping default (some completions legitimately
    /// want numbers) — a measurement knob.
    public var banDigits: Bool

    /// Experiment lever : ban digit tokens ONLY for the FIRST generated token.
    /// The "web number" prior is strongest right at the start of a completion
    /// ("Des " → "20 ans"), but later digits are often legitimate ("à 14
    /// heures"). Banning leading-only kills the prior without losing valid
    /// numbers mid-completion. Ignored when `banDigits` (full ban) is set.
    public var banDigitsLeading: Bool

    /// Force tokens whose piece contains an emoji / pictograph to `-inf`. Once
    /// markup + digits are banned the base model sometimes falls back to emoji
    /// ("Merci pour votre" → "⭐️"); a ghost is text, never an emoji, so we ban
    /// them at the source.
    public var banEmoji: Bool

    /// Nucleus gate width for the noise-robust corpus bias: a corpus candidate
    /// is boosted only if its model logit is within this many units of the top
    /// logit. Larger = more permissive (legit personalization steers harder,
    /// but a polluted corpus leaks more). `0` falls back to the engine default.
    public var nucleusMargin: Float

    /// Confidence gate (Cotypist `minBranchProbability` parity). When > 0, the
    /// decode is ABORTED with zero tokens if the FIRST sampled token's softmax
    /// probability is below this threshold — i.e. the model is guessing rather
    /// than confident. The caller raises it mid-word (where a low first-token
    /// prob means "wrong word": "co" → colette/comment/commande split) and
    /// leaves it 0 at a word boundary (where several continuations are all
    /// legitimate). `0` disables the gate (zero overhead — no softmax scan).
    public var minFirstTokenProb: Float

    /// TOKEN HEALING (experiment). When non-empty, the trailing partial word
    /// the user has already typed (e.g. "fis" of "Rapport fis"). The base
    /// SentencePiece model would otherwise tokenize "fis" to ONE complete token
    /// and freely derive a DIFFERENT word ("fiscaal" / doubled letters). Healing
    /// pops the prompt token(s) that cover this partial off the tokenized
    /// prompt, then masks every vocab token whose decoded piece is NOT
    /// prefix-compatible with the not-yet-consumed partial, until the dropped
    /// characters are re-derived at a clean token boundary. `nil` (the default)
    /// means NO healing — the prompt path is byte-identical to a build without
    /// this field.
    public var healPrefix: String? = nil

    public init(temperature: Float = 0,
                repeatPenalty: Float = 1.1,
                repeatLastN: Int32 = 64,
                seed: UInt32 = 0,
                personalizationStrength: Float = 0,
                topK: Int32 = 0,
                topP: Float = 0,
                minP: Float = 0,
                banMarkup: Bool = false,
                banDigits: Bool = false,
                banDigitsLeading: Bool = false,
                banEmoji: Bool = false,
                nucleusMargin: Float = 0,
                minFirstTokenProb: Float = 0,
                healPrefix: String? = nil) {
        self.temperature = temperature
        self.repeatPenalty = repeatPenalty
        self.repeatLastN = repeatLastN
        self.seed = seed
        self.personalizationStrength = personalizationStrength
        self.topK = topK
        self.topP = topP
        self.minP = minP
        self.banMarkup = banMarkup
        self.banDigits = banDigits
        self.banDigitsLeading = banDigitsLeading
        self.banEmoji = banEmoji
        self.nucleusMargin = nucleusMargin
        self.minFirstTokenProb = minFirstTokenProb
        self.healPrefix = healPrefix
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

    /// Cached list of vocab token ids whose decoded piece contains web-markup
    /// characters (`< > ` `` ` `` ` * #`). Built lazily on first `banMarkup`
    /// generation by scanning the vocab once, then reused. Reset to `nil` on
    /// every `load` (a new model has a different vocab). `nil` = not yet built.
    private var markupBannedTokens: [Int32]?

    /// Cached list of vocab token ids whose decoded piece contains an ASCII
    /// digit. Built lazily on first `banDigits` generation. Reset on `load`.
    private var digitBannedTokens: [Int32]?

    /// Cached list of vocab token ids whose decoded piece contains an emoji /
    /// pictograph scalar. Built lazily on first `banEmoji` generation. Reset on
    /// `load`.
    private var emojiBannedTokens: [Int32]?

    /// Cached metaspace-normalized piece for EVERY vocab token id, built once
    /// per load the first time token healing runs. The heal mask in the decode
    /// loop compares every vocab token's piece against the not-yet-derived
    /// partial word; without this cache that was an O(nVocab)
    /// `llama_token_to_piece` FFI call + String allocation on EVERY healing step
    /// (the dominant mid-word cost). The piece for a token id is deterministic,
    /// so caching is byte-identical to recomputing it per step. Reset on `load`.
    private var healPieceCache: [String]?

    /// Noise-robustness tuning for the corpus logit bias (see the decode loop).
    /// `nucleusMargin` : a corpus candidate is only boosted if its logit is
    /// within this many units of the top logit (already plausible to the model).
    /// `minBiasCount` : ignore corpus candidates seen fewer times (one-offs are
    /// noise). `maxBiasBoost` : cap the additive boost so a high count can't
    /// blow a token past the nucleus gate. Calibrated against the probe's
    /// polluted-vs-clean corpus A/B (Experiment 8/9).
    static let nucleusMargin: Float = 8.0
    static let minBiasCount: Int = 2
    static let maxBiasBoost: Float = 6.0

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
        // New vocab ⇒ rebuild the ban sets on next demand.
        markupBannedTokens = nil
        digitBannedTokens = nil
        emojiBannedTokens = nil
        healPieceCache = nil
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

    /// Builds (once) and returns the list of vocab token ids whose decoded
    /// piece contains a web-markup character. Scans the full vocab — O(nVocab)
    /// `token_to_piece` calls — but only on the first `banMarkup` generation
    /// after a load; the result is cached on the actor.
    private func markupBanList() -> [Int32] {
        if let cached = markupBannedTokens { return cached }
        guard let h = handles else { return [] }
        let markup: Set<Character> = ["<", ">", "`", "*", "#", "~"]
        let nVocab = llama_vocab_n_tokens(h.vocab)
        var ids: [Int32] = []
        ids.reserveCapacity(2048)
        var id: Int32 = 0
        while id < nVocab {
            let p = piece(id)
            if p.contains(where: { markup.contains($0) }) {
                ids.append(id)
            }
            id += 1
        }
        markupBannedTokens = ids
        Log.info(.predictor, "markup_ban_built", count: ids.count)
        return ids
    }

    /// Builds (once) and returns the list of vocab token ids whose decoded
    /// piece contains an ASCII digit. Same one-shot vocab scan as the markup set.
    private func digitBanList() -> [Int32] {
        if let cached = digitBannedTokens { return cached }
        guard let h = handles else { return [] }
        let nVocab = llama_vocab_n_tokens(h.vocab)
        var ids: [Int32] = []
        ids.reserveCapacity(4096)
        var id: Int32 = 0
        while id < nVocab {
            if piece(id).contains(where: { $0.isASCII && $0.isNumber }) {
                ids.append(id)
            }
            id += 1
        }
        digitBannedTokens = ids
        Log.info(.predictor, "digit_ban_built", count: ids.count)
        return ids
    }

    /// Builds (once) and returns vocab token ids whose decoded piece contains an
    /// emoji / pictograph scalar. Uses Unicode scalar properties (emoji
    /// presentation, or scalar ≥ U+1F000) so ASCII like `#`/`*` is NOT caught
    /// here (those are the markup set's job).
    private func emojiBanList() -> [Int32] {
        if let cached = emojiBannedTokens { return cached }
        guard let h = handles else { return [] }
        func isEmoji(_ c: Character) -> Bool {
            c.unicodeScalars.contains { s in
                s.properties.isEmojiPresentation || s.value >= 0x1F000
                    || (0x2190...0x2BFF).contains(s.value)   // arrows, symbols, dingbats
            }
        }
        let nVocab = llama_vocab_n_tokens(h.vocab)
        var ids: [Int32] = []
        var id: Int32 = 0
        while id < nVocab {
            if piece(id).contains(where: isEmoji) { ids.append(id) }
            id += 1
        }
        emojiBannedTokens = ids
        Log.info(.predictor, "emoji_ban_built", count: ids.count)
        return ids
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

    /// Token-healing piece normalization. SentencePiece marks a word boundary
    /// with the metaspace `▁` (U+2581). llama.cpp's `llama_token_to_piece`
    /// usually renders that as a literal leading space, but we normalize BOTH
    /// the literal `▁` and a literal leading space to nothing so the result is
    /// the raw text the token contributes to the surface string (e.g. "fiscal",
    /// "cal", "rm"). Used to compare a candidate token against the still-typed
    /// partial word during healing — only ever called while healing is active,
    /// so it adds zero cost to the normal path.
    private func healPiece(_ token: Int32) -> String {
        var p = piece(token)
        p = p.replacingOccurrences(of: "\u{2581}", with: " ")
        if p.first == " " { p.removeFirst() }
        return p
    }

    /// Builds (once per load) the metaspace-normalized `healPiece` for EVERY
    /// vocab token id and caches it on the actor. The token-healing mask reads
    /// this array instead of calling `llama_token_to_piece` + allocating a
    /// String for every id on every healing step. Same one-shot O(nVocab) vocab
    /// scan as the ban-set builders; the result is byte-identical to calling
    /// `healPiece(id)` per id (a token id always decodes to the same piece).
    /// Reset to nil on `load`.
    private func healPieceList() -> [String] {
        if let cached = healPieceCache { return cached }
        guard let h = handles else { return [] }
        let nVocab = Int(llama_vocab_n_tokens(h.vocab))
        var arr = [String](repeating: "", count: nVocab)
        var id: Int32 = 0
        while id < Int32(nVocab) {
            arr[Int(id)] = healPiece(id)
            id += 1
        }
        healPieceCache = arr
        Log.info(.predictor, "heal_piece_cache_built", count: nVocab)
        return arr
    }

    /// Counts tokens for a piece of text (used for coarse budgeting). Cheap
    /// wrapper over `tokenize`.
    public func countTokens(_ text: String) -> Int {
        tokenize(text, addSpecial: false).count
    }

    /// Counts tokens for `text` WITH the BOS/special prefix — i.e. exactly how
    /// `generate` tokenises a prompt. Test/probe seam for asserting KV
    /// bookkeeping against the resident sequence length.
    public func countTokensWithBOS(_ text: String) -> Int {
        tokenize(text, addSpecial: true).count
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

        // ── Token healing (experiment, opt-in) ───────────────────────────────
        // When `healPrefix` is non-empty the prompt ends mid-word; the trailing
        // partial tokenized to ONE complete token, freeing the model to derive a
        // DIFFERENT word ("Rapport fis" → "fiscaal"). We walk back from the END
        // of promptTokens, accumulating the (metaspace-normalized) pieces, until
        // the accumulated suffix COVERS the partial word, then pop that run. The
        // popped text (clamped to the actual partial) seeds `remainingHeal`,
        // which the decode loop consumes by masking non-prefix-compatible
        // tokens. `nil`/empty ⇒ this whole block is skipped (byte-identical).
        var remainingHeal = ""
        if let heal = sampling.healPrefix, !heal.isEmpty, promptTokens.count > 1 {
            var acc = ""
            var popCount = 0
            // Accumulate from the tail until the partial word is fully covered.
            // Cap the walk so a pathological vocab can't pop the whole prompt.
            let maxPop = min(promptTokens.count - 1, 8)
            while popCount < maxPop {
                let p = healPiece(promptTokens[promptTokens.count - 1 - popCount])
                acc = p + acc
                popCount += 1
                if acc.hasSuffix(heal) || acc.count >= heal.count { break }
            }
            // Only heal if the popped run actually ends with the partial word
            // (i.e. the boundary is where we expect). If the accumulated suffix
            // is shorter than the partial (no token covered it), skip healing.
            if popCount > 0, acc.hasSuffix(heal) {
                promptTokens.removeLast(popCount)
                remainingHeal = heal
                Log.info(.predictor, "token_heal_pop", count: popCount)
            }
        }

        // Dev-only boundary debug (DUMP_PROMPT): dump the last ~6 prompt tokens
        // with their pieces to stderr so the trailing-token boundary that healing
        // pops can be eyeballed. Gated on an env var; no production code path.
        if ProcessInfo.processInfo.environment["DUMP_PROMPT"] != nil {
            let n = promptTokens.count
            let tail = promptTokens.suffix(6)
            var lines = "TAIL TOKENS (post-heal, n=\(n), remainingHeal=\(remainingHeal.debugDescription)):\n"
            for t in tail { lines += "  [\(t)] \(piece(t).debugDescription)\n" }
            FileHandle.standardError.write(Data(lines.utf8))
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
            // Tail trimming BEFORE temperature so we sample from a clean nucleus.
            // Disabled stages (== 0) are simply not added.
            if sampling.topK > 0 {
                llama_sampler_chain_add(sampler, llama_sampler_init_top_k(sampling.topK))
            }
            if sampling.topP > 0 {
                llama_sampler_chain_add(sampler, llama_sampler_init_top_p(sampling.topP, 1))
            }
            if sampling.minP > 0 {
                llama_sampler_chain_add(sampler, llama_sampler_init_min_p(sampling.minP, 1))
            }
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
        // Markup / digit ban : precompute the lists once. Markup + full digit
        // ban apply every step ; leading-only digit ban applies on produced==0.
        let alwaysBan: [Int32] = (sampling.banMarkup ? markupBanList() : [])
            + (sampling.banDigits ? digitBanList() : [])
            + (sampling.banEmoji ? emojiBanList() : [])
        let leadingBan: [Int32] = (sampling.banDigitsLeading && !sampling.banDigits)
            ? digitBanList() : []
        let banActive = !alwaysBan.isEmpty || !leadingBan.isEmpty
        // Token-healing mask is active only while there are dropped characters
        // left to re-derive (`!remainingHeal.isEmpty`, re-checked each step since
        // `remainingHeal` shrinks as the partial word is consumed). Once empty
        // the loop reverts to normal unconstrained generation.
        let useSuffixArray = !corpusSuffixArray.isEmpty
        // Sliding window of recently-decoded token ids (prompt tail + emitted)
        // used to compute the current corpus-match context. The suffix array
        // matches up to `maxMatchLen` tokens, so we keep that many ; the fixed
        // n-gram fallback only ever reads the last two.
        let windowLen = LlamaCorpusSuffixArray.maxMatchLen
        var recentIds: [Int32] = biasActive ? Array(promptTokens.suffix(windowLen)) : []

        // Token-healing piece cache (built once per load, reused across calls).
        // Empty unless healing is active for THIS generation — `remainingHeal`
        // only ever shrinks, so if it is empty now it stays empty and we never
        // touch the cache. When active, the heal mask reads this array instead
        // of an `llama_token_to_piece` FFI call per vocab id per step.
        let healPieces: [String] = remainingHeal.isEmpty ? [] : healPieceList()

        while produced < maxTokens {
            if Task.isCancelled { break }

            // Context-dependent corpus boost : add `strength * log(1+count)`
            // to each candidate next-token's logit BEFORE sampling, so the
            // sampler chain (penalties + greedy/temp) reads the modified
            // distribution.
            if (biasActive || banActive || !remainingHeal.isEmpty),
               let logits = llama_get_logits_ith(h.context, -1) {
                // Markup ban : force web-markup tokens to -inf so they can never
                // be sampled (kills `<strong>`, fenced code, etc. at the source).
                if banActive {
                    for id in alwaysBan { logits[Int(id)] = -Float.infinity }
                    if produced == 0 {
                        for id in leadingBan { logits[Int(id)] = -Float.infinity }
                    }
                }
                // Token-healing mask : while the dropped partial word is not yet
                // re-derived, force every vocab token whose (metaspace-normalized)
                // piece is NOT prefix-compatible with `remainingHeal` to -inf, so
                // greedy is forced to walk the correct merged token at a clean
                // boundary. Prefix-compatible = piece starts with remainingHeal
                // (token overshoots / completes the word, e.g. "fis"→"fiscal") OR
                // remainingHeal starts with piece (token is a sub-fragment of the
                // partial, e.g. "fis"→"fi"). Direct O(nVocab) scan — fine for the
                // experiment. Mid-word ⇒ we also exclude the empty / whitespace-
                // only piece so we never re-introduce the boundary we just removed.
                if !remainingHeal.isEmpty {
                    // Cached per-token pieces (built once per load) — the inner
                    // compatibility test is now a pure array read, no FFI / no
                    // String alloc per id. Byte-identical to the old per-id
                    // `healPiece(id)` scan.
                    let n = healPieces.count
                    var i = 0
                    while i < n {
                        let p = healPieces[i]
                        let compatible = !p.isEmpty
                            && (p.hasPrefix(remainingHeal) || remainingHeal.hasPrefix(p))
                        if !compatible { logits[i] = -Float.infinity }
                        i += 1
                    }
                }
              if biasActive {
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
                // ── Noise-robust corpus bias ─────────────────────────────────
                // A polluted corpus (junk ghosts accepted during debugging)
                // must NOT be able to drag the output toward words the model
                // would never produce. Three guards make the bias degrade
                // gracefully when the corpus is low-quality:
                //   1. matchLen ≥ 2 — only steer on a real multi-token context
                //      match, never a single-token coincidence.
                //   2. count ≥ minCount — a one-off accepted entry (count 1) is
                //      noise, not a pattern; it never biases.
                //   3. NUCLEUS GATE — only boost a corpus candidate whose model
                //      logit is already within `nucleusMargin` of the top logit,
                //      i.e. a token the model ALREADY finds plausible. This is
                //      the key guard: the corpus can re-rank plausible
                //      candidates but can never inject an implausible junk token
                //      ("…de la viande" ↛ "meufs"). Additionally the per-token
                //      boost is capped so a huge count can't blow past the gate.
                if !candidates.isEmpty && matchLen >= 2 {
                    let nVocab = llama_vocab_n_tokens(h.vocab)
                    // Top logit (plausibility reference). Gemma 3 1B vocab is
                    // ~256k entries; a Swift `for` scan costs ~15ms per biased
                    // step on M2 (measured 2026-05-28 ablation bench: with-perso
                    // ran +327ms over with-ocr for 16 generated tokens, ≈20ms
                    // per step). `vDSP_maxv` does the same reduction with SIMD
                    // and drops the per-step cost to <1ms — same algorithm,
                    // byte-identical output for the bias decision.
                    var topLogit: Float = -Float.greatestFiniteMagnitude
                    vDSP_maxv(logits, 1, &topLogit, vDSP_Length(nVocab))
                    let margin = sampling.nucleusMargin > 0 ? sampling.nucleusMargin : Self.nucleusMargin
                    let floor = topLogit - margin
                    let sharpen = 1.0 + 0.5 * Float(max(0, matchLen - 1))
                    for (id, count) in candidates
                        where id >= 0 && id < nVocab && count >= Self.minBiasCount {
                        let i = Int(id)
                        guard logits[i] >= floor else { continue }   // implausible → skip
                        let boost = min(Self.maxBiasBoost,
                                        strength * sharpen * logf(Float(count)))
                        logits[i] += boost
                    }
                }
              }  // if biasActive
            }  // if (biasActive || banActive || healing)

            let tokenId = llama_sampler_sample(sampler, h.context, -1)
            if llama_vocab_is_eog(h.vocab, tokenId) { break }

            // Token-healing bookkeeping : subtract the just-sampled piece from
            // the not-yet-consumed partial. If the piece covers (or overshoots)
            // the remainder, healing is complete and the mask turns off; if it's
            // a sub-fragment, drop the consumed prefix and keep masking on the
            // next step. The mask above guaranteed prefix-compatibility, so one
            // of these two branches always applies.
            if !remainingHeal.isEmpty {
                // `healPieces` is non-empty here (remainingHeal was non-empty at
                // loop entry, which is what built it) and tokenId is a valid id.
                let p = healPieces[Int(tokenId)]
                if p.count >= remainingHeal.count {
                    remainingHeal = ""           // fully consumed (or overshot)
                } else {
                    remainingHeal.removeFirst(p.count)  // sub-fragment consumed
                }
            }

            // Confidence gate (Cotypist `minBranchProbability` parity). On the
            // FIRST token only, compute the softmax probability the model gave
            // the token it actually chose. The logits at position -1 are still
            // the ones the sampler just read (we haven't decoded the new token
            // yet), so this is exact — including any ban (-inf) / corpus bias
            // already applied in place above. A low value means the model is
            // guessing (mid-word word-identity ambiguity, or a language flip);
            // we abort with zero tokens so no ghost is shown.
            if produced == 0, sampling.minFirstTokenProb > 0,
               let logits = llama_get_logits_ith(h.context, -1) {
                let nVocab = Int(llama_vocab_n_tokens(h.vocab))
                var maxLogit = -Float.greatestFiniteMagnitude
                for i in 0..<nVocab where logits[i] > maxLogit { maxLogit = logits[i] }
                var sumExp: Double = 0
                for i in 0..<nVocab {
                    let l = logits[i]
                    if l > -Float.greatestFiniteMagnitude { sumExp += Double(expf(l - maxLogit)) }
                }
                let prob = sumExp > 0 ? Double(expf(logits[Int(tokenId)] - maxLogit)) / sumExp : 0
                metrics.firstTokenProb = prob
                if prob < Double(sampling.minFirstTokenProb) { break }
            }

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
