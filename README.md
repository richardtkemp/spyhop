# spyhop

A living ocean that visualises a host's telemetry in real time — and runs as a
live desktop wallpaper. Processes swim as sea creatures, system load drives the
weather, and pressure shows up as storms. It's `htop` reincarnated as an
aquarium you can leave on your screen.

The name is a whale behaviour: a whale *spyhops* when it rises vertically to
poke its head above the surface and **watch its surroundings** — which is
exactly what this does for your machine.

One stdlib-only Python file serves the page and a live telemetry feed; one
self-contained HTML file draws the scene on a `<canvas>`. No dependencies, no
build step, no external network calls.

## What the scene means

| You see | It means |
| --- | --- |
| **sky** (clouds, wind, waves) | 5-minute load average — builds as the host gets busier |
| **lightning** | swap in use > 90% |
| **rain** | an active alert is firing |
| **rocks on the seabed** | disk usage |
| **creatures** | process groups — **size** = memory (RSS), **speed** = CPU |
| **water temperature glow** | CPU package temperature |
| host name, top-left | which machine you're watching (from the server) |

The server keeps the process groups that make up the bulk of memory or CPU use,
plus any you've **pinned** (see below), so the scene stays legible instead of
showing every PID.

## Quick start

```sh
git clone https://github.com/richardtkemp/spyhop.git
cd spyhop
python3 spyhop.py            # serves on http://0.0.0.0:8477
```

Open `http://localhost:8477/` (or `http://<this-host-lan-ip>:8477/` from
another machine on the same network). Set the port with `SPYHOP_PORT=9000`.

Requirements: Python 3.8+ (standard library only). `docker` and a local
[netdata](https://www.netdata.cloud/) are used opportunistically for the
container count and alert rain — both are optional; without them those signals
just read zero.

### Running the server on a different host

You watch whichever machine the server runs on, so `spyhop.py` belongs on *that*
host — which needn't be the one you edit on. Because it's a single
standard-library file with no build step, you don't need the whole repo on the
target: copy just the script (developing on your laptop, deploying to a home
server, say) and run it there.

```sh
scp spyhop.py you@server:~/            # deploy from your dev machine
ssh you@server 'python3 ~/spyhop.py'   # or wire it up as a service (see below)
```

Then point any client — a browser, Plash, or the native app — at
`http://<server-lan-ip>:8477/`. For an always-on install, see
[Run it permanently](#run-it-permanently-systemd-user-service).

## Use it as a live desktop wallpaper

The page is one self-contained URL, so any "web page as wallpaper" tool works.

### macOS — [Plash](https://sindresorhus.com/plash) (recommended)

```sh
brew install --cask plash
```

Then: Plash menu-bar icon → **Add Website…** → `http://<host-lan-ip>:8477/`.
It becomes your animated desktop immediately. Worth enabling **Deactivate on
battery** in Plash's settings for laptops.

- Your Mac and the host must be on the **same network** (the server is
  LAN-only; it isn't exposed to the internet).
- It's a continuously animating canvas, so it uses some GPU/battery. It honours
  macOS **Reduce Motion** (System Settings → Accessibility → Display), and the
  browser engine auto-throttles it when the desktop is fully covered by windows.

**Übersicht** also works if you already use it, but it's built for
command-driven widgets — you'd wrap a webview in a widget, which is fiddlier
than Plash for a full-page URL.

### macOS — native app (`mac/`)

For a lighter, multi-display alternative to the web-in-Plash route, there's a
native **SpriteKit** build in [`mac/`](mac/). It's a third telemetry client
that talks to the same server, renders the identical scene on the GPU at
**~3× lower CPU and less than half the memory** of the WebView, and covers an
arbitrary number of displays with a menu-bar screen picker. It builds with the
Command Line Tools only (no Xcode). See [`mac/README.md`](mac/README.md) for
build and run instructions.

### Linux / Windows

Any browser in fullscreen/kiosk mode pointed at the URL, or a wallpaper tool
that renders a URL (e.g. Wallpaper Engine on Windows).

## Pin processes to creatures (no code edits)

Which process becomes which creature is **data, not code**. The built-in
defaults are sensible, and you override them with a small JSON file — spyhop
looks for one, in order:

1. `$SPYHOP_CONFIG` (an explicit path), else
2. `~/.config/spyhop/config.json`, else
3. `spyhop.config.json` next to `spyhop.py` (git-ignored).

Copy [`spyhop.config.example.json`](spyhop.config.example.json) to one of those
locations and edit it:

```json
{
  "creatures": [
    { "match": "postgres|postgresql", "shape": "crab",  "hue": 210, "always": true },
    { "match": "ollama|llama",        "shape": "whale", "always": true },
    { "match": "my-service",          "shape": "school", "hue": 285, "spd": 0.9 }
  ]
}
```

Your entries are matched **before** the built-in defaults, so they win. The
defaults still apply to everything you don't mention. Restart spyhop to pick up
changes.

### Fields

| Field | Required | Meaning |
| --- | --- | --- |
| `match` | ✅ | Case-insensitive regex tested against the process' display name. First match wins. |
| `shape` | | One of: `angler`, `whale`, `jelly`, `squid`, `ray`, `fish`, `school`, `crab`. Defaults to `fish`. |
| `detail` | | `simple` or `complex` body art. Omit to follow `render.creatureDetail` (default `complex`). Whales have a single form and ignore it. |
| `hue` | | 0–360. Omit and a stable colour is derived from the name. |
| `sat`, `lit` | | HSL saturation / lightness (0–100). |
| `spd` | | Relative swim speed (~0.2 slow … ~1.0 fast). |
| `band` | | `[min, max]` fraction of water depth the creature lives in (`0` = surface, `1` = seabed). Crabs sit near `[.93, .98]`. |
| `mul` | | Size multiplier. |
| `always` | | `true` pins this process into the scene even when it isn't among the heaviest. |

A process' display name is derived from its command — interpreters like
`python`/`node`/`java` are unwrapped to the script, module, jar, or project
directory they're running, so you match on something meaningful (e.g.
`radarr`, not `mono`).

Bad regexes or unknown shapes are skipped with a warning rather than crashing.

## Hide noisy alerts

Alerts (from netdata) make it rain. If a particular alert fires constantly and
you don't want to see it, mute it by name in the same config file with
`muteAlerts` — a list of case-insensitive regexes matched against the alert
name. Matched alerts are dropped entirely: no rain, and they don't count.

```json
{
  "muteAlerts": ["inbound_packets_dropped", "30min_ram_swapped_out"]
}
```

(`creatures` and `muteAlerts` can live in the same file.) To see the exact
alert names your host is raising, hit netdata directly —
`curl http://<netdata-host>:19999/api/v1/alarms` — or check spyhop's
`/state.json`, whose `alerts` array lists them.

## Run it permanently (systemd user service)

A ready-to-edit unit ships as [`spyhop.service`](spyhop.service). Installed as a
**user** service with lingering enabled, it starts at boot without anyone
logging in:

```sh
mkdir -p ~/.config/systemd/user
# Fill in the install path automatically from wherever you cloned it:
sed "s|/path/to/spyhop|$PWD|g" spyhop.service > ~/.config/systemd/user/spyhop.service
loginctl enable-linger "$USER"                  # start at boot without login
systemctl --user daemon-reload
systemctl --user enable --now spyhop.service
```

Handy afterwards:

```sh
systemctl --user status spyhop        # check it
systemctl --user restart spyhop       # after editing the files or config
journalctl --user -u spyhop -f        # follow logs
```

## HTTP endpoints

| Path | Returns |
| --- | --- |
| `/` | the ocean page |
| `/state.json` | live telemetry snapshot (host, load, cpu, mem, swap, disk, temp, alerts, roster) |
| `/config.json` | the merged creature config (your pins + defaults) the client renders from |
| `/health` | `ok` |

## License

MIT — see [LICENSE](LICENSE).
