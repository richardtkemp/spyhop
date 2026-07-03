#!/usr/bin/env python3
"""
spyhop — a tiny stdlib-only server feeding the living-ocean wallpaper with
real telemetry from this host.

  GET /            -> the ocean page (spyhop.html, read fresh each request)
  GET /state.json  -> live snapshot
  GET /config.json -> the creature config (user pins + built-in defaults)
  GET /health      -> "ok"

Configuration (all optional, data not code — see load_config() for the search
path: $SPYHOP_PORT overrides the port; $SPYHOP_CONFIG -> ~/.config/spyhop/
config.json -> ./spyhop.config.json for the JSON below):
  { "creatures":  [ {match, shape, hue, ...}, ... ],   # pin processes to creatures
    "muteAlerts": [ "regex", ... ] }                    # hide noisy netdata alerts
  Creature entries are matched before DEFAULT_CREATURES, so they override the
  defaults without editing this file. The client fetches /config.json and
  renders from it, so this table is the single source of truth for both
  roster-pinning and looks. muteAlerts drops matching alerts before they become
  rain (and before they're counted).

State contract:
  uptime, load (1m), load5 (5m), cores          # load5 drives the weather
  cpu (host busy%), memPct, swapPct              # cpu/mem/swap gauges
  alarms (count), alerts [{n,s,v,u}]             # raised netdata alarms
  containers
  roster [{n, m(MiB), c(count), cpu(max % of one core in the group)}]
      -> the set of process-groups that together make up TOP_FRAC of total RSS
         OR total CPU (union), plus every "always-show" named creature present.
         Selection is eager here; the client defers removals.
"""
import glob, json, os, re, subprocess, threading, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT       = int(os.environ.get("SPYHOP_PORT", os.environ.get("POND_PORT", "8477")))
HERE       = os.path.dirname(os.path.abspath(__file__))
HTML       = os.path.join(HERE, "spyhop.html")

CLK_TCK    = os.sysconf("SC_CLK_TCK")
PAGE_KB    = os.sysconf("SC_PAGE_SIZE") // 1024
TOP_FRAC   = 0.80            # keep the set covering this fraction of RSS / CPU
MIN_GROUPS = 15              # always show at least this many (pad from next-largest by RSS)
MAX_GROUPS = 30              # never show more than this (keep always-show creatures + largest)
STATE_TTL  = 2.0            # seconds; one real compute shared across viewers
SLOW_TTL   = 8.0            # seconds; docker + netdata refresh cadence
# ---------- creature config ----------
# Which process maps to which creature. `match` is a case-insensitive regex
# tested against the process' display name; `always` pins it into the roster
# even when it isn't among the heaviest by RSS/CPU. Shapes the client can draw:
#   angler, whale, jelly, squid, ray, fish, school, crab
# The client fetches this table (merged with any user config) from /config.json,
# so it is the single source of truth for both pinning and appearance.
DEFAULT_CREATURES = [
    {"match": "spyhop|nuc-pond", "shape": "angler", "hue": 46,  "sat": 85, "lit": 62, "spd": 0.42, "band": [.60, .84], "always": True},
    {"match": "qemu",            "shape": "whale",  "hue": 205, "sat": 28, "lit": 62, "spd": 0.26, "band": [.50, .78], "always": True},
    {"match": "netdata",         "shape": "jelly",  "hue": 286, "sat": 68, "lit": 72, "spd": 0.22, "band": [.16, .82], "always": True},
    {"match": "opencode",        "shape": "squid",  "hue": 32,  "sat": 88, "lit": 62, "spd": 0.70, "band": [.30, .60], "always": True},
    {"match": "foci",            "shape": "ray",    "hue": 250, "sat": 44, "lit": 62, "spd": 0.50, "band": [.55, .82], "always": True},
    {"match": "firefox",         "shape": "fish",   "hue": 24,  "sat": 88, "lit": 60, "spd": 0.70, "band": [.32, .58], "mul": 1.15, "always": True},
    {"match": "claude",          "shape": "school", "hue": 172, "sat": 70, "lit": 63, "spd": 0.95, "band": [.28, .52], "always": True},
    {"match": "^kworker$",       "shape": "school", "hue": 210, "sat": 12, "lit": 55, "spd": 0.70, "band": [.40, .72], "always": True},
    {"match": "pihole",          "shape": "fish",   "hue": 2,   "sat": 78, "lit": 60, "spd": 0.80, "band": [.40, .62], "always": True},
    {"match": "radarr|sonarr|prowlarr|qbittorrent|jackett|lidarr|readarr|bazarr",
                                 "shape": "crab",   "hue": 16,  "sat": 82, "lit": 56, "spd": 0.50, "band": [.93, .98], "always": True},
    {"match": "home|python",       "shape": "fish", "hue": 128, "sat": 55, "lit": 58, "spd": 0.60, "band": [.55, .75]},
    {"match": "docker|containerd", "shape": "fish", "hue": 208, "sat": 48, "lit": 56, "spd": 0.50, "band": [.62, .82]},
]


def _config_path():
    """First existing of: $SPYHOP_CONFIG, ~/.config/spyhop/config.json, ./spyhop.config.json."""
    env = os.environ.get("SPYHOP_CONFIG")
    if env:
        return env
    xdg = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    xdg_cfg = os.path.join(xdg, "spyhop", "config.json")
    if os.path.exists(xdg_cfg):
        return xdg_cfg
    return os.path.join(HERE, "spyhop.config.json")


def load_config():
    """Read the optional user config once. Shape: {creatures: [...], muteAlerts: [...]}.
    A bare list is treated as {creatures: [...]}. Missing or malformed -> {} (defaults only)."""
    path = _config_path()
    try:
        with open(path) as f:
            doc = json.load(f)
    except FileNotFoundError:
        return {}
    except Exception as e:
        print(f"spyhop: ignoring config at {path}: {e}")
        return {}
    if isinstance(doc, list):
        doc = {"creatures": doc}
    if not isinstance(doc, dict):
        print(f"spyhop: ignoring config at {path}: expected an object or a list")
        return {}
    print(f"spyhop: loaded config from {path}")
    return doc


def _compile_union(patterns, label):
    """One case-insensitive regex from a list, skipping (and reporting) any bad pattern.
    Returns None when the list is empty or nothing compiles."""
    good = []
    for p in patterns:
        if not isinstance(p, str):
            continue
        try:
            re.compile(p)
            good.append(p)
        except re.error as e:
            print(f"spyhop: skipping bad {label} regex {p!r}: {e}")
    return re.compile("|".join(good), re.I) if good else None


def _creatures(doc):
    """User creatures (matched first, so they win) followed by the built-in defaults."""
    user = doc.get("creatures", [])
    if not isinstance(user, list):
        print("spyhop: `creatures` must be a list; ignoring it")
        user = []
    user = [c for c in user if isinstance(c, dict) and c.get("match")]
    if user:
        print(f"spyhop: {len(user)} custom creature rule(s)")
    return user + DEFAULT_CREATURES


CONFIG      = load_config()
CREATURES   = _creatures(CONFIG)
# roster-pin regex: every creature flagged `always` (bad patterns skipped)
ALWAYS_RE   = _compile_union([c["match"] for c in CREATURES if c.get("always")], "creature") \
              or re.compile(r"(?!x)x")   # match nothing if somehow empty
# alerts whose netdata name matches this are hidden — no rain, not counted. None = show all.
MUTE_ALERTS = _compile_union(CONFIG.get("muteAlerts") or CONFIG.get("mute_alerts") or [], "muteAlerts")
if MUTE_ALERTS:
    print("spyhop: muting alerts matching /%s/i" % MUTE_ALERTS.pattern)
# interpreters whose comm ("python3", "java", …) is uninformative — dig a real name out of argv
GENERIC_PREFIX = ("python", "node", "java", "php", "ruby", "perl", "mono", "dotnet")
GENERIC_EXACT  = {"sh", "bash", "nodejs", "deno", "bun", "tsx"}
SCRIPT_EXT     = re.compile(r"\.(py|js|mjs|cjs|ts|php|rb|pl|jar|sh)$", re.I)
# script basenames too generic to be useful — fall back to the containing project/dir name
GENERIC_SCRIPT = {"main", "app", "server", "run", "manage", "cli", "index", "__main__",
                  "start", "serve", "bot", "daemon", "worker", "service", "wsgi", "asgi",
                  "gunicorn", "uvicorn", "entrypoint", "launch"}
FLAG_WITH_VALUE = {"-cp", "-classpath", "--class-path", "-p", "--module-path", "--config",
                   "--add-opens", "--add-exports", "--add-reads", "--add-modules",
                   "--patch-module", "--module", "-splash"}


def _script_token(toks):
    skip = False
    for tk in toks:
        if skip:
            skip = False; continue
        if tk in FLAG_WITH_VALUE:
            skip = True; continue
        if tk.startswith("-"):
            continue
        return tk
    return None


def display_name(comm, pid):
    """Best human name for a process; None for kernel threads we don't surface."""
    name0 = comm.rstrip(":").strip()
    if name0.startswith("kworker"):
        return "kworker"                              # fold the swarm of kernel workers into one shoal
    try:
        raw = open(f"/proc/{pid}/cmdline", "rb").read()
    except OSError:
        return name0 or None
    if not raw.strip(b"\0"):
        return None                                   # other kernel threads — skip
    args = [a for a in raw.decode("utf-8", "replace").split("\0") if a]
    cl = " ".join(args).lower()
    if ".claude/" in cl:                              # claude-code shell wrappers -> the claude shoal
        return "claude"
    if "firefox" in cl:                               # fold content/extension procs into one
        return "firefox"
    if "netdata" in cl and ("plugin" in cl or "/netdata/" in cl):
        return "netdata"
    low = name0.lower()
    if not (low.startswith(GENERIC_PREFIX) or low in GENERIC_EXACT):
        return name0
    toks = args[1:]
    if low.startswith("python") and "-m" in toks:
        i = toks.index("-m")
        if i + 1 < len(toks):
            return toks[i + 1].split(".")[-1]
    if low.startswith("java") and "-jar" in toks:
        i = toks.index("-jar")
        if i + 1 < len(toks):
            return re.sub(r"\.jar$", "", os.path.basename(toks[i + 1]), flags=re.I)
    tk = _script_token(toks)
    if not tk:
        return name0
    if low.startswith("java") and "/" not in tk and "." in tk:
        return tk.split(".")[-1]                       # main class com.foo.Bar -> Bar
    base = SCRIPT_EXT.sub("", os.path.basename(tk))
    if base.lower() in GENERIC_SCRIPT:                  # main.py -> the project/dir it lives in or runs from
        parent = os.path.basename(os.path.dirname(tk)) if "/" in tk else ""
        if not parent:
            try:
                parent = os.path.basename(os.readlink(f"/proc/{pid}/cwd"))
            except OSError:
                parent = ""
        if parent and parent not in (".", ""):
            return parent
    return base or name0


def cpu_temp():
    for h in glob.glob("/sys/class/hwmon/hwmon*"):
        try:
            if open(f"{h}/name").read().strip() not in ("coretemp", "k10temp", "zenpower"):
                continue
            inp = f"{h}/temp1_input"
            for lab in glob.glob(f"{h}/temp*_label"):
                if any(w in open(lab).read().lower() for w in ("package", "tctl")):
                    inp = lab.replace("_label", "_input"); break
            return round(int(open(inp).read()) / 1000)
        except (OSError, ValueError):
            continue
    for z in glob.glob("/sys/class/thermal/thermal_zone*"):
        try:
            if open(f"{z}/type").read().strip() == "x86_pkg_temp":
                return round(int(open(f"{z}/temp").read()) / 1000)
        except (OSError, ValueError):
            continue
    return 0


def disk_max_pct():
    try:
        out = subprocess.run(["df", "-P"], capture_output=True, text=True, timeout=4).stdout
    except Exception:
        return 0
    m = 0
    for line in out.splitlines()[1:]:
        f = line.split()
        if len(f) >= 5 and f[0].startswith("/dev/"):
            try:
                m = max(m, int(f[4].rstrip("%")))
            except ValueError:
                pass
    return m

_lock, _state_lock = threading.Lock(), threading.Lock()
_prev_cpu = None
_prev_procs, _prev_procs_t = {}, 0.0
_slow = {"t": 0, "alarms": 0, "containers": 0, "alerts": [], "disk": 0}
_state = {"t": 0, "data": None}
_nd_ip = None


# ---------- signals ----------
def cpu_busy_pct():
    global _prev_cpu
    with open("/proc/stat") as f:
        p = [float(x) for x in f.readline().split()[1:]]
    idle, total = p[3] + (p[4] if len(p) > 4 else 0), sum(p)
    prev, _prev_cpu = _prev_cpu, (total, idle)
    if not prev:
        return None
    dt, di = total - prev[0], idle - prev[1]
    return round(max(0.0, min(100.0, (dt - di) / dt * 100)), 1) if dt > 0 else None


def meminfo():
    m = {}
    with open("/proc/meminfo") as f:
        for line in f:
            k, v = line.split(":")
            m[k] = int(v.strip().split()[0])
    sw = m.get("SwapTotal", 0)
    return (round((m["MemTotal"] - m["MemAvailable"]) / m["MemTotal"] * 100),
            round((sw - m.get("SwapFree", 0)) / sw * 100) if sw else 0)


def uptime_str():
    with open("/proc/uptime") as f:
        s = float(f.readline().split()[0])
    return f"{int(s // 86400)}d {int((s % 86400) // 3600)}h"


def loadavgs():
    with open("/proc/loadavg") as f:
        a = f.readline().split()
    return round(float(a[0]), 2), round(float(a[1]), 2)     # 1m, 5m


def _sample_procs():
    procs = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/stat") as f:
                s = f.read()
            rp = s.rindex(")")
            comm, rest = s[s.index("(") + 1:rp], s[rp + 2:].split()
            with open(f"/proc/{pid}/statm") as f:
                resident = int(f.read().split()[1])
            procs[pid] = (comm, resident * PAGE_KB, int(rest[11]) + int(rest[12]))
        except (OSError, ValueError, IndexError):
            continue
    return procs


def process_groups():
    """Aggregate by command name: [rss_kb, count, cpu_max%]."""
    global _prev_procs, _prev_procs_t
    now = time.monotonic()
    procs = _sample_procs()
    dt, prev = (now - _prev_procs_t) if _prev_procs_t else 0, _prev_procs
    agg = {}
    for pid, (comm, rss, jif) in procs.items():
        name = display_name(comm, pid)
        if not name:
            continue
        cpu = 0.0
        if dt > 0 and pid in prev and jif > prev[pid]:
            cpu = (jif - prev[pid]) / CLK_TCK / dt * 100
        a = agg.setdefault(name, [0, 0, 0.0])
        a[0] += rss; a[1] += 1; a[2] = max(a[2], cpu)
    _prev_procs = {pid: v[2] for pid, v in procs.items()}
    _prev_procs_t = now
    return agg


def _cover(items, key):
    """Smallest prefix (sorted desc by key) that covers TOP_FRAC of the total."""
    total = sum(key(i) for i in items)
    if total <= 0:
        return set()
    keep, cum = set(), 0.0
    for it in sorted(items, key=key, reverse=True):
        keep.add(it["n"]); cum += key(it)
        if cum >= TOP_FRAC * total:
            break
    return keep


def roster():
    groups = sorted(({"n": n, "m": kb // 1024, "c": c, "cpu": round(cpu, 1)}
                     for n, (kb, c, cpu) in process_groups().items()),
                    key=lambda g: -g["m"])
    always = {g["n"] for g in groups if ALWAYS_RE.search(g["n"])}
    keep = _cover(groups, lambda g: g["m"]) | _cover(groups, lambda g: g["cpu"]) | always
    sel = [g for g in groups if g["n"] in keep]
    for g in groups:                                        # pad up to the minimum with the next-largest
        if len(sel) >= MIN_GROUPS:
            break
        if g["n"] not in keep:
            sel.append(g)
    sel.sort(key=lambda g: (g["n"] not in always, -g["m"]))  # keep always-show creatures through the cap
    return sel[:MAX_GROUPS]


def netdata_ip():
    global _nd_ip
    if _nd_ip:
        return _nd_ip
    try:
        names = subprocess.run(["docker", "ps", "--format", "{{.Names}}"],
                               capture_output=True, text=True, timeout=4).stdout
        cname = next(n for n in names.splitlines() if "netdata" in n)
        ip = subprocess.run(["docker", "inspect", "-f",
                             "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}", cname],
                            capture_output=True, text=True, timeout=4).stdout.split()
        _nd_ip = ip[0] if ip else None
    except Exception:
        _nd_ip = None
    return _nd_ip


def slow_signals():
    global _nd_ip
    now = time.time()
    with _lock:
        if now - _slow["t"] < SLOW_TTL:
            return _slow["alarms"], _slow["containers"], _slow["alerts"], _slow["disk"]
        alarms, containers, alerts, disk = _slow["alarms"], _slow["containers"], list(_slow["alerts"]), _slow["disk"]
    disk = disk_max_pct()
    try:
        containers = len(subprocess.run(["docker", "ps", "-q"],
                         capture_output=True, text=True, timeout=4).stdout.split())
    except Exception:
        pass
    ip = netdata_ip()
    if ip:
        try:
            with urllib.request.urlopen(f"http://{ip}:19999/api/v1/alarms", timeout=2) as r:
                raw = json.load(r).get("alarms", {})
            alerts = []
            for k, v in raw.items():
                if v.get("status") not in ("WARNING", "CRITICAL"):
                    continue
                name = v.get("name", k)
                if MUTE_ALERTS and MUTE_ALERTS.search(name):
                    continue                                  # muted via config -> no rain, not counted
                alerts.append({"n": name, "s": v.get("status", ""),
                               "v": round(v.get("value") or 0, 1), "u": v.get("units", "")})
            alarms = len(alerts)
        except Exception:
            _nd_ip = None
    with _lock:
        _slow.update({"t": now, "alarms": alarms, "containers": containers, "alerts": alerts, "disk": disk})
    return alarms, containers, alerts, disk


def build_state():
    cpu = cpu_busy_pct()
    mem_pct, swap_pct = meminfo()
    load1, load5 = loadavgs()
    alarms, containers, alerts, disk = slow_signals()
    return {"t": int(time.time()), "host": os.uname().nodename, "uptime": uptime_str(),
            "cpu": cpu if cpu is not None else 0.0, "load": load1, "load5": load5,
            "cores": os.cpu_count(), "memPct": mem_pct, "swapPct": swap_pct, "temp": cpu_temp(),
            "disk": disk, "alarms": alarms, "alerts": alerts, "containers": containers, "roster": roster()}


def cached_state():
    with _state_lock:
        if not _state["data"] or time.time() - _state["t"] >= STATE_TTL:
            _state["data"], _state["t"] = build_state(), time.time()
        return _state["data"]


# ---------- http ----------
class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        try:
            if path in ("/", "/index.html"):
                with open(HTML, "rb") as f:
                    self._send(200, f.read(), "text/html; charset=utf-8")
            elif path == "/state.json":
                self._send(200, json.dumps(cached_state()), "application/json")
            elif path == "/config.json":
                self._send(200, json.dumps({"creatures": CREATURES}), "application/json")
            elif path == "/health":
                self._send(200, "ok", "text/plain")
            else:
                self._send(404, "not found", "text/plain")
        except BrokenPipeError:
            pass
        except Exception as e:
            self._send(500, f"error: {e}", "text/plain")

    def log_message(self, *a):
        pass


def main():
    cpu_busy_pct()
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"spyhop serving on http://0.0.0.0:{PORT}  ({len(CREATURES)} creature rules · Ctrl-C to stop)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")


if __name__ == "__main__":
    main()
