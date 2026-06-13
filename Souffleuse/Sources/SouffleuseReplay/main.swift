import Foundation
import SouffleuseCore
import SouffleuseCorpus  // TypingHistoryEntry — nommé explicitement pour le snapshot JSON + le mode diag
import SouffleuseLlama
import SouffleuseLog
import SouffleusePersonalization
import SouffleuseTyping

// SouffleuseReplay — offline driver for the REAL autocomplete pipeline.
//
// It drives the same pieces the live app uses — `SuggestionPolicyEngine`
// (routeInstant + onLLMChunk), `LlamaPromptBuilder`, the real `LlamaEngine`
// loading the real GGUF, `ChunkFilter`, and the real encrypted typing history
// via `TypingHistoryStore` — over a list of typed-prefix sequences (parsed from
// the live predict debug log, or a hardcoded French fallback). For each tail it
// prints `userTail → ghost [source]`.
//
// FIDELITY NOTE: this mirrors `PredictorViewModel.predict`'s LLM path, NOT the
// cache layers. predictCache / undoCache are deliberately OMITTED (they only
// absorb the "type space → backspace" regen cycle and are irrelevant to a
// single-shot offline replay). Everything else — instant routing, bare prompt,
// sampler config, per-token ChunkFilter + lastEmitted rule, the relevance gate
// — is reproduced from the live code path.

// MARK: - Configuration (mirrors PVM / generateLlama defaults)

let kMaxWords: Int = {       // PVM default completion-length cap (env-overridable for A/B)
    if let s = ProcessInfo.processInfo.environment["SOUFFLEUSE_MAXWORDS"], let n = Int(s) { return n }
    return 6                 // aligné sur le défaut LIVE (PVM maxWords=6), pas 8
}()
let kMaxTokens = 48          // generation cap for the replay
let kGGUFPath = ("~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf" as NSString)
    .expandingTildeInPath

/// Personalization (NgramLogitBias) strength used at inference. Defaults to 0
/// for backward-compat with the historical "replay: no personalization gain"
/// behavior. Set `SOUFFLEUSE_REPLAY_STRENGTH` to a Float to reproduce the
/// live runtime default (1.0) or to A/B the bias effect.
let kPersonalizationStrength: Float = {
    if let s = ProcessInfo.processInfo.environment["SOUFFLEUSE_REPLAY_STRENGTH"],
       let f = Float(s) { return f }
    return 0
}()

/// Repetition-penalty knobs — env-overridable for the Cotypist-parity
/// investigation. Defaults mirror generateLlama PROD (1.3 / 64). Hypothesis:
/// a high penalty over a window that includes the prompt context penalises
/// context-echo ("fiscale" on screen → model avoids "fiscal"). Override:
///   SOUFFLEUSE_REPLAY_REPEAT_PENALTY=1.0 SOUFFLEUSE_REPLAY_REPEAT_LAST_N=0
let kRepeatPenalty: Float = {
    if let s = ProcessInfo.processInfo.environment["SOUFFLEUSE_REPLAY_REPEAT_PENALTY"],
       let f = Float(s) { return f }
    return 1.3
}()
let kRepeatLastN: Int32 = {
    if let s = ProcessInfo.processInfo.environment["SOUFFLEUSE_REPLAY_REPEAT_LAST_N"],
       let n = Int32(s) { return n }
    return 64
}()

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

// ===== BEAM-CORE PATH (SOUFFLEUSE_REPLAY_BEAM=1) ============================
// Quand le flag est posé, la génération LLM du diag passe par le MÊME moteur que
// la prod par défaut (`ModelRuntime.generateGhostBeam` → `BeamGhostEngine`) au
// lieu du greedy `runLLM`. Correctif de représentativité : en prod
// `SuggestionPolicy.Tuning.beamCoreEnabled` est ON, donc TOUT le ghost (frontière
// ET mid-mot) sort du beam ; le greedy est le fallback mort. Mesurer la justesse
// sur le greedy donnait des chiffres non représentatifs.
//
// On reproduit `generateGhostBeam` en mode STATELESS par entrée (pas de réserve /
// session — `ghost(prompt:requiredPrefix:maxWidth:)` frais à chaque appel ; la
// réserve n'est qu'une optim de perf en frappe vivante et ne change pas le ghost
// produit). Mêmes pièces que la prod : `BeamGhostShaper.{sentenceArmed,
// beamConfigChoice,buildPrompt,selectGhost}`, même `beamWidth`, même formule de
// bias. Le moteur EMPRUNTE le modèle déjà chargé dans `LlamaEngine` (poids
// partagés, vocab identique) et reçoit le MÊME corpus train que le greedy.
let kReplayBeam = ProcessInfo.processInfo.environment["SOUFFLEUSE_REPLAY_BEAM"] == "1"

/// `beamWidth` de PROD : `BeamConfig.ghostCore().maxSearchWidth` (défaut 2,
/// env-overridable via `SOUFFLEUSE_BEAM_K`) — exactement ce que `ModelRuntime`
/// passe à `beamConfigChoice`. Lu une fois.
let kBeamWidth = BeamConfig.ghostCore().maxSearchWidth

/// Reproduit `ModelRuntime.generateGhostBeam` pour UNE entrée, sans état (pas de
/// réserve). Renvoie la string ghost FINALE (déjà post-filtrée/sélectionnée comme
/// en prod), ou "" si gaté / silence G2 / boundary non armée.
///
/// Parité prod (generateGhostBeam) :
///   1. bias : `strength × LlamaSampling.personalizationGainScale`, posé via
///      `setBiasStrength` (même formule que la voie greedy).
///   2. garde G2 : `BeamGhostShaper.sentenceArmed(userTail:)` → "" sinon.
///   3. config : `BeamGhostShaper.beamConfigChoice(userTail:, beamWidth: kBeamWidth)`
///      → requiredPrefix / isBoundary / width.
///   4. prompt : `BeamGhostShaper.buildPrompt(customInstr:"", ctxPrefix:, llmTail:)`.
///      Le diag n'a ni persona ni texte après caret → customInstr="" afterCaret=nil.
///   5. génération : `ghost(prompt:requiredPrefix:maxWidth:width)` (stateless).
///   6. sélection/post-filtre : `BeamGhostShaper.selectGhost(...)` sur les
///      candidats (`BeamResult.candidates`, champ `.ghost`), afterCaret=nil —
///      hors mid-line, post-filtre du seul best, byte-identique à la prod.
func runBeam(
    beam: BeamGhostEngine,
    userTail: String,
    customInstr: String = "",
    ctxPrefix: String = "",
    personalizationStrength: Float
) async -> String {
    // (1) bias — même formule que generateGhostBeam (perso × gain scale).
    await beam.setBiasStrength(personalizationStrength * LlamaSampling.personalizationGainScale)

    // (2) G2 : reprise après le point.
    guard BeamGhostShaper.sentenceArmed(userTail: userTail) else { return "" }

    // (3) config beam (mid-mot → requiredPrefix + K plein ; frontière → K=1).
    let choice = BeamGhostShaper.beamConfigChoice(userTail: userTail, beamWidth: kBeamWidth)

    // (4) prompt — slots prose, comme la prod. `customInstr` = le persona réel de
    // l'app (monté en tête « Contexte : … » par buildPrompt) — c'est le slot
    // qui ancre le modèle en français et que le diag laissait à vide. `ctxPrefix`
    // (app/window/OCR) reste "" en mode diag held-out : c'est du contexte
    // DYNAMIQUE (focus courant) hors-périmètre de ce replay offline.
    let prompt = BeamGhostShaper.buildPrompt(
        customInstr: customInstr, ctxPrefix: ctxPrefix, llmTail: userTail)

    if ProcessInfo.processInfo.environment["DUMP_PROMPT"] != nil {
        err("=== BEAM PROMPT for \(userTail.debugDescription) (K=\(choice.width) req=\(choice.requiredPrefix.debugDescription)) ===\n\(prompt)\n=== END PROMPT ===")
    }

    // (5) génération stateless (pas de réserve — fresh ghost par entrée).
    let result = await beam.ghost(prompt: prompt,
                                  requiredPrefix: choice.requiredPrefix,
                                  maxWidth: choice.width)

    // (6) sélection + post-filtre — verbatim generateGhostBeam. caretAfterSpace
    // dérivé du tail ; afterCaret nil (le diag n'a pas de texte après curseur).
    let caretAfterSpace = userTail.last == " " || userTail.last == "\t"
    let rawCandidates = result.candidates.isEmpty
        ? [result.best?.ghost ?? ""]
        : result.candidates.map(\.ghost)
    let ghost = BeamGhostShaper.selectGhost(
        rawCandidates: rawCandidates, isBoundary: choice.isBoundary,
        caretAfterSpace: caretAfterSpace, userTail: userTail,
        maxWords: kMaxWords, afterCaret: nil)

    if ProcessInfo.processInfo.environment["DUMP_RAW"] != nil {
        err("BEAM RAW for \(userTail.debugDescription): best=\((result.best?.ghost ?? "").debugDescription) → selected=\(ghost.debugDescription)")
    }
    return ghost
}

/// Best ghost BRUT (pré-post-filtre) du beam — pour le diagnostic
/// d'over-suppression (le pendant beam de « le greedy renvoie raw quand le gate
/// vide tout »). Même prompt/config/bias que `runBeam`, mais retourne
/// `result.best.ghost` sans selectGhost. "" si G2 silence ou aucun candidat.
func beamBestRaw(beam: BeamGhostEngine, userTail: String, strength: Float) async -> String {
    await beam.setBiasStrength(strength * LlamaSampling.personalizationGainScale)
    guard BeamGhostShaper.sentenceArmed(userTail: userTail) else { return "" }
    let choice = BeamGhostShaper.beamConfigChoice(userTail: userTail, beamWidth: kBeamWidth)
    let prompt = BeamGhostShaper.buildPrompt(customInstr: "", ctxPrefix: "", llmTail: userTail)
    let result = await beam.ghost(prompt: prompt, requiredPrefix: choice.requiredPrefix, maxWidth: choice.width)
    return result.best?.ghost ?? ""
}
// ===== END BEAM-CORE PATH ==================================================

// MARK: - JSON scenario schema

/// Minimal scenario shape for JSON-driven replay. Mirrors the relevant fields
/// of `SouffleuseCoherence`'s schema but kept local so SouffleuseReplay doesn't
/// take a new module dependency. The cascade still consults the real
/// TypingHistoryStore (Keychain-backed) for L0/L1 routing — only the LLM
/// prompt's context prefix is injected from JSON.
struct Scenario: Decodable {
    let id: String
    let label: String?
    let app: String?
    let windowTitle: String?
    let visibleText: String?
    let userTail: String
}

struct ScenarioFile: Decodable {
    let version: Int
    let scenarios: [Scenario]
}

/// Reproduces the relevant subset of `EnrichedContext.prefix` (compact prose,
/// no `[Label:]` syntax) so the model receives the same shape it would in the
/// running app, without taking a SouffleuseContext dependency.
func buildCtxPrefix(_ s: Scenario) -> String {
    var bits: [String] = []
    if let app = s.app, !app.isEmpty {
        if let title = s.windowTitle, !title.isEmpty {
            bits.append("App \(app), window \"\(title)\".")
        } else {
            bits.append("App \(app).")
        }
    }
    if let v = s.visibleText, !v.isEmpty {
        bits.append("On screen: \(v).")
    }
    return bits.joined(separator: " ")
}

func loadScenarios(_ path: String) -> [Scenario]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    do {
        let file = try JSONDecoder().decode(ScenarioFile.self, from: data)
        return file.scenarios
    } catch {
        err("FATAL: could not decode scenarios JSON at \(path): \(error)")
        return nil
    }
}

// MARK: - Typed-prefix corpus

/// Hardcoded French fallback prefixes when the predict log is missing.
let fallbackTails: [String] = [
    "Bonjour, je vous écris pour ",
    "Merci beaucoup pour votre ",
    "Je reviens vers vous concernant ",
    "Coucou, ceci est un test et je ",
    "Aujourd'hui je voudrais ",
    "Pourriez-vous me confirmer ",
    "Je suis désolé pour le ",
    "N'hésitez pas à me ",
]

/// Unescapes a `debugDescription`-style quoted body (`\"`, `\n`, `\t`, `\\`, `\'`).
func unescapeDebug(_ s: String) -> String {
    var out = ""
    var it = s.makeIterator()
    var pending: Character? = nil
    func next() -> Character? {
        if let p = pending { pending = nil; return p }
        return it.next()
    }
    while let c = next() {
        if c == "\\" {
            guard let n = next() else { out.append(c); break }
            switch n {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "\"": out.append("\"")
            case "'": out.append("'")
            case "\\": out.append("\\")
            default: out.append(n)
            }
        } else {
            out.append(c)
        }
    }
    return out
}

/// Parses `predict_called userTail="..."` lines from the live predict debug
/// log into a distinct, order-preserving list of userTails (capped ~150).
func parsePredictLog(_ path: String) -> [String] {
    guard let data = FileManager.default.contents(atPath: path),
          let text = String(data: data, encoding: .utf8) else { return [] }
    var seen = Set<String>()
    var tails: [String] = []
    for line in text.split(whereSeparator: { $0 == "\n" }) {
        guard let r = line.range(of: "userTail=\"") else { continue }
        let afterOpen = line[r.upperBound...]
        // Find the closing unescaped quote.
        var body = ""
        var idx = afterOpen.startIndex
        var escaped = false
        while idx < afterOpen.endIndex {
            let ch = afterOpen[idx]
            if escaped {
                body.append("\\"); body.append(ch); escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                break
            } else {
                body.append(ch)
            }
            idx = afterOpen.index(after: idx)
        }
        let tail = unescapeDebug(body)
        if tail.trimmingCharacters(in: .whitespaces).count >= 3, !seen.contains(tail) {
            seen.insert(tail)
            tails.append(tail)
            if tails.count >= 150 { break }
        }
    }
    return tails
}

// MARK: - Pipeline mirror

/// Reproduces `generateLlama`'s caret derivation + sampler config, runs the
/// engine, and applies `ChunkFilter` per token with the same `lastEmitted`
/// "emit only when changed" rule to produce the final one-line LLM ghost.
func runLLM(
    engine: LlamaEngine,
    userTail: String,
    customInstr: String = "",   // persona réel (parité A/B avec le beam) — slot « Contexte : … »
    ctxPrefix: String = "",
    personalizationStrength: Float = kPersonalizationStrength  // diag passe 1.0/env
) async -> String {
    // `customInstr` = le persona réel de l'app (par défaut "" hors diag, pour les
    // hooks FORCE_LLM/EXPMID qui sondent le prompt nu). En diag il reçoit le MÊME
    // persona que le beam → parité de tête de prompt entre les deux moteurs. JSON
    // mode injects `ctxPrefix` so the model sees the same "App X, window Y"
    // shape it would in the live app. `ctxPrefix` (app/window/OCR) reste dynamique
    // et hors-périmètre du diag offline. `beforeCursor` = userTail.
    let prompt = LlamaPromptBuilder.buildLlamaPrompt(
        system: "",
        customInstr: customInstr,
        ctxPrefix: ctxPrefix,
        fieldContext: "",
        afterCursor: "",
        beforeCursor: userTail
    )
    if ProcessInfo.processInfo.environment["DUMP_PROMPT"] != nil {
        err("=== PROMPT for \(userTail.debugDescription) (rp=\(kRepeatPenalty) rln=\(kRepeatLastN)) ===\n\(prompt)\n=== END PROMPT ===")
    }
    // Caret derivation — verbatim from generateLlama.
    let caretAfterSpace = userTail.last == " " || userTail.last == "\t"
    let caretMidWord = userTail.last.map { $0.isLetter || $0.isNumber } ?? false
    let minFirstTokenProb: Float = caretMidWord ? LlamaPromptBuilder.midWordMinFirstTokenProb : 0

    // TOKEN HEALING — mirrors production `generateLlama` exactly: mid-word, drop
    // the trailing partial-word token(s) from the prompt and re-derive the merged
    // token at a clean boundary (see LlamaSampling.healPrefix). Gated on the same
    // `Tuning.midWordHealingEnabled` flag the app uses, so the replay's LLM path
    // is faithful to what the live app generates. `NOHEAL=1` forces it off to
    // reproduce the pre-V2 garbage baseline for A/B measurement.
    let healPrefix: String? = (SuggestionPolicy.Tuning.midWordHealingEnabled
                               && ProcessInfo.processInfo.environment["NOHEAL"] == nil
                               && caretMidWord)
        ? OutputFilter.trailingPartialWord(userTail)
        : nil

    // Mutable accumulator + lastEmitted tracker — the caller-side state that
    // ChunkFilter intentionally does NOT own (preserves the live emit sequence).
    final class Acc: @unchecked Sendable {
        var generated = ""
        var lastEmitted = ""
    }
    let acc = Acc()

    _ = await engine.generate(
        prompt: prompt,
        maxTokens: kMaxTokens,
        sampling: LlamaSampling(
            temperature: 0,
            repeatPenalty: kRepeatPenalty,
            repeatLastN: kRepeatLastN,
            personalizationStrength: personalizationStrength,  // env-overridable; default 0 (diag: 1.0)
            banMarkup: true,
            banDigitsLeading: true,
            banEmoji: true,
            minFirstTokenProb: minFirstTokenProb,
            healPrefix: healPrefix
        )
    ) { piece in
        acc.generated += piece
        let (verdict, _, sentenceComplete, reachedWordCap) = ChunkFilter.filterChunk(
            accumulated: acc.generated,
            userTail: userTail,
            caretAfterSpace: caretAfterSpace,
            maxWords: kMaxWords
        )
        switch verdict {
        case .reset:
            // ghost_dropped_repeat → live emits onChunk(""); here just stop.
            return true
        case .dropKeepGenerating:
            if !acc.lastEmitted.isEmpty { acc.lastEmitted = "" }
            return true
        case .emit(let oneLine):
            if oneLine != acc.lastEmitted { acc.lastEmitted = oneLine }
            // Mirror the live path: stop at a completed sentence OR once the
            // complete-word budget is full (never mid-word).
            return !sentenceComplete && !reachedWordCap
        }
    }
    if ProcessInfo.processInfo.environment["DUMP_RAW"] != nil {
        err("RAW gen for \(userTail.debugDescription): generated=\(acc.generated.debugDescription) → emitted=\(acc.lastEmitted.debugDescription)")
    }
    return acc.lastEmitted
}

// MARK: - Entry source (store vs snapshot)

/// Charge les entrées d'historique soit depuis un snapshot JSON local
/// (`SOUFFLEUSE_CORPUS_SNAPSHOT`), soit depuis le vrai store chiffré (Keychain).
///
/// Le snapshot existe pour itérer sans rouvrir le Keychain à chaque run :
/// l'utilisateur exporte une fois (`SOUFFLEUSE_EXPORT_SNAPSHOT`) puis travaille
/// sur le fichier. Quand le snapshot est fourni, on ne touche JAMAIS le store —
/// donc aucun accès Keychain, conformément à l'invariant de privacy.
func loadEntries() async -> [TypingHistoryEntry] {
    let envns = ProcessInfo.processInfo.environment
    if let snapPath = envns["SOUFFLEUSE_CORPUS_SNAPSHOT"], !snapPath.isEmpty {
        guard let data = FileManager.default.contents(atPath: snapPath) else {
            err("FATAL: SOUFFLEUSE_CORPUS_SNAPSHOT introuvable à \(snapPath)")
            exit(1)
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601  // symétrique de l'export
            let decoded = try decoder.decode([TypingHistoryEntry].self, from: data)
            err("[snapshot] loaded \(decoded.count) entries (no keychain)")
            return decoded
        } catch {
            err("FATAL: décodage du snapshot échoué (\(snapPath)): \(error)")
            exit(1)
        }
    }
    // Voie normale — vrai historique chiffré (seul accès Keychain).
    let store = TypingHistoryStore()
    let loaded = await store.allEntries()

    // Export one-shot : c'est l'UNIQUE accès Keychain attendu de ce run. On
    // sérialise puis on sort, l'utilisateur itère ensuite via le snapshot.
    if let outPath = envns["SOUFFLEUSE_EXPORT_SNAPSHOT"], !outPath.isEmpty {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(loaded)
            try data.write(to: URL(fileURLWithPath: outPath))
            err("[snapshot] exported \(loaded.count) entries to \(outPath)")
        } catch {
            err("FATAL: écriture du snapshot échouée (\(outPath)): \(error)")
            exit(1)
        }
        exit(0)
    }
    return loaded
}

// MARK: - Diagnostic (qualité held-out sur la vraie historique)

/// Normalise un texte pour comparaison casse/accents-insensible (NFD puis
/// suppression des diacritiques, minuscules). Utilisé pour le test de préfixe.
func foldDiacritics(_ s: String) -> String {
    s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
}

/// Extrait le premier « run de mots » : la séquence initiale de caractères-mots
/// (lettres, `'`, `-`), en sautant les espaces de tête. Sert de cible/comparaison
/// principale (le 1er mot prime). Renvoie "" si rien d'alphabétique.
func firstWordRun(_ s: String) -> String {
    func isWord(_ c: Character) -> Bool { c.isLetter || c == "'" || c == "-" }
    var out = ""
    var started = false
    for c in s {
        if isWord(c) { out.append(c); started = true }
        else if started { break }
        else if c == " " || c == "\t" || c == "\n" { continue }
        else { break }  // ponctuation/chiffre en tête → pas de run de mots
    }
    return out
}

/// CORRECT si le 1er run de mots du ghost préfixe celui de la vérité (ou
/// l'inverse), insensible casse/accents. Capture « fis » → « fiscal » comme
/// l'utilisateur le vivrait (continuation valide).
func ghostMatchesTruth(ghost: String, truth: String) -> Bool {
    let g = foldDiacritics(firstWordRun(ghost))
    let t = foldDiacritics(firstWordRun(truth))
    guard !g.isEmpty, !t.isEmpty else { return false }
    return g.hasPrefix(t) || t.hasPrefix(g)
}

/// Catégorise un ghost FAUX (heuristiques, plusieurs tags possibles) pour savoir
/// quel levier tirer. `prefix`=contextBefore, `truth`=accepted, `gated`=ghost
/// vidé par le gate.
func failureTags(prefix: String, ghost: String, truth: String, gated: Bool) -> [String] {
    var tags: [String] = []
    let g = ghost.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)

    // vide/gaté — rien à afficher (le gate a supprimé ou le modèle n'a rien sorti).
    if g.isEmpty || gated {
        tags.append("vide/gaté")
    } else if g.count <= 2 {
        tags.append("tronqué")
    }

    // début-de-phrase — contexte vide ou se terminant par . ! ? (pas de continuation
    // de mot, la perso a peu de signal).
    if trimmedPrefix.isEmpty || (trimmedPrefix.last.map { ".!?".contains($0) } ?? false) {
        tags.append("début-de-phrase")
    }

    // nom-propre-attendu — la vérité démarre par une majuscule en milieu de phrase
    // (le contexte ne finit pas par une ponctuation de fin).
    if let tf = truth.trimmingCharacters(in: .whitespaces).first, tf.isUppercase,
       !trimmedPrefix.isEmpty, !(trimmedPrefix.last.map { ".!?".contains($0) } ?? false) {
        tags.append("nom-propre-attendu")
    }

    if !g.isEmpty {
        // chiffre/montant — un chiffre collé à €/$/% dans le ghost.
        let chars = Array(g)
        for (i, c) in chars.enumerated() where c.isNumber {
            let prev = i > 0 ? chars[i - 1] : " "
            let nextC = i + 1 < chars.count ? chars[i + 1] : " "
            if "€$%".contains(prev) || "€$%".contains(nextC) { tags.append("chiffre/montant"); break }
        }
        // markup — résidu de balisage que le base model imite parfois.
        if g.contains("<") || g.contains(">") || g.contains("**") || g.contains("_") {
            tags.append("markup")
        }
        // hors-sujet — aucun mot du ghost partagé avec la vérité.
        let truthWords = Set(foldDiacritics(truth)
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init).filter { $0.count >= 2 })
        let ghostWords = foldDiacritics(g)
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init).filter { $0.count >= 2 }
        let shared = ghostWords.contains { truthWords.contains($0) }
        if !shared, !ghostWords.isEmpty { tags.append("hors-sujet") }

        // bon-mais-différent — mot français plausible (alpha, ≥3 lettres) qui n'est
        // tombé dans AUCUNE autre catégorie d'échec. Distingue « valide mais pas la
        // vérité littérale » de « mauvais » → sous-estime la vraie qualité.
        let alphaOnly = g.allSatisfy { $0.isLetter || $0 == "'" || $0 == "-" || $0 == " " }
        let firstRun = firstWordRun(g)
        if tags.isEmpty, alphaOnly, firstRun.count >= 3 {
            tags.append("bon-mais-différent")
        }
    }

    if tags.isEmpty { tags.append("autre") }
    return tags
}

/// Génère le ghost pour une entrée de test via le MÊME chemin que le replay
/// normal : instant d'abord, LLM en repli. Renvoie (ghost, source, gated).
/// `gated` = le LLM a produit du texte mais `onLLMChunk` l'a rejeté (gate).
func diagGenerate(
    engine: LlamaEngine,
    beam: BeamGhostEngine?,   // non-nil ssi SOUFFLEUSE_REPLAY_BEAM=1 → voie prod
    prefix: String,
    train: [TypingHistoryEntry],
    wordCompleter: WordCompleter,
    maxWords: Int,
    strength: Float,
    persona: String   // customInstr réel (persona de l'app), monté en tête « Contexte : … »
) async -> (ghost: String, source: String, gated: Bool) {
    // Stage 1 — instant (corpus recall / word-complete / history).
    let instant: GhostUpdate? = await MainActor.run {
        SuggestionPolicyEngine(maxWords: maxWords)
            .routeInstant(userTail: prefix, historySnapshot: train, wordCompleter: wordCompleter)
    }
    if let route = instant, !route.text.isEmpty {
        return (route.text, "instant:" + sourceLabel(route.source), false)
    }
    // Stage 2 — BEAM CORE (SOUFFLEUSE_REPLAY_BEAM=1) : voie de génération PAR DÉFAUT
    // de la prod. `runBeam` reproduit `generateGhostBeam` stateless ; il applique
    // DÉJÀ le gate du chemin beam (G2 + selectGhost/beamPostFilter), donc sa sortie
    // EST le ghost final — pas de `onLLMChunk` ensuite (le beam ne passe pas par lui
    // en prod). `gated` = le beam a produit un best mais le post-filtre l'a vidé.
    if let beam = beam {
        let ghost = await runBeam(beam: beam, userTail: prefix, customInstr: persona, ctxPrefix: "",
                                  personalizationStrength: strength)
        if !ghost.isEmpty {
            return (ghost, "beam", false)
        }
        // Best non-vide mais post-filtre/G2 l'a tué → cas « gaté » (sur-suppression).
        // On régénère le best brut pour le diagnostic d'over-suppression, comme la
        // voie greedy renvoie `raw` quand le gate vide tout.
        let bestRaw = await beamBestRaw(beam: beam, userTail: prefix, strength: strength)
        if !bestRaw.isEmpty { return (bestRaw, "beam", true) }
        return ("", "beam", false)  // beam silencieux — pas un cas « gaté »
    }
    // Stage 2 (fallback A/B) — LLM greedy (profil prod historique : temp 0, bans
    // markup/digits/emoji, strength = SOUFFLEUSE_REPLAY_STRENGTH ou 1.0).
    let raw = await runLLM(engine: engine, userTail: prefix, customInstr: persona, ctxPrefix: "", personalizationStrength: strength)
    if raw.isEmpty {
        return ("", "llm", false)  // modèle silencieux — pas un cas « gaté »
    }
    let update: GhostUpdate? = await MainActor.run {
        SuggestionPolicyEngine(maxWords: maxWords).onLLMChunk(raw, userTail: prefix)
    }
    if let u = update, !u.text.isEmpty {
        return (u.text, "llm", false)
    }
    // Le LLM a produit du texte mais le gate l'a tué → sur-suppression potentielle.
    return (raw, "llm", true)
}

/// Mode diagnostic complet : split 80/20, perso held-out, génération via le vrai
/// chemin, catégorisation des échecs, agrégats sur stdout.
func runDiagnostic(engine: LlamaEngine, entries: [TypingHistoryEntry]) async {
    let envns = ProcessInfo.processInfo.environment

    // FIDÉLITÉ PROMPT — la prod (BeamGhostShaper.buildPrompt / LlamaPromptBuilder)
    // injecte DEUX slots non-vides que le diag laissait à vide : le persona
    // (customInstr, monté en tête « Contexte : … ») et la strength réelle. Sans
    // eux, le diag produit du charabia que la prod ne produit pas
    // (« nous calc » → diag « calcool » vs app « calculons le nombre »).
    //
    // Les valeurs RÉELLES vivent dans le domaine UserDefaults de l'APP
    // (`app.cocotypist.Souffleuse`), PAS le domaine standard du diag. Lecture
    // sans mot de passe via le suite name.
    let appDefaults = UserDefaults(suiteName: "app.cocotypist.Souffleuse")
    let appPersona = appDefaults?.string(forKey: "customAIInstructions")
    // `personalizationStrength` est stocké en STRING par l'app (ex. "1.5802…").
    let appStrength: Float? = appDefaults?.string(forKey: "personalizationStrength").flatMap { Float($0) }
    let persoEnabled = appDefaults?.bool(forKey: "personalizedSuggestionsEnabled") ?? false

    // strength : env override (comportement existant) > valeur réelle de l'app > 1.0.
    let diagStrength: Float = {
        if let s = envns["SOUFFLEUSE_REPLAY_STRENGTH"], let f = Float(s) { return f }
        return appStrength ?? 1.0
    }()

    // persona : env override > customAIInstructions de l'app > "". Escape hatch :
    // SOUFFLEUSE_REPLAY_NOPERSONA=1 force "" pour reproduire l'ancien prompt nu (A/B).
    let persona: String = {
        if envns["SOUFFLEUSE_REPLAY_NOPERSONA"] == "1" { return "" }
        if let p = envns["SOUFFLEUSE_REPLAY_PERSONA"] { return p }
        return appPersona ?? ""
    }()

    // Log sur err uniquement — JAMAIS le texte du persona sur stdout (dev-only,
    // mais on garde l'invariant : seul le COMPTE de chars sort, pas la prose).
    err("[diag] persona injecté (\(persona.count) chars), strength=\(String(format: "%.2f", diagStrength)), persoEnabled=\(persoEnabled)")

    // Split déterministe 80/20 : index % 5 == 0 → test, sinon train.
    // FULLCORPUS (SOUFFLEUSE_REPLAY_FULLCORPUS=1) : le bias/recall voit TOUT le
    // corpus (comme l'app LIVE), pas seulement 80%. Held-out mesure la
    // GÉNÉRALISATION (texte inédit) ; full-corpus mesure le VÉCU prod (l'app
    // rappelle/biaise depuis l'historique COMPLET, y compris ce que tu viens de
    // taper). En full-corpus, un cas test présent dans l'historique fait un
    // rappel instant comme en prod — c'est voulu (fidélité au vécu).
    let fullCorpus = ProcessInfo.processInfo.environment["SOUFFLEUSE_REPLAY_FULLCORPUS"] == "1"
    var train: [TypingHistoryEntry] = []
    var test: [TypingHistoryEntry] = []
    for (i, e) in entries.enumerated() {
        if i % 5 == 0 { test.append(e) } else { train.append(e) }
    }
    if fullCorpus { train = entries }   // bias/recall = historique complet (parité LIVE)
    err("[diag] entries=\(entries.count) train=\(train.count) test=\(test.count) fullCorpus=\(fullCorpus)")

    // Held-out : la perso ne voit que le train. Full-corpus : elle voit tout.
    let trainCorpus = train.map { $0.contextBefore.isEmpty ? $0.accepted : $0.contextBefore + " " + $0.accepted }
    await engine.setCorpus(trainCorpus)

    // BEAM CORE (SOUFFLEUSE_REPLAY_BEAM=1) : charge le moteur prod en EMPRUNTANT le
    // modèle déjà résident dans `engine` (poids partagés, vocab identique → ids de
    // corpus identiques) et lui pose le MÊME corpus train. Config = `ghostCore()`
    // (le profil que `ModelRuntime` charge en prod : K=2 env-aware). nil si le flag
    // est absent → `diagGenerate` reste sur la voie greedy.
    var beam: BeamGhostEngine? = nil
    if kReplayBeam {
        let b = BeamGhostEngine(config: .ghostCore())
        var loaded = false
        if let borrowed = await engine.borrowModel() {
            loaded = await b.load(borrowedModel: borrowed, contextTokens: 2048)
        }
        if !loaded {
            // Repli : charge le modèle depuis le même fichier que le greedy.
            loaded = await b.load(modelPath: kGGUFPath, contextTokens: 2048)
        }
        guard loaded else {
            err("FATAL: SOUFFLEUSE_REPLAY_BEAM=1 mais le BeamGhostEngine n'a pas chargé.")
            exit(1)
        }
        await b.setCorpus(trainCorpus)
        beam = b
        err("[diag] BEAM CORE actif (K=\(kBeamWidth), config ghostCore).")
    }

    let wordCompleter = WordCompleter()
    let showExamples = ProcessInfo.processInfo.environment["SOUFFLEUSE_SHOW_EXAMPLES"] == "1"

    var nTested = 0
    var nCorrect = 0
    // Justesse par source : (corrects, total).
    var bySource: [String: (correct: Int, total: Int)] = [:]
    // Comptes de catégories d'échec.
    var failCats: [String: Int] = [:]
    var nFalse = 0
    var nGoodButDifferent = 0
    var nGated = 0
    var nGatedWouldBeCorrect = 0
    // Exemples (collectés seulement si demandés) : prefix tronqué | ghost | truth | cat.
    var examples: [(String, String, String, String)] = []
    // Dump COMPLET (SOUFFLEUSE_REPLAY_DUMP=/path) : chaque cas test, pour un juge
    // d'INTENTION externe (cohérence ≠ match exact). Dev-only, texte brut local,
    // jamais committé — même périmètre que SHOW_EXAMPLES.
    let dumpPath = ProcessInfo.processInfo.environment["SOUFFLEUSE_REPLAY_DUMP"]
    var dumpRows: [[String: Any]] = []

    for e in test {
        let prefix = e.contextBefore
        let truth = e.accepted
        guard !prefix.isEmpty, !truth.isEmpty else { continue }
        nTested += 1

        let (ghost, source, gated) = await diagGenerate(
            engine: engine, beam: beam, prefix: prefix, train: train,
            wordCompleter: wordCompleter, maxWords: kMaxWords, strength: diagStrength,
            persona: persona
        )

        let correct = ghostMatchesTruth(ghost: ghost, truth: truth)
        if correct { nCorrect += 1 }

        var srcStat = bySource[source] ?? (0, 0)
        srcStat.total += 1
        if correct { srcStat.correct += 1 }
        bySource[source] = srcStat

        if dumpPath != nil {
            dumpRows.append([
                "prefix": prefix,
                "ghost": ghost,
                "truth": truth,
                "source": source,
                "exact": correct,
                "gated": gated,
            ])
        }

        if gated {
            nGated += 1
            // Sur-suppression : le ghost brut (avant gate) aurait-il été correct ?
            if correct { nGatedWouldBeCorrect += 1 }
        }

        if !correct {
            nFalse += 1
            let tags = failureTags(prefix: prefix, ghost: ghost, truth: truth, gated: gated)
            for t in tags { failCats[t, default: 0] += 1 }
            if tags.contains("bon-mais-différent") { nGoodButDifferent += 1 }
            if showExamples, examples.count < 15 {
                let shortPrefix = String(prefix.suffix(40))
                examples.append((shortPrefix, ghost, truth, tags.joined(separator: ",")))
            }
        }
    }

    // SORTIE — agrégats uniquement (aucun texte utilisateur sauf SHOW_EXAMPLES).
    let pct = nTested == 0 ? 0 : nCorrect * 100 / nTested
    print("=== DIAG (held-out 80/20) ===")
    print("n_test=\(nTested) corrects=\(nCorrect) pertinence_globale=\(pct)%")

    print("--- par SOURCE (corrects/total, taux) ---")
    for (src, stat) in bySource.sorted(by: { $0.value.total > $1.value.total }) {
        let rate = stat.total == 0 ? 0 : stat.correct * 100 / stat.total
        print("\(src): \(stat.correct)/\(stat.total) (\(rate)%)")
    }

    print("--- catégories d'ÉCHEC (count, triées) ---")
    for (cat, count) in failCats.sorted(by: { $0.value > $1.value }) {
        print("\(cat): \(count)")
    }

    let goodPct = nFalse == 0 ? 0 : nGoodButDifferent * 100 / nFalse
    print("bon-mais-différent parmi les faux: \(nGoodButDifferent)/\(nFalse) (\(goodPct)%) = sous-estimation de la vraie qualité")
    print("ghosts gatés: \(nGated) — dont AURAIENT été corrects (sur-suppression): \(nGatedWouldBeCorrect)")

    if let dumpPath, let data = try? JSONSerialization.data(withJSONObject: dumpRows, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: dumpPath))
        err("[diag] dump écrit: \(dumpPath) (\(dumpRows.count) cas)")
    }

    if showExamples {
        print("--- exemples (prefix…|ghost|truth|catégorie) ---")
        for (p, g, t, c) in examples {
            print("…\(p) | \(g) | \(t) | \(c)")
        }
    }
    print("=============================")
}

// MARK: - Audit garde mid-mot (catch vs faux positifs)

/// Rejoue la garde de cohérence mid-mot RETIRÉE (2026-05-27) —
/// `OutputFilter.midWordCandidate` + `TypoDetector.isValidWord` — sur un dump
/// de cas beam (SOUFFLEUSE_REPLAY_DUMP). Compte les ghosts qu'elle DROPPERAIT
/// (fusion `partiel+tête` invalide fr+en) et les liste pour classer catch
/// (non-mots) vs faux positif (bon ghost, ex. jargon/nom propre). Pas de modèle
/// requis. Dev-only, texte brut local.
func runMidwordAudit(dumpPath: String) {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: dumpPath)),
          let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
        err("FATAL: dump illisible: \(dumpPath)"); exit(1)
    }
    let typo = TypoDetector()
    var nGhost = 0, nMidword = 0
    var drops: [(p: String, g: String, t: String, cand: String)] = []
    for r in rows {
        let prefix = (r["prefix"] as? String) ?? ""
        let ghost = (r["ghost"] as? String) ?? ""
        guard !ghost.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
        nGhost += 1
        guard let candidate = OutputFilter.midWordCandidate(userTail: prefix, ghost: ghost) else { continue }
        nMidword += 1
        if !typo.isValidWord(candidate, language: nil) {
            drops.append((prefix, ghost, (r["truth"] as? String) ?? "", candidate))
        }
    }
    print("=== AUDIT GARDE MID-MOT (midWordCandidate + isValidWord fr+en) ===")
    print("cas avec ghost non-vide : \(nGhost)")
    print("cas mid-mot (candidate non-nil) : \(nMidword)")
    print("WOULD-DROP (fusion invalide) : \(drops.count)")
    print("--- cas droppés (…prefix | ghost | truth | =fusion) ---")
    for d in drops {
        print("…\(String(d.p.suffix(30))) | \(d.g) | \(String(d.t.prefix(20))) | =\(d.cand)")
    }
    print("=============================")
}

// MARK: - Main

func main() async {
    // Audit garde mid-mot (SOUFFLEUSE_MIDWORD_AUDIT=/path/dump.json) — sort avant
    // tout chargement de modèle (pure analyse du dump).
    if let auditPath = ProcessInfo.processInfo.environment["SOUFFLEUSE_MIDWORD_AUDIT"] {
        runMidwordAudit(dumpPath: auditPath)
        exit(0)
    }

    // 1. Load the real GGUF into the real engine.
    let engine = LlamaEngine()
    let ok = await engine.load(modelPath: kGGUFPath, contextTokens: 2048)
    guard ok else {
        err("FATAL: could not load GGUF at \(kGGUFPath)")
        exit(1)
    }

    // 2. Real encrypted typing history (Keychain + history.db). Warn + continue
    //    empty on failure — privacy invariant: only TypingHistoryStore touches
    //    the db. `loadEntries()` choisit snapshot (sans Keychain) vs store, et
    //    gère l'export one-shot (exit après écriture).
    let entries = await loadEntries()

    // 2.bis DIAGNOSTIC — mesure de qualité held-out sur la VRAIE historique.
    //   Split 80/20 déterministe, perso entraînée sur le train seul, vérité =
    //   ce que l'utilisateur a réellement écrit. Sort après le rapport (n'entre
    //   jamais dans le replay normal).
    if ProcessInfo.processInfo.environment["SOUFFLEUSE_REPLAY_DIAG"] == "1" {
        await runDiagnostic(engine: engine, entries: entries)
        exit(0)
    }

    if entries.isEmpty {
        err("WARN: typing history is empty (or failed to decrypt) — continuing with no corpus.")
    } else {
        err("INFO: loaded \(entries.count) typing-history entries.")
        await engine.setCorpus(entries.map { $0.contextBefore.isEmpty ? $0.accepted : $0.contextBefore + " " + $0.accepted })

        // Corpus quality stats — aggregates only, no stored prose printed.
        // Gated so it never interferes with a normal replay run.
        if ProcessInfo.processInfo.environment["SOUFFLEUSE_CORPUS_STATS"]?.isEmpty == false {
            let total = entries.count
            // Exact-duplicate ratio over (contextBefore, accepted).
            var seen = Set<String>()
            var dupCount = 0
            var freq: [String: Int] = [:]
            for e in entries {
                let key = e.contextBefore + "\u{0}" + e.accepted
                if seen.contains(key) { dupCount += 1 } else { seen.insert(key) }
                freq[key, default: 0] += 1
            }
            let unique = seen.count
            // Accepted length histogram.
            var buckets = [0, 0, 0, 0, 0]  // 3-5, 6-10, 11-20, 21-50, 51+
            for e in entries {
                switch e.accepted.count {
                case ..<6: buckets[0] += 1
                case ..<11: buckets[1] += 1
                case ..<21: buckets[2] += 1
                case ..<51: buckets[3] += 1
                default: buckets[4] += 1
                }
            }
            // mid_word flag distribution.
            var midNil = 0, midTrue = 0, midFalse = 0
            for e in entries {
                switch e.midWordContinuation {
                case nil: midNil += 1
                case .some(true): midTrue += 1
                case .some(false): midFalse += 1
                }
            }
            // Mid-word-glue candidate population (contextBefore ends word-char AND
            // accepted starts word-char) — the class joinHistory must reason about.
            func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "-" }
            let glueCandidates = entries.filter {
                if let cb = $0.contextBefore.last, let af = $0.accepted.first { return isWord(cb) && isWord(af) }
                return false
            }.count
            // Lone-consonant fragment residue ("s de…").
            let fragResidue = entries.filter {
                let t = $0.accepted.trimmingCharacters(in: .whitespacesAndNewlines)
                let cs = Array(t)
                guard cs.count >= 2, cs[0].isLetter, cs[1] == " " else { return false }
                return !"aàyôoAÀYÔO".contains(cs[0])
            }.count
            let topRepeat = freq.values.max() ?? 0
            err("=== CORPUS STATS ===")
            err("total=\(total) unique=\(unique) duplicates=\(dupCount) (\(total == 0 ? 0 : dupCount * 100 / total)%)")
            err("accepted_len 3-5=\(buckets[0]) 6-10=\(buckets[1]) 11-20=\(buckets[2]) 21-50=\(buckets[3]) 51+=\(buckets[4])")
            err("mid_word flag: nil(legacy)=\(midNil) true=\(midTrue) false=\(midFalse)")
            err("mid_word_glue_candidates=\(glueCandidates) lone_consonant_fragments=\(fragResidue)")
            err("most_repeated_pair_count=\(topRepeat)")
            err("====================")
        }
    }

    // 3. Build the replay items — either from a JSON scenarios file (rich:
    //    per-scenario id + ctxPrefix) or from the predict log / fallback (plain
    //    tails with empty ctxPrefix, preserving the historical behavior).
    struct ReplayItem {
        let id: String?
        let userTail: String
        let ctxPrefix: String
    }

    let args = CommandLine.arguments
    var items: [ReplayItem] = []
    var jsonMode = false

    if args.count >= 2, args[1].hasSuffix(".json") {
        guard let scenarios = loadScenarios(args[1]) else { exit(1) }
        jsonMode = true
        items = scenarios.map {
            ReplayItem(id: $0.id, userTail: $0.userTail, ctxPrefix: buildCtxPrefix($0))
        }
        err("INFO: loaded \(items.count) scenarios from \(args[1]).")
        err("INFO: personalizationStrength=\(kPersonalizationStrength), afterSpaceL1BarRuntime=\(SuggestionPolicy.Tuning.afterSpaceL1BarRuntime).")
    } else {
        let logPath = "/tmp/souffleuse-predict.log"
        var tails = parsePredictLog(logPath)
        if tails.isEmpty {
            err("INFO: \(logPath) missing/empty — using \(fallbackTails.count) hardcoded French prefixes.")
            tails = fallbackTails
        } else {
            err("INFO: parsed \(tails.count) distinct userTails from \(logPath).")
        }
        items = tails.map { ReplayItem(id: nil, userTail: $0, ctxPrefix: "") }
    }

    // 4. Drive the real pipeline per item.
    let engineActor = WordCompleter()  // WordCompleter is @unchecked Sendable
    var mdRows: [String] = jsonMode
        ? ["| id | userTail | ghost | source |", "|---|---|---|---|"]
        : ["| userTail | ghost | source |", "|---|---|---|"]

    for item in items {
        let tail = item.userTail
        // INVESTIGATION (FORCE_LLM): bypass routeInstant (corpus/L0) entirely and
        // show the RAW model output for this tail + what the mid-word gate would
        // decide. Lets us see what the LLM produces at "Rapport fis" even when the
        // corpus would otherwise pre-empt it with a history recall.
        if ProcessInfo.processInfo.environment["FORCE_LLM"] != nil {
            let partial = OutputFilter.trailingPartialWord(tail)
            let raw = await runLLM(engine: engine, userTail: tail, ctxPrefix: item.ctxPrefix)
            let gated: GhostUpdate? = await MainActor.run {
                SuggestionPolicyEngine(maxWords: kMaxWords).onLLMChunk(raw, userTail: tail)
            }
            printRow(id: item.id, tail: tail, ghost: raw,
                     source: "llm-raw:plen=\(partial.count):\(gated == nil ? "GATED" : "pass")",
                     rows: &mdRows, jsonMode: jsonMode)
            continue
        }
        // EXPMID (legacy investigation hook): raw mid-word LLM when routeInstant
        // would return nil — kept for ad-hoc probing of the un-gated generation.
        if ProcessInfo.processInfo.environment["EXPMID"] != nil,
           let last = tail.last, last.isLetter || last.isNumber,
           tail.trimmingCharacters(in: .whitespaces).count >= 3 {
            let routedNil: Bool = await MainActor.run {
                SuggestionPolicyEngine(maxWords: kMaxWords)
                    .routeInstant(userTail: tail, historySnapshot: entries, wordCompleter: engineActor) == nil
            }
            if routedNil {
                let partial = OutputFilter.trailingPartialWord(tail)
                let raw = await runLLM(engine: engine, userTail: tail, ctxPrefix: item.ctxPrefix)
                printRow(id: item.id, tail: tail, ghost: raw, source: "llm-mid:plen=\(partial.count)", rows: &mdRows, jsonMode: jsonMode)
                continue
            }
        }

        // TWO-STAGE mirror of PredictorViewModel.predict: stage 1 sets the INSTANT
        // ghost (routeInstant: corpus recall / L0 word-complete / L1 history),
        // stage 2 runs the LLM and lets `onLLMChunk` REPLACE it subject to the
        // relevance gate + replacement bar. We report the FINAL ghost the user
        // sees after the stream settles — so a healed LLM ("fis"→"cal annuel")
        // that beats a context-blind L0 ("ton") shows as the llm result, exactly
        // as it does live. The single-stage "routeInstant wins" model hid this.
        let needLLM = tail.trimmingCharacters(in: .whitespaces).count >= 3
        let raw = needLLM ? await runLLM(engine: engine, userTail: tail, ctxPrefix: item.ctxPrefix) : ""
        let (ghost, source): (String, String) = await MainActor.run {
            let policy = SuggestionPolicyEngine(maxWords: kMaxWords)
            var g = "", s = "none"
            // Stage 1 — instant ghost.
            if let route = policy.routeInstant(userTail: tail, historySnapshot: entries, wordCompleter: engineActor) {
                policy.applyGhost(route.text, source: route.source, score: route.score)
                g = route.text; s = sourceLabel(route.source)
            }
            // Stage 2 — LLM stream can replace the instant ghost via the gate.
            if !raw.isEmpty, let update = policy.onLLMChunk(raw, userTail: tail) {
                policy.applyGhost(update.text, source: update.source, score: update.score)
                g = update.text; s = sourceLabel(update.source)
            }
            return (g, s)
        }
        printRow(id: item.id, tail: tail, ghost: ghost, source: source, rows: &mdRows, jsonMode: jsonMode)
    }

    // 5. Write the markdown table.
    let md = mdRows.joined(separator: "\n") + "\n"
    let outPath = jsonMode ? "/tmp/replay-results-json.md" : "/tmp/replay-results.md"
    try? md.write(toFile: outPath, atomically: true, encoding: .utf8)
    err("INFO: wrote \(outPath)")
}

func sourceLabel(_ s: SuggestionSource) -> String {
    switch s {
    case .none: return "none"
    case .wordComplete: return "wordComplete"
    case .learnedWord: return "learnedWord"
    case .history: return "history"
    case .cache: return "cache"
    case .undoCache: return "undoCache"
    case .llm: return "llm"
    }
}

func printRow(id: String?, tail: String, ghost: String, source: String, rows: inout [String], jsonMode: Bool) {
    let idTag = id.map { "[\($0)] " } ?? ""
    print(idTag + tail.debugDescription + " → " + ghost.debugDescription + "  [" + source + "]")
    let safeTail = tail.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "⏎")
    let safeGhost = ghost.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "⏎")
    if jsonMode {
        rows.append("| \(id ?? "—") | `\(safeTail)` | `\(safeGhost)` | \(source) |")
    } else {
        rows.append("| `\(safeTail)` | `\(safeGhost)` | \(source) |")
    }
}

await main()
