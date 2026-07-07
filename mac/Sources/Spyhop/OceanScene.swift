import SpriteKit

/// One ocean per screen. Drives the Sim in `update()` and syncs SpriteKit nodes to it.
/// Stage A (minimal ocean): gradient sky/water + creatures as tinted bodies. Baked shapes,
/// day/night shaders, weather and particles land in later stages.
@MainActor
final class OceanScene: SKScene {
    let sim: Sim
    private let isMaster: Bool   // in mirror mode only one scene steps the shared sim; all render it
    var fpsOverride: Int?   // CLI --fps wins over config.render.fps (like URL params on the web)
    var off: Set<String> = []   // --off=streaks,clouds,… disable layers (profiling / parity with web)

    init(size: CGSize, sim: Sim, isMaster: Bool) {
        self.sim = sim; self.isMaster = isMaster
        super.init(size: size)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("use init(size:sim:isMaster:)") }

    private var lastTime: TimeInterval = 0
    private var nodes: [String: SKSpriteNode] = [:]
    private var nodeKey: [String: String] = [:]   // shape+wiggle-phase currently on each node
    private var schoolNodes: [String: [SKSpriteNode]] = [:]   // N member sprites per school
    private let creatureLayer = SKNode()
    private let seabed = Seabed()
    private let waterFX = WaterFX()
    private let celestial = Celestial()
    private let clouds = Clouds()
    private let wind = Wind()
    private let stormFX = StormFX()
    private var skyNode: SKSpriteNode?
    private let waterShape = SKShapeNode()   // wavy top edge that matches the drawn surface line
    private var waterTex: SKTexture?
    private let thermal = SKSpriteNode()     // warm underglow (temp-driven, night-only)
    private let dawn = SKSpriteNode()        // warm horizon wash when the sun is low
    private var labels: [String: SKLabelNode] = [:]
    private let labelLayer = SKNode()
    private let hudHost = SKLabelNode(fontNamed: "Menlo")
    private let hudConn = SKLabelNode(fontNamed: "Menlo")
    private let hudDot = SKShapeNode(circleOfRadius: 3.5)
    private let hudStats = SKLabelNode(fontNamed: "Menlo")
    private let hudLegend = SKLabelNode(fontNamed: "Menlo")
    private var hudStatsText = ""
    private var lastHost = ""
    var topInset: CGFloat = 0   // menu-bar height on the primary display; HUD sits below it
    private let refR = ShapeBaker.refR   // reference body radius the shape textures are baked at

    override func didMove(to view: SKView) {
        scaleMode = .resizeFill
        anchorPoint = CGPoint(x: 0, y: 0)   // sim is in pixel space; we y-flip explicitly
        backgroundColor = rgb(Pal.waterNight[2])
        creatureLayer.zPosition = 0
        addChild(celestial.node)
        addChild(wind.node)
        addChild(clouds.node)
        addChild(stormFX.node)
        addChild(seabed.node)
        thermal.anchorPoint = CGPoint(x: 0.5, y: 0); thermal.zPosition = -6; thermal.blendMode = .add
        addChild(thermal)
        dawn.anchorPoint = CGPoint(x: 0.5, y: 0); dawn.zPosition = -10.5; dawn.blendMode = .alpha; addChild(dawn)
        addChild(creatureLayer)
        labelLayer.zPosition = 6; addChild(labelLayer)
        for n in [hudHost, hudConn, hudStats, hudLegend] { n.zPosition = 20; addChild(n) }
        hudDot.zPosition = 20; hudDot.lineWidth = 0; addChild(hudDot)
        hudHost.horizontalAlignmentMode = .left; hudHost.verticalAlignmentMode = .top
        hudConn.fontSize = 11; hudConn.fontColor = NSColor(srgbRed: 214/255, green: 162/255, blue: 74/255, alpha: 1)   // only shown for bad states
        hudConn.horizontalAlignmentMode = .left; hudConn.verticalAlignmentMode = .center
        hudStats.horizontalAlignmentMode = .right; hudStats.verticalAlignmentMode = .top; hudStats.numberOfLines = 0
        hudLegend.horizontalAlignmentMode = .left; hudLegend.verticalAlignmentMode = .bottom; hudLegend.numberOfLines = 0
        hudLegend.attributedText = hudAttr("weather = 5-min load — clouds, wind & waves\nstorm = active alert · lightning = swap>90%\ncreatures = processes · size = mem · speed = cpu",
                                           NSColor(srgbRed: 160/255, green: 195/255, blue: 200/255, alpha: 1), 10.5, .left)
        waterFX.attach(to: self)
        updateGeometry()
    }

    override func didChangeSize(_ oldSize: CGSize) { updateGeometry() }

    private func updateGeometry() {
        guard size.width > 1 else { return }
        sim.W = Double(size.width); sim.H = Double(size.height)
        sim.waterY = sim.H * Const.waterLevelF
        sim.bedY = sim.H * Const.bedFrac
        buildBackground()
        seabed.build(size: size, bedY: CGFloat(sim.bedY))
        waterFX.build(size: size, waterY: CGFloat(sim.waterY))
        celestial.build(size: size, waterY: CGFloat(sim.waterY))
        clouds.build(size: size)
        wind.build(size: size, tierCount: 3)
        stormFX.topInset = topInset
        stormFX.build(size: size, waterY: CGFloat(sim.waterY))
        let warm = [NSColor(srgbRed: 1, green: 110/255, blue: 45/255, alpha: 0),
                    NSColor(srgbRed: 1, green: 110/255, blue: 45/255, alpha: 1)]
        thermal.texture = gradientTexture(warm, size: CGSize(width: size.width, height: size.height * 0.4))
        thermal.size = CGSize(width: size.width, height: size.height * 0.4)
        thermal.position = CGPoint(x: size.width / 2, y: 0)

        let dawnStops = [NSColor(srgbRed: 1, green: 150/255, blue: 90/255, alpha: 0),
                         NSColor(srgbRed: 1, green: 138/255, blue: 95/255, alpha: 1)]
        let dawnMargin: CGFloat = 60   // extend below the mean surface so wave troughs stay lit (matches the sky seam)
        let dawnH = size.height * 0.3 + dawnMargin
        dawn.texture = gradientTexture(dawnStops, size: CGSize(width: size.width, height: dawnH))
        dawn.size = CGSize(width: size.width, height: dawnH)
        dawn.position = CGPoint(x: size.width / 2, y: size.height - CGFloat(sim.waterY) - dawnMargin)
        let top = size.height - topInset
        hudHost.position = CGPoint(x: 22, y: top - 14)
        hudDot.position = CGPoint(x: 25.5, y: top - 44)
        hudConn.position = CGPoint(x: 38, y: top - 44)
        hudStats.position = CGPoint(x: size.width - 22, y: top - 14)
        hudLegend.position = CGPoint(x: 22, y: 18)
    }

    // MARK: background

    private var lastSunH = -1.0

    private func buildBackground() {
        let sunH = sim.env.sunH; lastSunH = sunH
        skyNode?.removeFromParent()
        let W = size.width, H = size.height
        let surfaceY = H - CGFloat(sim.waterY)   // y-up height of the mean water surface
        let margin: CGFloat = 60                 // cover the wave amplitude at the seam
        let waterStops = (0..<3).map { mixColor(Pal.waterNight[$0], Pal.waterDay[$0], sunH) }
        let skyStops = (0..<3).map { mixColor(Pal.skyNight[$0], Pal.skyDay[$0], sunH) }

        // water is a wavy-topped shape filled with the gradient (its top edge is rebuilt each frame)
        waterTex = gradientTexture(waterStops, size: CGSize(width: W, height: surfaceY + margin))
        waterShape.fillTexture = waterTex; waterShape.fillColor = .white; waterShape.strokeColor = .clear
        waterShape.zPosition = -9
        if waterShape.parent == nil { addChild(waterShape) }

        // sky extends DOWN past the mean surface so troughs reveal sky, not background
        let skyH = H - surfaceY + margin
        let sky = SKSpriteNode(texture: gradientTexture(skyStops, size: CGSize(width: W, height: skyH)))
        sky.size = CGSize(width: W, height: skyH)   // texture is a narrow strip; stretch it to full width
        sky.anchorPoint = CGPoint(x: 0.5, y: 0)
        sky.position = CGPoint(x: W / 2, y: surfaceY - margin)
        sky.zPosition = -11
        addChild(sky); skyNode = sky
    }

    /// Wavy surface height (y-up) at x — the same formula the surface line uses, so they align.
    private func surfLineY(_ x: CGFloat, _ t: CGFloat, _ waveAmp: CGFloat, _ M: CGFloat) -> CGFloat {
        CGFloat(sim.H) - (CGFloat(sim.waterY) + sin(x * 0.02 + t * 1.4 * M) * waveAmp + sin(x * 0.05 - t * M) * waveAmp * 0.4)
    }

    private func updateWaterTop() {
        let W = size.width, t = CGFloat(sim.clock), wave = CGFloat(sim.env.waveAmp), M = CGFloat(sim.motionScale)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: 0))
        var x: CGFloat = 0
        while x <= W { p.addLine(to: CGPoint(x: x, y: surfLineY(x, t, wave, M))); x += 12 }
        p.addLine(to: CGPoint(x: W, y: surfLineY(W, t, wave, M)))   // reach the right edge exactly (W may not be a multiple of 12)
        p.addLine(to: CGPoint(x: W, y: 0)); p.closeSubpath()
        waterShape.path = p
    }

    private func gradientTexture(_ colors: [NSColor], size: CGSize) -> SKTexture {
        // The gradient is purely vertical, so a narrow strip carries all the information — the node
        // stretches it to full width. Storing full width would be W× the bytes for no visible gain.
        let w = 8, h = max(1, Int(size.height))
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return SKTexture()
        }
        let cgColors = colors.map(\.cgColor) as CFArray
        let locs: [CGFloat] = colors.indices.map { CGFloat($0) / CGFloat(max(1, colors.count - 1)) }
        if let grad = CGGradient(colorsSpace: cs, colors: cgColors, locations: locs) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: h), end: .zero, options: [])  // colors[0] at top
        }
        guard let img = ctx.makeImage() else { return SKTexture() }
        return SKTexture(cgImage: img)
    }

    // MARK: telemetry passthrough (AppController forwards here)

    func setConfig(_ cfg: Config) {
        sim.setConfig(cfg)
        (view as? SKView)?.preferredFramesPerSecond = max(1, fpsOverride ?? cfg.render.fps)
    }
    func applyState(_ st: State) { sim.applyState(st, now: ProcessInfo.processInfo.systemUptime) }

    /// Drop the per-node texture keys so every creature re-requests its texture next frame
    /// (used after the atlas frame count changes and the bake cache was flushed).
    func invalidateTextures() { nodeKey.removeAll() }

    // MARK: frame

    override func update(_ currentTime: TimeInterval) {
        if lastTime == 0 { lastTime = currentTime }
        let dt = min(0.05, currentTime - lastTime); lastTime = currentTime
        if isMaster { sim.step(dt: dt, now: currentTime) }   // mirror: only the master advances the shared sim
        if abs(sim.env.sunH - lastSunH) > 0.01 { buildBackground() }   // day/night colour drift
        updateWaterTop()
        let ti = clampD((sim.env.tempDisp - Const.tempLo) / (Const.tempHi - Const.tempLo), 0, 1) * (1 - sim.env.sunH)
        thermal.alpha = CGFloat(0.85 * ti); thermal.isHidden = ti < 0.02
        let df = sim.env.sunH
        dawn.alpha = CGFloat(0.5 * (df > 0.02 ? clampD(1 - df * 2, 0, 1) : 0))
        updateHUD()
        syncCreatures()
        seabed.update(clock: sim.clock, wind: sim.env.wind, rockCount: sim.env.rockCount, uptimeDays: uptimeDays(sim.uptime))
        waterFX.update(dt: dt, clock: sim.clock, wind: sim.env.wind, waveAmp: sim.env.waveAmp, wi: sim.env.wi, motionScale: sim.motionScale, sunH: sim.env.sunH)
        celestial.update(sunH: sim.env.sunH, clock: sim.clock)
        if !off.contains("clouds") {
            clouds.update(sunH: sim.env.sunH, wind: sim.env.wind, cloudCount: sim.env.cloudCount,
                          cloudSize: sim.env.cloudSize, wi: sim.env.wi, motionScale: sim.motionScale)
        }
        if !off.contains("streaks") {
            wind.update(dt: dt, wi: sim.env.wi, wind: sim.env.wind, waterY: sim.waterY, motionScale: sim.motionScale,
                        trailLen: sim.windLength, a0: sim.windA0, a1max: sim.windA1)
        }
        stormFX.update(dt: dt, clock: sim.clock, swapPct: sim.swapPct, stormA: sim.env.stormA,
                       alerts: sim.alerts, waveAmp: sim.env.waveAmp, sunH: sim.env.sunH, motionScale: sim.motionScale)
    }

    private func syncCreatures() {
        var live = Set<String>()
        for c in sim.order {
            live.insert(c.name)
            if c.k.shape == .school {
                syncSchool(c)
            } else {
                let node = nodes[c.name] ?? makeNode(for: c)
                let phase = wigPhase(c)
                let bkt = ShapeBaker.sizeBucket(CGFloat(c.rT))   // bake sharpness follows the creature's target size
                let key = "\(c.k.shape.rawValue)\(phase)|\(c.k.detail)|\(Int(bkt))"
                if nodeKey[c.name] != key {   // shape, wiggle phase, or size bucket changed → swap the (cached) texture
                    node.texture = ShapeBaker.texture(c.k.shape, c.k, phase: phase, sizeR: CGFloat(c.rT), scale: view?.window?.backingScaleFactor ?? 2)
                    nodeKey[c.name] = key
                }
                let s = CGFloat(c.rDraw) / refR
                node.position = CGPoint(x: CGFloat(c.x), y: CGFloat(sim.H - (c.swimY + c.avoidY)))
                node.xScale = s * CGFloat(c.dir * c.turn)
                node.yScale = s * CGFloat(c.turnY)
                node.zRotation = CGFloat(-c.dir * c.spyRot)   // spyhop nose-up tilt (0 otherwise); sign maps canvas→SpriteKit
                node.zPosition = CGFloat(c.frac)              // stable paint order by resting depth — overlaps never swap
                node.alpha = CGFloat(c.alpha)
            }

            if sim.showLabels {
                let lbl = labels[c.name] ?? makeLabel(c.name)
                if lbl.text != c.labelName { lbl.text = c.labelName }
                lbl.position = CGPoint(x: CGFloat(c.x + c.labelOffX),
                                       y: CGFloat(sim.H - (c.swimY + c.avoidY - c.rDraw - 8 + c.labelOffY)))
                lbl.alpha = CGFloat(c.alpha)
            }
        }
        for (name, node) in nodes where !live.contains(name) { node.removeFromParent(); nodes[name] = nil; nodeKey[name] = nil }
        for (name, members) in schoolNodes where !live.contains(name) { members.forEach { $0.removeFromParent() }; schoolNodes[name] = nil }
        for (name, lbl) in labels where !live.contains(name) { lbl.removeFromParent(); labels[name] = nil }
    }

    private func syncSchool(_ c: Creature) {
        let maxSize = c.off.map { $0.size }.max() ?? 1   // one texture per school, baked sharp enough for its largest member
        let tex = ShapeBaker.texture(.fish, c.k, phase: wigPhase(c), sizeR: CGFloat(c.rT) * Const.schoolFish * CGFloat(maxSize), scale: view?.window?.backingScaleFactor ?? 2)
        // Two nodes per member: a primary and a wrap-around ghost. The ghost lets a member cross the
        // screen edge seamlessly — it appears on the far side exactly as the primary leaves this one —
        // so a school straddles the boundary (half on each side) instead of teleporting as one unit.
        var members = schoolNodes[c.name] ?? []
        let want = c.off.count * 2
        while members.count < want {
            let n = SKSpriteNode(); n.size = CGSize(width: ShapeBaker.nativeSize, height: ShapeBaker.nativeSize)
            creatureLayer.addChild(n); members.append(n)
        }
        while members.count > want { members.removeLast().removeFromParent() }
        schoolNodes[c.name] = members
        let s = CGFloat(c.rDraw * Const.schoolFish) / refR
        let W = CGFloat(sim.W), my0 = c.swimY + c.avoidY
        for (i, o) in c.off.enumerated() {
            let prim = members[2 * i], ghost = members[2 * i + 1]
            let ms = s * CGFloat(o.size)   // per-member size from its real process RSS
            let halfW = ms * ShapeBaker.nativeSize / 2
            var mx = CGFloat(c.x + o.dx).truncatingRemainder(dividingBy: W)   // wrap each fish's own x independently
            if mx < 0 { mx += W }
            let y = CGFloat(sim.H - (my0 + o.dy))
            for n in [prim, ghost] {
                n.texture = tex
                n.xScale = ms * CGFloat(o.face * c.turn); n.yScale = ms * CGFloat(c.turnY)
                n.alpha = CGFloat(c.alpha); n.zPosition = CGFloat(c.frac)
            }
            prim.position = CGPoint(x: mx, y: y)
            if mx - halfW < 0 { ghost.position = CGPoint(x: mx + W, y: y); ghost.isHidden = false }        // straddles left edge → mirror on the right
            else if mx + halfW > W { ghost.position = CGPoint(x: mx - W, y: y); ghost.isHidden = false }   // straddles right edge → mirror on the left
            else { ghost.isHidden = true }
        }
    }

    /// HUD text with a soft dark shadow so it reads over both night sky and bright daytime clouds.
    private func hudAttr(_ s: String, _ color: NSColor, _ size: CGFloat, _ align: NSTextAlignment) -> NSAttributedString {
        let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.85); sh.shadowBlurRadius = 3.5
        let para = NSMutableParagraphStyle(); para.alignment = align
        let font = NSFont(name: "Menlo", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .shadow: sh, .paragraphStyle: para])
    }

    private func uptimeDays(_ s: String) -> Int {
        for tok in s.split(separator: " ") where tok.hasSuffix("d") { return Int(tok.dropLast()) ?? 0 }
        return 0
    }

    private func wigPhase(_ c: Creature) -> Int {
        let tau = Double.pi * 2
        let w = (c.wig.truncatingRemainder(dividingBy: tau) + tau).truncatingRemainder(dividingBy: tau)
        return Int(w / tau * Double(ShapeBaker.phases)) % ShapeBaker.phases
    }

    private func updateHUD() {
        let hostStr = sim.host.isEmpty ? "spyhop" : sim.host
        if hostStr != lastHost {
            hudHost.attributedText = hudAttr(hostStr, NSColor(srgbRed: 191/255, green: 224/255, blue: 228/255, alpha: 1), 15, .left)
            lastHost = hostStr
        }
        let a = sim.alarms
        let txt = "up \(sim.uptime)\nload5 \(String(format: "%.1f", sim.load5))/\(Int(sim.cores))\n"
            + "load15 \(String(format: "%.1f", sim.load15))/\(Int(sim.cores))\n"
            + "cpu \(Int(sim.cpu))% · \(Int(sim.temp))°\nmem \(Int(sim.memPct))%\nswap \(Int(sim.swapPct))%\ndisk \(Int(sim.disk))%\n"
            + "\(sim.containers) containers\n\(a) alert\(a == 1 ? "" : "s")"
        if txt != hudStatsText {
            hudStats.attributedText = hudAttr(txt, NSColor(srgbRed: 178/255, green: 212/255, blue: 216/255, alpha: 1), 10.5, .right)
            hudStatsText = txt
        }

        let stale = NSColor(srgbRed: 214/255, green: 162/255, blue: 74/255, alpha: 1)
        let down = NSColor(srgbRed: 214/255, green: 90/255, blue: 90/255, alpha: 1)
        // only surface BAD connection states — nothing shown while live/bench
        if sim.isBench {
            hudDot.isHidden = true; hudConn.text = ""
        } else if sim.lastStateTime == 0 {
            hudDot.isHidden = false; hudDot.fillColor = down; hudConn.text = "connecting…"
        } else {
            let age = Int(ProcessInfo.processInfo.systemUptime - sim.lastStateTime)
            if age <= 8 { hudDot.isHidden = true; hudConn.text = "" }
            else if age <= 15 { hudDot.isHidden = false; hudDot.fillColor = stale; hudConn.text = "reconnecting… (\(age)s)" }
            else { hudDot.isHidden = false; hudDot.fillColor = down; hudConn.text = "no connection" }
        }
    }

    private func makeLabel(_ name: String) -> SKLabelNode {
        let l = SKLabelNode(fontNamed: "Menlo")
        l.fontSize = 10.5; l.fontColor = NSColor(srgbRed: 150/255, green: 195/255, blue: 195/255, alpha: 0.6)
        l.verticalAlignmentMode = .bottom; l.horizontalAlignmentMode = .center
        labelLayer.addChild(l); labels[name] = l; return l
    }

    private func makeNode(for c: Creature) -> SKSpriteNode {
        let scale = view?.window?.backingScaleFactor ?? 2
        let n = SKSpriteNode(texture: ShapeBaker.texture(c.k.shape, c.k, phase: 0, sizeR: CGFloat(c.rT), scale: scale))
        n.size = CGSize(width: ShapeBaker.nativeSize, height: ShapeBaker.nativeSize)  // body radius = refR
        creatureLayer.addChild(n)
        nodes[c.name] = n
        return n
    }
}
