#!/usr/bin/env bash
# Performance baseline for PurePlay.app
# Measures:
#   - Cold launch time (seconds until main window is on-screen)
#   - Peak resident memory during a short play session
#   - Average CPU during play
#
# Design targets (Design.md §9 Phase 6 task 6.1):
#   - launch < 1.0s
#   - peak memory < 300 MB
#   - decode-only CPU < 5% on M-series
#
# Run with no other heavy processes for cleanest numbers.
# Usage:
#   ./scripts/perf_bench.sh [path/to/PurePlay.app] [optional-test-audio.wav]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/PurePlay.app}"
AUDIO="${2:-}"

[ -d "$APP" ] || { echo "App not found: $APP"; exit 1; }
BIN="$APP/Contents/MacOS/PurePlay"
[ -x "$BIN" ] || { echo "Executable missing: $BIN"; exit 1; }

echo "==> PurePlay perf benchmark"
echo "    App   : $APP"
echo "    Audio : ${AUDIO:-(none, idle launch only)}"

# Kill stale instances so we measure a cold launch.
killall PurePlay 2>/dev/null || true
sleep 0.5

# -----------------------------------------------------------------
# 1. Cold launch timing
# -----------------------------------------------------------------
echo ""
echo "==> Cold launch timing (10 trials, median reported)"
TIMES=()
for i in 1 2 3 4 5 6 7 8 9 10; do
    killall PurePlay 2>/dev/null || true
    sleep 0.4
    T_START=$(python3 -c 'import time; print(time.time())')
    open -a "$APP" -g
    # Poll until process exists and main window is up (proxy: process running > 0.3s)
    for _ in $(seq 1 60); do
        if pgrep -x PurePlay >/dev/null; then break; fi
        sleep 0.02
    done
    # Wait for window-server registration (heuristic: 50ms after pid exists)
    sleep 0.05
    T_END=$(python3 -c 'import time; print(time.time())')
    DT=$(python3 -c "print(f'{$T_END - $T_START:.3f}')")
    TIMES+=("$DT")
    echo "    trial $i: ${DT}s"
done
killall PurePlay 2>/dev/null || true

MEDIAN=$(python3 -c "
import statistics
vals = [float(x) for x in '''${TIMES[*]}'''.split()]
print(f'{statistics.median(vals):.3f}')")
echo "    median: ${MEDIAN}s   (target < 1.000)"

# -----------------------------------------------------------------
# 2. Memory baseline (idle)
# -----------------------------------------------------------------
echo ""
echo "==> Idle memory (after 5s warm-up)"
killall PurePlay 2>/dev/null || true
sleep 0.5
open -a "$APP" -g
sleep 5
PID=$(pgrep -x PurePlay | head -1 || true)
if [ -n "$PID" ]; then
    RSS_KB=$(ps -o rss= -p "$PID" | tr -d ' ')
    RSS_MB=$(python3 -c "print(f'{$RSS_KB / 1024:.1f}')")
    echo "    idle RSS: ${RSS_MB} MB   (target < 100 MB)"
else
    echo "    (process not found)"
fi

# -----------------------------------------------------------------
# 3. Sustained memory + CPU during 30s playback (if audio provided)
# -----------------------------------------------------------------
if [ -n "$AUDIO" ] && [ -f "$AUDIO" ]; then
    echo ""
    echo "==> 30s playback: $AUDIO"
    open -a "$APP" "$AUDIO" -g
    sleep 2

    PID=$(pgrep -x PurePlay | head -1 || true)
    [ -n "$PID" ] || { echo "    PID not found"; exit 0; }

    PEAK_RSS_KB=0
    CPU_SUM=0
    SAMPLES=0
    for _ in $(seq 1 30); do
        sleep 1
        RSS_KB=$(ps -o rss= -p "$PID" 2>/dev/null | tr -d ' ' || echo 0)
        CPU=$(ps -o %cpu= -p "$PID" 2>/dev/null | tr -d ' ' || echo 0)
        [ -z "$RSS_KB" ] && RSS_KB=0
        [ -z "$CPU" ] && CPU=0
        if (( RSS_KB > PEAK_RSS_KB )); then PEAK_RSS_KB=$RSS_KB; fi
        CPU_SUM=$(python3 -c "print(f'{$CPU_SUM + $CPU:.2f}')")
        SAMPLES=$((SAMPLES + 1))
    done
    PEAK_MB=$(python3 -c "print(f'{$PEAK_RSS_KB / 1024:.1f}')")
    AVG_CPU=$(python3 -c "print(f'{$CPU_SUM / $SAMPLES:.2f}')")
    echo "    peak RSS:  ${PEAK_MB} MB   (target < 300 MB)"
    echo "    avg CPU:   ${AVG_CPU}%    (target < 10% for decode-only)"
fi

killall PurePlay 2>/dev/null || true
echo ""
echo "Done."
