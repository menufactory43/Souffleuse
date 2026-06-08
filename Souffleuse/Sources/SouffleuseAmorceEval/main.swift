import Foundation
import SouffleuseCore
import SouffleuseLlama
import SouffleuseLog

// Souffleuse Amorce Eval — Ticket #1 : amorcer le LLM par la CONVERSATION.
//
// Question objective, headless, UNE seule variable (le `ctxPrefix` passé à
// LlamaPromptBuilder.buildLlamaPrompt ; `beforeCursor` reste constant) :
//   le message du correspondant injecté en TRANSCRIPT NATUREL rend-il la bonne
//   continuation plus probable que le PRÉAMBULE MÉTADONNÉES app/fenêtre actuel
//   (lequel, en plus, fuit) ?
//
// Trois constructions de prompt, MÊME continuation gold :
//   A  métadonnées  — ctxPrefix = le préambule actuel d'EnrichedContext.prefix
//                     ('App Intercom, window "…".') — la baseline NUISIBLE (#2)
//   B  rien         — ctxPrefix = "" (témoin)
//   C  transcript   — ctxPrefix = 'Client : <message>' (la conversation, #3)
//
// Métrique = LlamaEngine.sequenceLogProb(context: prompt, continuation: gold)
// (SouffleuseLlama/LlamaEngine.swift:897) : Σ log P(tokenᵢ | prompt). Plus haut
// (proche de 0) = bon mot ATTEIGNABLE. Hypothèse : logP(C) ≫ logP(A) — réplique
// du −13.37 → −4.19 sur « Tesla » (reach-probe / constat #3).
//
// + Détection de FUITE (constat #2) : on génère sur A et C (greedy, sampling
// prod) et on flague si la sortie recopie les métadonnées (A) ou fait l'écho du
// rôle/message client (C, le risque que la note signale pour le transcript).
//
// Pur scoring + génération courte : aucun historique lu, aucun Keychain. GGUF
// requis (même fichier que Cotypist).
// Usage : SOUFFLEUSE_GGUF=~/…/gemma-3-1b.i1-Q5_K_M.gguf swift run SouffleuseAmorceEval

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// La baseline A = le même chrome d'app que prod injecte, QUEL QUE SOIT le message.
let baseApp = "Intercom"
let baseWindow = "Boîte de réception — Acme"

// Reproduit VERBATIM EnrichedContext.prefix (SouffleuseContext/ContextEnricher.swift:27-44),
// trailing "\n\n" inclus : prod le passe tel quel en ctxPrefix, et buildLlamaPrompt
// en rajoute un second — on réplique donc fidèlement, double saut compris.
func metadataPrefix() -> String { "App \(baseApp), window \"\(baseWindow)\".\n\n" }
// Le transcript : un tour naturel, SANS label [Label:] que le base model imiterait.
func transcriptPrefix(_ clientMessage: String) -> String { "Client : \(clientMessage)" }

struct Case {
    let label: String
    let clientMessage: String   // contexte conversation (contient l'entité atteignable)
    let replyPrefix: String     // beforeCursor : début de réponse, finit sur un mot, SANS espace final
    let gold: String            // continuation idéale, commence par un espace (token SentencePiece)
}

// 7 cas où la bonne continuation dépend d'une entité du message client + 1 contrôle.
// Entité placée en tête de continuation → le delta de reachability s'y concentre.
let cases: [Case] = [
    Case(label: "Binance",
         clientMessage: "Bonjour, j'ai vendu mes cryptos sur Binance et je veux rapatrier l'argent sur mon compte en banque.",
         replyPrefix: "Bonjour, pour rapatrier vos fonds depuis",
         gold: " Binance, lancez un virement depuis l'exchange."),
    Case(label: "Waltio/Solana",
         clientMessage: "Est-ce que Waltio prend en charge les transactions Solana pour ma déclaration ?",
         replyPrefix: "Oui, tout à fait,",
         gold: " Waltio gère bien les transactions Solana."),
    Case(label: "Metamask",
         clientMessage: "Mon wallet Metamask n'est plus reconnu par l'outil depuis la mise à jour.",
         replyPrefix: "Pour reconnecter votre",
         gold: " Metamask, ouvrez l'extension et cliquez sur Connecter."),
    Case(label: "Kraken",
         clientMessage: "Je suis sur Kraken et je n'arrive pas à exporter mon historique de transactions.",
         replyPrefix: "Pour exporter votre historique depuis",
         gold: " Kraken, ouvrez la section Historique."),
    Case(label: "formulaire 2086",
         clientMessage: "Le formulaire 2086 me bloque pour déclarer mes cessions de crypto.",
         replyPrefix: "Le formulaire",
         gold: " 2086 sert à déclarer vos cessions de crypto-actifs."),
    Case(label: "Géraldine",
         clientMessage: "Ma collègue Géraldine m'a dit de vous écrire pour l'intégration.",
         replyPrefix: "Très bien, je vais voir cela avec",
         gold: " Géraldine pour finaliser votre intégration."),
    Case(label: "Fiscalio",
         clientMessage: "On hésite entre votre solution et Fiscalio pour la compta crypto.",
         replyPrefix: "Par rapport à",
         gold: " Fiscalio, notre solution est plus complète."),
    // Contrôle : entité grand public déjà connue du modèle → A/B/C devraient être
    // proches (le contexte n'aide pas un terme déjà atteignable). Valide que la
    // métrique DISCRIMINE rare vs commun.
    Case(label: "Paris (contrôle)",
         clientMessage: "Nous avons rendez-vous à Paris la semaine prochaine.",
         replyPrefix: "Parfait, je vous retrouve à",
         gold: " Paris la semaine prochaine."),
]

// ── Boot engine (pattern InjectionEval/ContextCopyEval) ─────────────────────
let ggufPath = (ProcessInfo.processInfo.environment["SOUFFLEUSE_GGUF"].flatMap { $0.isEmpty ? nil : $0 }
    ?? "~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf")
let resolved = (ggufPath as NSString).expandingTildeInPath
let engine = LlamaEngine()
err("[amorce] loading GGUF: \(resolved)")
guard await engine.load(modelPath: resolved, contextTokens: 4096) else { err("FATAL: GGUF load failed"); exit(1) }
await engine.setCorpus([])   // biais perso OFF : on teste le contexte-texte PUR

// ── Génération courte pour la détection de fuite (sampling prod, greedy) ────
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

// Fuite métadonnées (A) : la sortie recopie-t-elle le chrome injecté ? (constat #2)
func leaksMetadata(_ out: String) -> Bool {
    let o = out.lowercased()
    let needles = [baseApp.lowercased(), "boîte de réception", "acme", "window", "on screen", "app "]
    return needles.contains { $0.count >= 3 && o.contains($0) }
}
// Écho de rôle (C) : la sortie recrache-t-elle « Client » ou un fragment verbatim
// (≥20 car.) du message du correspondant ? (le risque que la note signale pour C)
func echoesClient(_ out: String, _ msg: String) -> Bool {
    let o = out.lowercased()
    if o.contains("client") || o.contains("correspondant") { return true }
    let body = Array(msg.lowercased()); var i = 0
    while i + 20 <= body.count {
        if o.contains(String(body[i..<i+20])) { return true }
        i += 6
    }
    return false
}

func f(_ d: Double?) -> String { d.map { String(format: "%+.2f", $0) } ?? "  nil" }
func pad(_ s: String, _ n: Int) -> String { s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count) }

struct Row {
    let label: String
    let a: Double?; let b: Double?; let c: Double?
    let outA: String; let outC: String
    let leakA: Bool; let echoC: Bool
    var delta: Double? { (a != nil && c != nil) ? c! - a! : nil }
}

// ── Run ─────────────────────────────────────────────────────────────────────
var rows: [Row] = []
for c in cases {
    let pA = LlamaPromptBuilder.buildLlamaPrompt(system: "", customInstr: "", ctxPrefix: metadataPrefix(), fieldContext: "", afterCursor: "", beforeCursor: c.replyPrefix)
    let pB = LlamaPromptBuilder.buildLlamaPrompt(system: "", customInstr: "", ctxPrefix: "", fieldContext: "", afterCursor: "", beforeCursor: c.replyPrefix)
    let pC = LlamaPromptBuilder.buildLlamaPrompt(system: "", customInstr: "", ctxPrefix: transcriptPrefix(c.clientMessage), fieldContext: "", afterCursor: "", beforeCursor: c.replyPrefix)

    let sA = await engine.sequenceLogProb(context: pA, continuation: c.gold)
    let sB = await engine.sequenceLogProb(context: pB, continuation: c.gold)
    let sC = await engine.sequenceLogProb(context: pC, continuation: c.gold)

    let lA = await gen(pA)
    let lC = await gen(pC)

    rows.append(Row(label: c.label, a: sA?.sumLogProb, b: sB?.sumLogProb, c: sC?.sumLogProb,
                    outA: lA, outC: lC, leakA: leaksMetadata(lA), echoC: echoesClient(lC, c.clientMessage)))
}

print("\n══════════ Amorce Eval — métadonnées (A) vs rien (B) vs transcript (C) ══════════")
print("Métrique = Σ logP(continuation gold | prompt) — plus haut (proche de 0) = bon mot ATTEIGNABLE")
print("ΔC−A > 0 = le transcript aide plus que les métadonnées\n")
print("  \(pad("cas", 18))  \(pad("A:méta", 8)) \(pad("B:rien", 8)) \(pad("C:transcr", 9))  \(pad("ΔC−A", 7))")
for r in rows {
    print("  \(pad(r.label, 18))  \(pad(f(r.a), 8)) \(pad(f(r.b), 8)) \(pad(f(r.c), 9))  \(pad(f(r.delta), 7))")
}

print("\n── Génération greedy (voir la FUITE A vs le transcript C) ──")
for r in rows {
    print("  \(pad(r.label, 16)) A\(r.leakA ? "⚠fuite" : "      "): \(r.outA.trimmingCharacters(in: .whitespaces).prefix(58))")
    print("  \(pad("", 16)) C\(r.echoC ? "⚠écho " : "      "): \(r.outC.trimmingCharacters(in: .whitespaces).prefix(58))")
}

let deltas = rows.compactMap { $0.delta }
let meanD = deltas.isEmpty ? 0 : deltas.reduce(0, +) / Double(deltas.count)
let cBeatsA = rows.filter { ($0.delta ?? -1) > 0 }.count
let leakA = rows.filter { $0.leakA }.count
let echoC = rows.filter { $0.echoC }.count
print("\n──────── Bilan (\(deltas.count) cas scorés) ────────")
print(String(format: "  ΔC−A moyen (transcript vs métadonnées) : %+.2f", meanD))
print("  C bat A : \(cBeatsA)/\(deltas.count)")
print("  fuite métadonnées en sortie (A) : \(leakA)/\(rows.count)   écho rôle/client (C) : \(echoC)/\(rows.count)")
print("""

LECTURE :
  ΔC−A ≫ 0 → injecter la conversation en transcript bat le préambule métadonnées
             (réplique #3). Si A FUIT et C non, la stratégie Ticket #1 tient.
  ΔC−A ≈ 0 → le transcript n'aide pas plus que les métadonnées sur ces cas.
  Contrôle « Paris » : Δ ≈ 0 attendu (entité déjà connue) → valide la métrique.
═══════════════════════════════════════════════════════════════════════════════
""")
