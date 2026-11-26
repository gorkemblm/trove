// Draws the app icon and writes Resources/AppIcon.icns.
// Run: swift Scripts/MakeIcon.swift   (needs only macOS: CoreGraphics and iconutil)
// Original artwork: no SF Symbols (their licence does not allow them in app icons).
import AppKit

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawIcon(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let cg = context.cgContext
    let s = CGFloat(size) / 1024 // Everything is drawn on a 1024 grid.
    cg.scaleBy(x: s, y: s)

    // Apple's grid: an 824 pt rounded square centred on the canvas, with a soft shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = roundedRect(tile, 185)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.30))
    cg.addPath(tilePath)
    cg.setFillColor(color(0.2, 0.3, 0.7))
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(tilePath)
    cg.clip()
    let background = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                colors: [color(0.33, 0.50, 0.96), color(0.20, 0.25, 0.62)] as CFArray,
                                locations: [0, 1])!
    cg.drawLinearGradient(background, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])
    // A soft light at the top for depth.
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(1, 1, 1, 0.18), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    cg.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 980), startRadius: 0,
                          endCenter: CGPoint(x: 512, y: 980), endRadius: 620, options: [])
    cg.restoreGState()

    // History: a card behind the clipboard, turned a little.
    cg.saveGState()
    cg.translateBy(x: 470, y: 520)
    cg.rotate(by: 9 * .pi / 180)
    cg.addPath(roundedRect(CGRect(x: -215, y: -270, width: 430, height: 520), 52))
    cg.setFillColor(color(1, 1, 1, 0.30))
    cg.fillPath()
    cg.restoreGState()

    // The clipboard.
    let board = CGRect(x: 312, y: 196, width: 400, height: 520)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0.05, 0.08, 0.25, 0.35))
    cg.addPath(roundedRect(board, 50))
    cg.setFillColor(color(0.98, 0.98, 1.0))
    cg.fillPath()
    cg.restoreGState()

    // Lines of copied text; the first one in the accent colour.
    let lines: [(CGFloat, CGColor)] = [
        (250, color(0.33, 0.50, 0.96)), (300, color(0.78, 0.82, 0.92)), (230, color(0.78, 0.82, 0.92)), (275, color(0.78, 0.82, 0.92)),
    ]
    for (index, line) in lines.enumerated() {
        let y = 560 - CGFloat(index) * 78
        cg.addPath(roundedRect(CGRect(x: 362, y: y, width: line.0, height: 34), 17))
        cg.setFillColor(line.1)
        cg.fillPath()
    }

    // The clip at the top.
    let clip = CGRect(x: 412, y: 668, width: 200, height: 96)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -6), blur: 12, color: color(0.05, 0.08, 0.25, 0.35))
    cg.addPath(roundedRect(clip, 30))
    let metal = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [color(0.30, 0.34, 0.50), color(0.17, 0.20, 0.33)] as CFArray, locations: [0, 1])!
    cg.clip()
    cg.drawLinearGradient(metal, start: CGPoint(x: 0, y: clip.maxY), end: CGPoint(x: 0, y: clip.minY), options: [])
    cg.restoreGState()
    cg.addEllipse(in: CGRect(x: 494, y: 724, width: 36, height: 22))
    cg.setFillColor(color(0.98, 0.98, 1.0))
    cg.fillPath()

    context.flushGraphics()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = drawIcon(size: base * scale).representation(using: .png, properties: [:])!
        try data.write(to: iconset.appendingPathComponent(name))
    }
}
try drawIcon(size: 1024).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("build/AppIcon-1024.png"))
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
