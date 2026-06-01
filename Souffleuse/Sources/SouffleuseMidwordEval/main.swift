import Foundation
import SouffleuseCore
import SouffleuseLlama
import SouffleuseLog
import SouffleusePersonalization
import SouffleuseTyping

// Souffleuse Mid-word Eval Bench
//
// The OCR ablation only exercises after-space / sentence-start completions.
// But the live `overlay_shown` log says ~80% of real ghosts fire MID-WORD
// (caret sits inside a word). That path does NOT go through the free LLM in
// production: `SuggestionPolicy.routeInstant` routes mid-word to L1 (corpus
// recall) first, then L0 (NSSpellChecker word completion); the L2 LLM is
// largely blocked there. So the relevance the user FEELS day-to-day is mostly
// decided by L0/L1 — never measured until now.
//
// For each mid-word prefix this bench prints, side by side:
//   L0  — WordCompleter.completion(for:)            (finish the partial word)
//   L1  — SuggestionPolicy.strongCorpusMatch(...)   (recall from real history)
//   L2  — LlamaEngine.generate(healPrefix:)         (healed whole-word LLM)
//   PICK — SuggestionPolicy.routeInstant(...)        (what prod ACTUALLY shows)
//
// `expected` is the correct continuation, so correctness is eyeball-able.
//
// Usage:
//   SOUFFLEUSE_GGUF=~/Library/Application\ Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf \
//     swift run SouffleuseMidwordEval

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

struct MWCase: Sendable {
    let label: String
    /// Prefix whose LAST char is a letter → caret sits mid-word.
    let prefix: String
    /// The continuation a perfect completer would emit (suffix of the word,
    /// possibly followed by next words). For judging only.
    let expected: String
}

let cases: [MWCase] = [
    // ── Killers from the codebase's own comments ──────────────────────────
    .init(label: "informations-pe", prefix: "Nous protégeons vos informations pe", expected: "rsonnelles"),
    .init(label: "rapport-fis",      prefix: "Vous trouverez votre rapport fis",   expected: "cal"),
    // ── Waltio / fiscalité support domain (matches OCR ablation register) ──
    .init(label: "plus-value",       prefix: "Le calcul de la plus-v",             expected: "alue"),
    .init(label: "investissement",   prefix: "qui prend en compte votre inv",      expected: "estissement"),
    .init(label: "cession",          prefix: "le montant de la cess",              expected: "ion"),
    .init(label: "portefeuille",     prefix: "la valeur globale de votre portef",  expected: "euille"),
    .init(label: "acquisition",      prefix: "votre prix total d'acqui",           expected: "sition"),
    .init(label: "imposable",        prefix: "la fraction imposa",                 expected: "ble"),
    // ── Generic FR support register ───────────────────────────────────────
    .init(label: "effectivement",    prefix: "merci pour votre message. Effectiv", expected: "ement"),
    .init(label: "normal",           prefix: "Bonjour, c'est tout à fait nor",     expected: "mal"),
    .init(label: "patience",         prefix: "je vous remercie de votre pati",     expected: "ence"),
    .init(label: "delais",           prefix: "nous reviendrons vers vous dans les meilleurs dél", expected: "ais"),
    .init(label: "disposition",      prefix: "Je reste à votre dispos",            expected: "ition"),
    // ── Short / ambiguous (where the 1B guesses the wrong word) ───────────
    .init(label: "co-short",         prefix: "Bonjour, co",                        expected: "mment (ambigu)"),
    .init(label: "po-short",         prefix: "Po",                                 expected: "ur (ambigu)"),
    // ── Mots imprévisibles par le contexte (phrase loufoque) : vrais mots du
    //    dico mais que rien dans la phrase ne laisse deviner. On veut voir si le
    //    modèle CONVERGE quand même une fois assez de lettres tapées. ──────────
    .init(label: "pingouin",         prefix: "Hier au zoo j'ai vu un pingou",      expected: "in"),
    .init(label: "aspirateur",       prefix: "je viens d'acheter un aspira",       expected: "teur"),
    .init(label: "sandwich",         prefix: "il a mangé tout mon sandwi",         expected: "ch"),
    .init(label: "cacahuete",        prefix: "une tartine au beurre de cacahu",    expected: "ète"),
    .init(label: "salsa",            prefix: "ce soir nous dansons la sal",        expected: "sa"),
    // ── Nom propre : génuinement indevinable → on ATTEND une divergence/suppr.
    .init(label: "gerard-propre",    prefix: "un aspirateur nommé Gér",            expected: "ard (ambigu)"),
    // ── Fragments courts réellement multi-continuations ────────────────────
    .init(label: "il-fa",            prefix: "je pense qu'il fa",                  expected: "ut/it (ambigu)"),
    .init(label: "je-tr",            prefix: "désolé, je tr",                      expected: "ouve/availle (ambigu)"),
]

// ── L2 sampling: mirror production `generateLlama` exactly. ───────────────
// `minFirstTokenProb` à un epsilon (0.0001) force le calcul du softmax top-1
// (sinon nil — « zéro overhead »). En greedy le token choisi EST l'argmax, donc
// `firstTokenProb` = la vraie confiance top-1 du modèle = le signal Cotypist
// `minBranchProbability`. Seuil si bas qu'il n'aborte jamais → sortie inchangée.
func runLLM(prefix: String, engine: LlamaEngine) async -> (out: String, ms: Int, p1: Double?) {
    let heal = OutputFilter.trailingPartialWord(prefix)
    let prompt = LlamaPromptBuilder.buildLlamaPrompt(
        system: "", customInstr: "", ctxPrefix: "", fieldContext: "",
        afterCursor: "", beforeCursor: prefix
    )
    let start = Date()
    final class Acc: @unchecked Sendable { var text = "" }
    let acc = Acc()
    let metrics = await engine.generate(
        prompt: prompt,
        maxTokens: 12,
        sampling: LlamaSampling(
            temperature: 0,
            repeatPenalty: 1.3,
            repeatLastN: 64,
            personalizationStrength: 0,
            banMarkup: true,
            banDigitsLeading: true,
            banEmoji: true,
            minFirstTokenProb: 0.0001,
            healPrefix: heal.isEmpty ? nil : heal
        )
    ) { tok in acc.text += tok; return true }
    let ms = Int(Date().timeIntervalSince(start) * 1000)
    let oneLine = acc.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? acc.text
    return (oneLine, ms, metrics.firstTokenProb)
}

// ── Branch-divergence mode (spike) ────────────────────────────────────────
// Hypothèse : le LLM peut redevenir pertinent mid-mot si on le CADRE par des
// branches. Une branche = un appel `generate` avec temperature>0 + seed
// distinct ; le RESTE du profil prod est IDENTIQUE (repeatPenalty 1.3, bans,
// healPrefix). `llama_sampler_init_dist(seed)` rend chaque branche stochastique
// ET reproductible. On mesure (a) l'ACCORD inter-branches sur le mot complété
// et (b) la confiance `firstTokenProb` par branche (parité Cotypist
// minBranchProbability). Le KV cache réutilise le prefill (prompt identique
// entre branches) → coût ≈ 1 prefill + k décodes courts.
/// Run de tête « mot » : lettres/chiffres + joints intra-mot (' ’ -), espaces
/// de tête ignorés. Vide ⇒ la branche a sauté au mot suivant (espace/ponct).
func leadWord(_ s: String) -> String {
    var t = Substring(s)
    while t.first == " " { t = t.dropFirst() }
    var out = ""
    for ch in t {
        if ch.isLetter || ch.isNumber || ch == "'" || ch == "’" || ch == "-" { out.append(ch) }
        else { break }
    }
    return out
}

/// K branches stochastiques (même prompt healed, seeds distincts). Retourne le
/// run de tête « mot » de chaque branche — c'est lui qu'on compare entre elles.
func runLLMBranches(prefix: String, engine: LlamaEngine, k: Int, temp: Float) async -> [String] {
    let heal = OutputFilter.trailingPartialWord(prefix)
    let prompt = LlamaPromptBuilder.buildLlamaPrompt(
        system: "", customInstr: "", ctxPrefix: "", fieldContext: "",
        afterCursor: "", beforeCursor: prefix
    )
    var leads: [String] = []
    for i in 0..<k {
        final class Acc: @unchecked Sendable { var text = "" }
        let acc = Acc()
        _ = await engine.generate(
            prompt: prompt,
            maxTokens: 12,
            sampling: LlamaSampling(
                temperature: temp,
                repeatPenalty: 1.3,
                repeatLastN: 64,
                seed: UInt32(i + 1),
                personalizationStrength: 0,
                topP: 0.9,
                banMarkup: true,
                banDigitsLeading: true,
                banEmoji: true,
                healPrefix: heal.isEmpty ? nil : heal
            )
        ) { tok in acc.text += tok; return true }
        let oneLine = acc.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? acc.text
        leads.append(leadWord(oneLine))
    }
    return leads
}

/// Accord inter-branches : mot modal (casse d'origine), son compte, l'accord [0,1].
func agreementStats(_ leads: [String]) -> (modal: String, modalCount: Int, agreement: Double) {
    guard !leads.isEmpty else { return ("", 0, 0) }
    var counts: [String: Int] = [:]
    for l in leads { counts[l.lowercased(), default: 0] += 1 }
    let top = counts.max { a, b in a.value < b.value }
    let modalKey = top?.key ?? ""
    let modalCount = top?.value ?? 0
    let modalDisplay = leads.first { $0.lowercased() == modalKey } ?? ""
    return (modalDisplay, modalCount, Double(modalCount) / Double(leads.count))
}

/// Verdict de correction : le mot modal reconstitue-t-il le mot VISÉ
/// (`partiel tapé + expected`) ? Tolère l'élision de tête (« d'acquisition ») et
/// le pluriel de queue. nil = cas marqué ambigu (exclu du calcul). Le modal est
/// le mot ENTIER re-dérivé par le healing, pas le suffixe — d'où la reconstruction.
func judgeBranch(prefix: String, expected: String, modal: String) -> Bool? {
    if expected.contains("(ambigu)") { return nil }
    func core(_ s: String) -> String { s.lowercased().filter { $0.isLetter } }
    let partial = OutputFilter.trailingPartialWord(prefix)
    let intended = core(partial + expected)
    let m = core(modal)
    guard m.count >= 3, !intended.isEmpty else { return false }
    return m == intended || m.contains(intended)
        || (intended.contains(m) && m.count >= 4 && m.count >= intended.count - 2)
}

struct CaseBranchStat { let label: String; let agreement: Double; let p1: Double?; let modal: String; let correct: Bool? }

// ── Escalation prototype (Frame C, forme shippable) ───────────────────────
// Étage 1 (greedy, 1 passe) : REJETTE vite les échecs de healing (mot fusionné
// invalide : « pingo », « a », « s », « i ») et ACCEPTE vite les complétions
// confiantes (P1 haut + fragment assez long pour être peu ambigu : « cacahuète »).
// Étage 2 (branches k≤3, courtes, early-exit) UNIQUEMENT pour la zone incertaine
// (mot valide mais P1 bas, ou fragment court : « fis », « co », « Po »). But :
// ne payer les branches QUE quand c'est nécessaire.

/// Validité dico synchrone : `defaultPartialWordIsComplete(w)` calcule
/// `trailingPartialWord(w)` (= w pour un mot nu) puis NSSpellChecker.
func isValidWordSync(_ w: String) -> Bool {
    guard !w.isEmpty else { return false }
    return SuggestionPolicy.defaultPartialWordIsComplete(w)
}

/// Le mot `modal` prolonge-t-il le partiel tapé ET est-il un vrai mot ? Attrape
/// les échecs de healing (« a » ne prolonge pas « aspira », « pingo » ≠ « pingou »).
func validExtends(partial: String, modal: String) -> Bool {
    guard modal.lowercased().hasPrefix(partial.lowercased()) else { return false }
    return isValidWordSync(modal)
}

/// Une branche COURTE (maxTokens 4 — on ne veut que le mot courant) → run de tête.
func oneBranchLead(prompt: String, heal: String?, seed: UInt32, temp: Float, engine: LlamaEngine) async -> String {
    final class Acc: @unchecked Sendable { var text = "" }
    let acc = Acc()
    _ = await engine.generate(
        prompt: prompt, maxTokens: 4,
        sampling: LlamaSampling(
            temperature: temp, repeatPenalty: 1.3, repeatLastN: 64, seed: seed,
            personalizationStrength: 0, topP: 0.9,
            banMarkup: true, banDigitsLeading: true, banEmoji: true,
            healPrefix: heal
        )
    ) { tok in acc.text += tok; return true }
    let oneLine = acc.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? acc.text
    return leadWord(oneLine)
}

struct EscResult {
    let stage: String        // FAST-ACCEPT / FAST-REJECT / BRANCHED
    let shown: Bool
    let word: String
    let agreement: Double    // 1.0 pour les voies rapides (pas de branches)
    let branches: Int
    let ms: Double
    let correct: Bool?
}

func escalate(c: MWCase, engine: LlamaEngine,
              fastP1: Double, minFastLen: Int, k: Int, temp: Float, agreeThresh: Double) async -> EscResult {
    let t0 = Date()
    let partial = OutputFilter.trailingPartialWord(c.prefix)
    let (gout, _, p1) = await runLLM(prefix: c.prefix, engine: engine)
    let gmodal = leadWord(gout)

    // Étage 1a — rejet rapide des échecs de healing (0 branche).
    if !validExtends(partial: partial, modal: gmodal) {
        return EscResult(stage: "FAST-REJECT", shown: false, word: gmodal, agreement: 1.0,
                         branches: 0, ms: Date().timeIntervalSince(t0) * 1000,
                         correct: judgeBranch(prefix: c.prefix, expected: c.expected, modal: gmodal))
    }
    // Étage 1b — accept rapide : confiant ET fragment assez long pour être peu
    // ambigu. (Un fragment court « Po » à P1 haut reste suspect → on branche.)
    if (p1 ?? 0) >= fastP1 && partial.count >= minFastLen {
        return EscResult(stage: "FAST-ACCEPT", shown: true, word: gmodal, agreement: 1.0,
                         branches: 0, ms: Date().timeIntervalSince(t0) * 1000,
                         correct: judgeBranch(prefix: c.prefix, expected: c.expected, modal: gmodal))
    }

    // Étage 2 — branches (le greedy compte comme 1 vote), early-exit dès qu'un
    // mot atteint la majorité requise.
    let heal = partial.isEmpty ? nil : partial
    let prompt = LlamaPromptBuilder.buildLlamaPrompt(
        system: "", customInstr: "", ctxPrefix: "", fieldContext: "", afterCursor: "", beforeCursor: c.prefix)
    var counts: [String: Int] = [gmodal.lowercased(): 1]
    var displays: [String: String] = [gmodal.lowercased(): gmodal]
    var votes = 1
    let needed = Int((agreeThresh * Double(k + 1)).rounded(.up))
    var used = 0
    for i in 0..<k {
        let lead = await oneBranchLead(prompt: prompt, heal: heal, seed: UInt32(i + 1), temp: temp, engine: engine)
        used += 1; votes += 1
        counts[lead.lowercased(), default: 0] += 1
        if displays[lead.lowercased()] == nil { displays[lead.lowercased()] = lead }
        if let top = counts.values.max(), top >= needed { break }   // early-exit
    }
    let top = counts.max { a, b in a.value < b.value }
    let modal = displays[top?.key ?? ""] ?? ""
    let agreement = Double(top?.value ?? 0) / Double(votes)
    let shown = agreement >= agreeThresh && validExtends(partial: partial, modal: modal)
    return EscResult(stage: "BRANCHED", shown: shown, word: modal, agreement: agreement,
                     branches: used, ms: Date().timeIntervalSince(t0) * 1000,
                     correct: judgeBranch(prefix: c.prefix, expected: c.expected, modal: modal))
}

// ── Boot the engine on the same GGUF as production / the OCR ablation. ────
let ggufPath: String = {
    if let p = ProcessInfo.processInfo.environment["SOUFFLEUSE_GGUF"], !p.isEmpty {
        return (p as NSString).expandingTildeInPath
    }
    return (("~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf") as NSString)
        .expandingTildeInPath
}()

let engine = LlamaEngine()
err("[midword] loading GGUF: \(ggufPath)")
guard await engine.load(modelPath: ggufPath, contextTokens: 4096) else {
    err("[midword] FATAL: could not load GGUF")
    exit(1)
}

// Real typing history → L1 corpus recall + engine n-gram (matches production).
let store = TypingHistoryStore()
let history = await store.allEntries()
err("[midword] history entries: \(history.count)")
if !history.isEmpty {
    await engine.setCorpus(history.map { e in
        e.contextBefore.isEmpty ? e.accepted : e.contextBefore + " " + e.accepted
    })
}

let wordCompleter = WordCompleter()
let policy = await MainActor.run { SuggestionPolicyEngine(maxWords: 8) }

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
}
func show(_ s: String?) -> String { (s?.isEmpty == false) ? s! : "∅" }

let branchK = max(1, Int(ProcessInfo.processInfo.environment["MW_BRANCHES"] ?? "5") ?? 5)
let branchTemp = Float(ProcessInfo.processInfo.environment["MW_BRANCH_TEMP"] ?? "0.7") ?? 0.7
err("[midword] branch mode: k=\(branchK) temp=\(branchTemp)")
let escalateMode = ProcessInfo.processInfo.environment["MW_ESCALATE"] != nil

// ── Mode MESURE (MW_MEASURE=1) : chiffre latence + K minimal + tokens/branche ─
// Utilise les VRAIES fonctions de prod (midWordLeadWordDefrag / midWordFastDecision
// / midWordBranchDecision) sur les 24 cas. Early-exit → n'affecte aucun autre mode.
if ProcessInfo.processInfo.environment["MW_MEASURE"] != nil {
    let kmax = max(1, Int(ProcessInfo.processInfo.environment["MW_KMAX"] ?? "6") ?? 6)
    let mtemp = Float(ProcessInfo.processInfo.environment["MW_MTEMP"] ?? "0.4") ?? 0.4
    err("\n──────────── MESURE (kmax=\(kmax) temp=\(mtemp) agree=\(SuggestionPolicy.Tuning.escAgreeThresh)) ────────────")

    func timedBranch(prompt: String, heal: String?, seed: UInt32, maxTokens: Int) async -> (lead: String, ms: Double) {
        final class Acc: @unchecked Sendable { var text = "" }
        let acc = Acc()
        let t0 = Date()
        _ = await engine.generate(
            prompt: prompt, maxTokens: maxTokens,
            sampling: LlamaSampling(temperature: mtemp, repeatPenalty: 1.3, repeatLastN: 64,
                seed: seed, personalizationStrength: 0, topP: 0.9,
                banMarkup: true, banDigitsLeading: true, banEmoji: true, healPrefix: heal))
        { tok in acc.text += tok; return true }
        let ms = Date().timeIntervalSince(t0) * 1000
        let oneLine = acc.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? acc.text
        return (SuggestionPolicy.midWordLeadWordDefrag(oneLine, partial: heal ?? ""), ms)
    }
    // Décision « juste » : cas ambigu ⇒ doit CACHER ; déterminable ⇒ doit MONTRER le bon mot.
    func decisionCorrect(_ c: MWCase, show: Bool, word: String) -> Bool {
        if c.expected.contains("(ambigu)") { return !show }
        return show && (judgeBranch(prefix: c.prefix, expected: c.expected, modal: word) == true)
    }

    // Pré-calcul greedy (déterministe) : lead + P1 + ms + prompt, une fois.
    struct G { let partial: String; let lead: String; let p1: Double?; let prompt: String; let ms: Int }
    var G_: [G] = []
    for c in cases {
        let partial = OutputFilter.trailingPartialWord(c.prefix)
        let (gout, gms, p1) = await runLLM(prefix: c.prefix, engine: engine)
        let prompt = LlamaPromptBuilder.buildLlamaPrompt(
            system: "", customInstr: "", ctxPrefix: "", fieldContext: "", afterCursor: "", beforeCursor: c.prefix)
        G_.append(G(partial: partial, lead: SuggestionPolicy.midWordLeadWordDefrag(gout, partial: partial),
                    p1: p1, prompt: prompt, ms: gms))
    }
    let determinable = cases.filter { !$0.expected.contains("(ambigu)") }.count
    let greedyMsAvg = G_.reduce(0) { $0 + $1.ms } / max(1, G_.count)

    // ── Phase A : sweep K (branches BTOK=4), + latence/branche ──
    var branchMsSum = 0.0, branchMsN = 0
    var greedyCorrect = 0
    var correctAtK = [Int](repeating: 0, count: kmax + 1)
    for (idx, c) in cases.enumerated() {
        let g = G_[idx]
        switch SuggestionPolicy.midWordFastDecision(partial: g.partial, greedyModal: g.lead, firstTokenProb: g.p1) {
        case .fastAccept(let w): if decisionCorrect(c, show: true, word: w) { greedyCorrect += 1 }
        default:                 if decisionCorrect(c, show: false, word: "") { greedyCorrect += 1 }
        }
        let heal = g.partial.isEmpty ? nil : g.partial
        var leads: [String] = []
        for i in 0..<kmax {
            let (lead, bms) = await timedBranch(prompt: g.prompt, heal: heal, seed: UInt32(i + 1), maxTokens: 4)
            branchMsSum += bms; branchMsN += 1
            leads.append(lead)
            let d = SuggestionPolicy.midWordBranchDecision(partial: g.partial, greedyModal: g.lead, branchLeads: leads)
            if decisionCorrect(c, show: d.show, word: d.word) { correctAtK[i + 1] += 1 }
        }
    }
    err("\nLATENCE  : greedy ~\(greedyMsAvg) ms/passe · branche ~\(Int(branchMsSum / Double(max(1, branchMsN)))) ms/passe")
    err("JUSTESSE (\(cases.count) cas dont \(determinable) déterminables) — Q2 : K minimal pour battre le greedy")
    err("  greedy seul           : \(greedyCorrect)/\(cases.count)")
    for k in 1...kmax {
        let delta = correctAtK[k] - greedyCorrect
        err("  greedy + \(k) branche(s)  : \(correctAtK[k])/\(cases.count)   (\(delta >= 0 ? "+" : "")\(delta) vs greedy)")
    }

    // ── Phase B : sweep tokens/branche (K=kmax fixe) — Q3 ──
    err("\nTOKENS/BRANCHE (K=\(kmax) fixe) — Q3 : justesse ET latence par token-count (incl. 8 = prod)")
    for btok in [2, 3, 4, 6, 8] {
        var corr = 0
        var msSum = 0.0, msN = 0
        for (idx, c) in cases.enumerated() {
            let g = G_[idx]
            let heal = g.partial.isEmpty ? nil : g.partial
            var leads: [String] = []
            for i in 0..<kmax {
                let (lead, bms) = await timedBranch(prompt: g.prompt, heal: heal, seed: UInt32(i + 1), maxTokens: btok)
                msSum += bms; msN += 1
                leads.append(lead)
            }
            let d = SuggestionPolicy.midWordBranchDecision(partial: g.partial, greedyModal: g.lead, branchLeads: leads)
            if decisionCorrect(c, show: d.show, word: d.word) { corr += 1 }
        }
        err("  \(btok) tokens/branche : \(corr)/\(cases.count) corrects · ~\(Int(msSum / Double(max(1, msN)))) ms/branche")
    }

    // ── Phase C : sweep cap GREEDY — justesse du mot de tête + latence ──
    err("\nGREEDY CAP — justesse du mot de tête (\(determinable) déterminables) + latence")
    for gcap in [3, 4, 6, 8] {
        var leadCorrect = 0
        var msSum = 0.0
        var detail: [String] = []
        for c in cases where !c.expected.contains("(ambigu)") {
            let partial = OutputFilter.trailingPartialWord(c.prefix)
            let prompt = LlamaPromptBuilder.buildLlamaPrompt(
                system: "", customInstr: "", ctxPrefix: "", fieldContext: "", afterCursor: "", beforeCursor: c.prefix)
            final class Acc: @unchecked Sendable { var text = "" }
            let acc = Acc()
            let t0 = Date()
            _ = await engine.generate(
                prompt: prompt, maxTokens: gcap,
                sampling: LlamaSampling(temperature: 0, repeatPenalty: 1.3, repeatLastN: 64,
                    personalizationStrength: 0, banMarkup: true, banDigitsLeading: true, banEmoji: true,
                    minFirstTokenProb: 0.0001, healPrefix: partial.isEmpty ? nil : partial))
            { tok in acc.text += tok; return true }
            msSum += Date().timeIntervalSince(t0) * 1000
            let oneLine = acc.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? acc.text
            let lead = SuggestionPolicy.midWordLeadWordDefrag(oneLine, partial: partial)
            let ok = judgeBranch(prefix: c.prefix, expected: c.expected, modal: lead) == true
            if ok { leadCorrect += 1 }
            // Détail seulement au cap prod (8) pour montrer mot visé vs trouvé.
            if gcap == 8 {
                let intended = partial + c.expected
                detail.append("    \(ok ? "✅" : "❌") \(pad(c.label, 16)) visé=\(pad(intended, 16)) greedy=\(lead.isEmpty ? "∅" : lead)")
            }
        }
        err("  cap \(gcap) : \(leadCorrect)/\(determinable) mots corrects · ~\(Int(msSum / Double(cases.count))) ms/passe")
        if !detail.isEmpty {
            err("  ── détail @cap8 (mot visé vs greedy) ──")
            for d in detail { err(d) }
        }
    }
    exit(0)
}

if !escalateMode {
err("\n──────────── Mid-word layer eval (\(cases.count) cases) ────────────")
var l0Hits = 0, l1Hits = 0, pickL0 = 0, pickL1 = 0, pickNone = 0
var branchStats: [CaseBranchStat] = []

for c in cases {
    let l0 = wordCompleter.completion(for: c.prefix)
    let l1 = SuggestionPolicy.strongCorpusMatch(userTail: c.prefix, snapshot: history)?.continuation
    let (l2, l2ms, l2p1) = await runLLM(prefix: c.prefix, engine: engine)
    let prefix = c.prefix
    let pick: (source: String, text: String)? = await MainActor.run {
        guard let g = policy.routeInstant(
            userTail: prefix, historySnapshot: history, wordCompleter: wordCompleter
        ) else { return nil }
        let src: String
        switch g.source {
        case .wordComplete: src = "L0"
        case .history:      src = "L1"
        default:            src = "\(g.source)"
        }
        return (src, g.text)
    }

    if l0 != nil { l0Hits += 1 }
    if l1 != nil { l1Hits += 1 }
    switch pick?.source {
    case .some("L0"): pickL0 += 1
    case .some("L1"): pickL1 += 1
    default: pickNone += 1
    }

    let pickStr: String
    switch pick?.source {
    case .some(let s): pickStr = "\(s):\(show(pick?.text))"
    case .none:        pickStr = "∅ (→ L2 LLM fills)"
    }

    print("""

    ### \(c.label)  —  "\(c.prefix)"   (attendu: \(c.expected))
      L0 word-complete : \(show(l0))
      L1 corpus-recall : \(show(l1))
      L2 LLM healed    : \(show(l2))   [\(l2ms)ms]
      → PROD MONTRE    : \(pickStr)
    """)

    // Branches : k tirages stochastiques (même prompt healed, seeds distincts).
    let leads = await runLLMBranches(prefix: c.prefix, engine: engine, k: branchK, temp: branchTemp)
    let (modal, modalCount, agreement) = agreementStats(leads)
    let correct = judgeBranch(prefix: c.prefix, expected: c.expected, modal: modal)
    branchStats.append(CaseBranchStat(label: c.label, agreement: agreement, p1: l2p1, modal: modal, correct: correct))
    let leadList = leads.map { $0.isEmpty ? "∅" : $0 }.joined(separator: " · ")
    let p1Str = l2p1.map { String(format: "%.2f", $0) } ?? "?"
    let verdict = correct == nil ? "➖ ambigu" : (correct! ? "✅ accord = bon mot" : "❌ accord ≠ attendu")
    print("""
      branches (k=\(branchK), T=\(branchTemp)): \(leadList)
      → modal "\(modal.isEmpty ? "∅" : modal)" ×\(modalCount)/\(branchK)   agreement=\(String(format: "%.2f", agreement))   P1(greedy top-1)=\(p1Str)   \(verdict)
    """)
}

err("""

──────────── Summary ────────────
cases:                 \(cases.count)
L0 produced a result:  \(l0Hits)/\(cases.count)
L1 produced a result:  \(l1Hits)/\(cases.count)
PROD pick = L0:        \(pickL0)
PROD pick = L1:        \(pickL1)
PROD pick = none(→L2): \(pickNone)

Reading:
  PROD pick column is what the user actually SEES mid-word. If most picks are
  L0 and L0 is wrong/jumpy, that — not the LLM, not OCR — is the felt "generic".
  If most picks are 'none(→L2)', the mid-word LLM healed quality (L2 column)
  is what matters and should be judged against `expected`.
""")

// ── Branch divergence : pouvoir discriminant (le résultat du spike) ────────
let judged = branchStats.filter { $0.correct != nil }
let hi = judged.filter { $0.agreement >= 0.6 }
let lo = judged.filter { $0.agreement < 0.6 }
let hiC = hi.filter { $0.correct == true }.count
let loC = lo.filter { $0.correct == true }.count
func meanD(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
let p1ok = meanD(judged.filter { $0.correct == true }.compactMap { $0.p1 })
let p1ko = meanD(judged.filter { $0.correct == false }.compactMap { $0.p1 })

var table = "\n──────────── Branch divergence : pouvoir discriminant ────────────\n"
table += "\(pad("case", 20))  agree   P1    modal\n"
for s in branchStats {
    let mark = s.correct == nil ? "➖" : (s.correct! ? "✅" : "❌")
    let p1s = s.p1.map { String(format: "%.2f", $0) } ?? " ?  "
    table += "\(pad(s.label, 20))  \(String(format: "%.2f", s.agreement))  \(p1s)   \(mark) \(s.modal.isEmpty ? "∅" : s.modal)\n"
}
table += """

Discrimination (cas non-ambigus : \(judged.count)) :
  agreement ≥ 0.60 : \(hi.count) cas, \(hiC) bons (\(hi.isEmpty ? 0 : hiC * 100 / hi.count)%)
  agreement < 0.60 : \(lo.count) cas, \(loC) bons (\(lo.isEmpty ? 0 : loC * 100 / lo.count)%)
  P1(bons)         = \(String(format: "%.2f", p1ok))
  P1(mauvais)      = \(String(format: "%.2f", p1ko))

Lecture :
  Si « agreement ≥ 0.60 » est très majoritairement bon ET « < 0.60 » majoritairement
  mauvais → la DIVERGENCE inter-branches discrimine (l'hypothèse Frame C tient).
  Si P1(bons) ≫ P1(mauvais) → la confiance top-1 greedy discrimine aussi (gate moins cher).
  Le meilleur des deux — ou les deux combinés — devient le score du gate mid-mot.
"""
err(table)
}  // if !escalateMode

// ── Escalation prototype : greedy+dico → branches seulement si incertain ──
if escalateMode {
    let fastP1 = Double(ProcessInfo.processInfo.environment["MW_FAST_P1"] ?? "0.85") ?? 0.85
    let minFastLen = Int(ProcessInfo.processInfo.environment["MW_FAST_LEN"] ?? "4") ?? 4
    let escK = max(1, Int(ProcessInfo.processInfo.environment["MW_ESC_K"] ?? "3") ?? 3)
    let escTemp = Float(ProcessInfo.processInfo.environment["MW_ESC_TEMP"] ?? "0.7") ?? 0.7
    let agreeThresh = Double(ProcessInfo.processInfo.environment["MW_AGREE"] ?? "0.6") ?? 0.6
    err("\n──────────── Escalation prototype (fastP1=\(fastP1) minLen=\(minFastLen) k≤\(escK) agree≥\(agreeThresh)) ────────────")

    var results: [(MWCase, EscResult)] = []
    for c in cases {
        let r = await escalate(c: c, engine: engine, fastP1: fastP1, minFastLen: minFastLen,
                               k: escK, temp: escTemp, agreeThresh: agreeThresh)
        results.append((c, r))
    }

    var tbl = "\n\(pad("case", 16)) \(pad("stage", 12)) show  br  ms     verdict word\n"
    var totBranches = 0
    var totMs = 0.0
    var fastA = 0, fastR = 0, branched = 0
    for (c, r) in results {
        totBranches += r.branches; totMs += r.ms
        switch r.stage {
        case "FAST-ACCEPT": fastA += 1
        case "FAST-REJECT": fastR += 1
        default: branched += 1
        }
        let mark = r.correct == nil ? "➖" : (r.correct! ? "✅" : "❌")
        tbl += "\(pad(c.label, 16)) \(pad(r.stage, 12)) \(pad(r.shown ? "SHOW" : "hide", 4))  \(r.branches)   \(pad(String(format: "%.0f", r.ms), 5))  \(mark)      \(r.word.isEmpty ? "∅" : r.word)\n"
    }
    err(tbl)

    let n = results.count
    let shows = results.filter { $0.1.shown }
    let goodShow = shows.filter { $0.1.correct == true }.count
    let badShow = shows.filter { $0.1.correct == false }.count
    // Un « hide » est CORRECT s'il cache un garbage (correct==false) ou un ambigu/
    // nom propre (correct==nil) — c.-à-d. tout sauf un bon qu'on aurait raté.
    let hides = results.filter { !$0.1.shown }
    let missedGood = hides.filter { $0.1.correct == true }.count
    let allBranchCost = n * escK
    let saved = allBranchCost == 0 ? 0 : (100 - totBranches * 100 / allBranchCost)
    err("""
    ── Coût & qualité ──
    cases:                 \(n)
    FAST-ACCEPT (0 br)  :  \(fastA)
    FAST-REJECT (0 br)  :  \(fastR)
    BRANCHED            :  \(branched)
    appels-branche tot. :  \(totBranches)   (vs \(allBranchCost) si on branchait tout → −\(saved)%)
    temps total         :  \(String(format: "%.0f", totMs)) ms   (moy \(String(format: "%.0f", totMs / Double(n))) ms/cas)
    ── décisions ──
    montrés             :  \(shows.count)   dont \(goodShow) bons, \(badShow) garbage
    cachés              :  \(hides.count)   dont \(missedGood) bons ratés (idéalement → fallback L0 dico)

    Lecture : un bon gate maximise « bons montrés », garde « garbage montré » à 0,
    et minimise les branches (coût). Les « bons ratés » sont les mots que le LLM
    fumble (pingouin/aspirateur…) → c'est le fallback WordCompleter L0 qui les couvre.
    """)
}
