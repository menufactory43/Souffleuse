import Foundation

public enum LogLevel: String, Sendable {
    case info, warn, error
}

public enum LogModule: String, Sendable {
    case ax, overlay, input, context, predictor, ui, log
}

/// Privacy invariant: ONLY these 5 fields are ever written. The struct (not a
/// dictionary) enforces it at the type level — no path of code can sneak a
/// user-supplied string into the file.
fileprivate struct LogEntry: Encodable {
    let ts: String
    let level: String
    let module: String
    let event: String
    let count: Int?
}

public enum Log {
    public static func info(_ module: LogModule, _ event: StaticString, count: Int? = nil) {
        write(.info, module, event, count: count)
    }

    public static func warn(_ module: LogModule, _ event: StaticString, count: Int? = nil) {
        write(.warn, module, event, count: count)
    }

    public static func error(_ module: LogModule, _ event: StaticString, count: Int? = nil) {
        write(.error, module, event, count: count)
    }

    private static func write(_ level: LogLevel, _ module: LogModule, _ event: StaticString, count: Int?) {
        // StaticString forces compile-time literals at the call site, which makes
        // it structurally impossible to log a user-supplied string here.
        let entry = LogEntry(
            ts: LogWriter.shared.timestamp(),
            level: level.rawValue,
            module: module.rawValue,
            event: "\(event)",
            count: count
        )
        LogWriter.shared.append(entry)
    }
}

/// Serial writer. One process owns the log file; future XPC agents will route
/// through an IPC channel rather than opening the file directly (see J4).
final class LogWriter: @unchecked Sendable {
    static let shared = LogWriter()

    private let queue = DispatchQueue(label: "dev.cocotypist.Souffleuse.log")
    private let encoder = JSONEncoder()
    private let formatter: ISO8601DateFormatter
    private let logURL: URL
    private let maxBytes: Int = 1_000_000
    private let backups: Int = 3

    private init() {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.logURL = dir.appendingPathComponent("Souffleuse.log")
    }

    func timestamp() -> String { formatter.string(from: Date()) }

    fileprivate func append(_ entry: LogEntry) {
        queue.async { [self] in
            guard let data = try? encoder.encode(entry) else { return }
            rotateIfNeeded()
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.write(contentsOf: Data([0x0A]))
        }
    }

    private func rotateIfNeeded() {
        guard let size = try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int,
              size >= maxBytes else { return }
        let fm = FileManager.default
        // shift .N → .(N+1), drop the oldest
        for i in stride(from: backups - 1, through: 1, by: -1) {
            let src = logURL.appendingPathExtension("\(i)")
            let dst = logURL.appendingPathExtension("\(i + 1)")
            try? fm.removeItem(at: dst)
            try? fm.moveItem(at: src, to: dst)
        }
        let first = logURL.appendingPathExtension("1")
        try? fm.removeItem(at: first)
        try? fm.moveItem(at: logURL, to: first)
    }
}
