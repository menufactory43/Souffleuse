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

/// Custom view that paints the brand mark on a small cream medallion: a soft
/// cream disc (the mark's native background colour) with a thin light border,
/// and the transparent `PresenceMark` PNG aspect-fit and centred on top. The
/// disc keeps the navy waves legible over both light and dark text fields.
private final class BadgeView: NSView {
    /// Loaded once: the detoured, transparent brand mark (cream background
    /// stripped). Bundled as a package resource via `Bundle.module`.
    private static let mark: NSImage? = Bundle.module.image(forResource: "PresenceMark")

    /// Cream backing — the mark's native canvas colour (#FBF7F1).
    private static let discColor = NSColor(srgbRed: 251 / 255, green: 247 / 255, blue: 241 / 255, alpha: 1.0)
    private static let discStroke = NSColor.white.withAlphaComponent(0.35)

    override func draw(_ dirtyRect: NSRect) {
        // Cream medallion behind the mark, inset to leave room for the stroke.
        let disc = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        Self.discColor.setFill()
        disc.fill()
        Self.discStroke.setStroke()
        disc.lineWidth = 1
        disc.stroke()

        guard let mark = Self.mark else { return }

        // High-quality downscale from the source PNG to the tiny badge size.
        NSGraphicsContext.current?.imageInterpolation = .high

        // Aspect-fit the mark inside the disc with enough inset that the wide
        // wave tips stay clear of the circular edge.
        let box = bounds.insetBy(dx: 2.5, dy: 2.5)
        let imageSize = mark.size
        let scale = min(box.width / imageSize.width, box.height / imageSize.height)
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
