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
    var detail = "complex"   // resolved body-detail level for this kind ("simple" | "complex")
}

/// One fish in a school: offset from the shoal anchor, boids velocity, and per-member draw traits.
struct SchoolMember {
    var dx: Double, dy: Double        // offset from the shoal anchor
    var vx = 0.0, vy = 0.0            // boids velocity (shoal-relative)
    var pref: Double                  // spacing personality (0.8–1.3)
    var face = 1.0                    // facing ±1
    var size = 1.0                    // draw-radius multiplier (real process RSS)
    var phase = 0.0                   // tail-wiggle phase offset — independent per member
    var wig = 0.0                     // current wiggle phase (recomputed each frame from phase + size-based rate)
    var wax = 0.0, way = 0.0          // wander drift acceleration, held for ~wanderHold seconds
    var wt = 0.0                      // time left before repicking the wander drift
}

/// Mutable per-creature state (reference type — mutated in place across passes, like the JS object).
final class Creature {
    let name: String
    var mem: Int
    var count: Int
    var sizes: [Int]            // real RSS (MiB) per process, for sizing individual school members
    var cpus: [Double]          // cpu% per process (aligned with sizes), for per-member tail-beat rate
    var k: Kind
    let frac: Double            // resting vertical position within [band.lo, band.hi]
    var r = 0.0, rT: Double     // eased radius / target
    var cpu = 0.0, cpuT: Double
    var cpuSlow = 0.0           // slowly-integrated CPU — drives swim speed (momentum), vs `cpu` for wiggle
    let person: Double          // per-creature speed personality
    var dir: Double             // -1 / +1 heading
    var dirLock = 0.0           // crabs: min time before `dir` may flip again (stops rapid jitter when boxed in)
    var t: Double               // local animation clock
    let bob: Double             // bob phase
    var x: Double
    var swimY = 0.0, avoidY = 0.0
    var rDraw = 0.0, turn = 1.0, turnY = 1.0, alpha = 1.0
    var act = 0.0               // cpu activity 0..1
    var wig = 0.0
    var boost = 0.0             // transient crab scoot
    var spy = false             // currently performing a spyhop
    var spyT = 0.0              // elapsed time within the current spyhop
    var spyRot = 0.0            // canvas-convention tilt (rad, ≤0 = nose-up); OceanScene maps to zRotation
    var spyWig = 0.0            // fluke-beat phase during a spyhop (driven by climb speed, not CPU)
    var spyLiftPrev = 0.0       // previous frame's lift, to derive the vertical velocity
    var labelOffX = 0.0, labelOffY = 0.0, labelHW = 0.0
    var cx = 0.0, cy = 0.0, topRel = 0.0        // school: members' centroid offset + top of the shoal (rel. to swimY)
    var labelAX = 0.0, labelAY = 0.0            // base label position (before labelOff); schools track the shoal, not the anchor
    var labelName = ""
    var arrive: Double          // 0..1 arrival progress
    var state: String           // entering | in | leaving
    var lastSeen: TimeInterval
    var off: [SchoolMember]  // school members (empty for solo creatures)

    // Give each school member its real size: multiplier = radius(its RSS) / group-reference radius (rT),
    // mirrors spyhop.html fishSizes(). No sizes (old server) -> keep the random schoolOffs fallback.
    func applyFishSizes(_ radius: (Double, Double?) -> Double) {
        guard k.shape == .school, !sizes.isEmpty else { return }
        let ref = rT > 0 ? rT : 1
        for i in off.indices { off[i].size = radius(Double(sizes[i % sizes.count]), k.mul) / ref }
    }

    init(item: RosterEntry, kind: Kind, present: Bool, now: TimeInterval,
         radius: (Double, Double?) -> Double, schoolOffs: (Int) -> [SchoolMember]) {
        name = item.name; mem = item.memMiB; count = item.count; sizes = item.sizes; cpus = item.cpus; k = kind
        let per = kind.shape == .school ? Double(item.memMiB) / Double(max(1, item.count)) : Double(item.memMiB)
        let members = kind.shape == .school ? min(Const.maxShoal, max(2, item.count)) : 1
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
        off = schoolOffs(members)
        applyFishSizes(radius)
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
    static let easeCpuSlow = 0.012   // ~3s time constant: swim speed integrates recent CPU (accelerates), vs easeCpu for wiggle
    // speed
    static let speedFloor = 8.0, speedCeil = 95.0, cpuRef = 90.0
    static let maxShoal = 128   // max fish drawn per school (matches server SCHOOL_MAX); safety ceiling, not a tight cap
    // edge
    static let edgeZone = 90.0, edgeBoost = 2.4
    // wiggle
    static let wiggleBase = 4.0, wiggleCpu = 7.0
    static let wiggleSizeRef = 24.0, wiggleSizeMin = 0.4   // bigger creatures beat fins slower
    // bob
    static let bobFish = 16.0, bobSchool = 14.0, bobCpuBoost = 0.7, jellyDrift = 12.0, jellyRate = 0.35, jellySlow = 0.22   // jellyRate: bell/tentacle pulse rate; jellySlow: the (much slower, decoupled) vertical drift
    static let whaleFlipperK = 70.0   // flipper phase rate = whaleFlipperK * (1 + act) / rDraw — big whales flap lazily (~4s/beat near max size), small ones twitch faster
    // radius
    static let radBase = 3.0, memK = 0.85, radMax = 58.0, schoolFish = 0.9   // radBase = smallest-fish radius (halved from 6)
    // shoal (boids tuning for school members) — sepK/neighK scale with each member's actual drawn size
    static let shoalSepK = 0.7, shoalSepForce = 650.0   // sep spacing scales with each PAIR's real drawn size (small fish stay close)
    static let shoalAlign = 0.55, shoalCohesion = 0.5, shoalWall = 8.0, shoalWallDamp = 3.0, shoalMaxSpd = 46.0, shoalMinSpd = 8.0   // no anchor; wall = spring+damper keeping the fish body under the wave trough / above the bed without bouncing
    static let shoalWander = 6.0, shoalWanderHold = 2.0   // wander = a drift each fish holds for ~wanderHold s (a meander, not per-frame noise)
    // avoid — gentle VERTICAL-only personal space (swimmers drift apart in depth to pass, never
    // shoved horizontally). Wide range (gap), cubic ramp so force builds slowly from ~0 at the
    // edge, and a low ceiling (avoidPush small). Diverges from the web's bidirectional push+slide.
    static let avoidGap = 1.7, avoidPush = 10.0
    static let crabNearGap = 1.7   // crabs are floor-pinned (no Y), so they still scoot on X
    // crab
    static let crabNear = 1.7, crabBoost = 2.8, crabDecay = 0.9, crabCrawl = 1.0, crabDirLock = 0.6
    // label
    static let labelPush = 0.45, labelCrabPush = 1.0, charW = 6.4, labelDecay = 0.82
    static let tempWindowMs = 15000.0
    static let waterLevelF = 0.30, bedFrac = 0.90, wxMax = 1.6
    // spyhop: one whale periodically rises to breach the surface (honours the app's name)
    static let spyFirst = 5.0, spyPeriod = 180.0, spyRetry = 20.0, spyDur = 7.5
    static let spyPeak = 0.4, spyTilt = 0.85, spySlow = 0.82   // peak at 40% → rise ~3s, slower fall ~4.5s, no hold
    static let spyRiseWig = 28.0, spyFallWig = 12.0   // fluke-beat gains: beat ∝ vertical speed, gentler descending
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
@inline(__always) func smoothstep(_ t: Double) -> Double { t * t * (3 - 2 * t) }
/// Jelly propulsion stroke over one bell cycle: quick contraction (~35%) that jets it up, then a slow
/// relaxation while it drifts back down — real jellyfish only power the up-stroke.
func jellyPulse(_ u: Double) -> Double {
    let f = u - floor(u)
    return f < 0.35 ? smoothstep(f / 0.35) : 1 - smoothstep((f - 0.35) / 0.65)
}
/// Spyhop vertical profile 0→1→0: a smooth raised-cosine hump peaking at `spyPeak` (rise faster,
/// fall slower). No flat top — it eases into the peak, kisses the surface still moving, then eases
/// back down. Velocity is zero only for the instant of the turnaround.
func spyLift(_ u: Double) -> Double {
    if u <= 0 || u >= 1 { return 0 }
    let p = Const.spyPeak
    return u < p ? 0.5 - 0.5 * cos(.pi * u / p)
                 : 0.5 + 0.5 * cos(.pi * (u - p) / (1 - p))
}
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
    var wiggleMode = "high"   // "high" (animated) | "none" (rigid — bakes 1 pose instead of 16)
    var windTiers = 0, windLength = 44
    var windA0 = 0.0, windA1 = 1.0
    var isBench = false
    var benchDayNight = false   // --daynight: cycle temp so the full sun↔moon transition is visible
    var showLabels = true
    var maxCreatures: Int? = nil   // client-side cap on the roster (nil = render all the server sends)
    var creatureDetailDefault = "complex"   // from render.creatureDetail (native detail is look-only)

    private(set) var order: [Creature] = []
    private var byName: [String: Creature] = [:]
    private var kinds: [Kind] = []
    private var lastRoster: [RosterEntry] = []   // most recent server roster, for re-capping on a menu change
    private var firstLoad = true
    private var tempHist: [(t: TimeInterval, v: Double)] = []

    var clock = 0.0
    private var nextSpyhop = Const.spyFirst   // sim-clock time the next whale spyhop is due

    // MARK: config -> kinds

    func setConfig(_ cfg: Config) {
        wiggleMode = cfg.render.wiggleMode
        windTiers = cfg.render.windTiers; windLength = cfg.render.windLength
        windA0 = cfg.render.windAlphaMin; windA1 = cfg.render.windAlphaMax
        creatureDetailDefault = cfg.render.creatureDetail
        kinds = cfg.creatures.compactMap { specToKind($0) }
        // Re-map any creatures that spawned before config arrived (fish fallback → real kind).
        for c in order {
            let k = kindOf(c.name)
            c.k = k
            let per = k.shape == .school ? Double(c.mem) / Double(max(1, c.count)) : Double(c.mem)
            c.rT = radius(per, k.mul)
        }
    }

    /// The creature's own `detail` if set, else the server's global default.
    private func resolvedDetail(_ spec: String?) -> String {
        if spec == "simple" || spec == "complex" { return spec! }
        return creatureDetailDefault
    }

    private func specToKind(_ c: CreatureConfig) -> Kind? {
        guard let re = try? NSRegularExpression(pattern: c.match, options: [.caseInsensitive]) else { return nil }
        let shape = Shape(rawValue: c.shape) ?? .fish
        let band: (Double, Double) = c.band.count >= 2 ? (c.band[0], c.band[1]) : (0.40, 0.78)
        return Kind(re: re, shape: shape, hue: c.hue, sat: c.sat, lit: c.lit, spd: c.spd,
                    band: band, mul: c.mul, always: c.always, detail: resolvedDetail(c.detail))
    }

    private func kindOf(_ name: String) -> Kind {
        let s = name.lowercased()
        for k in kinds {
            let range = NSRange(s.startIndex..., in: s)
            if let re = k.re, re.firstMatch(in: s, range: range) != nil { return k }
        }
        let h = hashHue(s)
        return Kind(re: nil, shape: .fish, hue: (h + 180).truncatingRemainder(dividingBy: 360),
                    sat: 42, lit: 58, spd: 0.5 + Double(Int(h) % 30) / 60, band: (0.40, 0.78),
                    mul: nil, always: nil, detail: resolvedDetail(nil))
    }

    private func radius(_ mib: Double, _ mul: Double?) -> Double {
        min(Const.radMax, (Const.radBase + sqrt(max(1, mib)) * Const.memK) * (mul ?? 1))
    }

    // size is a random fallback multiplier; applyFishSizes() overwrites it with the real per-process
    // size when the server provides one (RosterEntry.sizes). phase desyncs the tail wiggle per member.
    private func schoolOffs(_ n: Int) -> [SchoolMember] {
        (0..<n).map { _ in SchoolMember(dx: (Double.random(in: 0..<1) - 0.5) * 60,
                                        dy: (Double.random(in: 0..<1) - 0.5) * 40,
                                        pref: 0.8 + Double.random(in: 0..<1) * 0.5,
                                        size: 0.55 + Double.random(in: 0..<1) * 0.9,
                                        phase: Double.random(in: 0..<1) * .pi * 2) }
    }

    // Distance-weighted centroid of a school (robust to a straggler) — mirrors spyhop.html labelCentroid.
    // Members far from the group are down-weighted, so the label tracks the bulk not a lone wanderer.
    // Two reweight passes; topRel = top of the core (well-weighted) members so the label clears the group.
    private func labelCentroid(_ c: Creature, _ rf: Double) {
        let n = Double(c.off.count), s2 = (rf * 4) * (rf * 4)   // weight falls off ~4 fish-radii out
        var cx = 0.0, cy = 0.0
        for m in c.off { cx += m.dx; cy += m.dy }
        cx /= n; cy /= n
        var top = Double.greatestFiniteMagnitude
        for it in 0..<2 {
            var wx = 0.0, wy = 0.0, ws = 0.0; top = Double.greatestFiniteMagnitude
            for m in c.off {
                let ex = m.dx - cx, ey = m.dy - cy, w = 1 / (1 + (ex * ex + ey * ey) / s2)
                wx += w * m.dx; wy += w * m.dy; ws += w
                if it == 1 && w > 0.25 { let t = m.dy - rf * m.size; if t < top { top = t } }
            }
            cx = wx / ws; cy = wy / ws
        }
        c.cx = cx; c.cy = cy; c.topRel = top < Double.greatestFiniteMagnitude ? top : cy - rf
    }

    /// Boids: separation + alignment + cohesion, plus a gentle pull back toward the group's own
    /// anchor point (so the shoal doesn't drift away from its label/position). O(n²) over the
    /// school's own members only (n ≤ 8), never against other creatures — trivial per frame.
    /// sep/neigh scale with the member's actual on-screen radius (bigger fish keep more distance)
    /// and each member's own `pref` personality, so the spacing isn't a uniform crystal-grid.
    // drift = the whole shoal's horizontal velocity (c.dir*spd*M). A member's on-screen motion is
    // drift + its shoal-relative vx, so facing must key off that sum — otherwise a fish nudged toward
    // the back of a forward-drifting shoal faces backward while actually moving forward.
    private func updateBoids(_ off: inout [SchoolMember], dt: Double, memberR: Double, drift: Double, swimY: Double) {
        let n = off.count
        for i in 0..<n {
            let ri = memberR * off[i].size
            off[i].wt -= dt
            if off[i].wt <= 0 {   // hold a random drift ~wanderHold s, then repick — a slow meander per fish, not per-frame noise
                off[i].wax = (Double.random(in: 0..<1) - 0.5) * Const.shoalWander
                off[i].way = (Double.random(in: 0..<1) - 0.5) * Const.shoalWander
                off[i].wt = Const.shoalWanderHold * (0.7 + Double.random(in: 0..<1) * 0.6)
            }
            var sepX = 0.0, sepY = 0.0, alX = 0.0, alY = 0.0, cohX = 0.0, cohY = 0.0, near = 0
            for j in 0..<n where j != i {
                let dx = off[i].dx - off[j].dx, dy = off[i].dy - off[j].dy
                let d = max(0.001, (dx * dx + dy * dy).squareRoot())
                let sep = (ri + memberR * off[j].size) * Const.shoalSepK * off[i].pref   // spacing = the two fish's real radii -> tiny fish crowd close, big fish keep room
                if d < sep { let f = (sep - d) / sep; sepX += (dx / d) * f; sepY += (dy / d) * f }
                alX += off[j].vx; alY += off[j].vy; cohX += off[j].dx; cohY += off[j].dy; near += 1   // infinite sensing radius: every member is a neighbour for align + cohesion
            }
            var ax = sepX * Const.shoalSepForce + off[i].wax
            var ay = sepY * Const.shoalSepForce + off[i].way
            if near > 0 {
                let nf = Double(near)
                ax += (alX / nf - off[i].vx) * Const.shoalAlign + (cohX / nf - off[i].dx) * Const.shoalCohesion
                ay += (alY / nf - off[i].vy) * Const.shoalAlign + (cohY / nf - off[i].dy) * Const.shoalCohesion
            }
            let my = swimY + off[i].dy, half = ri * 0.6   // half = fish body's vertical half-height; measure the body top/bottom, not the centre
            let surfY = waterY + 1.4 * env.waveAmp        // surface = wave trough (deepest the surface dips)
            let topGap = (my - half) - surfY, hr = ri * 1.5   // hr = headroom where the surface wall kicks in (raised so fish are held a bit further below the surface)
            if topGap < hr { ay += (hr - topGap) * Const.shoalWall - off[i].vy * Const.shoalWallDamp } else { let botGap = bedY - (my + half); if botGap < ri { ay -= (ri - botGap) * Const.shoalWall + off[i].vy * Const.shoalWallDamp } }
            off[i].vx += ax * dt; off[i].vy += ay * dt
            let spd = max(0.001, (off[i].vx * off[i].vx + off[i].vy * off[i].vy).squareRoot())
            let cl = clampD(spd, Const.shoalMinSpd, Const.shoalMaxSpd)
            off[i].vx = off[i].vx / spd * cl; off[i].vy = off[i].vy / spd * cl
            let avx = drift + off[i].vx; if abs(avx) > 4 { off[i].face = avx > 0 ? 1 : -1 }   // face the absolute direction of travel (drift + relative) — a fish drifting backward turns to face that way; hysteresis stops flicker near zero
            off[i].dx += off[i].vx * dt; off[i].dy += off[i].vy * dt
        }
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

    /// Re-apply the current cap to the live scene right away (e.g. the "Max creatures" menu changed),
    /// instead of waiting for the next state poll.
    func applyCap(now: TimeInterval) { if !lastRoster.isEmpty { reconcile(lastRoster, now: now) } }

    private func reconcile(_ list: [RosterEntry], now: TimeInterval) {
        lastRoster = list
        // Client-side cap: the server sends its roster largest/pinned-first, so keep the prefix.
        let kept = maxCreatures.map { Array(list.prefix($0)) } ?? list
        // Creatures pushed out by the cap (still in the roster, just past the cut) leave at once —
        // don't route them through the 60s keepAlive path, which is there to ride out a process that
        // momentarily drops from a poll. Genuinely-vanished processes keep that grace. Raising the
        // cap re-admits an over-cap creature below (its "leaving" flips back to "entering").
        if maxCreatures != nil {
            let keepNames = Set(kept.map { $0.name })
            let inRoster = Set(list.map { $0.name })
            for c in order where c.state != "leaving" && inRoster.contains(c.name) && !keepNames.contains(c.name) {
                c.state = "leaving"
            }
        }
        for item in kept {
            if let c = byName[item.name] {
                c.mem = item.memMiB; c.count = item.count; c.sizes = item.sizes; c.cpus = item.cpus; c.cpuT = item.cpu; c.lastSeen = now
                let per = c.k.shape == .school ? Double(item.memMiB) / Double(max(1, item.count)) : Double(item.memMiB)
                c.rT = radius(per, c.k.mul)
                if c.state == "leaving" { c.state = "entering" }
                if c.k.shape == .school {
                    let w = min(Const.maxShoal, max(2, item.count))
                    while c.off.count < w { c.off.append(schoolOffs(1)[0]) }
                    if c.off.count > w { c.off.removeLast(c.off.count - w) }
                    c.applyFishSizes(radius)
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

    /// Pick one present whale (not already spyhopping) to start a spyhop, and set the next due time.
    /// Retries sooner if there's no whale available, rather than skipping the whole period.
    private func triggerSpyhop() {
        let whales = order.filter { $0.k.shape == .whale && $0.state == "in" && !$0.spy }
        guard !whales.isEmpty else { nextSpyhop = clock + Const.spyRetry; return }
        let c = whales[min(whales.count - 1, Int(Double.random(in: 0..<1) * Double(whales.count)))]
        c.spy = true; c.spyT = 0; c.spyWig = c.wig; c.spyLiftPrev = 0   // continue the fluke phase from where it was
        nextSpyhop = clock + Const.spyPeriod
    }

    func step(dt: Double, now: TimeInterval) {
        clock += dt
        if clock >= nextSpyhop { triggerSpyhop() }
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
            c.cpu += (c.cpuT - c.cpu) * Const.easeCpu             // fast — momentary effort (wiggle)
            c.cpuSlow += (c.cpuT - c.cpuSlow) * Const.easeCpuSlow // slow — recent-seconds average (speed)
            let arrE = easeOut(c.arrive)
            c.act = clampD(c.cpu / Const.cpuRef, 0, 1)
            let actSlow = clampD(c.cpuSlow / Const.cpuRef, 0, 1)
            c.rDraw = c.r * lerpD(Const.farScale, 1, arrE)
            c.turn = lerpD(Const.farTurn, 1, arrE)
            c.turnY = lerpD(Const.farYscale, 1, arrE)
            c.alpha = lerpD(Const.farAlpha, 1, arrE)
            let sizeSlow = clampD(Const.wiggleSizeRef / c.rDraw, Const.wiggleSizeMin, 1)   // big creatures beat fins slower
            let wigRate: Double
            switch c.k.shape {
            case .jelly: wigRate = (2 * .pi * Const.jellyRate + c.act * Const.wiggleCpu) * sizeSlow          // momentary activity → faster tentacle pulse
            case .whale: wigRate = Const.whaleFlipperK * (1 + c.act) / max(c.rDraw, 1)                       // uncapped size scaling: big whales flap lazily
            default: wigRate = (Const.wiggleBase + c.k.spd * 4 + c.act * Const.wiggleCpu) * sizeSlow
            }
            c.wig = wiggleMode != "none" ? c.t * wigRate : 0
            c.boost *= Const.crabDecay
            c.dirLock -= dt
            var lift = 0.0                                        // 0 = swimming normally; 0→1→0 over a spyhop
            if c.spy {
                c.spyT += dt
                let u = c.spyT / Const.spyDur
                if u >= 1 { c.spy = false; c.spyT = 0; c.spyRot = 0 }
                else {
                    lift = spyLift(u); c.spyRot = -Double.pi / 2 * Const.spyTilt * lift
                    // Wiggle driven by the climb, not CPU: fast up (∝ rise speed), pause at the peak, slow down.
                    let spyVel = (lift - c.spyLiftPrev) / max(dt, 1e-4); c.spyLiftPrev = lift
                    let spyWigRate = (spyVel > 0 ? Const.spyRiseWig : Const.spyFallWig) * abs(spyVel)
                    if wiggleMode != "none" { c.spyWig += spyWigRate * sizeSlow * dt; c.wig = c.spyWig }
                }
            }
            let edgeB = 1 + Const.edgeBoost * clampD(1 - min(abs(c.x), abs(W - c.x)) / Const.edgeZone, 0, 1)
            var base = (Const.speedFloor + (Const.speedCeil - Const.speedFloor) * actSlow) * c.k.spd   // accelerate toward the CPU-set ceiling over seconds
            if c.k.shape == .crab { base = max(base, Const.crabCrawl) }
            let spd = base * c.person * arrE * edgeB * (1 + c.boost) * (1 - Const.spySlow * lift)   // near-stationary while spyhopping
            c.t += dt
            c.x += c.dir * spd * dt * M
            if c.k.shape == .school {
                // Schools wrap per-member at render time (see OceanScene.syncSchool), so members can
                // straddle the edge — half on each side. Keep the anchor on a clean [0,W) torus so its
                // own wrap is an exact-W jump the render modulo absorbs seamlessly (no whole-school pop).
                if c.x >= W { c.x -= W } else if c.x < 0 { c.x += W }
            } else {
                let marg = c.rDraw + 8
                if c.x > W + marg { c.x = -marg } else if c.x < -marg { c.x = W + marg }
            }
            let baseY = waterY + c.frac * (bedY - waterY)
            switch c.k.shape {
            case .jelly: c.swimY = baseY + sin(c.t * Const.jellySlow + c.bob) * Const.jellyDrift * M   // slow, smooth drift — decoupled from the (activity-driven) tentacle pulse
            case .crab: c.swimY = bedY + 22 - c.rDraw * 0.7   // bottom edge sits at the seafloor trough (bedY + 22)
            default:
                let amp = (c.k.shape == .school ? Const.bobSchool : Const.bobFish) * M * (1 + c.act * Const.bobCpuBoost)
                c.swimY = baseY + sin(c.t * 0.7 + c.bob) * amp
            }
            if c.k.shape == .school {
                let rf = c.rDraw * Const.schoolFish, wb0 = Const.wiggleBase + c.k.spd * 4
                updateBoids(&c.off, dt: dt, memberR: rf, drift: c.dir * spd * M, swimY: c.swimY)
                for i in c.off.indices {   // independent tail beat: own phase + own size-based rate + own process CPU (busy procs flick faster)
                    let mAct = c.cpus.isEmpty ? c.act : clampD(c.cpus[i % c.cpus.count] / Const.cpuRef, 0, 1)
                    let mr = clampD(Const.wiggleSizeRef / max(rf * c.off[i].size, 1), Const.wiggleSizeMin, 1)
                    c.off[i].wig = wiggleMode != "none" ? c.t * (wb0 + mAct * Const.wiggleCpu) * mr + c.off[i].phase : 0
                }
                labelCentroid(c, rf)   // distance-weighted centroid (label ignores a wandered-off straggler)
            }
            if lift > 0 { c.swimY += (waterY - c.rDraw * 0.12 - c.swimY) * lift }   // ease up from the normal bob toward a surface breach and back
            c.avoidY *= Const.avoidDecay
            c.labelOffX *= Const.labelDecay
            c.labelOffY *= Const.labelDecay
            c.labelName = c.k.shape == .school ? "\(c.name) ×\(c.count)" : c.name
            c.labelHW = Double(c.labelName.count) * Const.charW / 2
            if c.k.shape == .school {   // label follows the members' centroid, above the topmost fish (wrapped like the fish)
                var lx = (c.x + c.cx).truncatingRemainder(dividingBy: W); if lx < 0 { lx += W }
                c.labelAX = lx; c.labelAY = c.swimY + c.avoidY + c.topRel - 8
            } else {
                c.labelAX = c.x; c.labelAY = c.swimY + c.avoidY - c.rDraw - 8
            }
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
                        big.boost = Const.crabBoost
                        if big.dirLock <= 0 { big.dir = big.x >= small.x ? 1 : -1; big.dirLock = Const.crabDirLock }   // commit, don't jitter
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
                    let ax = a.labelAX + a.labelOffX, ay = a.labelAY + a.labelOffY
                    let bx = b.labelAX + b.labelOffX, by = b.labelAY + b.labelOffY
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
