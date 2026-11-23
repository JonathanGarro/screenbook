// draws the app icon. build_app.sh uses both forms:
//   swift make_icon.swift build/AppIcon.iconset          rounded icon for older macos, turned into AppIcon.icns
//   swift make_icon.swift --full-bleed build/icon.png    edge to edge art that macos 26 masks to its own shape

import AppKit
import CoreGraphics

// config

let args = CommandLine.arguments.dropFirst().filter { $0 != "--full-bleed" }
let fullBleed = CommandLine.arguments.contains("--full-bleed")
let outDir = args.first ?? (fullBleed ? "build/icon.png" : "build/AppIcon.iconset")
let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

// drawing

func drawIcon(_ ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // macos icon grid: 824pt body centered on a 1024 canvas, or the whole canvas for macos 26,
    // which masks the art to its own shape and adds its own shadow
    let body = fullBleed ? CGRect(x: 0, y: 0, width: canvas, height: canvas) : CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = fullBleed ? CGPath(rect: body, transform: nil)
        : CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // drop shadow under the body
    if !fullBleed {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
        ctx.addPath(bodyPath)
        ctx.setFillColor(color(0x241a52))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // background gradient
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [color(0x3a2a86), color(0x1d6f8c), color(0x22a39a)] as CFArray,
                        locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: body.minX + 100, y: body.maxY), end: CGPoint(x: body.maxX - 100, y: body.minY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // soft highlight in the upper left
    let glow = CGGradient(colorsSpace: space, colors: [color(0xffffff, 0.18), color(0xffffff, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 800), startRadius: 0,
                           endCenter: CGPoint(x: 330, y: 800), endRadius: 520, options: [])
    ctx.restoreGState()

    // edge to edge art has more room, so the drawing grows to fill it
    if fullBleed {
        ctx.translateBy(x: 512, y: 512)
        ctx.scaleBy(x: 1.14, y: 1.14)
        ctx.translateBy(x: -512, y: -512)
    }

    // screen with a stand
    let screen = CGRect(x: 222, y: 352, width: 580, height: 400)
    let screenPath = CGPath(roundedRect: screen, cornerWidth: 64, cornerHeight: 64, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x0b0626, 0.4))
    ctx.addPath(screenPath)
    ctx.setFillColor(color(0xffffff, 0.96))
    ctx.fillPath()
    ctx.restoreGState()

    let stand = CGPath(roundedRect: CGRect(x: 432, y: 296, width: 160, height: 30), cornerWidth: 15, cornerHeight: 15, transform: nil)
    ctx.addPath(stand)
    ctx.setFillColor(color(0xffffff, 0.85))
    ctx.fillPath()
    ctx.fill(CGRect(x: 494, y: 320, width: 36, height: 36))

    // play triangle filled with the background gradient
    let tri = CGMutablePath()
    tri.move(to: CGPoint(x: 458, y: 470))
    tri.addLine(to: CGPoint(x: 458, y: 634))
    tri.addLine(to: CGPoint(x: 600, y: 552))
    tri.closeSubpath()
    let rounded = tri.copy(strokingWithWidth: 36, lineCap: .round, lineJoin: .round, miterLimit: 10)
    ctx.saveGState()
    ctx.addPath(tri)
    ctx.addPath(rounded)
    ctx.clip(using: .winding)
    ctx.drawLinearGradient(bg, start: CGPoint(x: 440, y: 650), end: CGPoint(x: 620, y: 450), options: [])
    ctx.restoreGState()

    // watched badge in the lower right
    let center = CGPoint(x: 742, y: 300)
    let radius: CGFloat = 112
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: color(0x0b0626, 0.45))
    ctx.addEllipse(in: CGRect(x: center.x - radius - 14, y: center.y - radius - 14, width: (radius + 14) * 2, height: (radius + 14) * 2))
    ctx.setFillColor(color(0xffffff))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    ctx.clip()
    let green = CGGradient(colorsSpace: space, colors: [color(0x5fd36b), color(0x2fa84a)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(green, start: CGPoint(x: center.x, y: center.y + radius), end: CGPoint(x: center.x, y: center.y - radius), options: [])
    ctx.restoreGState()

    let check = CGMutablePath()
    check.move(to: CGPoint(x: center.x - 52, y: center.y + 2))
    check.addLine(to: CGPoint(x: center.x - 14, y: center.y - 38))
    check.addLine(to: CGPoint(x: center.x + 56, y: center.y + 44))
    ctx.addPath(check)
    ctx.setStrokeColor(color(0xffffff))
    ctx.setLineWidth(30)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
}

// rendering

func render(size: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let scale = CGFloat(size) / canvas
    ctx.scaleBy(x: scale, y: scale)
    drawIcon(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

// main

if fullBleed {
    try FileManager.default.createDirectory(at: URL(fileURLWithPath: outDir).deletingLastPathComponent(), withIntermediateDirectories: true)
    try render(size: 1024).write(to: URL(fileURLWithPath: outDir))
    print("Wrote \(outDir)")
    exit(0)
}
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(base)x\(base)@2x.png"))
}
print("Wrote \(outDir)")
