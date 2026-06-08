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
// et c'est la lecture AX-read-first du mode `observe`.

import AppKit
import ApplicationServices
import Foundation
import SouffleuseAX
import SouffleuseContext

// Flush chaque ligne quand stdout est redirigé (tee, > fichier).
setbuf(stdout, nil)

// MARK: - Constantes

let cotypistBundleID = "app.cotypist.Cotypist"
let textEditBundleID = "com.apple.TextEdit"

// Phrase de test fixe pilotée dans TextEdit, char par char, en mode observe.
let testPhrase = "Bonjour, je voulais te dire que "

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
      SouffleuseCotypistObserve --help    Cette aide.

    FLAGS (mode observe) :
      --delay <ms>   Délai/budget de polling inter-frappe (défaut 300).
      --out <path>   Chemin du fichier JSONL (défaut /tmp/cotypist-observe.jsonl).

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

// L'aide ne touche pas l'AX : ce chemin doit toujours réussir, sans TCC.
if args.contains("--help") || args.contains("-h") || mode == nil {
    printUsage()
    exit(0)
}

guard mode == "scan" || mode == "observe" else {
    warn("Mode inconnu : \(mode ?? "?"). Attendu : scan | observe. Voir --help.")
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

/// Collecte les strings non vides (value / AXStaticText) de l'arbre Cotypist.
/// Heuristique : le ghost vit dans une fenêtre overlay distincte ; en l'absence
/// de certitude on retourne TOUS les AXStaticText / value non vides — le mode
/// `scan` aura déjà révélé la vraie structure pour affiner si besoin.
func ghostCandidates(in appEl: AXUIElement) -> [String] {
    var out: [String] = []
    var nodeCount = 0
    func collect(_ el: AXUIElement, depth: Int) {
        guard nodeCount < maxNodes, depth < defaultMaxDepth else { return }
        nodeCount += 1
        let role = axString(el, kAXRoleAttribute)
        if let v = (axString(el, kAXValueAttribute) ?? axString(el, kAXTitleAttribute)),
           !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // On garde surtout les AXStaticText (typique d'un label overlay), mais
            // on collecte aussi les autres value non vides : le ghost peut être
            // exposé sous un rôle inattendu.
            if role == kAXStaticTextRole || role == "AXStaticText" {
                out.append(v)
            } else {
                out.append(v)
            }
        }
        for child in axChildren(el) { collect(child, depth: depth + 1) }
    }
    collect(appEl, depth: 0)
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
    let k: Int
    let prefix: String
    let ghost: String
    let source: String   // "ax" | "ocr" | "none"
    let ts_ms: Int64
    let latency_ms: Int?
}

func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

func runObserve() {
    guard let pid = cotypistPID() else {
        warn("Cotypist introuvable. Lancer Cotypist puis relancer (observe).")
        exit(1)
    }
    let cotypistAppEl = AXUIElementCreateApplication(pid)
    let client = AXClient()

    let delayMs = intFlag("--delay", default: 300)
    let outPath = stringFlag("--out", default: "/tmp/cotypist-observe.jsonl")

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
    print("phrase=\"\(testPhrase)\" delay=\(delayMs)ms out=\(outPath)")

    let pollStepMs: UInt32 = 20
    let chars = Array(testPhrase)

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

        // Fallback OCR — best-effort, voir intent ci-dessous.
        if source == "none" {
            if let ocr = bestEffortOCR() {
                ghost = ocr
                source = "ocr"
                latency = Int(nowMs() - tPost)
            }
            // sinon : source reste "none" (l'AX n'a rien rendu, OCR non exploitable).
        }

        // Lire le préfixe réel + caret du champ TextEdit focalisé.
        let snap = client.snapshot()
        let prefix = snap.text ?? typedSoFar

        let obs = Observation(
            k: index,
            prefix: prefix,
            ghost: ghost,
            source: source,
            ts_ms: nowMs(),
            latency_ms: latency
        )
        if let data = try? encoder.encode(obs), let line = String(data: data, encoding: .utf8) {
            print(line)
            handle.write(Data((line + "\n").utf8))
        }
    }

    print("=== fin OBSERVE — JSONL écrit dans \(outPath) ===")
}

// OCR fallback: best-effort — voir task intent.
// Les APIs réelles (ScreenCapturer.capture(bundleID:) + VisionOCR.extract, toutes
// async et taillées pour clusteriser des bulles de chat) ne capturent pas
// trivialement une région ghost overlay ponctuelle. Le chemin AX-read-first
// au-dessus est le vrai livrable ; cet OCR reste un stub honnête qui retourne nil
// (→ source="none") plutôt que de prétendre lire un ghost qu'il ne peut pas
// localiser de façon fiable. Câbler un capture+OCR ciblé sur le rect de l'overlay
// Cotypist est une amélioration future une fois que `scan` aura confirmé le rect.
func bestEffortOCR() -> String? {
    guard ScreenCapturer.hasPermission() else { return nil }
    // Pas de localisation fiable de la région ghost → ne pas deviner. nil = "none".
    return nil
}

// MARK: - Dispatch

switch mode {
case "scan": runScan()
case "observe": runObserve()
default:
    printUsage()
    exit(2)
}
