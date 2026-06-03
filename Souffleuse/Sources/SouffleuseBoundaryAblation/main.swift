import Foundation
import NaturalLanguage
import SouffleuseLlama
import SouffleuseCore
import SouffleusePersonalization
import SouffleuseTyping

// ═════════════════════════════════════════════════════════════════════════
// SouffleuseBoundaryAblation — OAT (one-axis-at-a-time) sweep harness for
// SENTENCE-BOUNDARY ghost generation (caret right after . ! ? …).
//
// Drives the REAL SouffleuseLlama.LlamaEngine (same engine PVM uses) through
// a parameterizable prompt assembly that mirrors
// LlamaPromptBuilder.buildLlamaPrompt(...) (SouffleuseCore). The PRODUCTION
// stack is untouched: this is a standalone dev executable.
//
// It emits one JSONL record per (config, case) on stdout (or a file), so a
// downstream judge (Claude, offline) can classify each ghost as
// ACCEPT(+2)/STEER(+1)/NEUTRAL(0)/HARMFUL(-1) and compute net value vs SILENCE.
//
// This harness does NOT judge. It only GENERATES the ghosts under each config.
// Post-generation gate thresholds (gateFloor, sourcePrior, lengthFit…) are
// analysis-time filters over these outputs — NOT a generation axis (per spec).
// ═════════════════════════════════════════════════════════════════════════

// ── Model location ─────────────────────────────────────────────────────────
// Default to the same GGUF SouffleuseLlamaProbe hardcodes (verified present).
// Overridable via SOUFFLEUSE_MODEL or arg1 == "--model <path>".
let defaultModel = NSString(string: "~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf").expandingTildeInPath

func argValue(_ flag: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
    return a[i + 1]
}

let modelPath = argValue("--model")
    ?? ProcessInfo.processInfo.environment["SOUFFLEUSE_MODEL"]
    ?? defaultModel
let casesPath = argValue("--cases") ?? "/tmp/boundary-cases.json"
let smoke = CommandLine.arguments.contains("--smoke")
// GATE-VERDICT mode: measure the FALSE-GATE rate. For each case we generate the
// RAW ghost (tailOnly, greedy, normal budget) then run the PURE SuggestionPolicy
// functions (prefixFit / lengthFit / score / passesGate) over (ghost, tail) and
// emit the verdict. This is a MEASUREMENT, not a generation-axis sweep. Implies
// --smoke cases unless a --cases file is given.
let gateVerdict = CommandLine.arguments.contains("--gateverdict")
// COMBINE mode: run the control (mid-*) cases for EVERY config (full
// non-regression guard), not just the preamble-variant subset.
let allControl = CommandLine.arguments.contains("--all-control")

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// ── Config (the OAT axes) ───────────────────────────────────────────────────

/// Which slots of the live preamble survive. `full` = persona + app + clipboard
/// (+ optional onScreen). `tailOnly` = just the user's text (no preamble at all,
/// the hypothesised winner per the diagnostic).
enum PreambleMode: String, Codable, CaseIterable {
    case full, noClipboard, noPersona, noApp, tailOnly
}

enum CorpusMode: String, Codable, CaseIterable {
    case empty, user
}

/// Selector for branches>1: how to pick the winning candidate from K decodes.
/// `grounding` favours lexical overlap with the case context (anti-generic),
/// NOT consensus (which collapses to the generic opener). `first` = take seed 0.
enum SelectorMode: String, Codable, CaseIterable {
    case first, grounding, longest, corrected
}

struct Config: Codable {
    var name: String
    var preamble: PreambleMode = .full
    var maxTokens: Int = 12
    var temperature: Double = 0
    var repetitionPenalty: Double = 1.3
    var corpus: CorpusMode = .empty
    var primer: Bool = false
    var prefixWindow: Int = 1024
    var branches: Int = 1
    var selector: SelectorMode = .first
    /// POST-FILTER mode (deterministic, mono-decode). When true, the SINGLE
    /// greedy candidate is run through two HARD gates AFTER generation:
    ///   (a) anti-echo  — silence if word-overlap with the typed tail is too high
    ///   (b) hard-lang  — silence if detected language != the case's expected one
    /// Failure → silence (""). This recovers temp0.3's de-echo / de-leak benefit
    /// without stochasticity (ghost stays stable frappe-à-frappe).
    var postFilter: Bool = false
    /// Anti-echo trip threshold. Echo score = max(Jaccard(ghost,tail),
    /// LCS-word-fraction of ghost covered by the tail's last sentence).
    var echoThreshold: Double = 0.5
}

/// On-disk case schema (matches /tmp/boundary-cases.json verbatim):
///   { id, register, inDist, context, position, acceptableIntentions }
/// The file does NOT carry preamble inputs (persona/app/clipboard) — those are
/// the PRODUCTION preamble slots, synthesised per-register below so the `full`
/// axis reproduces the diagnostic (EN persona → English drift).
struct DiskCase: Codable {
    var id: String
    var register: String
    var inDist: Bool
    var context: String
    var position: String
    var acceptableIntentions: [String]
}

/// A boundary test case with the preamble inputs resolved.
struct BoundaryCase {
    var id: String
    var register: String
    var ood: Bool
    var position: String          // "boundary" | "midword" | "midsentence"
    var before: String            // == disk `context`
    var acceptableIntentions: [String]
    var persona: String?
    var app: String?
    var windowTitle: String?
    var clipboard: String?
}

/// Synthesise the PRODUCTION preamble inputs for a case from its register.
/// This is the exact aggravating preamble proved in the diagnostic: an EN
/// persona ("My name is Gabriel. I usually write in French."), an app/window
/// context line, and (sometimes) a clipboard line. Keyed on register so each
/// case gets a plausible live context, NOT carried in the case file.
func resolveCase(_ d: DiskCase) -> BoundaryCase {
    let persona = "My name is Gabriel. I usually write in French."
    let (app, win, clip): (String?, String?, String?)
    switch d.register {
    case "fr-crypto-fiscalite", "ctrl-fr-crypto-fiscalite":
        (app, win, clip) = ("Brave", "Fiscalio — Déclaration crypto", "0x9f2a…declaration 2086")
    case "fr-chat-info", "ctrl-fr-chat-info":
        (app, win, clip) = ("Messages", nil, nil)
    case "fr-slack", "ctrl-fr-slack":
        (app, win, clip) = ("Slack", "#dev — Fiscalio", nil)
    case "fr-signal-chat":
        (app, win, clip) = ("Signal", "Signal", nil)
    case "ood-email-formel-fr":
        (app, win, clip) = ("Brave", "Inbox · Gmail", nil)
    case "ood-english-pro", "ctrl-english-pro":
        (app, win, clip) = ("Slack", "#general", nil)
    case "ood-english-chat":
        (app, win, clip) = ("Messages", nil, nil)
    case "ood-spanish":
        (app, win, clip) = ("WhatsApp", "WhatsApp", nil)
    case "ood-cuisine-voyage-fr", "ctrl-cuisine-voyage-fr":
        (app, win, clip) = ("Notes", "Recettes", nil)
    default:
        (app, win, clip) = ("Brave", nil, nil)
    }
    return BoundaryCase(
        id: d.id, register: d.register, ood: !d.inDist, position: d.position,
        before: d.context, acceptableIntentions: d.acceptableIntentions,
        persona: persona, app: app, windowTitle: win, clipboard: clip
    )
}

// ── Preamble assembly (mirrors LlamaPromptBuilder.buildLlamaPrompt) ──────────
// Production assembly (PVM:543-549 + ContextEnricher.prefix + LlamaPromptBuilder):
//   contextPrefix = "App X, window \"Y\". Clipboard: Z. On screen: …"  (EN prose)
//   basePreamble  = customInstructions(persona) + "\n\n" + contextPrefix + "\n\n"
//   prompt        = basePreamble + windowed(tail), trailing space stripped.
// We rebuild the SAME string but let `PreambleMode` drop slots.

func appContextProse(app: String?, windowTitle: String?) -> String {
    guard let app, !app.isEmpty else { return "" }
    if let t = windowTitle, !t.isEmpty { return "App \(app), window \"\(t)\"." }
    return "App \(app)."
}

func buildPrompt(_ c: BoundaryCase, _ cfg: Config) -> String {
    var personaPart = ""
    var ctxBits: [String] = []

    switch cfg.preamble {
    case .full:
        personaPart = c.persona ?? ""
        if let a = appContextProse(app: c.app, windowTitle: c.windowTitle) as String?, !a.isEmpty { ctxBits.append(a) }
        if let clip = c.clipboard, !clip.isEmpty { ctxBits.append("Clipboard: \(clip).") }
    case .noClipboard:
        personaPart = c.persona ?? ""
        let a = appContextProse(app: c.app, windowTitle: c.windowTitle)
        if !a.isEmpty { ctxBits.append(a) }
    case .noPersona:
        personaPart = ""
        let a = appContextProse(app: c.app, windowTitle: c.windowTitle)
        if !a.isEmpty { ctxBits.append(a) }
        if let clip = c.clipboard, !clip.isEmpty { ctxBits.append("Clipboard: \(clip).") }
    case .noApp:
        personaPart = c.persona ?? ""
        if let clip = c.clipboard, !clip.isEmpty { ctxBits.append("Clipboard: \(clip).") }
    case .tailOnly:
        personaPart = ""
        ctxBits = []
    }

    var parts: [String] = []
    let trimmedPersona = personaPart.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedPersona.isEmpty { parts.append(trimmedPersona) }
    let ctx = ctxBits.joined(separator: " ")
    if !ctx.isEmpty { parts.append(ctx) }
    var preamble = parts.isEmpty ? "" : parts.joined(separator: "\n\n") + "\n\n"

    // PRIMER (FIM lever): a leading "clean prose" frame to nudge the base model
    // out of "web-document continuation" register. LlamaProbe found a primer can
    // flip a generic opener toward a coherent one. Prepended ahead of preamble.
    if cfg.primer {
        preamble = "Voici un message écrit dans un français correct et naturel.\n\n" + preamble
    }

    // Windowed tail (prefixWindow chars), trailing whitespace stripped exactly
    // as LlamaPromptBuilder.buildLlamaPrompt does (SentencePiece leading-space).
    var tail = String(c.before.suffix(cfg.prefixWindow))
    while let last = tail.last, last == " " || last == "\t" { tail.removeLast() }
    return preamble + tail
}

// ── Sampling per branch ──────────────────────────────────────────────────────
// Branch k uses a distinct seed; greedy (temp 0) is deterministic regardless of
// seed, so for branches>1 we force a small temperature if the config is greedy
// (otherwise all K decodes are identical). Ship-style anti-junk bans are always
// on (banMarkup/banDigitsLeading/banEmoji) — they're filters, not a gen axis.
func sampling(_ cfg: Config, branchIndex: Int) -> LlamaSampling {
    var temp = Float(cfg.temperature)
    if cfg.branches > 1 && temp == 0 { temp = 0.4 } // diversify a greedy baseline
    return LlamaSampling(
        temperature: temp,
        repeatPenalty: Float(cfg.repetitionPenalty),
        repeatLastN: 64,
        seed: UInt32(42 &+ branchIndex),
        personalizationStrength: cfg.corpus == .user ? 6 : 0,
        minP: temp > 0 ? 0.05 : 0,
        banMarkup: true,
        banDigitsLeading: true,
        banEmoji: true
    )
}

// ── Selector (branches>1) ────────────────────────────────────────────────────
// Anchored selection: prefer the candidate that shares the most lower-cased
// word tokens with the case context (grounding), NOT the most frequent
// (consensus = generic). Fallback to first non-empty.
func selectGrounded(_ cands: [String], context: String) -> Int {
    let ctxWords = Set(context.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count > 3 })
    var best = 0
    var bestScore = -1
    for (i, c) in cands.enumerated() {
        let w = c.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        let overlap = w.filter { ctxWords.contains($0) }.count
        if overlap > bestScore { bestScore = overlap; best = i }
    }
    return best
}

// ── CORRECTED selector ───────────────────────────────────────────────────────
// The old `grounding` selector was counter-productive (rewarded verbatim echo of
// the tail, sometimes elected a HARMFUL candidate). The corrected pipeline:
//   (a) HARD language filter — drop any candidate whose detected language (NL)
//       != the case's expected language. Wrong-language ghost is the worst leak.
//   (b) ANTI-ECHO — penalise Jaccard overlap of the candidate's word set vs the
//       typed tail (do NOT reward a candidate that just recopies what was typed).
//   (c) Among survivors, pick the most CONTEXT-RELEVANT / least GENERIC:
//       relevance = overlap with context words (>3 chars) MINUS echo penalty
//       MINUS a generic-opener penalty. Fallback = silence ("") if nothing passes.

/// Expected ISO language code for a case register.
func expectedLang(_ register: String) -> String {
    let r = register.lowercased()
    if r.contains("english") || r.contains("-en") || r == "en" { return "en" }
    if r.contains("spanish") || r.contains("-es") || r == "es" { return "es" }
    return "fr" // all fr-*, ood-*-fr, cuisine, email-formel-fr
}

/// NLLanguageRecognizer-based detection, restricted to {fr,en,es}. Returns nil
/// when the text is too short / ambiguous (so we don't drop on noise).
func detectLangNL(_ s: String) -> String? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t.count >= 4 else { return nil }
    let r = NLLanguageRecognizer()
    r.languageConstraints = [.french, .english, .spanish]
    r.processString(t)
    let hyp = r.languageHypotheses(withMaximum: 3)
    guard let (lang, conf) = hyp.max(by: { $0.value < $1.value }), conf >= 0.50 else { return nil }
    switch lang {
    case .french: return "fr"
    case .english: return "en"
    case .spanish: return "es"
    default: return nil
    }
}

private func wordSet(_ s: String) -> Set<String> {
    Set(s.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count > 3 })
}

/// Generic FR/EN/ES openers a base model defaults to — penalise these.
private let genericOpeners: [String] = [
    "bonjour", "coucou", "salut", "merci", "hello", "hi", "dear", "thank",
    "i'm", "i am", "as an", "je suis", "je vous", "hola", "buenos",
]

func selectCorrected(_ cands: [String], context: String, register: String) -> Int? {
    let expLang = expectedLang(register)
    let tailWords = wordSet(context)
    let ctxWords = tailWords // context relevance uses the same vocab
    var best: Int? = nil
    var bestScore = -Double.infinity
    for (i, raw) in cands.enumerated() {
        let c = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.isEmpty { continue }
        // (a) hard language filter
        if let dl = detectLangNL(c), dl != expLang { continue }
        let cw = wordSet(c)
        // (b) anti-echo: Jaccard vs the typed tail
        let echo: Double = {
            guard !cw.isEmpty, !tailWords.isEmpty else { return 0 }
            let inter = Double(cw.intersection(tailWords).count)
            let uni = Double(cw.union(tailWords).count)
            return uni > 0 ? inter / uni : 0
        }()
        // (c) context relevance (non-echo overlap): context words present in the
        // candidate that are NOT just a verbatim tail copy.
        let novelCtxOverlap = Double(cw.intersection(ctxWords).count)
        let lc = c.lowercased()
        let genericPenalty: Double = genericOpeners.contains(where: { lc.hasPrefix($0) }) ? 1.5 : 0
        // anti-generic length bonus (very short ghosts are usually filler)
        let lengthBonus = min(Double(cw.count), 4) * 0.1
        let score = novelCtxOverlap * 0.5 - echo * 2.0 - genericPenalty + lengthBonus
        if score > bestScore { bestScore = score; best = i }
    }
    return best
}

// ── POST-FILTER (deterministic, mono-decode) ─────────────────────────────────
// Applied to the SINGLE greedy candidate (not a K-branch selection). Reuses the
// SAME two logics the `corrected` K3 selector used, but as hard gates over one
// decode: trip either → silence. Returns the filter that fired ("" = passes).
//
// Two echo measures (we keep the worse of the two):
//   • Jaccard of word sets (ghost ∩ tail / ghost ∪ tail) — broad overlap.
//   • Coverage: fraction of the ghost's content words that appear in the tail's
//     LAST sentence — catches the verbatim-recopy failure ("…merci pour votre
//     retour rapide." → "Je vous remercie pour votre retour rapide.") where the
//     ghost reuses nearly all the tail's nouns/verbs even if reworded.
func lastSentence(_ s: String) -> String {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    // Split on sentence terminators; take the final non-empty fragment, OR the
    // whole tail when there's no terminator (single-clause tail).
    let parts = trimmed.split(whereSeparator: { ".!?…".contains($0) })
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    return parts.last ?? trimmed
}

func echoScore(ghost: String, tail: String) -> Double {
    let g = wordSet(ghost)
    let t = wordSet(tail)
    guard !g.isEmpty else { return 0 }
    let jaccard: Double = {
        guard !t.isEmpty else { return 0 }
        let inter = Double(g.intersection(t).count)
        let uni = Double(g.union(t).count)
        return uni > 0 ? inter / uni : 0
    }()
    let lastW = wordSet(lastSentence(tail))
    let coverage: Double = lastW.isEmpty ? 0 : Double(g.intersection(lastW).count) / Double(g.count)
    return max(jaccard, coverage)
}

/// Returns (ghost, filterTriggered). filterTriggered ∈ {"", "anti-echo", "lang"}.
/// "" means the candidate passed both gates and is kept verbatim.
func applyPostFilter(_ cfg: Config, ghost raw: String, context: String, register: String, position: String) -> (String, String) {
    let g = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if g.isEmpty { return ("", "") } // already silent
    // (a) anti-echo — recopy of the typed tail wins the user 0 keystrokes. ONLY
    // at a sentence BOUNDARY: mid-sentence/mid-word continuations legitimately
    // reuse the preceding clause's vocabulary, so echo there is expected, not a
    // recopy. Gating on position keeps the control (mid-*) path untouched.
    if position == "boundary" {
        let echo = echoScore(ghost: g, tail: context)
        if echo >= cfg.echoThreshold { return ("", "anti-echo") }
    }
    // (b) hard language filter — wrong-language ghost is the worst leak.
    if let dl = detectLangNL(g), dl != expectedLang(register) { return ("", "lang") }
    return (raw, "")
}

func selectIndex(_ cfg: Config, cands: [String], context: String, register: String) -> Int? {
    switch cfg.selector {
    case .first: return 0
    case .longest: return cands.enumerated().max(by: { $0.element.count < $1.element.count })?.offset ?? 0
    case .grounding: return selectGrounded(cands, context: context)
    case .corrected: return selectCorrected(cands, context: context, register: register)
    }
}

// ── Engine driver ────────────────────────────────────────────────────────────
final class Sink: @unchecked Sendable { var s = "" }

func generateOne(_ engine: LlamaEngine, prompt: String, _ smp: LlamaSampling, maxTokens: Int) async -> String {
    let sink = Sink()
    _ = await engine.generate(prompt: prompt, maxTokens: maxTokens, sampling: smp) { t in
        sink.s += t; return true
    }
    // First line only (mirrors the app's one-line cut).
    return sink.s.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? sink.s
}

// ── MID-WORD continuation generator ──────────────────────────────────────────
// Drives the SAME engine as production mid-word (ModelRuntime.runEscalationPass),
// reusing `healPrefix` so the WHOLE word is re-derived from a clean boundary
// ("Dans la phi" → " losophie, la vérité est"), NOT a broken split. UNLIKE the
// escalation pass — which caps at ~4 tokens and KEEPS only the lead word — we
// generate to the full word-budget cap and KEEP the full continuation, so the
// caller can slice C0 (lead word) vs C1/C2 (word + continuation). One-line cut
// mirrors the app. The `partial` is the trailing partial word of the typed tail
// (OutputFilter.trailingPartialWord), exactly what production hands the engine.
func generateMidWord(_ engine: LlamaEngine, prompt: String, partial: String,
                     temperature: Float, seed: UInt32, maxTokens: Int) async -> String {
    let sink = Sink()
    let smp = LlamaSampling(
        temperature: temperature,
        repeatPenalty: 1.3,
        repeatLastN: 64,
        seed: seed,
        personalizationStrength: 0,
        topP: temperature > 0 ? 0.9 : 0,
        minP: temperature > 0 ? 0.05 : 0,
        banMarkup: true,
        banDigitsLeading: true,
        banEmoji: true,
        healPrefix: partial.isEmpty ? nil : partial
    )
    _ = await engine.generate(prompt: prompt, maxTokens: maxTokens, sampling: smp) { t in
        sink.s += t; return true
    }
    return sink.s.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? sink.s
}

// JSON-escape a string for manual JSONL emission (Encodable is used for structs;
// here we emit one flat record per (config, case) by encoding a dictionary).
struct Record: Codable {
    var config: String
    var caseId: String
    var register: String
    var ood: Bool
    var preamble: String
    var corpus: String
    var branches: Int
    var selector: String
    var position: String
    var context: String
    var acceptableIntentions: [String]
    var prompt: String
    var ghost: String
    var branchOutputs: [String]
    /// Which post-filter silenced this case (post-filter mode only):
    /// "" = passed / not in post-filter mode, "anti-echo", or "lang".
    var filterTriggered: String = ""
    /// Pre-filter greedy candidate (post-filter mode only) so the judge can see
    /// what the filter suppressed.
    var preFilterGhost: String = ""

    // ── MID-WORD continuation experiment (position=="midword" only) ──────────
    /// The trailing partial word handed to the engine as healPrefix ("phi").
    var midWordPartial: String = ""
    /// The FULL greedy generation, word + continuation ("losophie, la vérité est").
    var ghostFullGreedy: String = ""
    /// The FULL temp0.3 generation (C2 raw).
    var ghostFullTemp03: String = ""
    /// C0 — escalation status quo: lead word ONLY (midWordLeadWordDefrag), cap'd.
    var c0LeadWord: String = ""
    /// C1 — continue greedy: full generation AFTER the de-echo / hard-lang gates.
    var c1ContinueGreedy: String = ""
    /// C2 — continue temp0.3: full generation AFTER the same gates.
    var c2ContinueTemp03: String = ""
    /// Which gate (if any) fired for C1 / C2 ("", "anti-echo", "lang").
    var c1Filter: String = ""
    var c2Filter: String = ""
}

// ── User corpus (from real history if accessible) ────────────────────────────
// corpus=user loads accepted/prose entries from the encrypted TypingHistoryStore.
// If the store is empty/unavailable, we DOCUMENT the fallback (empty corpus) and
// tag it in the record path — the harness still runs, the corpus axis is a no-op.
func loadUserCorpus() async -> [String] {
    let store = TypingHistoryStore()
    let entries = await store.allEntries()
    // Corpus = contextBefore + accepted tail, the same shape PVM feeds setCorpus.
    let texts = entries.map { e -> String in
        let ctx = e.contextBefore.trimmingCharacters(in: .whitespacesAndNewlines)
        let acc = e.accepted.trimmingCharacters(in: .whitespacesAndNewlines)
        return ctx.isEmpty ? acc : ctx + " " + acc
    }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    return Array(texts.suffix(200))
}

// ═════════════════════════════════════════════════════════════════════════
// GATE-VERDICT MEASUREMENT (false-gate rate)
// ═════════════════════════════════════════════════════════════════════════
// We DO NOT re-implement any gate logic here: we call the SAME pure functions
// production uses (SuggestionPolicy.prefixFit / lengthFit / score, Score.value,
// Score.passesGate, Tuning.gateFloor / replacementBar). The only derived field
// is `gateVerdict`, a classification of WHY a (good) continuation would be
// dropped, computed strictly from those values:
//
//   block_prefixfit0     score.value == 0  (prefixFit fell to 0 → score 0)
//   block_floor          0 < value < gateFloor (0.25)
//   keep_under_bar_risk  1-word ghost (lengthFit ≤ 0.6) whose score cannot beat
//                        a ghost held at 0.60 (i.e. value < 0.60 * replacementBar)
//   pass                 value ≥ gateFloor and not at keep-under-bar risk
//
// `boundaryType` classifies the typed tail's last char so we can attribute a
// prefixFit=0 block to the after-digit / after-punct path (SuggestionPolicy
// prefixFit ~227: after a non-whitespace non-letter tail it routes through
// isNaturalContinuationStart, which REJECTS a leading ',' → prefixFit 0).
struct GateVerdictRecord: Codable {
    var caseId: String
    var register: String
    var position: String
    var tail: String          // the windowed tail actually fed to the engine
    var lastChar: String      // last char of the tail (for boundaryType attribution)
    var boundaryType: String  // after-digit | after-letter | after-space | after-punct | empty
    var rawGhost: String      // raw greedy continuation (tailOnly, normal budget)
    var prefixFit: Float
    var lengthFit: Float
    var sourcePrior: Float
    var score: Float          // Score.value (sourcePrior * prefixFit * lengthFit)
    var passesGate: Bool
    var gateFloor: Float
    var replacementBar: Float
    var gateVerdict: String
}

func boundaryTypeOf(_ tail: String) -> (String, String) {
    guard let last = tail.last else { return ("empty", "") }
    let s = String(last)
    if last.isNumber { return ("after-digit", s) }
    if last.isLetter { return ("after-letter", s) }
    if last.isWhitespace { return ("after-space", s) }
    return ("after-punct", s)
}

/// Classify why a continuation would (not) be shown, from the pure-function
/// values only. Mirrors production: passesGate uses gateFloor; the replacement
/// bar is the churn guard a 1-word ghost must clear against an incumbent held
/// at the typical 0.60 LLM score (sourcePrior .llm).
func classifyVerdict(score: Score) -> String {
    let v = score.value
    if v == 0 { return "block_prefixfit0" }
    if v < SuggestionPolicy.Tuning.gateFloor { return "block_floor" }
    // keep_under_bar_risk: a 1-word ghost (lengthFit ≤ 0.6) that cannot beat a
    // ghost held at the canonical LLM score (0.60) under the replacement bar.
    let incumbent: Float = SuggestionPolicy.Tuning.sourcePrior[.llm] ?? 0.60
    let barTarget = incumbent * SuggestionPolicy.Tuning.replacementBar
    if score.lengthFit <= 0.6, v < barTarget { return "keep_under_bar_risk" }
    return "pass"
}

func runGateVerdictCase(_ engine: LlamaEngine, _ c: BoundaryCase) async -> GateVerdictRecord {
    // RAW ghost: tailOnly preamble, greedy, NORMAL budget (12 tokens, the prod
    // "moyen"). One-line cut mirrors the app. We use the SAME tail-windowing as
    // buildPrompt so `tail` matches exactly what the engine saw.
    let cfg = Config(name: "gateverdict", preamble: .tailOnly, maxTokens: 12,
                     temperature: 0, repetitionPenalty: 1.3, corpus: .empty,
                     primer: false, prefixWindow: 1024, branches: 1, selector: .first)
    let prompt = buildPrompt(c, cfg)
    // Recompute the exact tail (buildPrompt strips trailing spaces/tabs); for
    // tailOnly the prompt IS the tail, so prefixFit sees the real boundary.
    var tail = String(c.before.suffix(cfg.prefixWindow))
    while let last = tail.last, last == " " || last == "\t" { tail.removeLast() }

    let rawGhost = await generateOne(engine, prompt: prompt, sampling(cfg, branchIndex: 0), maxTokens: cfg.maxTokens)

    // PURE gate functions — the exact ones PVM composes.
    let pf = SuggestionPolicy.prefixFit(ghost: rawGhost, userTail: tail)
    let lf = SuggestionPolicy.lengthFit(ghost: rawGhost)
    let s = SuggestionPolicy.score(source: .llm, ghost: rawGhost, userTail: tail)
    let (bType, last) = boundaryTypeOf(tail)

    return GateVerdictRecord(
        caseId: c.id, register: c.register, position: c.position,
        tail: tail, lastChar: last, boundaryType: bType,
        rawGhost: rawGhost,
        prefixFit: pf, lengthFit: lf, sourcePrior: s.sourcePrior,
        score: s.value, passesGate: s.passesGate,
        gateFloor: SuggestionPolicy.Tuning.gateFloor,
        replacementBar: SuggestionPolicy.Tuning.replacementBar,
        gateVerdict: classifyVerdict(score: s)
    )
}

// ═════════════════════════════════════════════════════════════════════════
// MAIN
// ═════════════════════════════════════════════════════════════════════════

guard FileManager.default.fileExists(atPath: modelPath) else {
    err("MODEL NOT FOUND: \(modelPath)")
    err("Set --model <path> or SOUFFLEUSE_MODEL.")
    exit(1)
}

let engine = LlamaEngine()
err("loading model: \(modelPath)")
let loaded = await engine.load(modelPath: modelPath, contextTokens: 2048)
guard loaded else { err("LOAD FAILED"); exit(1) }
err("LOADED")

// ── GATE-VERDICT mode: measure false-gate rate, then exit ────────────────────
if gateVerdict {
    // Default cases: the two after-digit continuations from the inspector proof
    // ("…1933" → ", il écrit"), plus a 1-word after-space case ("français") to
    // exercise the keep_under_bar_risk path. A --cases file overrides these.
    var gvCases: [BoundaryCase]
    if let data = FileManager.default.contents(atPath: casesPath),
       let decoded = try? JSONDecoder().decode([DiskCase].self, from: data) {
        gvCases = decoded.map(resolveCase)
        err("gateverdict: loaded \(gvCases.count) cases from \(casesPath)")
    } else {
        gvCases = [
            resolveCase(DiskCase(id: "after-digit-1933", register: "fr-prose", inDist: true,
                context: "Le 1er février 1933", position: "boundary",
                acceptableIntentions: [", il écrit"])),
            resolveCase(DiskCase(id: "after-digit-2086", register: "fr-prose", inDist: true,
                context: "Le projet sera livré en 2086", position: "boundary",
                acceptableIntentions: [", soit dans"])),
        ]
        err("gateverdict: using built-in after-digit smoke cases (\(gvCases.count))")
    }
    let gvEncoder = JSONEncoder()
    gvEncoder.outputFormatting = []
    await engine.setCorpus([])
    for c in gvCases {
        let rec = await runGateVerdictCase(engine, c)
        if let d = try? gvEncoder.encode(rec), let line = String(data: d, encoding: .utf8) {
            print(line)
        }
    }
    err("gateverdict: DONE")
    exit(0)
}

// Load cases from disk (real schema) and resolve preamble inputs per register.
var cases: [BoundaryCase] = []
if smoke {
    cases = [
        resolveCase(DiskCase(id: "smoke-email-ood", register: "ood-email-formel-fr", inDist: false,
            context: "Bonjour Madame, je vous remercie pour votre retour rapide. ", position: "boundary",
            acceptableIntentions: ["Je reviens vers vous", "Comme convenu"])),
        resolveCase(DiskCase(id: "smoke-casual-ood", register: "ood-cuisine-voyage-fr", inDist: false,
            context: "Trop cool ce resto hier soir ! ", position: "boundary",
            acceptableIntentions: ["On y retourne quand ?", "Faut absolument y retourner"])),
        // MID-WORD continuation smoke cases (caret INSIDE a word, no trailing space).
        resolveCase(DiskCase(id: "smoke-midword-phi", register: "fr-chat-info", inDist: true,
            context: "Dans la phi", position: "midword",
            acceptableIntentions: ["losophie, la vérité est"])),
        resolveCase(DiskCase(id: "smoke-midword-confir", register: "fr-slack", inDist: true,
            context: "Je te confir", position: "midword",
            acceptableIntentions: ["me que c'est bon"])),
    ]
} else if let data = FileManager.default.contents(atPath: casesPath),
          let decoded = try? JSONDecoder().decode([DiskCase].self, from: data) {
    cases = decoded.map(resolveCase)
    err("loaded \(cases.count) cases from \(casesPath)")
} else {
    err("NO CASES: \(casesPath) missing/invalid. Use --smoke or provide a JSON array of cases.")
    exit(1)
}

// Split boundary vs control (mid-*) — control cases are the non-regression guard.
let boundaryCases = cases.filter { $0.position == "boundary" }
let controlCases = cases.filter { $0.position != "boundary" }

// ── OAT config sweep ─────────────────────────────────────────────────────────
// BASELINE = production default: full preamble, corpus=user, maxTokens 12 (moyen),
// greedy (temp 0, penalty 1.3), no primer, window 1024, K=1, selector first.
// Each variant flips EXACTLY ONE axis (one-axis-at-a-time, coordinate-ascent).
func baseline(_ name: String) -> Config {
    Config(name: name, preamble: .full, maxTokens: 12, temperature: 0,
           repetitionPenalty: 1.3, corpus: .user, primer: false,
           prefixWindow: 1024, branches: 1, selector: .first)
}
func oatSweep() -> [Config] {
    var v: [Config] = [baseline("baseline")]
    // AXIS: preamble (the headline suspect)
    for p in [PreambleMode.noClipboard, .noPersona, .noApp, .tailOnly] {
        var c = baseline("preamble-\(p.rawValue)"); c.preamble = p; v.append(c)
    }
    // AXIS: corpus
    do { var c = baseline("corpus-empty"); c.corpus = .empty; v.append(c) }
    // AXIS: maxTokens (court 6 / long 24 ; moyen=12 is baseline)
    do { var c = baseline("tokens-court"); c.maxTokens = 6; v.append(c) }
    do { var c = baseline("tokens-long"); c.maxTokens = 24; v.append(c) }
    // AXIS: sampling (temp 0.3 / 0.5 ; greedy is baseline)
    do { var c = baseline("temp-0.3"); c.temperature = 0.3; v.append(c) }
    do { var c = baseline("temp-0.5"); c.temperature = 0.5; v.append(c) }
    // AXIS: repetitionPenalty (SOUFFLEUSE_PENALTY analogue ; 1.3 baseline)
    do { var c = baseline("penalty-1.0"); c.repetitionPenalty = 1.0; v.append(c) }
    do { var c = baseline("penalty-1.6"); c.repetitionPenalty = 1.6; v.append(c) }
    // AXIS: primer FIM frame
    do { var c = baseline("primer-on"); c.primer = true; v.append(c) }
    // AXIS: prefix window
    do { var c = baseline("window-512"); c.prefixWindow = 512; v.append(c) }
    do { var c = baseline("window-2048"); c.prefixWindow = 2048; v.append(c) }
    // AXIS: branches (light K=3 in OAT, anchored grounding selector)
    do { var c = baseline("branches-3-grounding"); c.branches = 3; c.selector = .grounding; v.append(c) }
    return v
}

var configs: [Config] = []
if smoke {
    configs = [baseline("baseline-full-greedy"),
               { var c = baseline("tailOnly-greedy"); c.preamble = .tailOnly; return c }()]
} else if let cfgPath = argValue("--configs") {
    guard let data = FileManager.default.contents(atPath: cfgPath) else {
        err("CONFIGS FILE UNREADABLE: \(cfgPath)"); exit(1)
    }
    do {
        configs = try JSONDecoder().decode([Config].self, from: data)
        err("loaded \(configs.count) configs from \(cfgPath)")
    } catch {
        err("CONFIGS DECODE FAILED: \(error)"); exit(1)
    }
} else {
    configs = oatSweep()
    err("built-in OAT sweep: \(configs.count) configs")
}

// Preload user corpus once if any config needs it.
let needsUser = configs.contains { $0.corpus == .user }
var userCorpus: [String] = []
if needsUser {
    userCorpus = await loadUserCorpus()
    err("user corpus: \(userCorpus.count) entries\(userCorpus.isEmpty ? " (EMPTY → corpus axis is a no-op fallback)" : "")")
}

let encoder = JSONEncoder()
encoder.outputFormatting = []

// Control (mid-*) cases run on baseline + the preamble variants most likely to
// fix-boundary-but-break-mid (the non-regression guard). Other axes don't touch
// the mid-* path semantics, so we skip them for control to bound decode cost.
let controlConfigNames: Set<String> = ["baseline", "preamble-tailOnly", "preamble-noPersona", "preamble-noApp"]

// ── MID-WORD continuation gates (C1/C2) ──────────────────────────────────────
// The validated guards from the prior run, applied to the FULL continuation:
//   (a) anti-echo vs the typed tail — silence if the continuation just recopies
//       what's already typed (Jaccard / last-sentence coverage ≥ threshold).
//   (b) hard language filter — silence if detected language != expected.
// CRITICAL: a midword continuation legitimately re-derives the typed PARTIAL
// word ("phi"→"philosophie"), so we strip the lead word before measuring echo
// — otherwise the heal'd word itself trips the anti-echo gate. We measure echo
// on the CONTINUATION only (the text AFTER the completed lead word).
func midWordGate(_ cfg: Config, full raw: String, leadWord: String,
                 context: String, register: String) -> (String, String) {
    let g = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if g.isEmpty { return ("", "") }
    // Continuation = full minus the lead word prefix (best-effort; lead word may
    // contain a healed partial, so match on the trimmed lead word substring).
    let lead = leadWord.trimmingCharacters(in: .whitespacesAndNewlines)
    var continuation = g
    if !lead.isEmpty, let r = g.range(of: lead) { continuation = String(g[r.upperBound...]) }
    // (a) anti-echo on the continuation only.
    let echo = echoScore(ghost: continuation, tail: context)
    if echo >= cfg.echoThreshold { return ("", "anti-echo") }
    // (b) hard language on the FULL ghost (a wrong-language continuation leaks).
    if let dl = detectLangNL(g), dl != expectedLang(register) { return ("", "lang") }
    return (raw, "")
}

func runMidWordCase(_ engine: LlamaEngine, _ c: BoundaryCase, _ cfg: Config) async -> Record {
    let prompt = buildPrompt(c, cfg)
    // Partial = trailing partial word of the typed tail (prod parity:
    // ModelRuntime.generateLlama → OutputFilter.trailingPartialWord).
    let partial = OutputFilter.trailingPartialWord(c.before)
    // maxWords-equivalent cap: use the config's maxTokens as the full budget
    // (baseline 12 ≈ "moyen"), unlike the escalation's ~4-token clamp.
    let fullGreedy = await generateMidWord(engine, prompt: prompt, partial: partial,
                                           temperature: 0, seed: 42, maxTokens: cfg.maxTokens)
    let fullTemp03 = await generateMidWord(engine, prompt: prompt, partial: partial,
                                           temperature: 0.3, seed: 42, maxTokens: cfg.maxTokens)
    // C0 = lead-word defrag of the greedy full (= what the escalation keeps today).
    let lead = SuggestionPolicy.midWordLeadWordDefrag(fullGreedy, partial: partial)
    // C1 = greedy full + gates ; C2 = temp0.3 full + gates.
    let (c1, c1f) = midWordGate(cfg, full: fullGreedy, leadWord: lead, context: c.before, register: c.register)
    let leadT = SuggestionPolicy.midWordLeadWordDefrag(fullTemp03, partial: partial)
    let (c2, c2f) = midWordGate(cfg, full: fullTemp03, leadWord: leadT, context: c.before, register: c.register)
    var rec = Record(
        config: cfg.name, caseId: c.id, register: c.register, ood: c.ood,
        preamble: cfg.preamble.rawValue, corpus: cfg.corpus.rawValue,
        branches: 1, selector: cfg.selector.rawValue, position: c.position,
        context: c.before, acceptableIntentions: c.acceptableIntentions,
        prompt: prompt, ghost: c1, branchOutputs: [fullGreedy, fullTemp03]
    )
    rec.midWordPartial = partial
    rec.ghostFullGreedy = fullGreedy
    rec.ghostFullTemp03 = fullTemp03
    rec.c0LeadWord = lead
    rec.c1ContinueGreedy = c1
    rec.c2ContinueTemp03 = c2
    rec.c1Filter = c1f
    rec.c2Filter = c2f
    return rec
}

func runCase(_ engine: LlamaEngine, _ c: BoundaryCase, _ cfg: Config) async -> Record {
    if c.position == "midword" { return await runMidWordCase(engine, c, cfg) }
    let prompt = buildPrompt(c, cfg)
    var branchOutputs: [String] = []
    let k = max(1, cfg.branches)
    for b in 0..<k {
        let g = await generateOne(engine, prompt: prompt, sampling(cfg, branchIndex: b), maxTokens: cfg.maxTokens)
        branchOutputs.append(g)
    }
    let idx = selectIndex(cfg, cands: branchOutputs, context: c.before, register: c.register)
    // Corrected selector returns nil → silence fallback (nothing passed the filters).
    var ghost: String
    if let idx, !branchOutputs.isEmpty {
        ghost = branchOutputs[min(idx, branchOutputs.count - 1)]
    } else {
        ghost = ""
    }
    // POST-FILTER mode: gate the (single greedy) candidate deterministically.
    var filterTriggered = ""
    var preFilterGhost = ""
    if cfg.postFilter {
        preFilterGhost = ghost
        let (filtered, trip) = applyPostFilter(cfg, ghost: ghost, context: c.before, register: c.register, position: c.position)
        ghost = filtered
        filterTriggered = trip
    }
    return Record(
        config: cfg.name, caseId: c.id, register: c.register, ood: c.ood,
        preamble: cfg.preamble.rawValue, corpus: cfg.corpus.rawValue,
        branches: k, selector: cfg.selector.rawValue, position: c.position,
        context: c.before, acceptableIntentions: c.acceptableIntentions,
        prompt: prompt, ghost: ghost, branchOutputs: branchOutputs,
        filterTriggered: filterTriggered, preFilterGhost: preFilterGhost
    )
}

func emit(_ rec: Record) {
    if let d = try? encoder.encode(rec), let line = String(data: d, encoding: .utf8) { print(line) }
}

for cfg in configs {
    await engine.setCorpus(cfg.corpus == .user ? userCorpus : [])
    for c in boundaryCases { emit(await runCase(engine, c, cfg)) }
    if smoke || allControl || controlConfigNames.contains(cfg.name) {
        for c in controlCases { emit(await runCase(engine, c, cfg)) }
    }
    err("config \(cfg.name): done")
}

err("DONE")
exit(0)
