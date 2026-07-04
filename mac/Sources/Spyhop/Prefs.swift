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
}
