// Generates Resources/AppIcon.icns : swiftc tools/make-icon.swift -o /tmp/mkicon && /tmp/mkicon
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(red: 0.90, green: 0.50, blue: 0.36, alpha: 1), ending: NSColor(red: 0.75, green: 0.36, blue: 0.24, alpha: 1))!
        .draw(in: shape, angle: -90)
    // gauge: 270° ring, open at the bottom
    let c = NSPoint(x: 512 * s, y: 512 * s), r = 235 * s
    func arc(_ from: CGFloat, _ to: CGFloat, _ color: NSColor) {
        let p = NSBezierPath()
        p.appendArc(withCenter: c, radius: r, startAngle: from, endAngle: to, clockwise: true)
        p.lineWidth = 78 * s; p.lineCapStyle = .round
        color.setStroke(); p.stroke()
    }
    arc(225, -45, NSColor.white.withAlphaComponent(0.28))        // track
    arc(225, 225 - 270 * 0.62, .white)                           // progress
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = "build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png"))
}
