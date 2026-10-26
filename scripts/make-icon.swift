// Draws Sempre's app icon ("Linen": walnut metronome, brass pendulum, warm linen tile)
// and writes a 1024 px PNG. Usage: swift scripts/make-icon.swift <out.png>
// scripts/make-icon.sh turns it into Resources/AppIcon.icns.
import AppKit

let size: CGFloat = 1024
let u = size / 100 // design grid: 100 × 100 units, same as the sketches

let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let gc = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("no context") }
let ctx = gc.cgContext
// Work top-down in design units like the SVG.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: u, y: -u)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

// macOS icon outline: a superellipse (n = 5) centred in the canvas.
let tile: CGPath = {
    let p = CGMutablePath(), c: CGFloat = 50, r: CGFloat = 40.2, n: CGFloat = 5
    for i in 0..<360 {
        let t = CGFloat(i) / 360 * 2 * .pi, ct = cos(t), st = sin(t)
        let pt = CGPoint(x: c + r * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n),
                         y: c + r * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n))
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.closeSubpath()
    return p
}()

// Metronome body: tapered, with softly rounded corners.
let body: CGPath = {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 44.6, y: 20)); p.addLine(to: CGPoint(x: 55.4, y: 20))
    p.addQuadCurve(to: CGPoint(x: 57.4, y: 21.6), control: CGPoint(x: 57, y: 20))
    p.addLine(to: CGPoint(x: 69.6, y: 78))
    p.addQuadCurve(to: CGPoint(x: 68, y: 80), control: CGPoint(x: 70, y: 80))
    p.addLine(to: CGPoint(x: 32, y: 80))
    p.addQuadCurve(to: CGPoint(x: 30.4, y: 78), control: CGPoint(x: 30, y: 80))
    p.addLine(to: CGPoint(x: 42.6, y: 21.6))
    p.addQuadCurve(to: CGPoint(x: 44.6, y: 20), control: CGPoint(x: 43, y: 20))
    p.closeSubpath()
    return p
}()

// 1. Tile with the soft drop shadow macOS icons carry.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 0.9), blur: 1.8 * u, color: rgb(0x000000, 0.28))
ctx.addPath(tile); ctx.setFillColor(rgb(0xF5EDE2)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tile); ctx.clip()

// 2. Linen: warm off-white, a little deeper towards the bottom, with a peach glow behind the metronome.
ctx.drawLinearGradient(gradient([(0, rgb(0xFBF6EF)), (1, rgb(0xEFE3D3))]),
                       start: CGPoint(x: 50, y: 0), end: CGPoint(x: 50, y: 100), options: [])
ctx.drawRadialGradient(gradient([(0, rgb(0xFFC58F, 0.55)), (1, rgb(0xFFC58F, 0))]),
                       startCenter: CGPoint(x: 50, y: 62), startRadius: 0,
                       endCenter: CGPoint(x: 50, y: 62), endRadius: 45, options: [])

// 3. Contact shadow under the metronome.
ctx.saveGState()
ctx.translateBy(x: 50, y: 80.6)
ctx.scaleBy(x: 1, y: 0.13) // a flattened radial gradient: soft and darkest right under the base
ctx.drawRadialGradient(gradient([(0, rgb(0x3B2215, 0.42)), (0.6, rgb(0x3B2215, 0.16)), (1, rgb(0x3B2215, 0))]),
                       startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 26, options: [])
ctx.restoreGState()

// 4. Walnut body: horizontal shading for roundness, then grain.
ctx.saveGState()
ctx.addPath(body); ctx.clip()
ctx.drawLinearGradient(gradient([(0, rgb(0x4A2C1B)), (0.38, rgb(0x7B4C2F)), (0.62, rgb(0x6A3F26)), (1, rgb(0x3B2215))]),
                       start: CGPoint(x: 28, y: 50), end: CGPoint(x: 72, y: 50), options: [])
var seed: UInt64 = 0x5EED
func rand() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
for _ in 0..<170 {
    let x = 28 + rand() * 44, wobble = 0.15 + rand() * 0.5, phase = rand() * 6
    let line = CGMutablePath()
    line.move(to: CGPoint(x: x, y: 18))
    for step in stride(from: CGFloat(18), through: 82, by: 2) {
        line.addLine(to: CGPoint(x: x + sin(step / 7 + phase) * wobble, y: step))
    }
    ctx.addPath(line)
    ctx.setStrokeColor(rand() < 0.75 ? rgb(0x24120A, 0.06 + rand() * 0.16) : rgb(0xC08A5A, 0.05 + rand() * 0.08))
    ctx.setLineWidth(0.08 + rand() * 0.35)
    ctx.strokePath()
}
// Light catching the top edge.
ctx.setFillColor(rgb(0xFFFFFF, 0.12)); ctx.fill(CGRect(x: 28, y: 18, width: 44, height: 2.2))
ctx.restoreGState()

// 5. Tempo scale: five fine marks.
ctx.setStrokeColor(rgb(0xE9CF98, 0.38)); ctx.setLineWidth(0.7)
for y in stride(from: CGFloat(34), through: 58, by: 6) {
    ctx.move(to: CGPoint(x: 48.6, y: y)); ctx.addLine(to: CGPoint(x: 51.4, y: y))
}
ctx.strokePath()

// 6. Brass pendulum, caught mid-swing.
let brass = gradient([(0, rgb(0x9C6B2A)), (0.45, rgb(0xF3D58E)), (1, rgb(0xB98638))])
func brassFill(_ rect: CGRect, radius: CGFloat) {
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.clip()
    ctx.drawLinearGradient(brass, start: CGPoint(x: rect.minX, y: 0), end: CGPoint(x: rect.maxX, y: 0), options: [])
    ctx.restoreGState()
}
ctx.saveGState()
ctx.translateBy(x: 50, y: 72); ctx.rotate(by: 9 * .pi / 180); ctx.translateBy(x: -50, y: -72)
ctx.setShadow(offset: CGSize(width: 0, height: 0.3), blur: 0.6 * u, color: rgb(0x000000, 0.35))
brassFill(CGRect(x: 49.2, y: 27, width: 1.6, height: 45), radius: 0.8)
brassFill(CGRect(x: 46.3, y: 36, width: 7.4, height: 5.2), radius: 1.4)
ctx.setShadow(offset: .zero, blur: 0)
ctx.setFillColor(rgb(0xFFFFFF, 0.55))
ctx.addPath(CGPath(roundedRect: CGRect(x: 46.8, y: 36.5, width: 6.4, height: 0.8), cornerWidth: 0.4, cornerHeight: 0.4, transform: nil))
ctx.fillPath()
ctx.restoreGState()

// Pivot.
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: 47.9, y: 69.9, width: 4.2, height: 4.2)); ctx.clip()
ctx.drawLinearGradient(brass, start: CGPoint(x: 47.9, y: 0), end: CGPoint(x: 52.1, y: 0), options: [])
ctx.restoreGState()

ctx.restoreGState() // tile clip

// 7. Hairline edge so the light tile holds its shape on white.
ctx.addPath(tile); ctx.setStrokeColor(rgb(0x000000, 0.08)); ctx.setLineWidth(0.25); ctx.strokePath()

gc.flushGraphics()
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
