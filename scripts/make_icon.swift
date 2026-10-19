// KeyV app icon generator — pure AppKit drawing, no external deps.
// Usage: swift scripts/make_icon.swift
// Output: apps/keyv-app/Resources/KeyV.icns (and KeyVIcon_*.png for review)

import AppKit

let outDir = URL(fileURLWithPath: "apps/keyv-app/Resources", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func drawIcon(_ size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let radius = size * 0.22
    let corner = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    corner.addClip()

    // Background: deep violet → indigo diagonal gradient
    let gradient = NSGradient(starting: NSColor(srgbRed: 0.30, green: 0.20, blue: 0.62, alpha: 1.0),
                              ending: NSColor(srgbRed: 0.13, green: 0.10, blue: 0.36, alpha: 1.0))
    gradient?.draw(in: corner, angle: -55)

    // Subtle top highlight
    if let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.16),
                                           NSColor.white.withAlphaComponent(0.0)]) {
        highlight.draw(in: NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius),
                       angle: 90)
    }

    // Vietnamese motif: the word "Việt"-style tone mark (grave accent) above the V.
    let accentColor = NSColor(srgbRed: 0.98, green: 0.29, blue: 0.29, alpha: 1.0)
    let accent = NSBezierPath()
    let ax = size * 0.40
    let ay = size * 0.865
    accent.move(to: NSPoint(x: ax, y: ay))
    accent.curve(to: NSPoint(x: ax + size * 0.20, y: ay + size * 0.045),
                 controlPoint1: NSPoint(x: ax + size * 0.06, y: ay + size * 0.035),
                 controlPoint2: NSPoint(x: ax + size * 0.13, y: ay + size * 0.020))
    accent.lineWidth = size * 0.065
    accent.lineCapStyle = .round
    accentColor.setStroke()
    accent.stroke()

    // Main glyph: bold "V"
    let font = NSFont.systemFont(ofSize: size * 0.58, weight: .heavy)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
    ]
    let str = NSAttributedString(string: "V", attributes: attrs)
    let bounds = str.size()
    str.draw(at: NSPoint(x: (size - bounds.width) / 2,
                         y: (size - bounds.height) / 2 - size * 0.02))

    image.unlockFocus()
    return image
}

let entries: [(Int, String, String)] = [
    (16, "16x16", "KeyVIcon_16.png"),
    (32, "16x16@2x", "KeyVIcon_32.png"),
    (32, "32x32", "KeyVIcon_32x32.png"),
    (64, "32x32@2x", "KeyVIcon_64.png"),
    (128, "128x128", "KeyVIcon_128.png"),
    (256, "128x128@2x", "KeyVIcon_256.png"),
    (256, "256x256", "KeyVIcon_256x256.png"),
    (512, "256x256@2x", "KeyVIcon_512.png"),
    (512, "512x512", "KeyVIcon_512x512.png"),
]

let iconset = outDir.appendingPathComponent("KeyV.iconset")
try? FileManager.default.removeItem(at: iconset)
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for (px, name, reviewName) in entries {
    let img = drawIcon(CGFloat(px))
    let tiff = img.tiffRepresentation!
    let rep = NSBitmapImageRep(data: tiff)!
    let png = rep.representation(using: .png, properties: [:])!

    let setPath = iconset.appendingPathComponent("icon_\(name).png")
    let revPath = outDir.appendingPathComponent(reviewName)
    try! png.write(to: setPath)
    try! png.write(to: revPath)

    // Keep the in-package copy used by the SwiftUI views in sync.
    if px == 512 {
        try! png.write(to: URL(fileURLWithPath: "apps/keyv-app/Sources/KeyVHostKit/KeyVIcon.png"))
    }
}

// iconset → icns
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns",
                     iconset.path,
                     "-o", outDir.appendingPathComponent("KeyV.icns").path]
try! process.run()
process.waitUntilExit()

if process.terminationStatus == 0 {
    print("Icon done: \(outDir.appendingPathComponent("KeyV.icns").path)")
} else {
    print("iconutil failed: \(process.terminationStatus)")
    exit(1)
}
