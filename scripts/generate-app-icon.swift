import AppKit
import Foundation

// Production geometry for the approved monochrome logo, in a 1024-point canvas.
// Transparent padding lets the rounded tile sit naturally in Finder and the Dock.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let packaging = root.appendingPathComponent("packaging")
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <rect x="92" y="92" width="840" height="840" rx="124" fill="#000000"/>
  <circle cx="512" cy="512" r="236" fill="none" stroke="#FFFFFF" stroke-width="34"/>
  <circle cx="512" cy="512" r="102" fill="#FFFFFF"/>
</svg>
"""
try (svg + "\n").write(to: packaging.appendingPathComponent("AppIcon.svg"), atomically: true, encoding: .utf8)

func render(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Cannot create icon bitmap")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    let cg = context.cgContext
    cg.clear(CGRect(x: 0, y: 0, width: size, height: size))
    cg.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    cg.setFillColor(NSColor.black.cgColor)
    cg.addPath(CGPath(roundedRect: CGRect(x: 92, y: 92, width: 840, height: 840),
                      cornerWidth: 124, cornerHeight: 124, transform: nil))
    cg.fillPath()
    cg.setStrokeColor(NSColor.white.cgColor)
    cg.setLineWidth(34)
    cg.strokeEllipse(in: CGRect(x: 276, y: 276, width: 472, height: 472))
    cg.setFillColor(NSColor.white.cgColor)
    cg.fillEllipse(in: CGRect(x: 410, y: 410, width: 204, height: 204))
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode icon PNG")
    }
    return png
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let png = try render(size: points * scale)
        try png.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
        if points * scale == 1024 {
            try png.write(to: packaging.appendingPathComponent("AppIcon.png"))
        }
    }
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", packaging.appendingPathComponent("AppIcon.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
print("Generated packaging/AppIcon.svg, AppIcon.png and AppIcon.icns")
