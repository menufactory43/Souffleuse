import AppKit
import Foundation
import QuartzCore

/// Une vue du carnet (aujourd'hui · 30 jours · depuis le début) — déjà formatée
/// par l'app (toute la copie française vit côté app, source unique), plus la
/// série brute pour la sparkline. `title` sert d'étiquette au sélecteur segmenté.
public struct CarnetView: Sendable, Equatable {
    public var title: String
    public var repliquesLine: String
    public var frappesLine: String
    public var tempsLine: String
    public var actesLine: String?
    /// Frappes épargnées par jour, du plus ancien au plus récent (dernier = aujourd'hui).
    public var sparkline: [Int]
    public var sparklineCaption: String

    public init(title: String, repliquesLine: String, frappesLine: String, tempsLine: String,
                actesLine: String?, sparkline: [Int], sparklineCaption: String) {
        self.title = title
        self.repliquesLine = repliquesLine
        self.frappesLine = frappesLine
        self.tempsLine = tempsLine
        self.actesLine = actesLine
        self.sparkline = sparkline
        self.sparklineCaption = sparklineCaption
    }
}

/// Données d'affichage du carnet : plusieurs vues commutables, plus l'index de
/// celle à présenter d'abord. La fenêtre ne fait que rendre + commuter.
public struct CarnetData: Sendable, Equatable {
    public var views: [CarnetView]
    public var initialIndex: Int

    public init(views: [CarnetView], initialIndex: Int = 0) {
        self.views = views
        self.initialIndex = initialIndex
    }
}

/// Mini-graphique « taille d'un mot » des frappes épargnées par jour. Pas d'axe,
/// pas de chiffre : juste la forme d'une tendance. Dernière barre (aujourd'hui)
/// en accent franc, les autres en filet discret.
private final class SparklineView: NSView {
    var values: [Int] = []
    var dark = false

    override func draw(_ dirtyRect: NSRect) {
        let n = values.count
        guard n > 0, bounds.height > 0 else { return }
        let maxV = max(1, values.max() ?? 1)
        let barGap: CGFloat = 2
        let barW = max(1, (bounds.width - CGFloat(n - 1) * barGap) / CGFloat(n))
        for (i, v) in values.enumerated() {
            let ratio = CGFloat(v) / CGFloat(maxV)
            let h = max(1.5, ratio * (bounds.height - 1))
            let x = CGFloat(i) * (barW + barGap)
            let isToday = (i == n - 1)
            let color = isToday ? LivretPalette.accent(dark) : LivretPalette.rule(dark)
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: barW, height: h),
                         xRadius: 1, yRadius: 1).fill()
        }
    }
}

/// Sélecteur de vues « programme » : libellés Didot capitales espacées sur une
/// rangée centrée ; l'actif en accent souligné d'un filet, les autres atténués.
/// Charte livret (pas de `NSSegmentedControl`, trop « système »). Clic ou flèches
/// (gérées par la carte) pour changer de vue.
private final class SegmentSelectorView: NSView {
    var titles: [String] = []
    var selected = 0
    var dark = false
    var onSelect: ((Int) -> Void)?
    private var segmentRects: [CGRect] = []

    private static let gap: CGFloat = 16   // espace entre segments

    override func draw(_ dirtyRect: NSRect) {
        guard !titles.isEmpty, bounds.height > 0 else { return }
        let strings: [NSAttributedString] = titles.enumerated().map { i, t in
            let isSel = (i == selected)
            return NSAttributedString(string: t.uppercased(), attributes: [
                .font: LivretPalette.didot(size: 10.5),
                .foregroundColor: isSel ? LivretPalette.accent(dark)
                                        : LivretPalette.ink(dark).withAlphaComponent(0.4),
                .kern: 1.6,
            ])
        }
        let widths = strings.map { ceil($0.size().width) }
        let total = widths.reduce(0, +) + Self.gap * CGFloat(max(0, titles.count - 1))
        var x = ((bounds.width - total) / 2).rounded()
        segmentRects = []
        for (i, s) in strings.enumerated() {
            let w = widths[i]
            let sz = s.size()
            let y = ((bounds.height - sz.height) / 2).rounded()
            s.draw(at: NSPoint(x: x, y: y))
            if i == selected {   // filet sous le segment actif (souligné accent discret)
                LivretPalette.accent(dark).withAlphaComponent(0.8).setFill()
                NSBezierPath(rect: NSRect(x: x, y: 0, width: w, height: 1)).fill()
            }
            segmentRects.append(CGRect(x: x, y: 0, width: w, height: bounds.height))
            x += w + Self.gap
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for (i, r) in segmentRects.enumerated() where r.contains(p) {
            if i != selected { onSelect?(i) }
            return
        }
    }
}

/// Vue-carte du carnet : fond papier, bordure, suit l'apparence système et
/// renvoie Échap / les flèches ‹/› au gestionnaire de vues.
private final class CarnetCardView: NSView {
    var onAppearanceChange: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onPrev: (() -> Void)?
    var onNext: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onDismiss?()          // Échap
        case 123: onPrev?()            // ‹ flèche gauche
        case 124: onNext?()            // › flèche droite
        default: super.keyDown(with: event)
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

private final class CarnetPanel: NSPanel {
    override var canBecomeKey: Bool { true }   // pour capter Échap/flèches + se masquer au clic dehors
}

/// **Le Carnet** — apparition livret convoquée au clic sur l'icône. Même charte
/// que le panneau de traduction (`LivretPalette`) : papier crème · bordeaux ·
/// Didot, mode pénombre en sombre. Trois vues (aujourd'hui · 30 jours · depuis le
/// début) commutées par le sélecteur en tête ou les flèches ‹/›. Se masque sur
/// Échap ou au clic en dehors.
@MainActor
public final class CarnetWindow: NSObject, NSWindowDelegate {
    private let panel: CarnetPanel
    private let container: CarnetCardView
    private let header: NSTextField
    private let ruleLeft: NSView
    private let ruleRight: NSView
    private let selector: SegmentSelectorView
    private let repliques: NSTextField
    private let frappes: NSTextField
    private let temps: NSTextField
    private let caption: NSTextField
    private let spark: SparklineView
    private let actes: NSTextField
    private var data = CarnetData(views: [])
    private var selectedIndex = 0

    public static let width: CGFloat = 320

    private var isDark: Bool { LivretPalette.isDark(container) }

    /// Vue actuellement présentée (nil seulement si aucune donnée chargée).
    private var currentView: CarnetView? {
        guard !data.views.isEmpty else { return nil }
        return data.views[min(selectedIndex, data.views.count - 1)]
    }

    public override init() {
        panel = CarnetPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        container = CarnetCardView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 220))
        container.wantsLayer = true
        container.layer?.cornerRadius = 7
        container.layer?.borderWidth = 1

        header = Self.label(centered: true)
        ruleLeft = NSView();  ruleLeft.wantsLayer = true
        ruleRight = NSView(); ruleRight.wantsLayer = true
        selector = SegmentSelectorView(frame: .zero)
        repliques = Self.label(centered: true)
        frappes = Self.label(centered: true)
        temps = Self.label(centered: true)
        caption = Self.label(centered: true)
        spark = SparklineView(frame: .zero)
        actes = Self.label(centered: true)

        for v in [ruleLeft, ruleRight, header, selector, repliques, frappes, temps, caption, spark, actes] {
            container.addSubview(v)
        }
        panel.contentView = container
        super.init()
        panel.delegate = self
        container.onDismiss = { [weak self] in self?.hide() }
        container.onAppearanceChange = { [weak self] in self?.render() }
        container.onPrev = { [weak self] in guard let s = self else { return }; s.select(s.selectedIndex - 1) }
        container.onNext = { [weak self] in guard let s = self else { return }; s.select(s.selectedIndex + 1) }
        selector.onSelect = { [weak self] i in self?.select(i) }
    }

    private static func label(centered: Bool) -> NSTextField {
        let t = NSTextField(labelWithString: "")
        t.alignment = centered ? .center : .left
        t.lineBreakMode = .byTruncatingTail
        return t
    }

    // MARK: - API

    /// Vrai quand l'utilisateur a coché « Réduire les animations » (Réglages ›
    /// Accessibilité). Toute apparition/disparition se fait alors d'un coup.
    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Affiche le carnet centré sur l'écran principal. L'encre qui se pose :
    /// fondu + légère montée, décéléré (ease-out, jamais de rebond).
    public func show(_ data: CarnetData) {
        self.data = data
        selectedIndex = max(0, min(data.initialIndex, max(0, data.views.count - 1)))
        render()
        let finalFrame = centeredFrame(height: container.frame.height)

        // Déjà visible (rafraîchissement) : on repositionne sans animer.
        if panel.isVisible {
            panel.setFrame(finalFrame, display: true)
            panel.alphaValue = 1
            panel.makeKeyAndOrderFront(nil)
            return
        }

        // Réduire les animations : pose instantanée, ni fondu ni déplacement.
        if Self.reduceMotion {
            panel.setFrame(finalFrame, display: true)
            panel.alphaValue = 1
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(container)
            return
        }

        // Part 8 px plus bas, à plat → remonte et se révèle en décélérant.
        panel.setFrame(finalFrame.offsetBy(dx: 0, dy: -8), display: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(container)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        }
    }

    public func hide() {
        guard panel.isVisible else { return }
        if Self.reduceMotion {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            self?.panel.alphaValue = 1
        })
    }

    public var isVisible: Bool { panel.isVisible }

    /// Bascule : convoque le carnet, ou le congédie s'il est déjà là.
    public func toggle(_ data: CarnetData) {
        if panel.isVisible { hide() } else { show(data) }
    }

    /// Change de vue (clic segment ou flèches). Hauteur de carte susceptible de
    /// varier (la ligne « actes » n'existe pas partout) → on ancre le bord HAUT
    /// pour que l'en-tête ne saute pas pendant la commutation.
    private func select(_ index: Int) {
        guard !data.views.isEmpty else { return }
        let clamped = max(0, min(index, data.views.count - 1))
        guard clamped != selectedIndex else { return }
        selectedIndex = clamped
        let topBefore = panel.frame.maxY
        render()
        guard panel.isVisible else { return }
        var f = panel.frame
        f.size = NSSize(width: Self.width, height: container.frame.height)
        f.origin.y = topBefore - f.size.height
        panel.setFrame(f, display: true)
    }

    private func centeredFrame(height: CGFloat) -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = vis.midX - Self.width / 2
        let y = vis.midY - height / 2 + vis.height * 0.08   // un peu au-dessus du centre
        return NSRect(x: x, y: y, width: Self.width, height: height)
    }

    // MARK: - Rendu

    private func render() {
        let dark = isDark
        container.layer?.backgroundColor = LivretPalette.paper(dark).cgColor
        container.layer?.borderColor = LivretPalette.border(dark).cgColor
        ruleLeft.layer?.backgroundColor = LivretPalette.rule(dark).cgColor
        ruleRight.layer?.backgroundColor = LivretPalette.rule(dark).cgColor

        // En-tête « programme » : Didot capitales espacées, accent, centré.
        let para = NSMutableParagraphStyle(); para.alignment = .center
        header.attributedStringValue = NSAttributedString(
            string: "LE CARNET",
            attributes: [.font: LivretPalette.didot(size: 12), .foregroundColor: LivretPalette.accent(dark),
                         .kern: 2.4, .paragraphStyle: para])

        selector.titles = data.views.map(\.title)
        selector.selected = min(selectedIndex, max(0, data.views.count - 1))
        selector.dark = dark
        selector.needsDisplay = true

        let view = currentView
        repliques.stringValue = view?.repliquesLine ?? ""
        repliques.font = LivretPalette.serif(size: 14)
        repliques.textColor = LivretPalette.ink(dark)

        frappes.stringValue = view?.frappesLine ?? ""
        frappes.font = LivretPalette.serif(size: 14)
        frappes.textColor = LivretPalette.ink(dark)

        temps.stringValue = view?.tempsLine ?? ""
        temps.font = LivretPalette.serif(size: 14)
        temps.textColor = LivretPalette.accent(dark)   // la valeur-phare

        caption.attributedStringValue = NSAttributedString(
            string: view?.sparklineCaption ?? "",
            attributes: [.font: LivretPalette.serif(size: 10, italic: true),
                         .foregroundColor: LivretPalette.ink(dark).withAlphaComponent(0.55),
                         .paragraphStyle: para])

        spark.values = view?.sparkline ?? []
        spark.dark = dark
        spark.needsDisplay = true

        if let line = view?.actesLine {
            actes.isHidden = false
            actes.stringValue = line
            actes.font = LivretPalette.serif(size: 12, italic: true)
            actes.textColor = LivretPalette.accent(dark)
        } else {
            actes.isHidden = true
        }

        relayout()
    }

    private func relayout() {
        let pad: CGFloat = 18
        let innerW = Self.width - pad * 2
        let headerH: CGFloat = 16
        let selectorH: CGFloat = 18
        let lineH: CGFloat = 20
        let captionH: CGFloat = 13
        let sparkH: CGFloat = 34
        let actesH: CGFloat = currentView?.actesLine == nil ? 0 : 18

        let gapHeaderSelector: CGFloat = 8
        let gapSelectorStats: CGFloat = 14
        let gapLine: CGFloat = 3
        let gapStatsCaption: CGFloat = 16
        let gapCaptionSpark: CGFloat = 6
        let gapSparkActes: CGFloat = actesH == 0 ? 0 : 12

        let total = pad + headerH + gapHeaderSelector + selectorH + gapSelectorStats
            + lineH * 3 + gapLine * 2 + gapStatsCaption + captionH + gapCaptionSpark
            + sparkH + gapSparkActes + actesH + pad

        container.frame = NSRect(x: 0, y: 0, width: Self.width, height: total)

        var top = total - pad
        func place(_ v: NSView, _ h: CGFloat, gap: CGFloat = 0) {
            top -= gap
            v.frame = NSRect(x: pad, y: top - h, width: innerW, height: h)
            top -= h
        }

        place(header, headerH)
        // Filets autour de la largeur réelle du titre.
        let textW = min(ceil(header.attributedStringValue.size().width) + 8, innerW)
        let centerX = Self.width / 2
        let ruleY = (header.frame.midY).rounded()
        let sideGap: CGFloat = 12
        let leftEnd = centerX - textW / 2 - sideGap
        let rightStart = centerX + textW / 2 + sideGap
        ruleLeft.frame = NSRect(x: pad, y: ruleY, width: max(0, leftEnd - pad), height: 1)
        ruleRight.frame = NSRect(x: rightStart, y: ruleY, width: max(0, (Self.width - pad) - rightStart), height: 1)

        place(selector, selectorH, gap: gapHeaderSelector)
        place(repliques, lineH, gap: gapSelectorStats)
        place(frappes, lineH, gap: gapLine)
        place(temps, lineH, gap: gapLine)
        place(caption, captionH, gap: gapStatsCaption)
        place(spark, sparkH, gap: gapCaptionSpark)
        if actesH > 0 { place(actes, actesH, gap: gapSparkActes) }
    }

    // MARK: - NSWindowDelegate

    /// Clic en dehors → la fenêtre perd le focus → on congédie le carnet.
    public func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}
