// generate-icon.swift — renders Spyhop's app icon (the whale from the menu-bar tray,
// 🐳, on an ocean-depth gradient) into an .icns. Standalone so it isn't linked into the
// app; build.sh compiles and runs it, then drops the result into the bundle's Resources.
// Run ON THE MAC (needs AppKit + iconutil):  swiftc -O generate-icon.swift && ./generate-icon out.icns
import AppKit

// Ocean gradient stops, transcribed to match Palette.swift (waterDay top → waterNight deep)
// so the icon reads as the same sea the wallpaper paints.
let top = NSColor(srgbRed: 98 / 255, green: 180 / 255, blue: 200 / 255, alpha: 1)
let bottom = NSColor(srgbRed: 8 / 255, green: 26 / 255, blue: 40 / 255, alpha: 1)

/// Render one square PNG of the icon at the given pixel size.
func renderPNG(px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(px)
    // ~10% margin all round, matching Apple's rounded-rect icon grid.
    let inset = (s * 0.09).rounded()
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = rect.width * 0.2237                       // ≈ continuous "squircle" corner
    let card = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Ocean-depth gradient fills the rounded card.
    NSGradient(colors: [top, bottom])?.draw(in: card, angle: -90)

    // The whale, centred, with a soft depth shadow — same glyph as the tray icon.
    let fontSize = rect.height * 0.62
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = fontSize * 0.06
    shadow.shadowOffset = NSSize(width: 0, height: -fontSize * 0.03)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize),
        .shadow: shadow,
    ]
    let str = NSAttributedString(string: "🐳", attributes: attrs)
    let sz = str.size()
    str.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// --- assemble the .iconset and hand it to iconutil ---------------------------
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".build/AppIcon.icns"
let fm = FileManager.default
let iconset = (outPath as NSString).deletingLastPathComponent + "/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

// (point size, @2x?) → filename, per Apple's iconset naming.
let variants: [(Int, Bool)] = [(16, false), (16, true), (32, false), (32, true),
                               (128, false), (128, true), (256, false), (256, true),
                               (512, false), (512, true)]
for (pt, retina) in variants {
    let px = retina ? pt * 2 : pt
    let name = "icon_\(pt)x\(pt)\(retina ? "@2x" : "").png"
    try! renderPNG(px: px).write(to: URL(fileURLWithPath: "\(iconset)/\(name)"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset, "-o", outPath]
try! iconutil.run()
iconutil.waitUntilExit()
try? fm.removeItem(atPath: iconset)
FileHandle.standardError.write("wrote \(outPath)\n".data(using: .utf8)!)
