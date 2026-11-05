// Renders Resources/AppIcon.icns: SF Symbol on a dark rounded square. Usage: swift Tools/make-icon.swift <outdir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let canvas = 1024.0, inset = 100.0, side = canvas - inset * 2

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let rect = NSRect(x: inset, y: inset, width: side, height: side)
let shape = NSBezierPath(roundedRect: rect, xRadius: side * 0.225, yRadius: side * 0.225)
NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.20, blue: 0.23, alpha: 1),
           ending: NSColor(srgbRed: 0.02, green: 0.02, blue: 0.03, alpha: 1))!.draw(in: shape, angle: -90)

let config = NSImage.SymbolConfiguration(pointSize: 440, weight: .medium)
    .applying(.init(paletteColors: [.white]))
let symbol = NSImage(systemSymbolName: "lock.display", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
let s = symbol.size
symbol.draw(in: NSRect(x: (canvas - s.width) / 2, y: (canvas - s.height) / 2, width: s.width, height: s.height))
NSGraphicsContext.restoreGraphicsState()

let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = NSImage(size: NSSize(width: canvas, height: canvas))
master.addRepresentation(rep)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: r)
        NSGraphicsContext.current?.imageInterpolation = .high
        master.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! r.representation(using: .png, properties: [:])!.write(to: iconset.appending(path: name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.appending(path: "AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print("wrote \(out.appending(path: "AppIcon.icns").path)")
