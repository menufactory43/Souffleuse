import Foundation
import SouffleusePersonalization

// MARK: - Usage
//
//   SouffleuseCorpusSeed <path> [--sender "Gabriel from Waltio"] [--as-bundle com.brave.Browser]
//
// <path> : a single .txt file OR a directory (scanned recursively for *.txt)
// --sender : which Intercom participant to import (default: "Gabriel from Waltio")
// --as-bundle : tag imported prose with this bundleID so it lands in the right
//   DomainCluster at runtime (P2.3). Default: com.intercom.conversations (.other).
//   Use the app you actually write that style in (e.g. com.brave.Browser → .web).
//
// Reads Intercom conversation exports, extracts messages from the specified
// sender, cleans the bodies, and bulk-inserts them into the live corpus
// (~/Library/Application Support/Souffleuse/history.db) as `source: .prose`.

// MARK: - Args

var args = CommandLine.arguments.dropFirst()
var senderFilter = "Gabriel from Waltio"
var inputPath: String? = nil
var asBundle: String? = nil

var it = args.makeIterator()
while let a = it.next() {
    if a == "--sender" {
        senderFilter = it.next() ?? senderFilter
    } else if a == "--as-bundle" {
        asBundle = it.next()
    } else {
        inputPath = a
    }
}

guard let path = inputPath else {
    fputs("Usage: SouffleuseCorpusSeed <file-or-directory> [--sender \"Gabriel from Waltio\"] [--as-bundle com.brave.Browser]\n", stderr)
    exit(1)
}

// MARK: - File discovery

func txtFiles(at path: String) -> [String] {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
        fputs("Path not found: \(path)\n", stderr); return []
    }
    if !isDir.boolValue { return [path] }
    guard let enumerator = FileManager.default.enumerator(atPath: path) else { return [] }
    var results: [String] = []
    for case let file as String in enumerator where file.hasSuffix(".txt") {
        results.append((path as NSString).appendingPathComponent(file))
    }
    return results
}

// MARK: - Intercom .txt parser

/// One parsed turn from the conversation.
struct Turn {
    let sender: String
    let body: String
}

/// Strips noise from a message body:
/// - [Image], [Attachment: ...], [App: ...]
/// - URLs in parentheses (https://...)
/// - Sources: / Source: trailing blocks (Walty bot artefact)
/// - Collapses whitespace
func cleanBody(_ raw: String) -> String {
    var s = raw
    // Remove attachment/image/app markers
    s = s.replacingOccurrences(of: #"\[Image\]"#, with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: #"\[Attachment:[^\]]*\]"#, with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: #"\[App:[^\]]*\]"#, with: "", options: .regularExpression)
    // Remove URLs in parens
    s = s.replacingOccurrences(of: #"\(https?://[^)]*\)"#, with: "", options: .regularExpression)
    // Strip trailing Sources / Source block
    for marker in ["\nSources:\n", "\nSource:\n", "\nSources:", "\nSource:"] {
        if let r = s.range(of: marker) { s = String(s[..<r.lowerBound]) }
    }
    // Collapse whitespace
    return s
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Returns message body lines joined; nil when line is a header/separator.
let timestampRE = try! NSRegularExpression(pattern: #"^\d{1,2}:\d{2} [AP]M \| "#)

func isTimestampLine(_ line: String) -> Bool {
    let r = NSRange(line.startIndex..., in: line)
    return timestampRE.firstMatch(in: line, range: r) != nil
}

func parseIntercomFile(_ content: String, sender: String) -> [String] {
    var results: [String] = []
    var currentSender: String? = nil
    var currentLines: [String] = []

    func flush() {
        guard let s = currentSender, s == sender else {
            currentSender = nil; currentLines = []; return
        }
        let body = cleanBody(currentLines.joined(separator: " "))
        if body.count >= 8 { results.append(body) }
        currentSender = nil
        currentLines = []
    }

    for line in content.components(separatedBy: "\n") {
        // Day separator or footer
        if line.hasPrefix("---") || line.hasPrefix("Conversation with")
            || line.hasPrefix("Started on") || line.hasPrefix("Exported from") {
            flush(); continue
        }
        if isTimestampLine(line) {
            flush()
            // Parse "HH:MM AM/PM | Sender: body"
            if let pipeRange = line.range(of: " | ") {
                let afterPipe = String(line[pipeRange.upperBound...])
                // Split on first ": " to get sender vs body
                if let colonRange = afterPipe.range(of: ": ") {
                    currentSender = String(afterPipe[..<colonRange.lowerBound])
                    let bodyPart = String(afterPipe[colonRange.upperBound...])
                    currentLines = [bodyPart]
                } else {
                    currentSender = ""
                    currentLines = []
                }
            }
        } else if currentSender != nil {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { currentLines.append(trimmed) }
        }
    }
    flush()
    return results
}

// MARK: - Main

let files = txtFiles(at: path)
guard !files.isEmpty else {
    fputs("No .txt files found at: \(path)\n", stderr); exit(1)
}

print("Sender filter : \"\(senderFilter)\"")
print("Files found   : \(files.count)")

// Write to a staging file the app will import on next launch.
// This avoids the Keychain access issue for unsigned CLI tools.
let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
let souffleuseDir = appSupport.appendingPathComponent("Souffleuse", isDirectory: true)
try? FileManager.default.createDirectory(at: souffleuseDir, withIntermediateDirectories: true)
let queueURL = souffleuseDir.appendingPathComponent("corpus-import.json")

var allMessages: [String] = []

// Load existing queue if any (append mode). Accept both the new
// `{bundleID, messages}` wrapper and the legacy `[String]`.
if let existing = try? Data(contentsOf: queueURL) {
    if let wrap = try? JSONDecoder().decode(CorpusImportQueue.self, from: existing) {
        allMessages = wrap.messages
        if asBundle == nil { asBundle = wrap.bundleID }   // preserve a prior tag if not overridden
    } else if let decoded = try? JSONDecoder().decode([String].self, from: existing) {
        allMessages = decoded
    }
}

for filePath in files.sorted() {
    guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
        fputs("Cannot read: \(filePath)\n", stderr); continue
    }
    allMessages += parseIntercomFile(content, sender: senderFilter)
}

// Dedup
let seen = NSMutableOrderedSet(array: allMessages)
let deduped = seen.array as! [String]

// Write the wrapper format when a bundle tag is given (so the importer scopes it
// to the right DomainCluster), otherwise the legacy `[String]` for compatibility.
let payload: Data?
if let b = asBundle {
    payload = try? JSONEncoder().encode(CorpusImportQueue(bundleID: b, messages: deduped))
} else {
    payload = try? JSONEncoder().encode(deduped)
}
if let data = payload {
    try? data.write(to: queueURL, options: .atomic)
    print("Messages parsed : \(allMessages.count)")
    print("After dedup     : \(deduped.count)")
    print("Bundle tag      : \(asBundle ?? "com.intercom.conversations (défaut)")")
    print("Queue written to: \(queueURL.path)")
    print("→ Lance l'app Souffleuse pour importer dans le corpus.")
} else {
    fputs("Failed to write queue file.\n", stderr)
    exit(1)
}
