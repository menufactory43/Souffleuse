import AppKit
import QuartzCore

/// Picker emoji au caret — la rangée « : » de Cotypist. Panneau non-activant
/// qui affiche jusqu'à 9 emoji avec un badge numéroté ①–⑨ ; la sélection se
/// fait au CLAVIER (rangée physique 1–9 via `KeyInterceptor`), jamais à la
/// souris — le panneau ignore les événements souris pour ne pas voler le focus
/// de l'app hôte. Le module Overlay ne dépend pas de SouffleuseTyping : l'API
/// prend des `[String]` d'emoji déjà ordonnés, la position visuelle = l'index.
@MainActor
public final class EmojiPickerWindow {
    private let panel: NSPanel
    private let container: NSView
    /// Vues par candidat, recyclées entre deux `show` (le filtrage retape la
    /// liste à chaque frappe — recréer 18 vues par tick serait du gâchis).
    private var itemViews: [(emoji: NSTextField, badge: NSTextField)] = []

    private static let emojiPointSize: CGFloat = 22
    private static let badgeDiameter: CGFloat = 15
    private static let itemSpacing: CGFloat = 10
    private static let padding: CGFloat = 10
    /// Le badge déborde au-dessus-gauche de l'emoji, comme chez Cotypist.
    private static let badgeOverhang: CGFloat = 6

    public private(set) var isVisible = false

    public init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 50),
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

        container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.borderWidth = 1
        panel.contentView = container
    }

    /// Affiche (ou met à jour en place) la rangée de candidats au-dessus du
    /// caret. `emojis` est tronqué à 9 — au-delà il n'y a plus de touche.
    public func show(emojis: [String], at caretRectQuartz: CGRect) {
        let shown = Array(emojis.prefix(9))
        guard !shown.isEmpty else {
            hide()
            return
        }
        applyColors()
        layout(emojis: shown, caretRectQuartz: caretRectQuartz)
        if !panel.isVisible {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        isVisible = true
    }

    public func hide() {
        guard isVisible || panel.isVisible else { return }
        isVisible = false
        panel.orderOut(nil)
    }

    /// Palette livret (papier/encre/accent), recalculée à chaque `show` — assez
    /// rare pour ne pas mériter un observer d'apparence dédié.
    private func applyColors() {
        let dark = LivretPalette.isDark(container)
        container.layer?.backgroundColor = LivretPalette.paper(dark).cgColor
        container.layer?.borderColor = LivretPalette.border(dark).cgColor
    }

    private func layout(emojis: [String], caretRectQuartz: CGRect) {
        // Crée les vues manquantes, cache les surnuméraires.
        while itemViews.count < emojis.count {
            let emoji = NSTextField(labelWithString: "")
            emoji.font = .systemFont(ofSize: Self.emojiPointSize)
            let badge = NSTextField(labelWithString: "")
            badge.font = .systemFont(ofSize: 9, weight: .semibold)
            badge.alignment = .center
            badge.textColor = .white
            badge.wantsLayer = true
            badge.layer?.cornerRadius = Self.badgeDiameter / 2
            badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            container.addSubview(emoji)
            container.addSubview(badge)
            itemViews.append((emoji, badge))
        }
        for (i, views) in itemViews.enumerated() {
            let visible = i < emojis.count
            views.emoji.isHidden = !visible
            views.badge.isHidden = !visible
        }

        let emojiSide = Self.emojiPointSize + 6
        let itemW = emojiSide
        let width = Self.padding * 2
            + CGFloat(emojis.count) * itemW
            + CGFloat(max(0, emojis.count - 1)) * Self.itemSpacing
            + Self.badgeOverhang
        let height = Self.padding * 2 + emojiSide + Self.badgeOverhang

        for (i, e) in emojis.enumerated() {
            let (emojiView, badgeView) = itemViews[i]
            emojiView.stringValue = e
            badgeView.stringValue = String(i + 1)
            let x = Self.padding + Self.badgeOverhang + CGFloat(i) * (itemW + Self.itemSpacing)
            emojiView.frame = NSRect(x: x, y: Self.padding, width: emojiSide, height: emojiSide)
            badgeView.frame = NSRect(
                x: x - Self.badgeOverhang,
                y: Self.padding + emojiSide - Self.badgeDiameter + Self.badgeOverhang,
                width: Self.badgeDiameter,
                height: Self.badgeDiameter)
        }
        container.frame = NSRect(x: 0, y: 0, width: width, height: height)

        // Quartz (origine haut-gauche) → AppKit (bas-gauche) ; le panneau se
        // pose AU-DESSUS de la ligne du caret, clampé à l'écran.
        let screen = NSScreen.screens.first ?? NSScreen.main
        let screenH = screen?.frame.height ?? 0
        let screenW = screen?.frame.width ?? 0
        let origin = TranslationHUDWindow.clampedOrigin(
            defaultOrigin: CGPoint(x: caretRectQuartz.minX, y: screenH - caretRectQuartz.minY + 6),
            offset: .zero,
            panelSize: CGSize(width: width, height: height),
            screenSize: CGSize(width: screenW, height: screenH))
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: height), display: true)
    }
}
