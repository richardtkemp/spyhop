import Cocoa
import SpriteKit

/// Agent that renders the ocean on the chosen displays (all by default). Each display can run its
/// own simulation (independent) or share one (mirror) — set via the status-bar menu, persisted in
/// UserDefaults. Telemetry from one shared poller (or a fixed bench workload) feeds every sim.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let options = Options.parse(CommandLine.arguments, env: ProcessInfo.processInfo.environment)
    private var telemetry: Telemetry?
    private var lastConfig: Config?
    private var lastState: State?
    private var signalSource: DispatchSourceSignal?
    private var windows: [CGDirectDisplayID: (window: DesktopWindow, view: SKView, scene: OceanScene)] = [:]
    private var statusItem: NSStatusItem?
    private var sharedSim: Sim?
    private var knownSims = Set<ObjectIdentifier>()
    private var currentKey = ""   // signature of the built window set; rebuild only when it changes
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    func applicationDidFinishLaunching(_ notification: Notification) {
        rebuildWindows()
        setupStatusItem()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        startTelemetry()

        signal(SIGUSR1, SIG_IGN)   // SIGUSR1 → snapshot the live instance
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in self?.snapshot(exitAfter: false) }
        src.resume(); signalSource = src

        if CommandLine.arguments.contains("--snap") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.snapshot(exitAfter: true) }
        }
    }

    private func snapshot(exitAfter: Bool) {
        for (i, entry) in windows.values.enumerated() {
            guard let tex = entry.view.texture(from: entry.scene) else { continue }
            let img = tex.cgImage()
            if let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: NSHomeDirectory() + "/scene-snap-\(i).png"))
                print("spyhop: snapshot \(i) written (\(img.width)x\(img.height))")
            }
        }
        if exitAfter { NSApp.terminate(nil) }
    }

    @objc private func screensChanged() { rebuildWindows() }

    // MARK: telemetry

    private func startTelemetry() {
        let t = Telemetry(baseURL: options.url); telemetry = t
        t.onConfig = { [weak self] cfg in self?.lastConfig = cfg; self?.applyConfig(cfg) }
        t.onState = { [weak self] st in self?.lastState = st; self?.forEachSim { $0.applyState(st, now: ProcessInfo.processInfo.systemUptime) } }
        if options.bench {
            lastConfig = Bench.defaultConfig(); lastState = Bench.state()
            applyConfig(lastConfig!); forEachSim { $0.applyState(self.lastState!, now: ProcessInfo.processInfo.systemUptime) }
            t.loadConfig()
        } else {
            t.start()
        }
    }

    private func applyConfig(_ cfg: Config) {
        forEachSim { $0.setConfig(cfg) }
        for w in windows.values { w.view.preferredFramesPerSecond = max(1, options.fpsOverride ?? cfg.render.fps) }
    }

    /// Apply to each *distinct* sim once (mirror shares one across displays).
    private func forEachSim(_ body: (Sim) -> Void) {
        var seen = Set<ObjectIdentifier>()
        for w in windows.values where seen.insert(ObjectIdentifier(w.scene.sim)).inserted { body(w.scene.sim) }
    }

    // MARK: windows

    private func targetScreens() -> [NSScreen] {
        let all = NSScreen.screens
        if options.oneScreen, let s = all.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            return [s]
        }
        let sel = Prefs.screenIDs
        guard !sel.isEmpty else { return all }
        let picked = all.filter { sel.contains($0.displayID) }
        return picked.isEmpty ? all : picked   // stale prefs → fall back to all
    }

    private func makeSim() -> Sim {
        let s = Sim(); s.isBench = options.bench; s.benchDayNight = options.daynight
        s.motionScale = reduceMotion ? 0.2 : 1
        return s
    }

    private func rebuildWindows() {
        let screens = targetScreens()
        let mirror = Prefs.mirror && !options.oneScreen
        let key = screens.map { "\($0.displayID):\(Int($0.frame.width))x\(Int($0.frame.height))" }.sorted().joined(separator: ",") + "|m=\(mirror)"
        if key == currentKey {
            for s in screens { windows[s.displayID]?.window.fit(to: s) }   // spurious event: just refit
            return
        }
        currentKey = key

        windows.values.forEach { $0.window.orderOut(nil) }
        windows = [:]; knownSims = []; sharedSim = mirror ? makeSim() : nil

        for (i, screen) in screens.enumerated() {
            let window = DesktopWindow(screen: screen)
            let view = SKView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.autoresizingMask = [.width, .height]; view.ignoresSiblingOrder = true
            view.preferredFramesPerSecond = max(1, options.fpsOverride ?? lastConfig?.render.fps ?? 30)

            let sim = mirror ? sharedSim! : makeSim()
            let scene = OceanScene(size: screen.frame.size, sim: sim, isMaster: mirror ? (i == 0) : true)
            scene.fpsOverride = options.fpsOverride; scene.off = options.off
            scene.topInset = screen.frame.maxY - screen.visibleFrame.maxY   // menu-bar strip (0 on non-primary)
            view.presentScene(scene)

            if knownSims.insert(ObjectIdentifier(sim)).inserted {   // seed each distinct sim once
                if let cfg = lastConfig { sim.setConfig(cfg) }
                if let st = lastState { sim.applyState(st, now: ProcessInfo.processInfo.systemUptime) }
            }
            window.contentView = view; window.orderBack(nil)
            windows[screen.displayID] = (window, view, scene)
        }
    }

    // MARK: status menu (dynamic — rebuilt each open so the display list is current)

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🐳"
        let menu = NSMenu(); menu.delegate = self
        item.menu = menu; statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: options.bench ? "spyhop (bench)" : "spyhop wallpaper", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let header = NSMenuItem(title: "Displays", action: nil, keyEquivalent: ""); header.isEnabled = false
        menu.addItem(header)
        let rendered = Set(windows.keys)
        for screen in NSScreen.screens {
            let title = "  \(screen.localizedName)  \(Int(screen.frame.width))×\(Int(screen.frame.height))"
            let it = NSMenuItem(title: title, action: #selector(toggleScreen(_:)), keyEquivalent: "")
            it.state = rendered.contains(screen.displayID) ? .on : .off
            it.representedObject = NSNumber(value: screen.displayID); it.target = self
            menu.addItem(it)
        }
        menu.addItem(.separator())
        let mir = NSMenuItem(title: "Mirror displays (clone)", action: #selector(toggleMirror), keyEquivalent: "")
        mir.state = Prefs.mirror ? .on : .off; mir.target = self
        menu.addItem(mir)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"); quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleScreen(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.uint32Value else { return }
        let allIDs = Set(NSScreen.screens.map(\.displayID))
        var sel = Prefs.screenIDs.isEmpty ? allIDs : Prefs.screenIDs
        if sel.contains(id) { sel.remove(id) } else { sel.insert(id) }
        if sel.isEmpty { sel = [id] }             // never zero displays
        Prefs.screenIDs = (sel == allIDs) ? [] : sel   // all selected → store "all"
        rebuildWindows()
    }

    @objc private func toggleMirror() { Prefs.mirror.toggle(); rebuildWindows() }

    @objc private func quit() { NSApp.terminate(nil) }
}

// Program entry runs on the main thread (the main actor's executor) — assert that so the
// @MainActor AppController can be constructed here without a concurrency error.
MainActor.assumeIsolated {
    setbuf(stdout, nil)
    if CommandLine.arguments.contains("--dump-shapes") {
        ShapeBaker.dumpAll(to: NSHomeDirectory() + "/shape-dumps")
        exit(0)
    }
    let app = NSApplication.shared
    let controller = AppController()
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    app.run()
}
