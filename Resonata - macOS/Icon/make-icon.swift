// Draws Resonata's app icon and writes Icon/AppIcon.icns.
//
//   swift Icon/make-icon.swift
//
// Drawn in code rather than kept as a picture, so it can be changed here and
// redrawn: the notch at the top with a cover and three bars, as the app
// looks closed, and an album-coloured wave below it, as it looks open. Every
// size is drawn from the shapes, not scaled down from the big one, so the
// small sizes stay sharp. build.sh copies the .icns into the app.

import AppKit

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// Draws the icon on a 1024-point canvas, y up, scaled to the context.
func draw(in ctx: CGContext) {
    // The tile: Apple's grid puts the body 100 pt in from each edge.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // A soft shadow under the tile, as macOS icons have.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(rgb(20, 14, 32))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()

    // Night sky: plum at the top, near-black at the bottom.
    let sky = CGGradient(colorsSpace: nil, colors: [rgb(64, 36, 84), rgb(30, 20, 48), rgb(12, 9, 20)] as CFArray,
                         locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])

    // A warm glow behind the wave.
    let glow = CGGradient(colorsSpace: nil, colors: [rgb(236, 92, 150, 0.55), rgb(236, 92, 150, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 320), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 320), endRadius: 400, options: [])

    // The wave: a filled band under a bright line, in the album colours.
    func wave(_ y: CGFloat, _ amp: CGFloat, _ phase: CGFloat) -> CGMutablePath {
        let path = CGMutablePath()
        for i in 0...96 {
            let x = 100 + CGFloat(i) * 824 / 96
            let t = CGFloat(i) / 96 * 3.4 * .pi + phase
            // Louder in the middle, quiet at the edges, like the app's wave.
            let swell = 0.45 + 0.55 * sin(CGFloat(i) / 96 * .pi)
            let point = CGPoint(x: x, y: y + amp * swell * (sin(t) + 0.3 * sin(t * 2.3)))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
    let line = wave(330, 52, 0.4)
    let band = line.mutableCopy()!
    band.addLine(to: CGPoint(x: 924, y: 100))
    band.addLine(to: CGPoint(x: 100, y: 100))
    band.closeSubpath()
    ctx.saveGState()
    ctx.addPath(band)
    ctx.clip()
    let fill = CGGradient(colorsSpace: nil, colors: [rgb(236, 92, 150, 0.42), rgb(248, 150, 96, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(fill, start: CGPoint(x: 0, y: 400), end: CGPoint(x: 0, y: 160), options: [])
    ctx.restoreGState()
    ctx.addPath(line)
    ctx.setStrokeColor(rgb(255, 128, 176))
    ctx.setLineWidth(14)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    // The notch, hanging from the top edge: square shoulders, round bottom.
    let notch = CGRect(x: 512 - 290, y: 924 - 170, width: 580, height: 170 + 40)
    ctx.addPath(CGPath(roundedRect: notch, cornerWidth: 78, cornerHeight: 78, transform: nil))
    ctx.setFillColor(rgb(0, 0, 0))
    ctx.fillPath()

    // In it, the cover on the left: a sunset square.
    let cover = CGRect(x: notch.minX + 52, y: notch.minY + 34, width: 96, height: 96)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: cover, cornerWidth: 16, cornerHeight: 16, transform: nil))
    ctx.clip()
    let sunset = CGGradient(colorsSpace: nil, colors: [rgb(250, 140, 92), rgb(196, 64, 122), rgb(52, 30, 92)] as CFArray,
                            locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(sunset, start: CGPoint(x: 0, y: cover.minY), end: CGPoint(x: 0, y: cover.maxY), options: [])
    ctx.setFillColor(rgb(255, 214, 140))
    ctx.fillEllipse(in: CGRect(x: cover.midX - 24, y: cover.minY + 22, width: 48, height: 48))
    ctx.restoreGState()

    // ...and the three bars on the right, mid-beat.
    let heights: [CGFloat] = [62, 100, 76]
    for (i, h) in heights.enumerated() {
        let x = notch.maxX - 52 - 26 - CGFloat(2 - i) * 42
        let bar = CGRect(x: x, y: cover.midY - h / 2, width: 26, height: h)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 13, cornerHeight: 13, transform: nil))
    }
    ctx.setFillColor(rgb(255, 255, 255))
    ctx.fillPath()

    ctx.restoreGState()
}

func png(pixels: Int) -> Data {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw(in: ctx)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try! png(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try! png(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
try! png(pixels: 1024).write(to: here.appendingPathComponent("AppIcon-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", here.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Icon/AppIcon.icns" : "iconutil failed")
