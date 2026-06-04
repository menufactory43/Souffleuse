import Foundation
import SouffleuseCore
import SouffleusePersonalization
import SouffleuseTyping

// SouffleuseCorpusEval — HARNAIS JETABLE (dev-only, hors SHIPPING_DIRS).
//
// But : en UN SEUL run autorisé par le Keychain, (1) exporter le corpus réel en
// clair dans /tmp pour analyse autonome, et (2) exécuter les mesures du chemin
// de PROD réel (LearnedLexicon.build + SuggestionPolicyEngine.routeInstant) sur
// des splits held-out 80/20 — sans LLM, instantané. Consolide RecallEval +
// LexiconRouteEval + VocabCompleteEval pour n'ouvrir le store (donc le Keychain)
// QU'UNE fois.
//
// Privacy : la sortie va exclusivement dans /tmp/cocotypist-eval/ (jamais le
// repo, jamais les logs). À SUPPRIMER après usage (ce fichier + le target).
//
// Usage : swift run SouffleuseCorpusEval

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let outDir = "/tmp/cocotypist-eval"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func writeJSON<T: Encodable>(_ value: T, to name: String) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(value) {
        try? data.write(to: URL(fileURLWithPath: outDir + "/" + name))
        err("[corpus-eval] wrote \(name) (\(data.count) bytes)")
    } else {
        err("[corpus-eval] FAILED to encode \(name)")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. Charge le corpus réel — UN SEUL accès Keychain.
// ─────────────────────────────────────────────────────────────────────────────
let store = TypingHistoryStore()
let all = await store.allEntries()
err("[corpus-eval] corpus entries: \(all.count)")
guard all.count >= 10 else {
    print("Corpus trop petit (\(all.count)) pour un split held-out. Seed plus de prose d'abord.")
    exit(0)
}

// ── Export complet du corpus en clair (autonomie downstream) ─────────────────
struct ExportRow: Encodable {
    let ts: Double
    let contextBefore: String
    let accepted: String
    let bundleID: String?
    let midWord: Bool?
    let source: String
}
let exportRows = all.map { e in
    ExportRow(
        ts: e.timestamp.timeIntervalSince1970,
        contextBefore: e.contextBefore,
        accepted: e.accepted,
        bundleID: e.bundleID,
        midWord: e.midWordContinuation,
        source: e.source.rawValue
    )
}
writeJSON(exportRows, to: "corpus_export.json")  // écrit EN PREMIER (artefact critique)

// ─────────────────────────────────────────────────────────────────────────────
// 2. Composition du corpus.
// ─────────────────────────────────────────────────────────────────────────────
func median(_ xs: [Int]) -> Int { xs.isEmpty ? 0 : xs.sorted()[xs.count / 2] }

// Heuristique français : ratio de stopwords FR sur les mots de `accepted`.
let frStop: Set<String> = [
    "le", "la", "les", "de", "des", "du", "un", "une", "et", "est", "vous", "je",
    "pour", "que", "qui", "avec", "pas", "sur", "dans", "au", "aux", "ce", "cette",
    "votre", "nous", "ne", "plus", "bien", "merci", "bonjour", "votre", "vos", "à",
    "il", "elle", "on", "sont", "ont", "fait", "tout", "ça", "donc", "mais",
]
func looksFrench(_ s: String) -> Bool {
    let toks = s.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init)
    guard toks.count >= 3 else { return false }
    let hits = toks.filter { frStop.contains($0) }.count
    return Double(hits) / Double(toks.count) >= 0.12
}

struct Stats: Encodable {
    let total: Int
    let prose: Int
    let accept: Int
    let emptyContext: Int
    let byBundle: [String: Int]
    let acceptedLenAvg: Int
    let acceptedLenMedian: Int
    let contextLenAvg: Int
    let uniqueAccepted: Int
    let duplicateRatePct: Int
    let frenchProsePct: Int
    let vocabSize: Int
    let distinctiveLexicon: Int
    let tsMinEpoch: Double
    let tsMaxEpoch: Double
}

let proseEntries = all.filter { $0.source == .prose }
let acceptEntries = all.filter { $0.source == .accept }
var byBundle: [String: Int] = [:]
for e in all { byBundle[e.bundleID ?? "∅", default: 0] += 1 }
let accLens = all.map { $0.accepted.count }
let ctxLens = all.map { $0.contextBefore.count }
let uniqueAcc = Set(all.map { $0.accepted }).count
let frenchProse = proseEntries.filter { looksFrench($0.accepted) }.count
var vocab = Set<String>()
for e in all { for (w, _) in LearnedLexicon.tokensWithCase(e.contextBefore.isEmpty ? e.accepted : e.contextBefore + " " + e.accepted) { vocab.insert(w.lowercased()) } }
let fullLexicon = LearnedLexicon.build(from: all)

let stats = Stats(
    total: all.count,
    prose: proseEntries.count,
    accept: acceptEntries.count,
    emptyContext: all.filter { $0.contextBefore.isEmpty }.count,
    byBundle: byBundle,
    acceptedLenAvg: accLens.isEmpty ? 0 : accLens.reduce(0, +) / accLens.count,
    acceptedLenMedian: median(accLens),
    contextLenAvg: ctxLens.isEmpty ? 0 : ctxLens.reduce(0, +) / ctxLens.count,
    uniqueAccepted: uniqueAcc,
    duplicateRatePct: all.isEmpty ? 0 : Int(Double(all.count - uniqueAcc) / Double(all.count) * 100),
    frenchProsePct: proseEntries.isEmpty ? 0 : Int(Double(frenchProse) / Double(proseEntries.count) * 100),
    vocabSize: vocab.count,
    distinctiveLexicon: fullLexicon.count,
    tsMinEpoch: all.map { $0.timestamp.timeIntervalSince1970 }.min() ?? 0,
    tsMaxEpoch: all.map { $0.timestamp.timeIntervalSince1970 }.max() ?? 0
)

// ─────────────────────────────────────────────────────────────────────────────
// 3. Génération de probes held-out (identique à RecallEval).
// ─────────────────────────────────────────────────────────────────────────────
struct Probe { let prefix: String; let trueSuffix: String; let kind: String }

func wordCharBoundaries(_ s: String) -> [String.Index] {
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
    for cut in wordCharBoundaries(t) {
        let off = t.distance(from: t.startIndex, to: cut)
        guard off >= 4, off < chars.count - 1 else { continue }
        out.append(Probe(prefix: String(chars[0..<off]), trueSuffix: String(chars[off...]), kind: "after-space"))
    }
    var wordStart = 0
    var i = 0
    while i <= chars.count {
        let atEnd = i == chars.count
        let isWord = !atEnd && (chars[i].isLetter || chars[i].isNumber)
        if atEnd || !isWord {
            let wordLen = i - wordStart
            if wordLen >= 5 {
                let cut = wordStart + 3
                if cut > 2 && cut < chars.count - 1 {
                    out.append(Probe(prefix: String(chars[0..<cut]), trueSuffix: String(chars[cut...]), kind: "mid-word"))
                }
            }
            wordStart = i + 1
        }
        i += 1
    }
    return Array(out.prefix(8))
}

func isCorrect(recalled: String, trueSuffix: String) -> Bool {
    func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).lowercased() }
    let r = norm(recalled), tr = norm(trueSuffix)
    guard !r.isEmpty, !tr.isEmpty else { return false }
    let rw = r.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? r
    let tw = tr.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? tr
    return tw.hasPrefix(rw) || rw.hasPrefix(tw)
}

// ── Split déterministe 80/20 (index % 5 == 0 → test) ─────────────────────────
var trainAll: [TypingHistoryEntry] = []
var test: [TypingHistoryEntry] = []
for (i, e) in all.enumerated() {
    if i % 5 == 0 { test.append(e) } else { trainAll.append(e) }
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. TRIGGER EVAL — chemin de prod réel AVEC la pile active complète
//    (routeInstant + LearnedLexicon construit sur TRAIN). Répond à « 1/10 ».
// ─────────────────────────────────────────────────────────────────────────────
struct KindMetric: Encodable {
    let kind: String; let probes: Int; let fired: Int; let correct: Int
    let fireRatePct: Int; let precisionPct: Int; let usefulCoveragePct: Int
}
struct SourceBreakdown: Encodable { let learnedWord: Int; let history: Int; let other: Int }
struct TriggerResult: Encodable {
    let trainLabel: String; let trainCount: Int
    let kinds: [KindMetric]
    let correctBySource: SourceBreakdown
    let overallProbes: Int; let overallFired: Int; let overallCorrect: Int
    let overallFireRatePct: Int; let overallPrecisionPct: Int; let overallUsefulCoveragePct: Int
}

@MainActor
func triggerEval(
    train: [TypingHistoryEntry], test: [TypingHistoryEntry], label: String,
    sampleHits: inout [String], sampleMisses: inout [String], collectSamples: Bool,
    scoped: Bool = false
) -> TriggerResult {
    let policy = SuggestionPolicyEngine(maxWords: 8)
    let wc = WordCompleter()
    let lex = LearnedLexicon.build(from: train)
    var byKind: [String: (probes: Int, fired: Int, correct: Int)] = [
        "after-space": (0, 0, 0), "mid-word": (0, 0, 0),
    ]
    var srcLearned = 0, srcHistory = 0, srcOther = 0
    for e in test {
        // Scoping (P1.2) : en mode SCOPED, le recall n'utilise QUE la prose des
        // apps du même cluster de registre que l'entrée testée. En mode UNSCOPED
        // (baseline), `.other` ⇒ aucun scope (comportement historique).
        let domain: DomainCluster = scoped ? DomainCluster.cluster(for: e.bundleID) : .other
        for pr in probes(from: e.accepted) {
            byKind[pr.kind]!.probes += 1
            guard let g = policy.routeInstant(
                userTail: pr.prefix, historySnapshot: train, wordCompleter: wc, lexicon: lex,
                activeDomain: domain
            ) else {
                if collectSamples && sampleMisses.count < 8 {
                    sampleMisses.append("[\(pr.kind)] …\(String(pr.prefix.suffix(22)))| → ∅ (vrai: \(String(pr.trueSuffix.prefix(18))))")
                }
                continue
            }
            byKind[pr.kind]!.fired += 1
            let ok = isCorrect(recalled: g.text, trueSuffix: pr.trueSuffix)
            if ok {
                byKind[pr.kind]!.correct += 1
                switch g.source {
                case .learnedWord: srcLearned += 1
                case .history: srcHistory += 1
                default: srcOther += 1
                }
                if collectSamples && sampleHits.count < 8 {
                    sampleHits.append("[\(pr.kind)] …\(String(pr.prefix.suffix(18)))| → \(g.source):\(String(g.text.prefix(24)))")
                }
            }
        }
    }
    var kinds: [KindMetric] = []
    var oP = 0, oF = 0, oC = 0
    for k in ["mid-word", "after-space"] {
        let s = byKind[k]!
        oP += s.probes; oF += s.fired; oC += s.correct
        kinds.append(KindMetric(
            kind: k, probes: s.probes, fired: s.fired, correct: s.correct,
            fireRatePct: s.probes > 0 ? Int(Double(s.fired) / Double(s.probes) * 100) : 0,
            precisionPct: s.fired > 0 ? Int(Double(s.correct) / Double(s.fired) * 100) : 0,
            usefulCoveragePct: s.probes > 0 ? Int(Double(s.correct) / Double(s.probes) * 100) : 0))
    }
    return TriggerResult(
        trainLabel: label, trainCount: train.count, kinds: kinds,
        correctBySource: SourceBreakdown(learnedWord: srcLearned, history: srcHistory, other: srcOther),
        overallProbes: oP, overallFired: oF, overallCorrect: oC,
        overallFireRatePct: oP > 0 ? Int(Double(oF) / Double(oP) * 100) : 0,
        overallPrecisionPct: oF > 0 ? Int(Double(oC) / Double(oF) * 100) : 0,
        overallUsefulCoveragePct: oP > 0 ? Int(Double(oC) / Double(oP) * 100) : 0)
}

// ── Comparaison UNSCOPED vs SCOPED (P1.2), TRAIN 100% held-out ──────────────
// `triggerCurve` reste la courbe historique (UNSCOPED, .other partout) pour ne
// pas casser les comparaisons existantes. `scopedResult100` rejoue le MÊME split
// held-out à TRAIN 100% en scopant chaque entrée sur le cluster déduit de SON
// bundleID. `scopingComparison` reporte les deux passes (global + par kind).
struct KindCompare: Encodable {
    let kind: String
    let unscopedFireRatePct: Int; let unscopedPrecisionPct: Int; let unscopedUsefulCoveragePct: Int
    let scopedFireRatePct: Int; let scopedPrecisionPct: Int; let scopedUsefulCoveragePct: Int
}
struct ScopingComparison: Encodable {
    let trainLabel: String
    let unscopedFireRatePct: Int; let unscopedPrecisionPct: Int; let unscopedUsefulCoveragePct: Int
    let scopedFireRatePct: Int; let scopedPrecisionPct: Int; let scopedUsefulCoveragePct: Int
    let byKind: [KindCompare]
}

var sampleHits: [String] = []
var sampleMisses: [String] = []
var scopedResult100: TriggerResult? = nil
let triggerCurve: [TriggerResult] = await MainActor.run {
    var hits: [String] = []
    var misses: [String] = []
    var dummyHits: [String] = []
    var dummyMisses: [String] = []
    let r25 = triggerEval(train: Array(trainAll.prefix(max(1, trainAll.count / 4))), test: test, label: "25%", sampleHits: &hits, sampleMisses: &misses, collectSamples: false)
    let r50 = triggerEval(train: Array(trainAll.prefix(max(1, trainAll.count / 2))), test: test, label: "50%", sampleHits: &hits, sampleMisses: &misses, collectSamples: false)
    let r100 = triggerEval(train: trainAll, test: test, label: "100%", sampleHits: &hits, sampleMisses: &misses, collectSamples: true)
    // 2e passe : MÊME held-out, TRAIN 100%, mais SCOPED par cluster de l'entrée.
    scopedResult100 = triggerEval(train: trainAll, test: test, label: "100% scoped", sampleHits: &dummyHits, sampleMisses: &dummyMisses, collectSamples: false, scoped: true)
    sampleHits = hits; sampleMisses = misses
    return [r25, r50, r100]
}

let scopingComparison: ScopingComparison = {
    let u = triggerCurve.last!
    let s = scopedResult100!
    var kindCompares: [KindCompare] = []
    let uByKind = Dictionary(uniqueKeysWithValues: u.kinds.map { ($0.kind, $0) })
    let sByKind = Dictionary(uniqueKeysWithValues: s.kinds.map { ($0.kind, $0) })
    for k in ["mid-word", "after-space"] {
        guard let uk = uByKind[k], let sk = sByKind[k] else { continue }
        kindCompares.append(KindCompare(
            kind: k,
            unscopedFireRatePct: uk.fireRatePct, unscopedPrecisionPct: uk.precisionPct, unscopedUsefulCoveragePct: uk.usefulCoveragePct,
            scopedFireRatePct: sk.fireRatePct, scopedPrecisionPct: sk.precisionPct, scopedUsefulCoveragePct: sk.usefulCoveragePct))
    }
    return ScopingComparison(
        trainLabel: "100%",
        unscopedFireRatePct: u.overallFireRatePct, unscopedPrecisionPct: u.overallPrecisionPct, unscopedUsefulCoveragePct: u.overallUsefulCoveragePct,
        scopedFireRatePct: s.overallFireRatePct, scopedPrecisionPct: s.overallPrecisionPct, scopedUsefulCoveragePct: s.overallUsefulCoveragePct,
        byKind: kindCompares)
}()

// ─────────────────────────────────────────────────────────────────────────────
// 5. LEXICON ROUTE — preuve terme-à-terme « Préfixe3 » → terme appris.
// ─────────────────────────────────────────────────────────────────────────────
struct LexTermRow: Encodable {
    let term: String; let freq: Int; let prefix3: String
    let source: String; let ghost: String; let rebuilt: String; let ok: Bool
}
struct LexResult: Encodable {
    let historyCount: Int; let distinctiveTerms: Int; let tested: Int
    let surfaced: Int; let viaLexicon: Int; let viaL1: Int; let rows: [LexTermRow]
}

let leads = ["Voici ", "Je recommande ", "On utilise ", "C'est avec ", "Mon préféré reste "]
let lexResult: LexResult = await MainActor.run {
    let lexicon = LearnedLexicon.build(from: all)
    let wc = WordCompleter()
    let policy = SuggestionPolicyEngine(maxWords: 8)
    var rows: [LexTermRow] = []
    for (i, t) in lexicon.terms.prefix(40).enumerated() where t.term.count >= 4 {
        let pre = String(t.term.prefix(3))
        let lead = leads[i % leads.count]
        let result = policy.routeInstant(userTail: lead + pre, historySnapshot: all, wordCompleter: wc, lexicon: lexicon)
        let srcStr: String
        switch result?.source {
        case .some(.learnedWord): srcStr = "learnedWord"
        case .some(.history): srcStr = "history(L1)"
        case .some(.wordComplete): srcStr = "wordComplete"
        case .some(let s): srcStr = "\(s)"
        case .none: srcStr = "∅"
        }
        let ghost = result?.text ?? ""
        let rebuilt = pre + ghost
        let ok = rebuilt.lowercased().hasPrefix(t.term.lowercased())
        rows.append(LexTermRow(term: t.term, freq: t.freq, prefix3: pre, source: srcStr, ghost: ghost, rebuilt: rebuilt, ok: ok))
    }
    return LexResult(
        historyCount: all.count, distinctiveTerms: lexicon.count, tested: rows.count,
        surfaced: rows.filter { $0.ok }.count,
        viaLexicon: rows.filter { $0.source == "learnedWord" && $0.ok }.count,
        viaL1: rows.filter { $0.source == "history(L1)" && $0.ok }.count,
        rows: rows)
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. VOCAB COMPLETE — recall/précision/keystrokes du complèteur mid-mot +
//    disponibilité « copie-contexte » (identique à VocabCompleteEval).
// ─────────────────────────────────────────────────────────────────────────────
func words(_ s: String) -> [String] {
    var out: [String] = []; var cur = ""
    for ch in s { if ch.isLetter { cur.append(ch) } else { if cur.count >= 2 { out.append(cur) }; cur = "" } }
    if cur.count >= 2 { out.append(cur) }
    return out
}
func entryText(_ e: TypingHistoryEntry) -> String {
    e.contextBefore.isEmpty ? e.accepted : e.contextBefore + " " + e.accepted
}

var vFreqByLower: [String: Int] = [:]
var vCaseVariants: [String: [String: Int]] = [:]
var vCapMid: [String: Int] = [:]
for e in trainAll {
    for (w, capMid) in LearnedLexicon.tokensWithCase(entryText(e)) {
        let lw = w.lowercased()
        vFreqByLower[lw, default: 0] += 1
        vCaseVariants[lw, default: [:]][w, default: 0] += 1
        if capMid { vCapMid[lw, default: 0] += 1 }
    }
}
let vDistinctive = Set(vFreqByLower.keys.filter { Float(vCapMid[$0] ?? 0) >= 0.5 * Float(vFreqByLower[$0] ?? 1) })
let vTestWords: [(String, String)] = test.flatMap { e in words(entryText(e)).map { ($0.lowercased(), $0) } }

struct VocabConfig: Encodable {
    let name: String; let prefix: Int; let minFreq: Int; let share: Double
    let vocab: Int; let fired: Int; let correct: Int
    let precisionPct: Double; let recallPct: Double; let savedKeystrokes: Int
}
@MainActor
func vocabEval(distinctive: Bool, prefix: Int, minFreq: Int, share: Float, capOnly: Bool) -> VocabConfig {
    let keys = distinctive ? vFreqByLower.keys.filter { vDistinctive.contains($0) } : Array(vFreqByLower.keys)
    let complete: (String) -> String? = { pre in
        let p = pre.lowercased()
        var bestK = ""; var bestF = 0; var totalF = 0
        for k in keys where k.count > p.count && k.hasPrefix(p) {
            let f = vFreqByLower[k] ?? 0; totalF += f
            if f > bestF { bestF = f; bestK = k }
        }
        guard bestF >= minFreq else { return nil }
        if share > 0 && Float(bestF) < share * Float(totalF) { return nil }
        return bestK.isEmpty ? nil : bestK
    }
    let minWord = prefix + 2
    var probed = 0, fired = 0, correct = 0, saved = 0, inVocab = 0
    for (lw, orig) in vTestWords where orig.count >= minWord {
        probed += 1
        if (distinctive ? vDistinctive.contains(lw) : vFreqByLower[lw] != nil) { inVocab += 1 }
        if capOnly && orig.first?.isUppercase != true { continue }
        guard let offer = complete(String(orig.prefix(prefix))) else { continue }
        fired += 1
        if offer == lw { correct += 1; saved += (orig.count - prefix) }
    }
    return VocabConfig(
        name: (distinctive ? (capOnly ? "DISTINCTIF+Maj" : "DISTINCTIF") : "TOUT"),
        prefix: prefix, minFreq: minFreq, share: Double(share),
        vocab: keys.count, fired: fired, correct: correct,
        precisionPct: fired > 0 ? Double(correct) / Double(fired) * 100 : 0,
        recallPct: inVocab > 0 ? Double(correct) / Double(inVocab) * 100 : 0,
        savedKeystrokes: saved)
}

struct VocabResult: Encodable {
    let trainVocab: Int; let distinctive: Int; let configs: [VocabConfig]
    let contextCopyAvailPct: Int; let distinctiveEvents: Int; let avgContextLen: Int
}
let vConfigs: [(Bool, Int, Int, Float, Bool)] = [
    (false, 3, 1, 0, false), (false, 4, 3, 0.6, false),
    (true, 3, 1, 0, false), (true, 4, 2, 0.5, false),
    (true, 3, 1, 0, true), (true, 2, 1, 0, true), (true, 3, 2, 0.5, true),
]
var distEvents = 0, withPrior = 0
for e in all {
    let before = e.contextBefore.lowercased()
    for w in words(e.accepted) where vDistinctive.contains(w.lowercased()) {
        distEvents += 1
        if before.contains(w.lowercased()) { withPrior += 1 }
    }
}
let vocabResult = VocabResult(
    trainVocab: vFreqByLower.count, distinctive: vDistinctive.count,
    configs: vConfigs.map { vocabEval(distinctive: $0.0, prefix: $0.1, minFreq: $0.2, share: $0.3, capOnly: $0.4) },
    contextCopyAvailPct: distEvents > 0 ? Int(Double(withPrior) / Double(distEvents) * 100) : 0,
    distinctiveEvents: distEvents,
    avgContextLen: ctxLens.isEmpty ? 0 : ctxLens.reduce(0, +) / ctxLens.count)

// ─────────────────────────────────────────────────────────────────────────────
// 7. Rapport consolidé + résumé humain.
// ─────────────────────────────────────────────────────────────────────────────
struct Report: Encodable {
    let stats: Stats
    let triggerCurve: [TriggerResult]
    let scopingComparison: ScopingComparison
    let lexicon: LexResult
    let vocab: VocabResult
    let sampleHits: [String]
    let sampleMisses: [String]
}
let report = Report(stats: stats, triggerCurve: triggerCurve, scopingComparison: scopingComparison, lexicon: lexResult, vocab: vocabResult, sampleHits: sampleHits, sampleMisses: sampleMisses)
writeJSON(report, to: "report.json")

let t100 = triggerCurve.last!
print("""

════════════ SouffleuseCorpusEval — résumé ════════════
Corpus      : \(stats.total) entrées  (prose \(stats.prose) / accept \(stats.accept))
              contextBefore vide : \(stats.emptyContext)  | dup rate : \(stats.duplicateRatePct)%
              prose FR : \(stats.frenchProsePct)%  | vocab : \(stats.vocabSize)  | lexique distinctif : \(stats.distinctiveLexicon)
Top apps    : \(byBundle.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key)=\($0.value)" }.joined(separator: "  "))

TRIGGER (pile active complète, held-out, TRAIN 100%)
  global    : \(t100.overallProbes) probes | déclenche \(t100.overallFireRatePct)% | précision \(t100.overallPrecisionPct)% | couverture utile \(t100.overallUsefulCoveragePct)%
""")
for k in t100.kinds {
    print("  \(k.kind.padding(toLength: 11, withPad: " ", startingAt: 0)): déclenche \(k.fireRatePct)% | précision \(k.precisionPct)% | couverture utile \(k.usefulCoveragePct)%")
}
print("  correct par source : lexique=\(t100.correctBySource.learnedWord)  history-L1=\(t100.correctBySource.history)  autre=\(t100.correctBySource.other)")
let sc = scopingComparison
print("""

SCOPING par cluster (UNSCOPED baseline vs SCOPED, held-out, TRAIN 100%)
  global    : déclenche \(sc.unscopedFireRatePct)%→\(sc.scopedFireRatePct)% | précision \(sc.unscopedPrecisionPct)%→\(sc.scopedPrecisionPct)% | couverture utile \(sc.unscopedUsefulCoveragePct)%→\(sc.scopedUsefulCoveragePct)%
""")
for k in sc.byKind {
    print("  \(k.kind.padding(toLength: 11, withPad: " ", startingAt: 0)): déclenche \(k.unscopedFireRatePct)%→\(k.scopedFireRatePct)% | précision \(k.unscopedPrecisionPct)%→\(k.scopedPrecisionPct)% | couverture utile \(k.unscopedUsefulCoveragePct)%→\(k.scopedUsefulCoveragePct)%")
}
print("""

LEXIQUE (preuve « Préfixe3 » → terme appris) : \(lexResult.surfaced)/\(lexResult.tested) ressortis  (lexique=\(lexResult.viaLexicon), L1=\(lexResult.viaL1))
VOCAB copie-contexte : \(vocabResult.contextCopyAvailPct)% des termes distinctifs déjà présents avant le curseur (\(vocabResult.distinctiveEvents) events)
Sorties JSON : \(outDir)/corpus_export.json + report.json
═══════════════════════════════════════════════════════
""")
