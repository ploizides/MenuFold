// Draws the MenuFold app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift            (run from the repo root)
//        swift scripts/make-icon.swift preview.png (also writes a 1024px preview)
//
// Design: the menu bar, folded. A dark squircle; three icons fading out to the left,
// the │ divider, and the ‹ chevron that folds them away.
import Cocoa

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024   // design on a 1024 grid

    // macOS icon grid: 824×824 shape inset 100, corner radius ≈ 185.
    let shape = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s),
                             xRadius: 185 * s, yRadius: 185 * s)

    // Soft drop shadow under the shape.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSColor(srgbRed: 0.10, green: 0.11, blue: 0.15, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Background: deep graphite gradient.
    NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.22, blue: 0.29, alpha: 1),
               ending: NSColor(srgbRed: 0.09, green: 0.10, blue: 0.14, alpha: 1))!
        .draw(in: shape, angle: -90)

    // Subtle top highlight.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(starting: NSColor.white.withAlphaComponent(0.10), ending: NSColor.white.withAlphaComponent(0))!
        .draw(in: NSRect(x: 100 * s, y: 560 * s, width: 824 * s, height: 364 * s), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let midY = 512 * s
    let white = NSColor.white

    // Three "menu bar icons" fading out to the left.
    let dotR = 32 * s
    for (i, alpha) in [0.18, 0.38, 0.62].enumerated() {
        let cx = (250 + CGFloat(i) * 100) * s
        white.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: NSRect(x: cx - dotR, y: midY - dotR, width: dotR * 2, height: dotR * 2)).fill()
    }

    // The │ divider.
    white.withAlphaComponent(0.55).setFill()
    NSBezierPath(roundedRect: NSRect(x: 552 * s, y: midY - 116 * s, width: 16 * s, height: 232 * s),
                 xRadius: 8 * s, yRadius: 8 * s).fill()

    // The ‹ chevron, in an accent colour.
    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: 778 * s, y: midY + 112 * s))
    chevron.line(to: NSPoint(x: 672 * s, y: midY))
    chevron.line(to: NSPoint(x: 778 * s, y: midY - 112 * s))
    chevron.lineWidth = 44 * s
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    NSColor(srgbRed: 0.40, green: 0.85, blue: 0.78, alpha: 1).setStroke()
    chevron.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! drawIcon(size: px).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}

try! fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")

if CommandLine.arguments.count > 1 {
    try! drawIcon(size: 1024).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    print("Wrote preview \(CommandLine.arguments[1])")
}
