// Renders MacCleaner's app icon into an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>   (then: iconutil -c icns <output.iconset>)
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try? FileManager.default.removeItem(at: output)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

/// Draws the icon at `pixels`×`pixels`, following the macOS icon grid (824 pt body in a 1024 pt canvas).
func renderIcon(pixels: Int) -> Data {
    let scale = CGFloat(pixels) / 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: scale, y: scale)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Soft drop shadow under the body.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    context.addPath(shape)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fillPath()
    context.restoreGState()

    // Diagonal purple → cyan gradient.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let colors = [CGColor(red: 0.47, green: 0.33, blue: 1.0, alpha: 1), CGColor(red: 0.16, green: 0.72, blue: 1.0, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    // Gentle top highlight.
    let highlight = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(highlight, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.midY), options: [])
    context.restoreGState()

    // White "sparkles" glyph, centred.
    let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold).applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let size = symbol.size
        let rect = CGRect(x: 512 - size.width / 2, y: 512 - size.height / 2 - 6, width: size.width, height: size.height)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: CGColor(gray: 0, alpha: 0.25))
        symbol.draw(in: rect)
        context.restoreGState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try renderIcon(pixels: size).write(to: output.appending(path: "icon_\(size)x\(size).png"))
    try renderIcon(pixels: size * 2).write(to: output.appending(path: "icon_\(size)x\(size)@2x.png"))
}
print("Wrote \(output.path)")
