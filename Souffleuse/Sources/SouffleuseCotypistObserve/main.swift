// SouffleuseCotypistObserve — probe dev d'observation BOÎTE-NOIRE de Cotypist.
//
// GARDE-FOU ÉTHIQUE / LÉGAL :
// Ce probe observe UNIQUEMENT la sortie d'accessibilité (AX) externellement
// visible de l'app commerciale Cotypist (app.cotypist.Cotypist), sous licence
// séparée. Il n'attache AUCUN debugger, ne patche pas, ne re-signe pas, ne
// contourne AUCUNE protection de Cotypist. Lecture seule, via l'API publique
// d'accessibilité macOS — exactement ce qu'un lecteur d'écran ferait.
//
// But : comprendre OÙ et SI Cotypist expose son ghost-text dans son arbre AX,
// et capturer ses complétions face à des frappes contrôlées dans TextEdit, comme
// base d'analyse comparative pour notre propre ghost.
//
// Fait de design : Cotypist (comme nous) dessine son ghost dans une fenêtre
// overlay non-activante SÉPARÉE — pas dans le champ TextEdit focalisé. Lire
// l'élément TextEdit focalisé ne rend donc que ce QU'ON a tapé. Pour capturer le
// ghost il faut walker l'arbre AX PROPRE de Cotypist via
// AXUIElementCreateApplication(cotypistPID). C'est ce que fait le mode `scan`,
// et c'est la lecture AX-read-first du mode `observe`. Le mode `accept` évite
// l'OCR : il appuie sur Tab après un délai contrôlé et lit le delta inséré dans
// TextEdit, ce qui mesure exactement le ghost accepté.

import AppKit
import ApplicationServices
import Foundation
import SouffleuseAX
import SouffleuseContext

// Flush chaque ligne quand stdout est redirigé (tee, > fichier).
setbuf(stdout, nil)

// MARK: - Constantes

let cotypistBundleID = "app.cotypist.Cotypist"
let souffleuseBundleID = "app.cocotypist.Souffleuse"
let textEditBundleID = "com.apple.TextEdit"

// Phrase de test par défaut pilotée dans TextEdit, char par char, en mode observe.
let defaultTestPhrase = "Bonjour, je voulais te dire que "

// Bornes de sécurité du walk AX (évite une explosion sur un arbre cyclique/profond).
let defaultMaxDepth = 12
let maxNodes = 5_000

let stderr = FileHandle.standardError
func warn(_ s: String) { stderr.write(Data((s + "\n").utf8)) }

// MARK: - Usage (AVANT toute touche à l'AX — pas de dépendance TCC pour l'aide)

func printUsage() {
    print("""
    SouffleuseCotypistObserve — observation boîte-noire (lecture AX seule) de Cotypist.

    USAGE :
      SouffleuseCotypistObserve scan      Dump l'arbre AX de Cotypist (rôle/subrole/value/rect).
      SouffleuseCotypistObserve observe   Pilote TextEdit char-par-char, lit le ghost de Cotypist
                                          (AX-read-first) et émet du JSONL (1 ligne/frappe).
      SouffleuseCotypistObserve accept    Tape chaque préfixe dans TextEdit, attend, presse Tab,
                                          puis lit exactement le delta inséré.
      SouffleuseCotypistObserve --help    Cette aide.

    FLAGS (modes observe/accept) :
      --delay <ms>   Délai/budget de polling inter-frappe (défaut 300).
      --delays <csv> Délais testés en mode accept (défaut: valeur de --delay).
      --phrase <txt> Phrase vérité-terrain à taper (défaut phrase courte FR).
      --out <path>   Chemin du fichier JSONL (défaut /tmp/cotypist-observe.jsonl).
      --target <name> Cible du mode accept: cotypist | souffleuse (défaut cotypist).
      --typing-delay <ms> Délai entre caractères en mode accept (défaut 12).

    PRÉREQUIS :
      scan     : Cotypist lancé (idéalement avec un ghost affiché).
      observe  : Cotypist lancé + TextEdit ouvert avec un document vide au premier plan.
                 Accessibilité accordée à ce binaire (System Settings → Privacy → Accessibility).

    ÉTHIQUE : lecture AX externe uniquement. Aucun debugger, patch, re-signature
              ni contournement d'une protection de Cotypist.
    """)
}

// MARK: - Parsing args

let args = CommandLine.arguments
let mode = args.dropFirst().first { !$0.hasPrefix("-") }

func intFlag(_ name: String, default def: Int) -> Int {
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let v = Int(args[i + 1]) else {
        return def
    }
    return v
}

func stringFlag(_ name: String, default def: String) -> String {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return def }
    return args[i + 1]
}

func intListFlag(_ name: String, default def: [Int]) -> [Int] {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return def }
    let values = args[i + 1].split(separator: ",").compactMap {
        Int($0.trimmingCharacters(in: .whitespaces))
    }
    return values.isEmpty ? def : values
}

struct ProbeTarget {
    let engine: String
    let displayName: String
    let bundleID: String
}

func acceptTarget() -> ProbeTarget {
    switch stringFlag("--target", default: "cotypist").lowercased() {
    case "souffleuse", "ours", "us":
        return ProbeTarget(engine: "souffleuse", displayName: "Souffleuse", bundleID: souffleuseBundleID)
    case "cotypist":
        return ProbeTarget(engine: "cotypist", displayName: "Cotypist", bundleID: cotypistBundleID)
    default:
        warn("Target inconnu. Attendu: cotypist | souffleuse.")
        exit(2)
    }
}

// L'aide ne touche pas l'AX : ce chemin doit toujours réussir, sans TCC.
if args.contains("--help") || args.contains("-h") || mode == nil {
    printUsage()
    exit(0)
}

guard mode == "scan" || mode == "observe" || mode == "accept" else {
    warn("Mode inconnu : \(mode ?? "?"). Attendu : scan | observe | accept. Voir --help.")
    exit(2)
}

// MARK: - Helpers AX bruts (dans le probe — AXClient n'expose pas l'arbre d'une
// app NON focalisée, et on ne le modifie pas).

/// pid de Cotypist via NSWorkspace (nil si l'app n'est pas lancée).
func cotypistPID() -> pid_t? {
    NSWorkspace.shared.runningApplications
        .first { $0.bundleIdentifier == cotypistBundleID }?
        .processIdentifier
}

func runningPID(bundleID: String) -> pid_t? {
    NSWorkspace.shared.runningApplications
        .first { $0.bundleIdentifier == bundleID }?
        .processIdentifier
}

/// Wrapper sur AXUIElementCopyAttributeValue (calque le helper privé d'AXClient).
func copyAttr(_ el: AXUIElement, _ attr: String) -> AnyObject? {
    var ref: AnyObject?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
    return ref
}

/// Lecture string d'un attribut AX (role/subrole/value/title…).
func axString(_ el: AXUIElement, _ attr: String) -> String? {
    copyAttr(el, attr) as? String
}

/// Lit position + size via AXValueGetValue (.cgPoint / .cgSize), comme readElementRect.
func axRect(_ el: AXUIElement, _ posAttr: String, _ sizeAttr: String) -> CGRect? {
    guard let posRef = copyAttr(el, posAttr), let sizeRef = copyAttr(el, sizeAttr) else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
          AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: origin, size: size)
}

/// Enfants AX d'un élément (cast sûr depuis kAXChildrenAttribute).
func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    (copyAttr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func preview(_ s: String, _ n: Int = 60) -> String {
    let trimmed = String(s.prefix(n)).replacingOccurrences(of: "\n", with: "↵")
    return s.count > n ? "\(trimmed)…" : trimmed
}

func rectString(_ r: CGRect) -> String {
    "(\(Int(r.origin.x)),\(Int(r.origin.y)),\(Int(r.size.width))x\(Int(r.size.height)))"
}

/// Walk récursif borné. Émet une ligne indentée par nœud. `nodeCount` est un
/// garde-fou global (passé inout) contre l'explosion d'un arbre profond/cyclique.
func walk(
    _ el: AXUIElement,
    depth: Int,
    maxDepth: Int,
    nodeCount: inout Int,
    sink: (String) -> Void
) {
    guard nodeCount < maxNodes else { return }
    nodeCount += 1

    let role = axString(el, kAXRoleAttribute) ?? "?"
    let subrole = axString(el, kAXSubroleAttribute)
    let value = axString(el, kAXValueAttribute) ?? axString(el, kAXTitleAttribute)
    let rect = axRect(el, kAXPositionAttribute, kAXSizeAttribute)

    let indent = String(repeating: "  ", count: depth)
    var parts = ["\(indent)role=\(role)"]
    if let subrole { parts.append("subrole=\(subrole)") }
    if let value, !value.isEmpty { parts.append("value=\"\(preview(value))\"") }
    if let rect { parts.append("rect=\(rectString(rect))") }
    sink(parts.joined(separator: " "))

    guard depth < maxDepth else { return }
    for child in axChildren(el) {
        walk(child, depth: depth + 1, maxDepth: maxDepth, nodeCount: &nodeCount, sink: sink)
    }
}

/// Collecte les strings non vides (value / AXStaticText) des fenêtres Cotypist.
/// On exclut volontairement l'app root et les menus : ils exposent "Cotypist" et
/// polluent les mesures sans correspondre au ghost affiché au caret.
func ghostCandidates(in appEl: AXUIElement) -> [String] {
    guard let windows = copyAttr(appEl, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
    var out: [String] = []
    var nodeCount = 0
    func collect(_ el: AXUIElement, depth: Int) {
        guard nodeCount < maxNodes, depth < defaultMaxDepth else { return }
        nodeCount += 1
        let role = axString(el, kAXRoleAttribute)
        if role == kAXMenuBarRole || role == kAXMenuRole || role == kAXMenuItemRole {
            return
        }
        if let v = (axString(el, kAXValueAttribute) ?? axString(el, kAXTitleAttribute)),
           !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if role == kAXStaticTextRole || role == "AXStaticText" || role == kAXUnknownRole {
                out.append(v)
            }
        }
        for child in axChildren(el) { collect(child, depth: depth + 1) }
    }
    for window in windows {
        collect(window, depth: 0)
    }
    return out
}

// MARK: - Injection clavier synthétique (le probe poste SES PROPRES touches ;
// il n'appelle PAS AXClient.inject). Réplique du pattern injectViaCGEvent.

func postCharacter(_ ch: Character) {
    let source = CGEventSource(stateID: .hidSystemState)
    let utf16 = Array(String(ch).utf16)
    let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
    utf16.withUnsafeBufferPointer { buf in
        down?.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        up?.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
    }
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
}

func postVirtualKey(_ keyCode: CGKeyCode) {
    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
}

func clearTextEditDocument() {
    let script = """
    tell application "TextEdit"
        activate
        if not (exists document 1) then make new document
        set text of front document to ""
    end tell
    """
    var error: NSDictionary?
    NSAppleScript(source: script)?.executeAndReturnError(&error)
    if let error {
        warn("AppleScript TextEdit clear failed: \(error)")
    }
}

// MARK: - Garde TCC (APRÈS le chemin d'aide — scan/observe en ont besoin)

guard AXClient.ensureTrusted(prompt: true) else {
    warn("Accessibilité refusée.")
    warn("Accorder dans System Settings → Privacy & Security → Accessibility, puis relancer.")
    exit(1)
}

// MARK: - Mode SCAN

func runScan() {
    guard let pid = cotypistPID() else {
        warn("Cotypist introuvable. Lancer Cotypist (idéalement avec un ghost affiché) puis relancer.")
        exit(1)
    }
    let appEl = AXUIElementCreateApplication(pid)
    print("=== DÉCOUVERTE de l'arbre AX de Cotypist (pid=\(pid), bundle=\(cotypistBundleID)) ===")
    print("Lecture AX externe seule. role/subrole/value(tronquée)/rect, profondeur ≤ \(defaultMaxDepth).")

    var nodeCount = 0
    // L'élément app lui-même.
    walk(appEl, depth: 0, maxDepth: defaultMaxDepth, nodeCount: &nodeCount) { print($0) }

    // Puis chaque fenêtre (les overlays ghost vivent ici).
    if let windows = copyAttr(appEl, kAXWindowsAttribute) as? [AXUIElement] {
        for (i, win) in windows.enumerated() {
            print("--- fenêtre #\(i) ---")
            walk(win, depth: 1, maxDepth: defaultMaxDepth, nodeCount: &nodeCount) { print($0) }
        }
    } else {
        print("(aucune fenêtre AX exposée par Cotypist)")
    }
    print("=== fin du dump (\(nodeCount) nœuds visités) ===")
}

// MARK: - Mode OBSERVE

/// Une ligne JSONL par frappe. JSONEncoder garantit l'échappement correct.
struct Observation: Codable {
    let engine: String
    let sentence: Int
    let target: String
    let k: Int
    let prefix_len: Int
    let prefix: String
    let ghost: String
    let source: String   // "ax" | "ocr" | "none"
    let ts_ms: Int64
    let latency_ms: Int?
    let timeout_ms: Int
}

func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

func runObserve() async {
    guard let pid = cotypistPID() else {
        warn("Cotypist introuvable. Lancer Cotypist puis relancer (observe).")
        exit(1)
    }
    let cotypistAppEl = AXUIElementCreateApplication(pid)
    let client = AXClient()

    let delayMs = intFlag("--delay", default: 300)
    let outPath = stringFlag("--out", default: "/tmp/cotypist-observe.jsonl")
    let phrase = stringFlag("--phrase", default: defaultTestPhrase)

    // Activer TextEdit au premier plan (best-effort — ne bloque pas si échec).
    if let te = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == textEditBundleID }) {
        te.activate(options: [])
    } else {
        warn("TextEdit non lancé. Ouvrir TextEdit avec un document vide au premier plan, puis relancer.")
        warn("(On continue : focaliser manuellement le champ TextEdit dans la fenêtre maintenant.)")
    }
    // Laisser le focus se stabiliser.
    usleep(800_000)

    // Ouvrir le fichier JSONL.
    FileManager.default.createFile(atPath: outPath, contents: nil)
    guard let handle = FileHandle(forWritingAtPath: outPath) else {
        warn("Impossible d'ouvrir le fichier de sortie : \(outPath)")
        exit(1)
    }
    defer { try? handle.close() }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    print("=== OBSERVE : pilotage de TextEdit, lecture ghost AX-read-first ===")
    print("phrase=\"\(phrase)\" delay=\(delayMs)ms out=\(outPath)")

    let pollStepMs: UInt32 = 20
    let chars = Array(phrase)

    for (index, ch) in chars.enumerated() {
        postCharacter(ch)
        let tPost = nowMs()

        var ghost = ""
        var source = "none"
        var latency: Int? = nil

        // Préfixe attendu = ce qu'on a tapé jusqu'ici (pour distinguer ghost ≠ préfixe).
        let typedSoFar = String(chars[0...index])

        // Polling AX-read-first.
        var elapsed = 0
        while elapsed < delayMs {
            let candidates = ghostCandidates(in: cotypistAppEl)
            if let g = candidates.first(where: { c in
                let t = c.trimmingCharacters(in: .whitespacesAndNewlines)
                return !t.isEmpty && t != typedSoFar && !typedSoFar.hasSuffix(t)
            }) {
                ghost = g
                source = "ax"
                latency = Int(nowMs() - tPost)
                break
            }
            usleep(pollStepMs * 1000)
            elapsed += Int(pollStepMs)
        }

        // Lire le préfixe réel + caret du champ TextEdit focalisé.
        let snap = client.snapshot()
        let prefix = snap.text ?? typedSoFar

        // Fallback OCR ciblé — best-effort à droite du caret TextEdit.
        if source == "none" {
            if let ocr = await bestEffortOCR(caretRect: snap.caretRect, typedSoFar: prefix) {
                ghost = ocr
                source = "ocr"
                latency = Int(nowMs() - tPost)
            }
            // sinon : source reste "none" (l'AX n'a rien rendu, OCR non exploitable).
        }

        let obs = Observation(
            engine: "cotypist",
            sentence: 0,
            target: phrase,
            k: index,
            prefix_len: index + 1,
            prefix: prefix,
            ghost: ghost,
            source: source,
            ts_ms: nowMs(),
            latency_ms: latency,
            timeout_ms: delayMs
        )
        if let data = try? encoder.encode(obs), let line = String(data: data, encoding: .utf8) {
            print(line)
            handle.write(Data((line + "\n").utf8))
        }
    }

    print("=== fin OBSERVE — JSONL écrit dans \(outPath) ===")
}

// MARK: - Mode ACCEPT

/// Une ligne JSONL par essai prefixe x délai. `inserted` est le delta exact
/// apparu dans TextEdit après Tab ; pas d'OCR, pas de lecture d'overlay.
struct AcceptanceObservation: Codable {
    let engine: String
    let sentence: Int
    let target: String
    let k: Int
    let prefix_len: Int
    let prefix: String
    let inserted: String
    let ghost: String
    let accepted: Bool
    let wait_ms: Int
    let typing_delay_ms: Int
    let ts_ms: Int64
}

func runAccept() {
    let target = acceptTarget()
    guard runningPID(bundleID: target.bundleID) != nil else {
        warn("\(target.displayName) introuvable. Lancer \(target.displayName) puis relancer (accept).")
        exit(1)
    }
    let client = AXClient()
    let delayMs = intFlag("--delay", default: 120)
    let delays = intListFlag("--delays", default: [delayMs]).sorted()
    let typingDelayMs = intFlag("--typing-delay", default: 12)
    let outPath = stringFlag("--out", default: "/tmp/\(target.engine)-accept.jsonl")
    let phrase = stringFlag("--phrase", default: defaultTestPhrase)
    let chars = Array(phrase)

    FileManager.default.createFile(atPath: outPath, contents: nil)
    guard let handle = FileHandle(forWritingAtPath: outPath) else {
        warn("Impossible d'ouvrir le fichier de sortie : \(outPath)")
        exit(1)
    }
    defer { try? handle.close() }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    print("=== ACCEPT : TextEdit prefix -> wait -> Tab -> delta ===")
    print("target=\(target.engine) phrase=\"\(phrase)\" delays=\(delays) typingDelay=\(typingDelayMs)ms out=\(outPath)")
    if target.engine == "cotypist" {
        warn("Conseil mesure: quitter Souffleuse pendant ce mode pour que Cotypist soit seul a gerer Tab.")
    } else {
        warn("Conseil mesure: quitter Cotypist pendant ce mode pour que Souffleuse soit seule a gerer Tab.")
    }

    for wait in delays {
        for i in 1..<chars.count {
            let prefix = String(chars.prefix(i))
            clearTextEditDocument()
            usleep(180_000)
            for ch in prefix {
                postCharacter(ch)
                usleep(useconds_t(max(0, typingDelayMs) * 1000))
            }
            usleep(useconds_t(max(0, wait) * 1000))
            postVirtualKey(48) // Tab
            usleep(120_000)

            let textAfter = client.snapshot().text ?? ""
            let inserted: String
            if textAfter.hasPrefix(prefix) {
                inserted = String(textAfter.dropFirst(prefix.count))
            } else {
                inserted = ""
            }
            let ghost = inserted == "\t" ? "" : inserted
            let obs = AcceptanceObservation(
                engine: target.engine,
                sentence: 0,
                target: phrase,
                k: i - 1,
                prefix_len: i,
                prefix: prefix,
                inserted: ghost,
                ghost: ghost,
                accepted: !ghost.isEmpty,
                wait_ms: wait,
                typing_delay_ms: typingDelayMs,
                ts_ms: nowMs()
            )
            if let data = try? encoder.encode(obs), let line = String(data: data, encoding: .utf8) {
                print(line)
                handle.write(Data((line + "\n").utf8))
            }
        }
    }

    print("=== fin ACCEPT — JSONL écrit dans \(outPath) ===")
}

// OCR fallback: best-effort. Cotypist peut ne pas exposer son overlay ghost en AX ;
// on capture donc une petite bande à droite du caret TextEdit et on laisse Vision
// lire uniquement ce qui est peint visuellement dans cette zone.
func bestEffortOCR(caretRect: CGRect?, typedSoFar: String) async -> String? {
    guard ScreenCapturer.hasPermission() else { return nil }
    guard let caretRect else { return nil }
    let region = CGRect(
        x: max(0, caretRect.maxX - 2),
        y: max(0, caretRect.minY - 10),
        width: 640,
        height: max(44, caretRect.height + 24)
    )
    guard let image = CGWindowListCreateImage(
        region,
        .optionOnScreenOnly,
        CGWindowID(0),
        [.bestResolution, .boundsIgnoreFraming]
    ) else { return nil }

    do {
        let raw = try await VisionOCR(languages: ["fr-FR", "en-US"]).extract(from: image)
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              cleaned != "Cotypist",
              !typedSoFar.hasSuffix(cleaned) else {
            return nil
        }
        return cleaned
    } catch {
        return nil
    }
}

// MARK: - Dispatch

switch mode {
case "scan": runScan()
case "observe": await runObserve()
case "accept": runAccept()
default:
    printUsage()
    exit(2)
}
