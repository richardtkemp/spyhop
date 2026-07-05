import Foundation

// Data contract shared with the web client — mirrors spyhop.py's /config.json and /state.json.
// The native app is just another client: fetch /config.json once, poll /state.json.

// MARK: - /config.json

struct CreatureConfig: Decodable {
    let match: String
    let shape: String
    let hue: Double
    let sat: Double
    let lit: Double
    let spd: Double
    let band: [Double]          // [lo, hi] vertical swim band as fractions of height
    let mul: Double?            // size multiplier (default 1)
    let always: Bool?           // server-side roster pin; client stores but never reads it
    let detail: String?         // "simple" | "complex" — overrides render.creatureDetail for this creature
}

/// The render block. Only `fps`, `wiggle`, and the `wind*` knobs are honored natively;
/// `dpr`/`spritePhases` are Canvas2D-specific and ignored (SpriteKit textures everything).
struct RenderConfig: Decodable {
    var fps: Int = 30
    var wiggleMode = "high"   // "none" | "low" | "high"; JSON key `wiggle` (accepts legacy bool)
    var windTiers: Int = 0
    var windLength: Int = 44
    var windAlphaMin: Double = 0
    var windAlphaMax: Double = 1
    var creatureDetail = "complex"   // global default body detail: "simple" | "complex"

    enum CodingKeys: String, CodingKey { case fps, wiggle, windTiers, windLength, windAlphaMin, windAlphaMax, creatureDetail }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent(Int.self, forKey: .fps) { fps = v }
        if let s = try? c.decode(String.self, forKey: .wiggle) {
            wiggleMode = s.lowercased() == "none" ? "none" : "high"
        } else if let b = try? c.decode(Bool.self, forKey: .wiggle) {
            wiggleMode = b ? "high" : "none"
        }
        if let v = try c.decodeIfPresent(Int.self, forKey: .windTiers) { windTiers = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .windLength) { windLength = v }
        if let v = try c.decodeIfPresent(Double.self, forKey: .windAlphaMin) { windAlphaMin = v }
        if let v = try c.decodeIfPresent(Double.self, forKey: .windAlphaMax) { windAlphaMax = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .creatureDetail) { creatureDetail = v == "simple" ? "simple" : "complex" }
    }
    init() {}
}

struct Config: Decodable {
    let creatures: [CreatureConfig]
    var render = RenderConfig()
    enum CodingKeys: String, CodingKey { case creatures, render }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        creatures = (try? c.decode([CreatureConfig].self, forKey: .creatures)) ?? []
        render = (try? c.decode(RenderConfig.self, forKey: .render)) ?? RenderConfig()
    }
}

// MARK: - /state.json

struct Alert: Decodable {
    let name: String, status: String, value: Double, units: String
    enum CodingKeys: String, CodingKey { case name = "n", status = "s", value = "v", units = "u" }
}

struct RosterEntry: Decodable {
    let name: String, memMiB: Int, count: Int, cpu: Double
    enum CodingKeys: String, CodingKey { case name = "n", memMiB = "m", count = "c", cpu }
}

struct State: Decodable {
    var host = "", uptime = ""
    var cpu = 0.0, load = 0.0, load5 = 0.0, load15 = 0.0
    var cores = 1, memPct = 0.0, swapPct = 0.0, temp = 0.0, disk = 0.0
    var alarms = 0, containers = 0
    var alerts: [Alert] = []
    var roster: [RosterEntry] = []

    enum CodingKeys: String, CodingKey {
        case host, uptime, cpu, load, load5, load15, cores, memPct, swapPct, temp, disk, alarms, containers, alerts, roster
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = (try? c.decode(String.self, forKey: .host)) ?? ""
        uptime = (try? c.decode(String.self, forKey: .uptime)) ?? ""
        cpu = (try? c.decode(Double.self, forKey: .cpu)) ?? 0
        load = (try? c.decode(Double.self, forKey: .load)) ?? 0
        load5 = (try? c.decode(Double.self, forKey: .load5)) ?? 0
        load15 = (try? c.decode(Double.self, forKey: .load15)) ?? 0
        cores = (try? c.decode(Int.self, forKey: .cores)) ?? 1
        memPct = (try? c.decode(Double.self, forKey: .memPct)) ?? 0
        swapPct = (try? c.decode(Double.self, forKey: .swapPct)) ?? 0
        temp = (try? c.decode(Double.self, forKey: .temp)) ?? 0
        disk = (try? c.decode(Double.self, forKey: .disk)) ?? 0
        alarms = (try? c.decode(Int.self, forKey: .alarms)) ?? 0
        containers = (try? c.decode(Int.self, forKey: .containers)) ?? 0
        alerts = (try? c.decode([Alert].self, forKey: .alerts)) ?? []
        roster = (try? c.decode([RosterEntry].self, forKey: .roster)) ?? []
    }
    init() {}
}

// MARK: - Client

/// Fetches /config.json once, then polls /state.json. One shared instance feeds every screen's
/// scene. Callbacks are delivered on the main queue.
@MainActor
final class Telemetry {
    let baseURL: URL
    var onConfig: ((Config) -> Void)?
    var onState: ((State) -> Void)?

    private let session = URLSession(configuration: .ephemeral)
    private var pollTimer: Timer?
    private var configLoaded = false
    private var pollInterval: TimeInterval = 4
    private var started = false   // live mode (start() called); false in bench
    private var active = true     // false while the wallpaper is fully occluded

    init(baseURL: URL) { self.baseURL = baseURL }

    func start(pollInterval: TimeInterval = 4) {
        // Try config (creature mapping) BEFORE the first state poll, then begin polling. The
        // very first LAN request can fail on a cold `open` launch, so keep retrying config each
        // poll until it lands; setConfig re-maps creatures that spawned as the fish fallback.
        self.pollInterval = pollInterval; started = true
        loadConfig { [weak self] in
            guard let self, self.active else { return }
            self.pollState()
            self.schedulePolling()
        }
    }

    private func schedulePolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.configLoaded { self.loadConfig() }
                self.pollState()
            }
        }
    }

    func stop() { pollTimer?.invalidate(); pollTimer = nil }

    /// Suspend polling while the wallpaper is fully occluded (nobody can see the telemetry anyway),
    /// and resume with an immediate refresh when it's exposed again. No-op in bench mode.
    func setActive(_ on: Bool) {
        guard started, on != active else { return }
        active = on
        if on { pollState(); schedulePolling() } else { stop() }
    }

    /// Config fetch. `done` fires on the main queue after the response (or failure).
    func loadConfig(_ done: (() -> Void)? = nil) {
        get("config.json") { [weak self] data in
            if let data, let cfg = try? JSONDecoder().decode(Config.self, from: data) {
                self?.configLoaded = true
                self?.onConfig?(cfg)
            }
            done?()
        }
    }

    private func pollState() {
        get("state.json") { [weak self] data in
            guard let data, let st = try? JSONDecoder().decode(State.self, from: data) else { return }
            self?.onState?(st)
        }
    }

    private func get(_ path: String, _ done: @escaping (Data?) -> Void) {
        let url = baseURL.appendingPathComponent(path)
        session.dataTask(with: url) { data, _, _ in
            DispatchQueue.main.async { done(data) }
        }.resume()
    }
}
