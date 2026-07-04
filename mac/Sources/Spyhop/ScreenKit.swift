import Cocoa

extension NSScreen {
    /// The Core Graphics display ID — a stable key for a physical screen across re-enumeration.
    /// (The `NSScreen` objects themselves are recreated on every screen-parameter change.)
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
