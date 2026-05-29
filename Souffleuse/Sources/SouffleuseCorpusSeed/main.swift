import Foundation
import SouffleusePersonalization

// MARK: - Usage
//
//   SouffleuseCorpusSeed <path> [--sender "Gabriel from Waltio"]
//
// <path> : a single .txt file OR a directory (scanned recursively for *.txt)
// --sender : which Intercom participant to import (default: "Gabriel from Waltio")
//
// Reads Intercom conversation exports, extracts messages from the specified
// sender, cleans the bodies, and bulk-inserts them into the live corpus
// (~/Library/Application Support/Souffleuse/history.db) as `source: .prose`.

// MARK: - Args

var args = CommandLine.arguments.dropFirst()
var senderFilter = "Gabriel from Waltio"
var inputPath: String? = nil

var it = args.makeIterator()
while let a = it.next() {
    if a == "--sender" {
        senderFilter = it.next() ?? senderFilter
    } else {
        inputPath = a
    }
}

guard let path = inputPath else {
    fputs("Usage: SouffleuseCorpusSeed <file-or-directory> [--sender \"Gabriel from Waltio\"]\n", stderr)
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

let store = TypingHistoryStore()

var totalMessages = 0
var totalInserted = 0

// TypingHistoryStore is an actor — run everything on a single task.
let sema = DispatchSemaphore(value: 0)
Task {
    await store.load()
    let beforeCount = await store.count()

    for filePath in files.sorted() {
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            fputs("Cannot read: \(filePath)\n", stderr); continue
        }
        let messages = parseIntercomFile(content, sender: senderFilter)
        totalMessages += messages.count
        for body in messages {
            let entry = TypingHistoryEntry(
                timestamp: Date(),
                contextBefore: "",
                accepted: body,
                bundleID: "com.intercom.conversations",
                source: .prose
            )
            await store.append(entry)
            totalInserted += 1
        }
    }

    let afterCount = await store.count()
    print("Messages parsed : \(totalMessages)")
    print("Entries inserted: \(afterCount - beforeCount)  (after gates)")
    print("Corpus total    : \(afterCount)")
    sema.signal()
}
sema.wait()
