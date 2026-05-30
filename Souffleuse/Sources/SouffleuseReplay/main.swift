import Foundation
import SouffleuseCore
import SouffleuseLlama
import SouffleuseLog
import SouffleusePersonalization
import SouffleuseTyping

// SouffleuseReplay — offline driver for the REAL autocomplete pipeline.
//
// It drives the same pieces the live app uses — `SuggestionPolicyEngine`
// (routeInstant + onLLMChunk), `LlamaPromptBuilder`, the real `LlamaEngine`
// loading the real GGUF, `ChunkFilter`, and the real encrypted typing history
// via `TypingHistoryStore` — over a list of typed-prefix sequences (parsed from
// the live predict debug log, or a hardcoded French fallback). For each tail it
// prints `userTail → ghost [source]`.
//
// FIDELITY NOTE: this mirrors `PredictorViewModel.predict`'s LLM path, NOT the
// cache layers. predictCache / undoCache are deliberately OMITTED (they only
// absorb the "type space → backspace" regen cycle and are irrelevant to a
// single-shot offline replay). Everything else — instant routing, bare prompt,
// sampler config, per-token ChunkFilter + lastEmitted rule, the relevance gate
// — is reproduced from the live code path.

// MARK: - Configuration (mirrors PVM / generateLlama defaults)

let kMaxWords = 8            // PVM default completion-length cap
let kMaxTokens = 48          // generation cap for the replay
let kGGUFPath = ("~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf" as NSString)
    .expandingTildeInPath

/// Personalization (NgramLogitBias) strength used at inference. Defaults to 0
/// for backward-compat with the historical "replay: no personalization gain"
/// behavior. Set `SOUFFLEUSE_REPLAY_STRENGTH` to a Float to reproduce the
/// live runtime default (1.0) or to A/B the bias effect.
let kPersonalizationStrength: Float = {
    if let s = ProcessInfo.processInfo.environment["SOUFFLEUSE_REPLAY_STRENGTH"],
       let f = Float(s) { return f }
    return 0
}()

/// Repetition-penalty knobs — env-overridable for the Cotypist-parity
/// investigation. Defaults mirror generateLlama PROD (1.3 / 64). Hypothesis:
/// a high penalty over a window that includes the prompt context penalises
/// context-echo ("fiscale" on screen → model avoids "fiscal"). Override:
///   SOUFFLEUSE_REPLAY_REPEAT_PENALTY=1.0 SOUFFLEUSE_REPLAY_REPEAT_LAST_N=0
let kRepeatPenalty: Float = {
    if let s = ProcessInfo.processInfo.environment["SOUFFLEUSE_REPLAY_REPEAT_PENALTY"],
       let f = Float(s) { return f }
    return 1.3
}()
let kRepeatLastN: Int32 = {
    if let s = ProcessInfo.processInfo.environment["SOUFFLEUSE_REPLAY_REPEAT_LAST_N"],
       let n = Int32(s) { return n }
    return 64
}()

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

// MARK: - JSON scenario schema

/// Minimal scenario shape for JSON-driven replay. Mirrors the relevant fields
/// of `SouffleuseCoherence`'s schema but kept local so SouffleuseReplay doesn't
/// take a new module dependency. The cascade still consults the real
/// TypingHistoryStore (Keychain-backed) for L0/L1 routing — only the LLM
/// prompt's context prefix is injected from JSON.
struct Scenario: Decodable {
    let id: String
    let label: String?
    let app: String?
    let windowTitle: String?
    let visibleText: String?
    let userTail: String
}

struct ScenarioFile: Decodable {
    let version: Int
    let scenarios: [Scenario]
}

/// Reproduces the relevant subset of `EnrichedContext.prefix` (compact prose,
/// no `[Label:]` syntax) so the model receives the same shape it would in the
/// running app, without taking a SouffleuseContext dependency.
func buildCtxPrefix(_ s: Scenario) -> String {
    var bits: [String] = []
    if let app = s.app, !app.isEmpty {
        if let title = s.windowTitle, !title.isEmpty {
            bits.append("App \(app), window \"\(title)\".")
        } else {
            bits.append("App \(app).")
        }
    }
    if let v = s.visibleText, !v.isEmpty {
        bits.append("On screen: \(v).")
    }
    return bits.joined(separator: " ")
}

func loadScenarios(_ path: String) -> [Scenario]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    do {
        let file = try JSONDecoder().decode(ScenarioFile.self, from: data)
        return file.scenarios
    } catch {
        err("FATAL: could not decode scenarios JSON at \(path): \(error)")
        return nil
    }
}

// MARK: - Typed-prefix corpus

/// Hardcoded French fallback prefixes when the predict log is missing.
let fallbackTails: [String] = [
    "Bonjour, je vous écris pour ",
    "Merci beaucoup pour votre ",
    "Je reviens vers vous concernant ",
    "Coucou, ceci est un test et je ",
    "Aujourd'hui je voudrais ",
    "Pourriez-vous me confirmer ",
    "Je suis désolé pour le ",
    "N'hésitez pas à me ",
]

/// Unescapes a `debugDescription`-style quoted body (`\"`, `\n`, `\t`, `\\`, `\'`).
func unescapeDebug(_ s: String) -> String {
    var out = ""
    var it = s.makeIterator()
    var pending: Character? = nil
    func next() -> Character? {
        if let p = pending { pending = nil; return p }
        return it.next()
    }
    while let c = next() {
        if c == "\\" {
            guard let n = next() else { out.append(c); break }
            switch n {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "\"": out.append("\"")
            case "'": out.append("'")
            case "\\": out.append("\\")
            default: out.append(n)
            }
        } else {
            out.append(c)
        }
    }
    return out
}

/// Parses `predict_called userTail="..."` lines from the live predict debug
/// log into a distinct, order-preserving list of userTails (capped ~150).
func parsePredictLog(_ path: String) -> [String] {
    guard let data = FileManager.default.contents(atPath: path),
          let text = String(data: data, encoding: .utf8) else { return [] }
    var seen = Set<String>()
    var tails: [String] = []
    for line in text.split(whereSeparator: { $0 == "\n" }) {
        guard let r = line.range(of: "userTail=\"") else { continue }
        let afterOpen = line[r.upperBound...]
        // Find the closing unescaped quote.
        var body = ""
        var idx = afterOpen.startIndex
        var escaped = false
        while idx < afterOpen.endIndex {
            let ch = afterOpen[idx]
            if escaped {
                body.append("\\"); body.append(ch); escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                break
            } else {
                body.append(ch)
            }
            idx = afterOpen.index(after: idx)
        }
        let tail = unescapeDebug(body)
        if tail.trimmingCharacters(in: .whitespaces).count >= 3, !seen.contains(tail) {
            seen.insert(tail)
            tails.append(tail)
            if tails.count >= 150 { break }
        }
    }
    return tails
}

// MARK: - Pipeline mirror

/// Reproduces `generateLlama`'s caret derivation + sampler config, runs the
/// engine, and applies `ChunkFilter` per token with the same `lastEmitted`
/// "emit only when changed" rule to produce the final one-line LLM ghost.
func runLLM(
    engine: LlamaEngine,
    userTail: String,
    ctxPrefix: String = ""
) async -> String {
    // BARE prompt by default — empty system / ctx / field / customInstr. JSON
    // mode injects `ctxPrefix` so the model sees the same "App X, window Y"
    // shape it would in the live app. `beforeCursor` = userTail.
    let prompt = LlamaPromptBuilder.buildLlamaPrompt(
        system: "",
        customInstr: "",
        ctxPrefix: ctxPrefix,
        fieldContext: "",
        afterCursor: "",
        beforeCursor: userTail
    )
    if ProcessInfo.processInfo.environment["DUMP_PROMPT"] != nil {
        err("=== PROMPT for \(userTail.debugDescription) (rp=\(kRepeatPenalty) rln=\(kRepeatLastN)) ===\n\(prompt)\n=== END PROMPT ===")
    }
    // Caret derivation — verbatim from generateLlama.
    let caretAfterSpace = userTail.last == " " || userTail.last == "\t"
    let caretMidWord = userTail.last.map { $0.isLetter || $0.isNumber } ?? false
    let minFirstTokenProb: Float = caretMidWord ? LlamaPromptBuilder.midWordMinFirstTokenProb : 0

    // TOKEN HEALING — mirrors production `generateLlama` exactly: mid-word, drop
    // the trailing partial-word token(s) from the prompt and re-derive the merged
    // token at a clean boundary (see LlamaSampling.healPrefix). Gated on the same
    // `Tuning.midWordHealingEnabled` flag the app uses, so the replay's LLM path
    // is faithful to what the live app generates. `NOHEAL=1` forces it off to
    // reproduce the pre-V2 garbage baseline for A/B measurement.
    let healPrefix: String? = (SuggestionPolicy.Tuning.midWordHealingEnabled
                               && ProcessInfo.processInfo.environment["NOHEAL"] == nil
                               && caretMidWord)
        ? OutputFilter.trailingPartialWord(userTail)
        : nil

    // Mutable accumulator + lastEmitted tracker — the caller-side state that
    // ChunkFilter intentionally does NOT own (preserves the live emit sequence).
    final class Acc: @unchecked Sendable {
        var generated = ""
        var lastEmitted = ""
    }
    let acc = Acc()

    _ = await engine.generate(
        prompt: prompt,
        maxTokens: kMaxTokens,
        sampling: LlamaSampling(
            temperature: 0,
            repeatPenalty: kRepeatPenalty,
            repeatLastN: kRepeatLastN,
            personalizationStrength: kPersonalizationStrength,  // env-overridable; default 0
            banMarkup: true,
            banDigitsLeading: true,
            banEmoji: true,
            minFirstTokenProb: minFirstTokenProb,
            healPrefix: healPrefix
        )
    ) { piece in
        acc.generated += piece
        let (verdict, _, sentenceComplete, reachedWordCap) = ChunkFilter.filterChunk(
            accumulated: acc.generated,
            userTail: userTail,
            caretAfterSpace: caretAfterSpace,
            maxWords: kMaxWords
        )
        switch verdict {
        case .reset:
            // ghost_dropped_repeat → live emits onChunk(""); here just stop.
            return true
        case .dropKeepGenerating:
            if !acc.lastEmitted.isEmpty { acc.lastEmitted = "" }
            return true
        case .emit(let oneLine):
            if oneLine != acc.lastEmitted { acc.lastEmitted = oneLine }
            // Mirror the live path: stop at a completed sentence OR once the
            // complete-word budget is full (never mid-word).
            return !sentenceComplete && !reachedWordCap
        }
    }
    if ProcessInfo.processInfo.environment["DUMP_RAW"] != nil {
        err("RAW gen for \(userTail.debugDescription): generated=\(acc.generated.debugDescription) → emitted=\(acc.lastEmitted.debugDescription)")
    }
    return acc.lastEmitted
}

// MARK: - Main

func main() async {
    // 1. Load the real GGUF into the real engine.
    let engine = LlamaEngine()
    let ok = await engine.load(modelPath: kGGUFPath, contextTokens: 2048)
    guard ok else {
        err("FATAL: could not load GGUF at \(kGGUFPath)")
        exit(1)
    }

    // 2. Real encrypted typing history (Keychain + history.db). Warn + continue
    //    empty on failure — privacy invariant: only TypingHistoryStore touches
    //    the db.
    let store = TypingHistoryStore()
    let entries = await store.allEntries()
    if entries.isEmpty {
        err("WARN: typing history is empty (or failed to decrypt) — continuing with no corpus.")
    } else {
        err("INFO: loaded \(entries.count) typing-history entries.")
        await engine.setCorpus(entries.map { $0.contextBefore.isEmpty ? $0.accepted : $0.contextBefore + " " + $0.accepted })

        // Corpus quality stats — aggregates only, no stored prose printed.
        // Gated so it never interferes with a normal replay run.
        if ProcessInfo.processInfo.environment["SOUFFLEUSE_CORPUS_STATS"]?.isEmpty == false {
            let total = entries.count
            // Exact-duplicate ratio over (contextBefore, accepted).
            var seen = Set<String>()
            var dupCount = 0
            var freq: [String: Int] = [:]
            for e in entries {
                let key = e.contextBefore + "\u{0}" + e.accepted
                if seen.contains(key) { dupCount += 1 } else { seen.insert(key) }
                freq[key, default: 0] += 1
            }
            let unique = seen.count
            // Accepted length histogram.
            var buckets = [0, 0, 0, 0, 0]  // 3-5, 6-10, 11-20, 21-50, 51+
            for e in entries {
                switch e.accepted.count {
                case ..<6: buckets[0] += 1
                case ..<11: buckets[1] += 1
                case ..<21: buckets[2] += 1
                case ..<51: buckets[3] += 1
                default: buckets[4] += 1
                }
            }
            // mid_word flag distribution.
            var midNil = 0, midTrue = 0, midFalse = 0
            for e in entries {
                switch e.midWordContinuation {
                case nil: midNil += 1
                case .some(true): midTrue += 1
                case .some(false): midFalse += 1
                }
            }
            // Mid-word-glue candidate population (contextBefore ends word-char AND
            // accepted starts word-char) — the class joinHistory must reason about.
            func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "-" }
            let glueCandidates = entries.filter {
                if let cb = $0.contextBefore.last, let af = $0.accepted.first { return isWord(cb) && isWord(af) }
                return false
            }.count
            // Lone-consonant fragment residue ("s de…").
            let fragResidue = entries.filter {
                let t = $0.accepted.trimmingCharacters(in: .whitespacesAndNewlines)
                let cs = Array(t)
                guard cs.count >= 2, cs[0].isLetter, cs[1] == " " else { return false }
                return !"aàyôoAÀYÔO".contains(cs[0])
            }.count
            let topRepeat = freq.values.max() ?? 0
            err("=== CORPUS STATS ===")
            err("total=\(total) unique=\(unique) duplicates=\(dupCount) (\(total == 0 ? 0 : dupCount * 100 / total)%)")
            err("accepted_len 3-5=\(buckets[0]) 6-10=\(buckets[1]) 11-20=\(buckets[2]) 21-50=\(buckets[3]) 51+=\(buckets[4])")
            err("mid_word flag: nil(legacy)=\(midNil) true=\(midTrue) false=\(midFalse)")
            err("mid_word_glue_candidates=\(glueCandidates) lone_consonant_fragments=\(fragResidue)")
            err("most_repeated_pair_count=\(topRepeat)")
            err("====================")
        }
    }

    // 3. Build the replay items — either from a JSON scenarios file (rich:
    //    per-scenario id + ctxPrefix) or from the predict log / fallback (plain
    //    tails with empty ctxPrefix, preserving the historical behavior).
    struct ReplayItem {
        let id: String?
        let userTail: String
        let ctxPrefix: String
    }

    let args = CommandLine.arguments
    var items: [ReplayItem] = []
    var jsonMode = false

    if args.count >= 2, args[1].hasSuffix(".json") {
        guard let scenarios = loadScenarios(args[1]) else { exit(1) }
        jsonMode = true
        items = scenarios.map {
            ReplayItem(id: $0.id, userTail: $0.userTail, ctxPrefix: buildCtxPrefix($0))
        }
        err("INFO: loaded \(items.count) scenarios from \(args[1]).")
        err("INFO: personalizationStrength=\(kPersonalizationStrength), afterSpaceL1BarRuntime=\(SuggestionPolicy.Tuning.afterSpaceL1BarRuntime).")
    } else {
        let logPath = "/tmp/souffleuse-predict.log"
        var tails = parsePredictLog(logPath)
        if tails.isEmpty {
            err("INFO: \(logPath) missing/empty — using \(fallbackTails.count) hardcoded French prefixes.")
            tails = fallbackTails
        } else {
            err("INFO: parsed \(tails.count) distinct userTails from \(logPath).")
        }
        items = tails.map { ReplayItem(id: nil, userTail: $0, ctxPrefix: "") }
    }

    // 4. Drive the real pipeline per item.
    let engineActor = WordCompleter()  // WordCompleter is @unchecked Sendable
    var mdRows: [String] = jsonMode
        ? ["| id | userTail | ghost | source |", "|---|---|---|---|"]
        : ["| userTail | ghost | source |", "|---|---|---|"]

    for item in items {
        let tail = item.userTail
        // INVESTIGATION (FORCE_LLM): bypass routeInstant (corpus/L0) entirely and
        // show the RAW model output for this tail + what the mid-word gate would
        // decide. Lets us see what the LLM produces at "Rapport fis" even when the
        // corpus would otherwise pre-empt it with a history recall.
        if ProcessInfo.processInfo.environment["FORCE_LLM"] != nil {
            let partial = OutputFilter.trailingPartialWord(tail)
            let raw = await runLLM(engine: engine, userTail: tail, ctxPrefix: item.ctxPrefix)
            let gated: GhostUpdate? = await MainActor.run {
                SuggestionPolicyEngine(maxWords: kMaxWords).onLLMChunk(raw, userTail: tail)
            }
            printRow(id: item.id, tail: tail, ghost: raw,
                     source: "llm-raw:plen=\(partial.count):\(gated == nil ? "GATED" : "pass")",
                     rows: &mdRows, jsonMode: jsonMode)
            continue
        }
        // EXPMID (legacy investigation hook): raw mid-word LLM when routeInstant
        // would return nil — kept for ad-hoc probing of the un-gated generation.
        if ProcessInfo.processInfo.environment["EXPMID"] != nil,
           let last = tail.last, last.isLetter || last.isNumber,
           tail.trimmingCharacters(in: .whitespaces).count >= 3 {
            let routedNil: Bool = await MainActor.run {
                SuggestionPolicyEngine(maxWords: kMaxWords)
                    .routeInstant(userTail: tail, historySnapshot: entries, wordCompleter: engineActor) == nil
            }
            if routedNil {
                let partial = OutputFilter.trailingPartialWord(tail)
                let raw = await runLLM(engine: engine, userTail: tail, ctxPrefix: item.ctxPrefix)
                printRow(id: item.id, tail: tail, ghost: raw, source: "llm-mid:plen=\(partial.count)", rows: &mdRows, jsonMode: jsonMode)
                continue
            }
        }

        // TWO-STAGE mirror of PredictorViewModel.predict: stage 1 sets the INSTANT
        // ghost (routeInstant: corpus recall / L0 word-complete / L1 history),
        // stage 2 runs the LLM and lets `onLLMChunk` REPLACE it subject to the
        // relevance gate + replacement bar. We report the FINAL ghost the user
        // sees after the stream settles — so a healed LLM ("fis"→"cal annuel")
        // that beats a context-blind L0 ("ton") shows as the llm result, exactly
        // as it does live. The single-stage "routeInstant wins" model hid this.
        let needLLM = tail.trimmingCharacters(in: .whitespaces).count >= 3
        let raw = needLLM ? await runLLM(engine: engine, userTail: tail, ctxPrefix: item.ctxPrefix) : ""
        let (ghost, source): (String, String) = await MainActor.run {
            let policy = SuggestionPolicyEngine(maxWords: kMaxWords)
            var g = "", s = "none"
            // Stage 1 — instant ghost.
            if let route = policy.routeInstant(userTail: tail, historySnapshot: entries, wordCompleter: engineActor) {
                policy.applyGhost(route.text, source: route.source, score: route.score)
                g = route.text; s = sourceLabel(route.source)
            }
            // Stage 2 — LLM stream can replace the instant ghost via the gate.
            if !raw.isEmpty, let update = policy.onLLMChunk(raw, userTail: tail) {
                policy.applyGhost(update.text, source: update.source, score: update.score)
                g = update.text; s = sourceLabel(update.source)
            }
            return (g, s)
        }
        printRow(id: item.id, tail: tail, ghost: ghost, source: source, rows: &mdRows, jsonMode: jsonMode)
    }

    // 5. Write the markdown table.
    let md = mdRows.joined(separator: "\n") + "\n"
    let outPath = jsonMode ? "/tmp/replay-results-json.md" : "/tmp/replay-results.md"
    try? md.write(toFile: outPath, atomically: true, encoding: .utf8)
    err("INFO: wrote \(outPath)")
}

func sourceLabel(_ s: SuggestionSource) -> String {
    switch s {
    case .none: return "none"
    case .wordComplete: return "wordComplete"
    case .history: return "history"
    case .cache: return "cache"
    case .undoCache: return "undoCache"
    case .llm: return "llm"
    }
}

func printRow(id: String?, tail: String, ghost: String, source: String, rows: inout [String], jsonMode: Bool) {
    let idTag = id.map { "[\($0)] " } ?? ""
    print(idTag + tail.debugDescription + " → " + ghost.debugDescription + "  [" + source + "]")
    let safeTail = tail.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "⏎")
    let safeGhost = ghost.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "⏎")
    if jsonMode {
        rows.append("| \(id ?? "—") | `\(safeTail)` | `\(safeGhost)` | \(source) |")
    } else {
        rows.append("| `\(safeTail)` | `\(safeGhost)` | \(source) |")
    }
}

await main()
