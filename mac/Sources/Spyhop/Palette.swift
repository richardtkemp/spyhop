import AppKit

// Colour helpers. Creature colours are CSS hsl(a) (lightness), so we need HSL→RGB — NSColor's
// hue/saturation/brightness is HSB and would be wrong. Palette RGB stops transcribed from
// spyhop.html (SKY_N/SKY_D/WATER_N/WATER_D etc.).

func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> (r: Double, g: Double, b: Double) {
    let s = s / 100, l = l / 100
    let c = (1 - abs(2 * l - 1)) * s
    let hp = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
    let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
    var r = 0.0, g = 0.0, b = 0.0
    switch hp {
    case 0..<1: (r, g, b) = (c, x, 0)
    case 1..<2: (r, g, b) = (x, c, 0)
    case 2..<3: (r, g, b) = (0, c, x)
    case 3..<4: (r, g, b) = (0, x, c)
    case 4..<5: (r, g, b) = (x, 0, c)
    default:    (r, g, b) = (c, 0, x)
    }
    let m = l - c / 2
    return (r + m, g + m, b + m)
}

func nsColor(hue: Double, sat: Double, lit: Double, alpha: Double = 1) -> NSColor {
    let (r, g, b) = hslToRGB(hue, sat, lit)
    return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
}

/// Mirrors `col(k, dl, a)` in spyhop.html — kind colour with a lightness delta.
func col(_ k: Kind, _ dl: Double, _ a: Double) -> NSColor {
    nsColor(hue: k.hue, sat: k.sat, lit: clampD(k.lit + dl, 0, 100), alpha: a)
}

func rgb(_ c: [Int], _ a: Double = 1) -> NSColor {
    NSColor(srgbRed: Double(c[0]) / 255, green: Double(c[1]) / 255, blue: Double(c[2]) / 255, alpha: a)
}

enum Pal {
    // gradient stops (top → bottom), night and day; blended by sun height.
    static let skyNight = [[7, 10, 26], [11, 20, 40], [19, 42, 56]]
    static let skyDay = [[74, 128, 186], [120, 170, 214], [176, 208, 232]]
    static let waterNight = [[18, 50, 68], [12, 37, 52], [6, 22, 32]]
    static let waterDay = [[86, 168, 190], [46, 120, 150], [22, 78, 104]]
    static let cloudNight = [64, 74, 104], cloudDay = [206, 214, 226]
    static let bedFill = [8, 37, 42], bedLow = [5, 23, 27]
}

/// Blend two integer-RGB stops by t and return an NSColor.
func mixColor(_ a: [Int], _ b: [Int], _ t: Double, alpha: Double = 1) -> NSColor {
    NSColor(srgbRed: lerpD(Double(a[0]), Double(b[0]), t) / 255,
            green: lerpD(Double(a[1]), Double(b[1]), t) / 255,
            blue: lerpD(Double(a[2]), Double(b[2]), t) / 255, alpha: alpha)
}
