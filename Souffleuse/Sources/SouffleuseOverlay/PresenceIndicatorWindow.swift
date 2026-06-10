import AppKit
import Foundation

/// Tiny logo-mark badge anchored near the caret. Same window topology as
/// `OverlayWindow` (borderless non-activating panel, status-bar level,
/// click-through, all-spaces) but with a custom drawing view instead of a
/// text field. Purpose: give the user a continuous "I'm watching" signal
/// without waiting for a suggestion to materialise. Renders the Souffleuse
/// brand mark (transparent PNG) instead of the old blue "S" disc.
@MainActor
public final class PresenceIndicatorWindow {
    private let panel: NSPanel
    private let badge: BadgeView

    /// Footprint of the badge in points. The brand mark is aspect-fit inside
    /// this square box, so the visible mark is ~22pt wide. Kept at the old
    /// "S"-disc size so anchoring/positioning stays unchanged.
    public static let diameter: CGFloat = 22

    public init() {
        self.panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter),
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
        panel.hasShadow = false
        panel.ignoresMouseEvents = true

        self.badge = BadgeView(
            frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter)
        )
        panel.contentView = badge
    }

    /// Show the badge anchored to the top-left of `fieldRectQuartz` (the
    /// focused text element's frame). Anchoring to the field — not the caret
    /// — means the badge doesn't chase the user as they type. Matches the
    /// Cotypist behaviour the user explicitly asked for.
    public func show(at fieldRectQuartz: CGRect) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
        // Sit just outside the field's top-left corner: 4pt left, 4pt above.
        let appKitY = primaryHeight - fieldRectQuartz.minY - 4
        let appKitX = fieldRectQuartz.origin.x - Self.diameter - 4
        let frame = NSRect(
            x: max(0, appKitX),
            y: max(0, appKitY),
            width: Self.diameter,
            height: Self.diameter
        )
        panel.setFrame(frame, display: true)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    public func hide() {
        if panel.isVisible {
            panel.orderOut(nil)
        }
    }
}

/// Custom view that paints the brand mark — the « s » + point oxblood sur son
/// médaillon papier (kit `Resources/Brand`, 2026-06). Le PNG embarque DÉJÀ le
/// disque, sa bordure et son ombre, dessinés à la taille du badge (22 px + @2x
/// Retina, ajustements optiques inclus) : la vue se contente de l'aspect-fit
/// plein cadre — plus de médaillon programmatique (il doublait la bordure et
/// rétrécissait la marque).
private final class BadgeView: NSView {
    /// Loaded once via `Bundle.module` ; `image(forResource:)` apparie le @2x
    /// automatiquement selon le backing scale de l'écran.
    private static let mark: NSImage? = Bundle.module.image(forResource: "PresenceMark")

    override func draw(_ dirtyRect: NSRect) {
        guard let mark = Self.mark else { return }
        NSGraphicsContext.current?.imageInterpolation = .high
        let imageSize = mark.size
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let drawSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let drawRect = NSRect(
            x: bounds.midX - drawSize.width / 2,
            y: bounds.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        mark.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }
}
