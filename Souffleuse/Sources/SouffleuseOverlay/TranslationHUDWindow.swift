import AppKit
import Foundation

/// Panneau flottant MINIMAL qui affiche la traduction (streamée puis finale) à
/// côté du champ. Même topologie NSPanel que `PresenceIndicatorWindow`
/// (borderless non-activating, niveau status-bar, click-through, toutes les
/// Spaces). Version « mini Phase 4 » : pas de poignée/drag, pas de chip
/// cliquable, pas de persistance — juste rendre une vraie traduction VISIBLE.
/// Le panneau riche (drag, hitTest, multi-rangées, ancrage mémorisé) = Phase 3b.
@MainActor
public final class TranslationHUDWindow {
    private let panel: NSPanel
    private let container: NSView
    private let header: NSTextField
    private let body: NSTextField
    private var anchorRectQuartz: CGRect = .zero

    public static let width: CGFloat = 320

    public init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true

        container = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 80))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(srgbRed: 0.098, green: 0.122, blue: 0.141, alpha: 0.98).cgColor
        container.layer?.cornerRadius = 12
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor(srgbRed: 0.165, green: 0.208, blue: 0.251, alpha: 1).cgColor

        header = NSTextField(labelWithString: "")
        header.font = .systemFont(ofSize: 10, weight: .semibold)
        header.textColor = NSColor(srgbRed: 0.43, green: 0.76, blue: 0.79, alpha: 1)

        body = NSTextField(wrappingLabelWithString: "")
        body.font = .systemFont(ofSize: 14)
        body.textColor = NSColor(srgbRed: 0.81, green: 0.88, blue: 0.93, alpha: 1)
        body.maximumNumberOfLines = 0
        body.lineBreakMode = .byWordWrapping

        container.addSubview(header)
        container.addSubview(body)
        panel.contentView = container
    }

    /// Affiche le panneau ancré à droite du cadre du champ (`fieldRectQuartz`,
    /// coordonnées Quartz top-left).
    public func show(at fieldRectQuartz: CGRect, header headerText: String, body bodyText: String) {
        anchorRectQuartz = fieldRectQuartz
        header.stringValue = headerText
        relayout(bodyText)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Met à jour le texte de traduction (appelé pendant le streaming).
    public func update(_ text: String) {
        relayout(text)
    }

    public func hide() {
        if panel.isVisible { panel.orderOut(nil) }
    }

    private func relayout(_ bodyText: String) {
        body.stringValue = bodyText.isEmpty ? "…" : bodyText
        let pad: CGFloat = 12
        let gap: CGFloat = 6
        let headerH: CGFloat = 14
        let bodyWidth = Self.width - pad * 2

        let attrs: [NSAttributedString.Key: Any] = [.font: body.font as Any]
        let bounding = (body.stringValue as NSString).boundingRect(
            with: NSSize(width: bodyWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        let bodyH = max(18, ceil(bounding.height))
        let total = pad + headerH + gap + bodyH + pad

        container.frame = NSRect(x: 0, y: 0, width: Self.width, height: total)
        header.frame = NSRect(x: pad, y: total - pad - headerH, width: bodyWidth, height: headerH)
        body.frame = NSRect(x: pad, y: pad, width: bodyWidth, height: bodyH)

        // Ancré au bord GAUCHE du champ, juste AU-DESSUS de son bord haut → bien
        // visible près du composer. Le bas du panneau est fixe (juste au-dessus du
        // champ) et il grandit vers le HAUT au fil du streaming. Clampé à l'écran.
        let screen = NSScreen.screens.first ?? NSScreen.main
        let screenH = screen?.frame.height ?? 0
        let screenW = screen?.frame.width ?? 0
        var x = anchorRectQuartz.minX
        var y = screenH - anchorRectQuartz.minY + 6   // bas du panneau, au-dessus du champ
        x = min(max(8, x), max(8, screenW - Self.width - 8))
        y = min(max(8, y), max(8, screenH - total - 8))
        panel.setFrame(NSRect(x: x, y: y, width: Self.width, height: total), display: true)
    }
}
