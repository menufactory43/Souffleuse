import AppKit
import SouffleuseCore

/// Fenêtre flottante DEV qui affiche le **trace ghost** en direct : à chaque
/// frappe, la SOURCE (corpus L1 / lexique L0 / dico / LLM / cache), ce que le
/// modèle a produit et ce qu'on en a fait (affiché en vert, gaté en rouge avec
/// le motif, dropé/stub en orange) + le score décomposé. Permet de voir
/// EXACTEMENT ce qui aurait dû s'afficher mais a été caché — pour savoir quoi
/// améliorer. Non-activating, **déplaçable** (drag par le fond), démarre au coin
/// haut-droit puis garde la position que tu lui donnes.
/// `NSTextView` qui laisse le clic-glissé déplacer la fenêtre (au lieu de le
/// capturer). La vue n'est ni éditable ni sélectionnable — aucune interaction
/// texte à préserver, donc tout le fond devient une poignée de drag.
private final class DraggableTextView: NSTextView {
    override var mouseDownCanMoveWindow: Bool { true }
}

@MainActor
final class GhostInspectorWindow {
    private let panel: NSPanel
    private let textView: NSTextView
    /// Position auto (coin haut-droit) seulement au PREMIER affichage ; ensuite on
    /// respecte là où l'utilisateur a glissé la fenêtre.
    private var hasPositioned = false
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
        // Déplaçable : on accepte les events souris (sinon le panel est inerte) et
        // on autorise le drag depuis n'importe quel point du fond. `.stationary`
        // retiré pour que le panel suive le drag.
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]

        let scroll = NSScrollView(frame: rect)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.autoresizingMask = [.width, .height]

        textView = DraggableTextView(frame: rect)
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
        if !hasPositioned {
            positionTopRight()
            hasPositioned = true
        }
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

    /// Couleur par couche source — corpus/lexique (perso) en cyan/violet,
    /// LLM en bleu, dico/cache/undo neutres — pour repérer la voie d'un coup d'œil.
    private static func sourceColor(_ s: SuggestionSource) -> NSColor {
        switch s {
        case .history:      return .systemCyan       // corpus L1 (rappel verbatim)
        case .learnedWord:  return .systemPurple      // lexique L0 (terme appris)
        case .wordComplete: return .systemGray        // dico système
        case .cache, .undoCache: return .systemBrown  // caches
        case .llm:          return .systemBlue        // génération LLM
        case .none:         return .darkGray
        }
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
        out.append(NSAttributedString(string: "GHOST INSPECTOR — vert=affiché · rouge=gaté · orange=dropé/stub · [source] glisse pour déplacer\n\n",
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
            // tag coloré · [SOURCE] coloré par couche · CONTENU en blanc · score
            // décomposé + raison en sourdine · fin de préfixe en gris foncé.
            out.append(NSAttributedString(string: tag + "  ",
                                          attributes: [.font: mono, .foregroundColor: color]))
            let srcLabel = GhostInspector.label(for: e.source)
            out.append(NSAttributedString(string: "[\(srcLabel)] ".padding(toLength: 13, withPad: " ", startingAt: 0),
                                          attributes: [.font: mono, .foregroundColor: Self.sourceColor(e.source)]))
            out.append(NSAttributedString(string: e.content,
                                          attributes: [.font: mono, .foregroundColor: NSColor.white]))
            if let s = e.score {
                out.append(NSAttributedString(string: String(format: "   %.2f(s%.2f·p%.2f·l%.2f)",
                                                             s.value, s.sourcePrior, s.prefixFit, s.lengthFit),
                                              attributes: [.font: dim, .foregroundColor: NSColor.systemTeal]))
            }
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
