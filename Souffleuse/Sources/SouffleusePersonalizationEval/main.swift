import Foundation
import SouffleuseCore
import SouffleuseLlama
import SouffleuseLog
import SouffleuseCorpus
import SouffleusePersonalization
import SouffleuseTyping

// Souffleuse Personalization Eval
//
// Goal (parité Cotypist) : un terme APPRIS — un nom propre, du jargon, un mot
// que le base model ne produirait jamais spontanément ("Binance", "Fiscalio",
// "Géraldine") — doit RESSORTIR dans le ghost dès que le contexte tapé matche
// ce qu'on a mémorisé. Le biais de logits historique (nucleus-gated) ne peut
// que RE-RANKER des tokens déjà plausibles : il ne fait jamais émerger un terme
// rare. Cet eval mesure exactement ça, en A/B/C :
//
//   base  : personalizationStrength = 0            (aucun biais — counterfactual)
//   bias  : strength = 1, promotion OFF            (ancien comportement)
//   promo : strength = 1, promotion ON (défaut)    (nouveau levier)
//
// Le corpus est SYNTHÉTIQUE (aucune donnée utilisateur lue, privacy-safe). On
// y répète chaque phrase apprise 3× pour simuler un usage récurrent → la
// promotion s'arme (matchLen long, count ≥ 3, share = 1.0).
//
// Métrique principale : sur 50 prompts (25 « personnalisables » + 25 contrôles),
//   - hits        = ghosts personnalisables contenant le terme appris
//   - sur-injection = contrôles dans lesquels un terme appris fuit (faux positif)
//   - lift        = hits(promo) − hits(base)
// Plus, pour le chemin INSTANT nommé dans le goal :
//   - strongCorpusMatch / historyExactSubstringMatch fire counts.
//
// Usage :
//   SOUFFLEUSE_GGUF=~/Library/Application\ Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf \
//     swift run -c release SouffleusePersonalizationEval
// Tuning sans rebuild :
//   SOUFFLEUSE_PROMOTE_MATCHLEN=3 SOUFFLEUSE_PROMOTE_MINCOUNT=3 \
//   SOUFFLEUSE_PROMOTE_SHARE=0.6  SOUFFLEUSE_PROMOTE_OVERSHOOT=0.5 …

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

func envFloat(_ k: String) -> Float? {
    guard let v = ProcessInfo.processInfo.environment[k], let f = Float(v) else { return nil }
    return f
}
func envInt(_ k: String) -> Int32? {
    guard let v = ProcessInfo.processInfo.environment[k], let i = Int32(v) else { return nil }
    return i
}

// ── Données apprises : (lead-in contextuel, terme appris) ──────────────────
// Le terme est volontairement indevinable par le base model. Le prompt = le
// lead-in EXACT (sans espace final) ; le ghost attendu commence par le terme.
struct Learned: Sendable { let lead: String; let term: String }

let learned: [Learned] = [
    .init(lead: "Pour mes paiements en crypto je passe toujours par", term: "Binance"),
    .init(lead: "Mon exchange principal reste évidemment", term: "Binance"),
    .init(lead: "J'ai transféré les fonds vers mon compte", term: "Binance"),
    .init(lead: "Le wallet hardware que je recommande c'est le", term: "Ledger"),
    .init(lead: "Je stocke mes clés privées sur mon", term: "Ledger"),
    .init(lead: "Notre logiciel de fiscalité crypto s'appelle", term: "Fiscalio"),
    .init(lead: "Pour déclarer mes plus-values j'utilise", term: "Fiscalio"),
    .init(lead: "Le projet sur lequel je bosse en ce moment c'est", term: "Cocotypist"),
    .init(lead: "L'app d'assistant de frappe que je développe s'appelle", term: "Cocotypist"),
    .init(lead: "La blockchain que je préfère pour les NFT reste", term: "Solana"),
    .init(lead: "J'ai minté la collection sur", term: "Solana"),
    .init(lead: "L'autre exchange sur lequel j'ai un compte c'est", term: "Kraken"),
    .init(lead: "Pour le staking je passe par", term: "Kraken"),
    .init(lead: "Mon extension de wallet préférée reste", term: "Metamask"),
    .init(lead: "Ma collègue sur ce dossier s'appelle", term: "Géraldine"),
    .init(lead: "Le rendez-vous de demain est avec", term: "Géraldine"),
    .init(lead: "Mon associé sur la partie technique c'est", term: "Aurélien"),
    .init(lead: "Cet été nous retournons en vacances à", term: "Étretat"),
    .init(lead: "Le moteur de suggestion in-house s'appelle", term: "Souffleuse"),
    .init(lead: "Pour le classement des candidats on utilise la distance de", term: "Damerau"),
    .init(lead: "La base chiffrée repose sur", term: "SQLCipher"),
    .init(lead: "L'app concurrente dont on vise la parité c'est", term: "Cotypist"),
    .init(lead: "Mon broker actions de référence reste", term: "Trade Republic"),
    .init(lead: "Le langage du projet est figé sur", term: "Swift"),
    .init(lead: "Notre cible matérielle c'est uniquement Apple", term: "Silicon"),
]

// ── Contrôles : débuts de phrase génériques. Un terme appris qui fuit ici est
//    une SUR-INJECTION (faux positif), pas de la personnalisation. ───────────
let controls: [String] = [
    "Merci beaucoup pour votre",
    "Je vous souhaite une excellente",
    "N'hésitez pas à revenir vers",
    "Nous reviendrons vers vous dans les meilleurs",
    "Bonjour, j'espère que vous allez",
    "Je reste à votre entière",
    "Pourriez-vous me confirmer la",
    "C'est noté, je m'en occupe dès",
    "Désolé pour la réponse",
    "Je vous remercie de votre",
    "Comme convenu lors de notre",
    "Veuillez trouver ci-joint le",
    "Je me permets de vous",
    "Au plaisir de vous lire très",
    "Excellente nouvelle, tout est",
    "Le dossier a bien été",
    "Pourriez-vous patienter encore quelques",
    "Voici le récapitulatif de la",
    "Je confirme la bonne réception de votre",
    "Belle journée et à très",
    "Avec plaisir, je vous tiens au",
    "Nous avons bien pris en compte votre",
    "Sachez que nous restons",
    "Permettez-moi de vous souhaiter une bonne",
    "Tout est en ordre de notre",
]

// ── Near-miss : prompts qui COMMENCENT comme un lead appris puis DIVERGENT
//    (un token de plus, hors corpus). Le suffix-array peut alors matcher un
//    contexte COURT coïncidant (ex. « …par » → "Binance" count 3, share 1.0).
//    Avec un garde-fou trop laxiste (matchLen 1) le terme appris s'injecterait
//    à tort ("…je passe toujours par la Binance"). À matchLen ≥ 3 le match court
//    ne promeut pas. Ces contrôles rendent la métrique de sur-injection
//    SENSIBLE — c'est la preuve que le plancher matchLen est porteur. ──────────
let nearMiss: [String] = [
    "Pour mes paiements en crypto je passe toujours par la",
    "Mon exchange principal reste fermé le",
    "Le wallet hardware que je recommande c'est le tien et le",
    "La blockchain que je préfère pour les NFT reste lente mais",
    "Ma collègue sur ce dossier s'appelle comme ma",
    "Le projet sur lequel je bosse en ce moment c'est top mais",
    // Queue COÏNCIDANTE : finit sur un token interne au corpus ("j'utilise",
    // qui y précède "Fiscalio"). Match court (1-2 tokens). À matchLen ≥ 3 : pas de
    // promotion ; à matchLen 1 : "Fiscalio" s'injecterait à tort → c'est CE cas
    // qui prouve que le plancher matchLen est porteur.
    "Je ne sais plus quel logiciel j'utilise",
    "Voici le terminal hardware que je",
]

// ── Corpus synthétique : chaque phrase apprise répétée 3× (usage récurrent). ─
let repeats = 3
var corpus: [String] = []
var historySnapshot: [TypingHistoryEntry] = []
for (i, l) in learned.enumerated() {
    let full = l.lead + " " + l.term
    for _ in 0..<repeats { corpus.append(full) }
    // Snapshot pour le chemin instant (strongCorpusMatch / exactSubstring).
    historySnapshot.append(TypingHistoryEntry(
        timestamp: Date(timeIntervalSince1970: Double(1000 - i)),
        contextBefore: l.lead, accepted: l.term, bundleID: nil
    ))
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
err("[perso] loading GGUF: \(ggufPath)")
guard await engine.load(modelPath: ggufPath, contextTokens: 4096) else {
    err("[perso] FATAL: could not load GGUF"); exit(1)
}
await engine.setCorpus(corpus)
err("[perso] corpus entries: \(corpus.count) (\(learned.count) learned terms ×\(repeats))")

// ── Un appel de génération, profil prod (greedy, bans), healing OFF (prompts
//    finissent sur un mot complet → next-word). `promote`/`strength` varient. ─
let envStrength = envFloat("SOUFFLEUSE_PERSO_STRENGTH")
func runOnce(_ prefix: String, strength: Float, promote: Bool) async -> String {
    let prompt = LlamaPromptBuilder.buildLlamaPrompt(
        system: "", customInstr: "", ctxPrefix: "", fieldContext: "",
        afterCursor: "", beforeCursor: prefix
    )
    final class Acc: @unchecked Sendable { var text = "" }
    let acc = Acc()
    _ = await engine.generate(
        prompt: prompt,
        maxTokens: 6,
        sampling: LlamaSampling(
            temperature: 0,
            repeatPenalty: 1.3,
            repeatLastN: 64,
            personalizationStrength: strength,
            banMarkup: true,
            banDigitsLeading: true,
            banEmoji: true,
            promoteStrongMatches: promote,
            promoteMatchLen: envInt("SOUFFLEUSE_PROMOTE_MATCHLEN") ?? 0,
            promoteMinCount: envInt("SOUFFLEUSE_PROMOTE_MINCOUNT") ?? 0,
            promoteShare: envFloat("SOUFFLEUSE_PROMOTE_SHARE") ?? 0,
            promoteOvershoot: envFloat("SOUFFLEUSE_PROMOTE_OVERSHOOT") ?? 0,
            promoteMaxGap: envFloat("SOUFFLEUSE_PROMOTE_MAXGAP") ?? 0,
            minFirstTokenProb: 0.0001,
            healPrefix: nil
        )
    ) { tok in acc.text += tok; return true }
    return acc.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? acc.text
}

func contains(_ haystack: String, _ needle: String) -> Bool {
    haystack.lowercased().contains(needle.lowercased())
}
let allTerms = Array(Set(learned.map { $0.term }))

// gain scale appliqué côté prod (slider × 6.0). On reproduit : strength 1.0
// utilisateur → 6.0 effectif. La struct prend déjà la valeur effective.
let userStrength = envStrength ?? 1.0
let effective = userStrength * LlamaSampling.personalizationGainScale

struct Row { let label: String; let expect: String?; let base: String; let bias: String; let promo: String }
var rows: [Row] = []

err("[perso] running 25 learned + 25 control prompts × 3 conditions…")
for l in learned {
    let base = await runOnce(l.lead, strength: 0, promote: false)
    let bias = await runOnce(l.lead, strength: effective, promote: false)
    let promo = await runOnce(l.lead, strength: effective, promote: true)
    rows.append(Row(label: l.term, expect: l.term, base: base, bias: bias, promo: promo))
}
for c in controls + nearMiss {
    let base = await runOnce(c, strength: 0, promote: false)
    let bias = await runOnce(c, strength: effective, promote: false)
    let promo = await runOnce(c, strength: effective, promote: true)
    rows.append(Row(label: "ctrl", expect: nil, base: base, bias: bias, promo: promo))
}

// ── Scoring ────────────────────────────────────────────────────────────────
let hits: (@escaping (Row) -> String) -> Int = { pick in
    rows.filter { $0.expect != nil && contains(pick($0), $0.expect!) }.count
}
let overInjections: (@escaping (Row) -> String) -> Int = { pick in
    rows.filter { r in r.expect == nil && allTerms.contains { term in contains(pick(r), term) } }.count
}
let learnedCount = rows.filter { $0.expect != nil }.count
let controlCount = rows.filter { $0.expect == nil }.count

// Chemin instant (métriques nommées dans le goal).
var strongFires = 0, exactFires = 0
for l in learned {
    if SuggestionPolicy.strongCorpusMatch(userTail: l.lead + " ", snapshot: historySnapshot) != nil { strongFires += 1 }
    if SuggestionPolicy.historyExactSubstringMatch(userTail: l.lead, snapshot: historySnapshot) != nil { exactFires += 1 }
}

func line(_ s: String, _ n: Int) -> String { s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count) }

print("\n──────────────── Personalization Eval ────────────────")
print("corpus: \(corpus.count) entries  |  learned prompts: \(learnedCount)  |  controls: \(controlCount)")
print("user strength: \(userStrength)  → effective: \(effective)")
print("\n  per-learned-prompt ghosts (term | base → bias → promo) :")
for r in rows where r.expect != nil {
    let mark = { (s: String) in contains(s, r.expect!) ? "✓" : "·" }
    print("    \(line(r.expect!, 16)) base[\(mark(r.base))] \(line(r.base.trimmingCharacters(in: .whitespaces), 22)) | bias[\(mark(r.bias))] | promo[\(mark(r.promo))] \(r.promo.trimmingCharacters(in: .whitespaces))")
}
let leaks = rows.filter { r in r.expect == nil && allTerms.contains { contains(r.promo, $0) } }
if !leaks.isEmpty {
    print("\n  ⚠️ over-injection (PROMO) — learned term leaked into a control ghost :")
    for r in leaks { print("    promo → \(r.promo.trimmingCharacters(in: .whitespaces))") }
}
print("\n──────────────── Summary (/\(rows.count)) ────────────────")
print("  LLM personalized hits   base : \(hits { $0.base })/\(learnedCount)")
print("  LLM personalized hits   bias : \(hits { $0.bias })/\(learnedCount)")
print("  LLM personalized hits   PROMO: \(hits { $0.promo })/\(learnedCount)   ← objectif ≥ 2")
print("  lift (promo − base)          : +\(hits { $0.promo } - hits { $0.base })")
print("  over-injection on controls   base:\(overInjections { $0.base }) bias:\(overInjections { $0.bias }) PROMO:\(overInjections { $0.promo })/\(controlCount)")
print("  instant strongCorpusMatch    : \(strongFires)/\(learnedCount)")
print("  instant exactSubstringMatch  : \(exactFires)/\(learnedCount)")
print("───────────────────────────────────────────────────────\n")
