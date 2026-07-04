import SpriteKit

/// Sky bodies driven by sun height: stars (night, twinkling), a moon (fixed high-right, dims by
/// day), and a sun (rises out of the water on the opposite side, height ∝ sunH). Ported from the
/// moon/sun/stars block of drawSky() in spyhop.html.
@MainActor
final class Celestial {
    let node = SKNode()

    private let starLayer = SKNode()
    private let moonGlow: SKSpriteNode
    private let moonCore = SKShapeNode(circleOfRadius: 1)
    private var moonCraters: [SKShapeNode] = []
    private let sunGlow: SKSpriteNode
    private let sunCore = SKShapeNode(circleOfRadius: 1)

    private struct Star { let n: SKShapeNode; let x: CGFloat; let y: CGFloat; let ph: CGFloat }
    private var stars: [Star] = []

    private var W: CGFloat = 0, H: CGFloat = 0, waterY: CGFloat = 0, r: CGFloat = 1
    private static let glowTex = Celestial.makeGlow()

    init() {
        node.zPosition = -9.5   // behind the foreground water (-9) so the sun doesn't shine underwater; above the sky gradient (-11)
        moonGlow = SKSpriteNode(texture: Celestial.glowTex)
        sunGlow = SKSpriteNode(texture: Celestial.glowTex)
        moonGlow.blendMode = .add; sunGlow.blendMode = .add
        moonGlow.colorBlendFactor = 1; sunGlow.colorBlendFactor = 1
        moonGlow.color = NSColor(srgbRed: 180/255, green: 205/255, blue: 200/255, alpha: 1)
        sunGlow.color = NSColor(srgbRed: 255/255, green: 200/255, blue: 120/255, alpha: 1)
        moonCore.lineWidth = 0; moonCore.fillColor = NSColor(srgbRed: 231/255, green: 239/255, blue: 230/255, alpha: 1)
        sunCore.lineWidth = 0; sunCore.fillColor = NSColor(srgbRed: 255/255, green: 236/255, blue: 190/255, alpha: 1)
        node.addChild(starLayer); node.addChild(moonGlow); node.addChild(moonCore); node.addChild(sunGlow); node.addChild(sunCore)
    }

    func build(size: CGSize, waterY: CGFloat) {
        W = size.width; H = size.height; self.waterY = waterY
        r = min(W, H) * 0.05
        // moon fixed high-right; glow ~r*8, core r, two craters
        moonGlow.size = CGSize(width: r * 8, height: r * 8)
        moonGlow.position = CGPoint(x: W * 0.82, y: H - H * 0.12)
        moonCore.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
        moonCore.position = moonGlow.position
        moonCraters.forEach { $0.removeFromParent() }; moonCraters = []
        for (dx, dy, rr) in [(-0.3, -0.2, 0.22), (0.35, 0.3, 0.15)] {
            let c = SKShapeNode(circleOfRadius: r * CGFloat(rr))
            c.lineWidth = 0; c.fillColor = NSColor(srgbRed: 120/255, green: 140/255, blue: 140/255, alpha: 0.18)
            c.position = CGPoint(x: moonGlow.position.x + r * CGFloat(dx), y: moonGlow.position.y - r * CGFloat(dy))
            node.addChild(c); moonCraters.append(c)
        }
        sunGlow.size = CGSize(width: r * 12, height: r * 12)
        sunCore.path = CGPath(ellipseIn: CGRect(x: -r * 1.1, y: -r * 1.1, width: 2.2 * r, height: 2.2 * r), transform: nil)

        // stars: 90 in the top third
        starLayer.removeAllChildren(); stars = []
        for _ in 0..<90 {
            let sr = CGFloat.random(in: 0.2..<1.4)
            let n = SKShapeNode(circleOfRadius: sr)
            n.lineWidth = 0; n.fillColor = NSColor(srgbRed: 200/255, green: 220/255, blue: 225/255, alpha: 1); n.blendMode = .add
            let x = CGFloat.random(in: 0..<1) * W, y = CGFloat.random(in: 0..<0.34) * H
            n.position = CGPoint(x: x, y: H - y)
            starLayer.addChild(n); stars.append(Star(n: n, x: x, y: y, ph: .random(in: 0..<(.pi * 2))))
        }
    }

    func update(sunH: Double, clock: Double) {
        let df = CGFloat(sunH), t = CGFloat(clock)
        // stars: twinkle + fade out by day
        let starDim = 1 - df
        for s in stars { s.n.alpha = 0.55 * (0.9 + 0.1 * sin(t * 1.5 + s.ph)) * starDim }
        // sun rises from fully submerged (sunH 0) to high (sunH 1); compute the fraction of its
        // disc above the waterline via the circular-segment area.
        let R = Double(r) * 1.1
        let syDown = lerpD(Double(waterY) + R, Double(H) * 0.12, sunH)
        let tt = clampD((Double(waterY) - syDown) / R, -1, 1)          // signed height of centre above the line / R
        let sunFrac = 0.5 + (tt * (1 - tt * tt).squareRoot() + asin(tt)) / .pi   // 0 = submerged, 1 = fully up

        // moon fades in proportion to the sun's visible area (invisible when the sun is fully up)
        let moonA = CGFloat(max(0, 1 - sunFrac))
        moonGlow.alpha = 0.4 * moonA; moonCore.alpha = moonA
        moonCraters.forEach { $0.alpha = moonA }

        let vis = df > 0.01
        sunGlow.isHidden = !vis; sunCore.isHidden = !vis
        if vis {
            let p = CGPoint(x: W * 0.18, y: H - CGFloat(syDown))
            sunGlow.position = p; sunCore.position = p
            sunGlow.alpha = 0.55; sunCore.alpha = 1   // full opacity — it emerges from the water, not fades in
        }
    }

    private static func makeGlow() -> SKTexture {
        let s = 128
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let g = CGGradient(colorsSpace: cs, colors: [NSColor(white: 1, alpha: 1).cgColor,
                                                           NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                                 locations: [0, 1]) else { return SKTexture() }
        let c = CGFloat(s) / 2
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: c, y: c), startRadius: 0,
                               endCenter: CGPoint(x: c, y: c), endRadius: c, options: [])
        return ctx.makeImage().map { SKTexture(cgImage: $0) } ?? SKTexture()
    }
}
