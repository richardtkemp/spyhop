import SpriteKit
import CoreGraphics

// Bakes each creature shape to an SKTexture once (cached by shape+colour), transliterating the
// drawX() routines from spyhop.html into CoreGraphics. Rigid pose (wig=0) for now — articulated
// tails/tentacles come as a later refinement. Drawn in canvas-like coords (origin = body centre,
// y-DOWN) so the geometry matches the reference 1:1.
@MainActor
enum ShapeBaker {
    static let refR: CGFloat = 64      // reference body radius the texture is baked at
    static let pad: CGFloat = 2.0      // texture half-extent = pad*refR (room for tails/tentacles/glow)
    static var nativeSize: CGFloat { pad * refR * 2 }   // logical sprite size in points

    private static var cache: [String: SKTexture] = [:]
    private static let eyeWhite = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9)
    private static let eyeDark = NSColor(srgbRed: 4/255, green: 20/255, blue: 26/255, alpha: 1)

    // Wiggle-atlas frames per kind (texture swapped per frame → articulation). More frames =
    // smoother motion and proportionally more texture memory. Multiples of 4 land samples on the
    // sin() motion extremes (full tail up/down); 1 = a single rest pose (rigid, ~⅓ the memory).
    static var phases = 24
    static let phasesDefault = 24

    /// Change the atlas frame count; flushes the bake cache so textures rebake at the new count.
    static func setPhases(_ n: Int) {
        let clamped = max(1, min(30, n))
        guard clamped != phases else { return }
        phases = clamped
        cache.removeAll()
    }

    // Bake resolution multiplier on top of the display scale. 1 = native (crisp); 0.5 = half linear
    // dims → ¼ the texture bytes, GPU-upscaled at draw (softer). A pure memory lever, area-scaled.
    static var resScale = 1.0
    static func setResScale(_ s: Double) {
        guard s != resScale else { return }
        resScale = s
        cache.removeAll()
    }

    // Bake each creature only as sharply as its on-screen size needs, not at the max radius —
    // texture memory is ~quadratic in size and most creatures are small. Buckets round UP, so a
    // creature is always baked at ≥ its display resolution (lossless); it only jumps to a sharper
    // bucket if its size actually reaches it. `refR` (64) tops the list since radMax is 58.
    static var bucketCount = 6
    static let minBucketR: CGFloat = 10
    static func setBucketCount(_ n: Int) { let c = max(1, n); guard c != bucketCount else { return }; bucketCount = c; cache.removeAll() }
    static func sizeBucket(_ r: CGFloat) -> CGFloat {   // round UP to one of `bucketCount` geometric levels in [minBucketR, refR]
        if bucketCount <= 1 { return refR }
        let clamped = max(minBucketR, min(refR, r))
        let t = log(clamped / minBucketR) / log(refR / minBucketR)
        let level = (t * CGFloat(bucketCount - 1)).rounded(.up)
        return minBucketR * pow(refR / minBucketR, level / CGFloat(bucketCount - 1))
    }

    static func texture(_ shape: Shape, _ k: Kind, phase: Int, sizeR: CGFloat, scale: CGFloat) -> SKTexture {
        let bkt = sizeBucket(sizeR)
        let key = "\(shape.rawValue)|\(Int(k.hue)),\(Int(k.sat)),\(Int(k.lit))|\(phase)|\(k.detail)|\(resScale)|\(Int(bkt))"
        if let t = cache[key] { return t }
        let wig = Double(phase) / Double(phases) * .pi * 2
        let t = bakeImage(shape, k, wig: wig, scale: scale * resScale * (bkt / refR)).map { SKTexture(cgImage: $0) } ?? SKTexture()
        cache[key] = t
        return t
    }

    static func bakeImage(_ shape: Shape, _ k: Kind, wig: Double = 0, scale: CGFloat) -> CGImage? {
        let half = pad * refR
        let px = Int((half * 2 * scale).rounded())
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: half, y: half)
        ctx.scaleBy(x: 1, y: -1)      // canvas-like: y-DOWN, origin at body centre
        let r = refR
        let cx = k.detail == "complex"
        switch shape {
        case .fish, .school: fish(ctx, r, k, wig, cx)
        case .whale:  whale(ctx, r, k, wig)
        case .jelly:  jelly(ctx, r, k, wig, cx)
        case .squid:  squid(ctx, r, k, wig, cx)
        case .ray:    ray(ctx, r, k, wig, cx)
        case .angler: angler(ctx, r, k, wig, cx)
        case .crab:   crab(ctx, r, k, wig, cx)
        }
        return ctx.makeImage()
    }

    /// Debug: bake every shape with a sample colour and write PNGs, to inspect the geometry.
    static func dumpAll(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let k = Kind(re: nil, shape: .fish, hue: 200, sat: 70, lit: 60, spd: 0.5, band: (0.4, 0.7), mul: nil, always: nil)
        for shape in [Shape.fish, .whale, .jelly, .squid, .ray, .angler, .crab] {
            guard let img = bakeImage(shape, k, scale: 2) else { print("dump \(shape.rawValue): nil"); continue }
            let rep = NSBitmapImageRep(cgImage: img)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(dir)/\(shape.rawValue).png"))
                print("dump \(shape.rawValue): \(img.width)x\(img.height)")
            }
        }
    }

    // MARK: primitives

    /// Opaque radial shading (lighter centre → darker edge, no transparency) — a rounded solid look
    /// for hard surfaces like the crab shell. Centred on the x-axis so it's left/right symmetric.
    private static func fillDome(_ ctx: CGContext, _ path: CGPath, _ k: Kind, _ gr: CGFloat, cy: CGFloat) {
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        let cs = CGColorSpaceCreateDeviceRGB()
        let colors = [col(k, 2, 1).cgColor, col(k, -16, 1).cgColor, col(k, -32, 1).cgColor] as CFArray   // darker toward the rim
        let c = CGPoint(x: 0, y: cy)
        if let g = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 0.55, 1]) {
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: gr, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.restoreGState()
    }

    private static func fillGlow(_ ctx: CGContext, _ path: CGPath, _ k: Kind, _ gr: CGFloat, at center: CGPoint = .zero) {
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        let cs = CGColorSpaceCreateDeviceRGB()
        let colors = [col(k, 12, 0.95).cgColor, col(k, 0, 0.5).cgColor, col(k, -8, 0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 0.55, 1]) {
            ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: gr, options: [])
        }
        ctx.restoreGState()
    }

    private static func ellipsePath(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: x - rx, y: y - ry, width: 2 * rx, height: 2 * ry), transform: nil)
    }
    private static func triPath(_ ax: CGFloat, _ ay: CGFloat, _ bx: CGFloat, _ by: CGFloat, _ cx: CGFloat, _ cy: CGFloat) -> CGPath {
        let p = CGMutablePath(); p.move(to: .init(x: ax, y: ay)); p.addLine(to: .init(x: bx, y: by)); p.addLine(to: .init(x: cx, y: cy)); p.closeSubpath(); return p
    }
    private static func fill(_ ctx: CGContext, _ path: CGPath, _ c: NSColor) {
        ctx.setFillColor(c.cgColor); ctx.addPath(path); ctx.fillPath()
    }
    private static func dot(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, _ rr: CGFloat, _ c: NSColor) {
        ctx.setFillColor(c.cgColor); ctx.fillEllipse(in: CGRect(x: x - rr, y: y - rr, width: 2 * rr, height: 2 * rr))
    }
    private static func stroke(_ ctx: CGContext, _ c: NSColor, _ w: CGFloat, _ build: (CGMutablePath) -> Void) {
        let p = CGMutablePath(); build(p)
        ctx.setStrokeColor(c.cgColor); ctx.setLineWidth(w); ctx.setLineCap(.round); ctx.addPath(p); ctx.strokePath()
    }
    private static func eyes(_ ctx: CGContext, _ r: CGFloat) {
        dot(ctx, r * 0.5, -r * 0.12, r * 0.11 + 0.6, eyeWhite)
        dot(ctx, r * 0.53, -r * 0.12, r * 0.055 + 0.3, eyeDark)
    }

    // MARK: shapes

    private static func rotated(_ path: CGPath, _ angle: CGFloat) -> CGPath {
        var t = CGAffineTransform(rotationAngle: angle)   // about the body origin, like ctx.rotate
        return path.copy(using: &t) ?? path
    }

    private static func fish(_ ctx: CGContext, _ r: CGFloat, _ k: Kind, _ wig: Double, _ cx: Bool) {
        let gr = r * 1.5
        if cx {                                                     // dorsal + pelvic fins (behind body)
            fillGlow(ctx, rotated(triPath(-r * 0.1, -r * 0.5, r * 0.4, -r * 0.5, -r * 0.35, -r * 1.05), CGFloat(sin(wig + 1) * 0.08)), k, gr)
            fillGlow(ctx, triPath(r * 0.05, r * 0.5, r * 0.35, r * 0.5, -r * 0.1, r * 0.95), k, gr)
        }
        let tail: CGPath                                            // caudal fin — forked when complex
        if cx {
            let p = CGMutablePath(); p.move(to: .init(x: -r * 0.8, y: 0)); p.addLine(to: .init(x: -r * 1.6, y: -r * 0.55))
            p.addLine(to: .init(x: -r * 1.2, y: 0)); p.addLine(to: .init(x: -r * 1.6, y: r * 0.55)); p.closeSubpath()
            tail = rotated(p, CGFloat(sin(wig) * 0.25))
        } else {
            tail = rotated(triPath(-r * 0.8, 0, -r * 1.5, -r * 0.5, -r * 1.5, r * 0.5), CGFloat(sin(wig) * 0.25))
        }
        fillGlow(ctx, tail, k, gr)
        fillGlow(ctx, ellipsePath(0, 0, r, r * 0.6), k, gr)         // body
        if cx {                                                     // markings — solid so they read over the glow body
            fill(ctx, ellipsePath(r * 0.1, r * 0.22, r * 0.78, r * 0.26), col(k, 20, 0.28))   // belly sheen
            stroke(ctx, col(k, -18, 0.5), max(1, r * 0.045)) { p in p.move(to: .init(x: r * 0.42, y: -r * 0.4)); p.addQuadCurve(to: .init(x: r * 0.42, y: r * 0.4), control: .init(x: r * 0.3, y: 0)) }   // gill cover
            for bx in [-r * 0.1, -r * 0.45] {
                stroke(ctx, col(k, -10, 0.32), max(1, r * 0.045)) { p in p.move(to: .init(x: bx, y: -r * 0.45)); p.addQuadCurve(to: .init(x: bx, y: r * 0.45), control: .init(x: bx - r * 0.06, y: 0)) }   // flank bars
            }
        }
        eyes(ctx, r)
    }

    private static func whale(_ ctx: CGContext, _ r: CGFloat, _ k: Kind, _ wig: Double) {
        let cs = CGColorSpaceCreateDeviceRGB()
        let grad = CGGradient(colorsSpace: cs, colors: [col(k, 6, 0.95).cgColor, col(k, -18, 0.95).cgColor] as CFArray, locations: [0, 1])!
        let paint: (CGPath) -> Void = { path in
            ctx.saveGState(); ctx.addPath(path); ctx.clip()
            ctx.drawLinearGradient(grad, start: .init(x: 0, y: -r * 0.6), end: .init(x: 0, y: r * 0.6),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        }
        let fluke = CGMutablePath()                                                    // notched two-lobe fluke
        fluke.move(to: .init(x: -r * 0.85, y: 0))
        fluke.addQuadCurve(to: .init(x: -r * 1.8, y: -r * 0.6), control: .init(x: -r * 1.4, y: -r * 0.25))
        fluke.addQuadCurve(to: .init(x: -r * 1.32, y: 0), control: .init(x: -r * 1.5, y: -r * 0.18))
        fluke.addQuadCurve(to: .init(x: -r * 1.8, y: r * 0.6), control: .init(x: -r * 1.5, y: r * 0.18))
        fluke.addQuadCurve(to: .init(x: -r * 0.85, y: 0), control: .init(x: -r * 1.4, y: r * 0.25))
        fluke.closeSubpath()
        paint(rotated(fluke, CGFloat(sin(wig) * 0.12)))
        paint(ellipsePath(0, 0, r, r * 0.52))                                          // body
        fill(ctx, ellipsePath(r * 0.1, r * 0.18, r * 0.85, r * 0.28), col(k, 18, 0.35))   // belly
        let flip = CGMutablePath()                                                     // pectoral flipper (paddles with wig)
        let ft = CGFloat(sin(wig)) * r * 0.12
        flip.move(to: .init(x: r * 0.34, y: r * 0.24))
        flip.addQuadCurve(to: .init(x: r * 0.02 + ft, y: r * 0.95), control: .init(x: r * 0.3, y: r * 0.62))
        flip.addQuadCurve(to: .init(x: r * 0.05, y: r * 0.26), control: .init(x: -r * 0.15, y: r * 0.7))
        flip.closeSubpath()
        fill(ctx, flip, col(k, -14, 0.92))
        stroke(ctx, col(k, -20, 0.55), max(1, r * 0.03)) { p in                        // jaw line
            p.move(to: .init(x: r * 0.3, y: r * 0.06)); p.addQuadCurve(to: .init(x: r * 0.99, y: r * 0.05), control: .init(x: r * 0.75, y: r * 0.16))
        }
        dot(ctx, r * 0.55, -r * 0.14, r * 0.07, eyeWhite)                              // eye + catchlight
        dot(ctx, r * 0.56, -r * 0.14, r * 0.035, eyeDark)
        dot(ctx, r * 0.575, -r * 0.155, r * 0.014, eyeWhite)
    }

    private static func jelly(_ ctx: CGContext, _ r: CGFloat, _ k: Kind, _ wig: Double, _ cx: Bool) {
        let cp = CGFloat(jellyPulse(wig / (2 * .pi)))               // 0 relaxed → 1 contracted (the jet stroke)
        let sx = 1 - 0.22 * cp, sy = 1 + 0.18 * cp                  // contract: narrower + taller
        ctx.saveGState()
        ctx.clip(to: CGRect(x: -r * 1.2, y: -r * 1.2, width: r * 2.4, height: r * 1.2))
        fillGlow(ctx, ellipsePath(0, 0, r * sx, r * 0.8 * sy), k, r * 1.6)
        if cx { fillGlow(ctx, ellipsePath(0, -r * 0.1 * sy, r * 0.55 * sx, r * 0.5 * sy), k, r * 0.9) }   // inner dome
        ctx.restoreGState()
        if cx {                                                     // scalloped rim (downward frills)
            let bw = r * sx, seg = 2 * bw / 6
            stroke(ctx, col(k, 14, 0.55), 1.4) { p in
                for i in 0..<6 { let x0 = -bw + seg * CGFloat(i); p.move(to: .init(x: x0, y: 0)); p.addQuadCurve(to: .init(x: x0 + seg, y: 0), control: .init(x: x0 + seg / 2, y: r * 0.16)) }
            }
        }
        let nT = cx ? 8 : 6                                         // more, length-varied tentacles when complex
        let spread = 1 - 0.12 * cp, ty0 = r * 0.7 - cp * r * 0.12   // tentacles pull in & up on the jet stroke
        for i in 0..<nT {
            let tx = (CGFloat(i) - CGFloat(nT - 1) / 2) * r * (cx ? 0.24 : 0.3) * spread
            let len = r * (cx ? 1.2 + CGFloat(i % 3) * 0.45 : 1.5)
            stroke(ctx, col(k, 6, 0.5), 1.6) { p in
                p.move(to: .init(x: tx, y: 0))
                for s in 1...6 { let f = CGFloat(s) / 6; p.addLine(to: .init(x: tx + CGFloat(sin(wig + Double(i) + Double(f) * 3)) * 5 * f, y: ty0 + f * len)) }
            }
        }
        if cx {                                                     // frilly oral arms — shorter, thicker, central
            for i in 0..<4 {
                let ax = (CGFloat(i) - 1.5) * r * 0.18 * spread
                stroke(ctx, col(k, 10, 0.6), 2.6) { p in
                    p.move(to: .init(x: ax, y: r * 0.1))
                    for s in 1...5 { let f = CGFloat(s) / 5; p.addLine(to: .init(x: ax + CGFloat(sin(wig + Double(i) * 2 + Double(f) * 4)) * 6 * f, y: r * 0.2 + f * r * 0.85)) }
                }
            }
        }
    }

    private static func squid(_ ctx: CGContext, _ r: CGFloat, _ k: Kind, _ wig: Double, _ cx: Bool) {
        let gr = r * 1.6
        fillGlow(ctx, ellipsePath(r * 0.15, 0, r * 0.95, r * 0.48), k, gr)                       // mantle
        fillGlow(ctx, triPath(r * 1.05, 0, r * 0.55, -r * 0.55, r * 0.55, r * 0.55), k, gr)      // tail fin
        for i in 0..<6 {
            let dy = (CGFloat(i) - 2.5) * r * 0.16
            stroke(ctx, col(k, 6, 0.55), 1.6) { p in
                p.move(to: .init(x: -r * 0.7, y: dy))
                for s in 1...5 { let f = CGFloat(s) / 5; p.addLine(to: .init(x: -r * 0.7 - f * r * 1.3, y: dy + CGFloat(sin(wig + Double(i) + Double(f) * 3)) * 4 * f)) }
            }
        }
        if cx {                                                     // two long feeding tentacles with paddle clubs
            for sgn in [CGFloat(-1), 1] {
                let dy = sgn * r * 0.1, ex = -r * 0.7 - r * 2, ey = dy + CGFloat(sin(wig + Double(sgn))) * r * 0.18
                stroke(ctx, col(k, 6, 0.55), 1.4) { p in p.move(to: .init(x: -r * 0.7, y: dy)); p.addQuadCurve(to: .init(x: ex, y: ey), control: .init(x: -r * 1.6, y: dy + sgn * r * 0.05)) }
                fillGlow(ctx, ellipsePath(ex, ey, r * 0.18, r * 0.09), k, r * 0.5, at: .init(x: ex, y: ey))   // club
            }
            fillGlow(ctx, ellipsePath(-r * 0.3, r * 0.2, r * 0.1, r * 0.18), k, r * 0.6)         // funnel hint
        }
        if cx { for (sx, sy) in [(0.0, -0.15), (0.35, 0.05), (0.62, -0.05), (-0.1, 0.12), (0.22, 0.2)] {   // chromatophores
            dot(ctx, r * CGFloat(sx), r * CGFloat(sy), r * 0.06, col(k, -22, 0.4)) } }
        dot(ctx, r * 0.25, -r * 0.16, r * 0.1, eyeWhite)
        dot(ctx, r * 0.27, -r * 0.16, r * 0.05, eyeDark)
        if cx { dot(ctx, r * 0.29, -r * 0.19, r * 0.025, eyeWhite) }   // catchlight
    }

    private static func ray(_ ctx: CGContext, _ r: CGFloat, _ k: Kind, _ wig: Double, _ cx: Bool) {
        let flap = CGFloat(sin(wig) * 0.5)                          // wings flap
        let body = CGMutablePath()
        body.move(to: .init(x: r * 1.1, y: 0))
        body.addQuadCurve(to: .init(x: -r * 0.9, y: -r * 0.15), control: .init(x: 0, y: -r * (1 + flap)))
        body.addQuadCurve(to: .init(x: -r * 0.9, y: r * 0.15), control: .init(x: -r * 0.4, y: 0))
        body.addQuadCurve(to: .init(x: r * 1.1, y: 0), control: .init(x: 0, y: r * (1 + flap)))
        fillGlow(ctx, body, k, r * 1.5)                             // disc
        if cx { for sgn in [CGFloat(-1), 1] {                       // cephalic fins (horns)
            let h = CGMutablePath(); h.move(to: .init(x: r * 1.1, y: sgn * r * 0.06))
            h.addQuadCurve(to: .init(x: r * 1.4, y: sgn * r * 0.3), control: .init(x: r * 1.46, y: sgn * r * 0.1))
            h.addQuadCurve(to: .init(x: r * 1.1, y: sgn * r * 0.06), control: .init(x: r * 1.2, y: sgn * r * 0.16))
            fillGlow(ctx, h, k, r * 1.5) } }
        stroke(ctx, col(k, 0, 0.45), 1.4) { p in p.move(to: .init(x: -r * 0.85, y: 0)); p.addLine(to: .init(x: -r * 1.9, y: CGFloat(sin(wig)) * r * 0.3)) }   // tail
        if cx {
            let tbx = -r * 1.45, tby = CGFloat(sin(wig)) * r * 0.22
            fill(ctx, triPath(tbx, tby - r * 0.05, tbx - r * 0.2, tby, tbx, tby + r * 0.12), col(k, -6, 0.6))   // tail barb
            for (sx, sy) in [(0.2, -0.25), (-0.1, 0.2), (0.4, 0.15), (-0.3, -0.12)] {                          // dorsal spots
                dot(ctx, r * CGFloat(sx), r * CGFloat(sy), r * 0.07, col(k, 16, 0.3))
            }
        }
        dot(ctx, r * 0.55, -r * 0.12, r * 0.07, eyeWhite)
        dot(ctx, r * 0.55, r * 0.12, r * 0.07, eyeWhite)
        if cx { dot(ctx, r * 0.56, -r * 0.12, r * 0.035, eyeDark); dot(ctx, r * 0.56, r * 0.12, r * 0.035, eyeDark) }
    }

    private static func angler(_ ctx: CGContext, _ r: CGFloat, _ k: Kind, _ wig: Double, _ cx: Bool) {
        let gr = r * 1.5
        fillGlow(ctx, rotated(triPath(-r * 0.7, 0, -r * 1.35, -r * 0.55, -r * 1.35, r * 0.55), CGFloat(sin(wig) * 0.2)), k, gr)   // tail
        fillGlow(ctx, ellipsePath(-r * 0.1, 0, r, r * 0.78), k, gr)                              // body
        if cx {                                                     // pectoral fin (behind the jaw layer)
            let fin = CGMutablePath(); fin.move(to: .init(x: -r * 0.2, y: r * 0.2))
            fin.addQuadCurve(to: .init(x: -r * 0.5, y: r * 0.64), control: .init(x: -r * 0.7, y: r * 0.42))
            fin.addQuadCurve(to: .init(x: -r * 0.2, y: r * 0.2), control: .init(x: -r * 0.3, y: r * 0.46))
            fill(ctx, fin, col(k, -10, 0.8))
        }
        let jaw = CGMutablePath()   // gaping jaw
        jaw.move(to: .init(x: r * 0.45, y: -r * 0.12)); jaw.addLine(to: .init(x: r * 1.05, y: -r * 0.05))
        jaw.addLine(to: .init(x: r * 1.05, y: r * 0.34)); jaw.addLine(to: .init(x: r * 0.4, y: r * 0.42)); jaw.closeSubpath()
        fill(ctx, jaw, col(k, -34, 0.92))
        let toothColor = NSColor(srgbRed: 230/255, green: 240/255, blue: 240/255, alpha: 0.8)
        for i in 0..<4 {   // upper fangs
            let tx = r * (0.55 + CGFloat(i) * 0.13)
            stroke(ctx, toothColor, 1) { p in p.move(to: .init(x: tx, y: r * 0.02)); p.addLine(to: .init(x: tx + r * 0.04, y: r * 0.17)) }
        }
        if cx {
            for i in 0..<4 {   // lower fangs
                let tx = r * (0.5 + CGFloat(i) * 0.13)
                stroke(ctx, toothColor, 1) { p in p.move(to: .init(x: tx, y: r * 0.4)); p.addLine(to: .init(x: tx + r * 0.04, y: r * 0.25)) }
            }
            for i in 0..<5 {   // dorsal spines
                let sx = -r * 0.55 + CGFloat(i) * r * 0.2
                stroke(ctx, col(k, -22, 0.7), max(1, r * 0.045)) { p in p.move(to: .init(x: sx, y: -r * 0.55)); p.addLine(to: .init(x: sx - r * 0.05, y: -r * 0.82 - (i == 2 ? r * 0.06 : 0))) }
            }
            for (sx, sy) in [(-0.3, -0.2), (-0.5, 0.08), (-0.1, 0.28), (-0.55, -0.12)] {   // pocked skin
                dot(ctx, r * CGFloat(sx), r * CGFloat(sy), r * 0.06, col(k, -24, 0.5))
            }
        }
        dot(ctx, r * 0.1, -r * 0.28, r * 0.13, eyeWhite)
        dot(ctx, r * 0.13, -r * 0.28, r * 0.06, eyeDark)
        // lure bobs (freezes with wig in rigid mode)
        let bx = r * 1.2 + CGFloat(sin(wig)) * r * 0.12, by = -r * 0.72 + CGFloat(cos(wig)) * r * 0.08
        stroke(ctx, col(k, 0, 0.6), 1.4) { p in p.move(to: .init(x: r * 0.1, y: -r * 0.55)); p.addQuadCurve(to: .init(x: bx, y: by), control: .init(x: r * 0.7, y: -r * 1.1)) }
        let cs = CGColorSpaceCreateDeviceRGB()
        let lg = CGGradient(colorsSpace: cs, colors: [nsColor(hue: 48, sat: 100, lit: 86, alpha: 0.95).cgColor, col(k, 20, 0.7).cgColor, col(k, 0, 0).cgColor] as CFArray, locations: [0, 0.4, 1])!
        ctx.saveGState(); ctx.addPath(ellipsePath(bx, by, r * 0.6, r * 0.6)); ctx.clip()
        ctx.drawRadialGradient(lg, startCenter: .init(x: bx, y: by), startRadius: 0, endCenter: .init(x: bx, y: by), endRadius: r * 0.6, options: [])
        ctx.restoreGState()
    }

    private static func crab(_ ctx: CGContext, _ r: CGFloat, _ k: Kind, _ wig: Double, _ cx: Bool) {
        for sgn in [CGFloat(-1), 1] {   // scuttling legs (knee-jointed when complex)
            for i in 0..<3 {
                let lx = (CGFloat(i) - 1) * r * 0.5
                let sw = CGFloat(sin(wig + Double(i) + (sgn > 0 ? 0 : 1.6))) * r * 0.12
                stroke(ctx, col(k, -12, 0.85), 2) { p in
                    p.move(to: .init(x: lx, y: 0))
                    if cx { p.addLine(to: .init(x: lx + sgn * r * 0.42, y: r * 0.32 + sw * 0.6)); p.addLine(to: .init(x: lx + sgn * r * 0.6, y: r * 0.62 + sw)) }
                    else { p.addLine(to: .init(x: lx + sgn * r * 0.5, y: r * 0.5 + sw)) }
                }
            }
        }
        for sgn in [CGFloat(-1), 1] {   // arms (with opening pincers when complex)
            let ex = sgn * r * 1.2, ey = -r * 0.5 + CGFloat(sin(wig)) * r * 0.08
            stroke(ctx, col(k, -4, 0.9), 2) { p in p.move(to: .init(x: sgn * r * 0.7, y: -r * 0.1)); p.addLine(to: .init(x: ex, y: ey)) }
            if cx {
                let gap = abs(CGFloat(sin(wig * 2 + (sgn > 0 ? 0 : 1)))) * r * 0.12 + r * 0.04
                fill(ctx, triPath(ex, ey, ex + sgn * r * 0.3, ey - r * 0.05 - gap, ex + sgn * r * 0.16, ey - gap * 0.2), col(k, -2, 0.95))
                fill(ctx, triPath(ex, ey, ex + sgn * r * 0.28, ey + r * 0.1 + gap * 0.3, ex + sgn * r * 0.15, ey + gap * 0.2), col(k, -2, 0.95))
            }
        }
        fillDome(ctx, ellipsePath(0, 0, r, r * 0.7), k, r, cy: -r * 0.1)                      // opaque shaded shell (symmetric)
        fill(ctx, ellipsePath(0, -r * 0.24, r * 0.34, r * 0.16), col(k, 12, 0.35))           // top-centre sheen
        for (sx, sy) in [(0.12, -0.3), (0.32, -0.12), (0.5, 0.05), (0.22, 0.18), (0.06, 0.06), (0.4, 0.26), (0.14, 0.32), (0.0, -0.14)] {   // speckles (symmetric so dir-flip stays invisible)
            dot(ctx, r * CGFloat(sx), r * CGFloat(sy), r * 0.035, col(k, -26, 0.55))
            if sx > 0 { dot(ctx, -r * CGFloat(sx), r * CGFloat(sy), r * 0.035, col(k, -26, 0.55)) }
        }
        if cx {                                                   // shell ridges, mandibles
            stroke(ctx, col(k, -20, 0.5), 1.4) { p in p.move(to: .init(x: -r * 0.5, y: -r * 0.12)); p.addQuadCurve(to: .init(x: r * 0.5, y: -r * 0.12), control: .init(x: 0, y: -r * 0.5)) }
            stroke(ctx, col(k, -20, 0.5), 1.4) { p in p.move(to: .init(x: -r * 0.34, y: -r * 0.02)); p.addQuadCurve(to: .init(x: r * 0.34, y: -r * 0.02), control: .init(x: 0, y: -r * 0.32)) }
            for sgn in [CGFloat(-1), 1] { stroke(ctx, col(k, -16, 0.7), 1.6) { p in p.move(to: .init(x: sgn * r * 0.06, y: r * 0.46)); p.addLine(to: .init(x: sgn * r * 0.12, y: r * 0.64)) } }
        }
        for sgn in [CGFloat(-1), 1] {   // eyestalks
            stroke(ctx, col(k, -8, 0.8), 2) { p in p.move(to: .init(x: sgn * r * 0.25, y: -r * 0.45)); p.addLine(to: .init(x: sgn * r * 0.3, y: -r * 0.8)) }
            dot(ctx, sgn * r * 0.3, -r * 0.8, r * 0.1, eyeWhite)
            dot(ctx, sgn * r * 0.3, -r * 0.8, r * 0.05, eyeDark)
        }
    }
}
