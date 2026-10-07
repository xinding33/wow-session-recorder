// Renders the app icon: a red record button set in a gold ring on a dark night-sky squircle.
//
//   swift scripts/make-icon.swift            writes the asset catalog and assets/icon.png
//   swift scripts/make-icon.swift out.png    writes a single 1024px preview
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws the icon into a 1024×1024 canvas, following the macOS icon grid (824pt body).
func drawIcon(in ctx: CGContext) {
    let canvas: CGFloat = 1024
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let center = CGPoint(x: canvas / 2, y: canvas / 2)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    // Soft drop shadow under the body.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.45)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x15173F).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Night-sky gradient with a faint glow behind the button.
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(starting: color(0x34397F), ending: color(0x0B0C26))!.draw(in: body, angle: -90)
    NSGradient(colors: [color(0x6F7BFF, 0.35), color(0x6F7BFF, 0)])!
        .draw(fromCenter: center, radius: 0, toCenter: center, radius: 400, options: [])
    // A thin top highlight gives the body some depth.
    NSGradient(colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)])!
        .draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Gold ring.
    let ringRadius: CGFloat = 262
    let ringWidth: CGFloat = 44
    let outer = NSBezierPath(ovalIn: CGRect(x: center.x - ringRadius - ringWidth / 2, y: center.y - ringRadius - ringWidth / 2,
                                            width: (ringRadius + ringWidth / 2) * 2, height: (ringRadius + ringWidth / 2) * 2))
    let inner = NSBezierPath(ovalIn: CGRect(x: center.x - ringRadius + ringWidth / 2, y: center.y - ringRadius + ringWidth / 2,
                                            width: (ringRadius - ringWidth / 2) * 2, height: (ringRadius - ringWidth / 2) * 2))
    let ring = NSBezierPath()
    ring.append(outer)
    ring.append(inner.reversed)
    let gold = NSGradient(colors: [color(0xFFE9A3), color(0xE2B04A), color(0x9A6A1E)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    NSGraphicsContext.saveGraphicsState()
    ring.addClip()
    gold.draw(in: outer.bounds, angle: -60)
    NSGraphicsContext.restoreGraphicsState()

    // Four diamond studs on the ring, like a compass rose.
    for angle in stride(from: CGFloat.pi / 2, to: 2.5 * .pi, by: .pi / 2) {
        let p = CGPoint(x: center.x + cos(angle) * ringRadius, y: center.y + sin(angle) * ringRadius)
        let s: CGFloat = 46
        let diamond = NSBezierPath()
        diamond.move(to: CGPoint(x: p.x, y: p.y + s))
        diamond.line(to: CGPoint(x: p.x + s * 0.62, y: p.y))
        diamond.line(to: CGPoint(x: p.x, y: p.y - s))
        diamond.line(to: CGPoint(x: p.x - s * 0.62, y: p.y))
        diamond.close()
        NSGraphicsContext.saveGraphicsState()
        diamond.addClip()
        gold.draw(in: diamond.bounds, angle: -60)
        NSGraphicsContext.restoreGraphicsState()
        color(0x5C3D0E, 0.6).setStroke()
        diamond.lineWidth = 4
        diamond.stroke()
    }

    // Red record button with a glossy highlight.
    let dotRadius: CGFloat = 168
    let dotRect = CGRect(x: center.x - dotRadius, y: center.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
    let dot = NSBezierPath(ovalIn: dotRect)
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = color(0xFF3B30, 0.55)
    glow.shadowBlurRadius = 40
    glow.set()
    color(0xD7261E).setFill()
    dot.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    dot.addClip()
    let lightSpot = CGPoint(x: center.x - 50, y: center.y + 60)
    NSGradient(colors: [color(0xFF7A6B), color(0xE0291F), color(0x9E1410)], atLocations: [0, 0.6, 1], colorSpace: .sRGB)!
        .draw(fromCenter: lightSpot, radius: 0, toCenter: center, radius: dotRadius, options: [.drawsAfterEndingLocation])
    let gloss = NSBezierPath(ovalIn: CGRect(x: center.x - 112, y: center.y + 38, width: 224, height: 110))
    NSGradient(colors: [color(0xFFFFFF, 0.45), color(0xFFFFFF, 0)])!.draw(in: gloss, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    drawIcon(in: context.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

_ = NSApplication.shared
let args = CommandLine.arguments
if args.count > 1 {
    try render(size: 1024).write(to: URL(fileURLWithPath: args[1]))
    exit(0)
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appending(path: "SessionRecorder/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(size: points * scale).write(to: iconset.appending(path: name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconset.appending(path: "Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": ["author": "xcode", "version": 1]], options: [.prettyPrinted])
    .write(to: iconset.deletingLastPathComponent().appending(path: "Contents.json"))
try render(size: 256).write(to: root.appending(path: "assets/icon.png"))
print("Wrote \(iconset.path) and assets/icon.png")
