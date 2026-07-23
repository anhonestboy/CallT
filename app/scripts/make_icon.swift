#!/usr/bin/env swift
// Genera AppIcon.iconset + AppIcon.icns.
// Design: squircle scuro con glifo SF Symbol "waveform" bianco,
// identico al simbolo usato nella menu bar per coerenza visiva.
// Uso: swift make_icon.swift <output-dir>

import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconsetDir = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetDir)
try! FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let img = NSImage(size: image.size)
    img.lockFocus()
    image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1.0)
    color.set()
    NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
    img.unlockFocus()
    return img
}

func render(_ px: Int) -> Data {
    let size = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = size / 1024.0
    // Griglia icona macOS: contenuto 824x824 centrato, angoli ~185
    let rect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)
    let gradient = NSGradient(
        starting: NSColor(srgbRed: 0.173, green: 0.184, blue: 0.216, alpha: 1),
        ending: NSColor(srgbRed: 0.078, green: 0.082, blue: 0.102, alpha: 1))!
    gradient.draw(in: path, angle: -90)

    let conf = NSImage.SymbolConfiguration(pointSize: 400 * s, weight: .medium)
    if let sym = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
        .withSymbolConfiguration(conf) {
        let white = tinted(sym, .white)
        let targetW = 470 * s
        let scale = targetW / white.size.width
        let w = white.size.width * scale
        let h = white.size.height * scale
        white.draw(
            in: NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h),
            from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in entries {
    try! render(px).write(to: iconsetDir.appendingPathComponent(name))
}
print("iconset: \(iconsetDir.path)")

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetDir.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "icns ok" : "icns FAILED")
