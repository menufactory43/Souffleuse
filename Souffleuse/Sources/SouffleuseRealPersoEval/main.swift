import Foundation
import SouffleuseCore
import SouffleuseLlama
import SouffleuseLog
import SouffleusePersonalization
import SouffleuseTyping

// Souffleuse Real-Data Personalization Eval
//
// Le `SouffleusePersonalizationEval` prouve la PLOMBERIE sur un corpus
// synthétique (phrases rejouées verbatim ×3). Ici on répond à la VRAIE
// question opérationnelle, sur ton `history.db` réel (lu via le seul
// `TypingHistoryStore`, voie sanctionnée — comme `SouffleuseRecallEval`) :
//
//   A. RÉCURRENCE INTRINSÈQUE (le test « déduplication ») — tes contextes de
//      ~4 mots reviennent-ils assez souvent (count ≥ 3) pour qu'une promotion
//      puisse s'armer un jour ? Si non, le levier est quasi-mort en vrai.
//   B. GÉNÉRALISATION — sur un held-out 80/20, à quelle fréquence un contexte
//      INÉDIT rejoue-t-il un contexte appris assez fort pour armer la
//      promotion ; et quand on génère, le terme réel ressort-il (lift LLM) ?
//
// PRIVACY : sortie en AGRÉGATS uniquement (compteurs, ratios). Aucun texte
// utilisateur n'est imprimé, sauf si SOUFFLEUSE_SHOW_EXAMPLES=1 (opt-in
// explicite, sur ta propre machine, pour juger la qualité). Cet exécutable est
// dev-only (hors SHIPPING_DIRS de l'audit).
//
// Usage :
//   SOUFFLEUSE_GGUF=~/Library/Application\ Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf \
//     swift run -c release SouffleuseRealPersoEval

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
let env = ProcessInfo.processInfo.environment
let showExamples = env["SOUFFLEUSE_SHOW_EXAMPLES"] == "1"
let pMatchLen = env["SOUFFLEUSE_PROMOTE_MATCHLEN"].flatMap(Int.init) ?? LlamaEngine.promoteMatchLen
let pMinCount = env["SOUFFLEUSE_PROMOTE_MINCOUNT"].flatMap(Int.init) ?? LlamaEngine.promoteMinCount
let pShare = env["SOUFFLEUSE_PROMOTE_SHARE"].flatMap(Float.init) ?? LlamaEngine.promoteShare
err("[real-perso] thresholds: matchLen=\(pMatchLen) minCount=\(pMinCount) share=\(pShare)")

// ── Charge le vrai historique (voie sanctionnée). ───────────────────────────
let store = TypingHistoryStore()
let all = await store.allEntries()
err("[real-perso] history entries: \(all.count)")
guard all.count >= 20 else {
    print("Historique trop petit (\(all.count) entrées) — rien à mesurer de fiable.")
    exit(0)
}

// Production corpus string : contextBefore + " " + accepted (ou accepted seul).
func corpusString(_ e: TypingHistoryEntry) -> String {
    e.contextBefore.isEmpty ? e.accepted : e.contextBefore + " " + e.accepted
}
// Le préfixe « tapé » que la promotion verrait = contextBefore. La vérité = le
// premier mot d'`accepted`.
func firstWord(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? ""
}
func contains(_ hay: String, _ needle: String) -> Bool {
    !needle.isEmpty && hay.lowercased().contains(needle.lowercased())
}

// ── Boot engine. ────────────────────────────────────────────────────────────
let ggufPath: String = {
    if let p = ProcessInfo.processInfo.environment["SOUFFLEUSE_GGUF"], !p.isEmpty {
        return (p as NSString).expandingTildeInPath
    }
    return (("~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf") as NSString)
        .expandingTildeInPath
}()
let engine = LlamaEngine()
err("[real-perso] loading GGUF…")
guard await engine.load(modelPath: ggufPath, contextTokens: 4096) else {
    err("[real-perso] FATAL: could not load GGUF"); exit(1)
}

func histo(_ xs: [Int]) -> String {
    let one = xs.filter { $0 == 1 }.count
    let two = xs.filter { $0 == 2 }.count
    let three = xs.filter { $0 >= 3 }.count
    return "count==1:\(one)  count==2:\(two)  count>=3:\(three)"
}

// ════════════ PASS A — récurrence intrinsèque (corpus = TOUT) ════════════════
await engine.setCorpus(all.map(corpusString))
var aMatch5 = 0, aArm = 0
var aTopCounts: [Int] = []
var aExamples: [(Int, Float)] = []
for e in all {
    let ctx = e.contextBefore
    guard !ctx.isEmpty else { continue }
    let p = await engine.probePromotion(prefix: ctx, matchLen: pMatchLen, minCount: pMinCount, share: pShare)
    if p.matchLen >= 5 { aMatch5 += 1; aTopCounts.append(p.topCount) }
    if p.wouldArm { aArm += 1; if aExamples.count < 8 { aExamples.append((p.matchLen, p.share)) } }
}
let aWithCtx = all.filter { !$0.contextBefore.isEmpty }.count

// ════════════ DIAGNOSTIC TERME (corpus = TOUT) ══════════════════════════════
// SOUFFLEUSE_TERM=Binance → pourquoi un terme précis (sou)ressort-il ou pas.
// Répond à « j'ai pourtant tapé Binance >3 fois ». On regarde : combien
// d'entrées le contiennent, où (accepted vs contextBefore), et — le point clé —
// pour chaque occurrence, le CONTEXTE qui précède le terme récurre-t-il (count)
// au point d'armer la promotion.
if let term = env["SOUFFLEUSE_TERM"], !term.isEmpty {
    let lc = term.lowercased()
    // Token-cible = forme continuation (précédée d'un espace, comme en contexte).
    let targetTok: Int32? = await engine.tokenizeForCorpus(" " + term).first
    var inAccepted = 0, inContext = 0, total = 0, withCtx = 0
    var longArm = 0           // armerait à contexte LONG (la promo actuelle)
    var promotable = 0        // ∃ longueur L où Binance est count≥3 ET dominant (share≥0.6)
    var freqNotDominant = 0   // ∃ L où count≥3 mais jamais dominant (un biais-mot serait bruité)
    var rare = 0              // jamais count≥3 à aucune longueur
    for e in all {
        let full = corpusString(e)
        if e.accepted.lowercased().contains(lc) { inAccepted += 1 }
        if e.contextBefore.lowercased().contains(lc) { inContext += 1 }
        let hay = full.lowercased()
        var searchFrom = hay.startIndex
        while let r = hay.range(of: lc, range: searchFrom..<hay.endIndex) {
            total += 1
            searchFrom = r.upperBound
            let prefix = String(full[full.startIndex..<full.index(full.startIndex, offsetBy: hay.distance(from: hay.startIndex, to: r.lowerBound))])
                .trimmingCharacters(in: .whitespaces)
            guard !prefix.isEmpty, let tgt = targetTok else { continue }
            withCtx += 1
            let ctxIds = await engine.tokenizeForCorpus(prefix)
            // Backoff : pour chaque longueur de contexte L (court → long), quel
            // est le count/share de BINANCE spécifiquement comme continuation ?
            var bestCount = 0, bestShare: Float = 0
            for L in 1...min(8, ctxIds.count) {
                let ctx = Array(ctxIds.suffix(L))
                let (cands, _) = await engine.suffixArrayCandidates(after: ctx)
                guard let c = cands[tgt], c > 0 else { continue }
                let tot = cands.values.reduce(0, +)
                let sh = Float(c) / Float(max(1, tot))
                if c > bestCount { bestCount = c }
                if c >= pMinCount && sh > bestShare { bestShare = sh }
            }
            // Long-context (promo actuelle) : armerait-elle ?
            let pp = await engine.probePromotion(prefix: prefix, matchLen: pMatchLen, minCount: pMinCount, share: pShare)
            if pp.wouldArm { longArm += 1 }
            if bestCount >= pMinCount && bestShare >= pShare { promotable += 1 }
            else if bestCount >= pMinCount { freqNotDominant += 1 }
            else { rare += 1 }
        }
    }
    print("\n════════════ Diagnostic terme « \(term) » ════════════")
    print("  entrées contenant le terme        : \(inAccepted + inContext) (accepted:\(inAccepted)  contextBefore:\(inContext))")
    print("  occurrences avec contexte avant   : \(withCtx)/\(total)")
    print("  ─ classement par occurrence (en cherchant Binance à TOUTE longueur de contexte) :")
    print("    promotable (count≥\(pMinCount) ET dominant≥\(pShare))   : \(promotable)  ← un fix backoff les ferait ressortir")
    print("    fréquent mais NON dominant            : \(freqNotDominant)  ← biais-mot = bruité (Binance pas le choix dominant)")
    print("    rare (jamais count≥\(pMinCount))                : \(rare)")
    print("  → promo ACTUELLE (contexte long) arme : \(longArm)/\(withCtx)")
    print("════════════════════════════════════════════════════════\n")
}

// ════════════ PASS B — généralisation 80/20 + lift LLM ══════════════════════
var train: [TypingHistoryEntry] = []
var test: [TypingHistoryEntry] = []
for (i, e) in all.enumerated() { if i % 5 == 0 { test.append(e) } else { train.append(e) } }
await engine.setCorpus(train.map(corpusString))

var bProbed = 0, bArm = 0
var armedTest: [TypingHistoryEntry] = []
for e in test {
    let ctx = e.contextBefore
    guard !ctx.isEmpty else { continue }
    bProbed += 1
    let p = await engine.probePromotion(prefix: ctx, matchLen: pMatchLen, minCount: pMinCount, share: pShare)
    if p.wouldArm { bArm += 1; armedTest.append(e) }
}

// LLM lift : sur les cas held-out où la promotion s'arme, le vrai mot ressort-il
// (promo) vs pas (base) ? Profil prod (greedy, bans), healing off (next-word).
func runOnce(_ prefix: String, promote: Bool) async -> String {
    let prompt = LlamaPromptBuilder.buildLlamaPrompt(
        system: "", customInstr: "", ctxPrefix: "", fieldContext: "",
        afterCursor: "", beforeCursor: prefix
    )
    final class Acc: @unchecked Sendable { var t = "" }
    let acc = Acc()
    _ = await engine.generate(
        prompt: prompt, maxTokens: 6,
        sampling: LlamaSampling(
            temperature: 0, repeatPenalty: 1.3, repeatLastN: 64,
            // Strength ON in BOTH arms — only `promoteStrongMatches` differs, so
            // the lift isolates the NEW promotion tier over the existing bias.
            personalizationStrength: LlamaSampling.personalizationGainScale,
            banMarkup: true, banDigitsLeading: true, banEmoji: true,
            promoteStrongMatches: promote,
            promoteMatchLen: Int32(pMatchLen), promoteMinCount: Int32(pMinCount), promoteShare: pShare,
            minFirstTokenProb: 0.0001, healPrefix: nil
        )
    ) { tok in acc.t += tok; return true }
    return acc.t.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? acc.t
}

let llmCap = 60
let sample = Array(armedTest.prefix(llmCap))
var truthHitBase = 0, truthHitPromo = 0, changed = 0, changedToTruth = 0
var bExamples: [(String, String, String)] = []  // ctx, base, promo (opt-in)
for e in sample {
    let truth = firstWord(e.accepted)
    guard !truth.isEmpty else { continue }
    let base = await runOnce(e.contextBefore, promote: false)
    let promo = await runOnce(e.contextBefore, promote: true)
    if contains(base, truth) { truthHitBase += 1 }
    if contains(promo, truth) { truthHitPromo += 1 }
    if firstWord(base) != firstWord(promo) {
        changed += 1
        if contains(promo, truth) && !contains(base, truth) { changedToTruth += 1 }
    }
    if showExamples && bExamples.count < 12 { bExamples.append((e.contextBefore, base, promo)) }
}

// ════════════════════════════ REPORT ════════════════════════════════════════
print("\n════════════ Real-Data Personalization Eval ════════════")
print("history entries (deduped by store) : \(all.count)")
print("\n── PASS A · récurrence intrinsèque (corpus = tout l'historique) ──")
print("  entrées avec contexte             : \(aWithCtx)")
print("  contexte ≥ 5 tokens matché        : \(aMatch5)")
print("  └ distribution du count           : \(histo(aTopCounts))")
print("  PROMOTION s'armerait              : \(aArm)/\(aWithCtx)")
print("  → si count>=3 ≈ 0, la dédup tue le levier (contextes jamais assez répétés)")
print("\n── PASS B · généralisation (held-out 80/20) ──")
print("  train / test                      : \(train.count) / \(test.count)")
print("  prefixes test probés              : \(bProbed)")
print("  PROMOTION s'armerait sur INÉDIT   : \(bArm)/\(bProbed)")
print("\n── PASS B · lift LLM (sur \(sample.count) cas armés held-out) ──")
print("  vrai mot ressorti (base)          : \(truthHitBase)/\(sample.count)")
print("  vrai mot ressorti (PROMO)         : \(truthHitPromo)/\(sample.count)")
print("  ghost changé par la promo         : \(changed)")
print("  └ changé VERS le vrai mot         : \(changedToTruth)  (le reste = changement neutre/incertain)")
if showExamples && !bExamples.isEmpty {
    print("\n── exemples (opt-in SOUFFLEUSE_SHOW_EXAMPLES) — ctx | base → promo ──")
    for (c, b, p) in bExamples {
        print("    «…\(String(c.suffix(40)))» | \(b.trimmingCharacters(in: .whitespaces)) → \(p.trimmingCharacters(in: .whitespaces))")
    }
}
print("════════════════════════════════════════════════════════\n")
