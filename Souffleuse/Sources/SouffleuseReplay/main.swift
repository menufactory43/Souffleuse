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

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

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
    userTail: String
) async -> String {
    // BARE prompt — empty system / ctx / field / customInstr (offline replay
    // has no AX snapshot or user instructions). `beforeCursor` = userTail.
    let prompt = LlamaPromptBuilder.buildLlamaPrompt(
        system: "",
        customInstr: "",
        ctxPrefix: "",
        fieldContext: "",
        afterCursor: "",
        beforeCursor: userTail
    )
    // Caret derivation — verbatim from generateLlama.
    let caretAfterSpace = userTail.last == " " || userTail.last == "\t"
    let caretMidWord = userTail.last.map { $0.isLetter || $0.isNumber } ?? false
    let minFirstTokenProb: Float = caretMidWord ? LlamaPromptBuilder.midWordMinFirstTokenProb : 0

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
            repeatPenalty: 1.3,
            repeatLastN: 64,
            personalizationStrength: 0,      // replay: no personalization gain
            banMarkup: true,
            banDigitsLeading: true,
            banEmoji: true,
            minFirstTokenProb: minFirstTokenProb
        )
    ) { piece in
        acc.generated += piece
        let (verdict, _) = ChunkFilter.filterChunk(
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
            guard oneLine != acc.lastEmitted else { return true }
            acc.lastEmitted = oneLine
            return true
        }
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

    // 3. Corpus of typed-prefix sequences.
    let logPath = "/tmp/souffleuse-predict.log"
    var tails = parsePredictLog(logPath)
    if tails.isEmpty {
        err("INFO: \(logPath) missing/empty — using \(fallbackTails.count) hardcoded French prefixes.")
        tails = fallbackTails
    } else {
        err("INFO: parsed \(tails.count) distinct userTails from \(logPath).")
    }

    // 4. Drive the real pipeline per tail.
    let engineActor = WordCompleter()  // WordCompleter is @unchecked Sendable
    var mdRows: [String] = ["| userTail | ghost | source |", "|---|---|---|"]

    for tail in tails {
        // 4a. Instant routing (L0/L1) via the real SuggestionPolicyEngine.
        let routed: GhostUpdate? = await MainActor.run {
            let policy = SuggestionPolicyEngine(maxWords: kMaxWords)
            return policy.routeInstant(
                userTail: tail,
                historySnapshot: entries,
                wordCompleter: engineActor
            )
        }

        var ghost = ""
        var source = "none"
        if let route = routed {
            ghost = route.text
            source = sourceLabel(route.source)
        } else if ProcessInfo.processInfo.environment["EXPMID"] != nil,
                  let last = tail.last, last.isLetter || last.isNumber,
                  tail.trimmingCharacters(in: .whitespaces).count >= 3 {
            // EXPERIMENT: mid-word LLM WITHOUT the Option-A onLLMChunk block,
            // tagged with the current partial-word length, to test whether
            // long partial words yield coherent completions (so we could allow
            // mid-word LLM above a length threshold instead of blocking all).
            let partial = OutputFilter.trailingPartialWord(tail)
            let raw = await runLLM(engine: engine, userTail: tail)
            printRow(tail: tail, ghost: raw, source: "llm-mid:plen=\(partial.count)", rows: &mdRows)
            continue
        } else {
            // 4b. LLM path — gate at ≥3 trimmed chars (PVM LLM gate).
            guard tail.trimmingCharacters(in: .whitespaces).count >= 3 else {
                printRow(tail: tail, ghost: "", source: "none", rows: &mdRows)
                continue
            }
            let raw = await runLLM(engine: engine, userTail: tail)
            if !raw.isEmpty {
                // 4c. Relevance gate via onLLMChunk on a fresh engine instance.
                let applied: GhostUpdate? = await MainActor.run {
                    let policy = SuggestionPolicyEngine(maxWords: kMaxWords)
                    return policy.onLLMChunk(raw, userTail: tail)
                }
                if let update = applied {
                    ghost = update.text
                    source = "llm"
                }
            }
        }
        printRow(tail: tail, ghost: ghost, source: source, rows: &mdRows)
    }

    // 5. Write the markdown table.
    let md = mdRows.joined(separator: "\n") + "\n"
    try? md.write(toFile: "/tmp/replay-results.md", atomically: true, encoding: .utf8)
    err("INFO: wrote /tmp/replay-results.md")
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

func printRow(tail: String, ghost: String, source: String, rows: inout [String]) {
    print(tail.debugDescription + " → " + ghost.debugDescription + "  [" + source + "]")
    let safeTail = tail.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "⏎")
    let safeGhost = ghost.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "⏎")
    rows.append("| `\(safeTail)` | `\(safeGhost)` | \(source) |")
}

await main()
