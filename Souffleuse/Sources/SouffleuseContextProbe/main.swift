import AppKit
import Foundation
import SouffleuseAX
import SouffleuseContext

// CLI demo for Phases 2.5.A + 2.5.B — prints the enriched context lines
// every 500 ms so we can eyeball what would be prepended to the model prompt.
//
// Usage:
//   cd ~/cocotypist/Souffleuse
//   swift run SouffleuseContextProbe                 # app + clipboard only
//   swift run SouffleuseContextProbe --capture       # also screen-OCR

// NSApplication.shared must be touched before NSWorkspace/AppKit subsystems
// behave correctly from a pure CLI binary.
_ = NSApplication.shared

let captureEnabled = CommandLine.arguments.contains("--capture")

guard AXClient.ensureTrusted(prompt: true) else {
    FileHandle.standardError.write(Data("Accessibility permission required.\n".utf8))
    exit(1)
}

if captureEnabled {
    if !ScreenCapturer.hasPermission() {
        print("Requesting Screen Recording permission — grant it in System Settings then relaunch.")
        _ = ScreenCapturer.requestPermission()
    }
}

let appProbe = AppContextProbe()
let clipboard = ClipboardReader()
let capturer = ScreenCapturer()
let ocr = VisionOCR()

print("SouffleuseContextProbe — Ctrl-C to quit. Sampling every 500 ms.")
print("AX trusted: \(AXClient.isTrusted) | Capture: \(captureEnabled) | ScreenRec trusted: \(ScreenCapturer.hasPermission())\n")
setbuf(stdout, nil)

// Cache the OCR result per bundleID — only re-OCR when the focused bundle
// changes, mimicking the production cache strategy (5s TTL, focus-bound).
actor VisibleCache {
    var lastBundleID: String?
    var lastVisible: String?
    var lastLogTime: Date = .distantPast

    func get() -> (String?, String?) { (lastBundleID, lastVisible) }
    func store(bundleID: String, text: String) { lastBundleID = bundleID; lastVisible = text }
    func reset(bundleID: String) { lastBundleID = bundleID; lastVisible = nil }
    func shouldLog() -> Bool {
        if Date().timeIntervalSince(lastLogTime) > 1 { lastLogTime = Date(); return true }
        return false
    }
}
let visibleCache = VisibleCache()

func tick() async {
    let ctx = appProbe.snapshot()
    let blocked: Bool
    if let bid = ctx.bundleID {
        blocked = await clipboard.isBlocked(bundleID: bid)
    } else {
        blocked = false
    }
    let clip = await clipboard.read(frontmostBundleID: ctx.bundleID)

    let appLine: String = {
        if let title = ctx.windowTitle, !title.isEmpty {
            return "[App: \(ctx.displayName) | Window: \"\(title)\"]"
        }
        return "[App: \(ctx.displayName)]"
    }()
    print(appLine)
    if blocked {
        print("[Clipboard: skipped — blocklist]")
    } else if let clip {
        print("[Clipboard excerpt: \(clip)]")
    }

    if captureEnabled, let bid = ctx.bundleID {
        let (cachedBid, cachedText) = await visibleCache.get()
        if bid != cachedBid {
            await visibleCache.reset(bundleID: bid)
            let t0 = Date()
            do {
                let capture = try await capturer.capture(bundleID: bid)
                let captureMs = Int(Date().timeIntervalSince(t0) * 1000)
                let t1 = Date()
                let text = try await ocr.extract(from: capture.image)
                let ocrMs = Int(Date().timeIntervalSince(t1) * 1000)
                await visibleCache.store(bundleID: bid, text: text)
                if await visibleCache.shouldLog() {
                    print("  (capture=\(captureMs)ms ocr=\(ocrMs)ms chars=\(text.count))")
                }
                if !text.isEmpty {
                    print("[Visible context: \(text)]")
                }
            } catch {
                print("  (capture error: \(error))")
            }
        } else if let visible = cachedText, !visible.isEmpty {
            print("[Visible context: \(visible)]")
        }
    }
    print("")
}

Task.detached {
    while !Task.isCancelled {
        await tick()
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
}

signal(SIGINT) { _ in
    print("\nbye.")
    exit(0)
}
RunLoop.main.run()
