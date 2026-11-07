import AppKit
import Foundation

// Original vector artwork. Render each macOS icon size directly for crisp edges.
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = root.appendingPathComponent("AgentDock.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}
func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}
func fill(_ rect: NSRect, radius: CGFloat, color: NSColor) {
    color.setFill(); rounded(rect, radius).fill()
}
func draw(size: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    // A restrained squircle tile with transparent outer corners.
    let tile = rounded(NSRect(x: 80, y: 80, width: 864, height: 864), 194)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0.12, 0.09, 0.30, 0.28)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -13)
    shadow.set()
    color(0.35, 0.29, 0.81).setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0.55, 0.46, 0.96), color(0.33, 0.27, 0.79), color(0.23, 0.19, 0.61)])!.draw(in: tile, angle: -65)
    let edge = rounded(NSRect(x: 82, y: 82, width: 860, height: 860), 192)
    color(1, 1, 1, 0.18).setStroke(); edge.lineWidth = 3; edge.stroke()

    // Two rear cards and one front conversation: a visible aggregation motif.
    fill(NSRect(x: 211, y: 530, width: 548, height: 253), radius: 60, color: color(0.84, 0.82, 1, 0.35))
    fill(NSRect(x: 242, y: 459, width: 548, height: 253), radius: 60, color: color(0.92, 0.90, 1, 0.65))
    NSGraphicsContext.saveGraphicsState()
    let cardShadow = NSShadow()
    cardShadow.shadowColor = color(0.12, 0.08, 0.38, 0.25)
    cardShadow.shadowBlurRadius = 25
    cardShadow.shadowOffset = NSSize(width: 0, height: -14)
    cardShadow.set()
    let front = rounded(NSRect(x: 209, y: 294, width: 606, height: 342), 70)
    color(0.99, 0.99, 1).setFill(); front.fill()
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: 292, y: 316))
    tail.line(to: NSPoint(x: 292, y: 231))
    tail.curve(to: NSPoint(x: 306, y: 225), controlPoint1: NSPoint(x: 292, y: 224), controlPoint2: NSPoint(x: 300, y: 220))
    tail.line(to: NSPoint(x: 397, y: 301))
    tail.close(); tail.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Legible even at small sizes: icon dot and two conversation lines.
    fill(NSRect(x: 281, y: 489, width: 62, height: 62), radius: 20, color: color(0.42, 0.35, 0.87))
    fill(NSRect(x: 375, y: 505, width: 306, height: 29), radius: 14.5, color: color(0.42, 0.35, 0.87))
    fill(NSRect(x: 281, y: 411, width: 337, height: 28), radius: 14, color: color(0.78, 0.76, 0.91))
    fill(NSRect(x: 281, y: 354, width: 248, height: 28), radius: 14, color: color(0.86, 0.84, 0.95))

    // Green completion beacon, white inset ring to separate it from the card.
    fill(NSRect(x: 648, y: 224, width: 182, height: 182), radius: 91, color: color(0.99, 0.99, 1))
    fill(NSRect(x: 662, y: 238, width: 154, height: 154), radius: 77, color: color(0.15, 0.72, 0.51))
    let check = NSBezierPath()
    check.move(to: NSPoint(x: 702, y: 313))
    check.line(to: NSPoint(x: 728, y: 287))
    check.line(to: NSPoint(x: 776, y: 338))
    check.lineWidth = 15; check.lineCapStyle = .round; check.lineJoinStyle = .round
    NSColor.white.setStroke(); check.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
        try draw(size: points * scale).write(to: iconset.appendingPathComponent(name))
    }
}
try draw(size: 1024).write(to: root.appendingPathComponent("AgentDock.png"))
print("Generated original AgentDock artwork and macOS iconset")
