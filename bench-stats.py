#!/usr/bin/env python3
# Stats over bench-results.json, grouped by experiment (label + commit + flags).
# Reports the same-session delta (cpu - baseline) where recorded — that's the
# portable, drift-cancelled number. Absolute cpu is shown as context only.
# Usage: ./bench-stats.py [results.json]
import json, sys, statistics
from collections import OrderedDict

path = sys.argv[1] if len(sys.argv) > 1 else "bench-results.json"
runs = json.load(open(path)).get("runs", [])

groups = OrderedDict()
for r in runs:
    key = (r["label"], r.get("commit"), r.get("dirty"),
           json.dumps(r.get("flags", {}), sort_keys=True))
    groups.setdefault(key, []).append(r)

hdr = f"{'label':26} {'commit':8} {'n':>2} {'Δpp':>7} {'Δsd':>5} {'cpu%':>6} {'ref%':>6}"
print(hdr); print("-" * len(hdr))
for (label, commit, dirty, flags), rs in groups.items():
    n = len(rs)
    cpus = [r["cpu"] for r in rs]
    deltas = [r["delta"] for r in rs if "delta" in r]
    refs = [r["baseline_cpu"] for r in rs if "baseline_cpu" in r]
    tag = (commit or "?") + ("*" if dirty else "")
    dmean = f"{statistics.mean(deltas):+.2f}" if deltas else "  —"
    dsd = f"{statistics.pstdev(deltas):.2f}" if len(deltas) > 1 else "  —"
    refm = f"{statistics.mean(refs):.1f}" if refs else "  —"
    print(f"{label[:26]:26} {tag[:8]:8} {n:>2} {dmean:>7} {dsd:>5} {statistics.mean(cpus):>6.1f} {refm:>6}")
    print(f"    flags: {flags}")
