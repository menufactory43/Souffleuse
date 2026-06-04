import Foundation
import SouffleuseCore
import SouffleuseLlama
import SouffleuseLog
import SouffleusePersonalization
import SouffleuseTyping

// Souffleuse Few-Shot A/B Eval (P1.2 / P1.3 — démonstration de la plume scopée)
//
// QUESTION : sur de VRAIS débuts de phrases support held-out de l'utilisateur
// (cluster `.web` = navigateur, là où il écrit son support Waltio), le ghost
// est-il visiblement plus « lui » quand on injecte le few-shot scopé `.web`
// (sa propre prose passée, même registre) vs le baseline Gemma 1B générique ?
//
// On génère DEUX fois par cas, côte à côte, via le VRAI chemin de prod :
//   (a) BASELINE : `examples: ""`            → Gemma 1B base, aucun style injecté.
//   (b) STYLÉ    : `examples: <few-shot>`    → bloc few-shot scopé `.web` de SA plume.
// Mêmes seed/params/bans sinon — seul le slot `examples` du prompt diffère, donc
// toute différence de ghost est imputable au few-shot.
//
// FIDÉLITÉ PROD : prompt = `LlamaPromptBuilder.buildLlamaPrompt` (slot `examples`
// en position ctxPrefix, beforeCursor strictement dernier) ; sampling = profil
// long-ghost de `ModelRuntime.midWordLongGhost` (greedy temp 0, repeatPenalty 1.3,
// repeatLastN 64, seed 0, banMarkup/banDigitsLeading/banEmoji ON, perso OFF,
// minFirstTokenProb 0, healPrefix nil car on coupe à une FRONTIÈRE de mot).
// Few-shot = `FewShotScoping.scopedExamplesPool` + `SimilarHistoryRetrieval.rank`
// (defaultK) + `buildExamplesBlock` — exactement comme `predict()`.
//
// DONNÉES : corpus EN CLAIR déjà exporté (pas de Keychain), array d'objets
// {ts, contextBefore, accepted, bundleID?, midWord?, source}. Dev-only,
// hors SHIPPING_DIRS de l'audit.
//
// Usage :
//   SOUFFLEUSE_GGUF=~/Library/Application\ Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf \
//     swift run -c release SouffleuseFewShotAB

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// ── Décodage du corpus exporté (clés du JSON ≠ TypingHistoryEntry). ──────────
// L'export utilise `ts: Double`, `midWord: Bool`, `source: String` ; on décode
// avec un struct local puis on mappe vers `TypingHistoryEntry` (le type que
// `FewShotScoping`/`SimilarHistoryRetrieval` consomment).
struct ExportEntry: Codable {
    let ts: Double
    let contextBefore: String
    let accepted: String
    let bundleID: String?
    let midWord: Bool?
    let source: String
}

extension ExportEntry {
    func toHistory() -> TypingHistoryEntry {
        TypingHistoryEntry(
            timestamp: Date(timeIntervalSince1970: ts),
            contextBefore: contextBefore,
            accepted: accepted,
            bundleID: bundleID,
            midWordContinuation: midWord,
            source: source == "prose" ? .prose : .accept
        )
    }
}

let exportPath = "/tmp/cocotypist-eval/corpus_export.json"
guard let data = FileManager.default.contents(atPath: exportPath) else {
    err("[fewshot-ab] FATAL: cannot read \(exportPath)"); exit(1)
}
let decoded: [ExportEntry]
do {
    decoded = try JSONDecoder().decode([ExportEntry].self, from: data)
} catch {
    err("[fewshot-ab] FATAL: decode failed: \(error)"); exit(1)
}
err("[fewshot-ab] corpus entries loaded: \(decoded.count)")

// ── 1. Garde la prose `.web` de longueur ≥ 40 car. (FALLBACK si trop peu). ───
let activeDomain: DomainCluster = .web
let allProse = decoded.filter { $0.source == "prose" }.map { $0.toHistory() }
// Prose `.web` PROPRE : on passe par le filtre de prod (scopé `.web` + sans
// URL/chemin/salutation) pour que les cas TEST soient de la VRAIE prose support,
// pas des liens collés — sinon le few-shot stylé n'a rien à démontrer.
let webProse = FewShotScoping.scopedExamplesPool(allProse, activeDomain: .web)
    .filter { $0.accepted.count >= 40 }
var usedFallback = false
var pool: [TypingHistoryEntry]
if webProse.count >= 12 {
    pool = webProse
    err("[fewshot-ab] prose .web PROPRE (≥ 40 car., sans URL/chemin): \(pool.count) entrées")
} else {
    usedFallback = true
    pool = FewShotScoping.scopedExamplesPool(allProse, activeDomain: .other)
        .filter { $0.accepted.count >= 40 }
    err("[fewshot-ab] FALLBACK: trop peu de prose .web propre (\(webProse.count)) → toute la prose propre ≥ 40 car. : \(pool.count) entrées")
}
guard pool.count >= 9 else {
    err("[fewshot-ab] FATAL: pas assez de prose (\(pool.count)) pour 8 TEST + few-shot"); exit(1)
}

// Ordre stable (par timestamp) pour des indices déterministes.
pool.sort { $0.timestamp < $1.timestamp }

// ── 2. Held-out : 8 phrases TEST à indices régulièrement espacés ; le RESTE
//      (passé par scopedExamplesPool) = pool de few-shot. ──────────────────────
let testCount = 8
let n = pool.count
var testIdx: [Int] = []
if n <= testCount {
    testIdx = Array(0..<n)
} else {
    // Indices régulièrement espacés sur [0, n-1].
    for k in 0..<testCount {
        let idx = Int((Double(k) * Double(n - 1) / Double(testCount - 1)).rounded())
        if testIdx.last != idx { testIdx.append(idx) }
    }
    // Anti-collision (arrondi) : complète si doublon a raboté la liste.
    var probe = 0
    while testIdx.count < testCount, probe < n {
        if !testIdx.contains(probe) { testIdx.append(probe) }
        probe += 1
    }
    testIdx.sort()
}
let testSet = Set(testIdx)
let testEntries = testIdx.map { pool[$0] }
let restEntries = pool.enumerated().filter { !testSet.contains($0.offset) }.map { $0.element }
// Pool few-shot = le reste, filtré comme en prod (scopé `.web`, prose, non-salutation).
let fewShotPool = FewShotScoping.scopedExamplesPool(restEntries, activeDomain: activeDomain)
err("[fewshot-ab] TEST: \(testEntries.count) | reste: \(restEntries.count) → few-shot pool scopé: \(fewShotPool.count)")

// ── 3. Découpe d'un PRÉFIXE à une frontière de mot autour des 25-40 premiers car.
//      userTail = préfixe ; trueContinuation = le reste. ──────────────────────
func splitPrefix(_ s: String) -> (prefix: String, cont: String)? {
    let chars = Array(s)
    guard chars.count >= 41 else { return nil }
    // Cherche la dernière frontière d'espace dans [25, 40] ; sinon coupe à 33.
    var cut = -1
    let lo = 25, hi = min(40, chars.count - 1)
    var i = hi
    while i >= lo {
        if chars[i] == " " { cut = i; break }
        i -= 1
    }
    if cut < 0 {
        // Pas d'espace dans la fenêtre → cherche le 1er espace après 25.
        var j = lo
        while j < chars.count, chars[j] != " " { j += 1 }
        cut = j < chars.count ? j : 33
    }
    let prefix = String(chars[0..<cut]).trimmingCharacters(in: .whitespaces)
    let cont = String(chars[cut...]).trimmingCharacters(in: .whitespaces)
    guard !prefix.isEmpty, !cont.isEmpty else { return nil }
    return (prefix, cont)
}

// ── Boot engine (même GGUF que prod). ──────────────────────────────────────
let ggufPath: String = {
    if let p = ProcessInfo.processInfo.environment["SOUFFLEUSE_GGUF"], !p.isEmpty {
        return (p as NSString).expandingTildeInPath
    }
    return (("~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf") as NSString)
        .expandingTildeInPath
}()
let engine = LlamaEngine()
err("[fewshot-ab] loading GGUF: \(ggufPath)")
guard await engine.load(modelPath: ggufPath, contextTokens: 4096) else {
    err("[fewshot-ab] FATAL: could not load GGUF"); exit(1)
}

// ── 5. Une génération via le VRAI chemin prod (long-ghost greedy). Seul le slot
//      `examples` varie entre baseline et stylé. ─────────────────────────────
func ghost(prefix: String, examples: String) async -> String {
    let prompt = LlamaPromptBuilder.buildLlamaPrompt(
        system: "", customInstr: "", ctxPrefix: "", fieldContext: "",
        afterCursor: "", beforeCursor: prefix,
        examples: examples
    )
    final class Acc: @unchecked Sendable { var text = "" }
    let acc = Acc()
    _ = await engine.generate(
        prompt: prompt,
        maxTokens: 28,  // ~24-32 tokens : budget long-ghost
        sampling: LlamaSampling(
            temperature: 0,
            repeatPenalty: 1.3,
            repeatLastN: 64,
            seed: 0,
            personalizationStrength: 0,
            banMarkup: true,
            banDigitsLeading: true,
            banEmoji: true,
            minFirstTokenProb: 0,
            // Coupe à une FRONTIÈRE de mot → on génère le mot SUIVANT, pas une
            // complétion de fragment → healPrefix nil (comme isBoundary en prod).
            healPrefix: nil
        )
    ) { piece in acc.text += piece; return true }
    // Première ligne nettoyée (le ghost est mono-ligne en prod).
    return OutputFilter.singleLine(acc.text).trimmingCharacters(in: .whitespaces)
}

func clip(_ s: String, _ n: Int) -> String {
    s.count <= n ? s : String(s.prefix(n)) + "…"
}

// ── 6. Génère et imprime les blocs côte-à-côte. ──────────────────────────────
print("\n════════════ Few-Shot A/B Eval — la plume scopée \(activeDomain.rawValue) (P1.2/P1.3) ════════════")
print("corpus prose total: \(allProse.count) | prose \(activeDomain.rawValue) ≥40c: \(webProse.count) | few-shot pool scopé: \(fewShotPool.count)")
if usedFallback { print("⚠️  FALLBACK ACTIF : trop peu de prose \(activeDomain.rawValue) → pool = toute la prose ≥ 40 car.") }
print("sampling: temp 0 greedy · repeatPenalty 1.3 · repeatLastN 64 · seed 0 · bans markup/digits/emoji · perso OFF · maxTokens 28")
print("(seul le slot few-shot du prompt diffère entre baseline et STYLÉ)\n")

var changedCount = 0
var caseNo = 0
for entry in testEntries {
    // Reconstruit la phrase complète comme en prod : contextBefore + " " + accepted.
    let full = entry.contextBefore.isEmpty
        ? entry.accepted
        : entry.contextBefore + " " + entry.accepted
    guard let (prefix, cont) = splitPrefix(full) else {
        err("[fewshot-ab] skip (trop court): \(clip(full, 30))")
        continue
    }
    caseNo += 1

    // 4. Few-shot scopé : rank(pool, userTail=préfixe, defaultK) → buildExamplesBlock.
    let ranked = SimilarHistoryRetrieval.rank(
        entries: fewShotPool,
        userTail: prefix,
        limit: SimilarHistoryRetrieval.defaultK
    )
    let examplesBlock = SimilarHistoryRetrieval.buildExamplesBlock(from: ranked)

    let baseline = await ghost(prefix: prefix, examples: "")
    let styled = await ghost(prefix: prefix, examples: examplesBlock)
    let differs = baseline != styled
    if differs { changedCount += 1 }

    print("── cas \(caseNo) ──")
    print("préfixe   : « \(prefix) »")
    print("VRAI      : « \(clip(cont, 90)) »")
    print("baseline  : « \(clip(baseline, 90)) »")
    print("STYLÉ     : « \(clip(styled, 90)) »\(differs ? "   ← few-shot de TA plume" : "   (= baseline)")")
    if ranked.isEmpty {
        print("few-shot  : (aucun exemple ne matche le préfixe — pool scopé sans overlap Jaccard ≥ \(SimilarHistoryRetrieval.minRelevanceScore))")
    } else {
        print("few-shot injectés (\(ranked.count)) :")
        for ex in ranked.prefix(3) {
            let line = ex.contextBefore.isEmpty ? ex.accepted : ex.contextBefore + " " + ex.accepted
            print("    · \(clip(line, 80))")
        }
    }
    print("")
}

print("════════════ Bilan ════════════")
print("cas où STYLÉ ≠ baseline (le few-shot a changé le ghost) : \(changedCount)/\(caseNo)")
print("═══════════════════════════════\n")
