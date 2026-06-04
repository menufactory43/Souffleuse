import Foundation
import SouffleuseCore
import SouffleuseCorpus
import SouffleusePersonalization
import SouffleuseTyping

// Souffleuse Recall Eval — honest held-out coverage of corpus recall (L1).
//
// Splits the REAL corpus 80/20. Holds out 20% of entries as TEST, keeps 80% as
// the recall corpus (TRAIN). For each held-out entry it generates realistic
// probes (mid-word + after-space cut points) and asks: does
// SuggestionPolicyEngine.routeInstant fire a recall against TRAIN, and is the
// recalled continuation a CORRECT prefix of the held-out true suffix?
//
// This measures generalization — "given everything else you've written, can the
// corpus complete a NEW sentence?" — which decides whether prompt-injection
// (styling the L2 for novel cases) is worth it:
//   high hit-rate  → recall alone is enough.
//   low  hit-rate  → your sentences are unique → need LLM styled by injection.
//
// Privacy: reads only via the sanctioned TypingHistoryStore. Prints aggregates
// + a few sample hits/misses (your own prose, dev tool only).
//
// Also sweeps TRAIN size (25/50/100%) → the coverage-vs-corpus curve.
//
// Usage:  swift run SouffleuseRecallEval

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// ── Load corpus ───────────────────────────────────────────────────────────
let store = TypingHistoryStore()
let all = await store.allEntries()
err("[recall-eval] corpus entries: \(all.count)")
guard all.count >= 10 else {
    print("Corpus too small (\(all.count)) for a held-out split. Seed more prose first.")
    exit(0)
}

// ── Deterministic 80/20 split (index % 5 == 0 → test) ─────────────────────
var trainAll: [TypingHistoryEntry] = []
var test: [TypingHistoryEntry] = []
for (i, e) in all.enumerated() {
    if i % 5 == 0 { test.append(e) } else { trainAll.append(e) }
}

// ── Probe generation from a held-out entry's accepted text ────────────────
struct Probe { let prefix: String; let trueSuffix: String; let kind: String }

func wordCharBoundaries(_ s: String) -> [String.Index] {
    // indices that sit AFTER a whitespace (start of a word) — for after-space cuts
    var idx: [String.Index] = []
    var prevSpace = true
    for i in s.indices {
        if prevSpace && !s[i].isWhitespace { idx.append(i) }
        prevSpace = s[i].isWhitespace
    }
    return idx
}

func probes(from text: String) -> [Probe] {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t.count >= 12 else { return [] }
    let chars = Array(t)
    var out: [Probe] = []
    // after-space cut at EVERY word boundary from the 2nd word on (captures both
    // repeated openers and unique content). The prefix must be >=4 chars and the
    // suffix non-empty.
    for cut in wordCharBoundaries(t) {
        let off = t.distance(from: t.startIndex, to: cut)
        guard off >= 4, off < chars.count - 1 else { continue }
        out.append(Probe(prefix: String(chars[0..<off]), trueSuffix: String(chars[off...]), kind: "after-space"))
    }
    // mid-word cut inside every word that is long enough — caret after the 3rd
    // char of a word (>=5 chars), where a complete-the-word recall would fire.
    var wordStart = 0
    var i = 0
    while i <= chars.count {
        let atEnd = i == chars.count
        let isWord = !atEnd && (chars[i].isLetter || chars[i].isNumber)
        if atEnd || !isWord {
            let wordLen = i - wordStart
            if wordLen >= 5 {
                let cut = wordStart + 3                      // caret 3 chars into the word
                if cut > 2 && cut < chars.count - 1 {
                    out.append(Probe(prefix: String(chars[0..<cut]), trueSuffix: String(chars[cut...]), kind: "mid-word"))
                }
            }
            wordStart = i + 1
        }
        i += 1
    }
    // bound per-entry probe count so one long message can't dominate
    return Array(out.prefix(8))
}

// ── Correctness: recalled continuation shares a real prefix with the truth ─
func isCorrect(recalled: String, trueSuffix: String) -> Bool {
    func norm(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).lowercased()
    }
    let r = norm(recalled), tr = norm(trueSuffix)
    guard !r.isEmpty, !tr.isEmpty else { return false }
    // first word of recall must be a prefix of the true suffix's first run (or vice-versa)
    let rw = r.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? r
    let tw = tr.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? tr
    return tw.hasPrefix(rw) || rw.hasPrefix(tw)
}

// ── Eval one TRAIN set against all test probes ────────────────────────────
@MainActor
func evaluate(train: [TypingHistoryEntry], label: String) {
    let policy = SuggestionPolicyEngine(maxWords: 8)
    let wc = WordCompleter()
    var byKind: [String: (probes: Int, fired: Int, correct: Int)] = [
        "after-space": (0, 0, 0), "mid-word": (0, 0, 0),
    ]
    var sampleHits: [String] = []
    var sampleMisses: [String] = []
    for e in test {
        for pr in probes(from: e.accepted) {
            byKind[pr.kind]!.probes += 1
            guard let g = policy.routeInstant(userTail: pr.prefix, historySnapshot: train, wordCompleter: wc) else {
                if sampleMisses.count < 4 { sampleMisses.append("[\(pr.kind)] \"…\(String(pr.prefix.suffix(24)))|\" → ∅ (vrai: \(String(pr.trueSuffix.prefix(20))))") }
                continue
            }
            byKind[pr.kind]!.fired += 1
            let ok = isCorrect(recalled: g.text, trueSuffix: pr.trueSuffix)
            if ok { byKind[pr.kind]!.correct += 1 }
            if ok && sampleHits.count < 4 {
                sampleHits.append("[\(pr.kind)] \"…\(String(pr.prefix.suffix(20)))|\" → \(g.source):\(String(g.text.prefix(28)))")
            }
        }
    }
    print("\n─── TRAIN \(label) (\(train.count) entries) ───")
    for kind in ["mid-word", "after-space"] {
        let s = byKind[kind]!
        let fireRate = s.probes > 0 ? Int(Double(s.fired) / Double(s.probes) * 100) : 0
        let prec = s.fired > 0 ? Int(Double(s.correct) / Double(s.fired) * 100) : 0
        let cov = s.probes > 0 ? Int(Double(s.correct) / Double(s.probes) * 100) : 0
        print("  \(kind.padding(toLength: 11, withPad: " ", startingAt: 0)): \(s.probes) probes | fired \(s.fired) (\(fireRate)%) | precision \(prec)% | USEFUL-COVERAGE \(cov)%")
    }
    if label == "100%" {
        print("  sample hits:")
        for h in sampleHits { print("    ✓ \(h)") }
        print("  sample misses:")
        for m in sampleMisses { print("    ✗ \(m)") }
    }
}

// ── Coverage curve: 25 / 50 / 100% of TRAIN ───────────────────────────────
err("[recall-eval] test probes from \(test.count) held-out entries; train pool \(trainAll.count)")
await MainActor.run {
    evaluate(train: Array(trainAll.prefix(trainAll.count / 4)), label: "25%")
    evaluate(train: Array(trainAll.prefix(trainAll.count / 2)), label: "50%")
    evaluate(train: trainAll, label: "100%")
}

print("""

READING:
  USEFUL-COVERAGE = correct recalls / all probes — the honest "how often does the
  corpus correctly finish a NEW sentence" number.
  - mid-word coverage HIGH  → recall (L1) already gives Cotypist-feel mid-word.
  - after-space coverage LOW → novel message starts are unpredictable from recall
    → prompt-injection (styling L2 to your voice) is where the next gain is.
  - watch the 25→50→100% curve: if it is still climbing, MORE corpus helps; if
    it flattened, you have saturated and need DIVERSITY, not volume.
""")
