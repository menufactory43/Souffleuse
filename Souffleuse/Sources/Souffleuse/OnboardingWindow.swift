import AppKit
import Foundation
import IOKit.hid
import SouffleuseAX

/// First-launch window that explains the two required permissions and
/// links straight to the relevant Settings panes. Closes itself once
/// both permissions are granted, and re-checks every second while open
/// so the user sees the ✓ flip as soon as they toggle the perms.
@MainActor
final class OnboardingWindow {
    private let window: NSWindow
    private let axRow: PermissionRow
    private let imRow: PermissionRow
    private var refreshTimer: Timer?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Bienvenue dans Souffleuse"
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window

        self.axRow = PermissionRow(
            title: "Accessibility",
            description: "Lit le contenu du champ texte focalisé et y écrit la suggestion acceptée.",
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!,
            isGranted: { AXClientIsTrusted() }
        )

        self.imRow = PermissionRow(
            title: "Input Monitoring",
            description: "Intercepte Tab/Esc uniquement quand une suggestion est affichée.",
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!,
            isGranted: { InputMonitoringIsTrusted() }
        )

        let title = NSTextField(labelWithString: "Quelques permissions, puis on est tranquilles")
        title.font = .boldSystemFont(ofSize: 16)

        let subtitle = NSTextField(wrappingLabelWithString: "Souffleuse vit dans ta barre de menus et propose des complétions dans n'importe quelle app. Pour ça, deux permissions système sont nécessaires.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, subtitle, axRow.view, imRow.view])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])
        window.contentView = content
    }

    func show() {
        refresh()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func close() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        window.orderOut(nil)
    }

    private func refresh() {
        axRow.refresh()
        imRow.refresh()
        if axRow.granted && imRow.granted {
            close()
        }
    }
}

@MainActor
private final class PermissionRow {
    let view: NSView
    private(set) var granted: Bool = false

    private let statusLabel = NSTextField(labelWithString: "")
    private let isGranted: () -> Bool

    init(title: String, description: String, settingsURL: URL, isGranted: @escaping () -> Bool) {
        self.isGranted = isGranted

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: 13)

        let descLabel = NSTextField(wrappingLabelWithString: description)
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = .secondaryLabelColor

        statusLabel.font = .systemFont(ofSize: 13)

        let button = NSButton(title: "Ouvrir Réglages", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.target = OnboardingButtonTarget.shared
        button.action = #selector(OnboardingButtonTarget.openURL(_:))
        button.identifier = NSUserInterfaceItemIdentifier(settingsURL.absoluteString)

        let titleRow = NSStackView(views: [titleLabel, NSView(), statusLabel])
        titleRow.orientation = .horizontal
        titleRow.distribution = .fill
        titleRow.alignment = .firstBaseline

        let column = NSStackView(views: [titleRow, descLabel, button])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        self.view = column
    }

    func refresh() {
        granted = isGranted()
        statusLabel.stringValue = granted ? "✓ accordée" : "✗ requise"
        statusLabel.textColor = granted ? .systemGreen : .systemRed
    }
}

@MainActor
final class OnboardingButtonTarget: NSObject {
    static let shared = OnboardingButtonTarget()
    @objc func openURL(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let url = URL(string: id) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Permission check helpers

@MainActor
private func AXClientIsTrusted() -> Bool {
    AXClient.isTrusted
}

@MainActor
private func InputMonitoringIsTrusted() -> Bool {
    IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
}
