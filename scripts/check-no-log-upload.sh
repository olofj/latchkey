#!/usr/bin/env bash
# R1 acceptance check: does the app talk to Tailscale's hosted log service?
#
#   scripts/check-no-log-upload.sh [seconds] [--expect-upload]
#   scripts/check-no-log-upload.sh --replay <endpoints-file> [--expect-upload]
#
# Launches the installed simulator build fresh, samples the app process's
# sockets with lsof every half second, and fails if any of them connects to an
# address of log.tailscale.com or log.tailscale.io.
#
# "No upload" needs POSITIVE evidence too (review, 2026-09-23). A process that
# crashed at t+1 s, or a node that never started, makes no connections
# either, and an instrument that saw nothing at all used to print the same
# "ok" as one that watched a live node for five minutes. So the verdict also
# requires that the pid is still alive at the end, and that at least one
# connection to something the node is EXPECTED to reach was observed: the
# control plane (a fresh node registers there to get its login link, whether
# or not it is authenticated) or a DERP relay. Each failure has its own
# message, so a crash, a node that never came up and a real upload read
# differently.
#
# --expect-upload inverts the verdict. It exists to validate the instrument:
# run it once against a build that DOES upload and confirm it sees the
# connections. A detector that has never been shown to catch an upload cannot
# certify that uploads have stopped.
#
# --replay skips the launch and the sampling and judges a recorded endpoints
# file (one remote `addr:port` per line, as the sampling writes them): the
# verdict logic, runnable without a simulator. Liveness cannot be replayed
# and is reported as not judged.
#
# Why lsof rather than a proxy or packet capture: the simulator shares the
# host's network stack, so the app's sockets are ordinary host sockets owned by
# its pid, and lsof sees them without privileges. logtail's HTTP client keeps
# connections alive between batches, so a 0.5 s sample catches them.
#
# Scope: `lsof -p` watches ONE process. The node -- tsnet, and logtail with it
# -- lives in the app process, which is the process this check is about.
# WebKit's networking runs in its own com.apple.WebKit.Networking process and
# is outside what this instrument can see; the page's traffic is the offline
# suite's business (R10).
set -euo pipefail

SECONDS_TO_WATCH=300
EXPECT_UPLOAD=0
REPLAY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --expect-upload) EXPECT_UPLOAD=1 ;;
        --replay) REPLAY=${2:-}; [[ -n "$REPLAY" ]] || { echo "error: --replay needs a file" >&2; exit 2; }; shift ;;
        [0-9]*) SECONDS_TO_WATCH=$1 ;;
        *) echo "usage: $0 [seconds] [--expect-upload] | --replay <endpoints-file> [--expect-upload]" >&2; exit 2 ;;
    esac
    shift
done
BUNDLE="net.lixom.latchkey"
LOG_HOSTS=(log.tailscale.com log.tailscale.io)
# What a live node is expected to reach. The control plane's ranges are from
# the same measurement as the log ranges below; DERP relays come from the
# published DERP map, fetched best-effort (the control plane alone is enough
# evidence: a node reaches it before it reaches any DERP).
CONTROL_HOSTS=(controlplane.tailscale.com)
CONTROL_RANGES_RE='(192\.200\.0\.[0-9]+|2606:b740:49:[0-9a-f:]*)'
# log.tailscale.com's own ranges, belt and braces under the resolved addresses.
LOG_RANGES_RE='(199\.165\.136\.[0-9]+|2606:b740:1:20:[0-9a-f:]*)'

say() { printf '::: %s\n' "$*"; }

resolve() {  # hosts... -> addresses, both families
    local h rr
    for h in "$@"; do
        for rr in A AAAA; do
            dig +short "$h" "$rr" 2>/dev/null | grep -E '^[0-9a-fA-F:.]+$' || true
        done
    done
}

LOG_ADDRS=$(mktemp); CONTROL_ADDRS=$(mktemp); DERP_ADDRS=$(mktemp); SEEN=$(mktemp); EXPECTED=$(mktemp)
trap 'rm -f "$LOG_ADDRS" "$CONTROL_ADDRS" "$DERP_ADDRS" "$SEEN" "$EXPECTED"' EXIT

resolve "${LOG_HOSTS[@]}" > "$LOG_ADDRS"
if [[ ! -s "$LOG_ADDRS" ]]; then
    echo "error: could not resolve any log host address; the check would prove nothing" >&2
    exit 2
fi
say "log host addresses: $(tr '\n' ' ' < "$LOG_ADDRS")"
resolve "${CONTROL_HOSTS[@]}" > "$CONTROL_ADDRS"
say "control plane addresses: $(tr '\n' ' ' < "$CONTROL_ADDRS")(plus the ranges 192.200.0.0/24, 2606:b740:49::/48)"
curl -fsS --max-time 10 https://controlplane.tailscale.com/derpmap/default 2>/dev/null | python3 -c '
import json, sys
for region in json.load(sys.stdin).get("Regions", {}).values():
    for node in region.get("Nodes", []):
        for key in ("IPv4", "IPv6"):
            value = node.get(key)
            if value and value != "none":
                print(value)
' > "$DERP_ADDRS" 2>/dev/null || : > "$DERP_ADDRS"
if [[ -s "$DERP_ADDRS" ]]; then
    say "DERP relay addresses: $(wc -l < "$DERP_ADDRS" | tr -d ' ') (from the published DERP map)"
else
    say "DERP map not fetched; the control plane alone will have to show the node was live"
fi

# ------------------------------------------------------------- sampling --
ALIVE=1
samples=0
if [[ -n "$REPLAY" ]]; then
    [[ -r "$REPLAY" ]] || { echo "error: cannot read $REPLAY" >&2; exit 2; }
    cp "$REPLAY" "$SEEN"
    say "replaying $(wc -l < "$SEEN" | tr -d ' ') recorded endpoint lines from $REPLAY (no process: liveness is not judged)"
else
    xcrun simctl terminate booted "$BUNDLE" >/dev/null 2>&1 || true
    PID=$(xcrun simctl launch booted "$BUNDLE" | awk -F': ' '{print $2}')
    if [[ -z "$PID" ]]; then
        echo "error: could not launch $BUNDLE" >&2
        exit 2
    fi
    say "watching pid $PID for ${SECONDS_TO_WATCH}s"
    end=$(( $(date +%s) + SECONDS_TO_WATCH ))
    while [[ $(date +%s) -lt $end ]]; do
        # A process that is gone cannot be sampled: stop at once and say so
        # below, rather than sampling nothing for the rest of the watch.
        if ! kill -0 "$PID" 2>/dev/null; then
            ALIVE=0
            say "pid $PID is gone after $samples samples (about $(( samples / 2 ))s)"
            break
        fi
        # NAME column looks like  10.0.0.5:51234->199.165.136.100:443 (ESTABLISHED)
        lsof -nP -a -p "$PID" -i 2>/dev/null | awk 'NR>1 {print $9}' | grep -- '->' \
            | sed -E 's/.*->//' >> "$SEEN" || true
        samples=$((samples + 1))
        # Re-resolve every ~10 s. The log hosts rotate between sibling addresses
        # (log.tailscale.com answered .100/::102 in one run and .101/::103 in the
        # next), so an address set taken once at startup can miss an upload to a
        # sibling the app happened to resolve.
        if (( samples % 20 == 0 )); then
            resolve "${LOG_HOSTS[@]}" >> "$LOG_ADDRS"
        fi
        sleep 0.5
    done
    if [[ $ALIVE -eq 1 ]] && ! kill -0 "$PID" 2>/dev/null; then ALIVE=0; fi
fi
sort -u -o "$LOG_ADDRS" "$LOG_ADDRS"

say "$samples samples; distinct remote endpoints:"
sort -u "$SEEN" | sed 's/^/      /'

# -------------------------------------------------------------- verdict --
# An address among the endpoints. IPv6 remotes appear bracketed: [2606:...]:443
saw_addr() { grep -qE "(^|\[)${1//./\\.}(\]|:)" "$SEEN"; }

hits=0
while read -r addr; do
    [[ -n "$addr" ]] || continue
    if saw_addr "$addr"; then
        say "CONNECTION TO LOG SERVICE: $addr"
        hits=$((hits + 1))
    fi
done < "$LOG_ADDRS"
# Checked against the control plane, which lives in 192.200.0.0/24 and
# 2606:b740:49::/48, so the log ranges do not false-positive on node traffic.
if grep -qE "(^|\[)${LOG_RANGES_RE}(\]|:)" "$SEEN"; then
    say "CONNECTION TO LOG SERVICE RANGE: $(grep -oE "(^|\[)${LOG_RANGES_RE}" "$SEEN" | tr -d '[' | sort -u | tr '\n' ' ')"
    hits=$((hits + 1))
fi

# The positive evidence: what the node reached that it was expected to reach.
: > "$EXPECTED"
while read -r addr; do
    [[ -n "$addr" ]] || continue
    if saw_addr "$addr"; then echo "control plane $addr" >> "$EXPECTED"; fi
done < "$CONTROL_ADDRS"
grep -oE "(^|\[)${CONTROL_RANGES_RE}" "$SEEN" | tr -d '[' | sort -u \
    | sed 's/^/control plane (by range) /' >> "$EXPECTED" || true
while read -r addr; do
    [[ -n "$addr" ]] || continue
    if saw_addr "$addr"; then echo "DERP $addr" >> "$EXPECTED"; fi
done < "$DERP_ADDRS"
sort -u -o "$EXPECTED" "$EXPECTED"
expected=$(grep -c . "$EXPECTED" || true)

if [[ $EXPECT_UPLOAD -eq 1 ]]; then
    if [[ $hits -gt 0 ]]; then
        say "ok: the instrument sees the upload (validation run)"
        exit 0
    fi
    say "FAIL: expected an upload and saw none -- the instrument cannot be trusted"
    exit 1
fi
if [[ $hits -gt 0 ]]; then
    say "FAIL: the app connected to Tailscale's log service"
    exit 1
fi
if [[ -z "$REPLAY" && $ALIVE -eq 0 ]]; then
    say "FAIL: the app process did not survive the watch (gone after $samples samples). A dead"
    say "      process makes no connections, so 'no upload' is not evidence here; look for a crash."
    exit 1
fi
if [[ $expected -eq 0 ]]; then
    say "FAIL: the instrument saw NO control-plane or DERP connection. Either the node never came"
    say "      up (so nothing, uploads included, was attempted) or lsof watched the wrong process."
    say "      That is not evidence of anything. Distinct endpoints seen: $(sort -u "$SEEN" | grep -c . || true)"
    exit 1
fi
if [[ -n "$REPLAY" ]]; then
    say "ok: no connection to ${LOG_HOSTS[*]} in the recording, from a node that reached:"
else
    say "ok: no connection to ${LOG_HOSTS[*]} in ${SECONDS_TO_WATCH}s, from a node that stayed up and reached:"
fi
sed 's/^/      /' "$EXPECTED"
