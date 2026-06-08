import Foundation
import SouffleuseCore
import SouffleuseLlama
import SouffleuseLog

// ─────────────────────────────────────────────────────────────────────────────
// SouffleuseEchoEval — mesure REPRODUCTIBLE de l'écho mid-mot.
//
// Question : quand le long-ghost est GATÉ « longghost-echo » (le modèle recrache
// ce que tu viens de taper), reste-t-il une VRAIE suite récupérable, ou est-ce de
// l'écho pur ? Et le rognage « malin » (couper à la 1ʳᵉ clause avant la reboucle)
// récupère-t-il plus que le rognage « naïf » (couture seule) ?
//
// Fidélité : MÊME GGUF que le ghost (gemma-3-1b base/pt), MÊME prompt
// (`LlamaPromptBuilder.buildLlamaPrompt`, beforeCursor = préfixe), MÊME sampling
// que la passe greedy long-ghost (temp 0, repeatPenalty 1.3, repeatLastN 64,
// bans, healPrefix = partiel), MÊME garde (`OutputFilter.echoScore ≥ 0.5`).
//
// Usage :
//   SOUFFLEUSE_GGUF=~/…/gemma-3-1b.i1-Q5_K_M.gguf swift run SouffleuseEchoEval
// ─────────────────────────────────────────────────────────────────────────────

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// Préfixes réalistes FR finissant MID-MOT (le domaine du long-ghost). Variés :
// emails, messages, bios, technique, narratif. Certains sont auto-similaires
// (propices à la boucle, comme la bio de la capture), d'autres sont des
// continuations normales.
let prefixes: [String] = [
    // — emails / pro —
    "Bonjour, je vous remercie pour votre message. Je revie",
    "Nous avons bien reçu votre commande et nous vous confir",
    "Suite à notre échange de ce matin, je vous propose de pla",
    "Je me permets de revenir vers vous concernant le dossier que nous avions évo",
    "Pourriez-vous me confirmer la date de la réunion afin que je puisse m'organ",
    "Le projet avance bien, je pense que nous pourrons livrer la première version d'ici la fin du m",
    // — messages / chat —
    "Salut ! Oui je suis dispo demain après-midi, on peut se voir vers quator",
    "Pas de souci, je m'en occupe ce soir et je te tiens au cou",
    "Je crois qu'on s'est mal compris, ce que je voulais dire c'est qu'il fau",
    // — bios auto-similaires (cas de la capture) —
    "Je suis un fan de la technologie et des voitures électr",
    "Je suis passionné de cuisine, de voyages et de pho",
    "J'adore lire, j'adore écrire et j'adore par",
    // — narratif —
    "Le soleil se couchait lentement derrière les collines tandis que les oiseaux reg",
    "Elle ouvrit la porte, jeta un dernier regard à la pièce vide et déci",
    "Après des années de travail acharné, il avait enfin réussi à attein",
    // — technique —
    "La fonction prend en entrée un tableau d'entiers et retourne la somme des élé",
    "Pour configurer le serveur, il faut d'abord installer les dépendances puis lan",
    "Le modèle est entraîné sur un large corpus de textes afin de prédire le prochain mo",
    // — phrases où la fin approche (écho-prones) —
    "Je voulais juste te dire que j'ai beaucoup apprécié notre conversation d'hi",
    "C'est une excellente nouvelle, je suis vraiment très con",
    "Merci infiniment pour ton aide, ça me touche beau",
    "On se retrouve donc demain à la même heure et au même en",
    "Il faut absolument qu'on parle de ce qui s'est passé la semaine der",
    "Je pense sincèrement que c'est la meilleure décision que nous puissions pren",
    // — contextes prone-à-boucle (longs, auto-référentiels, listes) —
    "La radioactivité est un phénomène naturel. Je cherche à savoir si la radioactivité est un dan",
    "Il faut acheter du pain, du lait, des œufs, du beurre, du pain, du lait et du beu",
    "Le chat dort sur le canapé. Le chat dort sur le canapé pendant que le chat dor",
    "Merci pour votre patience. Nous vous remercions encore une fois pour votre pati",
]

// Cas SYNTHÉTIQUES de vraie boucle (ghost = recopie verbatim d'un bout du tail) :
// le nouveau garde DOIT les gater. Sert de contrôle positif au discriminateur.
let syntheticLoops: [(tail: String, ghost: String)] = [
    (tail: "je cherche à savoir si la radioactivité", ghost: "à savoir si la radioactivité est"),
    (tail: "Je suis un fan de la technologie et des voitures", ghost: "Je suis un fan de la technologie et"),
    (tail: "on se retrouve demain à la même heure", ghost: "demain à la même heure et au"),
]

let echoMinRunWords = 4   // seuil candidat : run verbatim ≥ 4 mots = vraie boucle

// ── Boot engine (pattern AmorceEval) ────────────────────────────────────────
let ggufPath = (ProcessInfo.processInfo.environment["SOUFFLEUSE_GGUF"].flatMap { $0.isEmpty ? nil : $0 }
    ?? "~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf")
let resolved = (ggufPath as NSString).expandingTildeInPath
let engine = LlamaEngine()
err("[echo] loading GGUF: \(resolved)")
guard await engine.load(modelPath: resolved, contextTokens: 4096) else { err("FATAL: GGUF load failed"); exit(1) }
await engine.setCorpus([])   // biais perso OFF (la passe long-ghost utilise personalizationStrength 0)

// Génération FIDÈLE à la passe greedy long-ghost (ModelRuntime).
func longGhostGen(prefix: String, partial: String) async -> String {
    final class Acc: @unchecked Sendable { var text = "" }
    let acc = Acc()
    let prompt = LlamaPromptBuilder.buildLlamaPrompt(
        system: "", customInstr: "", ctxPrefix: "", fieldContext: "",
        afterCursor: "", beforeCursor: prefix)
    _ = await engine.generate(
        prompt: prompt,
        maxTokens: 14,                       // midWordLongGhostMaxTokens défaut
        sampling: LlamaSampling(
            temperature: 0, repeatPenalty: 1.3, repeatLastN: 64, seed: 0,
            personalizationStrength: 0, banMarkup: true, banDigitsLeading: true,
            banEmoji: true,
            healPrefix: partial.isEmpty ? nil : partial
        )
    ) { piece in acc.text += piece; return true }
    return acc.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? acc.text
}

// ── Mesure : garde ACTUEL (sac-de-mots) vs garde POSITIONNEL ────────────────
struct Row {
    let prefix: String; let gen: String
    let s: Double            // echoScore sac-de-mots (garde actuel)
    let run: Int             // plus long run verbatim (discriminateur positionnel)
    var oldGate: Bool { s >= OutputFilter.continuationEchoThreshold }
    var newGate: Bool { oldGate && run >= echoMinRunWords }   // gate seulement si vraie boucle
}

let threshold = OutputFilter.continuationEchoThreshold
var rows: [Row] = []

for prefix in prefixes {
    let partial = OutputFilter.trailingPartialWord(prefix)
    let gen = await longGhostGen(prefix: prefix, partial: partial)
    let s = OutputFilter.echoScore(ghost: gen, tail: prefix)
    let run = OutputFilter.longestVerbatimRunWords(ghost: gen, tail: prefix)
    rows.append(Row(prefix: prefix, gen: gen, s: s, run: run))
}

func pct(_ n: Int, _ d: Int) -> String { d == 0 ? "0%" : "\(Int((Double(n) / Double(d) * 100).rounded()))%" }
func f2(_ x: Double) -> String { let n = Int((x * 100).rounded()); return "\(n/100).\(String(format: "%02d", n%100))" }
func tail40(_ s: String) -> String { s.count <= 40 ? s : "…" + String(s.suffix(38)) }

print("")
print("════════════════════════════════════════════════════════════════════════")
print(" SouffleuseEchoEval — \(rows.count) préfixes · seuil sac-de-mots \(f2(threshold)) · run≥\(echoMinRunWords)")
print("════════════════════════════════════════════════════════════════════════")
print("")

// Désaccords = ghosts que le garde ACTUEL tue mais que le POSITIONNEL garderait.
let recovered = rows.filter { $0.oldGate && !$0.newGate }    // bons ghosts récupérés
let stillGated = rows.filter { $0.newGate }                  // vrais échos toujours gatés

print("GHOSTS RÉCUPÉRÉS (gatés aujourd'hui à tort → affichés avec le garde positionnel) :")
print("")
for r in recovered {
    print("  tail   : …\(tail40(r.prefix))")
    print("  ghost  : \(r.gen.debugDescription)")
    print("  → s=\(f2(r.s)) (gaté) mais run verbatim=\(r.run) mots (< \(echoMinRunWords)) ⇒ PAS une boucle ✅ affiché")
    print("")
}
if !stillGated.isEmpty {
    print("VRAIS ÉCHOS (gatés par les DEUX gardes — corpus prone-à-boucle) :")
    print("")
    for r in stillGated {
        print("  tail   : …\(tail40(r.prefix))")
        print("  ghost  : \(r.gen.debugDescription)   s=\(f2(r.s)) run=\(r.run) ⇒ boucle, gaté ✓")
        print("")
    }
}

// Contrôle positif : les boucles synthétiques DOIVENT être gatées par le positionnel.
print("CONTRÔLE — boucles synthétiques (le garde positionnel DOIT les gater) :")
print("")
var synthOK = 0
for c in syntheticLoops {
    let s = OutputFilter.echoScore(ghost: c.ghost, tail: c.tail)
    let run = OutputFilter.longestVerbatimRunWords(ghost: c.ghost, tail: c.tail)
    let gated = s >= threshold && run >= echoMinRunWords
    if gated { synthOK += 1 }
    print("  ghost \(c.ghost.debugDescription)  s=\(f2(s)) run=\(run) ⇒ \(gated ? "GATÉ ✓" : "PASSÉ ✗ (raté !)")")
}
print("")
print("────────────────────────────────────────────────────────────────────────")
print(" SYNTHÈSE")
print("────────────────────────────────────────────────────────────────────────")
print("  Préfixes testés ................... \(rows.count)")
print("  Gatés par garde ACTUEL (sac-mots) . \(rows.filter { $0.oldGate }.count)")
print("  Gatés par garde POSITIONNEL ....... \(rows.filter { $0.newGate }.count)")
print("  → bons ghosts RÉCUPÉRÉS ............ \(recovered.count)  (\(pct(recovered.count, rows.filter { $0.oldGate }.count)) des gatés actuels)")
print("  Boucles synthétiques gatées ....... \(synthOK)/\(syntheticLoops.count)")
print("")
print("  VERDICT :")
if synthOK == syntheticLoops.count && recovered.count > 0 {
    print("  ✅ Le garde POSITIONNEL sépare proprement : il récupère \(recovered.count) bon(s)")
    print("  ghost(s) tué(s) à tort, ET continue de gater 100% des vraies boucles.")
    print("  → Implémenter : gate = echoScore≥\(f2(threshold)) ET run verbatim≥\(echoMinRunWords) mots.")
} else if synthOK < syntheticLoops.count {
    print("  ⚠️ Le positionnel laisse passer des boucles (\(synthOK)/\(syntheticLoops.count)) → seuil run trop haut,")
    print("  baisser echoMinRunWords ou combiner avec un autre signal.")
} else {
    print("  Aucun bon ghost récupéré sur ce corpus — soit l'écho est rare, soit le")
    print("  seuil run mérite calibration (voir les run= ci-dessus).")
}
print("")

await engine.unload()
