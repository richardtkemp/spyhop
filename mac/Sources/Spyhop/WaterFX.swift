import SpriteKit

/// Water-column effects: rising bubbles + twinkling plankton (baked-texture sprites, cheap), and
/// the wavy surface line (one dynamic SKShapeNode). Ported from drawBubbles()/drawSurface() and
/// the plankton loop in drawWater(). Sim y-DOWN → SpriteKit y-UP on write.
@MainActor
final class WaterFX {
    private let bubbleLayer = SKNode()
    private let planktonLayer = SKNode()
    private let godCrop = SKCropNode()      // clips godrays to the foreground (wavy) water
    private let godMask = SKShapeNode()
    private let whitecapLayer = SKNode()
    private let surface = SKShapeNode()
    private struct GodBeam { let node: SKSpriteNode; var x: CGFloat; var vx: CGFloat; var age: CGFloat; var life: CGFloat; var peak: CGFloat }
    private var godBeams: [GodBeam] = []
    private var caps: [SKSpriteNode] = []

    private static let dotTex = WaterFX.makeDot(ring: false)
    private static let ringTex = WaterFX.makeDot(ring: true)
    private static let beamTex = WaterFX.makeBeam()

    private struct Bubble { let n: SKSpriteNode; var x: CGFloat; var y: CGFloat; let r: CGFloat; let ph: CGFloat }
    private var bubbles: [Bubble] = []

    private struct Plankton { let x: CGFloat; let y: CGFloat; let ph: CGFloat; let sp: CGFloat }
    private let planktonSpec: [Plankton]
    private var planktonNodes: [SKSpriteNode] = []

    private var W: CGFloat = 0, H: CGFloat = 0, waterY: CGFloat = 0
    private let bubbleColor = NSColor(srgbRed: 160/255, green: 225/255, blue: 220/255, alpha: 1)
    private let planktonColor = NSColor(srgbRed: 140/255, green: 210/255, blue: 200/255, alpha: 1)
    private let surfaceColor = NSColor(srgbRed: 150/255, green: 220/255, blue: 220/255, alpha: 0.35)

    init() {
        planktonSpec = (0..<40).map { _ in
            Plankton(x: .random(in: 0..<1), y: .random(in: 0..<1), ph: .random(in: 0..<(.pi * 2)), sp: .random(in: 0.1..<0.4))
        }
        planktonLayer.zPosition = -9; bubbleLayer.zPosition = -2; surface.zPosition = 5
        godCrop.zPosition = -8; whitecapLayer.zPosition = 5
        godMask.fillColor = .white; godMask.strokeColor = .clear; godCrop.maskNode = godMask
        surface.strokeColor = surfaceColor; surface.lineWidth = 1.4; surface.blendMode = .add; surface.fillColor = .clear
    }

    func attach(to scene: SKScene) { [planktonLayer, godCrop, bubbleLayer, surface, whitecapLayer].forEach(scene.addChild) }

    func build(size: CGSize, waterY: CGFloat) {
        W = size.width; H = size.height; self.waterY = waterY
        planktonLayer.removeAllChildren(); planktonNodes = []
        for _ in planktonSpec {
            let d = SKSpriteNode(texture: WaterFX.dotTex); d.size = CGSize(width: 4, height: 4)
            d.color = planktonColor; d.colorBlendFactor = 1; d.blendMode = .add
            planktonLayer.addChild(d); planktonNodes.append(d)
        }
        bubbleLayer.removeAllChildren(); bubbles = []

        godCrop.removeAllChildren(); godBeams = []
        for _ in 0..<6 {
            let n = SKSpriteNode(texture: WaterFX.beamTex)
            n.anchorPoint = CGPoint(x: 0.5, y: 1); n.blendMode = .add; n.colorBlendFactor = 1; n.alpha = 0
            n.color = NSColor(srgbRed: 120/255, green: 200/255, blue: 200/255, alpha: 1)
            godCrop.addChild(n)
            var beam = GodBeam(node: n, x: 0, vx: 0, age: 0, life: 1, peak: 0)
            respawn(&beam); beam.age = .random(in: 0..<beam.life)   // stagger initial phase
            godBeams.append(beam)
        }
        whitecapLayer.removeAllChildren(); caps = []
        for _ in 0..<(Int(W / 46) + 1) {
            let c = SKSpriteNode(texture: WaterFX.dotTex); c.size = CGSize(width: 12, height: 4)
            c.color = NSColor(srgbRed: 190/255, green: 235/255, blue: 235/255, alpha: 1); c.colorBlendFactor = 1; c.blendMode = .add; c.isHidden = true
            whitecapLayer.addChild(c); caps.append(c)
        }
    }

    private func surfAt(_ x: CGFloat, _ t: CGFloat, _ waveAmp: CGFloat, _ M: CGFloat) -> CGFloat {
        waterY + sin(x * 0.02 + t * 1.4 * M) * waveAmp + sin(x * 0.05 - t * M) * waveAmp * 0.4
    }

    func update(dt: Double, clock: Double, wind: Double, waveAmp: Double, wi: Double, motionScale: Double, sunH: Double) {
        let t = CGFloat(clock), M = CGFloat(motionScale), wnd = CGFloat(wind), wave = CGFloat(waveAmp)
        // God rays converge on whichever light is brighter (a shaft comes from one source, not a
        // blend): sun brightness ∝ sunH; the moon dims to ~0.22 by day. Aim each beam to hit it.
        let df = CGFloat(sunH)
        let sunLit = df > 1 - df * 0.78
        let godSrcX = sunLit ? W * 0.18 : W * 0.82                         // the brighter light's x
        let godSrcY = sunLit ? waterY + (H * 0.12 - waterY) * df : H * 0.12   // its height (sim y-down)
        let godGap = max(H * 0.08, waterY - godSrcY)                       // surface→light drop, clamped off the horizon

        // godrays: clipped to the wavy foreground water; each beam has its own random lifecycle
        let mp = CGMutablePath()
        mp.move(to: CGPoint(x: 0, y: 0)); var mgx: CGFloat = 0
        while mgx <= W { mp.addLine(to: CGPoint(x: mgx, y: H - surfAt(mgx, t, wave, M))); mgx += 12 }
        mp.addLine(to: CGPoint(x: W, y: H - surfAt(W, t, wave, M)))   // reach the right edge exactly
        mp.addLine(to: CGPoint(x: W, y: 0)); mp.closeSubpath()
        godMask.path = mp
        for i in godBeams.indices {
            godBeams[i].age += CGFloat(dt)
            if godBeams[i].age >= godBeams[i].life { respawn(&godBeams[i]) }
            godBeams[i].x += godBeams[i].vx * CGFloat(dt) * M
            let b = godBeams[i]
            let env = min(min(b.age / 1.5, (b.life - b.age) / 1.5), 1)   // fade in over 1.5s, hold, fade out
            b.node.position = CGPoint(x: b.x, y: H - waterY + wave + 20)   // top above the crests; mask trims it to the surface
            b.node.zRotation = max(-1.05, min(1.05, atan2(b.x - godSrcX, godGap)))   // aim the beam at the light
            b.node.alpha = max(0, env) * b.peak
        }
        let capA = CGFloat(clampD((wi - 0.45) * 0.5, 0, 0.3))   // whitecaps at high wind
        var ci = 0, cx: CGFloat = 0
        while cx <= W && ci < caps.count {
            let show = wi > 0.45 && sin(cx * 0.02 + t * 1.4 * M) > 0.6
            caps[ci].isHidden = !show
            if show { caps[ci].position = CGPoint(x: cx, y: H - surfAt(cx, t, wave, M)); caps[ci].alpha = capA }
            cx += 46; ci += 1
        }

        for (i, n) in planktonNodes.enumerated() {
            let pk = planktonSpec[i]
            let px = ((pk.x + t * pk.sp * 0.006 * M).truncatingRemainder(dividingBy: 1)) * W
            let py = waterY + pk.y * (H - waterY) + sin(t + pk.ph) * 6 * M
            n.position = CGPoint(x: px < 0 ? px + W : px, y: H - py)
            n.alpha = 0.12 + 0.1 * sin(t * 2 + pk.ph)
        }

        if CGFloat.random(in: 0..<1) < 0.4 {
            let sm = min(W * 0.6, wnd * 2.2)
            let r = CGFloat.random(in: 1..<4)
            let b = SKSpriteNode(texture: WaterFX.ringTex); b.size = CGSize(width: r * 2.6, height: r * 2.6)
            b.color = bubbleColor; b.colorBlendFactor = 1; b.blendMode = .add; b.alpha = 0.28
            bubbleLayer.addChild(b)
            bubbles.append(Bubble(n: b, x: -sm + .random(in: 0..<(W + sm)), y: H, r: r, ph: .random(in: 0..<(.pi * 2))))
        }
        for i in bubbles.indices.reversed() {
            bubbles[i].y -= (20 + bubbles[i].r * 6) * CGFloat(dt) * M
            bubbles[i].x += (wnd * 0.002 + sin(t * 1.5 + bubbles[i].ph) * 0.01 * wave) * CGFloat(dt) * 60 * M
            if bubbles[i].y < surfAt(bubbles[i].x, t, wave, M) {
                bubbles[i].n.removeFromParent(); bubbles.remove(at: i); continue
            }
            bubbles[i].n.position = CGPoint(x: bubbles[i].x, y: H - bubbles[i].y)
        }

        let p = CGMutablePath()
        var x: CGFloat = 0
        p.move(to: CGPoint(x: 0, y: H - surfAt(0, t, wave, M)))
        while x <= W { p.addLine(to: CGPoint(x: x, y: H - surfAt(x, t, wave, M))); x += 12 }
        p.addLine(to: CGPoint(x: W, y: H - surfAt(W, t, wave, M)))   // reach the right edge exactly
        surface.path = p
    }

    private func respawn(_ b: inout GodBeam) {
        b.x = .random(in: 0..<1) * W
        let maxSpeed = 0.01 * W                  // random drift, capped at the old sweep speed
        b.vx = .random(in: -maxSpeed..<maxSpeed)
        b.life = .random(in: 4..<11)             // random duration
        b.peak = .random(in: 0.03..<0.055)       // lower alpha than before
        b.age = 0
        b.node.size = CGSize(width: .random(in: 130..<210), height: H - waterY)   // wider, random width
    }

    /// Baked white dot (soft radial) or ring (stroked circle), tinted per-node.
    private static func makeDot(ring: Bool) -> SKTexture {
        let s = 32, cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return SKTexture() }
        let c = CGFloat(s) / 2
        if ring {
            ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(3)
            ctx.strokeEllipse(in: CGRect(x: 4, y: 4, width: CGFloat(s) - 8, height: CGFloat(s) - 8))
        } else if let g = CGGradient(colorsSpace: cs, colors: [NSColor(white: 1, alpha: 1).cgColor,
                                                               NSColor(white: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: c, y: c), startRadius: 0, endCenter: CGPoint(x: c, y: c), endRadius: c, options: [])
        }
        return ctx.makeImage().map { SKTexture(cgImage: $0) } ?? SKTexture()
    }

    private static func makeBeam() -> SKTexture {
        let w = 96, h = 128, cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return SKTexture() }
        let band = CGMutablePath()   // slanted shaft: narrow at top (waterline), drifting right & fading down
        band.move(to: CGPoint(x: 22, y: h)); band.addLine(to: CGPoint(x: 46, y: h))
        band.addLine(to: CGPoint(x: 78, y: 0)); band.addLine(to: CGPoint(x: 54, y: 0)); band.closeSubpath()
        ctx.addPath(band); ctx.clip()
        if let g = CGGradient(colorsSpace: cs, colors: [NSColor(white: 1, alpha: 1).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: w / 2, y: h), end: CGPoint(x: w / 2, y: 0), options: [])   // bright at the surface
        }
        return ctx.makeImage().map { SKTexture(cgImage: $0) } ?? SKTexture()
    }
}
