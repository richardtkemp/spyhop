import SpriteKit

/// Drifting clouds. Each cloud is ONE baked-texture sprite (a 5-puff cluster), moved/scaled/
/// tinted per frame — not 5 live SKShapeNodes — so day/night recolour is a cheap GPU
/// colorBlendFactor and there's no per-frame tessellation. Ported from drawSky()'s cloud block.
@MainActor
final class Clouds {
    let node = SKNode()

    private static let puffs: [(CGFloat, CGFloat, CGFloat)] =
        [(0, 0, 1), (0.6, 0.1, 0.8), (-0.6, 0.12, 0.75), (0.25, -0.2, 0.7), (-0.25, -0.15, 0.65)]
    private static let texSize = CGSize(width: 150, height: 80)   // logical cluster size at c.s = 1
    private static let tex = Clouds.makeCloudTexture()

    private final class Cloud { let sprite: SKSpriteNode; var x: CGFloat; var y: CGFloat; let s: CGFloat; let v: CGFloat; var a: CGFloat
        init(x: CGFloat, y: CGFloat, s: CGFloat, v: CGFloat) {
            sprite = SKSpriteNode(texture: Clouds.tex); sprite.size = Clouds.texSize; sprite.colorBlendFactor = 1
            self.x = x; self.y = y; self.s = s; self.v = v; a = 0
        } }

    private var clouds: [Cloud] = []
    private var backClouds: [Cloud] = []
    private var W: CGFloat = 0, H: CGFloat = 0

    init() { node.zPosition = -8 }

    func build(size: CGSize) {
        W = size.width; H = size.height
        node.removeAllChildren(); clouds = []; backClouds = []
        for _ in 0..<22 {
            let c = Cloud(x: .random(in: 0..<1), y: 0.04 + .random(in: 0..<0.17), s: 0.7 + .random(in: 0..<0.7), v: 0.4 + .random(in: 0..<0.7))
            clouds.append(c); node.addChild(c.sprite)
        }
        for _ in 0..<6 {   // overcast layer: bigger, slower
            let c = Cloud(x: .random(in: 0..<1), y: 0.05 + .random(in: 0..<0.16), s: 2.0 + .random(in: 0..<1.6), v: 0.2 + .random(in: 0..<0.3))
            backClouds.append(c); node.addChild(c.sprite)
        }
    }

    func update(sunH: Double, wind: Double, cloudCount: Double, cloudSize: Double, wi: Double, motionScale: Double) {
        let tint = mixColor(Pal.cloudNight, Pal.cloudDay, sunH)
        let M = CGFloat(motionScale), wnd = CGFloat(wind)

        for (i, c) in clouds.enumerated() {
            c.a += ((i < Int(cloudCount) ? 1 : 0) - c.a) * CGFloat(Const.cloudFade)
            c.x += wnd * c.v / W * 0.012 * M; if c.x > 1.28 { c.x = -0.25 }
            c.sprite.position = CGPoint(x: c.x * W, y: H - c.y * H)
            c.sprite.setScale(c.s * CGFloat(cloudSize))
            c.sprite.color = tint; c.sprite.alpha = 0.6 * c.a
        }

        let overcast = clampD((wi - 0.5) * 1.3, 0, 0.55)
        for c in backClouds {
            c.x += wnd * c.v / W * 0.006 * M; if c.x > 1.45 { c.x = -0.45 }
            c.sprite.position = CGPoint(x: c.x * W, y: H - c.y * H)
            c.sprite.setScale(c.s * (1 + CGFloat(wi) * 0.3))
            c.sprite.color = tint; c.sprite.alpha = CGFloat(overcast) * 0.6
        }
    }

    /// Bake the 5-puff white cluster once; tinted per-cloud via colorBlendFactor.
    private static func makeCloudTexture() -> SKTexture {
        let scale: CGFloat = 2, w = texSize.width, h = texSize.height
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: Int(w * scale), height: Int(h * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return SKTexture() }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: w / 2, y: h / 2)
        ctx.setFillColor(NSColor(white: 1, alpha: 0.55).cgColor)
        for (dx, dy, rr) in puffs {
            let rx = 40 * rr, ry = 26 * rr
            ctx.fillEllipse(in: CGRect(x: dx * 46 - rx, y: dy * 46 - ry, width: 2 * rx, height: 2 * ry))
        }
        return ctx.makeImage().map { SKTexture(cgImage: $0) } ?? SKTexture()
    }
}
