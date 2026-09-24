import AppKit
import CoreImage

// Composites the README image: the mixer (rendered by PanelSnapshotTests) on a
// glass panel hanging from a menu bar, beside the app icon and name. Real glass
// needs a live window server, so the glass here is the background blurred,
// tinted, and edged, the way the panel looks over a colorful desktop.
//
// Usage: swift scripts/make-readme-image.swift <mixer-dark-clear@2x.png> <icon-1024.png> <output.jpg|png>

let args = CommandLine.arguments
guard args.count == 4, let panelRep = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: args[1]))) ?? Data()),
      let icon = NSImage(contentsOfFile: args[2]) else {
    print("Usage: swift scripts/make-readme-image.swift <mixer-dark-clear@2x.png> <icon-1024.png> <output.jpg|png>")
    exit(1)
}

let scale: CGFloat = 2
let canvas = NSSize(width: 1200, height: 560)
let menuBarHeight: CGFloat = 28
let panelSize = NSSize(width: CGFloat(panelRep.pixelsWide) / scale, height: CGFloat(panelRep.pixelsHigh) / scale)
panelRep.size = panelSize

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
/// Rect in top-left coordinates, converted to AppKit's bottom-left origin.
func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: x, y: canvas.height - y - h, width: w, height: h)
}
func render(_ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = canvas
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// Desktop: the icon's deep indigo, lit by its coral, sky, and mint.
let desktop = render {
    NSGradient(colors: [rgb(44, 34, 104), rgb(24, 20, 62), rgb(10, 10, 28)], atLocations: [0, 0.55, 1],
               colorSpace: .sRGB)!.draw(in: NSRect(origin: .zero, size: canvas), angle: -70)
    for (x, y, radius, color) in [(760.0, 90.0, 420.0, rgb(255, 84, 104, 0.55)), (1080, 380, 380, rgb(64, 132, 255, 0.55)),
                                  (820, 560, 300, rgb(40, 200, 150, 0.45)), (120, 600, 360, rgb(255, 120, 110, 0.18))] {
        let center = NSPoint(x: x, y: canvas.height - y)
        NSGradient(colors: [color, color.withAlphaComponent(0)])!
            .draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
    }
}

let context = CIContext()
func blurred(_ rep: NSBitmapImageRep, radius: CGFloat) -> NSImage {
    let input = CIImage(bitmapImageRep: rep)!
    let output = input.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: input.extent)
    let image = NSImage(cgImage: context.createCGImage(output, from: input.extent)!, size: canvas)
    return image
}
let frosted = blurred(desktop, radius: 36)

// Menu bar items, right to left: clock, Control Center, Wi-Fi, battery, then Soundcheck.
let menuFont = NSFont.systemFont(ofSize: 13, weight: .medium)
let clock = NSAttributedString(string: "Wed Sep 24  9:41", attributes: [.font: menuFont, .foregroundColor: NSColor.white])
var itemX = canvas.width - 16 - clock.size().width
let clockX = itemX
var symbols: [(String, CGFloat)] = []
for name in ["switch.2", "wifi", "battery.100percent"] {
    itemX -= 32
    symbols.append((name, itemX))
}
itemX -= 34
let soundcheckItem = rect(itemX, 3, 30, 22)
let panelFrame = rect(min(canvas.width - panelSize.width - 10, soundcheckItem.maxX + 12 - panelSize.width),
                      menuBarHeight + 8, panelSize.width, panelSize.height)
let glassPath = NSBezierPath(roundedRect: panelFrame, xRadius: 24, yRadius: 24)

let final = render {
    desktop.draw(in: NSRect(origin: .zero, size: canvas))

    // Menu bar: a light frosted strip with the Soundcheck item highlighted, as when the panel is open.
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: rect(0, 0, canvas.width, menuBarHeight)).addClip()
    frosted.draw(in: NSRect(origin: .zero, size: canvas))
    NSColor.white.withAlphaComponent(0.1).setFill()
    rect(0, 0, canvas.width, menuBarHeight).fill()
    NSGraphicsContext.restoreGraphicsState()
    clock.draw(at: NSPoint(x: clockX, y: canvas.height - 21))
    for (name, x) in symbols {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium).applying(.init(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            symbol.draw(in: rect(x + (22 - symbol.size.width) / 2, (menuBarHeight - symbol.size.height) / 2, symbol.size.width, symbol.size.height))
        }
    }
    NSColor.white.withAlphaComponent(0.2).setFill()
    NSBezierPath(roundedRect: soundcheckItem, xRadius: 6, yRadius: 6).fill()
    // The status glyph: three knobless faders at the brand levels (see StatusIcon.swift).
    var faderX = soundcheckItem.midX - (3 * 4 + 2 * 2.5) / 2
    for level in [0.72, 0.28, 0.88] as [CGFloat] {
        let track = NSRect(x: faderX, y: soundcheckItem.midY - 7, width: 4, height: 14)
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: faderX, y: track.minY, width: 4, height: 4 + 10 * level), xRadius: 2, yRadius: 2).fill()
        faderX += 6.5
    }

    // Soft shadow under the glass.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowBlurRadius = 34
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()
    NSColor.black.setFill()
    glassPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Glass: the blurred desktop, a dark tint, and a thin light edge.
    NSGraphicsContext.saveGraphicsState()
    glassPath.addClip()
    frosted.draw(in: NSRect(origin: .zero, size: canvas))
    NSColor.black.withAlphaComponent(0.34).setFill()
    panelFrame.fill()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.08), NSColor.white.withAlphaComponent(0)])!
        .draw(in: panelFrame, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    let edge = NSBezierPath(roundedRect: panelFrame.insetBy(dx: 0.5, dy: 0.5), xRadius: 23.5, yRadius: 23.5)
    edge.lineWidth = 1
    NSColor.white.withAlphaComponent(0.16).setStroke()
    edge.stroke()
    panelRep.draw(in: panelFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)

    // Name and pitch, centered beside the panel.
    let columnX: CGFloat = 84, columnWidth = panelFrame.minX - columnX - 60
    let title = NSAttributedString(string: "Soundcheck", attributes: [
        .font: NSFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: NSColor.white, .kern: -1.2])
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineHeightMultiple = 1.08
    let pitch = NSAttributedString(string: "A volume for every app, right in your menu bar.", attributes: [
        .font: NSFont.systemFont(ofSize: 26, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.74),
        .paragraphStyle: paragraph])
    let pitchHeight = pitch.boundingRect(with: NSSize(width: columnWidth, height: 400), options: .usesLineFragmentOrigin).height
    let iconSize: CGFloat = 104
    let blockHeight = iconSize + 22 + title.size().height + 10 + pitchHeight
    var y = menuBarHeight + (canvas.height - menuBarHeight - blockHeight) / 2
    icon.draw(in: rect(columnX - 10, y, iconSize, iconSize))
    y += iconSize + 22
    title.draw(at: NSPoint(x: columnX, y: canvas.height - y - title.size().height))
    y += title.size().height + 10
    pitch.draw(with: rect(columnX, y, columnWidth, pitchHeight), options: .usesLineFragmentOrigin)
}

// JPEG keeps the smooth gradients small; PNG is available for lossless output.
let output = URL(fileURLWithPath: args[3])
let jpeg = ["jpg", "jpeg"].contains(output.pathExtension.lowercased())
try final.representation(using: jpeg ? .jpeg : .png, properties: jpeg ? [.compressionFactor: 0.88] : [:])!.write(to: output)
print("Wrote \(args[3]) (\(final.pixelsWide)×\(final.pixelsHigh))")
