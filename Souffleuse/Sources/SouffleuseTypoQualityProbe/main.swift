import Foundation
import SouffleuseLlama

// ════════════════════════════════════════════════════════════════════════════
// TYPO QUALITY PROBE — does the local LLM discriminate ambiguous corrections,
// and at what MARGIN can we trust it?
//
// Noisy-channel question: a spell-checker returns dictionary candidates for a
// typo; can the model's CONTEXT log-prob pick the right one? We score
// P(candidate | context) via `LlamaEngine.sequenceLogProb` and look at the
// MARGIN between the top-2 candidates (avg log-prob per token). The margin is
// what a conservative corrector would threshold on: correct only when the winner
// clears the runner-up by enough.
//
// Sections:
//   A. Typo disambiguation — the real feature (misspelled word, context decides).
//   B. Easy typos — one clear correction; margins should be wide.
//   C. Should-BAIL — genuinely ambiguous; we WANT a small margin (abstain).
//   D. Homophones — real, correctly-spelled words; OUT of the current typo path
//      (NSSpellChecker won't flag them) but they probe the LM and inform a
//      possible future real-word corrector.
// ════════════════════════════════════════════════════════════════════════════

// `SOUFFLEUSE_MODEL` prime ; sinon le GGUF de Cotypist (machine de dev — même
// poids gemma-3-1b que notre défaut, déjà téléchargé par l'app concurrente).
let modelPath = ProcessInfo.processInfo.environment["SOUFFLEUSE_MODEL"]
    ?? NSString(string: "~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf").expandingTildeInPath

let engine = LlamaEngine()
guard await engine.load(modelPath: modelPath, contextTokens: 2048) else {
    FileHandle.standardError.write("LOAD FAILED: \(modelPath)\n".data(using: .utf8)!)
    exit(1)
}
FileHandle.standardError.write("LOADED\n".data(using: .utf8)!)

enum Expect { case pick(String); case bail }

struct Case {
    let section: String
    let context: String
    let typo: String
    let expect: Expect
    let candidates: [String]
}

let cases: [Case] = [
    // ── A. Typo disambiguation (the real feature) ────────────────────────────
    Case(section: "A", context: "Bonjour, je ", typo: "sius", expect: .pick("suis"), candidates: ["suis", "sous"]),
    Case(section: "A", context: "Le chat dort ", typo: "sius", expect: .pick("sous"), candidates: ["suis", "sous"]),
    Case(section: "A", context: "Il faut que je te ", typo: "dut", expect: .pick("dis"), candidates: ["dis", "dit", "dut"]),
    Case(section: "A", context: "Nous ", typo: "somme", expect: .pick("sommes"), candidates: ["sommes", "somme", "pomme"]),
    Case(section: "A", context: "I am ", typo: "form", expect: .pick("from"), candidates: ["from", "form", "for"]),
    Case(section: "A", context: "Please fill out the ", typo: "form", expect: .pick("form"), candidates: ["from", "form", "for"]),
    Case(section: "A", context: "They parked ", typo: "ther", expect: .pick("their"), candidates: ["there", "their", "the"]),
    Case(section: "A", context: "I really ", typo: "wnat", expect: .pick("want"), candidates: ["want", "what", "wont"]),
    Case(section: "A", context: "I have already ", typo: "ben", expect: .pick("been"), candidates: ["been", "ban", "bend"]),
    Case(section: "A", context: "Elle a ouvert la ", typo: "porte", expect: .pick("porte"), candidates: ["porte", "perte", "parte"]),
    Case(section: "A", context: "On se voit ", typo: "demian", expect: .pick("demain"), candidates: ["demain", "demian"]),

    // ── B. Easy typos (one clear correction; expect wide margin) ─────────────
    Case(section: "B", context: "Merci pour ton ", typo: "mesage", expect: .pick("message"), candidates: ["message", "passage"]),
    Case(section: "B", context: "Je vais au ", typo: "travial", expect: .pick("travail"), candidates: ["travail", "trivial"]),
    Case(section: "B", context: "C'est une belle ", typo: "jrounée", expect: .pick("journée"), candidates: ["journée", "tournée"]),
    Case(section: "B", context: "This is a great ", typo: "oppportunity", expect: .pick("opportunity"), candidates: ["opportunity"]),

    // ── C. Should-BAIL (genuinely ambiguous; want small margin → abstain) ────
    Case(section: "C", context: "Il a ", typo: "manger", expect: .bail, candidates: ["mangé", "manger"]),
    Case(section: "C", context: "Je ", typo: "vais", expect: .bail, candidates: ["vais", "vois"]),
    Case(section: "C", context: "She will ", typo: "tehre", expect: .bail, candidates: ["there", "three"]),

    // ── D. Homophones (real words, OUT of current typo path) ─────────────────
    Case(section: "D", context: "Il a perdu ", typo: "ces", expect: .pick("ses"), candidates: ["ces", "ses"]),
    Case(section: "D", context: "Regarde ", typo: "ces", expect: .pick("ces"), candidates: ["ces", "ses"]),
    Case(section: "D", context: "Il ", typo: "et", expect: .pick("est"), candidates: ["et", "est"]),
    Case(section: "D", context: "Pierre ", typo: "et", expect: .pick("et"), candidates: ["et", "est"]),
    Case(section: "D", context: "Ils ", typo: "son", expect: .pick("sont"), candidates: ["son", "sont"]),
    Case(section: "D", context: "Où est ", typo: "son", expect: .pick("son"), candidates: ["son", "sont"]),
    Case(section: "D", context: "Je ne sais pas ", typo: "ou", expect: .pick("où"), candidates: ["ou", "où"]),
    Case(section: "D", context: "Tu veux du thé ", typo: "ou", expect: .pick("ou"), candidates: ["ou", "où"]),
    Case(section: "D", context: "Je vais à Paris ", typo: "a", expect: .pick("à"), candidates: ["a", "à"]),
    Case(section: "D", context: "Il ", typo: "a", expect: .pick("a"), candidates: ["a", "à"]),
]

func avg(_ s: (sumLogProb: Double, tokenCount: Int)) -> Double {
    s.tokenCount > 0 ? s.sumLogProb / Double(s.tokenCount) : -.greatestFiniteMagnitude
}

struct Result { let c: Case; let ranked: [(cand: String, score: Double, toks: Int)]; let margin: Double; let winner: String }

var results: [Result] = []
for c in cases {
    var scored: [(cand: String, score: Double, toks: Int)] = []
    for cand in c.candidates {
        if let s = await engine.sequenceLogProb(context: c.context, continuation: cand) {
            scored.append((cand, avg(s), s.tokenCount))
        } else {
            scored.append((cand, -.greatestFiniteMagnitude, 0))
        }
    }
    let ranked = scored.sorted { $0.score > $1.score }
    let margin = ranked.count >= 2 ? ranked[0].score - ranked[1].score : .greatestFiniteMagnitude
    results.append(Result(c: c, ranked: ranked, margin: margin, winner: ranked[0].cand))
}

func sectionTitle(_ s: String) -> String {
    switch s {
    case "A": return "A. Typo disambiguation (vraie feature)"
    case "B": return "B. Typos faciles (marge large attendue)"
    case "C": return "C. À ABSTENIR (ambigu — petite marge voulue)"
    default:  return "D. Homophones (hors chemin typo actuel)"
    }
}

var lastSection = ""
for r in results {
    if r.c.section != lastSection {
        print("\n" + String(repeating: "─", count: 78))
        print(sectionTitle(r.c.section))
        print(String(repeating: "─", count: 78))
        lastSection = r.c.section
    }
    let expStr: String
    switch r.c.expect {
    case .pick(let w): expStr = "→ \(w)"
    case .bail:        expStr = "→ (abstenir)"
    }
    print("\n“\(r.c.context)[\(r.c.typo)]”  \(expStr)")
    for x in r.ranked {
        let exp: Bool = { if case .pick(let w) = r.c.expect { return x.cand == w }; return false }()
        print(String(format: "   %@ %-10@ avg/tok=%8.3f", exp ? "✓" : " ", x.cand as NSString, x.score))
    }
    let okStr: String
    switch r.c.expect {
    case .pick(let w): okStr = r.winner == w ? "✅ \(r.winner)" : "❌ \(r.winner)"
    case .bail:        okStr = "marge=\(String(format: "%.2f", r.margin)) (faible = bien)"
    }
    print(String(format: "   gagnant: %@   marge#1-#2=%.2f", okStr, r.margin))
}

// ── Calibration summary ──────────────────────────────────────────────────────
let pickCases = results.filter { if case .pick = $0.c.expect { return true }; return false }
let bailCases = results.filter { if case .bail = $0.c.expect { return true }; return false }
let correct = pickCases.filter { r in if case .pick(let w) = r.c.expect { return r.winner == w }; return false }
// Les cas à candidat UNIQUE ont une marge sentinelle infinie (pas de #2) :
// les exclure des stats de calibration, sinon max/médiane sont faussés.
let correctMargins = correct.map { $0.margin }.filter { $0.isFinite }.sorted()
let bailMargins = bailCases.map { $0.margin }.sorted()

print("\n" + String(repeating: "═", count: 78))
print("CALIBRATION")
print(String(repeating: "═", count: 78))
print(String(format: "Pick: %d/%d gagnant correct", correct.count, pickCases.count))
if let lo = correctMargins.first, let hi = correctMargins.last {
    print(String(format: "Marges des corrections CORRECTES : min=%.2f  médiane=%.2f  max=%.2f",
                 lo, correctMargins[correctMargins.count/2], hi))
}
if !bailMargins.isEmpty {
    print(String(format: "Marges des cas à ABSTENIR        : min=%.2f  max=%.2f",
                 bailMargins.first!, bailMargins.last!))
}
// Suggest a threshold: the largest gap that keeps all correct picks while
// rejecting as many bail cases as possible.
if let minCorrect = correctMargins.first {
    let bailedBelow = bailMargins.filter { $0 < minCorrect }.count
    print(String(format: "\nSeuil candidat = %.2f (min des corrections) → abstient %d/%d cas ambigus, garde %d/%d corrections",
                 minCorrect, bailedBelow, bailMargins.count, correct.count, correct.count))
    print("Si des cas corrects ont une marge ~aussi faible que des cas ambigus,")
    print("la marge seule ne suffit pas → combiner avec la distance d'édition (noisy channel complet).")
}
print(String(repeating: "═", count: 78))
await engine.unload()
