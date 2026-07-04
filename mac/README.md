# spyhop — native macOS wallpaper

A native **SpriteKit** rendering of the spyhop ocean, built to run as a
desktop-level wallpaper on macOS. It exists **alongside** the web version
(`../spyhop.html`), which stays the portable, zero-build path. This one trades
portability for a big efficiency win and full multi-display support.

## How it relates to the web version

There is **one backend, three clients**:

```
spyhop.py (host)  ──/config.json ─┬─▶ spyhop.html      (web canvas — portable, unchanged)
    serves        ──/state.json  ─┴─▶ mac/ SpriteKit app (native, this directory)
```

The native app is just another telemetry client: it fetches `/config.json`
once and polls `/state.json`, exactly like the web page. Only the per-frame
**simulation** (`frame()`) and **drawing** (`drawX()`) are ported to Swift —
the server, roster selection, pinning, alert muting and day/night source data
are 100% reused. Config is honoured transparently (`creatures[]` matching,
`render.fps`, `render.wiggle`, the `wind*` knobs; `dpr`/`spritePhases` are
Canvas-specific and ignored).

Point it at your server with `SPYHOP_URL` / `--url=` (default
`http://192.168.1.150:8477` — set it to your host).

## Why native

The web version is draw-call-bound inside WebKit at ~40% of one core per
screen. Rendering natively on SpriteKit (which batches to Metal) drops that to
**~13–15% per screen**, covers an arbitrary number of displays, and uses **less
than half the memory** of the WebView. See [Performance](#performance) below.

## Prerequisites

- macOS 13+ on Apple Silicon (arm64).
- **Command Line Tools for Xcode** — the *stable* release, not a beta.
  - Full Xcode is **not** required. SwiftPM is **not** used.
  - ⚠️ A mismatched/beta CLT (e.g. a beta SDK on a stable macOS) makes
    `import SpriteKit` fail with `redefinition of module 'SwiftBridging'`.
    If you hit that, install the stable CLT `.dmg` from
    [developer.apple.com/download/all](https://developer.apple.com/download/all/)
    (search "Command Line Tools for Xcode") and retry.

## Build

Run **on the Mac** (it needs the macOS SDK):

```sh
cd mac
./build.sh            # compiles with swiftc -O, assembles Spyhop.app, ad-hoc signs
./build.sh run        # same, then (re)launches the app
```

`build.sh` invokes `swiftc` directly (not `swift build`) because SPM's manifest
step is broken under CLT-only setups. The result is `mac/Spyhop.app`.

### Building from another machine

If you edit on a Linux/dev box and build over SSH:

```sh
tar -cf - mac | ssh mac 'rm -rf ~/spyhop-build && mkdir -p ~/spyhop-build && tar -xf - -C ~/spyhop-build'
ssh mac 'cd ~/spyhop-build/mac && ./build.sh'
```

## Run

```sh
open Spyhop.app                          # live wallpaper on every display
open Spyhop.app --args --bench           # synthetic all-shapes scene (see below)
```

The app is a menu-bar agent (`LSUIElement`) — no Dock icon, no window; it draws
directly onto the desktop behind your icons.

### Flags

| Flag / env | Effect |
| --- | --- |
| `--url=<url>` · `SPYHOP_URL` | Telemetry server (default `http://192.168.1.150:8477`) |
| `--bench` · `SPYHOP_BENCH` | Compiled-in synthetic workload; never polls. Cycles day→night, ramps disk 0→100%, toggles alerts every 2s |
| `--one-screen` | Render on the built-in (smallest) display only — for a fair vs-web benchmark |
| `--off=a,b` | Disable named subsystems (e.g. `--off=streaks`) for profiling |
| `--fps=N` | Cap the frame rate (overrides `render.fps` from config) |
| `--seconds=N` | Auto-exit after N seconds (benchmark runs) |
| `--snap` | Wait 5s, write `~/scene-snap-<i>.png` per display, then exit |

### Controls (menu-bar icon)

- **Displays ▸** — tick which screens to render on (empty = all).
- **Mirror** — clone one aquarium to every screen, or run each independently.

Both persist in `UserDefaults`. The set of displays reconciles automatically
when you plug/unplug a monitor.

## Debugging a desktop-level window

`screencapture` can't grab a wallpaper-level window, so to see what the live app
is actually drawing, send it `SIGUSR1`:

```sh
kill -USR1 $(pgrep -x Spyhop)     # writes ~/scene-snap-<display>.png
```

(`--dump-shapes` writes one PNG per baked creature shape, for inspecting the
geometry ports.)

## Performance

Measured on the built-in display, same-session paired deltas:

| | CPU (1 core) | Memory (RSS) |
| --- | --- | --- |
| Web (WebKit), one screen | ~40% | ~523 MB |
| Native, one screen | ~13–15% | ~217 MB (8-phase wiggle) / ~410 MB (16-phase) |

The dominant native cost was **`SKShapeNode` re-tessellating filled paths on the
CPU every frame**. Converting clouds, bubbles, plankton and weed to
baked-texture sprites took the full scene from ~33% → ~12% per screen. The
wiggle atlas (N baked pose frames per creature kind, swapped per frame) is the
main memory lever — each frame is a full-resolution texture, so doubling phases
roughly doubles the creature-texture pool. `ShapeBaker.phases` controls it.

## Source map

| File | Role |
| --- | --- |
| `main.swift` | Menu-bar agent, per-display window/scene set, screen reconcile, snapshot |
| `DesktopWindow.swift` | Desktop-level `NSWindow` (lifted from Plash, MIT) |
| `ScreenKit.swift` · `Prefs.swift` | Screen helpers · `UserDefaults` prefs |
| `Telemetry.swift` | `/config.json` + `/state.json` client (config-first, retries) |
| `Sim.swift` | The `frame()` port — advance, avoidance, day/night, reconcile |
| `OceanScene.swift` | Scene graph, layer z-order, per-frame drive, HUD |
| `Shapes.swift` | Creature bakes (CoreGraphics) + wiggle atlas |
| `WaterFX · StormFX · Clouds · Wind · Celestial · Seabed` | Weather/water/sky/floor subsystems |
| `Palette.swift` | HSL colour helpers (creatures are CSS `hsla`) |
| `Bench.swift` | `--bench` state + option parsing |

`Package.swift` is present for editor tooling only; the build uses `swiftc`
directly via `build.sh`.
