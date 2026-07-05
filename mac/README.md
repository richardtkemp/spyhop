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
are 100% reused. Config is honoured transparently (`creatures[]` matching
and per-creature `detail`, `render.fps`, `render.wiggle`, `render.creatureDetail`,
the `wind*` knobs; `dpr`/`spritePhases` are Canvas-specific and ignored).
Creature animation can be overridden per-machine from the menu (see
[Controls](#controls-menu-bar-icon)); on the native app `detail` is a look-only
choice (baked either way), so it's left to the server / web client.

Point it at your server with `SPYHOP_URL` / `--url=` (default
`http://your-host:8477` — set it to your host).

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

## Install & run

Run it straight from the build directory:

```sh
open Spyhop.app                          # live wallpaper on every display
open Spyhop.app --args --bench           # synthetic all-shapes scene (see below)
```

To keep it around, copy the bundle into `/Applications` — it then shows up (with
its whale icon) in Finder and Launchpad:

```sh
pkill -x Spyhop 2>/dev/null              # stop any running copy first
cp -R Spyhop.app /Applications/
open /Applications/Spyhop.app
```

The app is a menu-bar agent (`LSUIElement`) — no Dock icon, no window; it draws
directly onto the desktop behind your icons. To start it automatically, tick
**Launch at login** in the menu-bar 🐳 menu (see [Controls](#controls-menu-bar-icon)).

### Flags

| Flag / env | Effect |
| --- | --- |
| `--url=<url>` · `SPYHOP_URL` | Telemetry server (default `http://your-host:8477`) |
| `--bench` · `SPYHOP_BENCH` | Compiled-in synthetic workload; never polls. Cycles day→night, ramps disk 0→100%, toggles alerts every 2s |
| `--one-screen` | Render on the built-in (smallest) display only — for a fair vs-web benchmark |
| `--off=a,b` | Disable named subsystems (e.g. `--off=streaks`) for profiling |
| `--fps=N` | Cap the frame rate (overrides `render.fps` from config) |
| `--seconds=N` | Auto-exit after N seconds (benchmark runs) |
| `--snap` | Wait 5s, write `~/scene-snap-<i>.png` per display, then exit |

### Controls (menu-bar icon)

- **Displays ▸** — tick which screens to render on (empty = all).
- **Mirror** — clone one aquarium to every screen, or run each independently.
- **Rendering (this Mac)** — client-side overrides of the server's `render`
  config, scoped to this machine (they win over `/config.json`):
  - **Animation ▸** — how many pose frames each creature is baked at (1 = rigid
    … 30). This is the native memory lever: frames trade directly against texture
    memory and against smoothness. **24 is the recommended default.** Multiples
    of 4 land frames on the motion extremes (full tail up/down); very low counts
    undersample them. CPU and creature `detail` don't change with this — detail
    is baked either way, so it's left to the server / web client.
  - **High-res creatures (4× RAM)** — off by default: creatures are cached at
    half linear dims (¼ the bytes, GPU-upscaled at draw — slightly softer). Turn
    it on to bake at full display resolution (4× the creature-texture memory).
    Independent of the frame count, so the two levers combine — the default
    (low-res, 24 frames) sits around ~220 MB in a busy scene.
  - **Max creatures ▸** — client-side cap (15–40, or **Show all**) on how many
    creatures render here. The server sends up to 40, largest/pinned-first, so a
    lower cap drops the smallest; overflow isn't force-killed — it ages out and
    swims off like a process that exited. Client-only; the server roster is
    unchanged. Default **Show all**.
  - **Show labels** — hide/show the creature name tags (client-only; no server
    equivalent).
- **Launch at login** — register the app as a login item so it starts at boot
  (uses `SMAppService`; toggles cleanly on and off).

Displays, Mirror and the render overrides persist in `UserDefaults`; the
login-item state is held by the system (`SMAppService`). The set of displays
reconciles automatically when you plug/unplug a monitor.

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
