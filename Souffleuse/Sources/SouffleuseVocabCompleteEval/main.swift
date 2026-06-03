import Foundation
import SouffleusePersonalization

// Souffleuse Learned-Vocabulary Completer Eval
//
// La capture Cotypist montre le VRAI mécanisme voulu : tu tapes « Bin », il
// complète « ance ». Ce n'est pas « deviner Binance d'après le sens » (next-word,
// la piste précédente) mais COMPLÉTER LE MOT EN COURS à partir de TON
// vocabulaire appris. Le préfixe tapé est le garde-fou : pas de « Binance » tant
// que tu n'as pas tapé « Bin… » → zéro sur-injection par construction, et une
// seule occurrence suffit à apprendre le mot.
//
// Cet eval MESURE, sur ton vrai history.db (lu via TypingHistoryStore, voie
// sanctionnée), ce qu'un tel complèteur donnerait — AVANT d'écrire quoi que ce
// soit dans l'app. Held-out 80/20 : vocabulaire construit sur TRAIN, simulation
// de frappe sur TEST.
//
// Métriques :
//   recall    = parmi les mots du test (assez longs), combien le complèteur
//               propose-t-il CORRECTEMENT à partir de leurs premières lettres.
//   précision = quand il propose, à quel taux a-t-il RAISON (le mot offert =
//               le mot réellement tapé). 1 − précision = taux de faux positifs.
//   keystrokes épargnés = lettres économisées sur les complétions correctes.
//
// Privacy : agrégats only (sauf SOUFFLEUSE_SHOW_EXAMPLES=1). Diagnostic d'un
// terme précis via SOUFFLEUSE_TERM=Binance.
//
// Knobs : SOUFFLEUSE_PREFIX (longueur déclenchement, déf 3),
//         SOUFFLEUSE_MINFREQ (fréquence vocab min, déf 1),
//         SOUFFLEUSE_SHARE (dominance parmi les mots du même préfixe, déf 0).

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
let env = ProcessInfo.processInfo.environment
let showExamples = env["SOUFFLEUSE_SHOW_EXAMPLES"] == "1"
let prefixLen = env["SOUFFLEUSE_PREFIX"].flatMap(Int.init) ?? 3
let minFreq = env["SOUFFLEUSE_MINFREQ"].flatMap(Int.init) ?? 1
let shareGuard = env["SOUFFLEUSE_SHARE"].flatMap(Float.init) ?? 0
let distinctiveOnly = env["SOUFFLEUSE_DISTINCTIVE"] == "1"
let minWordLen = prefixLen + 2   // n'a de sens que si la complétion économise ≥2 lettres

// « Distinctif » = nom propre / marque / jargon que le dico système rate.
// Signal autonome (pas de NSSpellChecker, qui bloque en CLI) : un mot
// MAJORITAIREMENT capitalisé EN MILIEU DE PHRASE (donc pas juste en tête de
// phrase) → Binance, Fiscalio, Aurélien, iPhone… tandis que « Bonjour »/« Merci »
// (capitalisés seulement en début de phrase) restent exclus. Renseigné pendant
// la tokenisation enrichie ci-dessous.

// ── Tokenisation en mots (lettres + accents ; apostrophe = séparateur). ──────
func words(_ s: String) -> [String] {
    var out: [String] = []
    var cur = ""
    for ch in s {
        if ch.isLetter { cur.append(ch) }
        else { if cur.count >= 2 { out.append(cur) }; cur = "" }
    }
    if cur.count >= 2 { out.append(cur) }
    return out
}

// Tokens enrichis : pour chaque mot, est-il capitalisé EN MILIEU de phrase ?
// (= 1ʳᵉ lettre majuscule ET non précédé d'un terminateur de phrase / début).
func tokensWithCase(_ s: String) -> [(word: String, capMid: Bool)] {
    var out: [(String, Bool)] = []
    var cur = ""
    var sentenceStart = true          // le tout 1ᵉʳ mot compte comme début de phrase
    var pendingTerminator = false     // a-t-on vu . ! ? : depuis le dernier mot ?
    func flush() {
        if cur.count >= 2 {
            let cap = cur.first?.isUppercase == true
            out.append((cur, cap && !sentenceStart))
            sentenceStart = false
        }
        cur = ""
        if pendingTerminator { sentenceStart = true; pendingTerminator = false }
    }
    for ch in s {
        if ch.isLetter { cur.append(ch) }
        else {
            flush()
            if ch == "." || ch == "!" || ch == "?" || ch == ":" || ch == "\n" { pendingTerminator = true }
        }
    }
    flush()
    return out
}

// ── Charge l'historique réel. SOUFFLEUSE_HISTORY_DB permet de lire une COPIE
//    (évite la contention de verrou SQLCipher avec une autre session/worktree).
let store: TypingHistoryStore = {
    if let p = env["SOUFFLEUSE_HISTORY_DB"], !p.isEmpty {
        return TypingHistoryStore(fileURL: URL(fileURLWithPath: (p as NSString).expandingTildeInPath))
    }
    return TypingHistoryStore()
}()
let all = await store.allEntries()
err("[vocab] history entries: \(all.count)")
guard all.count >= 20 else { print("Historique trop petit (\(all.count))."); exit(0) }

func entryText(_ e: TypingHistoryEntry) -> String {
    e.contextBefore.isEmpty ? e.accepted : e.contextBefore + " " + e.accepted
}

// Held-out 80/20.
var trainEntries: [TypingHistoryEntry] = []
var testEntries: [TypingHistoryEntry] = []
for (i, e) in all.enumerated() { if i % 5 == 0 { testEntries.append(e) } else { trainEntries.append(e) } }

// ── Maps de base (TRAIN), calculées UNE fois (un seul accès Keychain). ───────
var freqByLower: [String: Int] = [:]
var caseVariants: [String: [String: Int]] = [:]   // lower -> (variante -> count)
var capMidCount: [String: Int] = [:]              // lower -> #occurrences cap. milieu de phrase
for e in trainEntries {
    for (w, capMid) in tokensWithCase(entryText(e)) {
        let lw = w.lowercased()
        freqByLower[lw, default: 0] += 1
        caseVariants[lw, default: [:]][w, default: 0] += 1
        if capMid { capMidCount[lw, default: 0] += 1 }
    }
}
let canonical: (String) -> String = { lower in
    (caseVariants[lower]?.max { $0.value < $1.value }?.key) ?? lower
}
let totalVocab = freqByLower.count
// Sous-ensemble DISTINCTIF : mots majoritairement capitalisés en milieu de
// phrase (≥50%) → noms propres / marques / jargon (Binance, Fiscalio, Aurélien).
let distinctiveKeys = Set(freqByLower.keys.filter {
    Float(capMidCount[$0] ?? 0) >= 0.5 * Float(freqByLower[$0] ?? 1)
})
// Mots test une fois (lower, original) pour réutilisation par config.
let testWords: [(String, String)] = testEntries.flatMap { e in words(entryText(e)).map { ($0.lowercased(), $0) } }

struct Metrics { let vocab: Int; let probed: Int; let inVocab: Int; let fired: Int; let correct: Int; let prec: Double; let recall: Double; let saved: Int }
// capOnly : ne déclenche que si le mot EN COURS est capitalisé (signal « nom
// propre » — comme « Bin » dans la capture). Élimine les faux positifs sur les
// mots courants minuscules.
let evaluate: (Bool, Int, Int, Float, Bool) -> Metrics = { distinctive, prefix, minFreq, share, capOnly in
    let keys = distinctive ? freqByLower.keys.filter { distinctiveKeys.contains($0) } : Array(freqByLower.keys)
    let complete: (String) -> String? = { pre in
        let p = pre.lowercased()
        var bestK = ""; var bestF = 0; var totalF = 0
        for k in keys where k.count > p.count && k.hasPrefix(p) {
            let f = freqByLower[k] ?? 0; totalF += f
            if f > bestF { bestF = f; bestK = k }
        }
        guard bestF >= minFreq else { return nil }
        if share > 0 && Float(bestF) < share * Float(totalF) { return nil }
        return bestK.isEmpty ? nil : bestK
    }
    let minWord = prefix + 2
    var probed = 0, fired = 0, correct = 0, saved = 0, inVocab = 0
    for (lw, orig) in testWords where orig.count >= minWord {
        probed += 1
        if (distinctive ? distinctiveKeys.contains(lw) : freqByLower[lw] != nil) { inVocab += 1 }
        if capOnly && orig.first?.isUppercase != true { continue }
        guard let offer = complete(String(orig.prefix(prefix))) else { continue }
        fired += 1
        if offer == lw { correct += 1; saved += (orig.count - prefix) }
    }
    return Metrics(vocab: keys.count, probed: probed, inVocab: inVocab, fired: fired, correct: correct,
                   prec: fired > 0 ? Double(correct)/Double(fired)*100 : 0,
                   recall: inVocab > 0 ? Double(correct)/Double(inVocab)*100 : 0, saved: saved)
}

print("\n════════════ Learned-Vocabulary Completer — données réelles ════════════")
print("history entries : \(all.count)  (train \(trainEntries.count) / test \(testEntries.count))")
print("vocabulaire TRAIN : \(totalVocab) mots  |  dont DISTINCTIFS (noms propres/marques) : \(distinctiveKeys.count)")
print("\n  variante           pre fréq dom |  vocab  propose  correct   préc%  recall%  saved")
let configs: [(String, Bool, Int, Int, Float, Bool)] = [
    ("TOUT le vocab",     false, 3, 1, 0,   false),
    ("TOUT le vocab",     false, 4, 3, 0.6, false),
    ("DISTINCTIF",        true,  3, 1, 0,   false),
    ("DISTINCTIF",        true,  4, 2, 0.5, false),
    ("DISTINCTIF +Maj",   true,  3, 1, 0,   true),
    ("DISTINCTIF +Maj",   true,  2, 1, 0,   true),
    ("DISTINCTIF +Maj",   true,  3, 2, 0.5, true),
]
for (name, dist, pre, mf, sh, cap) in configs {
    let m = evaluate(dist, pre, mf, sh, cap)
    print(String(format: "  %-18s %d   %d   %.1f |  %5d   %5d    %5d   %5.1f   %5.1f   %5d",
                 (name as NSString).utf8String!, pre, mf, sh, m.vocab, m.fired, m.correct, m.prec, m.recall, m.saved))
}

// ── Disponibilité « copie-contexte » : quand tu tapes un terme distinctif,
//    était-il DÉJÀ présent plus tôt dans le contextBefore (texte AX avant le
//    curseur) ? Si oui → la copie LLM le ressortirait sans rien apprendre.
//    BORNE BASSE : contextBefore est tronqué, sans l'après-curseur ni l'OCR. ──
var distEvents = 0, withPrior = 0
var ctxLens: [Int] = []
for e in all {
    ctxLens.append(e.contextBefore.count)
    let before = e.contextBefore.lowercased()
    for w in words(e.accepted) {
        let lw = w.lowercased()
        guard distinctiveKeys.contains(lw) else { continue }
        distEvents += 1
        if before.contains(lw) { withPrior += 1 }
    }
}
let avgCtx = ctxLens.isEmpty ? 0 : ctxLens.reduce(0, +) / ctxLens.count
print("\n── Disponibilité copie-contexte (texte AX avant curseur, borne basse) ──")
print("  longueur moyenne du contextBefore : \(avgCtx) caractères")
print("  fois où tu TAPES un terme distinctif : \(distEvents)")
print("  └ terme DÉJÀ dans le contexte avant  : \(withPrior)" + (distEvents > 0 ? String(format: "  (%.0f%%)", Double(withPrior)/Double(distEvents)*100) : ""))
print("  → ce % = copie gratuite ; le reste exigerait OCR/après-curseur/injection")

// ── Diagnostic terme (ex. Binance) : en mode DISTINCTIF, préfixe 3. ──────────
if let term = env["SOUFFLEUSE_TERM"], !term.isEmpty {
    let lt = term.lowercased()
    let f = freqByLower[lt] ?? 0
    let isDist = distinctiveKeys.contains(lt)
    var typedWithPrior = 0, typedTotal = 0
    for e in all where words(e.accepted).contains(where: { $0.lowercased() == lt }) {
        typedTotal += 1
        if e.contextBefore.lowercased().contains(lt) { typedWithPrior += 1 }
    }
    print("\n─ terme « \(term) » : fréquence TRAIN = \(f)  |  classé distinctif : \(isDist ? "oui" : "non")")
    print("    fois tapé avec « \(term) » DÉJÀ dans le contexte avant : \(typedWithPrior)/\(typedTotal)  ← copie gratuite")
    if f > 0 {
        let keys = freqByLower.keys.filter { distinctiveKeys.contains($0) }
        for k in [2, 3, 4] where k < lt.count {
            let pre = String(lt.prefix(k))
            let group = keys.filter { $0.count > pre.count && $0.hasPrefix(pre) }
            let best = group.max { (freqByLower[$0] ?? 0) < (freqByLower[$1] ?? 0) }
            let ok = best == lt
            print("    préfixe « \(pre) » (mode distinctif) → « \(best.map(canonical) ?? "∅") »  \(ok ? "✓" : "✗")   [\(group.count) mots distinctifs partagent ce préfixe]")
        }
    }
}
print("════════════════════════════════════════════════════════════════════════\n")
