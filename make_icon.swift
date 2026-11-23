// draws the app icon: a book cover in wemmick's blue gradient with a white play symbol and a red bookmark
// ribbon hanging from the top edge.
// build_app.sh uses both forms:
//   swift make_icon.swift build/AppIcon.iconset          rounded icon for older macos, turned into AppIcon.icns
//   swift make_icon.swift --full-bleed build/icon.png    edge to edge art that macos 26 masks to its own shape

import AppKit
import CoreGraphics

// config

let args = CommandLine.arguments.dropFirst().filter { $0 != "--full-bleed" }
let fullBleed = CommandLine.arguments.contains("--full-bleed")
let outDir = args.first ?? (fullBleed ? "build/icon.png" : "build/AppIcon.iconset")
let canvas: CGFloat = 1024
// a cover in wemmick's gradient, a white play symbol, and a red ribbon
let top = (r: 47, g: 111, b: 222)
let bottom = (r: 24, g: 52, b: 110)
let ink = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
let ribbonRed = CGColor(srgbRed: 229 / 255, green: 72 / 255, blue: 77 / 255, alpha: 1)

func rgb(_ c: (r: Int, g: Int, b: Int)) -> CGColor {
    CGColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
}

// drawing (coordinates are top down: y grows toward the bottom of the icon)

func drawBackground(_ ctx: CGContext, in rect: CGRect) {
    // the whole icon is the book's cover, in wemmick's top to bottom gradient
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(colorsSpace: space, colors: [rgb(top), rgb(bottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func drawBook(_ ctx: CGContext) {
    ctx.saveGState()
    ctx.setLineJoin(.round)

    // play symbol in the middle of the cover, with softened corners
    let cx: CGFloat = 532
    let cy: CGFloat = 548
    let h: CGFloat = 372
    let w: CGFloat = 322
    let play = CGMutablePath()
    play.move(to: CGPoint(x: cx - w / 2, y: cy - h / 2))
    play.addLine(to: CGPoint(x: cx - w / 2, y: cy + h / 2))
    play.addLine(to: CGPoint(x: cx + w / 2, y: cy))
    play.closeSubpath()
    ctx.addPath(play)
    ctx.setFillColor(ink)
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(64)
    ctx.drawPath(using: .fillStroke)

    // red bookmark ribbon hanging from the top edge, with a notched tail. it starts above the
    // canvas so it reads as tucked into the pages
    let left: CGFloat = 584
    let right: CGFloat = 784
    let tail: CGFloat = 300
    let ribbon = CGMutablePath()
    ribbon.move(to: CGPoint(x: left, y: -10))
    ribbon.addLine(to: CGPoint(x: right, y: -10))
    ribbon.addLine(to: CGPoint(x: right, y: tail))
    ribbon.addLine(to: CGPoint(x: (left + right) / 2, y: tail - 86))
    ribbon.addLine(to: CGPoint(x: left, y: tail))
    ribbon.closeSubpath()
    ctx.addPath(ribbon)
    ctx.setFillColor(ribbonRed)
    ctx.fillPath()
    ctx.restoreGState()
}

func drawIcon(_ ctx: CGContext) {
    // flip to top-down coordinates
    ctx.translateBy(x: 0, y: canvas)
    ctx.scaleBy(x: 1, y: -1)

    if fullBleed {
        // edge to edge; macos 26 masks it to its own shape and adds its own shadow
        drawBackground(ctx, in: CGRect(x: 0, y: 0, width: canvas, height: canvas))
        drawBook(ctx)
        return
    }

    // older macos: the 824 pt rounded body on the 1024 grid, with a soft shadow
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgb(bottom))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    drawBackground(ctx, in: body)
    // the drawing shrinks with the body
    ctx.translateBy(x: 512, y: 512)
    ctx.scaleBy(x: 824 / canvas, y: 824 / canvas)
    ctx.translateBy(x: -512, y: -512)
    drawBook(ctx)
    ctx.restoreGState()
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
