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

    static let phases = 16   // wiggle-atlas frames per kind (texture swapped per frame → articulation)

    static func texture(_ shape: Shape, _ k: Kind, phase: Int, scale: CGFloat) -> SKTexture {
        let key = "\(shape.rawValue)|\(Int(k.hue)),\(Int(k.sat)),\(Int(k.lit))|\(phase)"
        if let t = cache[key] { return t }
        let wig = Double(phase) / Double(phases) * .pi * 2
        let t = bakeImage(shape, k, wig: wig, scale: scale).map { SKTexture(cgImage: $0) } ?? SKTexture()
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
        switch shape {
        case .fish, .school: fish(ctx, r, k, wig)
        case .whale:  whale(ctx, r, k, wig)
        case .jelly:  jelly(ctx, r, k, wig)
        case .squid:  squid(ctx, r, k, wig)
        case .ray:    ray(ctx, r, k, wig)
        case .angler: angler(ctx, r, k, wig)
        case .crab:   crab(ctx, r, k, wig)
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

    private static func fillGlow(_ ctx: CGContext, _ path: CGPath, _ k: Kind, _ gr: CGFloat) {
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        let cs = CGColorSpaceCreateDeviceRGB()
        let colors = [col(k, 12, 0.95).cgColor, col(k, 0, 0.5).cgColor, col(k, -8, 0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 0.55, 1]) {
            ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: gr, options: [])
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

    private static func fish(_ ctx: CGContext, _ r: CGFloat, _ k: Kind, _ wig: Double) {
        let gr = r * 1.5
        let tail = rotated(triPath(-r * 0.8, 0, -r * 1.5, -r * 0.5, -r * 1.5, r * 0.5), CGFloat(sin(wig) * 0.25))
        fillGlow(ctx, tail, k, gr)                                   // wagging tail
        fillGlow(ctx, ellipsePath(0, 0, r, r * 0.6), k, gr)         // body
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
        let tail = CGMutablePath()
        tail.move(to: .init(x: -r * 0.9, y: 0))
        tail.addQuadCurve(to: .init(x: -r * 1.7, y: -r * 0.1), control: .init(x: -r * 1.5, y: -r * 0.6))
        tail.addQuadCurve(to: .init(x: -r * 0.9, y: 0), control: .init(x: -r * 1.5, y: r * 0.05))
        paint(rotated(tail, CGFloat(sin(wig) * 0.12)))
        paint(ellipsePath(0, 0, r, r * 0.52))
        fill(ctx, ellipsePath(r * 0.1, r * 0.18, r * 0.85, r * 0.28), col(k, 18, 0.35))   // belly
        dot(ctx, r * 0.55, -r * 0.14, r * 0.06 + 1, eyeWhite)
    }

    private static func jelly(_ ctx: CGContext, _ r: CGFloat, _ k: Kind, _ wig: Double) {
        let pulse = 1 + CGFloat(sin(wig)) * 0.12                     // bell pulses
        ctx.saveGState()
        ctx.clip(to: CGRect(x: -r * 1.2, y: -r * 1.2, width: r * 2.4, height: r * 1.2))
        fillGlow(ctx, ellipsePath(0, 0, r * pulse, r * 0.8 * pulse), k, r * 1.6)
        ctx.restoreGState()
        for i in 0..<6 {   // swaying tentacles
            let tx = (CGFloat(i) - 2.5) * r * 0.3
            stroke(ctx, col(k, 6, 0.5), 1.6) { p in
                p.move(to: .init(x: tx, y: 0))
                for s in 1...6 { let f = CGFloat(s) / 6; p.addLine(to: .init(x: tx + CGFloat(sin(wig + Double(i) + Double(f) * 3)) * 5 * f, y: r * 0.7 + f * r * 1.5)) }
            }
        }
    }

    private static func squid(_ ctx: CGContext, _ r: CGFloat, _ k: Kind, _ wig: Double) {
        let gr = r * 1.6
        fillGlow(ctx, ellipsePath(r * 0.15, 0, r * 0.95, r * 0.48), k, gr)
        fillGlow(ctx, triPath(r * 1.05, 0, r * 0.55, -r * 0.55, r * 0.55, r * 0.55), k, gr)
        for i in 0..<6 {
            let dy = (CGFloat(i) - 2.5) * r * 0.16
            stroke(ctx, col(k, 6, 0.55), 1.6) { p in
                p.move(to: .init(x: -r * 0.7, y: dy))
                for s in 1...5 { let f = CGFloat(s) / 5; p.addLine(to: .init(x: -r * 0.7 - f * r * 1.3, y: dy + CGFloat(sin(wig + Double(i) + Double(f) * 3)) * 4 * f)) }
            }
        }
        dot(ctx, r * 0.25, -r * 0.16, r * 0.1, eyeWhite)
        dot(ctx, r * 0.27, -r * 0.16, r * 0.05, eyeDark)
    }

    private static func ray(_ ctx: CGContext, _ r: CGFloat, _ k: Kind, _ wig: Double) {
        let flap = CGFloat(sin(wig) * 0.5)                          // wings flap
        let body = CGMutablePath()
        body.move(to: .init(x: r * 1.1, y: 0))
        body.addQuadCurve(to: .init(x: -r * 0.9, y: -r * 0.15), control: .init(x: 0, y: -r * (1 + flap)))
        body.addQuadCurve(to: .init(x: -r * 0.9, y: r * 0.15), control: .init(x: -r * 0.4, y: 0))
        body.addQuadCurve(to: .init(x: r * 1.1, y: 0), control: .init(x: 0, y: r * (1 + flap)))
        fillGlow(ctx, body, k, r * 1.5)
        stroke(ctx, col(k, 0, 0.45), 1.4) { p in p.move(to: .init(x: -r * 0.85, y: 0)); p.addLine(to: .init(x: -r * 1.9, y: CGFloat(sin(wig)) * r * 0.3)) }
        dot(ctx, r * 0.55, -r * 0.12, r * 0.07, eyeWhite)
        dot(ctx, r * 0.55, r * 0.12, r * 0.07, eyeWhite)
    }

    private static func angler(_ ctx: CGContext, _ r: CGFloat, _ k: Kind, _ wig: Double) {
        let gr = r * 1.5
        fillGlow(ctx, rotated(triPath(-r * 0.7, 0, -r * 1.35, -r * 0.55, -r * 1.35, r * 0.55), CGFloat(sin(wig) * 0.2)), k, gr)   // tail
        fillGlow(ctx, ellipsePath(-r * 0.1, 0, r, r * 0.78), k, gr)                              // body
        let jaw = CGMutablePath()   // gaping jaw
        jaw.move(to: .init(x: r * 0.45, y: -r * 0.12)); jaw.addLine(to: .init(x: r * 1.05, y: -r * 0.05))
        jaw.addLine(to: .init(x: r * 1.05, y: r * 0.34)); jaw.addLine(to: .init(x: r * 0.4, y: r * 0.42)); jaw.closeSubpath()
        fill(ctx, jaw, col(k, -34, 0.92))
        for i in 0..<4 {   // teeth
            let tx = r * (0.55 + CGFloat(i) * 0.13)
            stroke(ctx, NSColor(srgbRed: 230/255, green: 240/255, blue: 240/255, alpha: 0.8), 1) { p in
                p.move(to: .init(x: tx, y: r * 0.02)); p.addLine(to: .init(x: tx + r * 0.04, y: r * 0.17))
            }
        }
        dot(ctx, r * 0.1, -r * 0.28, r * 0.13, eyeWhite)
        dot(ctx, r * 0.13, -r * 0.28, r * 0.06, eyeDark)
        // lure bobs
        let bx = r * 1.2 + CGFloat(sin(wig)) * r * 0.12, by = -r * 0.72 + CGFloat(cos(wig)) * r * 0.08
        stroke(ctx, col(k, 0, 0.6), 1.4) { p in p.move(to: .init(x: r * 0.1, y: -r * 0.55)); p.addQuadCurve(to: .init(x: bx, y: by), control: .init(x: r * 0.7, y: -r * 1.1)) }
        let cs = CGColorSpaceCreateDeviceRGB()
        let lg = CGGradient(colorsSpace: cs, colors: [nsColor(hue: 48, sat: 100, lit: 86, alpha: 0.95).cgColor, col(k, 20, 0.7).cgColor, col(k, 0, 0).cgColor] as CFArray, locations: [0, 0.4, 1])!
        ctx.saveGState(); ctx.addPath(ellipsePath(bx, by, r * 0.6, r * 0.6)); ctx.clip()
        ctx.drawRadialGradient(lg, startCenter: .init(x: bx, y: by), startRadius: 0, endCenter: .init(x: bx, y: by), endRadius: r * 0.6, options: [])
        ctx.restoreGState()
    }

    private static func crab(_ ctx: CGContext, _ r: CGFloat, _ k: Kind, _ wig: Double) {
        for sgn in [CGFloat(-1), 1] {   // scuttling legs
            for i in 0..<3 {
                let lx = (CGFloat(i) - 1) * r * 0.5
                let sw = CGFloat(sin(wig + Double(i) + (sgn > 0 ? 0 : 1.6))) * r * 0.12
                stroke(ctx, col(k, -12, 0.85), 2) { p in p.move(to: .init(x: lx, y: 0)); p.addLine(to: .init(x: lx + sgn * r * 0.5, y: r * 0.5 + sw)) }
            }
        }
        for sgn in [CGFloat(-1), 1] {   // claws
            stroke(ctx, col(k, -4, 0.9), 2) { p in p.move(to: .init(x: sgn * r * 0.7, y: -r * 0.1)); p.addLine(to: .init(x: sgn * r * 1.2, y: -r * 0.5 + CGFloat(sin(wig)) * r * 0.08)) }
        }
        fillGlow(ctx, ellipsePath(0, 0, r, r * 0.7), k, r * 1.2)   // shell
        for sgn in [CGFloat(-1), 1] {   // eyestalks
            stroke(ctx, col(k, -8, 0.8), 2) { p in p.move(to: .init(x: sgn * r * 0.25, y: -r * 0.45)); p.addLine(to: .init(x: sgn * r * 0.3, y: -r * 0.8)) }
            dot(ctx, sgn * r * 0.3, -r * 0.8, r * 0.1, eyeWhite)
            dot(ctx, sgn * r * 0.3, -r * 0.8, r * 0.05, eyeDark)
        }
    }
}
