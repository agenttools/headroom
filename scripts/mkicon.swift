// mkicon.swift — draws Headroom's icon: a simple gauge on a dark rounded square (SPEC §8.7).
//
//   swift scripts/mkicon.swift <out.icns>             full macOS iconset (16…1024) packed by iconutil
//   swift scripts/mkicon.swift --png <px> <out.png>   one PNG (e.g. Chrome extension icons 16/48/128)
//
// Every size is drawn directly with Core Graphics at its pixel size (no downscaling), so small sizes
// stay crisp. Small sizes drop the tick marks. No SF Symbols and no fonts, so the output is the same on
// every machine.
import AppKit
import Foundation

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// Draws the icon into a `px`×`px` bitmap. Geometry is in a 1024-unit design space.
func render(px: Int, fullBleed: Bool) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let k = CGFloat(px) / 1024
    ctx.scaleBy(x: k, y: k)

    // Tile: macOS app-icon grid (824 pt square, 100 pt margin, ~185 pt corner) or full bleed for PNGs.
    let tile = fullBleed ? CGRect(x: 0, y: 0, width: 1024, height: 1024) : CGRect(x: 100, y: 100, width: 824, height: 824)
    let radius: CGFloat = fullBleed ? 200 : 185
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    if !fullBleed { // soft drop shadow, like system icons
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
        ctx.addPath(tilePath); ctx.setFillColor(color(0x10161F)); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [color(0x2A3646), color(0x121821)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.minY), options: [])
    // faint top sheen
    let sheen = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.midY), options: [])
    ctx.restoreGState()

    // Gauge: a 240° arc opening downwards, centred a little below the tile's middle.
    let c = CGPoint(x: 512, y: 440)
    let r: CGFloat = 270
    let lw: CGFloat = px <= 32 ? 96 : 64
    let start = CGFloat.pi * 7 / 6        // 210° (lower left)
    let end = -CGFloat.pi / 6             // -30° (lower right)
    let level: CGFloat = 0.34             // how full the gauge reads: plenty of headroom left
    let needleAngle = start + (end - start) * level

    ctx.setLineCap(.round)
    // track
    ctx.setLineWidth(lw)
    ctx.setStrokeColor(color(0xFFFFFF, 0.14))
    ctx.addArc(center: c, radius: r, startAngle: start, endAngle: end, clockwise: true)
    ctx.strokePath()
    // filled part: mint → teal gradient clipped to the arc stroke
    ctx.saveGState()
    ctx.addArc(center: c, radius: r, startAngle: start, endAngle: needleAngle, clockwise: true)
    ctx.setLineWidth(lw)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let fill = CGGradient(colorsSpace: cs, colors: [color(0x3DDC97), color(0x2BB3C0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fill, start: CGPoint(x: c.x - r, y: c.y - r / 2), end: CGPoint(x: c.x, y: c.y + r),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // ticks (only where they are legible)
    if px >= 128 {
        ctx.setLineWidth(14)
        ctx.setStrokeColor(color(0xFFFFFF, 0.35))
        for i in 0...8 {
            let a = start + (end - start) * CGFloat(i) / 8
            let r0 = r - lw / 2 - 34, r1 = r - lw / 2 - (i % 4 == 0 ? 84 : 62)
            ctx.move(to: CGPoint(x: c.x + r0 * cos(a), y: c.y + r0 * sin(a)))
            ctx.addLine(to: CGPoint(x: c.x + r1 * cos(a), y: c.y + r1 * sin(a)))
        }
        ctx.strokePath()
    }

    // needle + hub
    let nLen = r - (px <= 32 ? 40 : 70)
    ctx.setLineWidth(px <= 32 ? 60 : 34)
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.move(to: c)
    ctx.addLine(to: CGPoint(x: c.x + nLen * cos(needleAngle), y: c.y + nLen * sin(needleAngle)))
    ctx.strokePath()
    let hub: CGFloat = px <= 32 ? 70 : 52
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillEllipse(in: CGRect(x: c.x - hub, y: c.y - hub, width: hub * 2, height: hub * 2))
    ctx.setFillColor(color(0x1B2330))
    let hole = hub * 0.42
    ctx.fillEllipse(in: CGRect(x: c.x - hole, y: c.y - hole, width: hole * 2, height: hole * 2))

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--png" {
    guard args.count == 3, let px = Int(args[1]), px > 0 else { fail("usage: mkicon.swift --png <px> <out.png>") }
    try render(px: px, fullBleed: false).write(to: URL(fileURLWithPath: args[2]))
    exit(0)
}
guard args.count == 1 else { fail("usage: mkicon.swift <out.icns> | --png <px> <out.png>") }
let out = URL(fileURLWithPath: args[0])
let set = FileManager.default.temporaryDirectory.appendingPathComponent("Headroom-\(getpid()).iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: set) }
for base in [16, 32, 128, 256, 512] {
    try render(px: base, fullBleed: false).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(px: base * 2, fullBleed: false).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.path]
try p.run(); p.waitUntilExit()
guard p.terminationStatus == 0 else { fail("iconutil failed (\(p.terminationStatus))") }
print("wrote \(out.path)")
