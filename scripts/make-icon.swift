// Disegna l'icona dell'app e la salva in Resources/AppIcon.icns.
// Uso (dalla cartella del progetto):  swift scripts/make-icon.swift
import AppKit

let fm = FileManager.default
let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true, attributes: nil)

func disegna(lato: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: lato, pixelsHigh: lato,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(lato) / 1024

    // Sfondo arrotondato come le icone di Big Sur.
    let sfondo = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let forma = NSBezierPath(roundedRect: sfondo, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let ombra = NSShadow()
    ombra.shadowColor = NSColor.black.withAlphaComponent(0.3)
    ombra.shadowOffset = NSSize(width: 0, height: -10 * s)
    ombra.shadowBlurRadius = 20 * s
    ombra.set()
    NSColor.white.setFill()
    forma.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.52, blue: 0.98, alpha: 1),
               ending: NSColor(calibratedRed: 0.07, green: 0.29, blue: 0.75, alpha: 1))!
        .draw(in: forma, angle: -90)

    // Scritta "F24".
    let attributi: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 300 * s, weight: .heavy),
        .foregroundColor: NSColor.white,
    ]
    let scritta = NSAttributedString(string: "F24", attributes: attributi)
    let misura = scritta.size()
    scritta.draw(at: NSPoint(x: sfondo.midX - misura.width / 2, y: 470 * s))

    // Bollino verde con la spunta.
    let bollino = NSRect(x: 382 * s, y: 170 * s, width: 260 * s, height: 260 * s)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: bollino.insetBy(dx: -14 * s, dy: -14 * s)).fill()
    NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.35, alpha: 1).setFill()
    NSBezierPath(ovalIn: bollino).fill()
    let spunta = NSBezierPath()
    spunta.move(to: NSPoint(x: bollino.minX + 70 * s, y: bollino.midY + 2 * s))
    spunta.line(to: NSPoint(x: bollino.minX + 115 * s, y: bollino.minY + 78 * s))
    spunta.line(to: NSPoint(x: bollino.maxX - 62 * s, y: bollino.maxY - 75 * s))
    spunta.lineWidth = 32 * s
    spunta.lineCapStyle = .round
    spunta.lineJoinStyle = .round
    NSColor.white.setStroke()
    spunta.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let dimensioni: [(String, Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
    ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
    ("512x512", 512), ("512x512@2x", 1024),
]
for (nome, lato) in dimensioni {
    let png = disegna(lato: lato).representation(using: .png, properties: [:])!
    try! png.write(to: iconset.appendingPathComponent("icon_\(nome).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "✓ Resources/AppIcon.icns" : "✗ iconutil non riuscito")
