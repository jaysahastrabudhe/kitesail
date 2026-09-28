// Renders Facet's app icon (1024×1024) to the path given as the first argument.
// Graphite squircle on Apple's icon grid (824 pt body, 100 pt margin) with a faceted white kite and tail.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Body with soft drop shadow
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
ctx.addPath(squircle); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [NSColor(srgbRed: 0.20, green: 0.21, blue: 0.25, alpha: 1).cgColor,
                             NSColor(srgbRed: 0.06, green: 0.065, blue: 0.08, alpha: 1).cgColor] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// faint top sheen
let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [NSColor.white.withAlphaComponent(0.10).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])

// Kite: a tilted diamond split into four facets along its spars, with a curving tail.
let top = CGPoint(x: 585, y: 790), right = CGPoint(x: 730, y: 560)
let bottom = CGPoint(x: 470, y: 300), left = CGPoint(x: 350, y: 610)
let cross = CGPoint(x: 560, y: 598)   // where the spars meet (upper third, like a real kite)

func facet(_ pts: [CGPoint], _ alpha: CGFloat, tint: NSColor = .white) {
    ctx.beginPath(); ctx.move(to: pts[0]); pts.dropFirst().forEach { ctx.addLine(to: $0) }; ctx.closePath()
    ctx.setFillColor(tint.withAlphaComponent(alpha).cgColor); ctx.fillPath()
}
facet([top, right, cross], 0.95)
facet([top, cross, left], 0.62)
facet([left, cross, bottom], 0.30)
facet([cross, right, bottom], 0.55, tint: NSColor(srgbRed: 0.82, green: 0.90, blue: 1.0, alpha: 1))

// spars + outline
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(3); ctx.setLineJoin(.round)
for seg in [[top, right, bottom, left, top], [top, bottom], [left, right]] {
    ctx.beginPath(); ctx.move(to: seg[0]); seg.dropFirst().forEach { ctx.addLine(to: $0) }; ctx.strokePath()
}

// tail: a soft S-curve with three bows
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor); ctx.setLineWidth(5); ctx.setLineCap(.round)
ctx.beginPath(); ctx.move(to: bottom)
ctx.addCurve(to: CGPoint(x: 330, y: 175), control1: CGPoint(x: 420, y: 230), control2: CGPoint(x: 400, y: 190))
ctx.strokePath()
for (i, p) in [CGPoint(x: 437, y: 252), CGPoint(x: 395, y: 207), CGPoint(x: 345, y: 180)].enumerated() {
    let s: CGFloat = 16 - CGFloat(i) * 2
    facet([CGPoint(x: p.x - s, y: p.y + s * 0.6), p, CGPoint(x: p.x - s, y: p.y - s * 0.6)], 0.75)
    facet([CGPoint(x: p.x + s, y: p.y + s * 0.6), p, CGPoint(x: p.x + s, y: p.y - s * 0.6)], 0.75)
}
ctx.restoreGState()
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print(out)
