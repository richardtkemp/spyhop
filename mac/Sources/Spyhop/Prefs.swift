import AppKit

/// Tiny persisted preferences (status-menu driven). KISS: which displays to render on, and
/// whether all displays share one simulation (mirror) or each runs its own (independent).
enum Prefs {
    private static let d = UserDefaults.standard

    /// Display IDs to render on. Empty = all connected displays.
    static var screenIDs: Set<CGDirectDisplayID> {
        get { Set((d.array(forKey: "screenIDs") as? [NSNumber] ?? []).map { $0.uint32Value }) }
        set { d.set(newValue.map { NSNumber(value: $0) }, forKey: "screenIDs"); d.synchronize() }
    }

    /// true = one shared simulation cloned to every display; false = independent per display.
    static var mirror: Bool {
        get { d.bool(forKey: "mirror") }
        set { d.set(newValue, forKey: "mirror"); d.synchronize() }
    }

    // Per-machine overrides of server render config (nil = follow the server's value).
    /// Animation frames per creature (1 = rigid … 30). Drives texture memory. nil = follow server.
    static var framesOverride: Int? {
        get { d.object(forKey: "framesOverride") as? Int }
        set { set(newValue.map { NSNumber(value: $0) }, "framesOverride") }
    }
    /// Max creatures to render on this Mac (client-side cap on the server roster). nil = show all
    /// the server sends. The server keeps the largest/pinned first, so a lower cap drops the
    /// smallest; overflow creatures aren't force-killed — they stop being refreshed and swim off.
    static var maxCreatures: Int? {
        get { d.object(forKey: "maxCreatures") as? Int }
        set { set(newValue.map { NSNumber(value: $0) }, "maxCreatures") }
    }
    /// Cache creature textures at full display resolution (4× the bytes). Off by default —
    /// creatures are cached at half linear dims (¼ the RAM, slightly softer) unless this is on.
    static var highResCreatures: Bool {
        get { d.bool(forKey: "highResCreatures") }
        set { d.set(newValue, forKey: "highResCreatures"); d.synchronize() }
    }
    /// Pure client display toggle (no server equivalent): hide the creature name labels.
    static var labelsHidden: Bool {
        get { d.bool(forKey: "labelsHidden") }
        set { d.set(newValue, forKey: "labelsHidden"); d.synchronize() }
    }

    private static func set(_ value: Any?, _ key: String) {
        if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
        d.synchronize()
    }
}
