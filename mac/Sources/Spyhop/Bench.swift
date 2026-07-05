import Foundation

/// Command-line / env options. Mirrors the web client's URL params so native and web
/// benchmark the identical scene.
struct Options {
    var bench = false
    var url = URL(string: "http://your-host:8477")!
    var off: Set<String> = []
    var fpsOverride: Int?
    var seconds: Double?
    var daynight = false
    var oneScreen = false   // benchmark on the built-in (smallest) display only, for a fair vs-web number

    static func parse(_ args: [String], env: [String: String]) -> Options {
        var o = Options()
        if env["SPYHOP_BENCH"] != nil { o.bench = true }
        if let u = env["SPYHOP_URL"], let url = URL(string: u) { o.url = url }
        for a in args.dropFirst() {
            switch true {
            case a == "--bench": o.bench = true
            case a == "--daynight": o.daynight = true
            case a == "--one-screen": o.oneScreen = true
            case a.hasPrefix("--url="): if let u = URL(string: String(a.dropFirst(6))) { o.url = u }
            case a.hasPrefix("--off="): o.off = Set(a.dropFirst(6).split(separator: ",").map(String.init))
            case a.hasPrefix("--fps="): o.fpsOverride = Int(a.dropFirst(6))
            case a.hasPrefix("--seconds="): o.seconds = Double(a.dropFirst(10))
            default: break
            }
        }
        return o
    }
}

/// Fixed synthetic all-elements workload — identical to BENCH_STATE in spyhop.html, so the
/// render cost is reproducible and comparable to the web run.
enum Bench {
    static func state() -> State {
        var s = State()
        s.host = "bench"; s.uptime = "7d 0h"
        s.cpu = 78; s.load = 5.0; s.load5 = 5.5; s.load15 = 4.8; s.cores = 4
        s.memPct = 82; s.swapPct = 95; s.temp = 62; s.disk = 85; s.alarms = 2; s.containers = 9
        s.alerts = [
            Alert(name: "cpu_pressure", status: "WARNING", value: 88, units: "%"),
            Alert(name: "disk_space", status: "CRITICAL", value: 96, units: "%"),
        ]
        let r: [(String, Int, Int, Int)] = [
            ("spyhop", 60, 1, 5), ("qemu", 2048, 1, 40), ("netdata", 180, 1, 8), ("opencode", 320, 1, 25),
            ("foci", 150, 1, 10), ("firefox", 900, 1, 30), ("claude", 400, 4, 35), ("kworker", 50, 8, 12),
            ("pihole", 120, 1, 6), ("radarr", 200, 1, 15), ("sonarr", 210, 1, 12), ("postgres", 300, 1, 20),
            ("python-worker", 250, 1, 18), ("dockerd", 180, 1, 9), ("node-app", 280, 1, 22), ("redis", 90, 1, 7),
            ("nginx", 70, 1, 5), ("java-svc", 1200, 1, 28),
        ]
        s.roster = r.map { RosterEntry(name: $0.0, memMiB: $0.1, count: $0.2, cpu: Double($0.3)) }
        return s
    }

    /// Compiled-in default creature mapping (subset of DEFAULT_CREATURES in spyhop.py) so bench
    /// runs are hermetic if /config.json is unreachable. Full mapping still comes from the server.
    static func defaultConfig() -> Config {
        let json = """
        {"creatures":[
          {"match":"spyhop","shape":"angler","hue":46,"sat":85,"lit":62,"spd":0.42,"band":[0.60,0.84]},
          {"match":"qemu","shape":"whale","hue":205,"sat":28,"lit":62,"spd":0.26,"band":[0.50,0.78]},
          {"match":"netdata","shape":"jelly","hue":286,"sat":68,"lit":72,"spd":0.22,"band":[0.16,0.82]},
          {"match":"opencode","shape":"squid","hue":32,"sat":88,"lit":62,"spd":0.70,"band":[0.30,0.60]},
          {"match":"foci","shape":"ray","hue":250,"sat":44,"lit":62,"spd":0.50,"band":[0.55,0.82]},
          {"match":"firefox","shape":"fish","hue":24,"sat":88,"lit":60,"spd":0.70,"band":[0.32,0.58],"mul":1.15},
          {"match":"claude","shape":"school","hue":172,"sat":70,"lit":63,"spd":0.95,"band":[0.28,0.52]},
          {"match":"^kworker$","shape":"school","hue":210,"sat":12,"lit":55,"spd":0.70,"band":[0.40,0.72]},
          {"match":"pihole","shape":"fish","hue":2,"sat":78,"lit":60,"spd":0.80,"band":[0.40,0.62]},
          {"match":"radarr|sonarr","shape":"crab","hue":16,"sat":82,"lit":56,"spd":0.50,"band":[0.93,0.98]}
        ],"render":{"fps":30,"wiggle":true}}
        """
        return (try? JSONDecoder().decode(Config.self, from: Data(json.utf8))) ?? Config(creatures: [])
    }
}

extension Config {
    init(creatures: [CreatureConfig]) { self.creatures = creatures; self.render = RenderConfig() }
}
