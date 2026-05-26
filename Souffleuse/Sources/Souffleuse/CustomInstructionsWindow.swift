import AppKit
import Foundation

@MainActor
final class CustomInstructionsWindow {
    static let defaultsKey = "customAIInstructions"
    static let placeholder = """
        Exemple :
        Je m'appelle Gabriel, j'écris principalement en français.
        Style : pro, chaleureux, direct, pas de formules creuses.
        Domaine : design produit + dev macOS.
        """

    private var window: NSWindow?
    private var textView: NSTextView?

    static func current() -> String {
        UserDefaults.standard.string(forKey: defaultsKey) ?? ""
    }

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Instructions personnalisées"
        w.isReleasedWhenClosed = false
        w.center()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.alignment = .leading

        let header = NSTextField(labelWithString: "Cette consigne est ajoutée en tête de chaque prompt envoyé au modèle.")
        header.font = .systemFont(ofSize: 12)
        header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byWordWrapping
        header.maximumNumberOfLines = 0
        header.preferredMaxLayoutWidth = 500
        stack.addArrangedSubview(header)

        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let tv = NSTextView()
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.string = Self.current()
        if tv.string.isEmpty {
            tv.string = ""
        }
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 6, height: 6)
        scroll.documentView = tv
        textView = tv

        let scrollContainer = NSView()
        scrollContainer.translatesAutoresizingMaskIntoConstraints = false
        scrollContainer.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: scrollContainer.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: scrollContainer.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: scrollContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: scrollContainer.trailingAnchor),
            scrollContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            scrollContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 500),
        ])
        stack.addArrangedSubview(scrollContainer)

        let footer = NSTextField(labelWithString: Self.placeholder)
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        footer.lineBreakMode = .byWordWrapping
        footer.maximumNumberOfLines = 0
        footer.preferredMaxLayoutWidth = 500
        stack.addArrangedSubview(footer)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.alignment = .centerY

        let cancel = NSButton(title: "Annuler", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        buttonRow.addArrangedSubview(cancel)

        let save = NSButton(title: "Enregistrer", target: self, action: #selector(saveClicked))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        buttonRow.addArrangedSubview(save)
        stack.addArrangedSubview(buttonRow)
        stack.setCustomSpacing(8, after: footer)

        w.contentView = stack
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    @objc private func saveClicked() {
        let value = textView?.string ?? ""
        UserDefaults.standard.set(value, forKey: Self.defaultsKey)
        window?.close()
    }

    @objc private func cancelClicked() {
        window?.close()
    }
}
