import AppKit
import Foundation

private enum Palette {
    static let paper = NSColor(
        srgbRed: 243.0 / 255.0,
        green: 234.0 / 255.0,
        blue: 217.0 / 255.0,
        alpha: 1
    )
    static let paperCard = NSColor(
        srgbRed: 251.0 / 255.0,
        green: 245.0 / 255.0,
        blue: 234.0 / 255.0,
        alpha: 1
    )
    static let paperDeep = NSColor(
        srgbRed: 236.0 / 255.0,
        green: 224.0 / 255.0,
        blue: 201.0 / 255.0,
        alpha: 1
    )
    static let ink = NSColor(
        srgbRed: 26.0 / 255.0,
        green: 22.0 / 255.0,
        blue: 19.0 / 255.0,
        alpha: 1
    )
    static let oxblood = NSColor(
        srgbRed: 140.0 / 255.0,
        green: 43.0 / 255.0,
        blue: 33.0 / 255.0,
        alpha: 1
    )
}

private struct IconMetrics {
    let inset: CGFloat
    let cornerRadius: CGFloat
    let borderWidth: CGFloat
    let glyphSize: CGFloat
    let glyphXOffset: CGFloat
    let glyphYOffset: CGFloat
    let dotSize: CGFloat
    let dotX: CGFloat
    let dotY: CGFloat
    let shadowOffset: CGFloat

    static func forSize(_ size: CGFloat) -> IconMetrics {
        if size <= 32 {
            return IconMetrics(
                inset: size * 0.055,
                cornerRadius: size * 0.215,
                borderWidth: max(0.8, size * 0.027),
                glyphSize: size * 0.64,
                glyphXOffset: -size * 0.018,
                glyphYOffset: size * 0.035,
                dotSize: max(2, size * 0.095),
                dotX: size * 0.69,
                dotY: size * 0.69,
                shadowOffset: size * 0.018
            )
        }

        if size <= 128 {
            return IconMetrics(
                inset: size * 0.06,
                cornerRadius: size * 0.205,
                borderWidth: max(1, size * 0.006),
                glyphSize: size * 0.64,
                glyphXOffset: -size * 0.02,
                glyphYOffset: size * 0.03,
                dotSize: size * 0.076,
                dotX: size * 0.69,
                dotY: size * 0.69,
                shadowOffset: size * 0.016
            )
        }

        return IconMetrics(
            inset: size * 0.068,
            cornerRadius: size * 0.2,
            borderWidth: size * 0.0048,
            glyphSize: size * 0.585,
            glyphXOffset: -size * 0.02,
            glyphYOffset: size * 0.032,
            dotSize: size * 0.07,
            dotX: size * 0.7,
            dotY: size * 0.69,
            shadowOffset: size * 0.017
        )
    }
}

private let fileManager = FileManager.default
private let rootURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
private let outputURL = rootURL
    .appendingPathComponent("Souffleuse")
    .appendingPathComponent("Resources")
    .appendingPathComponent("Brand")
private let iconsetURL = outputURL.appendingPathComponent("AppIcon.iconset")

try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

private func bitmap(size: Int) -> (NSBitmapImageRep, NSGraphicsContext) {
    let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    representation.size = NSSize(width: size, height: size)
    return (representation, NSGraphicsContext(bitmapImageRep: representation)!)
}

private func writePNG(_ representation: NSBitmapImageRep, to url: URL) throws {
    let data = representation.representation(using: .png, properties: [:])!
    try data.write(to: url)
}

private func drawAppIcon(size: Int, output: URL) throws {
    let logicalSize = CGFloat(size)
    let metrics = IconMetrics.forSize(logicalSize)
    let (representation, context) = bitmap(size: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.shouldAntialias = true

    NSColor.clear.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: logicalSize, height: logicalSize)).fill()

    let tile = NSRect(
        x: metrics.inset,
        y: metrics.inset,
        width: logicalSize - metrics.inset * 2,
        height: logicalSize - metrics.inset * 2
    )
    let shadowRect = tile.offsetBy(
        dx: metrics.shadowOffset,
        dy: -metrics.shadowOffset * 1.25
    )
    let shadow = NSBezierPath(
        roundedRect: shadowRect,
        xRadius: metrics.cornerRadius,
        yRadius: metrics.cornerRadius
    )
    Palette.ink.withAlphaComponent(size <= 32 ? 0.18 : 0.13).setFill()
    shadow.fill()

    let tilePath = NSBezierPath(
        roundedRect: tile,
        xRadius: metrics.cornerRadius,
        yRadius: metrics.cornerRadius
    )
    Palette.paperCard.setFill()
    tilePath.fill()
    Palette.ink.withAlphaComponent(size <= 32 ? 0.5 : 0.34).setStroke()
    tilePath.lineWidth = metrics.borderWidth
    tilePath.stroke()

    if size >= 64 {
        let innerInset = logicalSize * 0.018
        let inner = NSBezierPath(
            roundedRect: tile.insetBy(dx: innerInset, dy: innerInset),
            xRadius: metrics.cornerRadius - innerInset,
            yRadius: metrics.cornerRadius - innerInset
        )
        Palette.paper.setStroke()
        inner.lineWidth = max(1, logicalSize * 0.0048)
        inner.stroke()
    }

    let fontName = size <= 32 ? "Georgia-Bold" : "BodoniSvtyTwoITCTT-Bold"
    let font = NSFont(name: fontName, size: metrics.glyphSize)
        ?? NSFont.systemFont(ofSize: metrics.glyphSize, weight: .bold)
    let mark = size <= 32 ? "S" : "s"
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: Palette.ink,
    ]
    let markSize = mark.size(withAttributes: attributes)
    let markPoint = NSPoint(
        x: logicalSize / 2 - markSize.width / 2 + metrics.glyphXOffset,
        y: logicalSize / 2 - markSize.height / 2 + metrics.glyphYOffset
    )

    if size >= 64 {
        mark.draw(
            at: NSPoint(
                x: markPoint.x + logicalSize * 0.009,
                y: markPoint.y - logicalSize * 0.01
            ),
            withAttributes: [
                .font: font,
                .foregroundColor: Palette.paperDeep,
            ]
        )
    }
    mark.draw(at: markPoint, withAttributes: attributes)

    let dot = NSBezierPath(
        ovalIn: NSRect(
            x: metrics.dotX,
            y: metrics.dotY,
            width: metrics.dotSize,
            height: metrics.dotSize
        )
    )
    Palette.oxblood.setFill()
    dot.fill()

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    try writePNG(representation, to: output)
}

private func drawPresence(size: Int, output: URL) throws {
    let logicalSize = CGFloat(size)
    let scale = logicalSize / 44
    let (representation, context) = bitmap(size: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.shouldAntialias = true

    NSColor.clear.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: logicalSize, height: logicalSize)).fill()

    let discRect = NSRect(
        x: 2.5 * scale,
        y: 2.5 * scale,
        width: 39 * scale,
        height: 39 * scale
    )
    let shadow = NSBezierPath(ovalIn: discRect.offsetBy(dx: 0, dy: -1.6 * scale))
    Palette.ink.withAlphaComponent(0.2).setFill()
    shadow.fill()

    let disc = NSBezierPath(ovalIn: discRect)
    Palette.paperCard.setFill()
    disc.fill()
    Palette.ink.withAlphaComponent(0.46).setStroke()
    disc.lineWidth = 1.3 * scale
    disc.stroke()

    let fontSize = 25.5 * scale
    let font = NSFont(name: "BodoniSvtyTwoITCTT-Bold", size: fontSize)
        ?? NSFont.systemFont(ofSize: fontSize, weight: .bold)
    let mark = "s"
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: Palette.ink,
    ]
    let markSize = mark.size(withAttributes: attributes)
    mark.draw(
        at: NSPoint(
            x: logicalSize / 2 - markSize.width / 2 - 0.4 * scale,
            y: logicalSize / 2 - markSize.height / 2 + 1.4 * scale
        ),
        withAttributes: attributes
    )

    let dot = NSBezierPath(
        ovalIn: NSRect(
            x: 28.2 * scale,
            y: 27.8 * scale,
            width: 3.8 * scale,
            height: 3.8 * scale
        )
    )
    Palette.oxblood.setFill()
    dot.fill()

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    try writePNG(representation, to: output)
}

let iconFiles: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, size) in iconFiles {
    try drawAppIcon(size: size, output: iconsetURL.appendingPathComponent(name))
}

try drawAppIcon(
    size: 1024,
    output: outputURL.appendingPathComponent("AppIconMaster-1024.png")
)
try drawAppIcon(
    size: 180,
    output: outputURL.appendingPathComponent("apple-touch-icon.png")
)
try drawAppIcon(
    size: 32,
    output: outputURL.appendingPathComponent("favicon-32.png")
)
try drawPresence(
    size: 22,
    output: outputURL.appendingPathComponent("PresenceMark.png")
)
try drawPresence(
    size: 44,
    output: outputURL.appendingPathComponent("PresenceMark@2x.png")
)
try drawPresence(
    size: 176,
    output: outputURL.appendingPathComponent("PresenceMark-preview.png")
)
