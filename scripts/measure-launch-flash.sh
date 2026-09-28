#!/usr/bin/env bash
# F21: record the simulator while one session test drives the real pinned
# bundle through a cold launch, then print the per-frame mean brightness so
# a flash is a number rather than something someone has to watch for.
#
#   scripts/measure-launch-flash.sh [--build] [TEST] [OUT.mp4]
#
# TEST defaults to CalmLaunchTests/testTheRealDashboardNeverPaintsItsDarkShellFirst,
# the F21 test: a cold launch of the signed-out dashboard with the fake
# gateway holding each asset 50 ms, since over bare loopback the bundle boots
# before its shell gets a frame on screen. Its control,
# CalmLaunchTests/testWithoutTheCalmShellTheRealDashboardPaintsDarkFirst, is the
# same launch with the fix off: the "before". OUT defaults to
# app/build/launch-flash-<timestamp>.mp4, with the per-frame numbers beside
# it as .csv.
#
# Needs ffprobe (brew install ffmpeg). The simulator is SIM_NAME as for
# scripts/test-session.sh (default "iPhone 17"). Wrap it as the suites are
# wrapped when the simulators are shared.
#
# Printed at the end: the darkest frame and, for every run of frames below
# DARK (mean luma, default 96 of 255) that starts after the first bright
# frame, when it began and how long it lasted. A white page area is about
# 200 and a solid dark shell about 25-35 (whole-screen mean, status bar
# included), so the threshold separates the two with room on both sides.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD=()
[[ "${1:-}" == "--build" ]] && { BUILD=(--build); shift; }
TEST="${1:-CalmLaunchTests/testTheRealDashboardNeverPaintsItsDarkShellFirst}"
OUT="${2:-$ROOT/app/build/launch-flash-$(date +%Y%m%d-%H%M%S).mp4}"
DARK="${DARK:-96}"
SIM_NAME="${SIM_NAME:-iPhone 17}"
command -v ffprobe >/dev/null || { echo "error: ffprobe is needed (brew install ffmpeg)" >&2; exit 1; }

UDID=$(xcrun simctl list devices available -j | python3 -c "
import json, sys
for devs in json.load(sys.stdin)['devices'].values():
    for d in devs:
        if d['name'] == '$SIM_NAME':
            print(d['udid']); sys.exit(0)
sys.exit(1)") || { echo "error: no simulator named $SIM_NAME" >&2; exit 1; }
xcrun simctl bootstatus "$UDID" -b >/dev/null
mkdir -p "$(dirname "$OUT")"

xcrun simctl io "$UDID" recordVideo --codec h264 --force "$OUT" > /dev/null 2>&1 &
REC=$!
trap 'kill -INT $REC 2>/dev/null; wait $REC 2>/dev/null || true' EXIT
sleep 1
RC=0
# `${BUILD[@]+…}`: an empty array is "unbound" to the system bash 3.2 under -u.
SIM_NAME="$SIM_NAME" ONLY_TESTS="$TEST" "$ROOT/scripts/test-session.sh" ${BUILD[@]+"${BUILD[@]}"} || RC=$?
sleep 1
kill -INT "$REC"; wait "$REC" 2>/dev/null || true
trap - EXIT
[[ -s "$OUT" ]] || { echo "error: no recording at $OUT" >&2; exit 1; }
[[ $RC -eq 0 ]] || echo "note: the test run exited $RC; the recording is analysed anyway"

CSV="${OUT%.mp4}.csv"
ffprobe -v error -f lavfi -i "movie=$OUT,signalstats" \
    -show_entries frame=pts_time:frame_tags=lavfi.signalstats.YAVG -of csv=p=0 > "$CSV"
python3 - "$CSV" "$DARK" "$OUT" <<'EOF'
import sys
# ffprobe may end a row with a trailing comma (a third, empty field).
rows = []
for line in open(sys.argv[1]):
    fields = [f for f in line.strip().split(",") if f]
    if len(fields) >= 2:
        rows.append((float(fields[0]), float(fields[1])))
dark = float(sys.argv[2])
print("recording: %s (%d frames, %.1f s)" % (sys.argv[3], len(rows), rows[-1][0] - rows[0][0] if rows else 0))
if not rows:
    sys.exit(1)
t_min, y_min = min(rows, key=lambda r: r[1])
print("darkest frame: mean luma %.1f at %.2f s" % (y_min, t_min))
# Runs of dark frames after the first bright one: a flash, not the launch screen.
first_bright = next((t for t, y in rows if y >= dark), None)
runs, start, prev = [], None, None
for t, y in rows:
    if first_bright is None or t < first_bright:
        continue
    if y < dark and start is None:
        start, low = t, y
    elif y < dark:
        low = min(low, y)
    elif start is not None:
        runs.append((start, t - start, low)); start = None
    prev = t
if start is not None:
    runs.append((start, (prev or start) - start, low))
if runs:
    print("dark runs (mean luma < %g) after the first bright frame:" % dark)
    for s, d, low in runs:
        print("  %.2f s: %d ms, darkest %.1f" % (s, round(d * 1000), low))
    print("total dark: %d ms in %d run(s)" % (round(sum(d for _, d, _ in runs) * 1000), len(runs)))
else:
    print("no dark run after the first bright frame")
EOF
