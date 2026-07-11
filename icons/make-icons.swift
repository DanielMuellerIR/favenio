// make-icons.swift — zeichnet die App-Icons von Favenio programmatisch.
//
// Konzept „F-Monogramm": dunkles macOS-Squircle, serifiges „F",
// bernsteinfarbene Lupe darüber. FavenioQuick bekommt die Abwandlung:
// Farben invertiert (Bernstein-Grund, dunkles F) und ein Blitz in der
// Lupe als Zeichen für „Schnellsuche".
//
// Aufruf (aus dem Repo-Root):
//   swift icons/make-icons.swift
// Ergebnis: icons/Favenio.iconset/ + icons/FavenioQuick.iconset/
// (alle von macOS verlangten Größen 16–1024 px). Die .icns baut danach
// iconutil — siehe build-app.sh bzw. README.
//
// Warum Swift statt SVG? Kein externer SVG-Rasterizer nötig; swiftc ist
// ohnehin die einzige Build-Voraussetzung des Projekts.

import AppKit

// ---------- Farbpalette ----------

// NSColor aus einem Hexwert wie 0x1E293B bauen (sRGB).
func rgb(_ hex: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0)
}

let slate = rgb(0x1E293B)   // dunkles Schieferblau (Grund der Haupt-App)
let amber = rgb(0xF59E0B)   // Bernstein (Lupe der Haupt-App, Grund der Quick-App)
let paper = rgb(0xF8FAFC)   // fast weiß (das „F" der Haupt-App)

// Eine Icon-Variante = vier Farbrollen + optionaler Blitz.
struct Variant {
    let background: NSColor  // Squircle-Füllung
    let glyph: NSColor       // Farbe des „F"
    let lens: NSColor        // Lupenring + Griff
    let bolt: NSColor?       // Blitz in der Lupe (nil = keiner)
}

let mainVariant  = Variant(background: slate, glyph: paper, lens: amber, bolt: nil)
let quickVariant = Variant(background: amber, glyph: slate, lens: slate, bolt: paper)

// ---------- Zeichnen ----------
// Alle Koordinaten sind im 1024er-Entwurfsraster gedacht und werden
// über den Faktor s auf die Zielgröße skaliert. AppKit zählt y von
// UNTEN — die Werte hier sind bereits umgerechnet.

func drawIcon(pixels: Int, variant: Variant) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let s = CGFloat(pixels) / 1024.0

    // Squircle nach Apple-Vorlage: 824×824 zentriert auf 1024er-Fläche,
    // Eckenradius 185. Der Rest bleibt transparent (macOS rechnet den
    // Schatten selbst dazu).
    let inset = 100 * s
    let square = NSRect(x: inset, y: inset,
                        width: CGFloat(pixels) - 2 * inset,
                        height: CGFloat(pixels) - 2 * inset)
    variant.background.setFill()
    NSBezierPath(roundedRect: square, xRadius: 185 * s, yRadius: 185 * s).fill()

    // Das „F": serifige Schrift (Georgia Bold), leicht links der Mitte,
    // damit rechts Platz für die Lupe bleibt.
    let font = NSFont(name: "Georgia-Bold", size: 494 * s)
        ?? NSFont.boldSystemFont(ofSize: 494 * s)
    let text = NSAttributedString(string: "F", attributes: [
        .font: font, .foregroundColor: variant.glyph,
    ])
    let textSize = text.size()
    // draw(at:) erwartet die linke UNTERE Ecke der Textbox; die Grundlinie
    // liegt |descender| darüber — deshalb descender (negativ) addieren.
    text.draw(at: NSPoint(x: 392 * s - textSize.width / 2,
                          y: 328 * s + font.descender))

    // Lupe: Ring rechts oben über dem F …
    let lensCenter = NSPoint(x: 645 * s, y: 430 * s)
    let lensRadius = 152 * s
    let ring = NSBezierPath(ovalIn: NSRect(x: lensCenter.x - lensRadius,
                                           y: lensCenter.y - lensRadius,
                                           width: lensRadius * 2,
                                           height: lensRadius * 2))
    ring.lineWidth = 44 * s
    variant.lens.setStroke()
    ring.stroke()

    // … plus Griff nach rechts unten.
    let handle = NSBezierPath()
    handle.move(to: NSPoint(x: 752 * s, y: 323 * s))
    handle.line(to: NSPoint(x: 820 * s, y: 240 * s))
    handle.lineWidth = 58 * s
    handle.lineCapStyle = .round
    handle.stroke()

    // Blitz in der Linse (nur Quick-Variante): einfacher Zickzack,
    // Koordinaten relativ zum Linsenmittelpunkt.
    if let boltColor = variant.bolt {
        let points: [(CGFloat, CGFloat)] = [
            (18, 96), (-42, -8), (-8, -8), (-18, -96), (42, 8), (8, 8),
        ]
        let bolt = NSBezierPath()
        for (i, p) in points.enumerated() {
            let point = NSPoint(x: lensCenter.x + p.0 * s,
                                y: lensCenter.y + p.1 * s)
            if i == 0 { bolt.move(to: point) } else { bolt.line(to: point) }
        }
        bolt.close()
        boltColor.setFill()
        bolt.fill()
    }

    return rep
}

// ---------- Iconset-Ordner schreiben ----------
// macOS-Iconsets brauchen feste Dateinamen: icon_<pt>x<pt>[@2x].png.

let sizes: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]

// Skript liegt in icons/ — dorthin schreiben wir auch die Ausgabe.
let iconsDir = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()

for (name, variant) in [("Favenio", mainVariant), ("FavenioQuick", quickVariant)] {
    let setDir = iconsDir.appendingPathComponent("\(name).iconset")
    try? FileManager.default.removeItem(at: setDir)
    try! FileManager.default.createDirectory(at: setDir,
                                             withIntermediateDirectories: true)
    for (points, scale) in sizes {
        let rep = drawIcon(pixels: points * scale, variant: variant)
        let suffix = scale == 2 ? "@2x" : ""
        let file = setDir.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try! rep.representation(using: .png, properties: [:])!.write(to: file)
    }
    print("geschrieben: \(setDir.path)")
}
