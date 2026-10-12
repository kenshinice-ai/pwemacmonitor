#!/bin/zsh
# Every power rail and the memory verdict, this Mac's own counters against Apple's powermetrics.
#
#   Tools/compare-rails.sh               # about two and a half minutes; asks for your password once
#   Tools/compare-rails.sh --warn-only   # skip the simulated "critical" memory level
#   Tools/compare-rails.sh --no-memory   # power only, 105 s, with the CPU at full load for 35 s
#
# It runs, in order: quiet · every core busy · quiet · the GPU busy · quiet · Vision work for the
# Neural Engine · quiet · memory pressure simulated at "warning" · at "critical" · quiet.
# The fans will come up for the CPU and GPU parts. Nothing is installed and nothing is left running.
#
# Two things need root, which is why this is a script you run and not something the app does:
# powermetrics, the reference, and `memory_pressure -S`, which sets the system's memory-pressure
# level by hand for a few seconds. The probe itself (Tools/railprobe) runs as you.
#
# > ⚠️ Close nothing, but expect a moment of housekeeping at the "critical" step.
# > Every app is told memory is critically low for eight seconds; a browser may unload background tabs.
# > They reload when you return to them. Use --warn-only to leave that step out.
#
# Results go to build/rails-<time>/ (ignored by git): probe.tsv, powermetrics.txt, memory.log, and
# report.txt — the comparison Tools/compare-rails-report.py prints at the end.
set -u
cd "$(dirname "$0")/.."

MEMORY=both
[[ "${1:-}" == "--warn-only" ]] && MEMORY=warn
[[ "${1:-}" == "--no-memory" ]] && MEMORY=none
SCALE="${RAILPROBE_SCALE:-1}"
LENGTH=147; PLAN=()
[[ "$MEMORY" == none ]] && { LENGTH=105; PLAN=(power); }
TOTAL=$(( LENGTH * SCALE )); TOTAL=${TOTAL%.*}

WORK="${TMPDIR:-/tmp}/pwe-mac-monitor-build"; mkdir -p "$WORK"
PROBE="$WORK/railprobe"
if [[ ! -x "$PROBE" || Tools/railprobe/main.swift -nt "$PROBE" ]]; then
  echo "▸ building the probe"
  swiftc -O -swift-version 5 Sources/Core/*.swift Tools/railprobe/main.swift \
    -framework IOKit -framework Metal -framework Vision -o "$PROBE" 2>&1 | grep -E "error" && exit 1
fi

OUT="build/rails-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
PM_PID=""; PROBE_PID=""
cleanup() {
  [[ -n "$PROBE_PID" ]] && kill "$PROBE_PID" 2>/dev/null
  [[ -n "$PM_PID" && -z "${RAILS_NO_SUDO:-}" ]] && sudo kill "$PM_PID" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if [[ -z "${RAILS_NO_SUDO:-}" ]]; then
  echo "▸ powermetrics and memory_pressure need your password (asked once):"
  sudo -v || exit 1
  # thermal is here for the record: it prints the pressure level macOS itself reports.
  sudo powermetrics --samplers cpu_power,gpu_power,ane_power,thermal -i 1000 -n $(( TOTAL + 8 )) \
    -o "$OUT/powermetrics.txt" >/dev/null 2>"$OUT/powermetrics.err" &
  PM_PID=$!
  sleep 3      # let it take its first sample before the probe starts counting
fi

"$PROBE" "$OUT/probe.tsv" "${PLAN[@]}" &
PROBE_PID=$!
T0=$(date +%s)

# The probe labels the seconds; this only has to set the level while it is watching.
at() { local wait=$(( $1 * SCALE - ($(date +%s) - T0) )); wait=${wait%.*}; (( wait > 0 )) && sleep "$wait"; }
if [[ "$MEMORY" != none && -z "${RAILS_NO_SUDO:-}" ]]; then
  at 107
  echo "▸ memory pressure: simulating WARNING for 12 s"
  sudo memory_pressure -S -l warn -s 12 > "$OUT/memory.log" 2>&1
  if [[ "$MEMORY" == both ]]; then
    at 123
    echo "▸ memory pressure: simulating CRITICAL for 8 s"
    sudo memory_pressure -S -l critical -s 8 >> "$OUT/memory.log" 2>&1
  fi
fi

wait "$PROBE_PID" 2>/dev/null; PROBE_PID=""
[[ -n "$PM_PID" ]] && { sleep 2; sudo kill "$PM_PID" 2>/dev/null; wait "$PM_PID" 2>/dev/null; PM_PID=""; }

echo
[[ -s "$OUT/powermetrics.txt" ]] && python3 Tools/compare-rails-report.py "$OUT" | tee "$OUT/report.txt"
echo
echo "✓ done. Results: $OUT"
ls -l "$OUT" | awk 'NR > 1 { printf "    %8d bytes  %s\n", $5, $9 }'
[[ -z "${RAILS_NO_SUDO:-}" && ! -s "$OUT/powermetrics.txt" ]] && echo "! powermetrics wrote nothing — see $OUT/powermetrics.err"
exit 0
