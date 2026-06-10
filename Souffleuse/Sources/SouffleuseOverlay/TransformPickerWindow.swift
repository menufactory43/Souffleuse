import AppKit
import QuartzCore

/// Picker des transformations « // » — rangée ①–⑤ (corriger · raccourcir ·
/// reformuler · ton · traduire) au caret, clone structurel d'`EmojiPickerWindow` :
/// panneau non-activant de niveau status-bar, l'app hôte garde le focus, la
/// sélection se fait au CLAVIER (rangée 1–5 / ⏎ via `KeyInterceptor`), jamais à
/// la souris. Le module Overlay ne dépend pas de SouffleuseCore : l'API prend
/// des `[String]` de libellés déjà filtrés/ordonnés, la position visuelle
/// (badge ①–⑤) = l'index. Quand `labels` est vide et qu'une instruction libre
/// est en cours de frappe, le panneau bascule sur la ligne « ⏎ « … » ».
@MainActor
public final class TransformPickerWindow {
    private let panel: NSPanel
    private let container: NSView
    /// Paires (libellé, badge ①–⑤) recyclées entre deux `show()` — le filtrage
    /// retape la liste à chaque frappe, recréer les vues par tick serait du gâchis.
    private var itemViews: [(label: NSTextField, badge: NSTextField)] = []
    /// Ligne « ⏎ « instruction » » du mode libre (masquée quand la rangée s'affiche).
    private let freeLine: NSTextField

    private static let labelPointSize: CGFloat = 13
    private static let badgeDiameter: CGFloat = 15
    private static let itemSpacing: CGFloat = 14
    private static let padding: CGFloat = 10
    /// Le badge déborde au-dessus-gauche du libellé, comme chez le picker emoji.
    private static let badgeOverhang: CGFloat = 6
    /// Hauteur de la rangée de libellés (systemFont 13 + respiration).
    private static let rowHeight: CGFloat = 18
    /// Tronque l'instruction libre affichée dans la ligne « ⏎ … ».
    static let freeInstructionDisplayCap = 60

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

        freeLine = NSTextField(labelWithString: "")
        freeLine.font = LivretPalette.serif(size: Self.labelPointSize, italic: true)
        freeLine.isHidden = true
        container.addSubview(freeLine)
    }

    /// Affiche (ou met à jour en place) la rangée au-dessus du caret.
    /// `labels` = libellés filtrés, tronqués à 5 (badge = index + 1) ; le PREMIER
    /// est surligné en accent — c'est lui que ⏎ sélectionne.
    /// `labels` vide ET `freeInstruction` non vide → ligne « ⏎ « instruction » ».
    /// `labels` vide ET `freeInstruction` nil/vide → équivaut à `hide()`.
    public func show(labels: [String], freeInstruction: String?, at caretRectQuartz: CGRect) {
        let shown = Array(labels.prefix(5))
        let free = freeInstruction.flatMap { $0.isEmpty ? nil : $0 }
        guard !shown.isEmpty || free != nil else {
            hide()
            return
        }
        applyColors()
        if shown.isEmpty, let free {
            layoutFreeLine(free, caretRectQuartz: caretRectQuartz)
        } else {
            layoutRow(labels: shown, caretRectQuartz: caretRectQuartz)
        }
        if !panel.isVisible {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        isVisible = true
    }

    /// Replie le panneau. Idempotent.
    public func hide() {
        guard isVisible || panel.isVisible else { return }
        isVisible = false
        panel.orderOut(nil)
    }

    /// Palette livret (papier/encre/accent), recalculée à chaque `show` — assez
    /// rare pour ne pas mériter un observer d'apparence dédié (même choix que
    /// le picker emoji).
    private func applyColors() {
        let dark = LivretPalette.isDark(container)
        container.layer?.backgroundColor = LivretPalette.paper(dark).cgColor
        container.layer?.borderColor = LivretPalette.border(dark).cgColor
        freeLine.textColor = LivretPalette.ink(dark)
    }

    // MARK: - Rangée ①–⑤

    private func layoutRow(labels: [String], caretRectQuartz: CGRect) {
        freeLine.isHidden = true
        let dark = LivretPalette.isDark(container)

        // Crée les vues manquantes, cache les surnuméraires (recyclage).
        while itemViews.count < labels.count {
            let label = NSTextField(labelWithString: "")
            let badge = NSTextField(labelWithString: "")
            badge.font = .systemFont(ofSize: 9, weight: .semibold)
            badge.alignment = .center
            badge.textColor = .white
            badge.wantsLayer = true
            badge.layer?.cornerRadius = Self.badgeDiameter / 2
            badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            container.addSubview(label)
            container.addSubview(badge)
            itemViews.append((label, badge))
        }
        for (i, views) in itemViews.enumerated() {
            let visible = i < labels.count
            views.label.isHidden = !visible
            views.badge.isHidden = !visible
        }

        // Libellés à largeur variable → mesure individuelle ; le premier match
        // (celui que ⏎ choisira) est surligné en accent + semibold.
        var widths: [CGFloat] = []
        for (i, text) in labels.enumerated() {
            let (label, badge) = itemViews[i]
            let isFirst = (i == 0)
            label.stringValue = text
            label.font = .systemFont(ofSize: Self.labelPointSize, weight: isFirst ? .semibold : .medium)
            label.textColor = isFirst ? LivretPalette.accent(dark) : LivretPalette.ink(dark)
            badge.stringValue = String(i + 1)
            badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            label.sizeToFit()
            widths.append(ceil(label.frame.width))
        }

        let width = Self.padding * 2
            + Self.badgeOverhang
            + widths.reduce(0, +)
            + CGFloat(max(0, labels.count - 1)) * Self.itemSpacing
        let height = Self.padding * 2 + Self.rowHeight + Self.badgeOverhang

        var x = Self.padding + Self.badgeOverhang
        for (i, w) in widths.enumerated() {
            let (label, badge) = itemViews[i]
            label.frame = NSRect(x: x, y: Self.padding, width: w, height: Self.rowHeight)
            badge.frame = NSRect(
                x: x - Self.badgeOverhang,
                y: Self.padding + Self.rowHeight - Self.badgeDiameter + Self.badgeOverhang,
                width: Self.badgeDiameter,
                height: Self.badgeDiameter)
            x += w + Self.itemSpacing
        }

        place(width: width, height: height, caretRectQuartz: caretRectQuartz)
    }

    // MARK: - Ligne instruction libre

    private func layoutFreeLine(_ instruction: String, caretRectQuartz: CGRect) {
        for views in itemViews {
            views.label.isHidden = true
            views.badge.isHidden = true
        }
        freeLine.isHidden = false
        freeLine.stringValue = "⏎ « \(Self.truncatedInstruction(instruction)) »"
        freeLine.sizeToFit()
        let lineW = ceil(freeLine.frame.width)
        let width = Self.padding * 2 + lineW
        let height = Self.padding * 2 + Self.rowHeight
        freeLine.frame = NSRect(x: Self.padding, y: Self.padding, width: lineW, height: Self.rowHeight)
        place(width: width, height: height, caretRectQuartz: caretRectQuartz)
    }

    /// Tronque l'instruction au cap d'affichage (en `Character`, ellipse au-delà).
    static func truncatedInstruction(_ s: String) -> String {
        s.count <= freeInstructionDisplayCap ? s : String(s.prefix(freeInstructionDisplayCap)) + "…"
    }

    // MARK: - Placement

    /// Quartz (origine haut-gauche) → AppKit (bas-gauche) ; le panneau se pose
    /// AU-DESSUS de la ligne du caret, clampé à l'écran (même calcul que l'emoji).
    private func place(width: CGFloat, height: CGFloat, caretRectQuartz: CGRect) {
        container.frame = NSRect(x: 0, y: 0, width: width, height: height)
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
