#!/bin/bash
# bench.sh — benchmark spyhop render variants.
#
#   ./bench.sh [-u BASEURL] [-n NOTE] [--ref Q] [--no-ref] [--no-record] "label|query" ...
#
# RUN THIS ON THE MAC that renders the wallpaper — the host actually doing the work.
# It swaps the Übersicht widget's URL and samples the com.apple.WebKit render
# processes directly, so the numbers come from the real engine on a real display.
# No ssh, no remote host. Needs: macOS, Übersicht running with the spyhop widget,
# and the desktop revealed (WebKit throttles a covered/occluded page to ~0% CPU).
#
# Defaults come from ./bench.conf (BASE_URL, WIDGET_DIR); CLI overrides.
# Each arg is "label|querystring", e.g.  "fps15|?fps=15"  "sharp|?dpr=2"
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

# ---- defaults (overridable by bench.conf, then CLI) ----
BASE_URL="http://your-host:8477/"                                 # telemetry source the widget fetches
WIDGET_DIR="$HOME/Library/Application Support/Übersicht/widgets"  # local Übersicht widgets dir
RECORD=1              # append each result to bench-results.json
NOTE=""               # optional annotation stored with each record
REF="?bench=1"        # same-session reference (all optimisation flags at original); measured next to each variant
USE_REF=1             # 0 = don't measure a reference / no delta
[ -f "$DIR/bench.conf" ] && source "$DIR/bench.conf"

while [[ "${1:-}" == -* ]]; do case "$1" in
  -u|--url)  BASE_URL="$2"; shift 2;;
  -n|--note) NOTE="$2"; shift 2;;
  --ref) REF="$2"; shift 2;;
  --no-ref) USE_REF=0; shift;;
  --no-record) RECORD=0; shift;;
  *) echo "unknown option: $1" >&2; exit 2;;
esac; done
[ "$#" -ge 1 ] || { echo 'usage: bench.sh [-u URL] [-n NOTE] [--ref Q] [--no-ref] [--no-record] "label|query" ...' >&2; exit 2; }

WFOLDER="spyhop.widget"
WIDGET="$DIR/$WFOLDER/index.jsx"
RESULTS="$DIR/bench-results.json"
HOST="$(scutil --get ComputerName 2>/dev/null || hostname)"   # this machine — recorded with each run

# Append one result: cpu + resolved render flags (config <- query) + git commit + same-session ref delta.
record_result() {   # $1=label $2=query $3=cpu $4=ref_cpu $5=delta $6=rss_mb
  [ "$RECORD" = 1 ] || return 0
  local t commit dirty cfg
  t=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  commit=$(git -C "$DIR" rev-parse --short HEAD 2>/dev/null || echo none)
  if git -C "$DIR" diff --quiet 2>/dev/null && git -C "$DIR" diff --cached --quiet 2>/dev/null; then dirty=false; else dirty=true; fi
  cfg=$(curl -s -m5 "${BASE_URL}config.json" 2>/dev/null || echo '{}')
  python3 "$DIR/bench-record.py" "$RESULTS" "$t" "$1" "$HOST" "$INTERVAL" "$2" "$3" "$commit" "$dirty" "$cfg" "$NOTE" "${4:-}" "${5:-}" "${6:-}" || true
}

INTERVAL="${INTERVAL:-8}"   # measurement window (s) per variant

# One sample of the SYSTEM WebKit framework's render processes: "pid cputime" lines.
# Filters to /System/Library/Frameworks/WebKit.framework — which excludes Safari (it
# runs a *staged* WebKit under /Cryptexes) — and drops the .Networking process.
webkit_snap() {
  ps -Ao pid,time,command | awk 'index(tolower($0),"/system/library/frameworks/webkit.framework") && tolower($0)!~/networking/ {print $1, $2}'
}

# Per-PID CPU over $1 seconds via cputime deltas. Being a delta, it ignores anything
# idle, so a suspended tab contributes 0. VERBOSE=1 prints the per-PID breakdown.
webkit_cpu() {
  local secs="${1:-$INTERVAL}"
  { webkit_snap; echo SEP; sleep "$secs"; webkit_snap; } \
  | awk -v secs="$secs" -v verbose="${VERBOSE:-0}" '
      function tosec(t,   a,n,s){ n=split(t,a,":"); s=a[n]; if(n>=2)s+=a[n-1]*60; if(n>=3)s+=a[n-2]*3600; return s+0 }
      /^SEP$/ { ph=1; next }
      ph==0 { t0[$1]=tosec($2); next }
      ph==1 { if($1 in t0){ d=tosec($2)-t0[$1]; if(d>0){ sum+=d; if(verbose) printf "    pid %-6s %5.1f%%\n",$1,d/secs*100 > "/dev/stderr" } } }
      END { printf "%.1f", sum/secs*100 }'
}

# Summed RSS (MB) of the ocean's System-WebKit render processes (WebContent + GPU).
# Use the delta across variants (e.g. spritePhases sweep) as the memory signal.
webkit_rss() {
  ps -Ao rss,command | awk 'index(tolower($0),"/system/library/frameworks/webkit.framework") && (tolower($0)~/webcontent/ || tolower($0)~/webkit\.gpu/) {sum+=$1} END{printf "%.0f", sum/1024}'
}

push_widget() {  # $1 = full URL; rewrite the widget cleanly (no compounding) then deploy to Übersicht
  local esc="${1//&/\\&}"
  sed "s|const URL = \"[^\"]*\";|const URL = \"${esc}\";|" "$TMPL_BASE" > "$WIDGET"
  mkdir -p "$WIDGET_DIR/$WFOLDER"
  cp "$DIR/$WFOLDER/"* "$WIDGET_DIR/$WFOLDER/"
}

run_bench() {
  TMPL_BASE=$(mktemp); cp "$WIDGET" "$TMPL_BASE"                 # pristine copy to rewrite from each time
  local orig; orig=$(grep -oE 'const URL = "[^"]*"' "$TMPL_BASE" | head -1 | sed -E 's/.*"(.*)".*/\1/')
  echo "base=$BASE_URL   window=${INTERVAL}s"
  echo "occlusion check + active WebKit procs:"
  local base; base=$(VERBOSE=1 webkit_cpu 4)
  echo "  total WebKit now: ${base}%"
  if awk -v b="$base" 'BEGIN{exit !(b+0 < 2.0)}'; then
    echo "⚠ wallpaper looks covered or paused (${base}%) — WebKit throttles the hidden page to ~0." >&2
    echo "  Reveal the desktop (no window over it) and rerun." >&2
    rm -f "$TMPL_BASE"; return 1
  fi
  [ "$USE_REF" = 1 ] && printf "%-26s %8s %8s %8s   ref=%s\n" "VARIANT" "cpu%" "ref%" "delta" "$REF" || printf "%-26s %s\n" "VARIANT" "WebKit %CPU (${INTERVAL}s)"
  for v in "$@"; do
    local lab="${v%%|*}" q="${v#*|}" ref_cpu="" delta=""
    if [ "$USE_REF" = 1 ]; then                                   # paired reference right before the variant, so drift cancels
      push_widget "${BASE_URL}${REF}"; sleep 13; ref_cpu=$(webkit_cpu "$INTERVAL")
    fi
    push_widget "${BASE_URL}${q}"; sleep 13
    local cpu rss; cpu=$(webkit_cpu "$INTERVAL"); rss=$(webkit_rss)
    if [ -n "$ref_cpu" ]; then
      delta=$(awk -v a="$cpu" -v b="$ref_cpu" 'BEGIN{printf "%+.1f", a-b}')
      printf "%-26s %8s %8s %8s %7s\n" "$lab" "$cpu" "$ref_cpu" "$delta" "${rss}M"
    else
      printf "%-26s %8s %7s\n" "$lab" "$cpu" "${rss}M"
    fi
    record_result "$lab" "$q" "$cpu" "$ref_cpu" "$delta" "$rss"
  done
  push_widget "$orig"; echo "(restored widget URL: $orig)"
  rm -f "$TMPL_BASE"
}

run_bench "$@"
