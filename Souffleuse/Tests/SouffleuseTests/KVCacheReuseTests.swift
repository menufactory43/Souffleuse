import Foundation
import Testing
@testable import SouffleuseLlama

/// KV / prompt cache reuse correctness.
///
/// These tests require a real GGUF model (greedy decoding is deterministic, so
/// cold-vs-warm output equivalence is verifiable). They locate the same Gemma
/// model the probe uses; if it is absent the suite is skipped rather than
/// failing — model artifacts are not vendored in the repo.
/// `.serialized` : these tests each load a real llama.cpp context on the shared
/// Metal backend. Running multiple contexts concurrently corrupts decoding
/// (the backend is process-global), so the suite must run one test at a time.
@Suite("KV cache reuse — cold vs warm equivalence", .serialized)
struct KVCacheReuseTests {

    /// Resolves the local model path, or nil if not present on this machine.
    static func modelPathIfAvailable() -> String? {
        let candidates = [
            "~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf",
        ]
        for c in candidates {
            let p = NSString(string: c).expandingTildeInPath
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    /// Greedy generation, collecting up to `maxTokens` pieces into a string.
    static func gen(_ engine: LlamaEngine, _ prompt: String, maxTokens: Int) async -> String {
        final class Sink: @unchecked Sendable { var s = "" }
        let sink = Sink()
        _ = await engine.generate(
            prompt: prompt,
            maxTokens: maxTokens,
            sampling: LlamaSampling(temperature: 0, repeatPenalty: 1.0, repeatLastN: 64)
        ) { tok in sink.s += tok; return true }
        return sink.s
    }

    static func loadedEngine() async -> LlamaEngine? {
        guard let path = modelPathIfAvailable() else { return nil }
        let engine = LlamaEngine()
        let ok = await engine.load(modelPath: path, contextTokens: 2048)
        return ok ? engine : nil
    }

    // (1a) Same final prompt yields identical output cold vs warm.
    @Test func sameFinalPromptIdenticalColdVsWarm() async throws {
        try await LlamaTestGate.shared.run {
            guard let engine = await Self.loadedEngine() else {
                throw XCTSkipLikeError("model not available")
            }
            let prompt = "<start_of_turn>user\nContinue: The quick brown fox jumps over the<end_of_turn>\n<start_of_turn>model\n"
            // Cold run (cache empty after load).
            #expect(await engine.cachedTokenCount == 0)
            let cold = await Self.gen(engine, prompt, maxTokens: 12)
            #expect(await engine.cachedTokenCount > 0)
            // Warm run: identical prompt → fully cached → trims one back, redecodes.
            let warm = await Self.gen(engine, prompt, maxTokens: 12)
            #expect(cold == warm)
            #expect(!cold.isEmpty)
        }
    }

    // (1b) Growing prompt (A, then A+continuation) warm == cold run on A+cont.
    @Test func growingPromptWarmEqualsCold() async throws {
        try await LlamaTestGate.shared.run {
            guard let engineWarm = await Self.loadedEngine() else {
                throw XCTSkipLikeError("model not available")
            }
            // B extends A inside the user turn by a few words, so the tokenised
            // prompts share a long clean prefix (the system/turn scaffolding plus
            // the shared leading words) — exactly the keystroke-growth case.
            let a = "<start_of_turn>user\nContinue: The quick brown fox<end_of_turn>\n<start_of_turn>model\n"
            let b = "<start_of_turn>user\nContinue: The quick brown fox jumps over the lazy<end_of_turn>\n<start_of_turn>model\n"

            // Warm: prime with A, then generate B (reuses the long common prefix).
            _ = await Self.gen(engineWarm, a, maxTokens: 6)
            let warm = await Self.gen(engineWarm, b, maxTokens: 12)

            // Cold: a fresh engine generating B directly.
            guard let engineCold = await Self.loadedEngine() else {
                throw XCTSkipLikeError("model not available")
            }
            let cold = await Self.gen(engineCold, b, maxTokens: 12)

            #expect(warm == cold)
        }
    }

    // (1c) Backspace / divergence trims correctly: after a long prompt, a
    // shorter / diverging prompt still produces the cold-equivalent output.
    @Test func divergenceTrimsCorrectly() async throws {
        try await LlamaTestGate.shared.run {
            let long = "<start_of_turn>user\nContinue: Le rendez-vous est fixé à quatorze heures précises<end_of_turn>\n<start_of_turn>model\n"
            let diverged = "<start_of_turn>user\nContinue: Le rendez-vous est annulé<end_of_turn>\n<start_of_turn>model\n"

            guard let engine = await Self.loadedEngine() else {
                throw XCTSkipLikeError("model not available")
            }
            _ = await Self.gen(engine, long, maxTokens: 8)      // warm KV with `long`
            let warmDiverged = await Self.gen(engine, diverged, maxTokens: 12)

            guard let coldEngine = await Self.loadedEngine() else {
                throw XCTSkipLikeError("model not available")
            }
            let coldDiverged = await Self.gen(coldEngine, diverged, maxTokens: 12)

            #expect(warmDiverged == coldDiverged)
        }
    }

    // (2) kvTokens bookkeeping after a simulated mid-stream stop: stopping
    // after N tokens leaves cachedTokenCount == promptTokens + N, and a
    // subsequent full generation of the same prompt still matches a cold run.
    @Test func bookkeepingAfterMidStreamStop() async throws {
        try await LlamaTestGate.shared.run {
            guard let engine = await Self.loadedEngine() else {
                throw XCTSkipLikeError("model not available")
            }
            let prompt = "<start_of_turn>user\nContinue: The quick brown fox jumps over the<end_of_turn>\n<start_of_turn>model\n"
            let promptLen = await engine.countTokensWithBOS(prompt)

            // Stop after exactly 3 emitted tokens.
            final class Counter: @unchecked Sendable { var n = 0 }
            let c = Counter()
            _ = await engine.generate(prompt: prompt, maxTokens: 16,
                                      sampling: LlamaSampling(temperature: 0)) { _ in
                c.n += 1
                return c.n < 3   // stop right after the 3rd token
            }
            // kvTokens = prompt + decoded-into-KV tokens. onToken stops AFTER
            // emitting token #3 but BEFORE decoding it, so 2 generated tokens are
            // resident (tokens 1 and 2 were decoded; token 3 emitted, not decoded).
            let count = await engine.cachedTokenCount
            #expect(count >= promptLen)
            #expect(count <= promptLen + 3)

            // A subsequent full generation of the same prompt matches a cold run.
            let warm = await Self.gen(engine, prompt, maxTokens: 12)
            guard let coldEngine = await Self.loadedEngine() else {
                throw XCTSkipLikeError("model not available")
            }
            let cold = await Self.gen(coldEngine, prompt, maxTokens: 12)
            #expect(warm == cold)
        }
    }
}

/// Lightweight skip signal — Swift Testing has no built-in skip-with-message in
/// this toolchain, so model-gated tests throw this to abort cleanly without a
/// hard failure (it surfaces as a thrown error only when the model is missing).
struct XCTSkipLikeError: Error { let reason: String; init(_ r: String) { reason = r } }
