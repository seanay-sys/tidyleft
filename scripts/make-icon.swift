// Draws the TidyLeft app icon (1024×1024 PNG) with plain Core Graphics.
// Usage: swift scripts/make-icon.swift OUTPUT.png
import AppKit

let size = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let ctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("no context") }
NSGraphicsContext.current = ctx
let cg = ctx.cgContext
let space = CGColorSpaceCreateDeviceRGB()

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

func linearGradient(_ path: CGPath, _ top: CGColor, _ bottom: CGColor, from y0: CGFloat, to y1: CGFloat) {
    cg.saveGState()
    cg.addPath(path)
    cg.clip()
    let g = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(g, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [])
    cg.restoreGState()
}

/// Four-pointed sparkle with concave sides.
func sparkle(center c: CGPoint, radius r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let pts = [CGPoint(x: c.x, y: c.y + r), CGPoint(x: c.x + r, y: c.y),
               CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x - r, y: c.y)]
    let k = r * 0.12
    let ctrls = [CGPoint(x: c.x + k, y: c.y + k), CGPoint(x: c.x + k, y: c.y - k),
                 CGPoint(x: c.x - k, y: c.y - k), CGPoint(x: c.x - k, y: c.y + k)]
    p.move(to: pts[0])
    for i in 0..<4 { p.addQuadCurve(to: pts[(i + 1) % 4], control: ctrls[i]) }
    p.closeSubpath()
    return p
}

// 1. Rounded-square tile on the standard macOS icon grid (824 pt body, 100 pt margin).
let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tile = CGPath(roundedRect: tileRect, cornerWidth: 185, cornerHeight: 185, transform: nil)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.35))
cg.addPath(tile)
cg.setFillColor(color(0.2, 0.4, 0.85))
cg.fillPath()
cg.restoreGState()
linearGradient(tile, color(0.24, 0.80, 0.84), color(0.18, 0.30, 0.82), from: 924, to: 100)

// Soft highlight across the top half.
cg.saveGState()
cg.addPath(tile)
cg.clip()
let glow = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.22), color(1, 1, 1, 0)] as CFArray,
                      locations: [0, 1])!
cg.drawRadialGradient(glow, startCenter: CGPoint(x: 400, y: 900), startRadius: 0,
                      endCenter: CGPoint(x: 400, y: 900), endRadius: 620, options: [])
cg.restoreGState()

// 2. Folder: back panel with tab, then front panel.
let back = CGMutablePath()
back.addRoundedRect(in: CGRect(x: 262, y: 270, width: 500, height: 360), cornerWidth: 44, cornerHeight: 44)
back.addRoundedRect(in: CGRect(x: 262, y: 560, width: 210, height: 110), cornerWidth: 40, cornerHeight: 40)
cg.saveGState()
cg.addPath(back)
cg.setFillColor(color(1, 1, 1, 0.55))
cg.fillPath()
cg.restoreGState()

let front = CGPath(roundedRect: CGRect(x: 262, y: 270, width: 500, height: 300),
                   cornerWidth: 44, cornerHeight: 44, transform: nil)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0.05, 0.1, 0.35, 0.35))
cg.addPath(front)
cg.setFillColor(color(1, 1, 1))
cg.fillPath()
cg.restoreGState()
linearGradient(front, color(1, 1, 1), color(0.88, 0.93, 1), from: 570, to: 270)

// Three "swept" lines on the folder front.
cg.setLineCap(.round)
cg.setLineWidth(26)
cg.setStrokeColor(color(0.20, 0.42, 0.85, 0.85))
for (y, w) in [(470.0, 250.0), (400.0, 190.0), (330.0, 120.0)] {
    cg.move(to: CGPoint(x: 330, y: y))
    cg.addLine(to: CGPoint(x: 330 + w, y: y))
    cg.strokePath()
}

// 3. Sparkles: one large warm one breaking out of the folder, two small white ones.
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0.6, 0.35, 0, 0.35))
let big = sparkle(center: CGPoint(x: 700, y: 640), radius: 150)
linearGradient(big, color(1, 0.93, 0.55), color(1, 0.72, 0.22), from: 790, to: 490)
cg.restoreGState()
cg.addPath(sparkle(center: CGPoint(x: 815, y: 800), radius: 58))
cg.setFillColor(color(1, 1, 1, 0.95))
cg.fillPath()
cg.addPath(sparkle(center: CGPoint(x: 560, y: 790), radius: 40))
cg.setFillColor(color(1, 1, 1, 0.85))
cg.fillPath()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
