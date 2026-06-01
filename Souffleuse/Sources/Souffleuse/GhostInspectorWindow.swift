import AppKit

/// Fenêtre flottante DEV qui affiche le **trace ghost** en direct : à chaque
/// frappe, ce que le modèle a produit et ce qu'on en a fait (affiché en vert,
/// gaté en rouge avec le motif, dropé/stub en orange). Permet de voir
/// EXACTEMENT ce qui aurait dû s'afficher mais a été caché — pour savoir quoi
/// améliorer. Non-activating, ignore la souris, coin haut-droit. Aucune
/// interaction : c'est un moniteur, pas un contrôle.
@MainActor
final class GhostInspectorWindow {
    private let panel: NSPanel
    private let textView: NSTextView
    private static let size = NSSize(width: 660, height: 360)

    init() {
        let rect = NSRect(origin: .zero, size: Self.size)
        panel = NSPanel(contentRect: rect,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.80)
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let scroll = NSScrollView(frame: rect)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.autoresizingMask = [.width, .height]

        textView = NSTextView(frame: rect)
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 8)
        scroll.documentView = textView
        panel.contentView = scroll
    }

    /// Visible à l'écran ? Tenu à jour par `show`/`hide` pour piloter le toggle
    /// du menu (et n'enregistrer les traces que fenêtre ouverte).
    private(set) var isVisible = false

    func show() {
        positionTopRight()
        panel.orderFrontRegardless()
        isVisible = true
    }

    func hide() {
        panel.orderOut(nil)
        isVisible = false
    }

    /// Bascule la visibilité et renvoie le nouvel état (pour synchroniser le
    /// menu et l'activation de l'enregistrement).
    @discardableResult
    func toggle() -> Bool {
        if isVisible { hide() } else { show() }
        return isVisible
    }

    private func positionTopRight() {
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        let f = panel.frame
        panel.setFrameOrigin(NSPoint(x: v.maxX - f.width - 16, y: v.maxY - f.height - 16))
    }

    /// Reconstruit l'affichage depuis le buffer de l'inspecteur (le plus récent
    /// en bas). Couleur par verdict ; motif de gate accolé pour les rejets.
    func refresh(_ entries: [GhostInspector.Entry]) {
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let dim = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: "GHOST INSPECTOR — vert=affiché · rouge=gaté · orange=dropé/stub\n\n",
                                      attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
                                                   .foregroundColor: NSColor.systemGray]))
        for e in entries {
            let color: NSColor
            let tag: String
            switch e.verdict {
            case .shown:   color = .systemGreen;  tag = "AFFICHÉ"
            case .gated:   color = .systemRed;    tag = "GATÉ   "
            case .dropped: color = .systemOrange; tag = "DROP   "
            case .stub:    color = .systemOrange; tag = "STUB   "
            }
            // tag coloré · CONTENU (le plus important) en blanc · raison+score
            // en entier (jamais tronqué) · fin de préfixe en sourdine.
            out.append(NSAttributedString(string: tag + "  ",
                                          attributes: [.font: mono, .foregroundColor: color]))
            out.append(NSAttributedString(string: e.content,
                                          attributes: [.font: mono, .foregroundColor: NSColor.white]))
            if !e.reason.isEmpty {
                out.append(NSAttributedString(string: "   " + e.reason,
                                              attributes: [.font: dim, .foregroundColor: NSColor.systemGray]))
            }
            out.append(NSAttributedString(string: "   …" + e.tail + "\n",
                                          attributes: [.font: dim, .foregroundColor: NSColor.darkGray]))
        }
        textView.textStorage?.setAttributedString(out)
        textView.scrollToEndOfDocument(nil)
    }
}
