// Draws the DMG window background (1x and 2x): graphite, with an arrow from the app slot to Applications.
// Usage: swift tools/make-dmg-background.swift <out-1x.png> <out-2x.png>
import AppKit

func render(scale: CGFloat, to path: String) {
    let size = NSSize(width: 660, height: 400)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [NSColor(srgbRed: 0.17, green: 0.18, blue: 0.21, alpha: 1).cgColor,
                                 NSColor(srgbRed: 0.08, green: 0.085, blue: 0.10, alpha: 1).cgColor] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 330, y: 400), end: CGPoint(x: 330, y: 0), options: [])

    // Title + hint (Finder draws the icons; these sit above/below them)
    let title = NSAttributedString(string: "Kitesail", attributes: [
        .font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: NSColor.white])
    title.draw(at: NSPoint(x: 330 - title.size().width / 2, y: 330))
    let sub = NSAttributedString(string: "Drag Kitesail into Applications to install", attributes: [
        .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white.withAlphaComponent(0.6)])
    sub.draw(at: NSPoint(x: 330 - sub.size().width / 2, y: 305))
    let foot = NSAttributedString(string: "First launch: right-click Kitesail → Open", attributes: [
        .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white.withAlphaComponent(0.4)])
    foot.draw(at: NSPoint(x: 330 - foot.size().width / 2, y: 28))

    // Arrow between the two icon slots (icons centred at x 180 and 480, y 190 from the top => 210 from bottom)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
    ctx.setLineWidth(3); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setLineDash(phase: 0, lengths: [2, 9])
    ctx.move(to: CGPoint(x: 262, y: 210)); ctx.addLine(to: CGPoint(x: 392, y: 210)); ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])
    ctx.move(to: CGPoint(x: 380, y: 222)); ctx.addLine(to: CGPoint(x: 396, y: 210)); ctx.addLine(to: CGPoint(x: 380, y: 198))
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
render(scale: 1, to: CommandLine.arguments[1])
render(scale: 2, to: CommandLine.arguments[2])
