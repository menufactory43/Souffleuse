import Foundation
import SouffleuseCore
import SouffleuseCorpus
import SouffleusePersonalization
import SouffleuseTyping

// Souffleuse Lexicon Route Eval — preuve BOUT-EN-BOUT
//
// Exerce le VRAI chemin de prod : `LearnedLexicon` (bâti depuis ton historique
// réel) + `SuggestionPolicyEngine.routeInstant(... lexicon:)` — exactement ce
// qui tournera dans l'app. AUCUN LLM (routeInstant est pur → instantané, pas de
// GGUF). Pour chaque terme distinctif appris, on simule la frappe « <lead> Bin »
// et on vérifie que routeInstant renvoie un ghost source `.learnedWord` qui
// reconstruit le terme (« Bin »→« ance »).
//
// Lecture historique via TypingHistoryStore (voie sanctionnée). SOUFFLEUSE_HISTORY_DB
// pour lire une COPIE (évite le lock SQLCipher avec une autre session).
//
// Usage : swift run -c release SouffleuseLexiconRouteEval   (pas de GGUF requis)

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
let env = ProcessInfo.processInfo.environment
let showExamples = env["SOUFFLEUSE_SHOW_EXAMPLES"] != "0"   // on montre par défaut (c'est la preuve)
let topN = env["SOUFFLEUSE_TOPN"].flatMap(Int.init) ?? 40

let store: TypingHistoryStore = {
    if let p = env["SOUFFLEUSE_HISTORY_DB"], !p.isEmpty {
        return TypingHistoryStore(fileURL: URL(fileURLWithPath: (p as NSString).expandingTildeInPath))
    }
    return TypingHistoryStore()
}()
let history = await store.allEntries()
err("[lexroute] history entries: \(history.count)")
guard history.count >= 20 else { print("Historique trop petit (\(history.count))."); exit(0) }

// Construit le lexique exactement comme PVM le fera.
let lexicon = LearnedLexicon.build(from: history)
err("[lexroute] lexique distinctif: \(lexicon.count) termes")

let wordCompleter = WordCompleter()
let policy = await MainActor.run { SuggestionPolicyEngine(maxWords: 8) }

// Pour chaque terme appris, simuler « <lead neutre> <Préfixe3> » et router.
// Lead neutre (peu susceptible de matcher une phrase prose) → on isole le
// lexique de L1 (recall de phrase). On reconstruit le mot = préfixe + ghost.
struct Row { let term: String; let freq: Int; let prefix3: String; let source: String; let ghost: String; let rebuilt: String; let ok: Bool }
var rows: [Row] = []
let leads = ["Voici ", "Je recommande ", "On utilise ", "C'est avec ", "Mon préféré reste "]

for (i, t) in lexicon.terms.prefix(topN).enumerated() where t.term.count >= 4 {
    let pre = String(t.term.prefix(3))               // préfixe capitalisé tapé
    let lead = leads[i % leads.count]
    let userTail = lead + pre                          // ex. « Voici Bin »
    let result = await MainActor.run {
        policy.routeInstant(userTail: userTail, historySnapshot: history,
                            wordCompleter: wordCompleter, lexicon: lexicon)
    }
    let srcStr: String
    switch result?.source {
    case .some(.learnedWord): srcStr = "learnedWord"
    case .some(.history):     srcStr = "history(L1)"
    case .some(.wordComplete):srcStr = "wordComplete"
    case .some(let s):        srcStr = "\(s)"
    case .none:               srcStr = "∅"
    }
    let ghost = result?.text ?? ""
    let rebuilt = pre + ghost
    // Succès = routeInstant a renvoyé le terme appris (peu importe via lexicon
    // ou L1 : les deux sont des rappels appris ; on distingue la source).
    let ok = rebuilt.lowercased().hasPrefix(t.term.lowercased())
    rows.append(Row(term: t.term, freq: t.freq, prefix3: pre, source: srcStr, ghost: ghost, rebuilt: rebuilt, ok: ok))
}

// ── Diagnostic terme (SOUFFLEUSE_TERM=Mariama) : pourquoi (pas) appris ? ──────
if let term = env["SOUFFLEUSE_TERM"], !term.isEmpty {
    let lt = term.lowercased()
    var total = 0, capMid = 0
    for e in history {
        let text = e.contextBefore.isEmpty ? e.accepted : e.contextBefore + " " + e.accepted
        for (w, mid) in LearnedLexicon.tokensWithCase(text) where w.lowercased() == lt {
            total += 1; if mid { capMid += 1 }
        }
    }
    let inLexicon = lexicon.terms.first { $0.term.lowercased() == lt }
    let pre = String(term.prefix(3))
    let comp = lexicon.completion(for: pre)
    let group = lexicon.terms.filter { $0.term.lowercased().hasPrefix(pre.lowercased()) }
        .sorted { $0.freq > $1.freq }
    print("\n─ Diagnostic « \(term) » ─")
    print("  occurrences dans l'historique : \(total)  (dont capitalisé milieu de phrase : \(capMid))")
    print("  ratio capMid                  : \(total > 0 ? String(format: "%.0f%%", Double(capMid)/Double(total)*100) : "—")  (besoin ≥50%)")
    print("  fréquence ≥2 ?                : \(total >= 2 ? "oui" : "NON (\(total))")")
    print("  → dans le lexique distinctif  : \(inLexicon != nil ? "oui (freq \(inLexicon!.freq))" : "NON")")
    print("  complétion de « \(pre) »        : \(comp ?? "∅")")
    print("  termes du lexique en « \(pre) » : \(group.prefix(6).map { "\($0.term)(\($0.freq))" }.joined(separator: ", "))")
}

let tested = rows.count
let viaLexicon = rows.filter { $0.source == "learnedWord" && $0.ok }.count
let viaL1 = rows.filter { $0.source == "history(L1)" && $0.ok }.count
let surfaced = rows.filter { $0.ok }.count

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count) }

print("\n════════════ Lexicon Route Eval — bout-en-bout (routeInstant réel) ════════════")
print("history: \(history.count)  |  termes distinctifs appris: \(lexicon.count)  |  testés (≥4 lettres, top\(topN)): \(tested)")
if showExamples {
    print("\n  terme            freq  tape   → ghost (source)            reconstruit   ✓")
    for r in rows.prefix(30) {
        print("  \(pad(r.term,15)) \(pad(String(r.freq),4)) \(pad(r.prefix3,5))  → \(pad(r.ghost.isEmpty ? "∅" : r.ghost, 12)) \(pad("("+r.source+")",16)) \(pad(r.rebuilt,13)) \(r.ok ? "✓" : "·")")
    }
}
print("\n──────── Bilan ────────")
print("  termes ressortis correctement     : \(surfaced)/\(tested)")
print("    └ via LEXIQUE appris (.learnedWord) : \(viaLexicon)")
print("    └ via recall phrase L1 (.history)   : \(viaL1)")
print("  → preuve : « Préfixe » → terme appris ressort par routeInstant, sans LLM")
print("═══════════════════════════════════════════════════════════════════════════════\n")
