// SouffleuseMaxWordsEval — balayage du cap `maxWords` du beam de prod.
//
// QUESTION : sur le chemin BEAM (le défaut), la préférence « Long » est rognée
// par le cap interne `BeamConfig.maxWords` (=3 en prod, BeamGhostEngine.swift).
// Au-delà de quelle longueur le ghost cesse-t-il d'être COHÉRENT ? On cherche le
// `maxWords` le plus grand qui garde un ghost lisible (pas de queue pendante sur
// un mot-outil, pas de répétition dégénérée) à latence raisonnable.
//
// MÉTHODE : pour chaque phrase, on coupe à ~1/3 (frontière après-espace — le cas
// où le ghost doit dérouler plusieurs mots). Pour chaque `maxWords` du balayage,
// on RECONSTRUIT le beam avec ce cap (le critère d'arrêt est `config.maxWords`,
// un simple trim post-filtre ne suffirait pas) puis on régénère. On mesure la
// dégradation INTRINSÈQUE (la cohérence « Long » est une affaire de fluidité, pas
// de coller à CETTE phrase précise) + la latence, et on dump chaque ghost.
//
// Config beam = celle de prod (`ghostCore`) sauf `maxWords`/`maxTokens` balayés :
// K=2, exp=0.7. maxTokens dimensionné `maxWords*4+2` (cf. PreferencesStore).
//
// Usage :
//   swift run -c release SouffleuseMaxWordsEval
//   MAXWORDS_SWEEP=3,4,5,6,7,8 swift run -c release SouffleuseMaxWordsEval
//   SOUFFLEUSE_GGUF=~/.../gemma-3-1b.i1-Q5_K_M.gguf swift run -c release SouffleuseMaxWordsEval

import Foundation
import SouffleuseCore
import SouffleuseLlama

let env = ProcessInfo.processInfo.environment
func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// ── Résolution du GGUF (miroir de SouffleuseBeamGhostProbe.resolveGGUF) ──
func resolveGGUF() -> String? {
    let fileName = "gemma-3-1b.i1-Q5_K_M.gguf"
    if let ov = env["SOUFFLEUSE_GGUF"], !ov.isEmpty {
        return (ov as NSString).expandingTildeInPath
    }
    let fm = FileManager.default
    if let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        .map({ $0.appendingPathComponent("Souffleuse/Models").path }) {
        let local = (dir as NSString).appendingPathComponent(fileName)
        if fm.fileExists(atPath: local) { return local }
    }
    let cotypist = ("~/Library/Application Support/app.cotypist.Cotypist/Models" as NSString)
        .expandingTildeInPath
    let fallback = (cotypist as NSString).appendingPathComponent(fileName)
    if fm.fileExists(atPath: fallback) { return fallback }
    return nil
}

// ── Corpus FR multi-registres (email pro, formel, casual, technique, etc.) ──
let corpus: [String] = [
    "Je vous confirme la disponibilité du produit pour la livraison de mardi prochain.",
    "Bonjour Madame, suite à notre échange je me permets de revenir vers vous.",
    "Merci beaucoup pour hier soir, c'était vraiment une super soirée entre amis.",
    "Pourriez-vous me transmettre le rapport financier avant la fin de la semaine ?",
    "Je suis désolé pour le retard, j'ai eu un imprévu de dernière minute.",
    "N'hésitez pas à me contacter si vous avez la moindre question complémentaire.",
    "Le projet avance bien et nous devrions tenir les délais initialement prévus.",
    "Je te propose qu'on se retrouve devant le cinéma vers vingt heures ce soir.",
    "Votre rapport fiscal annuel est désormais disponible dans votre espace personnel.",
    "Après réflexion, je pense que la meilleure option reste de reporter la réunion.",
    "Il faudrait penser à réserver les billets de train avant que les prix augmentent.",
    "Comme convenu lors de notre dernier appel, je vous envoie le devis en pièce jointe.",
]

// ── Coupe : prefix = ~1/3 des mots + espace (frontière après-espace) ; truth = reste ──
func splitPrefix(_ sentence: String) -> (prefix: String, truth: String) {
    let words = sentence.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard words.count >= 6 else { return (sentence + " ", "") }
    let k = max(2, words.count / 3)
    let prefix = words[0..<k].joined(separator: " ") + " "
    let truth = words[k...].joined(separator: " ")
    return (prefix, truth)
}

// ── Heuristiques de cohérence intrinsèque ──

// Mots-outils français : un ghost qui se termine là-dessus est tronqué de façon
// incohérente (« ... pour la » / « ... et » — la pill propose une queue pendante).
let functionWords: Set<String> = [
    "le", "la", "les", "l", "un", "une", "des", "de", "du", "d", "au", "aux",
    "et", "ou", "à", "en", "que", "qui", "dans", "sur", "sous", "pour",
    "par", "avec", "sans", "ce", "cet", "cette", "ces", "mon", "ma", "mes",
    "ton", "ta", "tes", "son", "sa", "ses", "notre", "votre", "leur", "leurs",
    "ne", "se", "je", "tu", "il", "elle", "on", "nous", "vous", "ils", "elles",
    "ni", "car", "donc", "mais", "or", "puis", "afin", "vers", "chez",
    "est", "a", "ont", "sont", "qu",
]

func normWord(_ s: Substring) -> String {
    s.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters)
}

func ghostWords(_ ghost: String) -> [String] {
    ghost.split(whereSeparator: { $0.isWhitespace }).map(normWord).filter { !$0.isEmpty }
}

// Queue pendante : dernier mot du ghost = mot-outil → tronqué de façon incohérente.
func hasDanglingTail(_ ghost: String) -> Bool {
    guard let last = ghostWords(ghost).last else { return false }
    return functionWords.contains(last)
}

// Répétition dégénérée : mot consécutif dupliqué OU bigramme répété (boucle du base model).
func hasRepetition(_ ghost: String) -> Bool {
    let w = ghostWords(ghost)
    guard w.count >= 2 else { return false }
    for i in 0..<(w.count - 1) where w[i] == w[i + 1] { return true }
    // Bigramme répété (i,i+1) == (j,j+1) plus loin. `while` pour éviter le range
    // vide quand i+2 dépasse la borne (w.count - 1).
    var i = 0
    while i + 1 < w.count {
        var j = i + 2
        while j + 1 < w.count {
            if w[i] == w[j] && w[i + 1] == w[j + 1] { return true }
            j += 1
        }
        i += 1
    }
    return false
}

// Arrêt propre : le ghost se termine sur une ponctuation de fin de phrase/clause.
func endsClean(_ ghost: String) -> Bool {
    guard let last = ghost.trimmingCharacters(in: .whitespaces).last else { return false }
    return ".!?".contains(last)
}

// Nombre de mots de tête du ghost identiques à la vérité terrain (informatif).
func truthWordMatch(_ ghost: String, _ truth: String) -> Int {
    let g = ghostWords(ghost)
    let t = truth.split(whereSeparator: { $0.isWhitespace }).map(normWord).filter { !$0.isEmpty }
    var n = 0
    while n < g.count, n < t.count, g[n] == t[n] { n += 1 }
    return n
}

// ── Config beam : prod `ghostCore` (K=2, exp=0.7), seul `maxWords` varie ──
func configFor(maxWords: Int) -> BeamConfig {
    BeamConfig(
        maxSearchWidth: 2,
        maxResultWidth: 2,
        minBranchProbability: 0.05,
        relativeCutoff: 1e-10,
        positionExponent: 0.7,
        maxTokens: maxWords * 4 + 2,   // dimensionné comme PreferencesStore (mot long FR ≤ 4 tok)
        maxWords: maxWords
    )
}

// Trim-arrière : on a généré jusqu'au cap, on RECULE jusqu'au dernier stop propre
// (on lâche les mots-outils traînants en fin). Ne raccourcit QUE quand la fin était
// bancale — « lien vers le site de la » → « lien vers le site » ; « informe que »
// → « informe ». Garde la longueur quand la fin est déjà du contenu. La virgule
// reste ATTACHÉE au mot (« demande, ») donc une fin sur clause-virgule survit.
func trimBackToCleanStop(_ ghost: String) -> String {
    func isTerminal(_ s: String) -> Bool { s.contains(where: { ".!?".contains($0) }) }
    var parts = ghost.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    while let last = parts.last {
        // Une fin sur ponctuation forte (« est à jour ? ») est PROPRE : on la garde.
        if isTerminal(last) { break }
        let n = normWord(Substring(last))
        // On lâche les mots-outils traînants et les tokens ponctuation-seuls (« , » nu).
        if n.isEmpty || functionWords.contains(n) { parts.removeLast() } else { break }
    }
    return parts.joined(separator: " ")
}

struct GenOut {
    let ghost: String   // ghost post-filtré (hard-cap maxWords)
    let wallMs: Int     // latence mur de l'appel beam
    let decodeMs: Int   // boucle pas-à-pas (decode multi-seq + scan vocab)
    let prefillMs: Int  // llama_decode du suffixe de prompt neuf
    let promptTok: Int
    let reusedTok: Int  // part du prompt réutilisée du KV cache (LCP)
}

// ── Un pas de génération beam, fidèle à `ModelRuntime.generateGhostBeam` ──
func genGhost(_ beam: BeamGhostEngine, prefix: String, maxWords: Int) async -> GenOut {
    let choice = BeamGhostShaper.beamConfigChoice(userTail: prefix, beamWidth: 2)
    let prompt = BeamGhostShaper.buildPrompt(customInstr: "", ctxPrefix: "", llmTail: prefix)
    let width = choice.isBoundary ? 1 : choice.width
    let t0 = Date()
    let result = await beam.ghost(prompt: prompt, requiredPrefix: choice.requiredPrefix, maxWidth: width)
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    let caretAfterSpace = prefix.last == " " || prefix.last == "\t"
    let ghost = BeamGhostShaper.beamPostFilter(
        rawGhost: result.best?.ghost ?? "", isBoundary: choice.isBoundary,
        caretAfterSpace: caretAfterSpace, userTail: prefix, maxWords: maxWords)
    return GenOut(ghost: ghost, wallMs: ms, decodeMs: result.decodeMillis,
                  prefillMs: result.prefillMillis, promptTok: result.promptTokenCount,
                  reusedTok: result.reusedPrefixTokens)
}

// ─────────────────────────────────────────────────────────────────────────────

guard let gguf = resolveGGUF() else {
    err("FATAL: GGUF introuvable. Pose SOUFFLEUSE_GGUF=<chemin/gemma-3-1b.i1-Q5_K_M.gguf>.")
    exit(1)
}

// Sweep monté plus HAUT que la plage utile : on cherche le PLATEAU des mots
// réellement affichés (après trim) — le cap où générer plus n'ajoute plus de
// mots mais coûte toujours plus de latence (le genou).
let sweep: [Int] = (env["MAXWORDS_SWEEP"].map { $0.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) } })
    .flatMap { $0.isEmpty ? nil : $0 } ?? [3, 4, 5, 6, 8, 10, 12]

let prefixes = corpus.map { splitPrefix($0) }

print("══════════════════════════════════════════════════════════════════════")
print(" SouffleuseMaxWordsEval — balayage maxWords du beam de prod (K=2, exp=0.7)")
print(" GGUF   : \((gguf as NSString).lastPathComponent)")
print(" Phrases: \(corpus.count) · frontière après-espace (cas « Long »)")
print(" Sweep  : maxWords ∈ \(sweep)")
print("══════════════════════════════════════════════════════════════════════")

struct Agg {
    var n = 0
    var words = 0
    var dangling = 0
    var repeats = 0
    var clean = 0
    var ms = 0
    var decode = 0
    var prefill = 0
    var truthMatch = 0
    // Mêmes phrases, APRÈS trim-arrière (ce qui serait réellement affiché en Long).
    var trimWords = 0
    var trimDangling = 0
    var trimClean = 0
    var trimRepeats = 0   // dérive/boucle (mot/bigramme répété) — borne HAUTE du cap Long
}
var aggByMW: [Int: Agg] = [:]
// Sorties du cap le plus haut, conservées pour le dump qualitatif « rendu caret ».
let trimCap = sweep.max() ?? 8
var cap8Outputs: [(prefix: String, truth: String, ghost: String, wallMs: Int)] = []

for mw in sweep {
    let beam = BeamGhostEngine(config: configFor(maxWords: mw))
    guard await beam.load(modelPath: gguf, contextTokens: 4096) else {
        err("FATAL: chargement GGUF échoué pour maxWords=\(mw)."); exit(1)
    }
    var agg = Agg()
    print("\n──────────────────────────────────────────────────────────────────────")
    print(" maxWords = \(mw)   (maxTokens = \(mw * 4 + 2))")
    print("──────────────────────────────────────────────────────────────────────")
    for (prefix, truth) in prefixes {
        let out = await genGhost(beam, prefix: prefix, maxWords: mw)
        let ghost = out.ghost
        let ms = out.wallMs
        if mw == trimCap { cap8Outputs.append((prefix, truth, ghost, ms)) }
        let w = ghostWords(ghost).count
        let dangling = hasDanglingTail(ghost)
        let rep = hasRepetition(ghost)
        let clean = endsClean(ghost)
        let tm = truthWordMatch(ghost, truth)
        agg.n += 1; agg.words += w; agg.ms += ms; agg.truthMatch += tm
        agg.decode += out.decodeMs; agg.prefill += out.prefillMs
        if dangling { agg.dangling += 1 }
        if rep { agg.repeats += 1 }
        if clean { agg.clean += 1 }
        // Même génération, trim-arrière appliqué → ce qui serait affiché en Long.
        let trimmed = trimBackToCleanStop(ghost)
        agg.trimWords += ghostWords(trimmed).count
        if hasDanglingTail(trimmed) { agg.trimDangling += 1 }
        if endsClean(trimmed) { agg.trimClean += 1 }
        if hasRepetition(trimmed) { agg.trimRepeats += 1 }
        var flags: [String] = []
        if dangling { flags.append("PENDANT") }
        if rep { flags.append("RÉPÉTITION") }
        if clean { flags.append("·fin propre") }
        let flagStr = flags.isEmpty ? "" : "  [\(flags.joined(separator: " "))]"
        let pfxShort = prefix.count > 34 ? "…" + String(prefix.suffix(33)) : prefix
        print(String(format: "  %-34@ → ⟨%@⟩  (%dmots %dms)%@",
                     pfxShort as NSString, ghost as NSString, w, ms, flagStr as NSString))
    }
    aggByMW[mw] = agg
}

// ── Synthèse ──
print("\n══════════════════════════════════════════════════════════════════════")
print(" SYNTHÈSE  (n=\(corpus.count) phrases par ligne)")
print("══════════════════════════════════════════════════════════════════════")
print(String(format: " %-9@ %-7@ %-9@ %-8@ %-8@ %-8@ %-10@ %-9@",
             "maxWords" as NSString, "ø mots" as NSString, "%pendant" as NSString,
             "%propre" as NSString, "ø ms" as NSString, "ødecode" as NSString,
             "øprefill" as NSString, "øvérité" as NSString))
print(" ─────────────────────────────────────────────────────────────────────")
for mw in sweep {
    guard let a = aggByMW[mw], a.n > 0 else { continue }
    let n = Double(a.n)
    let avgWords = Double(a.words) / n
    let pctDangling = 100.0 * Double(a.dangling) / n
    let pctClean = 100.0 * Double(a.clean) / n
    let avgMs = Double(a.ms) / n
    let avgDecode = Double(a.decode) / n
    let avgPrefill = Double(a.prefill) / n
    let avgTruth = Double(a.truthMatch) / n
    print(String(format: " %-9d %-7.1f %-9.0f %-8.0f %-8.0f %-8.0f %-10.0f %-9.1f",
                 mw, avgWords, pctDangling, pctClean, avgMs, avgDecode, avgPrefill, avgTruth))
}
print(" (ø ms = latence mur ; ødecode = boucle pas-à-pas ; øprefill = llama_decode prompt neuf)")

// ── VARIANTE trim-arrière APPLIQUÉE À CHAQUE CAP : recherche du plateau ──
// Chaque cap génère (et paie la latence) jusqu'à `maxWords`, puis trim-arrière.
// On regarde où « ø mots affichés » plateau (le modèle finit ses phrases / gating)
// tandis que « ø ms » continue de monter → c'est le genou, le bon cap Long.
print("\n══════════════════════════════════════════════════════════════════════")
print(" TRIM-ARRIÈRE PAR CAP  — recherche du genou (mots affichés vs latence)")
print("══════════════════════════════════════════════════════════════════════")
print(String(format: " %-6@ %-10@ %-11@ %-9@ %-8@ %-8@ %-9@ %-8@",
             "cap" as NSString, "hard-mots" as NSString, "trim-mots" as NSString,
             "%pendant" as NSString, "%répét" as NSString, "%propre" as NSString,
             "ø ms" as NSString, "ms/mot" as NSString))
print(" ─────────────────────────────────────────────────────────────────────")
// Bon cap Long = le plus haut AVANT que la dérive (%répét) n'apparaisse. Seuil
// serré : un seul bigramme répété sur 12 phrases (8 %) est déjà un défaut visible
// à cette longueur — le flag exact-bigram SOUS-compte la dérive sémantique.
let driftThreshold = 5.0
var bestLong = sweep.min() ?? 3
for mw in sweep.sorted() {
    guard let a = aggByMW[mw], a.n > 0 else { continue }
    let n = Double(a.n)
    let hardW = Double(a.words) / n
    let trimW = Double(a.trimWords) / n
    let pctDang = 100.0 * Double(a.trimDangling) / n
    let pctRep = 100.0 * Double(a.trimRepeats) / n
    let pctClean = 100.0 * Double(a.trimClean) / n
    let avgMs = Double(a.ms) / n
    let msPerWord = trimW > 0 ? avgMs / trimW : 0
    if pctRep <= driftThreshold { bestLong = mw }
    print(String(format: " %-6d %-10.1f %-11.1f %-9.0f %-8.0f %-8.0f %-9.0f %-8.1f",
                 mw, hardW, trimW, pctDang, pctRep, pctClean, avgMs, msPerWord))
}
print(" (trim-mots = mots RÉELLEMENT affichés ; %répét = dérive/boucle = borne haute)")

// ── Dump qualitatif au cap max (rendu caret tel qu'affiché) ──
print("\n──────────────────────────────────────────────────────────────────────")
print(" RENDU CARET au cap \(trimCap) + trim  (texte tapé ‹ghost›)")
print("──────────────────────────────────────────────────────────────────────")
for o in cap8Outputs {
    let trimmed = trimBackToCleanStop(o.ghost)
    let shrank = ghostWords(o.ghost).count - ghostWords(trimmed).count
    let tag = shrank > 0 ? "  (−\(shrank))" : ""
    print("  \(o.prefix)‹\(trimmed)›\(tag)")
}

print("\n RECOMMANDATION — cap « Long » :")
print("   → maxWords = \(bestLong)  (plus haut cap AVANT que la dérive %répét ne dépasse \(Int(driftThreshold))%)")
print("   Pas de plateau des mots affichés : le modèle remplit jusqu'au cap.")
print("   Le trim garde %pendant ≈ 0 partout → la propreté de FIN n'est plus le frein.")
print("   Les deux vrais freins : la LATENCE (≈ 18 ms/mot, linéaire) et")
print("   la DÉRIVE (%répét) qui décolle aux caps hauts. Le bon cap est leur compromis.")

// Le backend llama/Metal SIGTRAP parfois au teardown des destructeurs globaux
// (après que tout le travail est fait). On flush puis on coupe court via `_exit`
// pour un code de sortie propre et un stdout intact même en mode pipe.
fflush(stdout)
_exit(0)
