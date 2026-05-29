import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

public struct AppContext: Sendable, Equatable {
    public let bundleID: String?
    public let localizedName: String?
    public let windowTitle: String?

    public init(bundleID: String?, localizedName: String?, windowTitle: String?) {
        self.bundleID = bundleID
        self.localizedName = localizedName
        self.windowTitle = windowTitle
    }

    /// Short identifier suitable for the `[App: …]` debug prefix.
    public var displayName: String {
        bundleID ?? localizedName ?? "-"
    }

    /// App name surfaced in the LLM prompt. Prefers `localizedName` over
    /// `bundleID` so the model sees "Brave" rather than "com.brave.Browser".
    ///
    /// **Web-app refinement.** When the frontmost app is a recognised browser
    /// AND the window title matches a known web-app surface, the returned
    /// name is the *web app* (with its role hint), not the browser. The 2026
    /// Bug-A replay (`.planning/phases/04-cascade-quality-architecture/replay-intercom-bugA.json`)
    /// established that `App Brave, window "Inbox · Intercom"` gives the base
    /// LLM far too little signal to pivot to customer-support priors. Naming
    /// the web app explicitly is a free upstream improvement.
    public var promptAppName: String {
        let base = localizedName ?? bundleID ?? "-"
        guard let title = windowTitle, !title.isEmpty,
              Self.isWebBrowserName(base) else { return base }
        return Self.webAppRefinement(forWindowTitle: title) ?? base
    }

    /// Window title with known browser-injected noise stripped (Brave/Chrome
    /// memory-warning suffixes, trailing browser-brand suffix). Returns nil if
    /// the cleaned title is empty.
    ///
    /// Observed pollution (2026-05-28 OCR triage): Brave appends
    /// " - Utilisation élevée de la mémoire - 1,3 Go – Brave" to ALL window
    /// titles when the process is over a memory threshold. That trailing 50+
    /// chars dilutes Gemma's attention on the title's *useful* prefix (the
    /// actual page name, e.g. "Boîte de réception Intercom").
    public var cleanedWindowTitle: String? {
        guard let raw = windowTitle, !raw.isEmpty else { return nil }
        let cleaned = Self.cleanWindowTitle(raw)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func cleanWindowTitle(_ title: String) -> String {
        var result = title
        // Brave/Chrome high-memory notice (FR + EN). Captures the
        // " - <warning> - X,Y Go – <Browser>" suffix; bounded so it stops
        // at end-of-line without eating useful prose.
        let suffixPatterns = [
            #"\s*[-–—]\s*Utilisation\s+élevée\s+de\s+la\s+mémoire.*$"#,
            #"\s*[-–—]\s*High\s+memory\s+usage.*$"#,
            #"\s*[-–—]\s*\d+([.,]\d+)?\s*[GM]o\s*[-–—]\s*(Brave|Google Chrome|Chromium|Edge|Safari|Firefox|Arc|Vivaldi|Opera)\s*$"#,
            // Trailing browser-brand suffix once the memory tail is gone.
            // "Inbox · Intercom – Brave" → "Inbox · Intercom".
            #"\s*[-–—]\s*(Brave|Google Chrome|Chromium|Microsoft Edge|Safari|Firefox|Arc|Vivaldi|Opera)\s*$"#,
        ]
        for pattern in suffixPatterns {
            result = result.replacingOccurrences(
                of: pattern, with: "", options: .regularExpression
            )
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Bundle-ID-agnostic web-browser detector. Matches by display name so
    /// new browsers (Arc, Vivaldi…) work without a bundleID allowlist.
    static func isWebBrowserName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return webBrowserKeywords.contains { lower.contains($0) }
    }

    private static let webBrowserKeywords: [String] = [
        "brave", "chrome", "safari", "arc", "edge", "firefox", "vivaldi", "opera",
    ]

    /// Maps a browser window title to a web-app role string, or nil if no
    /// pattern matches. Patterns are intentionally narrow and prose-friendly —
    /// the goal is to give Gemma enough lexical signal to switch its prior,
    /// not to ship an exhaustive registry.
    static func webAppRefinement(forWindowTitle title: String) -> String? {
        let lower = title.lowercased()
        if lower.contains("intercom") { return "Intercom (support client)" }
        if lower.contains("zendesk") { return "Zendesk (support client)" }
        if lower.contains("helpscout") || lower.contains("help scout") {
            return "Help Scout (support client)"
        }
        if lower.contains("freshdesk") { return "Freshdesk (support client)" }
        if lower.contains("crisp.chat") || lower.contains(" crisp ") {
            return "Crisp (support client)"
        }
        if lower.contains("gmail") { return "Gmail" }
        if lower.contains("notion.so") || lower.hasSuffix(" – notion") || lower.hasSuffix(" - notion") {
            return "Notion"
        }
        if lower.contains("linear.app") || lower.contains(" linear") { return "Linear" }
        return nil
    }
}

/// Reads frontmost app metadata (bundle, window title) via AX + NSWorkspace.
/// No new permission required beyond Accessibility (already granted in J2).
public final class AppContextProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cocotypist.context.app", qos: .userInitiated)
    private let systemWide: AXUIElement

    public init() {
        self.systemWide = AXUIElementCreateSystemWide()
    }

    public func snapshot() -> AppContext {
        queue.sync { readSnapshot() }
    }

    private func readSnapshot() -> AppContext {
        // CGWindowList reads the live WindowServer state and works from CLI
        // binaries that haven't registered an NSApplication. NSWorkspace
        // returned stale data in that case.
        guard let top = topmostOnScreenWindow() else {
            return AppContext(bundleID: nil, localizedName: nil, windowTitle: nil)
        }
        let running = NSRunningApplication(processIdentifier: top.pid)
        let bundleID = running?.bundleIdentifier
        let localizedName = running?.localizedName ?? top.ownerName

        let appEl = AXUIElementCreateApplication(top.pid)
        let title = focusedWindowTitle(of: appEl) ?? top.windowName
        return AppContext(bundleID: bundleID, localizedName: localizedName, windowTitle: title)
    }

    private struct WindowInfo {
        let pid: pid_t
        let ownerName: String?
        let windowName: String?
    }

    /// macOS system processes that surface transient windows during Mission
    /// Control / Cmd-Tab / Stage Manager transitions. Ignoring them keeps the
    /// frontmost reading stable across animations.
    private static let systemShellBundleIDs: Set<String> = [
        "com.apple.WindowManager",
        "com.apple.dock",
        "com.apple.loginwindow",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
    ]

    private func topmostOnScreenWindow() -> WindowInfo? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        // The list is ordered front-to-back. The first window at layer 0 owned
        // by a real app (not a system shell, not ourselves) is the active one.
        for entry in list {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t else { continue }
            if pid == getpid() { continue }
            if let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
               Self.systemShellBundleIDs.contains(bid) {
                continue
            }
            let owner = entry[kCGWindowOwnerName as String] as? String
            let name = entry[kCGWindowName as String] as? String
            return WindowInfo(pid: pid, ownerName: owner, windowName: name?.isEmpty == false ? name : nil)
        }
        return nil
    }

    private func focusedWindowTitle(of appEl: AXUIElement) -> String? {
        guard let win = copyAttr(appEl, kAXFocusedWindowAttribute) else {
            // Fallback to the main window.
            if let main = copyAttr(appEl, kAXMainWindowAttribute) {
                return copyStringAttr(main as! AXUIElement, kAXTitleAttribute)
            }
            return nil
        }
        return copyStringAttr(win as! AXUIElement, kAXTitleAttribute)
    }

    private func copyAttr(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var ref: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard status == .success else { return nil }
        return ref
    }

    private func copyStringAttr(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttr(element, attribute) as? String
    }
}
