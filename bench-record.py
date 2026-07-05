#!/usr/bin/env python3
# Append one benchmark record to bench-results.json (a {"runs":[...]} array).
# Called by bench.sh. Captures the measured CPU plus the settings that produced it:
# the resolved render flags (server config `render` <- URL query overrides) and the
# git commit — so code-level optimizations (strict wins, no flag) are tracked by commit,
# and trade-offs (fps/dpr/wiggle/… and future flags like bitmapclouds) by `flags`.
import json, os, sys
from urllib.parse import parse_qs

path, time, label, host, window, query, cpu, commit, dirty, cfg_json, note = sys.argv[1:12]
ref_cpu = sys.argv[12] if len(sys.argv) > 12 else ""
delta   = sys.argv[13] if len(sys.argv) > 13 else ""
rss_mb  = sys.argv[14] if len(sys.argv) > 14 else ""

render = {}
try:
    render = (json.loads(cfg_json) or {}).get("render", {}) or {}
except Exception:
    pass

q = parse_qs(query.lstrip("?"), keep_blank_values=True)
def coerce(v):
    if v in ("true", "True"): return True
    if v in ("false", "False"): return False
    try: return int(v)          # numeric strings (incl. "1"/"0") stay numeric, not bool
    except ValueError:
        try: return float(v)
        except ValueError: return v

flags = dict(render)                       # start from resolved server render config
for k, vals in q.items():                  # URL query overrides / adds (fps, dpr, wiggle, bench, off, future flags…)
    if k in ("debug", "shot"):             # pure dev toggles, not scene-defining
        continue
    flags[k] = coerce(vals[0])

rec = {
    "time": time, "label": label, "cpu": float(cpu), "host": host,
    "window_s": int(window), "query": query, "flags": flags,
    "commit": commit, "dirty": (dirty == "true"),
}
if note:
    rec["note"] = note
if ref_cpu:
    rec["baseline_cpu"] = float(ref_cpu)      # same-session reference (all flags at original)
if delta:
    rec["delta"] = float(delta)               # cpu - baseline_cpu; the portable, drift-cancelled number
if rss_mb:
    rec["rss_mb"] = float(rss_mb)             # summed WebKit render-process RSS (MB); use deltas across a sweep

data = {"runs": []}
if os.path.exists(path):
    try:
        loaded = json.load(open(path))
        if isinstance(loaded, dict) and isinstance(loaded.get("runs"), list):
            data = loaded
    except Exception:
        pass
data["runs"].append(rec)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print("  recorded: %s -> %s%%  {%s}" % (label, cpu, ", ".join(f"{k}={v}" for k, v in flags.items())))
