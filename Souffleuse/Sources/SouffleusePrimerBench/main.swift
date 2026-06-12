import Foundation
import SouffleuseCore
import SouffleuseLlama
import SouffleuseLog

// Souffleuse Primer Bench — étage 1 du plan « style primer » (2026-06-12).
//
// Question objective, headless, UNE seule variable (le `ctxPrefix` du prompt
// BEAM — la forme exacte de prod via `BeamGhostShaper.buildPrompt`, qui exclut
// system/fieldContext/afterCursor/examples) :
//   préfixer le prompt beam avec la PROSE PASSÉE de l'utilisateur (« style
//   primer », completion prompting — la littérature le donne supérieur au
//   few-shot étiqueté pour l'imitation de style sur un modèle base) améliore-t-il
//   l'atteignabilité d'une continuation du BON REGISTRE, sans contaminer le
//   sujet ni recopier le primer ?
//
// Trois conditions, MÊME continuation gold :
//   A  baseline   — ctxPrefix = "" (le prompt beam d'aujourd'hui, sans contexte)
//   B  accordé    — ctxPrefix = 2 proses user du MÊME registre que le champ
//   C  désaccordé — ctxPrefix = 2 proses user du registre OPPOSÉ
//
// B−A mesure le gain du primer ; B−C mesure la valeur de l'ACCORD de registre —
// c'est le chiffre qui justifie (ou non) un ton par défaut PAR APP
// (`ToneStore.tone(forBundle:)` comme prior de sélection du primer).
//
// Métriques :
//   1. Σ logP(gold | prompt) via `LlamaEngine.sequenceLogProb` (reachability).
//   2. Génération greedy courte (sampling prod) : contamination de SUJET (une
//      entité du primer surgit dans la sortie), ÉCHO verbatim (≥18 chars du
//      primer recopiés), BASCULE de registre (tutoiement ⇄ vouvoiement).
//   3. Coût tokens du primer (proxy TTFT : tokens ajoutés au prompt).
//
// Pur scoring + génération courte : aucun historique lu, aucun Keychain, corpus
// n-gram OFF (`setCorpus([])`) pour isoler la variable prompt.
// Usage : SOUFFLEUSE_GGUF=~/…/gemma-3-1b.i1-Q5_K_M.gguf swift run SouffleusePrimerBench

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// ── Primers : la prose passée simulée de l'utilisateur, par registre ─────────
// Entités distinctives volontaires (padel, Biarritz / facture 2214, audit) :
// elles n'ont RIEN à faire dans les continuations des cas — toute apparition
// en sortie = contamination de sujet mesurable.

let casualPrimer = [
    "ahah grave, on s'est éclatés au padel hier soir, faut qu'on remette ça vite",
    "t'inquiète je gère, je t'envoie les photos de Biarritz ce soir et tu me dis ce que t'en penses",
]
let formalPrimer = [
    "Bonjour Madame Morel, je vous remercie pour votre retour concernant l'audit du troisième trimestre. Je reste à votre disposition pour toute précision.",
    "Cher Monsieur, je vous confirme la bonne réception de la facture n° 2214. Nous procéderons au règlement sous huitaine.",
]
// Mots-marqueurs du primer pour la détection de contamination (pas les mots de
// registre, qui sont au contraire SOUHAITÉS en sortie).
let casualSubjects = ["padel", "biarritz", "photos"]
let formalSubjects = ["audit", "facture", "2214", "huitaine", "morel"]

// Condition D : primer accordé mais PAUVRE EN ENTITÉS (style-rich, subject-poor).
// Si le gain de D tient face à B, la règle de sélection prod devient « bon
// registre + prose filtrée sans entités distinctives » — la contamination de
// sujet disparaît par construction. Aucun recouvrement avec les golds des cas.
let casualNeutralPrimer = [
    "ahah ouais carrément, on gère ça tranquille cette semaine",
    "t'inquiète c'est tout bon, je te renvoie ça ce soir sans faute",
]
let formalNeutralPrimer = [
    "Je vous remercie de votre retour et reste à votre disposition pour toute précision complémentaire.",
    "Je vous confirme la bonne prise en compte de votre demande et reviens vers vous dans les meilleurs délais.",
]

func primerBlock(_ entries: [String]) -> String {
    entries.joined(separator: "\n\n")
}

// ── Cas : frappes FR avec gold marqué en registre ────────────────────────────

enum Register: String { case casual = "tutoiement", formal = "vouvoiement" }

struct Case {
    let label: String
    let register: Register
    let userTail: String   // beforeCursor : finit sur un mot, sans espace final
    let gold: String       // continuation idéale, commence par un espace
}

let cases: [Case] = [
    // Tutoiement (chat / Slack)
    Case(label: "rdv décontracté", register: .casual,
         userTail: "salut ! pour demain on",
         gold: " se fait ça tranquille, t'inquiète pas."),
    Case(label: "merci pote", register: .casual,
         userTail: "merci encore pour hier, c'était",
         gold: " trop cool, on remet ça quand tu veux."),
    Case(label: "envoi doc casual", register: .casual,
         userTail: "je t'envoie le fichier ce soir et tu",
         gold: " me dis ce que t'en penses."),
    Case(label: "propo casual", register: .casual,
         userTail: "si t'es chaud on",
         gold: " se capte en début de semaine."),
    // Vouvoiement (courriel)
    Case(label: "accusé réception", register: .formal,
         userTail: "Bonjour Madame, nous avons bien reçu votre dossier et nous",
         gold: " vous remercions de votre confiance."),
    Case(label: "relance formelle", register: .formal,
         userTail: "Sans retour de votre part, je me permets de",
         gold: " vous relancer concernant notre proposition."),
    Case(label: "disponibilité", register: .formal,
         userTail: "N'hésitez pas à revenir vers moi si",
         gold: " vous avez la moindre question."),
    Case(label: "excuse formelle", register: .formal,
         userTail: "Je vous prie de bien vouloir",
         gold: " m'excuser pour ce contretemps."),
]

// ── Boot engine (pattern AmorceEval/InjectionEval) ───────────────────────────
let ggufPath = (ProcessInfo.processInfo.environment["SOUFFLEUSE_GGUF"].flatMap { $0.isEmpty ? nil : $0 }
    ?? "~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf")
let resolved = (ggufPath as NSString).expandingTildeInPath
let engine = LlamaEngine()
err("[primer] loading GGUF: \(resolved)")
guard await engine.load(modelPath: resolved, contextTokens: 4096) else { err("FATAL: GGUF load failed"); exit(1) }
await engine.setCorpus([])   // biais perso OFF : on isole la variable PROMPT

// ── Génération greedy courte (sampling prod) ─────────────────────────────────
func gen(_ prompt: String) async -> String {
    final class Acc: @unchecked Sendable { var s = "" }
    let acc = Acc()
    _ = await engine.generate(
        prompt: prompt, maxTokens: 24,
        sampling: LlamaSampling(
            temperature: 0, repeatPenalty: 1.3, repeatLastN: 64,
            personalizationStrength: 0, banMarkup: true, banDigitsLeading: true, banEmoji: true
        )
    ) { piece in acc.s += piece; return true }
    return acc.s.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? acc.s
}

// ── Détections ───────────────────────────────────────────────────────────────

/// Contamination de sujet : une entité distinctive du primer surgit en sortie.
func contaminates(_ out: String, subjects: [String]) -> Bool {
    let o = out.lowercased()
    return subjects.contains { o.contains($0) }
}

/// Écho verbatim : la sortie recopie ≥18 caractères consécutifs du primer.
/// Les spans aussi présents dans le GOLD du cas sont exclus — sinon un gold qui
/// partage une tournure avec le primer compte une « bonne » continuation comme
/// écho (leçon de la v1 : « envoi doc casual »).
func echoes(_ out: String, primer: [String], gold: String) -> Bool {
    let o = out.lowercased()
    let g = gold.lowercased()
    for p in primer {
        let body = Array(p.lowercased()); var i = 0
        while i + 18 <= body.count {
            let span = String(body[i..<i+18])
            if o.contains(span) && !g.contains(span) { return true }
            i += 6
        }
    }
    return false
}

/// Registre détecté dans un texte (nil si aucun marqueur). Espaces normalisés
/// pour attraper début/fin de chaîne.
func detectedRegister(_ text: String) -> Register? {
    let t = " " + text.lowercased() + " "
    let tu = [" tu ", " t'", " ton ", " ta ", " tes ", " toi "]
    let vous = [" vous ", " votre ", " vos ", " vous."]
    let tuHits = tu.reduce(0) { $0 + (t.contains($1) ? 1 : 0) }
    let vousHits = vous.reduce(0) { $0 + (t.contains($1) ? 1 : 0) }
    if tuHits == 0 && vousHits == 0 { return nil }
    return tuHits >= vousHits ? .casual : .formal
}

func f(_ d: Double?) -> String { d.map { String(format: "%+.2f", $0) } ?? "  nil" }
func pad(_ s: String, _ n: Int) -> String { s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count) }

// ── Run ──────────────────────────────────────────────────────────────────────

struct Row {
    let label: String
    let register: Register
    let a: Double?; let b: Double?; let c: Double?; let d: Double?
    let outA: String; let outB: String; let outC: String; let outD: String
    let contamB: Bool; let echoB: Bool
    let contamD: Bool; let echoD: Bool
    let flipB: Bool   // la sortie B a basculé de registre vs le registre attendu
    let flipC: Bool
    let flipD: Bool
    var dBA: Double? { (a != nil && b != nil) ? b! - a! : nil }
    var dBC: Double? { (b != nil && c != nil) ? b! - c! : nil }
    var dDA: Double? { (a != nil && d != nil) ? d! - a! : nil }
}

var rows: [Row] = []
for cse in cases {
    let matched = cse.register == .casual ? casualPrimer : formalPrimer
    let opposite = cse.register == .casual ? formalPrimer : casualPrimer
    let neutral = cse.register == .casual ? casualNeutralPrimer : formalNeutralPrimer
    let matchedSubjects = cse.register == .casual ? casualSubjects : formalSubjects

    // Forme de prompt BEAM exacte (mêmes slots que generateGhostBeam).
    let pA = BeamGhostShaper.buildPrompt(customInstr: "", ctxPrefix: "", llmTail: cse.userTail)
    let pB = BeamGhostShaper.buildPrompt(customInstr: "", ctxPrefix: primerBlock(matched), llmTail: cse.userTail)
    let pC = BeamGhostShaper.buildPrompt(customInstr: "", ctxPrefix: primerBlock(opposite), llmTail: cse.userTail)
    let pD = BeamGhostShaper.buildPrompt(customInstr: "", ctxPrefix: primerBlock(neutral), llmTail: cse.userTail)

    let sA = await engine.sequenceLogProb(context: pA, continuation: cse.gold)
    let sB = await engine.sequenceLogProb(context: pB, continuation: cse.gold)
    let sC = await engine.sequenceLogProb(context: pC, continuation: cse.gold)
    let sD = await engine.sequenceLogProb(context: pD, continuation: cse.gold)

    let oA = await gen(pA)
    let oB = await gen(pB)
    let oC = await gen(pC)
    let oD = await gen(pD)

    let regB = detectedRegister(oB)
    let regC = detectedRegister(oC)
    let regD = detectedRegister(oD)

    rows.append(Row(
        label: cse.label, register: cse.register,
        a: sA?.sumLogProb, b: sB?.sumLogProb, c: sC?.sumLogProb, d: sD?.sumLogProb,
        outA: oA, outB: oB, outC: oC, outD: oD,
        contamB: contaminates(oB, subjects: matchedSubjects),
        echoB: echoes(oB, primer: matched, gold: cse.gold),
        contamD: contaminates(oD, subjects: matchedSubjects),
        echoD: echoes(oD, primer: neutral, gold: cse.gold),
        flipB: regB != nil && regB != cse.register,
        flipC: regC != nil && regC != cse.register,
        flipD: regD != nil && regD != cse.register
    ))
}

// Coût tokens du primer (proxy TTFT) : tokens ajoutés au prompt par condition B.
let casualTok = await engine.tokenizeForCorpus(primerBlock(casualPrimer) + "\n\n").count
let formalTok = await engine.tokenizeForCorpus(primerBlock(formalPrimer) + "\n\n").count

print("\n══════ Primer Bench — rien (A) vs accordé (B) vs opposé (C) vs accordé-NEUTRE (D) ══════")
print("Métrique = Σ logP(continuation gold | prompt) — plus haut = registre voulu ATTEIGNABLE")
print("ΔB−A > 0 = le primer aide ; ΔB−C > 0 = l'ACCORD de registre compte (→ ton par app)")
print("ΔD−A ≈ ΔB−A = le style paie SANS les entités → sélection subject-poor en prod\n")
print("  \(pad("cas", 18))  \(pad("reg", 4))  \(pad("A:rien", 8)) \(pad("B:accordé", 9)) \(pad("C:opposé", 8)) \(pad("D:neutre", 8))  \(pad("ΔB−A", 7)) \(pad("ΔB−C", 7)) \(pad("ΔD−A", 7))")
for r in rows {
    let reg = r.register == .casual ? "tu" : "vous"
    print("  \(pad(r.label, 18))  \(pad(reg, 4))  \(pad(f(r.a), 8)) \(pad(f(r.b), 9)) \(pad(f(r.c), 8)) \(pad(f(r.d), 8))  \(pad(f(r.dBA), 7)) \(pad(f(r.dBC), 7)) \(pad(f(r.dDA), 7))")
}

print("\n── Génération greedy (B = accordé brut ; D = accordé neutre ; flags ⚠) ──")
for r in rows {
    func flags(_ contam: Bool, _ echo: Bool, _ flip: Bool) -> String {
        var fs: [String] = []
        if contam { fs.append("contam") }
        if echo { fs.append("écho") }
        if flip { fs.append("registre") }
        return fs.isEmpty ? "      " : "⚠" + fs.joined(separator: "+")
    }
    print("  \(pad(r.label, 16)) A      : \(r.outA.trimmingCharacters(in: .whitespaces).prefix(58))")
    print("  \(pad("", 16)) B\(pad(flags(r.contamB, r.echoB, r.flipB), 6)): \(r.outB.trimmingCharacters(in: .whitespaces).prefix(58))")
    print("  \(pad("", 16)) C\(r.flipC ? "⚠reg  " : "      "): \(r.outC.trimmingCharacters(in: .whitespaces).prefix(58))")
    print("  \(pad("", 16)) D\(pad(flags(r.contamD, r.echoD, r.flipD), 6)): \(r.outD.trimmingCharacters(in: .whitespaces).prefix(58))")
}

let dBAs = rows.compactMap { $0.dBA }
let dBCs = rows.compactMap { $0.dBC }
let dDAs = rows.compactMap { $0.dDA }
let meanBA = dBAs.isEmpty ? 0 : dBAs.reduce(0, +) / Double(dBAs.count)
let meanBC = dBCs.isEmpty ? 0 : dBCs.reduce(0, +) / Double(dBCs.count)
let meanDA = dDAs.isEmpty ? 0 : dDAs.reduce(0, +) / Double(dDAs.count)
let bBeatsA = rows.filter { ($0.dBA ?? -1) > 0 }.count
let bBeatsC = rows.filter { ($0.dBC ?? -1) > 0 }.count
let dBeatsA = rows.filter { ($0.dDA ?? -1) > 0 }.count
let contamB = rows.filter { $0.contamB }.count
let echoB = rows.filter { $0.echoB }.count
let flipsB = rows.filter { $0.flipB }.count
let contamD = rows.filter { $0.contamD }.count
let echoD = rows.filter { $0.echoD }.count
let flipsD = rows.filter { $0.flipD }.count

print("\n──────── Bilan (\(rows.count) cas) ────────")
print(String(format: "  ΔB−A moyen (accordé brut vs rien)      : %+.2f   (B bat A : \(bBeatsA)/\(dBAs.count))", meanBA))
print(String(format: "  ΔB−C moyen (accordé vs désaccordé)     : %+.2f   (B bat C : \(bBeatsC)/\(dBCs.count))", meanBC))
print(String(format: "  ΔD−A moyen (accordé NEUTRE vs rien)    : %+.2f   (D bat A : \(dBeatsA)/\(dDAs.count))", meanDA))
print("  B : contam \(contamB)/\(rows.count) · écho \(echoB)/\(rows.count) · bascule reg \(flipsB)/\(rows.count)")
print("  D : contam \(contamD)/\(rows.count) · écho \(echoD)/\(rows.count) · bascule reg \(flipsD)/\(rows.count)")
print("  coût primer : casual \(casualTok) tok · formel \(formalTok) tok (préfixe stable par champ → payé 1× par session de champ, KV ensuite)")
print("""

LECTURE :
  ΔD−A > 0 ET contam/écho D = 0 → GO étage 2 : câbler le primer (flag default-OFF)
             dans le ctxPrefix beam, FIGÉ PAR CHAMP (KV), avec sélection
             « bon registre (ToneStore.tone(forBundle:)) + prose pauvre en
             entités distinctives ».
  ΔB−C ≫ 0 → l'accord de registre paie : le ton par défaut PAR APP pilote la
             sélection du primer.
  ΔD−A ≪ ΔB−A → le gain venait des entités, pas du style : revoir la forme
             (few-shot délimité, slot `examples`) avant tout câblage.
═══════════════════════════════════════════════════════════════════════════════
""")
