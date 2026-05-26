import Foundation
import MLX
import MLXLLM
import MLXLMCommon

struct BenchCase: Sendable {
    let label: String
    let prompt: String
    let lang: String
}

@main
struct Bench {
    /// Quantization A/B: same base (Gemma 3 1B PT), different precisions.
    /// 8-bit and bf16 will be downloaded on first run if missing.
    static let models: [(id: String, label: String)] = [
        ("mlx-community/gemma-3-1b-pt-4bit", "4-bit"),
        ("mlx-community/gemma-3-1b-pt-8bit", "8-bit"),
        ("mlx-community/gemma-3-1b-pt-bf16", "bf16"),
    ]

    static let cases: [BenchCase] = [
        BenchCase(
            label: "Ferme d' (cas réel utilisateur)",
            prompt: "Ferme d'",
            lang: "fr"
        ),
        BenchCase(
            label: "Ferme d'anim",
            prompt: "Ferme d'anim",
            lang: "fr"
        ),
        BenchCase(
            label: "FR — mail pro",
            prompt: "Bonjour Marie,\n\nJe te confirme notre rendez-vous de demain 14h. Je",
            lang: "fr"
        ),
        BenchCase(
            label: "EN — slack casual",
            prompt: "hey team, quick update on the deploy — we're going to",
            lang: "en"
        ),
        BenchCase(
            label: "FR/EN — code-switching",
            prompt: "Hey, j'ai poussé le fix sur staging, can you",
            lang: "mixed"
        ),
        BenchCase(
            label: "FR — note longue",
            prompt: "Réunion produit du 21 mai. Les sujets abordés : (1) refonte de l'onboarding, (2)",
            lang: "fr"
        ),
    ]

    static func main() async {
        setbuf(stdout, nil)
        setbuf(stderr, nil)

        emit("──────────────────────────────────────────────")
        emit(" Souffleuse Bench — quantization A/B           ")
        emit(" Base : Gemma 3 1B PT · greedy (temp=0)        ")
        emit("──────────────────────────────────────────────")

        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)

        // Per-(case, model) outputs for the final side-by-side table.
        var matrix: [String: [String: String]] = [:]
        // Per-model load + throughput stats.
        var perfRows: [(model: String, loadSec: Double, avgTTFT: Int, avgTPS: Double)] = []

        for (mIdx, m) in models.enumerated() {
            emit("\n══ [\(mIdx + 1)/\(models.count)] \(m.label) — \(m.id) ══")
            let configuration = ModelConfiguration(id: m.id, defaultPrompt: "")

            emit("Chargement…")
            let loadStart = Date()
            let container: ModelContainer
            do {
                container = try await LLMModelFactory.shared.loadContainer(configuration: configuration) { progress in
                    let pct = Int(progress.fractionCompleted * 100)
                    if pct % 25 == 0 { emit("  download: \(pct) %") }
                }
            } catch {
                emit("ERREUR chargement \(m.label) : \(error)")
                continue
            }
            let loadElapsed = Date().timeIntervalSince(loadStart)
            emit("  prêt en \(String(format: "%.1f", loadElapsed)) s")

            var ttfts: [Int] = []
            var tpss: [Double] = []

            for (idx, c) in cases.enumerated() {
                emit("\n  ─── \(idx + 1)/\(cases.count) — \(c.label) [\(c.lang)] ───")
                let shortPrompt = c.prompt.replacingOccurrences(of: "\n", with: " ⏎ ")
                emit("  prompt : \(shortPrompt)")
                if let r = await runCase(c, on: container) {
                    let suffix = r.text.replacingOccurrences(of: "\n", with: " ⏎ ")
                    emit("  suffixe: \"\(suffix)\"")
                    emit("  TTFT   : \(r.ttftMs) ms · \(String(format: "%.1f", r.tps)) tok/s")
                    matrix[c.label, default: [:]][m.label] = suffix
                    if r.ttftMs >= 0 { ttfts.append(r.ttftMs) }
                    if r.tps > 0 { tpss.append(r.tps) }
                } else {
                    matrix[c.label, default: [:]][m.label] = "<ERROR>"
                }
            }

            let avgTTFT = ttfts.isEmpty ? -1 : ttfts.reduce(0, +) / ttfts.count
            let avgTPS = tpss.isEmpty ? 0 : tpss.reduce(0, +) / Double(tpss.count)
            perfRows.append((m.label, loadElapsed, avgTTFT, avgTPS))
        }

        // Side-by-side dump
        emit("\n\n──────────────────────────────────────────────")
        emit(" Comparaison side-by-side                      ")
        emit("──────────────────────────────────────────────")
        for c in cases {
            emit("\n[\(c.label)]")
            emit("  prompt: \(c.prompt.replacingOccurrences(of: "\n", with: " ⏎ "))")
            for m in models {
                let out = matrix[c.label]?[m.label] ?? "<no data>"
                emit("  \(m.label.padding(toLength: 6, withPad: " ", startingAt: 0)) → \"\(out)\"")
            }
        }

        // Perf summary
        emit("\n──────────────────────────────────────────────")
        emit(" Perf moyenne par modèle                       ")
        emit("──────────────────────────────────────────────")
        emit(" model  | load(s) | avg TTFT | avg tok/s")
        for r in perfRows {
            let load = String(format: "%6.1f", r.loadSec)
            let ttft = r.avgTTFT >= 0 ? "\(r.avgTTFT) ms" : "n/a"
            let tps = String(format: "%.1f", r.avgTPS)
            emit(" \(r.model.padding(toLength: 6, withPad: " ", startingAt: 0)) | \(load)  | \(ttft.padding(toLength: 8, withPad: " ", startingAt: 0)) | \(tps)")
        }

        emit("\n──────────────────────────────────────────────")
        emit(" Bench terminé.                                ")
        emit("──────────────────────────────────────────────")
    }

    struct CaseResult {
        let text: String
        let ttftMs: Int
        let tps: Double
    }

    static func runCase(_ c: BenchCase, on container: ModelContainer) async -> CaseResult? {
        let start = Date()
        do {
            return try await container.perform { context -> CaseResult in
                // PT models: raw text continuation. No chat template, matches what
                // Souffleuse's predict() does on the production path.
                let promptTokens = context.tokenizer.encode(text: c.prompt)
                let input = LMInput(tokens: MLXArray(promptTokens))
                // Greedy decoding to match Souffleuse's prod config.
                let params = GenerateParameters(
                    maxTokens: 24,
                    temperature: 0,
                    topP: 0.9,
                    repetitionPenalty: 1.15,
                    repetitionContextSize: 32
                )
                let stream = try MLXLMCommon.generate(input: input, parameters: params, context: context)

                var firstTokenAt: Date?
                var generated = ""
                var tokenCount = 0

                for await event in stream {
                    if case .chunk(let text) = event {
                        if firstTokenAt == nil { firstTokenAt = Date() }
                        tokenCount += 1
                        generated += text
                    }
                }

                let ttft: Int
                let tps: Double
                if let first = firstTokenAt {
                    ttft = Int(first.timeIntervalSince(start) * 1000)
                    let elapsed = Date().timeIntervalSince(first)
                    tps = elapsed > 0 ? Double(tokenCount) / elapsed : 0
                } else {
                    ttft = -1
                    tps = 0
                }
                return CaseResult(text: generated, ttftMs: ttft, tps: tps)
            }
        } catch {
            emit("  ERREUR : \(error)")
            return nil
        }
    }
}

@Sendable func emit(_ s: String) {
    let line = s + "\n"
    FileHandle.standardOutput.write(Data(line.utf8))
}
