import AppKit

// Reproduzierbarer 2×-Master (1200×840 Pixel) für die 600×420 Punkte große
// DMG-Inhaltsfläche. Der Finder legt die Icons später genau über die drei
// gestrichelten Kreise: Favenio.app, FavenioQuick.app und der
// /Applications-Alias (Icon-Positionen stellt release.sh per AppleScript ein).
// Aufruf:  xcrun swift assets/generate-dmg-background.swift <ausgabe.png>

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "dist/DmgBackground.png"

let size = NSSize(width: 1200, height: 840)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size.width),
    pixelsHigh: Int(size.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else { exit(1) }
bitmap.size = size

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        red: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: 1
    )
}

func centeredText(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let measured = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: (size.width - measured.width) / 2, y: y),
              withAttributes: attributes)
}

guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext
let context = graphicsContext.cgContext

// Dezenter kühler Verlauf von hell nach etwas dunkler.
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(0xF8FAFC).cgColor, color(0xEDF1F6).cgColor] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(gradient,
                           start: CGPoint(x: 600, y: 840),
                           end: CGPoint(x: 600, y: 0),
                           options: [])

let ink = color(0x22262B)
let muted = color(0x6B7280)
let accent = color(0x2F6FDE)
let dashed = color(0xAEB4BF)

centeredText("Favenio", y: 686,
             font: .systemFont(ofSize: 64, weight: .semibold), color: ink)
centeredText("Dateisuche ohne Index · Index-free file search", y: 618,
             font: .systemFont(ofSize: 26, weight: .regular), color: muted)

// Drei gestrichelte Kreise: zwei Apps links, Applications-Ordner rechts.
context.setStrokeColor(dashed.cgColor)
context.setLineWidth(4)
context.setLineDash(phase: 0, lengths: [19, 17])
for centerX in [220.0, 540.0, 960.0] {
    context.strokeEllipse(in: CGRect(x: centerX - 128, y: 128, width: 256, height: 256))
}
context.setLineDash(phase: 0, lengths: [])

// Pfeil von den Apps zum Applications-Ordner.
context.setFillColor(accent.cgColor)
context.fill(CGRect(x: 692, y: 250, width: 110, height: 12))
context.beginPath()
context.move(to: CGPoint(x: 832, y: 256))
context.addLine(to: CGPoint(x: 796, y: 279))
context.addLine(to: CGPoint(x: 796, y: 233))
context.closePath()
context.fillPath()

centeredText("Beide Apps zum Installieren nach Applications ziehen · Drag both apps to Applications",
             y: 36, font: .systemFont(ofSize: 20, weight: .regular), color: muted)

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
