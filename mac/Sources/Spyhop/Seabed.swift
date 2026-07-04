import SpriteKit

/// Seabed floor: static silhouette + depth gradient, rocks revealed by disk usage (rockCount),
/// and weed blades that sway each frame. Ported from drawBed()/drawRock() in spyhop.html.
/// All geometry is converted from the sim's y-DOWN pixel space to SpriteKit's y-UP here.
@MainActor
final class Seabed {
    let node = SKNode()

    private struct LichenPatch { let blobs: [(x: CGFloat, y: CGFloat, r: CGFloat)]; let hue: CGFloat }
    private struct RockSpec { let x: CGFloat; let s: CGFloat; let o: CGFloat; let tone: CGFloat; let design: Int
        var lichen: [LichenPatch] = [] }   // patches baked into the rock texture, one per day of uptime
    private struct WeedSpec { let x: CGFloat; let h: CGFloat; let ph: CGFloat; let hue: CGFloat }
    private var rocksSpec: [RockSpec]
    private let weedsSpec: [WeedSpec]

    private var rockNodes: [SKSpriteNode] = []
    private var lichenTotal = 0   // patches placed so far (tracks days of uptime)
    private var weedNodes: [SKSpriteNode] = []
    private static let bladeTex = Seabed.makeBlade()
    private var silhouette: SKShapeNode?
    private var gradient: SKSpriteNode?
    private var W: CGFloat = 0, H: CGFloat = 0, bedY: CGFloat = 0

    init() {
        // x kept < 0.85 to leave the bottom-right corner clear for a desktop icon; tone brightened so rocks read solid
        rocksSpec = (0..<72).map { _ in
            RockSpec(x: .random(in: 0..<0.85), s: 9 + CGFloat(pow(Double.random(in: 0..<1), 4.5)) * 69,   // long tail: mostly small, larger ones increasingly rare, up to ~2× former
                     o: (.random(in: 0..<1) - 0.5) * 6, tone: 34 + .random(in: 0..<20), design: .random(in: 0..<4))
        }
        weedsSpec = (0..<34).map { i in
            WeedSpec(x: (CGFloat(i) + 0.5) / 34 + (.random(in: 0..<1) - 0.5) * 0.02,
                     h: 0.05 + .random(in: 0..<0.11), ph: .random(in: 0..<(.pi * 2)), hue: 150 + .random(in: 0..<50))
        }.filter { $0.x < 0.85 }
        node.zPosition = -5   // above the water backdrop, below creatures
    }

    /// The sim-space floor line (y-down) at a given x, matching drawBed's silhouette.
    private func bedLineDown(_ x: CGFloat) -> CGFloat { bedY + sin(x * 0.03) * 8 }

    func build(size: CGSize, bedY: CGFloat) {
        self.W = size.width; self.H = size.height; self.bedY = bedY
        node.removeAllChildren(); rockNodes = []; weedNodes = []

        // depth gradient (transparent up top → bedLow at the bottom)
        let gTop = H - CGFloat(bedY - 40)                      // sim bedY-40 → y-up
        let grad = SKSpriteNode(texture: verticalGradient([rgb(Pal.bedLow, 0), rgb(Pal.bedLow)],
                                                          size: CGSize(width: W, height: max(1, gTop))))
        grad.anchorPoint = CGPoint(x: 0.5, y: 0); grad.position = CGPoint(x: W / 2, y: 0); grad.zPosition = 0
        node.addChild(grad); gradient = grad

        // silhouette (bedFill), y-up
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        var x: CGFloat = 0
        while x <= W { path.addLine(to: CGPoint(x: x, y: H - (bedLineDown(x) + 14))); x += 24 }
        path.addLine(to: CGPoint(x: W, y: 0)); path.closeSubpath()
        let sil = SKShapeNode(path: path)
        sil.fillColor = rgb(Pal.bedFill); sil.lineWidth = 0; sil.zPosition = 1
        node.addChild(sil); silhouette = sil

        // rocks: baked opaque textures (lichen baked in). Visibility set per frame by rockCount.
        for rk in rocksSpec {
            let rx = rk.x * W
            let yDown = bedLineDown(rx) + 12 + rk.o
            let n = SKSpriteNode(texture: bakeRock(rk)); n.size = rockTexSize(rk)
            n.position = CGPoint(x: rx, y: H - yDown + rk.s * 0.35)   // body centre, raised above the bed line
            n.zPosition = 4   // in front of the weed (3)
            node.addChild(n); rockNodes.append(n)
        }

        // weed blades: baked sprites that sway by rotating at the base (no per-frame path rebuild)
        for w in weedsSpec {
            let bx = w.x * W, baseDown = bedLineDown(bx) + 12
            let blade = SKSpriteNode(texture: Seabed.bladeTex)
            blade.anchorPoint = CGPoint(x: 0.5, y: 0)   // pivot at the base
            blade.size = CGSize(width: 5, height: w.h * H)
            blade.color = nsColor(hue: w.hue, sat: 45, lit: 42); blade.colorBlendFactor = 1; blade.alpha = 0.7
            blade.position = CGPoint(x: bx, y: H - baseDown); blade.zPosition = 3
            node.addChild(blade); weedNodes.append(blade)
        }
    }

    func update(clock: Double, wind: Double, rockCount: Double, uptimeDays: Int) {
        let rc = Int(rockCount)
        for (i, n) in rockNodes.enumerated() { n.isHidden = i >= rc }

        // one lichen patch per day of uptime, placed on a random rock and baked into its texture
        if uptimeDays > lichenTotal && !rocksSpec.isEmpty {
            let target = min(uptimeDays, 150)
            var changed = Set<Int>()
            while lichenTotal < target {
                let ri = Int.random(in: 0..<rocksSpec.count)
                let s = rocksSpec[ri].s
                let cx = CGFloat.random(in: -s * 0.55..<s * 0.55), cy = CGFloat.random(in: -s * 0.35..<s * 0.3)
                let blobs = (0..<4).map { _ in (x: cx + CGFloat.random(in: -s * 0.12..<s * 0.12),
                                                y: cy + CGFloat.random(in: -s * 0.12..<s * 0.12),
                                                r: s * CGFloat.random(in: 0.08..<0.16)) }
                rocksSpec[ri].lichen.append(LichenPatch(blobs: blobs, hue: .random(in: 80..<140)))
                changed.insert(ri); lichenTotal += 1
            }
            for ri in changed { rockNodes[ri].texture = bakeRock(rocksSpec[ri]) }
        }

        let t = CGFloat(clock), wnd = CGFloat(wind)
        for (i, blade) in weedNodes.enumerated() {
            blade.zRotation = sin(t * 1.2 + weedsSpec[i].ph + wnd * 0.003) * 0.12   // sway at the base
        }
    }

    private func rockTexSize(_ rk: RockSpec) -> CGSize { CGSize(width: rk.s * 2.9, height: rk.s * 2.0) }

    /// Fill one of four rock silhouettes (origin = centre, y-down context).
    private func rockBody(_ ctx: CGContext, _ s: CGFloat, _ design: Int) {
        switch design {
        case 0:   // round cobble
            ctx.fillEllipse(in: CGRect(x: -s, y: -s * 0.58, width: s * 2, height: s * 1.16))
        case 1:   // wide, flat stone
            ctx.fillEllipse(in: CGRect(x: -s * 1.25, y: -s * 0.42, width: s * 2.5, height: s * 0.84))
        case 2:   // angular boulder: straight edges with just the corners softened
            let v = [(-1.05, 0.12), (-0.62, -0.5), (0.28, -0.62), (1.02, -0.08), (0.72, 0.52), (-0.42, 0.58)]
                .map { CGPoint(x: $0.0 * s, y: $0.1 * s) }
            let n = v.count, f: CGFloat = 0.22, p = CGMutablePath()
            for i in 0..<n {
                let cur = v[i], prev = v[(i + n - 1) % n], next = v[(i + 1) % n]
                let a = CGPoint(x: cur.x + (prev.x - cur.x) * f, y: cur.y + (prev.y - cur.y) * f)
                let b = CGPoint(x: cur.x + (next.x - cur.x) * f, y: cur.y + (next.y - cur.y) * f)
                if i == 0 { p.move(to: a) } else { p.addLine(to: a) }
                p.addQuadCurve(to: b, control: cur)
            }
            p.closeSubpath(); ctx.addPath(p); ctx.fillPath()
        default:  // two-lobe boulder
            ctx.fillEllipse(in: CGRect(x: -s * 1.05, y: -s * 0.5, width: s * 1.7, height: s * 1.0))
            ctx.fillEllipse(in: CGRect(x: -s * 0.15, y: -s * 0.62, width: s * 1.35, height: s * 1.12))
        }
    }

    private func bakeRock(_ rk: RockSpec) -> SKTexture {
        let sz = rockTexSize(rk), scale: CGFloat = 2
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: Int(sz.width * scale), height: Int(sz.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return SKTexture() }
        ctx.scaleBy(x: scale, y: scale); ctx.translateBy(x: sz.width / 2, y: sz.height / 2); ctx.scaleBy(x: 1, y: -1)   // origin = body centre, y-down
        ctx.setFillColor(nsColor(hue: 195, sat: 10, lit: rk.tone).cgColor)
        rockBody(ctx, rk.s, rk.design)
        ctx.setFillColor(NSColor(srgbRed: 150/255, green: 175/255, blue: 175/255, alpha: 0.13).cgColor)
        ctx.fillEllipse(in: CGRect(x: -rk.s * 0.7, y: -rk.s * 0.4, width: rk.s * 0.8, height: rk.s * 0.4))   // upper-left sheen
        for patch in rk.lichen {
            ctx.setFillColor(nsColor(hue: Double(patch.hue), sat: 45, lit: 40, alpha: 0.8).cgColor)
            for b in patch.blobs { ctx.fillEllipse(in: CGRect(x: b.x - b.r, y: b.y - b.r, width: b.r * 2, height: b.r * 2)) }
        }
        return ctx.makeImage().map { SKTexture(cgImage: $0) } ?? SKTexture()
    }

    private static func makeBlade() -> SKTexture {
        let w = 8, h = 128, cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return SKTexture() }
        ctx.setFillColor(NSColor.white.cgColor)
        let p = CGMutablePath()                 // tapered blade, base (y=0) → tip (y=h)
        p.move(to: CGPoint(x: 2.5, y: 0)); p.addLine(to: CGPoint(x: 5.5, y: 0))
        p.addLine(to: CGPoint(x: 4.3, y: CGFloat(h))); p.addLine(to: CGPoint(x: 3.7, y: CGFloat(h))); p.closeSubpath()
        ctx.addPath(p); ctx.fillPath()
        return ctx.makeImage().map { SKTexture(cgImage: $0) } ?? SKTexture()
    }

    private func verticalGradient(_ colors: [NSColor], size: CGSize) -> SKTexture {
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return SKTexture() }
        if let g = CGGradient(colorsSpace: cs, colors: colors.map(\.cgColor) as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: h), end: .zero, options: [])  // colors[0] at top
        }
        guard let img = ctx.makeImage() else { return SKTexture() }
        return SKTexture(cgImage: img)
    }
}
