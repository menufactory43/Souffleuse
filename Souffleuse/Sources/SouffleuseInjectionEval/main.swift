import Foundation
import SouffleuseCore
import SouffleuseLlama
import SouffleuseLog
import SouffleusePersonalization

// Souffleuse Injection A/B/C Eval — does injecting the user's own prose into the
// prompt make the L2 completion sound like THEM on a NOVEL prefix, without
// derailing the base model (the documented multi-greeting cross-pollution)?
//
// Held-out: take a real message, use its OPENER as the prefix, its rest as the
// "truth". Generate three ways:
//   A  baseline       — no examples (current live behaviour)
//   B  raw block       — SimilarHistoryRetrieval.buildExamplesBlock (no label)
//   C  labelled block  — "Voici des exemples de mes réponses :" + bullets (FR)
//
// Examples are retrieved from TRAIN (corpus minus held-out): top-K by Jaccard,
// filled with recent prose if fewer than K relevant (style transfer needs K
// examples even when nothing is topically relevant — your prose is bespoke).
//
// Per case we print A/B/C side by side (eyeball the voice — the real goal is
// SUBJECTIVE parity), plus automated proxies:
//   overlap%  = token Jaccard of the output with what you ACTUALLY wrote next
//   ⚠greet    = output opens with a greeting although the prefix is mid-message
//   ⚠echo     = output regurgitates an injected example verbatim (>=20 chars)
//
// Usage:
//   SOUFFLEUSE_GGUF=~/…/gemma-3-1b.i1-Q5_K_M.gguf swift run SouffleuseInjectionEval

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let K = 3
let maxGenTokens = 28

// ── Load corpus + 80/20 split ─────────────────────────────────────────────
let store = TypingHistoryStore()
let all = await store.allEntries()
err("[inject-eval] corpus entries: \(all.count)")
guard all.count >= 10 else { print("Corpus too small (\(all.count))."); exit(0) }

var train: [TypingHistoryEntry] = []
var test: [TypingHistoryEntry] = []
for (i, e) in all.enumerated() { if i % 5 == 0 { test.append(e) } else { train.append(e) } }
let recentProse = train.filter { $0.source == .prose }.suffix(20)

// ── Opener prefix + truth from a held-out message ─────────────────────────
struct Case { let prefix: String; let truth: String }
func makeCase(_ e: TypingHistoryEntry) -> Case? {
    let t = e.accepted.trimmingCharacters(in: .whitespacesAndNewlines)
    let words = t.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard words.count >= 6 else { return nil }
    let openerWords = max(3, min(6, words.count / 2))
    let prefix = words.prefix(openerWords).joined(separator: " ") + " "
    let truth = words.dropFirst(openerWords).joined(separator: " ")
    return Case(prefix: prefix, truth: truth)
}
let cases = test.compactMap(makeCase).prefix(15)

// ── Example selection: top-K relevant, filled with recent prose ───────────
@MainActor
func selectExamples(for prefix: String) -> [TypingHistoryEntry] {
    var ex = SimilarHistoryRetrieval.rank(entries: train, userTail: prefix, limit: K)
    if ex.count < K {
        for e in recentProse.reversed() where !ex.contains(e) {
            ex.append(e); if ex.count >= K { break }
        }
    }
    return Array(ex.prefix(K))
}

func labelledBlock(_ ex: [TypingHistoryEntry], maxChars: Int = 400) -> String {
    var lines: [String] = []; var total = 0
    for e in ex {
        let line = e.contextBefore.isEmpty ? e.accepted : e.contextBefore + " " + e.accepted
        let one = "- " + line
        if total + one.count + 1 > maxChars { break }
        lines.append(one); total += one.count + 1
    }
    if lines.isEmpty { return "" }
    return "Voici des exemples de mes réponses précédentes :\n" + lines.joined(separator: "\n")
}

// ── Generation (mirror live generateLlama sampling, no heal/no perso) ──────
func gen(prompt: String, engine: LlamaEngine) async -> String {
    final class Acc: @unchecked Sendable { var s = "" }
    let acc = Acc()
    _ = await engine.generate(
        prompt: prompt, maxTokens: maxGenTokens,
        sampling: LlamaSampling(
            temperature: 0, repeatPenalty: 1.3, repeatLastN: 64,
            personalizationStrength: 0, banMarkup: true, banDigitsLeading: true, banEmoji: true
        )
    ) { piece in acc.s += piece; return true }
    return acc.s.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? acc.s
}

// ── Proxies ───────────────────────────────────────────────────────────────
func overlap(_ a: String, _ b: String) -> Int {
    let sa = Set(SimilarHistoryRetrieval.tokenize(a)), sb = Set(SimilarHistoryRetrieval.tokenize(b))
    if sa.isEmpty || sb.isEmpty { return 0 }
    return Int(Double(sa.intersection(sb).count) / Double(sa.union(sb).count) * 100)
}
let greetings = ["bonjour", "bonsoir", "salut", "coucou", "hello", "hi", "madame", "monsieur"]
func opensWithGreeting(_ out: String, prefix: String) -> Bool {
    let firstWord = out.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        .split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
    // only a problem if the prefix is already mid-message (not itself a greeting)
    let prefixLooksMidMessage = prefix.count > 14 && !greetings.contains(where: { prefix.lowercased().hasPrefix($0) })
    return prefixLooksMidMessage && greetings.contains(firstWord)
}
func echoesExample(_ out: String, _ ex: [TypingHistoryEntry]) -> Bool {
    let o = out.lowercased()
    for e in ex {
        let body = (e.contextBefore + " " + e.accepted).lowercased()
        let bchars = Array(body)
        var i = 0
        while i + 20 <= bchars.count {
            let frag = String(bchars[i..<i+20])
            if o.contains(frag) { return true }
            i += 6
        }
    }
    return false
}

// ── Boot engine ───────────────────────────────────────────────────────────
let ggufPath = (ProcessInfo.processInfo.environment["SOUFFLEUSE_GGUF"].flatMap { $0.isEmpty ? nil : $0 }
    ?? "~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf")
let resolved = (ggufPath as NSString).expandingTildeInPath
let engine = LlamaEngine()
err("[inject-eval] loading GGUF: \(resolved)")
guard await engine.load(modelPath: resolved, contextTokens: 4096) else { err("FATAL: GGUF load failed"); exit(1) }

// ── Run ───────────────────────────────────────────────────────────────────
err("[inject-eval] \(cases.count) held-out openers × 3 conditions\n")
var sumA = 0, sumB = 0, sumC = 0, greetB = 0, greetC = 0, echoB = 0, echoC = 0, n = 0

for c in cases {
    let ex = selectExamples(for: c.prefix)
    let rawBlock = SimilarHistoryRetrieval.buildExamplesBlock(from: ex)
    let labBlock = labelledBlock(ex)

    let pA = LlamaPromptBuilder.buildLlamaPrompt(system: "", customInstr: "", ctxPrefix: "", fieldContext: "", afterCursor: "", beforeCursor: c.prefix)
    let pB = LlamaPromptBuilder.buildLlamaPrompt(system: "", customInstr: "", ctxPrefix: rawBlock, fieldContext: "", afterCursor: "", beforeCursor: c.prefix)
    let pC = LlamaPromptBuilder.buildLlamaPrompt(system: "", customInstr: "", ctxPrefix: labBlock, fieldContext: "", afterCursor: "", beforeCursor: c.prefix)

    let oA = await gen(prompt: pA, engine: engine)
    let oB = await gen(prompt: pB, engine: engine)
    let oC = await gen(prompt: pC, engine: engine)

    let vA = overlap(oA, c.truth), vB = overlap(oB, c.truth), vC = overlap(oC, c.truth)
    sumA += vA; sumB += vB; sumC += vC; n += 1
    let gB = opensWithGreeting(oB, prefix: c.prefix), gC = opensWithGreeting(oC, prefix: c.prefix)
    let eB = echoesExample(oB, ex), eC = echoesExample(oC, ex)
    if gB { greetB += 1 }; if gC { greetC += 1 }; if eB { echoB += 1 }; if eC { echoC += 1 }

    print("""

    ### "\(c.prefix)|"  (\(ex.count) exemples injectés)
      vrai → \(String(c.truth.prefix(70)))
      A none  [ov \(vA)%] : \(String(oA.prefix(72)))
      B raw   [ov \(vB)%]\(gB ? " ⚠greet" : "")\(eB ? " ⚠echo" : "") : \(String(oB.prefix(72)))
      C label [ov \(vC)%]\(gC ? " ⚠greet" : "")\(eC ? " ⚠echo" : "") : \(String(oC.prefix(72)))
    """)
}

let mA = n > 0 ? "\(sumA / n)%" : "—"
let mB = n > 0 ? "\(sumB / n)%" : "—"
let mC = n > 0 ? "\(sumC / n)%" : "—"
err("""

──────────── Injection A/B/C Summary (\(n) openers) ────────────
mean overlap-with-your-actual-reply:
  A none   : \(mA)
  B raw    : \(mB)     greet-derail \(greetB)/\(n)   echo \(echoB)/\(n)
  C label  : \(mC)     greet-derail \(greetC)/\(n)   echo \(echoC)/\(n)

READING:
  overlap = how many content words the model produced that you ACTUALLY used.
  - B/C overlap > A  → injecting your prose pulls the model toward your real
    wording → injection WORKS. Pick the format with fewer ⚠derails.
  - B/C ≈ A           → injection does not move content; the win (if any) is pure
    tone, judge it by eye in the A/B/C lines above.
  - high ⚠greet/⚠echo → that format makes the base model parrot the examples
    (the documented cross-pollution) → reject it.
  This is a PROXY. The real verdict is your eyes on the three lines: which sounds
  like you?
""")
