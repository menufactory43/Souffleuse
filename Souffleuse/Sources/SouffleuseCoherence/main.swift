import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import SouffleusePrompt
import Tokenizers

// Simule un utilisateur qui tape une phrase cible lettre par lettre, et vérifie
// à CHAQUE point d'arrêt (mi-mot + frontière de mot) ce que le ghost propose,
// en rejouant FIDÈLEMENT le pipeline prod :
//   - gates  : ≥3 chars + hasCompletedFirstWord
//   - modèle : greedy temp=0, repetitionPenalty=1.0 (config PROD, pas 1.15 du bench)
//   - affichage : stripPrefixOverlap + strip newline/HTML/markdown + troncature
//                 phrase/virgule + cap maxWords + anti-repeat → ghost vide
//
// Score par étape :
//   MATCH  : le ghost prédit exactement la suite réelle (la suite commence par le ghost)
//   ALT    : ghost non vide mais ≠ la suite (alternative plausible OU faux)
//   EMPTY  : ghost vide (anti-repeat a tué, ou modèle muet) → l'user voit RIEN
//   GATED  : la prod ne déclenche pas (trop court / 1er mot pas fini) → RIEN
//
// Limite assumée : on compare à UNE seule cible. Une continuation valide mais
// différente compte ALT, pas MATCH. Utile en relatif + pour repérer EMPTY/GATED/junk.

// MARK: - Pipeline prod répliqué (miroir de PredictorViewModel)

enum Prod {
    static let maxWords = 4
    static let maxTokens = 12

    static func hasCompletedFirstWord(_ s: String) -> Bool {
        var sawWord = false
        for c in s {
            if c.isLetter || c.isNumber || c == "'" || c == "’" || c == "-" {
                sawWord = true
            } else if sawWord {
                return true
            }
        }
        return false
    }

    static func stripPrefixOverlap(_ snapshot: String, prefix: String) -> String {
        let maxLen = min(prefix.count, snapshot.count)
        if maxLen == 0 { return snapshot }
        var len = maxLen
        while len >= 2 {
            let suffix = prefix.suffix(len)
            if snapshot.hasPrefix(suffix) { return String(snapshot.dropFirst(len)) }
            len -= 1
        }
        return snapshot
    }

    static func normalizeForRepeatCheck(_ s: String) -> String {
        let lowered = s.lowercased()
        var out = ""
        var lastWasSpace = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber { out.append(ch); lastWasSpace = false }
            else if !lastWasSpace { out.append(" "); lastWasSpace = true }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func stripTrailingPartialWord(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            let c = s[prev]
            if c.isLetter || c.isNumber || c == "'" || c == "’" || c == "-" { end = prev }
            else { break }
        }
        return String(s[..<end])
    }

    static func ghostIsRepeatingPrefix(_ ghost: String, prefix: String) -> Bool {
        let g = normalizeForRepeatCheck(String(ghost.prefix(60)))
        guard g.count >= 4 else { return false }
        let trimmed = stripTrailingPartialWord(prefix)
        let p = normalizeForRepeatCheck(String(trimmed.suffix(120)))
        var k = min(g.count, 60)
        while k >= 4 {
            if p.contains(String(g.prefix(k))) { return true }
            k -= 1
        }
        return false
    }

    /// Applique exactement la chaîne de trimming de `onChunk`. Renvoie le ghost
    /// tel que l'utilisateur le verrait (ou "" si anti-repeat / vide).
    static func displayGhost(rawSnapshot: String, prefix: String) -> String {
        let snapshot = stripPrefixOverlap(rawSnapshot, prefix: prefix)
        let stripped = snapshot.drop(while: { $0 == "\n" || $0 == "\r" })
        var oneLine: String
        if let nl = stripped.firstIndex(of: "\n") { oneLine = String(stripped[..<nl]) }
        else { oneLine = String(stripped) }
        oneLine = oneLine.replacingOccurrences(
            of: "<[/!?]?[A-Za-z][A-Za-z0-9]{0,15}\\s*[^>]{0,32}>",
            with: "", options: .regularExpression)
        oneLine = oneLine.replacingOccurrences(of: "**", with: "")
        oneLine = oneLine.replacingOccurrences(of: "__", with: "")
        oneLine = oneLine.replacingOccurrences(of: "`", with: "")
        if oneLine.count > 3 {
            for terminator in [". ", "? ", "! ", "… "] {
                if let r = oneLine.range(of: terminator) {
                    oneLine = String(oneLine[..<r.upperBound]).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
        }
        if oneLine.count > 12, let r = oneLine.range(of: ", ") {
            oneLine = String(oneLine[..<r.lowerBound])
        }
        let words = oneLine.split(whereSeparator: { $0.isWhitespace })
        if words.count > maxWords { oneLine = words.prefix(maxWords).joined(separator: " ") }
        if ghostIsRepeatingPrefix(oneLine, prefix: prefix) { return "" }
        return oneLine
    }
}

// MARK: - Cas de test

struct Target { let label: String; let text: String; var lead: String = "" }

// SOUFFLEUSE_CONTEXT=1 → préfixe chaque cible d'un contexte amont réaliste
// (texte déjà présent dans le champ). Sinon champ vierge (cold start).
let useContext = !(ProcessInfo.processInfo.environment["SOUFFLEUSE_CONTEXT"] ?? "").isEmpty

let targets: [Target] = [
    Target(label: "FR salutation", text: "Bonjour, comment allez-vous ?",
           lead: useContext ? "" : ""),
    Target(label: "FR merci", text: "Merci beaucoup pour ton retour rapide.",
           lead: useContext ? "Salut Paul, j'ai bien reçu le document que tu m'as envoyé hier soir. " : ""),
    Target(label: "FR rdv", text: "Je te confirme notre rendez-vous de demain.",
           lead: useContext ? "Bonjour Marie, suite à notre échange de ce matin. " : ""),
    Target(label: "FR contact", text: "N'hésite pas à me contacter si besoin.",
           lead: useContext ? "Voilà, je t'ai tout expliqué dans le mail précédent. " : ""),
    Target(label: "FR retard", text: "Je suis désolé pour le retard de ma réponse.",
           lead: useContext ? "Bonjour, je reviens vers vous concernant votre demande. " : ""),
    Target(label: "FR revient", text: "Je vais regarder ça et je reviens vers toi.",
           lead: useContext ? "Ok j'ai vu ton message à propos du bug sur la page de paiement. " : ""),
    Target(label: "EN review", text: "hey, can you review my pull request please",
           lead: useContext ? "I just finished the refactor we talked about in standup. " : ""),
    Target(label: "EN thanks", text: "thanks a lot for the quick reply, really appreciate it",
           lead: useContext ? "Got it, that solved my problem completely. " : ""),
]

// MARK: - Points d'arrêt (mi-mot + frontières)

func breakpoints(_ text: String) -> [Int] {
    let chars = Array(text)
    var pts = Set<Int>()
    var i = 0
    func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "’" || c == "-" }
    while i < chars.count {
        if isWord(chars[i]) {
            let start = i
            var j = i
            while j < chars.count, isWord(chars[j]) { j += 1 }
            let len = j - start
            if len >= 4 { pts.insert(start + len / 2) }   // point mi-mot
            // frontière : début du mot suivant (inclut les séparateurs)
            if j < chars.count { pts.insert(j + leadingSepCount(chars, from: j)) }
            i = j
        } else { i += 1 }
    }
    return pts.filter { $0 >= 1 && $0 < chars.count }.sorted().prefix(14).map { $0 }
}

func leadingSepCount(_ chars: [Character], from: Int) -> Int {
    var n = 0
    var k = from
    func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "’" || c == "-" }
    while k < chars.count, !isWord(chars[k]) { n += 1; k += 1 }
    return n
}

// MARK: - Génération brute (config PROD : penalty 1.0)

let penalty: Float = Float(ProcessInfo.processInfo.environment["SOUFFLEUSE_PENALTY"] ?? "") ?? 1.0

// Cotypist-style prompt wrapper. Set SOUFFLEUSE_COTYPIST_STYLE=1 to wrap each
// prefix with the user's actual prod persona + `My writing: ` label before
// passing it to MLX. Used to test whether the format anchor shifts the model
// away from web-text degenerate modes (`@juliette`, `100000000000`, etc.) on
// short prefixes.
let cotypistStyle = !(ProcessInfo.processInfo.environment["SOUFFLEUSE_COTYPIST_STYLE"] ?? "").isEmpty
let cotypistPersona = "My name is Gabriel. I usually write in French. Write in a friendly, professional and empathetic voice. Keep your sentences short, concise and readable."

func wrappedPrefix(_ prefix: String) -> String {
    guard cotypistStyle else { return prefix }
    return "\(cotypistPersona)\n\nMy writing: \(prefix)"
}

func rawGhost(prefix: String, on container: ModelContainer) async -> String {
    let result = try? await container.perform { ctx -> String in
        let toks = ctx.tokenizer.encode(text: wrappedPrefix(prefix))
        let input = LMInput(tokens: MLXArray(toks))
        let params = GenerateParameters(
            maxTokens: Prod.maxTokens, temperature: 0, topP: 0.9,
            repetitionPenalty: penalty, repetitionContextSize: 32)
        let stream = try MLXLMCommon.generate(input: input, parameters: params, context: ctx)
        var out = ""
        for await ev in stream { if case .chunk(let t) = ev { out += t } }
        return out
    }
    return result ?? ""
}

// MARK: - Classification

enum Verdict: String { case match = "MATCH", alt = "ALT", empty = "EMPTY", gated = "GATED" }

func classify(prefix: String, ghost: String, remaining: String, fired: Bool) -> Verdict {
    if !fired { return .gated }
    if ghost.isEmpty { return .empty }
    if remaining.lowercased().hasPrefix(ghost.lowercased()) { return .match }
    return .alt
}

@Sendable func emit(_ s: String) {
    FileHandle.standardOutput.write(Data((s + "\n").utf8))
}

// MARK: - Replay harness (--replay sub-command)

/// One curated scenario. Schema per D-07 (CONTEXT.md) and §7 (RESEARCH.md).
/// Phase 2 (Plan 02-05) adds 5 optional fields to exercise the new high-signal
/// slots (`fieldContext`, `afterCursor`). All new fields are `Optional` so the
/// v1 scenarios in `replay-scenarios.json` decode unchanged — `ScenarioFile.version`
/// stays at 1.
struct Scenario: Codable, Sendable {
    let id: String
    let label: String
    let bundleID: String
    let windowTitle: String?
    let contextPrefix: String
    let userTail: String
    let notes: String?
    let customInstructions: String?
    // ── Phase 2 additions (optional — v1 scenarios decode unchanged) ──
    let role: String?
    let subrole: String?
    let placeholder: String?
    let help: String?
    let textAfterCaret: String?
    // ── Phase 4 v2 (optional — v1 scenarios decode unchanged) ──
    // Auto-classification baseline for D-12 confusion matrix.
    let expectedCategory: ExpectedCategory?
    let expectedGhostPrefix: String?
}

/// Top-level scenario file (versioned per project's persisted-config convention,
/// cf. `AllowlistFile` in Sources/Souffleuse/AllowlistConfig.swift).
/// `version`: 1 (Phase 1) or 2 (Phase 4 — adds optional `expectedCategory` +
/// `expectedGhostPrefix` on `Scenario`). v1 files decode unchanged because the
/// new fields are `Optional` and Swift's synthesised `Codable` tolerates missing
/// keys for Optionals.
struct ScenarioFile: Codable, Sendable {
    let version: Int   // v1 or v2; v2 adds optional expectedCategory + expectedGhostPrefix
    let scenarios: [Scenario]
}

/// Expected outcome category for a replay scenario. Drives the D-12 confusion
/// matrix in `renderReplayResults`. Values mirror the quality grid in
/// `04-RESEARCH.md`:
/// - `correct` : ghost begins with `expectedGhostPrefix` (case-insensitive).
/// - `acceptable` : ghost non-empty, doesn't match the prefix but plausible.
/// - `useless` : ghost empty (anti-repeat killed, model silent).
/// - `bad` : harmful output — requires human signal, untestable in replay.
/// - `parasite` : appears mid-conversation — untestable in single-pass replay.
/// - `skip` : no `expectedGhostPrefix` set → cannot auto-classify.
enum ExpectedCategory: String, Codable, Sendable, CaseIterable {
    case correct
    case acceptable
    case useless
    case bad
    case parasite
    case skip
}

/// Naive single-pass classifier for the D-12 confusion matrix.
///
/// Returns `.skip` when no `expectedPrefix` is provided (cannot judge).
/// Returns `.useless` when the ghost is empty (user sees nothing).
/// Returns `.correct` when the ghost begins with `expectedPrefix`
/// (case-insensitive — covers minor capitalization variance from LLM output).
/// Returns `.acceptable` otherwise — a plausible-but-different completion.
///
/// `.bad` and `.parasite` require human signal and are intentionally NOT
/// emitted by this helper. Live-production logging is the source of truth
/// for those categories.
func classifyReplayGhost(ghost: String, expectedPrefix: String?) -> ExpectedCategory {
    guard let expected = expectedPrefix, !expected.isEmpty else { return .skip }
    if ghost.isEmpty { return .useless }
    if ghost.lowercased().hasPrefix(expected.lowercased()) { return .correct }
    return .acceptable
}

/// Local TokenCounting impl mirroring `MLXTokenCounter` from the Souffleuse
/// app target. Duplicated here per Phase 1 simplicity (RESEARCH §6). Phase 2
/// candidate: extract to a shared `SouffleusePrompt`-public adapter.
/// TODO Phase 2: dedupe with Sources/Souffleuse/MLXTokenCounter.swift.
struct CoherenceTokenCounter: TokenCounting {
    let tokenizer: any Tokenizer

    func countTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return tokenizer.encode(text: text).count
    }

    func truncateHead(_ text: String, toBudget budget: Int) -> String {
        guard budget >= 1 else { return "" }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        if countTokens(trimmed) <= budget { return trimmed }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return "" }
        let sentenceEnds: Set<Character> = [".", "?", "!", "…"]
        for cutWordIdx in 1..<words.count {
            let prev = words[cutWordIdx - 1]
            guard let last = prev.last, sentenceEnds.contains(last) else { continue }
            let suffix = words[cutWordIdx...].joined(separator: " ")
            if countTokens(suffix) <= budget { return suffix }
        }
        for cutWordIdx in 1..<words.count {
            let suffix = words[cutWordIdx...].joined(separator: " ")
            if countTokens(suffix) <= budget { return suffix }
        }
        return ""
    }
}

/// Run a single scenario through the PromptBuilder pipeline, returning the
/// displayed ghost. `contextPrefix` parameter lets the caller disable it for
/// the WITHOUT-context variant without mutating the scenario.
func replayScenario(
    _ s: Scenario,
    contextPrefix: String,
    container: ModelContainer
) async -> String {
    let result = try? await container.perform { ctx -> String in
        let counter = CoherenceTokenCounter(tokenizer: ctx.tokenizer)
        let builder = PromptBuilder(counter: counter, budget: .phase2Default)
        // Simplified system prompt (see W5 caveat in REPLAY-RESULTS.md): the
        // production `PredictorViewModel.buildSystemPrompt(detectedLanguage:)`
        // injects detected-language framing; here we ship a stable minimal
        // string so the verdict measures the EFFECT OF contextPrefix only.
        let system = "You are an inline autocomplete. Continue the user's text naturally."

        // Phase 2 slot bodies — mirror the PredictorViewModel slot-construction
        // logic from Plan 02-04 (helper duplication acceptable per 02-PATTERNS.md
        // `// TODO Phase 2: dedupe` precedent). Each line is conditional on the
        // presence of the corresponding scenario field (D-15c); the slot is
        // skipped entirely if no field produces a value (D-15).
        let fieldContextSlot: String = {
            var lines: [String] = []
            if let label = PromptBuilder.roleLabelFR(role: s.role, subrole: s.subrole) {
                lines.append("Champ : \(label).")
            }
            if let placeholder = s.placeholder?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !placeholder.isEmpty {
                lines.append("Placeholder : « \(placeholder) ».")
            }
            if let help = s.help?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !help.isEmpty {
                lines.append("Aide : « \(help) ».")
            }
            return lines.joined(separator: "\n")
        }()

        // afterCursor slot body — D-14 FR prose-delimited format. Skip entirely
        // if the scenario carries no `textAfterCaret` (D-14c — no empty header
        // injected to avoid spurious signal).
        let afterCursorSlot: String = {
            guard let after = s.textAfterCaret?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !after.isEmpty else { return "" }
            return "Suite du texte (à ne pas répéter) : « \(after) »."
        }()

        let built = builder.build(
            system: system,
            customInstructions: s.customInstructions ?? "",
            contextPrefix: contextPrefix,
            fieldContext: fieldContextSlot,
            afterCursor: afterCursorSlot,
            previousUserInputs: "",         // Phase 1: few-shot not exercised in replay
            beforeCursor: s.userTail
        )
        let toks = ctx.tokenizer.encode(text: built.text)
        let input = LMInput(tokens: MLXArray(toks))
        let params = GenerateParameters(
            maxTokens: Prod.maxTokens,
            temperature: 0,
            topP: 0.9,
            repetitionPenalty: 1.0,
            repetitionContextSize: 32
        )
        let stream = try MLXLMCommon.generate(
            input: input, parameters: params, context: ctx
        )
        var raw = ""
        for await ev in stream {
            if case .chunk(let t) = ev { raw += t }
        }
        return raw
    }
    let rawSnapshot = result ?? ""
    return Prod.displayGhost(rawSnapshot: rawSnapshot, prefix: s.userTail)
}

/// Load scenarios from JSON file.
func loadScenarios(from path: String) throws -> ScenarioFile {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(ScenarioFile.self, from: data)
}

/// Generate the REPLAY-RESULTS.md markdown.
func renderReplayResults(
    modelId: String,
    results: [(scenario: Scenario, withoutCtx: String, withCtx: String)]
) -> String {
    let iso = ISO8601DateFormatter().string(from: Date())
    var out = """
    # Replay Results — Phase 1 Hypothesis Validation

    **Generated:** \(iso)
    **Model:** \(modelId)
    **Scenarios:** \(results.count)
    **Founding hypothesis under test:** « le ghost junk vient du prompt pauvre, pas du modèle ».

    Pour chaque scénario : le ghost produit SANS contexte (`contextPrefix=""`)
    vs AVEC contexte (`contextPrefix` du scénario). Eyeball verdict : ✓ si
    avec-contexte est plus pertinent, = si neutre, ✗ si moins pertinent.

    > **Caveat — système prompt** (W5) : le system prompt utilisé en replay
    > est une version simplifiée (`"You are an inline autocomplete. Continue
    > the user's text naturally."`) — la version production passe par
    > `PredictorViewModel.buildSystemPrompt(detectedLanguage:)` qui injecte
    > la langue détectée et un framing plus riche. Le verdict porte donc sur
    > l'EFFET DU `contextPrefix` (with vs without), pas sur la parité prompt
    > complète production.

    > **Caveat — paramètres génération** (W6) : `temperature=0`, `topP=0.9`,
    > `repetitionPenalty=1.0`, `maxTokens=12`. Peuvent différer des prefs
    > runtime utilisateur (qui modulent `maxTokens` via la pref "Court /
    > Moyen / Long").

    ---

    """

    // ── Phase 4 D-12 — Confusion Matrix ────────────────────────────────
    // Auto-classify each scenario's WITH-context ghost against its
    // `expectedGhostPrefix`. `expectedCategory` is the human-annotated
    // baseline ; `actual` is what `classifyReplayGhost` emits.
    struct Classified {
        let scenario: Scenario
        let actual: ExpectedCategory
    }
    let classified: [Classified] = results.map { r in
        Classified(
            scenario: r.scenario,
            actual: classifyReplayGhost(
                ghost: r.withCtx,
                expectedPrefix: r.scenario.expectedGhostPrefix
            )
        )
    }
    let categoriesForMatrix: [ExpectedCategory] = [.correct, .acceptable, .useless, .bad]
    out += "## Confusion Matrix (D-12)\n\n"
    out += "Rows: human-annotated `expectedCategory`. Columns: `classifyReplayGhost` actual.\n"
    out += "Scenarios with no `expectedCategory` (or `skip`) are excluded from the rows but\n"
    out += "still contribute to the per-scenario detail table below.\n\n"
    out += "| expected \\ actual | correct | acceptable | useless | bad | total |\n"
    out += "|--------------------|---------|------------|---------|-----|-------|\n"
    for expectedCat in categoriesForMatrix {
        let row = classified.filter { $0.scenario.expectedCategory == expectedCat }
        let c = row.filter { $0.actual == .correct }.count
        let a = row.filter { $0.actual == .acceptable }.count
        let u = row.filter { $0.actual == .useless }.count
        let b = row.filter { $0.actual == .bad }.count
        let total = c + a + u + b
        out += "| **expected: \(expectedCat.rawValue)** | \(c) | \(a) | \(u) | \(b) | \(total) |\n"
    }
    let tc = classified.filter { $0.actual == .correct }.count
    let ta = classified.filter { $0.actual == .acceptable }.count
    let tu = classified.filter { $0.actual == .useless }.count
    let tb = classified.filter { $0.actual == .bad }.count
    let grandTotal = classified.count
    out += "| **total**          | \(tc) | \(ta) | \(tu) | \(tb) | \(grandTotal) |\n\n"

    // ── Release gate D-11 simulation ──────────────────────────────────
    // parasite is untestable in single-pass replay → only correct + lowQuality
    // (useless + bad) ratios are computed here. The third leg of the gate
    // (`parasite ≤ 5%`) is enforced via live-production logging.
    let correctRate = Double(tc) / Double(max(1, grandTotal))
    let lowQualityRate = Double(tu + tb) / Double(max(1, grandTotal))
    out += "### Release gate D-11 (simulated on replay — parasite untestable in single-pass)\n\n"
    out += "- \(correctRate >= 0.30 ? "✓" : "✗") correct/total ≥ 30% → \(tc)/\(grandTotal) = \(String(format: "%.1f", correctRate * 100))%\n"
    out += "- \(lowQualityRate <= 0.35 ? "✓" : "✗") (useless+bad)/total ≤ 35% → \(tu + tb)/\(grandTotal) = \(String(format: "%.1f", lowQualityRate * 100))%\n"
    out += "- parasite/total ≤ 5% — untestable in single-pass replay (live production only)\n\n"
    out += "---\n\n"

    // Per-scenario classification map for the detail table below.
    let actualByID: [String: ExpectedCategory] = Dictionary(
        uniqueKeysWithValues: classified.map { ($0.scenario.id, $0.actual) }
    )

    for (i, r) in results.enumerated() {
        let safeUserTail = r.scenario.userTail
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "\n", with: "⏎")
        let safeWithout = r.withoutCtx
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "\n", with: "⏎")
        let safeWith = r.withCtx
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "\n", with: "⏎")
        let expectedCatStr = r.scenario.expectedCategory.map { $0.rawValue } ?? "—"
        let actualCatStr = actualByID[r.scenario.id]?.rawValue ?? "—"
        let expectedPrefixStr = r.scenario.expectedGhostPrefix
            .map { "`\($0)`" } ?? "—"
        out += """

        ## \(i + 1). [\(r.scenario.id)] \(r.scenario.label)

        - **bundleID:** `\(r.scenario.bundleID)`
        - **windowTitle:** \(r.scenario.windowTitle.map { "`\($0)`" } ?? "—")
        - **userTail:** `\(safeUserTail)`
        - **notes:** \(r.scenario.notes ?? "—")
        - **expectedCategory:** \(expectedCatStr)
        - **expectedGhostPrefix:** \(expectedPrefixStr)
        - **actual category (D-12):** \(actualCatStr)

        | Variant | Ghost | Actual category |
        |---------|-------|-----------------|
        | **WITHOUT context** | `\(safeWithout)` | — |
        | **WITH context**    | `\(safeWith)` | \(actualCatStr) |

        **Verdict:** [ ] ✓ with-context better  [ ] = neutral  [ ] ✗ with-context worse

        **Human note:** _(fill in)_

        ---

        """
    }
    out += """

    ## Tally (fill in after eyeball pass)

    - ✓ with-context better: ___ / \(results.count)
    - = neutral:              ___ / \(results.count)
    - ✗ with-context worse:   ___ / \(results.count)

    **AUDIT-02 gate (planner-set):** ≥ 6 / \(results.count) ✓ verdicts to proceed to Phase 2.

    """
    return out
}

/// Replay sub-command entry point. Caller has already loaded the model (or
/// skipped MLX entirely in dry-run mode).
/// If `outPath` is non-nil it is used verbatim as the REPLAY-RESULTS.md
/// destination; otherwise we fall back to the legacy colocated-with-scenarios
/// path (Phase 1 behaviour preserved for v1 callers — B-2, Plan 02-05).
///
/// `dryRun=true` skips MLX inference entirely: both `withoutCtx` and `withCtx`
/// are produced via a deterministic stub (empty string). This lets CI and
/// worktree environments — which lack the MLX `metallib` bundled by
/// `make-app.sh` — validate the markdown structure of the confusion matrix
/// without GPU access. The release-gate D-11 verdict in dry-run mode will
/// always be ✗ (100% useless) but the table shape is asserted equal to the
/// production-run shape (Phase 4 Plan 04-10).
func runReplay(
    scenariosPath: String,
    outPath: String? = nil,
    modelId: String,
    container: ModelContainer?,
    dryRun: Bool = false
) async {
    let file: ScenarioFile
    do {
        file = try loadScenarios(from: scenariosPath)
    } catch {
        emit("ERREUR chargement scenarios: \(error)")
        return
    }
    let modeLabel = dryRun ? "DRY-RUN (no MLX)" : "modèle \(modelId)"
    emit("Replay: \(file.scenarios.count) scénarios — \(modeLabel)")
    var results: [(scenario: Scenario, withoutCtx: String, withCtx: String)] = []
    for (i, s) in file.scenarios.enumerated() {
        emit("[\(i + 1)/\(file.scenarios.count)] \(s.id)")
        let withoutCtx: String
        let withCtx: String
        if dryRun || container == nil {
            // No MLX available — emit deterministic empty ghosts. The confusion
            // matrix in renderReplayResults still computes useful structural
            // signal: every scenario with a non-null expectedGhostPrefix lands
            // in the `useless` column, exercising the matrix code path.
            withoutCtx = ""
            withCtx = ""
        } else {
            // Run BOTH variants sequentially (MLX is GPU-bound, parallel doesn't help).
            withoutCtx = await replayScenario(s, contextPrefix: "", container: container!)
            withCtx    = await replayScenario(s, contextPrefix: s.contextPrefix, container: container!)
        }
        emit("    WITHOUT: \"\(withoutCtx.replacingOccurrences(of: "\n", with: "⏎"))\"")
        emit("    WITH:    \"\(withCtx.replacingOccurrences(of: "\n", with: "⏎"))\"")
        results.append((s, withoutCtx, withCtx))
    }
    let md = renderReplayResults(modelId: modelId, results: results)
    let outURL: URL = {
        if let outPath {
            return URL(fileURLWithPath: outPath)
        }
        // Legacy colocated default (Phase 1 callers without --out).
        return URL(fileURLWithPath: scenariosPath)
            .deletingLastPathComponent()
            .appendingPathComponent("REPLAY-RESULTS.md")
    }()
    do {
        try Data(md.utf8).write(to: outURL, options: .atomic)
        emit("→ écrit: \(outURL.path)")
    } catch {
        emit("ERREUR écriture REPLAY-RESULTS.md: \(error)")
    }
}

@main
struct Coherence {
    static func main() async {
        setbuf(stdout, nil); setbuf(stderr, nil)
        let args = CommandLine.arguments
        let modelId = ProcessInfo.processInfo.environment["SOUFFLEUSE_MODEL"]
            ?? "mlx-community/gemma-3-1b-pt-8bit"

        // Detect --dry-run flag anywhere in args (Phase 4 Plan 04-10).
        // Dry-run skips MLX load + inference: useful in worktrees / CI lacking
        // the bundled metallib. Validates markdown structure of the confusion
        // matrix without GPU access.
        let dryRun = args.contains("--dry-run")

        // Model load — shared by both default (typing simulé) and replay paths.
        // Skipped entirely in dry-run mode.
        let container: ModelContainer?
        if dryRun {
            emit("DRY-RUN — MLX load skipped.\n")
            container = nil
        } else {
            MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
            let cfg = ModelConfiguration(id: modelId, defaultPrompt: "")
            emit("Chargement (\(modelId))…")
            do {
                container = try await LLMModelFactory.shared.loadContainer(configuration: cfg) { _ in }
            } catch {
                emit("ERREUR chargement: \(error)")
                return
            }
            emit("  prêt.\n")
        }

        // ── Sub-command dispatch ─────────────────────────────────────
        if args.count >= 3, args[1] == "--replay" {
            // Optional `--out <path>` flag may follow the scenarios path.
            // Usage:
            //   SouffleuseCoherence --replay <scenarios.json>
            //   SouffleuseCoherence --replay <scenarios.json> --out <results.md>
            //   SouffleuseCoherence --replay <scenarios.json> --out <results.md> --dry-run
            // (B-2, Plan 02-05): the explicit `--out` flag is the sole output
            // mechanism. Phase 2 callers pass it to write REPLAY-RESULTS.md
            // outside the scenarios directory; Phase 1 callers omit it and
            // get the legacy colocated default. `--dry-run` (Phase 4 04-10)
            // skips MLX inference, useful for worktree validation.
            var outPath: String? = nil
            for idx in 3..<args.count {
                if args[idx] == "--out", idx + 1 < args.count {
                    outPath = args[idx + 1]
                }
            }
            await runReplay(
                scenariosPath: args[2],
                outPath: outPath,
                modelId: modelId,
                container: container,
                dryRun: dryRun
            )
            return
        }

        // From here on, default coherence loop assumes a loaded container.
        guard let container else {
            emit("Default coherence loop requires MLX — exiting (--dry-run is replay-only).")
            return
        }

        // ── Default coherence loop (verbatim — typage simulé) ────────
        emit("──────────────────────────────────────────────")
        emit(" Coherence — typing simulé (config PROD)       ")
        emit(" modèle: \(modelId)")
        emit(" greedy temp=0 · penalty=\(penalty) · maxWords=\(Prod.maxWords)")
        emit("──────────────────────────────────────────────")

        var totals: [Verdict: Int] = [:]

        for t in targets {
            emit("[\(t.label)] « \(t.text) »")
            let chars = Array(t.text)
            for k in breakpoints(t.text) {
                let typed = String(chars[0..<k])
                let prefix = t.lead + typed          // ce que voit le modèle (contexte + tapé)
                let remaining = String(chars[k...])
                let trimmed = prefix.trimmingCharacters(in: .whitespaces)
                let fired = trimmed.count >= 3 && Prod.hasCompletedFirstWord(prefix)
                var ghost = ""
                if fired {
                    let raw = await rawGhost(prefix: prefix, on: container)
                    ghost = Prod.displayGhost(rawSnapshot: raw, prefix: prefix)
                }
                let v = classify(prefix: prefix, ghost: ghost, remaining: remaining, fired: fired)
                totals[v, default: 0] += 1
                let mark: String
                switch v {
                case .match: mark = "✓ MATCH"
                case .alt:   mark = "~ ALT  "
                case .empty: mark = "∅ EMPTY"
                case .gated: mark = "· GATED"
                }
                let shownPrefix = typed.replacingOccurrences(of: "\n", with: "⏎")
                let shownRem = remaining.replacingOccurrences(of: "\n", with: "⏎")
                emit("  \(mark)  tapé:\"\(shownPrefix)\"  ghost:\"\(ghost)\"  (cible→\"\(shownRem.prefix(28))\")")
            }
            emit("")
        }

        let fired = (totals[.match] ?? 0) + (totals[.alt] ?? 0) + (totals[.empty] ?? 0)
        let total = fired + (totals[.gated] ?? 0)
        emit("──────────────────────────────────────────────")
        emit(" Bilan global (\(total) étapes)")
        emit("──────────────────────────────────────────────")
        emit(" ✓ MATCH : \(totals[.match] ?? 0)")
        emit(" ~ ALT   : \(totals[.alt] ?? 0)")
        emit(" ∅ EMPTY : \(totals[.empty] ?? 0)   (ghost vide → user voit rien)")
        emit(" · GATED : \(totals[.gated] ?? 0)   (prod ne déclenche pas)")
        if fired > 0 {
            let mr = Double(totals[.match] ?? 0) / Double(fired) * 100
            let er = Double(totals[.empty] ?? 0) / Double(fired) * 100
            emit(String(format: " → match rate (sur déclenchés): %.0f%%", mr))
            emit(String(format: " → empty rate (sur déclenchés): %.0f%%", er))
        }
        emit("──────────────────────────────────────────────")
    }
}
