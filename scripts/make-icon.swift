// Draws Airflow's icon from code — a microphone whose voice waves straighten into
// typed lines of text, ending in a text cursor — and writes:
//   Resources/AppIcon.icns                 app icon (Finder, Dock, permission lists)
//   Resources/MenuBarIcon.png / @2x.png    monochrome template for the menu bar
//   build/AppIcon.iconset/                 the individual PNGs (preview: icon_512x512@2x.png)
//
// Usage (from the repo root): swift scripts/make-icon.swift   — or: make icon
import AppKit

let canvas: CGFloat = 1024
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let violet = color(0x6B5CFC)
let cyan = color(0x1CC4E6)
let cursorYellow = color(0xFFD166)
let white = color(0xFFFFFF)
let black = color(0x000000)

/// The glyph, in 1024-canvas coordinates with y pointing down.
/// Content bounds: x 204…817, y 290…717.
func drawGlyph(_ ctx: CGContext, ink: CGColor, accent: CGColor, weight: CGFloat) {
    let stroke = 34 * weight
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(ink)
    ctx.setFillColor(ink)
    ctx.setLineWidth(stroke)

    // Microphone: capsule, U-shaped holder, stem, base.
    ctx.addPath(CGPath(
        roundedRect: CGRect(x: 271, y: 290, width: 150, height: 270),
        cornerWidth: 75, cornerHeight: 75, transform: nil))
    ctx.fillPath()
    ctx.addArc(center: CGPoint(x: 346, y: 480), radius: 125, startAngle: 0, endAngle: .pi, clockwise: false)
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 346, y: 605))
    ctx.addLine(to: CGPoint(x: 346, y: 700))
    ctx.move(to: CGPoint(x: 281, y: 700))
    ctx.addLine(to: CGPoint(x: 411, y: 700))
    ctx.strokePath()

    // Voice → text: each line starts as a decaying wave and settles into a straight "typed" line.
    let lines: [(y: CGFloat, end: CGFloat, amplitude: CGFloat)] = [(405, 800, 15), (485, 760, -15), (565, 690, 15)]
    let waveStart: CGFloat = 525
    let waveEnd: CGFloat = 655
    for line in lines {
        // One smooth period whose height fades to zero: sound settling into a line of text.
        func y(at x: CGFloat) -> CGFloat {
            let t = (x - waveStart) / (waveEnd - waveStart)
            return line.y - line.amplitude * (1 - t) * sin(t * .pi * 2)
        }
        ctx.move(to: CGPoint(x: waveStart, y: y(at: waveStart)))
        var x = waveStart
        while x < waveEnd {
            x = min(x + 2, waveEnd)
            ctx.addLine(to: CGPoint(x: x, y: y(at: x)))
        }
        ctx.addLine(to: CGPoint(x: line.end, y: line.y))
        ctx.strokePath()
    }

    // Text cursor after the last line.
    let cursorWidth = 18 * weight
    ctx.setFillColor(accent)
    ctx.addPath(CGPath(
        roundedRect: CGRect(x: 735 - cursorWidth / 2, y: 518, width: cursorWidth, height: 94),
        cornerWidth: cursorWidth / 2, cornerHeight: cursorWidth / 2, transform: nil))
    ctx.fillPath()
}

func makeBitmap(_ width: Int, _ height: Int) -> (NSBitmapImageRep, CGContext) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    context.interpolationQuality = .high
    context.setShouldAntialias(true)
    return (rep, context)
}

func renderAppIcon(pixels: Int) -> NSBitmapImageRep {
    let (rep, ctx) = makeBitmap(pixels, pixels)
    let scale = CGFloat(pixels) / canvas
    // Shadows are specified in device space, so scale them by hand.
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: canvas)
    ctx.scaleBy(x: 1, y: -1)

    // macOS icon grid: 824×824 rounded square centered in 1024.
    let body = CGPath(
        roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
        cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 24 * scale, color: color(0x000000, 0.28))
    ctx.addPath(body)
    ctx.setFillColor(cyan)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let background = CGGradient(colorsSpace: srgb, colors: [violet, cyan] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        background, start: CGPoint(x: 260, y: 100), end: CGPoint(x: 764, y: 924),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let gloss = CGGradient(
        colorsSpace: srgb, colors: [color(0xFFFFFF, 0.20), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 540), options: [])
    ctx.restoreGState()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 14 * scale, color: color(0x1B1464, 0.25))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    drawGlyph(ctx, ink: white, accent: cursorYellow, weight: pixels <= 32 ? 1.5 : 1)
    ctx.endTransparencyLayer()
    ctx.restoreGState()
    return rep
}

/// Black-on-transparent glyph for the menu bar (used as a template image).
func renderMenuBarGlyph(pointWidth: CGFloat, pointHeight: CGFloat, pixelScale: CGFloat) -> NSBitmapImageRep {
    let (rep, ctx) = makeBitmap(Int(pointWidth * pixelScale), Int(pointHeight * pixelScale))
    rep.size = NSSize(width: pointWidth, height: pointHeight)
    let content = CGRect(x: 204, y: 290, width: 613, height: 427)
    let fit = min((pointWidth - 1) / content.width, (pointHeight - 1) / content.height)
    ctx.scaleBy(x: pixelScale, y: pixelScale)
    ctx.translateBy(x: 0, y: pointHeight)
    ctx.scaleBy(x: 1, y: -1)
    ctx.translateBy(
        x: (pointWidth - content.width * fit) / 2, y: (pointHeight - content.height * fit) / 2)
    ctx.scaleBy(x: fit, y: fit)
    ctx.translateBy(x: -content.minX, y: -content.minY)
    drawGlyph(ctx, ink: black, accent: black, weight: 1.45)
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
    }
    try data.write(to: url)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try writePNG(renderAppIcon(pixels: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try writePNG(renderAppIcon(pixels: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    print("iconutil failed (\(iconutil.terminationStatus))")
    exit(1)
}

try writePNG(renderMenuBarGlyph(pointWidth: 22, pointHeight: 16, pixelScale: 1),
             to: resources.appendingPathComponent("MenuBarIcon.png"))
try writePNG(renderMenuBarGlyph(pointWidth: 22, pointHeight: 16, pixelScale: 2),
             to: resources.appendingPathComponent("MenuBarIcon@2x.png"))

print("✔ Resources/AppIcon.icns, Resources/MenuBarIcon.png, Resources/MenuBarIcon@2x.png")
print("  preview: build/AppIcon.iconset/icon_512x512@2x.png")
