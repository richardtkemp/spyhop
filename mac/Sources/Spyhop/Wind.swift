import SpriteKit

/// Wind streaks: 20 ribbons whose heads drift with the wind, wobble (load-scaled), and are
/// steered upward by a force field near the sea surface. Each trail is drawn as a few opacity/
/// width tiers (SKShapeNode has no per-vertex alpha), honoring the config wind knobs. Ported
/// from drawStreaks() in spyhop.html. Sits between the sky and water sprites (see OceanScene z).
@MainActor
final class Wind {
    let node = SKNode()

    private final class Streak {
        var hx: CGFloat, hy: CGFloat, th: CGFloat, phase: CGFloat
        let w1: CGFloat, w2: CGFloat, a1: CGFloat, a2: CGFloat, ph: CGFloat, ph2: CGFloat, sp: CGFloat
        var trail: [CGPoint] = []
        var tiers: [SKShapeNode] = []
        init(W: CGFloat, H: CGFloat) {
            hx = .random(in: 0..<1) * W; hy = (0.05 + .random(in: 0..<0.22)) * H; th = (.random(in: 0..<1) - 0.5) * 0.5
            phase = .random(in: 0..<100)
            w1 = 0.5 + .random(in: 0..<1); w2 = 1.0 + .random(in: 0..<1.5)
            a1 = 0.7 + .random(in: 0..<0.7); a2 = 0.4 + .random(in: 0..<0.5)
            ph = .random(in: 0..<(.pi * 2)); ph2 = .random(in: 0..<(.pi * 2)); sp = 0.7 + .random(in: 0..<0.6)
        }
    }

    private var streaks: [Streak] = []
    private var W: CGFloat = 0, H: CGFloat = 0
    private var T = 4

    init() { node.zPosition = -10 }

    func build(size: CGSize, tierCount: Int) {
        W = size.width; H = size.height; T = max(1, tierCount)
        node.removeAllChildren(); streaks = []
        for _ in 0..<14 {
            let s = Streak(W: W, H: H)
            for _ in 0..<T {
                let n = SKShapeNode(); n.lineCap = .round; n.lineJoin = .round; n.fillColor = .clear
                node.addChild(n); s.tiers.append(n)
            }
            streaks.append(s)
        }
    }

    private func windColor(_ a: CGFloat) -> NSColor { NSColor(srgbRed: 190/255, green: 205/255, blue: 225/255, alpha: a) }

    func update(dt: Double, wi: Double, wind: Double, waterY: Double, motionScale: Double,
                trailLen: Int, a0: Double, a1max: Double) {
        let swx = clampD(wi * 0.5, 0, 0.5)
        if swx <= 0.015 {   // calm: clear
            for s in streaks { s.trail.removeAll(keepingCapacity: true); s.tiers.forEach { $0.path = nil } }
            return
        }
        let M = motionScale
        let turb = 1.1 + wi * 5.5, spd = (24 + wind * 0.8) * M
        let FZONE = 50.0, LIFT = 5.0, DIP = 60.0
        let wY = waterY, Hd = Double(H), Wd = Double(W)

        for s in streaks {
            s.phase += CGFloat(dt)
            var omega = turb * (sin(Double(s.phase * s.w1) + Double(s.ph)) * Double(s.a1)
                              + sin(Double(s.phase * s.w2) - Double(s.ph2)) * Double(s.a2)) - 0.9 * sin(Double(s.th))
            let gap = wY - Double(s.hy)
            if gap < FZONE {
                let up = -(cos(Double(s.th)) == 0 ? 1 : sgn(cos(Double(s.th))))
                if sgn(omega) != up { omega = 0 }
                omega += up * (1 - gap / FZONE) * LIFT
            }
            s.th += CGFloat(omega * dt)
            s.hx += CGFloat(cos(Double(s.th)) * spd * Double(s.sp) * dt)
            s.hy += CGFloat(sin(Double(s.th)) * spd * Double(s.sp) * dt)
            s.hy = CGFloat(clampD(Double(s.hy), Hd * 0.015, wY + DIP))
            if Double(s.hx) > Wd + 40 || Double(s.hx) < -90 {
                s.hx = -30; s.hy = CGFloat((0.05 + Double.random(in: 0..<0.22)) * Hd)
                s.th = CGFloat((Double.random(in: 0..<1) - 0.5) * 0.5); s.trail.removeAll(keepingCapacity: true)
            }
            s.trail.append(CGPoint(x: s.hx, y: s.hy))
            if s.trail.count > trailLen { s.trail.removeFirst(s.trail.count - trailLen) }

            renderTiers(s, swx: swx, a0: a0, a1max: a1max)
        }
    }

    private func renderTiers(_ s: Streak, swx: Double, a0: Double, a1max: Double) {
        let n = s.trail.count
        guard n >= 2 else { s.tiers.forEach { $0.path = nil }; return }
        let paths = (0..<T).map { _ in CGMutablePath() }
        var started = [Bool](repeating: false, count: T)
        let yUp: (CGPoint) -> CGPoint = { CGPoint(x: $0.x, y: self.H - $0.y) }
        for i in 1..<n {
            let fi = Double(i) / Double(max(1, n - 1))
            let tier = min(T - 1, Int(fi * Double(T)))
            if !started[tier] { paths[tier].move(to: yUp(s.trail[i - 1])); started[tier] = true }
            paths[tier].addLine(to: yUp(s.trail[i]))
        }
        for k in 0..<T {
            let f = (Double(k) + 0.5) / Double(T)
            let node = s.tiers[k]
            node.path = started[k] ? paths[k] : nil
            node.strokeColor = windColor(CGFloat(swx * (a0 + (a1max - a0) * f)))
            node.lineWidth = 0.5 + CGFloat(f) * 1.5
        }
    }
}

@inline(__always) func sgn(_ v: Double) -> Double { v > 0 ? 1 : (v < 0 ? -1 : 0) }
