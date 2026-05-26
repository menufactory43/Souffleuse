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

    /// Short identifier suitable for the `[App: …]` prefix line.
    public var displayName: String {
        bundleID ?? localizedName ?? "-"
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
