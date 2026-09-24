#!/bin/zsh
# CPU power, this app against Apple's own powermetrics, second by second.
#
#   Tools/compare-powermetrics.sh            # 12 one-second samples, idle or whatever is running
#   Tools/compare-powermetrics.sh --load     # the same with every core pinned for the duration
#
# Needs your password: powermetrics only runs as root. This app never does, which is the point —
# on macOS 27 it reads CPU power from the PMP cluster histograms because the Energy Model
# counters arrive in batches every several minutes (docs/power-rails.md). powermetrics is the
# reference those histograms have to agree with.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/PWE Monitor.app/Contents/MacOS/pwemon"
[[ -x "$APP" ]] || { echo "build first: ./build.sh"; exit 1; }
N=12
TMP=$(mktemp -d)

sudo -v                                    # ask for the password before anything starts

if [[ "${1:-}" == "--load" ]]; then
  for i in $(seq 1 "$(sysctl -n hw.logicalcpu)"); do yes >/dev/null & done
  trap 'kill $(jobs -p) 2>/dev/null' EXIT
  sleep 3
fi

sudo powermetrics --samplers cpu_power -i 1000 -n "$N" 2>/dev/null \
  | awk '/^CPU Power/ {print $3 / 1000}' > "$TMP/pm" &
"$APP" --json --loop 2>/dev/null | head -n "$N" \
  | python3 -c 'import json,sys
for l in sys.stdin: d=json.loads(l); print(d["cpu"]["power_w"], d["power"]["cpu_source"])' > "$TMP/app"
wait %1 2>/dev/null || true

python3 - "$TMP/pm" "$TMP/app" <<'PY'
import sys
pm = [float(x) for x in open(sys.argv[1]) if x.strip()]
app = [l.split() for l in open(sys.argv[2]) if l.strip()]
n = min(len(pm), len(app))
if n == 0: sys.exit("no samples — did powermetrics run?")
print(f"{'powermetrics':>13}  {'PWE Monitor':>12}  source")
for p, (a, src) in zip(pm, app):
    print(f"{p:11.2f} W  {float(a):10.2f} W  {src}")
mp, ma = sum(pm[:n]) / n, sum(float(a) for a, _ in app[:n]) / n
print(f"{'mean':>4} {mp:6.2f} W  {ma:10.2f} W  ({(ma / mp - 1) * 100:+.1f} %)" if mp else "")
PY
rm -rf "$TMP"
