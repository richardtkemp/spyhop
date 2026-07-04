import SpriteKit

/// Alarm/pressure weather: lightning (swap→flash+bolt), and a storm cloud with rain + alert
/// text when there are active alarms. Ported from the lightning/storm blocks of drawSky().
/// Alert text is baked to a texture (stroke halo → readable on any sky) and rebuilt on change.
@MainActor
final class StormFX {
    let node = SKNode()

    // lightning
    private let flash = SKSpriteNode(color: NSColor(srgbRed: 226/255, green: 232/255, blue: 255/255, alpha: 1), size: .zero)
    private let flashCrop = SKCropNode()   // clips the flash to the sky (above the wavy water)
    private let flashMask = SKShapeNode()
    private let bolt = SKShapeNode()
    private var lightning = 0.0

    // storm cloud + rain + alerts
    private let cloudWarn: SKSpriteNode
    private let cloudCritNight: SKSpriteNode   // crimson crit cloud (night)
    private let cloudCritDay: SKSpriteNode     // light bluey-purple crit cloud (day) — crossfaded by sun height
    private struct Drop { let n: SKSpriteNode; var x: CGFloat; var y: CGFloat; let sp: CGFloat }
    private var drops: [Drop] = []
    private var alertNodes: [SKSpriteNode] = []
    private var lastAlertKey = ""
    private var stormFlash = 0.0

    private var W: CGFloat = 0, H: CGFloat = 0, waterY: CGFloat = 0
    var topInset: CGFloat = 0   // menu-bar strip (unused now the cloud anchors to the moon, which is already clear of it)
    private static let rainTex = StormFX.makeRain()

    /// Cloud centre (y-DOWN), anchored to the moon (W*0.82, H*0.12) and nudged so it covers most —
    /// but not all — of the moon.
    private var cloudCenter: CGPoint {
        let moonR = min(W, H) * 0.05
        return CGPoint(x: W * 0.82 - moonR * 0.9 - 110, y: H * 0.12 + moonR * 0.15)   // -110 ≈ half the cloud width
    }

    init() {
        node.zPosition = -7   // in front of clouds, behind the water/creatures
        cloudWarn = SKSpriteNode(texture: StormFX.makeStormCloud([74, 52, 104], [110, 80, 150]))
        cloudCritNight = SKSpriteNode(texture: StormFX.makeStormCloud([96, 42, 78], [132, 60, 100]))
        cloudCritDay = SKSpriteNode(texture: StormFX.makeStormCloud([70, 68, 112], [104, 106, 156]))   // moody, brooding storm blue-purple
        flash.anchorPoint = CGPoint(x: 0, y: 1); flash.blendMode = .alpha
        bolt.strokeColor = NSColor(srgbRed: 246/255, green: 249/255, blue: 255/255, alpha: 1)
        bolt.lineWidth = 2.2; bolt.lineJoin = .round; bolt.blendMode = .add
        for c in [cloudWarn, cloudCritNight, cloudCritDay] { c.zPosition = 1; node.addChild(c) }
        flashMask.fillColor = .white; flashMask.strokeColor = .clear
        flashCrop.maskNode = flashMask; flashCrop.addChild(flash)
        node.addChild(flashCrop); node.addChild(bolt)
    }

    func build(size: CGSize, waterY: CGFloat) {
        W = size.width; H = size.height; self.waterY = waterY
        flash.size = CGSize(width: W, height: waterY + 40)
        flash.position = CGPoint(x: 0, y: H)
        let c = cloudCenter
        for cl in [cloudWarn, cloudCritNight, cloudCritDay] { cl.position = CGPoint(x: c.x, y: H - c.y) }
        drops.forEach { $0.n.removeFromParent() }; drops = []
        for _ in 0..<26 {
            let d = SKSpriteNode(texture: StormFX.rainTex); d.size = CGSize(width: 3, height: 10)
            d.color = NSColor(srgbRed: 205/255, green: 196/255, blue: 240/255, alpha: 1); d.colorBlendFactor = 1
            d.zPosition = 2; node.addChild(d)
            drops.append(Drop(n: d, x: .random(in: 0..<1), y: .random(in: 0..<1), sp: .random(in: 0.5..<1.0)))
        }
    }

    func update(dt: Double, clock: Double, swapPct: Double, stormA: Double, alerts: [Alert], waveAmp: Double, sunH: Double, motionScale: Double) {
        // keep the flash's sky mask on the wavy surface, so the flash never lights the water
        let t = CGFloat(clock), M = CGFloat(motionScale), wave = CGFloat(waveAmp)
        let mp = CGMutablePath()
        mp.move(to: CGPoint(x: 0, y: H)); mp.addLine(to: CGPoint(x: W, y: H))
        var x = W; while x >= 0 { mp.addLine(to: CGPoint(x: x, y: H - surfAt(x, t, wave, M))); x -= 12 }
        mp.closeSubpath(); flashMask.path = mp

        updateLightning(swapPct: swapPct, motionScale: motionScale, waveAmp: waveAmp)
        updateStorm(dt: dt, alerts: alerts, stormA: stormA, sunH: sunH, motionScale: motionScale)
    }

    private func surfAt(_ x: CGFloat, _ t: CGFloat, _ waveAmp: CGFloat, _ M: CGFloat) -> CGFloat {
        waterY + sin(x * 0.02 + t * 1.4 * M) * waveAmp + sin(x * 0.05 - t * M) * waveAmp * 0.4
    }

    private func updateLightning(swapPct: Double, motionScale: Double, waveAmp: Double) {
        let swi = clampD((swapPct - 90) / 10, 0, 1)
        if swi > 0 && motionScale > 0.5 && Double.random(in: 0..<1) < 0.003 + swi * 0.035 {
            lightning = 1; regenBolt()
        }
        lightning *= 0.82
        let on = lightning > 0.02
        flash.isHidden = !on; bolt.isHidden = !on
        if on {
            flash.alpha = CGFloat(lightning * (0.3 + 0.55 * swi))
            bolt.alpha = CGFloat(lightning)
        }
    }

    private func regenBolt() {
        let n = 9
        var cx = W * (0.2 + CGFloat.random(in: 0..<0.6))
        let p = CGMutablePath()
        for i in 0...n {
            let y = H - waterY * CGFloat(i) / CGFloat(n)   // y-up: top → surface
            if i == 0 { p.move(to: CGPoint(x: cx, y: y)) } else { p.addLine(to: CGPoint(x: cx, y: y)) }
            cx += CGFloat.random(in: -23..<23)
        }
        bolt.path = p
    }

    private func updateStorm(dt: Double, alerts: [Alert], stormA: Double, sunH: Double, motionScale: Double) {
        let A = CGFloat(stormA)
        let crit = alerts.contains { $0.status == "CRITICAL" }
        let vis = A > 0.02
        cloudWarn.isHidden = crit || !vis
        cloudCritNight.isHidden = !crit || !vis
        cloudCritDay.isHidden = !crit || !vis
        cloudWarn.alpha = A
        let dayMix = CGFloat(clampD(sunH * 1.5, 0, 1))   // crossfade crimson → light bluey-purple by day
        cloudCritNight.alpha = A * (1 - dayMix)
        cloudCritDay.alpha = A * dayMix

        let visible = A > 0.02
        stormFlash *= 0.9
        if visible && motionScale > 0.5 && Double.random(in: 0..<1) < 0.004 { stormFlash = 1 }

        let c = cloudCenter, sx = c.x, syDown = c.y
        for i in drops.indices {
            drops[i].y += CGFloat(drops[i].sp) * 0.022 * CGFloat(max(0.2, motionScale))
            if drops[i].y > 1 { drops[i].y = 0 }
            let dx = sx + (drops[i].x - 0.5) * 150
            let dyDown = syDown + 24 + drops[i].y * (waterY - syDown - 14)
            drops[i].n.position = CGPoint(x: dx, y: H - dyDown)
            drops[i].n.alpha = visible ? 0.5 * A : 0
        }

        // alert text — rebuild only when the set changes
        let key = alerts.prefix(2).map { "\($0.name)|\($0.status)|\(Int($0.value))" }.joined(separator: ",") + (visible ? "1" : "0")
        if key != lastAlertKey {
            lastAlertKey = key
            alertNodes.forEach { $0.removeFromParent() }; alertNodes = []
            if visible {
                for (i, a) in alerts.prefix(2).enumerated() {
                    var nm = a.name.replacingOccurrences(of: "_", with: " ")
                    if nm.count > 26 { nm = String(nm.prefix(25)) + "…" }
                    let txt = "\(nm) · \(a.status.lowercased()) · \(Int(a.value))\(a.units)"
                    let (tex, sz) = StormFX.bakeText(txt)
                    let n = SKSpriteNode(texture: tex); n.size = sz; n.zPosition = 3
                    n.position = CGPoint(x: sx, y: H - (syDown - 6 + CGFloat(i) * 14))   // centred on the cloud
                    node.addChild(n); alertNodes.append(n)
                }
            }
        }
        alertNodes.forEach { $0.alpha = A }
    }

    // MARK: baked textures

    private static func makeStormCloud(_ base: [Int], _ inner: [Int]) -> SKTexture {
        let puffs: [(CGFloat, CGFloat, CGFloat, [Int])] =
            [(0, 0, 1, base), (0.6, 0.1, 0.8, inner), (-0.6, 0.12, 0.75, base), (0.25, -0.2, 0.7, inner), (-0.25, -0.15, 0.65, base)]
        let s: CGFloat = 1.25, scale: CGFloat = 2, w: CGFloat = 220, h: CGFloat = 120
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: Int(w * scale), height: Int(h * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return SKTexture() }
        ctx.scaleBy(x: scale, y: scale); ctx.translateBy(x: w / 2, y: h / 2)
        for (dx, dy, rr, c) in puffs {
            ctx.setFillColor(rgb(c).cgColor)
            let rx = 40 * s * rr, ry = 26 * s * rr
            ctx.fillEllipse(in: CGRect(x: dx * 46 * s - rx, y: -dy * 46 * s - ry, width: 2 * rx, height: 2 * ry))
        }
        return ctx.makeImage().map { SKTexture(cgImage: $0) } ?? SKTexture()
    }

    private static func makeRain() -> SKTexture {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: 6, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return SKTexture() }
        ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1.3)
        ctx.move(to: CGPoint(x: 4, y: 19)); ctx.addLine(to: CGPoint(x: 1, y: 1)); ctx.strokePath()
        return ctx.makeImage().map { SKTexture(cgImage: $0) } ?? SKTexture()
    }

    private static func bakeText(_ s: String) -> (SKTexture, CGSize) {
        let font = NSFont(name: "Menlo-Bold", size: 26) ?? .monospacedSystemFont(ofSize: 26, weight: .bold)
        let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.55); sh.shadowBlurRadius = 3
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .shadow: sh]   // white on the moody cloud
        let str = NSAttributedString(string: s, attributes: attrs)
        let sz = str.size()
        let pad: CGFloat = 10
        let img = NSImage(size: CGSize(width: sz.width + pad, height: sz.height + pad))
        img.lockFocus(); str.draw(at: CGPoint(x: pad / 2, y: pad / 2)); img.unlockFocus()
        return (SKTexture(image: img), CGSize(width: img.size.width / 2, height: img.size.height / 2))
    }
}
