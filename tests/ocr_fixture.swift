import AppKit
import ImageIO

let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 500,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 500).fill()
for (index, text) in ["Rechnung München 4729", "Straße und Überweisung", "Invoice number 6382"].enumerated() {
    (text as NSString).draw(at: NSPoint(x: 60, y: 100 + index * 90),
        withAttributes: [.font: NSFont.systemFont(ofSize: 38), .foregroundColor: NSColor.black])
}
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
