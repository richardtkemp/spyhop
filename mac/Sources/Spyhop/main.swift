import Cocoa
import ServiceManagement
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
        // Pause the whole scene + telemetry when every wallpaper window is hidden behind other
        // windows — SpriteKit already skips the GPU render when occluded, but it keeps calling
        // update() (stepping the sim + rebuilding geometry) ~60×/s for nobody. This zeroes that out.
        NotificationCenter.default.addObserver(
            self, selector: #selector(occlusionChanged),
            name: NSApplication.didChangeOcclusionStateNotification, object: nil)
        startTelemetry()
        occlusionChanged()   // sync initial state (e.g. launched while covered)

        signal(SIGUSR1, SIG_IGN)   // SIGUSR1 → snapshot the live instance
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in self?.snapshot(exitAfter: false) }
        src.resume(); signalSource = src

        if CommandLine.arguments.contains("--snap") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.snapshot(exitAfter: true) }
        }
        if let secs = options.seconds {   // --seconds=N — auto-exit for scripted benchmark runs
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { NSApp.terminate(nil) }
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

    private var renderPaused = false
    @objc private func occlusionChanged() {
        if options.bench { return }   // benchmarks run at full rate regardless of window visibility
        setRenderPaused(!NSApp.occlusionState.contains(.visible))
    }

    /// Pause/resume every render window's scene loop and the telemetry poll. Idempotent so
    /// rebuildWindows() can re-apply the current state to freshly created views.
    private func setRenderPaused(_ paused: Bool) {
        renderPaused = paused
        for w in windows.values { w.view.isPaused = paused }
        telemetry?.setActive(!paused)
    }

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

    /// Atlas frame count for this Mac: menu override, else 16 when the server wants animation, else 1.
    private func effectiveFrames(_ cfg: Config) -> Int {
        Prefs.framesOverride ?? (cfg.render.wiggleMode == "none" ? 1 : ShapeBaker.phasesDefault)
    }

    private func applyConfig(_ cfg: Config) {
        let frames = effectiveFrames(cfg), res = Prefs.highResCreatures ? 1.0 : 0.5
        let buckets = (UserDefaults.standard.object(forKey: "sizeBuckets") as? Int).map { max(1, $0) } ?? 6   // benchmark knob
        if ShapeBaker.phases != frames || ShapeBaker.resScale != res || ShapeBaker.bucketCount != buckets {   // reshape atlas → flush + re-request
            ShapeBaker.setPhases(frames); ShapeBaker.setResScale(res); ShapeBaker.setBucketCount(buckets)
            for w in windows.values { w.scene.invalidateTextures() }
        }
        forEachSim { applyEffectiveConfig(to: $0, cfg) }
        for w in windows.values { w.view.preferredFramesPerSecond = max(1, options.fpsOverride ?? cfg.render.fps) }
    }

    /// Push server config to a sim with this Mac's menu overrides layered on top (applied after
    /// setConfig, which resets them from the server values). 1 frame ⇒ freeze wig (fully rigid).
    private func applyEffectiveConfig(to sim: Sim, _ cfg: Config) {
        sim.setConfig(cfg)
        sim.wiggleMode = effectiveFrames(cfg) > 1 ? "high" : "none"
        sim.showLabels = !Prefs.labelsHidden
        sim.maxCreatures = Prefs.maxCreatures
        sim.applyCap(now: ProcessInfo.processInfo.systemUptime)   // evict/admit now, don't wait for the next poll
    }

    /// Re-apply the last server config after a menu override changes (rebuilds textures next frame).
    private func reapplyConfig() { if let cfg = lastConfig { applyConfig(cfg) } }

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
                if let cfg = lastConfig { applyEffectiveConfig(to: sim, cfg) }
                if let st = lastState { sim.applyState(st, now: ProcessInfo.processInfo.systemUptime) }
            }
            window.contentView = view; window.orderBack(nil)
            view.isPaused = renderPaused   // stay paused if rebuilt while occluded
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

        // Rendering — client-side overrides of the server config, scoped to this Mac.
        menu.addItem(.separator())
        let rHeader = NSMenuItem(title: "Rendering (this Mac)", action: nil, keyEquivalent: ""); rHeader.isEnabled = false
        menu.addItem(rHeader)
        // Animation ▸ frames per creature — the native memory lever. More frames = smoother motion
        // and proportionally more texture memory. Combines with the resolution toggle below.
        // Detail is baked either way (free on native), so it's left to the server / web client.
        let animParent = NSMenuItem(title: "Animation", action: nil, keyEquivalent: "")
        let animSub = NSMenu()
        let note = NSMenuItem(title: "frames — smoother, but heavy on memory", action: nil, keyEquivalent: ""); note.isEnabled = false
        animSub.addItem(note); animSub.addItem(.separator())
        let effFrames = Prefs.framesOverride ?? (lastConfig?.render.wiggleMode == "none" ? 1 : ShapeBaker.phasesDefault)
        for f in [1, 4, 8, 12, 16, 24, 30] {
            let label = f == 1 ? "Rigid (1 frame)" : f == ShapeBaker.phasesDefault ? "\(f) frames (recommended)" : "\(f) frames"
            let it = NSMenuItem(title: label, action: #selector(setFrames(_:)), keyEquivalent: ""); it.target = self
            it.representedObject = NSNumber(value: f)
            it.state = (Prefs.framesOverride != nil && f == effFrames) ? .on : .off
            animSub.addItem(it)
        }
        animSub.addItem(.separator())
        let follow = NSMenuItem(title: "Follow server", action: #selector(setFrames(_:)), keyEquivalent: ""); follow.target = self
        follow.representedObject = NSNumber(value: 0); follow.state = Prefs.framesOverride == nil ? .on : .off
        animSub.addItem(follow)
        animParent.submenu = animSub
        menu.addItem(animParent)
        // Client-side cap on how many creatures (process-groups) the server roster renders here.
        let maxParent = NSMenuItem(title: "Max creatures", action: nil, keyEquivalent: "")
        let maxSub = NSMenu()
        for n in [15, 20, 25, 30, 35, 40] {
            let it = NSMenuItem(title: "\(n)", action: #selector(setMaxCreatures(_:)), keyEquivalent: ""); it.target = self
            it.representedObject = NSNumber(value: n)
            it.state = Prefs.maxCreatures == n ? .on : .off
            maxSub.addItem(it)
        }
        maxSub.addItem(.separator())
        let maxFollow = NSMenuItem(title: "Show all", action: #selector(setMaxCreatures(_:)), keyEquivalent: ""); maxFollow.target = self
        maxFollow.representedObject = NSNumber(value: 0); maxFollow.state = Prefs.maxCreatures == nil ? .on : .off
        maxSub.addItem(maxFollow)
        maxParent.submenu = maxSub
        menu.addItem(maxParent)
        let hiRes = NSMenuItem(title: "High-res creatures (4× RAM)", action: #selector(toggleHiRes), keyEquivalent: "")
        hiRes.state = Prefs.highResCreatures ? .on : .off; hiRes.target = self
        menu.addItem(hiRes)
        let labels = NSMenuItem(title: "Show labels", action: #selector(toggleLabels), keyEquivalent: "")
        labels.state = Prefs.labelsHidden ? .off : .on; labels.target = self
        menu.addItem(labels)

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off; login.target = self
        menu.addItem(login)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"); quit.target = self
        menu.addItem(quit)
    }

    /// Register/unregister the bundle as a login item (SMAppService, macOS 13+). No-op with a
    /// logged warning if it fails — e.g. when run from a location the system won't auto-launch.
    @objc private func toggleLaunchAtLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            NSLog("spyhop: could not toggle launch-at-login: \(error.localizedDescription)")
        }
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

    /// Set the atlas frame count on this Mac (tag 0 = clear override / follow server).
    @objc private func setFrames(_ sender: NSMenuItem) {
        let f = (sender.representedObject as? NSNumber)?.intValue ?? 0
        Prefs.framesOverride = f == 0 ? nil : f
        reapplyConfig()
    }

    /// Cap the rendered roster on this Mac (tag 0 = clear override / show all the server sends).
    @objc private func setMaxCreatures(_ sender: NSMenuItem) {
        let n = (sender.representedObject as? NSNumber)?.intValue ?? 0
        Prefs.maxCreatures = n == 0 ? nil : n
        reapplyConfig()
    }

    @objc private func toggleHiRes() { Prefs.highResCreatures.toggle(); reapplyConfig() }

    @objc private func toggleLabels() { Prefs.labelsHidden.toggle(); reapplyConfig() }

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
