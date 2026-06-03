import Foundation
import SouffleuseCore
import SouffleuseLlama
import SouffleuseLog

// Souffleuse Context-Copy Eval (healing, biais OFF)
//
// Question : un terme rare que le base model ne connaît pas (« Binance ») peut-il
// ressortir en mid-word UNIQUEMENT parce qu'il est PRÉSENT dans le contexte
// (copie par attention), avec token-healing et SANS aucun biais de corpus ?
//
// Reproduit la capture : "...exchange Bin" → "ance". 3 conditions par terme :
//   A. sans mention + biais OFF   (modèle seul → devrait échouer sur le rare)
//   B. AVEC mention + biais OFF   (hypothèse COPIE : devrait réussir)
//   C. AVEC mention + biais ON    (pour comparaison)
//
// Synthétique : aucun historique lu, aucun Keychain. Healing = trailing partial.

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

struct Case: Sendable {
    let term: String          // mot cible (casse réelle)
    let mention: String       // phrase de contexte CONTENANT le terme
    let tail: String          // amorce finissant par le préfixe (capitalisé), sans le terme
}
// tail finit par les 3 premières lettres du terme (préfixe tapé « Bin »).
func pfx(_ t: String) -> String { String(t.prefix(3)) }

let cases: [Case] = [
    .init(term: "Binance",   mention: "J'utilise l'exchange Binance tous les jours.", tail: "Honnêtement mon préféré reste \(pfx("Binance"))"),
    .init(term: "Fiscalio",    mention: "Pour ma déclaration crypto je passe par Fiscalio.", tail: "L'outil que je recommande c'est \(pfx("Fiscalio"))"),
    .init(term: "Kraken",    mention: "Mon compte Kraken est vérifié depuis hier.", tail: "Je vais retirer mes fonds de \(pfx("Kraken"))"),
    .init(term: "Metamask",  mention: "J'ai connecté mon wallet Metamask au site.", tail: "Ouvre ton extension \(pfx("Metamask"))"),
    .init(term: "Solana",    mention: "La collection est mintée sur Solana.", tail: "Les frais sont bas sur \(pfx("Solana"))"),
    .init(term: "Cocotypist", mention: "Je développe une app qui s'appelle Cocotypist.", tail: "Le projet se nomme \(pfx("Cocotypist"))"),
    .init(term: "Géraldine", mention: "Ma collègue Géraldine gère ce dossier.", tail: "J'en parle demain avec \(pfx("Géraldine"))"),
    .init(term: "Aurélien",  mention: "Mon associé Aurélien s'occupe de la technique.", tail: "Le rendez-vous est avec \(pfx("Aurélien"))"),
    // Contrôle : terme que le modèle connaît (devrait marcher même sans mention).
    .init(term: "Paris",     mention: "Nous avons rendez-vous à Paris la semaine prochaine.", tail: "Le bureau principal est à \(pfx("Paris"))"),
]

let ggufPath: String = {
    if let p = ProcessInfo.processInfo.environment["SOUFFLEUSE_GGUF"], !p.isEmpty {
        return (p as NSString).expandingTildeInPath
    }
    return (("~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf") as NSString)
        .expandingTildeInPath
}()
let engine = LlamaEngine()
err("[ctxcopy] loading GGUF…")
guard await engine.load(modelPath: ggufPath, contextTokens: 4096) else {
    err("[ctxcopy] FATAL: could not load GGUF"); exit(1)
}

// Génère le ghost mid-word. `withMention` préfixe le contexte contenant le terme.
// `bias` active la promotion+corpus (sinon biais totalement OFF, corpus vide).
func run(_ c: Case, withMention: Bool, bias: Bool) async -> String {
    let before = withMention ? (c.mention + " " + c.tail) : c.tail
    let heal = OutputFilter.trailingPartialWord(before)
    if bias {
        // Corpus = la mention seule (source du biais). Sinon corpus vide.
        await engine.setCorpus([c.mention])
    } else {
        await engine.setCorpus([])
    }
    let prompt = LlamaPromptBuilder.buildLlamaPrompt(
        system: "", customInstr: "", ctxPrefix: "", fieldContext: "",
        afterCursor: "", beforeCursor: before
    )
    final class Acc: @unchecked Sendable { var t = "" }
    let acc = Acc()
    _ = await engine.generate(
        prompt: prompt, maxTokens: 6,
        sampling: LlamaSampling(
            temperature: 0, repeatPenalty: 1.3, repeatLastN: 64,
            personalizationStrength: bias ? LlamaSampling.personalizationGainScale : 0,
            banMarkup: true, banDigitsLeading: true, banEmoji: true,
            promoteStrongMatches: bias,
            minFirstTokenProb: 0.0001,
            healPrefix: heal.isEmpty ? nil : heal
        )
    ) { tok in acc.t += tok; return true }
    let line = acc.t.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? acc.t
    return (pfx(c.term) + line)   // préfixe tapé + ghost = mot reconstruit
}

func hit(_ full: String, _ term: String) -> Bool {
    full.lowercased().hasPrefix(term.lowercased()) || full.lowercased().contains(term.lowercased())
}

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count) }

print("\n════════════ Context-Copy Eval (healing) ════════════")
print("Le terme est-il reconstruit en mid-word selon le contexte/biais ?")
print("préfixe tapé = 3 lettres ; ✓ = le mot cible ressort\n")
print("  \(pad("terme", 12))  A:sansMention/sansBiais   B:AVEC-contexte/sansBiais   C:contexte+biais")
var aHit = 0, bHit = 0, cHit = 0
for c in cases {
    let a = await run(c, withMention: false, bias: false)
    let b = await run(c, withMention: true,  bias: false)
    let cc = await run(c, withMention: true, bias: true)
    let (ah, bh, ch) = (hit(a, c.term), hit(b, c.term), hit(cc, c.term))
    if ah { aHit += 1 }; if bh { bHit += 1 }; if ch { cHit += 1 }
    print("  \(pad(c.term, 12))  \(ah ? "✓" : "·") \(pad(a.trimmingCharacters(in: .whitespaces), 20))  \(bh ? "✓" : "·") \(pad(b.trimmingCharacters(in: .whitespaces), 20))  \(ch ? "✓" : "·") \(cc.trimmingCharacters(in: .whitespaces))")
}
let n = cases.count
print("\n──────── Bilan (/\(n)) ────────")
print("  A · modèle seul (sans contexte, sans biais) : \(aHit)/\(n)")
print("  B · COPIE depuis le contexte (sans biais)    : \(bHit)/\(n)   ← l'hypothèse")
print("  C · contexte + biais                          : \(cHit)/\(n)")
print("═══════════════════════════════════════════════════════\n")
