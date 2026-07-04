import Foundation

// Faithful port of the per-frame simulation in spyhop.html (`frame()` passes 1/2/2b and
// `applyState`). Pure logic in y-DOWN pixel space (like the canvas); OceanScene reads the
// creatures each frame and writes SpriteKit nodes (y-flip + CGFloat happen there).

enum Shape: String { case angler, whale, jelly, squid, ray, fish, school, crab }

struct Kind {
    var re: NSRegularExpression?
    var shape: Shape
    var hue: Double
    var sat: Double
    var lit: Double
    var spd: Double
    var band: (lo: Double, hi: Double)
    var mul: Double?
    var always: Bool?
}

/// Mutable per-creature state (reference type — mutated in place across passes, like the JS object).
final class Creature {
    let name: String
    var mem: Int
    var count: Int
    var k: Kind
    let frac: Double            // resting vertical position within [band.lo, band.hi]
    var r = 0.0, rT: Double     // eased radius / target
    var cpu = 0.0, cpuT: Double
    let person: Double          // per-creature speed personality
    var dir: Double             // -1 / +1 heading
    var t: Double               // local animation clock
    let bob: Double             // bob phase
    var x: Double
    var swimY = 0.0, avoidY = 0.0
    var rDraw = 0.0, turn = 1.0, turnY = 1.0, alpha = 1.0
    var act = 0.0               // cpu activity 0..1
    var wig = 0.0
    var boost = 0.0             // transient crab scoot
    var labelOffX = 0.0, labelOffY = 0.0, labelHW = 0.0
    var labelName = ""
    var arrive: Double          // 0..1 arrival progress
    var state: String           // entering | in | leaving
    var lastSeen: TimeInterval
    var off: [(dx: Double, dy: Double, ph: Double)]  // school member offsets

    init(item: RosterEntry, kind: Kind, present: Bool, now: TimeInterval,
         radius: (Double, Double?) -> Double, schoolOffs: (Int) -> [(Double, Double, Double)]) {
        name = item.name; mem = item.memMiB; count = item.count; k = kind
        let per = kind.shape == .school ? Double(item.memMiB) / Double(max(1, item.count)) : Double(item.memMiB)
        let members = kind.shape == .school ? min(8, max(2, item.count)) : 1
        frac = kind.band.lo + Double.random(in: 0..<1) * (kind.band.hi - kind.band.lo)
        rT = radius(per, kind.mul)
        cpuT = item.cpu
        person = 0.85 + Double.random(in: 0..<1) * 0.3
        dir = Double.random(in: 0..<1) < 0.5 ? -1 : 1
        t = Double.random(in: 0..<1) * 100
        bob = Double.random(in: 0..<1) * .pi * 2
        x = Double.random(in: 0..<1) * 1920   // reset to real width on first step via geometry
        arrive = present ? 1 : 0
        state = present ? "in" : "entering"
        lastSeen = now
        off = schoolOffs(members).map { ($0.0, $0.1, $0.2) }
        if present { r = rT }
    }
}

/// Env (weather) — mirrors spyhop.html `env`.
struct Env {
    var wi = 0.0
    var cloudCount = Const.cloudBase
    var cloudSize = Const.sizeBase
    var wind = Const.windBase
    var waveAmp = Const.waveBase
    var stormA = 0.0, stormAT = 0.0
    var rockCount = Double(Const.diskBase)
    var tempDisp = 0.0, sunH = 0.0, sunH1 = 0.0
}

/// CFG + PAL constants transcribed from spyhop.html.
enum Const {
    static let pollMs = 4000.0, keepAliveMs = 60000.0
    static let arriveSec = 1.5, leaveSec = 5.1
    // far (receding) factors
    static let farScale = 0.12, farTurn = 0.18, farYscale = 0.28, farAlpha = 0.12
    // eases
    static let easeR = 0.06, easeCpu = 0.05, easeStorm = 0.12, avoidDecay = 0.86, easeTemp = 0.05
    // speed
    static let speedFloor = 8.0, speedCeil = 95.0, cpuRef = 90.0
    // edge
    static let edgeZone = 90.0, edgeBoost = 2.4
    // wiggle
    static let wiggleBase = 4.0, wiggleCpu = 7.0
    // bob
    static let bobFish = 16.0, bobSchool = 14.0, bobCpuBoost = 0.7, jellyDrift = 40.0
    // radius
    static let radBase = 6.0, memK = 0.85, radMax = 58.0, schoolFish = 0.9
    // avoid — gentle VERTICAL-only personal space (swimmers drift apart in depth to pass, never
    // shoved horizontally). Wide range (gap), cubic ramp so force builds slowly from ~0 at the
    // edge, and a low ceiling (avoidPush small). Diverges from the web's bidirectional push+slide.
    static let avoidGap = 1.7, avoidPush = 10.0
    static let crabNearGap = 1.7   // crabs are floor-pinned (no Y), so they still scoot on X
    // crab
    static let crabNear = 1.7, crabBoost = 2.8, crabDecay = 0.9, crabCrawl = 1.0
    // label
    static let labelPush = 0.45, labelCrabPush = 1.0, charW = 6.4, labelDecay = 0.82
    static let tempWindowMs = 15000.0
    static let waterLevelF = 0.30, bedFrac = 0.90, wxMax = 1.6
    // weather
    static let weatherFloor = 0.18
    static let cloudBase = 3.0, cloudGain = 12.0, poolMax = 22.0, cloudFade = 0.03
    static let sizeBase = 1.0, sizeGain = 1.2
    static let windBase = 4.0, windGain = 95.0
    static let waveBase = 1.2, waveGain = 16.0
    static let whitecapWi = 0.45
    static let boltFloor = 90.0
    static let diskKnee = 80.0, diskBase = 2.0, diskMax = 68.0, diskExp = 1.8
    static let tempLo = 50.0, tempHi = 92.0, dayLo = 66.0, dayHi = 90.0
    static let sunTau = 1.8
    static let shapes: Set<String> = ["angler", "whale", "jelly", "squid", "ray", "fish", "school", "crab"]
}

@inline(__always) func clampD(_ v: Double, _ a: Double, _ b: Double) -> Double { v < a ? a : (v > b ? b : v) }
@inline(__always) func lerpD(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
@inline(__always) func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
func hashHue(_ s: String) -> Double {
    var h = 0
    for ch in s.unicodeScalars { h = (h * 31 + Int(ch.value)) % 360 }
    return Double(h)
}

/// The simulation engine: owns creatures + env, advances one frame, ingests telemetry.
final class Sim {
    // geometry (set on resize, y-down pixel space)
    var W = 1920.0, H = 1080.0, waterY = 324.0, bedY = 972.0
    var motionScale = 1.0      // M — 0.2 under reduce-motion

    // running telemetry (S) + derived
    var cpu = 0.0, load = 0.0, load5 = 0.0, load15 = 0.0, cores = 4.0
    var memPct = 0.0, swapPct = 0.0, temp = 0.0, tempMean = 0.0, disk = 0.0
    var alarms = 0, containers = 0
    var alerts: [Alert] = []
    var host = "", uptime = "—"
    var lastStateTime: TimeInterval = 0   // for the HUD connection status
    var env = Env()

    // config
    var wiggle = true
    var windTiers = 0, windLength = 44
    var windA0 = 0.0, windA1 = 1.0
    var isBench = false
    var benchDayNight = false   // --daynight: cycle temp so the full sun↔moon transition is visible
    var showLabels = true

    private(set) var order: [Creature] = []
    private var byName: [String: Creature] = [:]
    private var kinds: [Kind] = []
    private var firstLoad = true
    private var tempHist: [(t: TimeInterval, v: Double)] = []

    var clock = 0.0

    // MARK: config -> kinds

    func setConfig(_ cfg: Config) {
        wiggle = cfg.render.wiggle
        windTiers = cfg.render.windTiers; windLength = cfg.render.windLength
        windA0 = cfg.render.windAlphaMin; windA1 = cfg.render.windAlphaMax
        kinds = cfg.creatures.compactMap { specToKind($0) }
        // Re-map any creatures that spawned before config arrived (fish fallback → real kind).
        for c in order {
            let k = kindOf(c.name)
            c.k = k
            let per = k.shape == .school ? Double(c.mem) / Double(max(1, c.count)) : Double(c.mem)
            c.rT = radius(per, k.mul)
        }
    }

    private func specToKind(_ c: CreatureConfig) -> Kind? {
        guard let re = try? NSRegularExpression(pattern: c.match, options: [.caseInsensitive]) else { return nil }
        let shape = Shape(rawValue: c.shape) ?? .fish
        let band: (Double, Double) = c.band.count >= 2 ? (c.band[0], c.band[1]) : (0.40, 0.78)
        return Kind(re: re, shape: shape, hue: c.hue, sat: c.sat, lit: c.lit, spd: c.spd,
                    band: band, mul: c.mul, always: c.always)
    }

    private func kindOf(_ name: String) -> Kind {
        let s = name.lowercased()
        for k in kinds {
            let range = NSRange(s.startIndex..., in: s)
            if let re = k.re, re.firstMatch(in: s, range: range) != nil { return k }
        }
        let h = hashHue(s)
        return Kind(re: nil, shape: .fish, hue: (h + 180).truncatingRemainder(dividingBy: 360),
                    sat: 42, lit: 58, spd: 0.5 + Double(Int(h) % 30) / 60, band: (0.40, 0.78), mul: nil, always: nil)
    }

    private func radius(_ mib: Double, _ mul: Double?) -> Double {
        min(Const.radMax, (Const.radBase + sqrt(max(1, mib)) * Const.memK) * (mul ?? 1))
    }

    private func schoolOffs(_ n: Int) -> [(Double, Double, Double)] {
        (0..<n).map { _ in ((Double.random(in: 0..<1) - 0.5) * 60,
                            (Double.random(in: 0..<1) - 0.5) * 40,
                            Double.random(in: 0..<1) * .pi * 2) }
    }

    // MARK: telemetry ingest (applyState)

    func applyState(_ d: State, now: TimeInterval) {
        cpu = d.cpu; load = d.load; load5 = d.load5; load15 = d.load15; cores = Double(d.cores)
        memPct = d.memPct; swapPct = d.swapPct; temp = d.temp; disk = d.disk
        alarms = d.alarms; containers = d.containers; alerts = d.alerts; host = d.host; uptime = d.uptime
        lastStateTime = now

        tempHist.append((now, d.temp))
        while let first = tempHist.first, now - first.t > Const.tempWindowMs / 1000 { tempHist.removeFirst() }
        tempMean = tempHist.isEmpty ? d.temp : tempHist.reduce(0) { $0 + $1.v } / Double(tempHist.count)

        let wx = clampD(load5 / max(1, cores), 0, Const.wxMax)
        let wi = clampD((wx - Const.weatherFloor) / (Const.wxMax - Const.weatherFloor), 0, 1)
        env.wi = wi
        env.cloudCount = (Const.cloudBase + wi * Const.cloudGain).rounded()
        env.cloudSize = Const.sizeBase + wi * Const.sizeGain
        env.wind = Const.windBase + wi * Const.windGain
        env.waveAmp = Const.waveBase + wi * Const.waveGain
        env.rockCount = Const.diskBase + (pow(clampD((disk - Const.diskKnee) / (100 - Const.diskKnee), 0, 1), Const.diskExp)
                                          * (Const.diskMax - Const.diskBase)).rounded()
        env.stormAT = alarms > 0 ? 1 : 0

        reconcile(d.roster, now: now)
    }

    private func reconcile(_ list: [RosterEntry], now: TimeInterval) {
        for item in list {
            if let c = byName[item.name] {
                c.mem = item.memMiB; c.count = item.count; c.cpuT = item.cpu; c.lastSeen = now
                let per = c.k.shape == .school ? Double(item.memMiB) / Double(max(1, item.count)) : Double(item.memMiB)
                c.rT = radius(per, c.k.mul)
                if c.state == "leaving" { c.state = "entering" }
                if c.k.shape == .school {
                    let w = min(8, max(2, item.count))
                    while c.off.count < w { c.off.append(schoolOffs(1)[0]) }
                    if c.off.count > w { c.off.removeLast(c.off.count - w) }
                }
            } else {
                let c = Creature(item: item, kind: kindOf(item.name), present: firstLoad, now: now,
                                 radius: radius, schoolOffs: schoolOffs)
                c.x = Double.random(in: 0..<1) * W
                byName[item.name] = c
                order.append(c)
            }
        }
        firstLoad = false
    }

    // MARK: per-frame advance (pass 1 + 2 + 2b). Drawing is OceanScene's job (pass 3).

    func step(dt: Double, now: TimeInterval) {
        clock += dt
        let M = motionScale
        env.stormA += (env.stormAT - env.stormA) * Const.easeStorm

        // dynamic bench workload: sun/moon cycle, disk ramp 0→100→0, alerts toggling every 2s
        if isBench {
            let period = 40.0, ph = clock.truncatingRemainder(dividingBy: period)
            let tv: Double
            if ph < 4 { tv = 30 + 62 * (ph / 4) }                   // fast sunrise
            else if ph < 15 { tv = 92 }                             // day: sun held high
            else if ph < 19 { tv = 92 - 27 * ((ph - 15) / 4) }      // sunset → warm (92→65)
            else if ph < 31 { tv = 65 }                             // warm night, sun fully down (65 < dayLo 66): red seabed thermal glow
            else if ph < 35 { tv = 65 - 35 * ((ph - 31) / 4) }      // cool down (65→30)
            else { tv = 30 }                                        // cold night
            temp = tv; tempMean = tv
            disk = 50 - 50 * cos(clock * 0.12)
            env.rockCount = Const.diskBase + (pow(clampD((disk - Const.diskKnee) / (100 - Const.diskKnee), 0, 1), Const.diskExp) * (Const.diskMax - Const.diskBase)).rounded()
            let warnOn = Int(clock / 2) % 2 == 0
            alarms = warnOn ? 2 : 0
            alerts = warnOn ? [Alert(name: "disk_space", status: "CRITICAL", value: disk, units: "%"),
                               Alert(name: "cpu_pressure", status: "WARNING", value: 88, units: "%")] : []
            env.stormAT = warnOn ? 1 : 0
        }
        // day/night: thermal display + two-stage low-pass sun height (temp → sunH, 0=night 1=day)
        let tSrc = tempMean != 0 ? tempMean : temp
        env.tempDisp += (tSrc - env.tempDisp) * Const.easeTemp
        let dfRaw = clampD((env.tempDisp - Const.dayLo) / (Const.dayHi - Const.dayLo), 0, 1)
        let aSun = 1 - exp(-dt / Const.sunTau)
        env.sunH1 += (dfRaw - env.sunH1) * aSun
        env.sunH += (env.sunH1 - env.sunH) * aSun

        // pass 1 — advance
        var dead: [String] = []
        for c in order {
            if !isBench && c.state != "leaving" && now - c.lastSeen > Const.keepAliveMs / 1000 { c.state = "leaving" }
            if c.state == "entering" {
                c.arrive += dt / Const.arriveSec
                if c.arrive >= 1 { c.arrive = 1; c.state = "in" }
            } else if c.state == "leaving" {
                c.arrive -= dt / Const.leaveSec
                if c.arrive <= 0 { dead.append(c.name); continue }
            }
            c.r += (c.rT - c.r) * Const.easeR
            c.cpu += (c.cpuT - c.cpu) * Const.easeCpu
            let arrE = easeOut(c.arrive)
            c.act = clampD(c.cpu / Const.cpuRef, 0, 1)
            c.rDraw = c.r * lerpD(Const.farScale, 1, arrE)
            c.turn = lerpD(Const.farTurn, 1, arrE)
            c.turnY = lerpD(Const.farYscale, 1, arrE)
            c.alpha = lerpD(Const.farAlpha, 1, arrE)
            c.wig = wiggle ? c.t * (Const.wiggleBase + c.k.spd * 4 + c.act * Const.wiggleCpu) : 0
            c.boost *= Const.crabDecay
            let edgeB = 1 + Const.edgeBoost * clampD(1 - min(abs(c.x), abs(W - c.x)) / Const.edgeZone, 0, 1)
            var base = (Const.speedFloor + (Const.speedCeil - Const.speedFloor) * c.act) * c.k.spd
            if c.k.shape == .crab { base = max(base, Const.crabCrawl) }
            let spd = base * c.person * arrE * edgeB * (1 + c.boost)
            c.t += dt
            c.x += c.dir * spd * dt * M
            let marg = c.rDraw + 8
            if c.x > W + marg { c.x = -marg } else if c.x < -marg { c.x = W + marg }
            let baseY = waterY + c.frac * (bedY - waterY)
            switch c.k.shape {
            case .jelly: c.swimY = baseY + sin(c.t * 0.5) * Const.jellyDrift * M
            case .crab: c.swimY = bedY - c.rDraw * 0.35
            default:
                let amp = (c.k.shape == .school ? Const.bobSchool : Const.bobFish) * M * (1 + c.act * Const.bobCpuBoost)
                c.swimY = baseY + sin(c.t * 0.7 + c.bob) * amp
            }
            c.avoidY *= Const.avoidDecay
            c.labelOffX *= Const.labelDecay
            c.labelOffY *= Const.labelDecay
            c.labelName = c.k.shape == .school ? "\(c.name) ×\(c.count)" : c.name
            c.labelHW = Double(c.labelName.count) * Const.charW / 2
        }
        for name in dead { remove(name) }

        // pass 2 — gentle VERTICAL-only avoidance: swimmers ease apart in depth to pass, never
        // shoved horizontally. Quadratic ramp from ~0 at the (wide) detection edge, low ceiling.
        // Crabs are floor-pinned (Y fixed), so a crab pair still scoots apart on X instead.
        let arr = order
        for i in 0..<arr.count {
            for j in (i + 1)..<arr.count {
                let a = arr[i], b = arr[j]
                let ay = a.swimY + a.avoidY, by = b.swimY + b.avoidY
                let dx = b.x - a.x, dy = by - ay
                let d = (dx * dx + dy * dy).squareRoot()
                let mn = (a.rDraw + b.rDraw) * Const.avoidGap
                if d >= mn || d <= 0.01 { continue }
                if a.k.shape == .crab && b.k.shape == .crab {
                    if d < mn * Const.crabNearGap {
                        let big = a.rDraw >= b.rDraw ? a : b, small = big === a ? b : a
                        big.boost = Const.crabBoost; big.dir = big.x >= small.x ? 1 : -1
                    }
                    continue
                }
                let t = (mn - d) / mn                       // 0..1 proximity
                let f = Const.avoidPush * t * t * dt         // quadratic ramp · low ceiling · Y only
                let sign: Double = dy != 0 ? (dy > 0 ? 1 : -1) : (a.x < b.x ? 1 : -1)
                if a.k.shape != .crab { a.avoidY -= sign * f }
                if b.k.shape != .crab { b.avoidY += sign * f }
            }
        }

        // pass 2b — label repulsion
        if showLabels {
            for i in 0..<arr.count {
                for j in (i + 1)..<arr.count {
                    let a = arr[i], b = arr[j]
                    let ax = a.x + a.labelOffX, ay = a.swimY + a.avoidY - a.rDraw + a.labelOffY
                    let bx = b.x + b.labelOffX, by = b.swimY + b.avoidY - b.rDraw + b.labelOffY
                    let ox = (a.labelHW + b.labelHW + 6) - abs(bx - ax)
                    let oy = 15 - abs(by - ay)
                    if ox > 0 && oy > 0 {
                        let f = (a.k.shape == .crab || b.k.shape == .crab) ? Const.labelCrabPush : Const.labelPush
                        if ox < oy * 3 {
                            let s = (bx - ax == 0 ? (Double.random(in: 0..<1) - 0.5) : (bx - ax)).sign01 * ox * 0.5 * f
                            a.labelOffX -= s; b.labelOffX += s
                        } else {
                            let s = (by - ay == 0 ? 1 : (by - ay)).sign01 * oy * 0.5 * f
                            a.labelOffY -= s; b.labelOffY += s
                        }
                    }
                }
            }
        }
    }

    private func remove(_ name: String) {
        byName[name] = nil
        if let idx = order.firstIndex(where: { $0.name == name }) { order.remove(at: idx) }
    }
}

private extension Double {
    var sign01: Double { self > 0 ? 1 : (self < 0 ? -1 : 0) }
}
