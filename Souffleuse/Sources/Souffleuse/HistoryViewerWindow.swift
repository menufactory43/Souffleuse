import AppKit
import SouffleuseCorpus
import SouffleusePersonalization
import SwiftUI

/// Read-only viewer for the entries currently persisted in
/// `TypingHistoryStore`. We disable screen sharing on this window so a stray
/// screenshot or screen-share can't leak the cleartext content of someone
/// else's typed text.
@MainActor
final class HistoryViewerWindow {
    private var window: NSWindow?
    private let history: TypingHistoryStore

    init(history: TypingHistoryStore) {
        self.history = history
    }

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = HistoryViewerRoot(history: history)
        let host = NSHostingController(rootView: root)
        host.view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let w = NSWindow(contentViewController: host)
        w.title = "Vos données collectées"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 640, height: 480))
        w.isReleasedWhenClosed = false
        w.sharingType = .none  // block screen capture / screen sharing
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}

private struct HistoryViewerRoot: View {
    let history: TypingHistoryStore
    @State private var entries: [TypingHistoryEntry] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Vos données collectées").font(.headline)
                Spacer()
                Text("\(entries.count) entrées").font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.top)

            if entries.isEmpty {
                ContentUnavailableView(
                    "Aucune donnée",
                    systemImage: "tray",
                    description: Text(loaded ? "Active la collecte dans Préférences > Personnalisation et accepte quelques suggestions." : "Chargement…")
                )
            } else {
                List(Array(entries.enumerated()), id: \.offset) { _, e in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(e.timestamp.formatted(date: .numeric, time: .shortened))
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(e.bundleID ?? "—")
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        if !e.contextBefore.isEmpty {
                            Text("…\(e.contextBefore)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Text(e.accepted)
                            .font(.body)
                            .lineLimit(3)
                    }
                    .padding(.vertical, 2)
                }
            }

            HStack {
                Text("Cette fenêtre désactive les captures d'écran système. Données chiffrées sur ton Mac, jamais envoyées.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .frame(minWidth: 480, minHeight: 320)
        .task {
            let e = await history.recentEntries(limit: 500).reversed()
            entries = Array(e)
            loaded = true
        }
    }
}
