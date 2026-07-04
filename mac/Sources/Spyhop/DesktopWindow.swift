import Cocoa

extension NSWindow.Level {
    /// kCGDesktopWindowLevel — the wallpaper layer, below desktop icons. (AppKit doesn't
    /// expose this as a named level, so derive it from Core Graphics like Plash does.)
    static let desktop = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
}

/// A desktop-wallpaper-level window that fully covers one screen and passes clicks through.
///
/// Adapted from Plash (MIT, © Sindre Sorhus — https://github.com/sindresorhus/Plash,
/// `DesktopWindow.swift`), stripped of its `Defaults`/browsing-mode/`Display` coupling: the
/// window simply binds to an `NSScreen` and covers its whole frame (behind the menu bar, like
/// a wallpaper). Screen add/remove/resize reconciliation lives in `AppController`.
@MainActor
final class DesktopWindow: NSWindow {
    // A wallpaper is never key/main and never grabs focus.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Stable identifier for the screen this window is pinned to (survives re-enumeration).
    let screenID: CGDirectDisplayID

    init(screen: NSScreen) {
        screenID = screen.displayID
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .desktop                     // kCGDesktopWindowLevel — sits on the wallpaper, below icons
        isRestorable = false
        canHide = false
        ignoresMouseEvents = true            // clicks fall through to the desktop
        displaysWhenScreenProfileChanges = true
        collectionBehavior = [
            .stationary,                     // don't move with Exposé/Mission Control
            .ignoresCycle,                   // skip in window cycling
            .fullScreenNone,                 // stay in the primary space, hide behind fullscreen apps
            .canJoinAllSpaces                // show on every Space
        ]
        disableSnapshotRestoration()
        setFrame(screen.frame, display: true)
    }

    /// Re-fit to a screen whose frame may have changed (resolution/arrangement).
    func fit(to screen: NSScreen) {
        setFrame(screen.frame, display: true)
    }
}
