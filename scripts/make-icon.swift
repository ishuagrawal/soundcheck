import AppKit
import Foundation

// Soundcheck's icon: three knobless capsule faders, the same shape as the panel's
// sliders, each filled with its own app-like color. The middle one is turned
// down: one app, turned down. Usage: swift scripts/make-icon.swift <appiconset dir>

let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// Apple's macOS icon body: an 824 pt rounded square centered on a 1024 canvas.
func squircle(_ rect: NSRect) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
}

func capsule(_ rect: NSRect) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: rect.width / 2, yRadius: rect.width / 2)
}

func drawIcon() {
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(body)

    // Drop shadow under the body, then a deep indigo body with a soft top glow.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.32)
    shadow.shadowBlurRadius = 24; shadow.shadowOffset = .init(width: 0, height: -10)
    shadow.set()
    rgb(20, 18, 48).setFill(); shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [rgb(58, 44, 128), rgb(30, 24, 78), rgb(12, 12, 34)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: body, angle: -90)
    NSGradient(starting: rgb(150, 130, 255, 0.35), ending: rgb(150, 130, 255, 0))!
        .draw(fromCenter: .init(x: 512, y: 900), radius: 0, toCenter: .init(x: 512, y: 900), radius: 560, options: [])

    let faders: [(level: CGFloat, top: NSColor, bottom: NSColor)] = [
        (0.70, rgb(255, 150, 120), rgb(255, 84, 104)),   // coral
        (0.26, rgb(120, 200, 255), rgb(64, 132, 255)),   // sky
        (0.88, rgb(140, 245, 190), rgb(40, 200, 150))    // mint
    ]
    let width: CGFloat = 132, height: CGFloat = 540, gap: CGFloat = 52
    var x = 512 - (3 * width + 2 * gap) / 2
    let y: CGFloat = 512 - height / 2 - 6
    for fader in faders {
        let track = NSRect(x: x, y: y, width: width, height: height)
        rgb(255, 255, 255, 0.09).setFill(); capsule(track).fill()
        let edge = capsule(track.insetBy(dx: 1.5, dy: 1.5))
        rgb(255, 255, 255, 0.12).setStroke(); edge.lineWidth = 3; edge.stroke()

        let fillRect = NSRect(x: x, y: y, width: width, height: width + (height - width) * fader.level)
        let fill = capsule(fillRect)
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = fader.bottom.withAlphaComponent(0.65)
        glow.shadowBlurRadius = 46; glow.shadowOffset = .zero
        glow.set()
        fader.bottom.setFill(); fill.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: fader.bottom, ending: fader.top)!.draw(in: fill, angle: 90)
        // A glassy highlight along the top of each fill.
        NSGraphicsContext.saveGraphicsState()
        fill.addClip()
        NSGradient(starting: rgb(255, 255, 255, 0), ending: rgb(255, 255, 255, 0.38))!
            .draw(in: NSRect(x: fillRect.minX, y: fillRect.maxY - width * 0.9, width: width, height: width * 0.9), angle: 90)
        NSGraphicsContext.restoreGraphicsState()
        x += width + gap
    }

    // Specular rim: bright along the top edge, fading down the sides.
    let cg = NSGraphicsContext.current!.cgContext
    cg.addPath(shape.cgPath)
    cg.setLineWidth(7)
    cg.replacePathWithStrokedPath()
    cg.clip()
    NSGradient(colors: [rgb(255, 255, 255, 0.45), rgb(255, 255, 255, 0.05), rgb(255, 255, 255, 0.16)],
               atLocations: [0, 0.5, 1], colorSpace: .sRGB)!.draw(in: body, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        drawIcon()
        NSGraphicsContext.restoreGraphicsState()
        let filename = "soundcheck-\(points)@\(scale)x.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination).appendingPathComponent(filename))
        images.append(["filename": filename, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
let metadata: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(
    to: URL(fileURLWithPath: destination).appendingPathComponent("Contents.json"))
