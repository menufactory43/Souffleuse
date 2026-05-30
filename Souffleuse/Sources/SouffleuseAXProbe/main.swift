import AppKit
import Foundation
import SouffleuseAX
import SouffleuseInput
import SouffleuseOverlay

// Flush every line when stdout is piped (tee, redirection).
setbuf(stdout, nil)

let blocklist: Set<String> = [
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "org.alacritty",
    "com.mitchellh.ghostty",
    "net.kovidgoyal.kitty",
    "dev.zed.Zed",
    "com.1password.1password",
    "com.1password.1password7",
    "com.apple.keychainaccess",
]

let stderr = FileHandle.standardError
func warn(_ s: String) { stderr.write(Data((s + "\n").utf8)) }

guard AXClient.ensureTrusted(prompt: true) else {
    warn("AXProbe: Accessibility permission denied.")
    warn("Grant in System Settings → Privacy & Security → Accessibility, then re-run.")
    exit(1)
}

let client = AXClient()
let debug = CommandLine.arguments.contains("--debug")
let overlayMode = CommandLine.arguments.contains("--overlay")
let injectMode = CommandLine.arguments.contains("--inject")
let ghostText = " (ghost demo)"

print("AXProbe running\(debug ? " [DEBUG]" : "")\(overlayMode ? " [OVERLAY]" : "")\(injectMode ? " [INJECT]" : ""). Ctrl-C to stop.")
print("AXIsProcessTrusted=\(AXClient.isTrusted)")
if injectMode {
    print("Inject mode: Tab inserts ghost text into the focused field, Esc hides the ghost.")
}

func preview(_ s: String, _ n: Int = 40) -> String {
    let trimmed = String(s.prefix(n)).replacingOccurrences(of: "\n", with: "↵")
    return s.count > n ? "\(trimmed)…" : trimmed
}

func rectString(_ r: CGRect) -> String {
    "(\(Int(r.origin.x)),\(Int(r.origin.y)),\(Int(r.size.width))x\(Int(r.size.height)))"
}

var lastLine = ""
var tick = 0
// Cache last known caret rect per-app so the ghost stays anchored through
// frames where AX (e.g. Notes) intermittently returns nil for the bounds query.
var lastCaretRect: [String: CGRect] = [:]

// Suggestion state shared between the polling timer and the CGEventTap thread.
// `nonisolated(unsafe)` because the tap callback reads/writes it from its own
// thread; in practice we mutate it only from the main actor, and reads from
// the tap thread tolerate one-frame staleness without consequence.
nonisolated(unsafe) var suggestionActive = false
nonisolated(unsafe) var lastGhostShownAt: CGRect? = nil

// Set by Esc; cleared the next time the host text changes. While true, the
// ghost is suppressed even if the focused field would otherwise show one.
var dismissedForText: String? = nil

// Created lazily in overlayMode below.
var interceptor: KeyInterceptor? = nil

@MainActor
func step(overlay: OverlayWindow?) {
    if debug {
        print("DIAG: \(client.diagnostic())")
        if tick % 4 == 0 {
            let rows = client.scanAllApps()
            if rows.isEmpty {
                print("SCAN: no app exposes a focused element")
            } else {
                print("SCAN: focused elements across all GUI apps:")
                for r in rows { print(r) }
            }
        }
    }
    tick += 1
    let snap = client.snapshot()
    let app = snap.bundleID ?? "?"
    let line: String
    var showGhost = false

    if let bid = snap.bundleID, blocklist.contains(bid) {
        line = "[\(app)] BLOCKLISTED — skipping"
    } else if snap.isSecureField {
        line = "[\(app)] SECURE FIELD (\(snap.role ?? "?")) — content not read"
    } else if let role = snap.role, let text = snap.text {
        let caret = snap.caretIndex.map(String.init) ?? "?"
        if let r = snap.caretRect {
            lastCaretRect[app] = r
        }
        let effectiveRect = snap.caretRect ?? lastCaretRect[app]
        let rectStr = snap.caretRect.map(rectString) ?? (lastCaretRect[app].map { "stale:\(rectString($0))" } ?? "?")
        line = "[\(app)] field=\(role) text=\"\(preview(text))\" caret=\(caret) rect=\(rectStr)"
        if let dismissed = dismissedForText, dismissed == text {
            // User pressed Esc; suppress ghost until the text changes.
            showGhost = false
        } else {
            dismissedForText = nil
            showGhost = effectiveRect != nil
        }
    } else if let role = snap.role {
        line = "[\(app)] role=\(role) (not a text element)"
    } else {
        line = "[\(app)] no focused element"
    }

    if line != lastLine {
        print(line)
        lastLine = line
    }

    if let overlay {
        let rectForGhost = snap.caretRect ?? lastCaretRect[app]
        if showGhost, let rect = rectForGhost {
            let font = snap.caretFont.flatMap {
                NSFont(name: $0.familyName, size: CGFloat($0.pointSize)) ?? .systemFont(ofSize: CGFloat($0.pointSize))
            }
            overlay.show(text: ghostText, at: rect, hostText: snap.text, caretIndex: snap.caretIndex, hostFont: font)
            suggestionActive = true
            lastGhostShownAt = rect
        } else {
            overlay.hide()
            suggestionActive = false
        }
        interceptor?.setActive(suggestionActive)
    }
}

if overlayMode {
    // GUI mode: NSApp + main-thread Timer driving snapshot+overlay.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let overlay = OverlayWindow()

    if injectMode {
        let tap = KeyInterceptor { key in
            // Runs on the CGEventTap thread.
            guard suggestionActive else { return false }
            switch key {
            case .tab, .acceptAll, .commit:
                // Inject on a background thread so we don't block the tap. Returning
                // true consumes the key so it doesn't reach the host app. The
                // probe accepts the whole ghost for both keys (no partial-accept
                // chunking here), so `.acceptAll` behaves like `.tab`.
                DispatchQueue.global(qos: .userInitiated).async {
                    client.inject(ghostText)
                }
                DispatchQueue.main.async {
                    overlay.hide()
                    suggestionActive = false
                    interceptor?.setActive(false)
                }
                return true
            case .esc:
                // Snapshot the current host text so we can suppress the ghost
                // until the user types (which changes it).
                DispatchQueue.global(qos: .userInitiated).async {
                    let snap = client.snapshot()
                    DispatchQueue.main.async {
                        dismissedForText = snap.text ?? ""
                        overlay.hide()
                        suggestionActive = false
                        interceptor?.setActive(false)
                    }
                }
                return true
            }
        }
        if tap.install() {
            interceptor = tap
            print("KeyInterceptor installed. Will consume Tab/Esc only while ghost is showing.")
        } else {
            warn("KeyInterceptor failed to install. Grant Input Monitoring in System Settings → Privacy & Security.")
        }
    }

    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
        MainActor.assumeIsolated { step(overlay: overlay) }
    }
    app.run()
} else {
    // CLI-only mode: tight loop, no overlay. Hop to main actor for `step`.
    while true {
        DispatchQueue.main.async { step(overlay: nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }
}
