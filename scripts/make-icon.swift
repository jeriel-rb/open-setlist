// Draws the Setlist app icon (a black vinyl record with "OPEN" running clockwise from twelve o'clock)
// and writes every size macOS needs into Setlist/Assets.xcassets/AppIcon.appiconset.
//
//   swift scripts/make-icon.swift
import AppKit
import CoreText

let canvas: CGFloat = 1024
let center = CGPoint(x: canvas / 2, y: canvas / 2)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func circle(_ radius: CGFloat) -> CGRect {
    CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
}

/// Text along a circle, starting at twelve o'clock and running clockwise, tops pointing outwards.
func drawText(_ text: String, radius: CGFloat, font: CTFont, tracking: CGFloat, color: CGColor, in ctx: CGContext) {
    var travelled: CGFloat = 0
    for character in text {
        let attributed = NSAttributedString(string: String(character), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        // Angle of this glyph's middle, measured the usual way (counter-clockwise from three o'clock).
        let angle = .pi / 2 - (travelled + width / 2) / radius
        ctx.saveGState()
        ctx.translateBy(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        ctx.rotate(by: angle - .pi / 2)
        ctx.textPosition = CGPoint(x: -width / 2, y: 0)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        travelled += width + tracking
    }
}

func drawIcon(in ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // Background: the standard macOS icon tile, 824 pt on a 1024 pt canvas, with its soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: color(0x000000, 0.32))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0xF3EDE2))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let paper = CGGradient(colorsSpace: space, colors: [color(0xFBF7EF), color(0xE2D8C6)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(paper, start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.minY), options: [])

    // The record, with a shadow so it sits on the tile.
    let recordRadius: CGFloat = 352
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x000000, 0.45))
    ctx.setFillColor(color(0x0B0B0D))
    ctx.fillEllipse(in: circle(recordRadius))
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addEllipse(in: circle(recordRadius))
    ctx.clip()

    // Sheen: two opposite streaks of reflected light, as on a real record.
    let wedges = 720
    for i in 0..<wedges {
        let a0 = CGFloat(i) / CGFloat(wedges) * 2 * .pi
        let a1 = CGFloat(i + 1) / CGFloat(wedges) * 2 * .pi + 0.002
        let strength = pow(max(0, cos(2 * (a0 - 2.2))), 6)
        guard strength > 0.004 else { continue }
        ctx.move(to: center)
        ctx.addArc(center: center, radius: recordRadius, startAngle: a0, endAngle: a1, clockwise: false)
        ctx.closePath()
        ctx.setFillColor(color(0xFFFFFF, 0.17 * strength))
        ctx.fillPath()
    }

    // Grooves, with the wider gaps that separate one track from the next.
    let labelRadius: CGFloat = 122
    let trackGaps: [CGFloat] = [176, 300]
    var r = labelRadius + 16
    while r < recordRadius - 10 {
        if !trackGaps.contains(where: { abs($0 - r) < 5 }) {
            ctx.setStrokeColor(color(0xFFFFFF, Int(r) % 12 < 6 ? 0.055 : 0.03))
            ctx.setLineWidth(1.4)
            ctx.strokeEllipse(in: circle(r))
        }
        r += 6
    }
    // A fine light edge on the rim.
    ctx.setStrokeColor(color(0xFFFFFF, 0.16))
    ctx.setLineWidth(2)
    ctx.strokeEllipse(in: circle(recordRadius - 1))
    ctx.restoreGState()

    // Label and spindle hole.
    ctx.saveGState()
    ctx.addEllipse(in: circle(labelRadius))
    ctx.clip()
    let label = CGGradient(colorsSpace: space, colors: [color(0xFF7A45), color(0xE8361C)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(label, start: CGPoint(x: 512, y: center.y + labelRadius), end: CGPoint(x: 512, y: center.y - labelRadius), options: [])
    ctx.restoreGState()
    ctx.setStrokeColor(color(0x000000, 0.22))
    ctx.setLineWidth(2)
    ctx.strokeEllipse(in: circle(labelRadius - 20))
    ctx.setFillColor(color(0xF3EDE2))
    ctx.fillEllipse(in: circle(15))
    ctx.setStrokeColor(color(0x000000, 0.35))
    ctx.setLineWidth(2)
    ctx.strokeEllipse(in: circle(15))

    // "OPEN", from twelve o'clock round to the right.
    let size: CGFloat = 92
    let base = NSFont.systemFont(ofSize: size, weight: .heavy)
    let rounded = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    drawText("OPEN", radius: 206, font: rounded as CTFont, tracking: 20, color: color(0xFFFFFF), in: ctx)

    ctx.restoreGState()
}

func render(pixels: Int) -> Data {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    drawIcon(in: ctx)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let catalog = root.appendingPathComponent("Setlist/Assets.xcassets")
let iconset = catalog.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try #"{"info":{"author":"xcode","version":1}}"#.write(to: catalog.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: points * scale).write(to: iconset.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconset.appendingPathComponent("Contents.json"))
print("wrote \(images.count) images to \(iconset.path)")
