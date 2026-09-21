#!/usr/bin/env bash
# R1 acceptance check: does the app talk to Tailscale's hosted log service?
#
#   scripts/check-no-log-upload.sh [seconds] [--expect-upload]
#
# Launches the installed simulator build fresh, samples the app process's
# sockets with lsof every half second, and fails if any of them connects to an
# address of log.tailscale.com or log.tailscale.io.
#
# --expect-upload inverts the verdict. It exists to validate the instrument:
# run it once against a build that DOES upload and confirm it sees the
# connections. A detector that has never been shown to catch an upload cannot
# certify that uploads have stopped.
#
# Why lsof rather than a proxy or packet capture: the simulator shares the
# host's network stack, so the app's sockets are ordinary host sockets owned by
# its pid, and lsof sees them without privileges. logtail's HTTP client keeps
# connections alive between batches, so a 0.5 s sample catches them.
set -euo pipefail

SECONDS_TO_WATCH="${1:-300}"
EXPECT_UPLOAD=0
[[ "${2:-}" == "--expect-upload" ]] && EXPECT_UPLOAD=1
BUNDLE="net.lixom.latchkey"
LOG_HOSTS=(log.tailscale.com log.tailscale.io)

say() { printf '::: %s\n' "$*"; }

# Resolve every address the log hosts currently answer with, both families.
LOG_ADDRS=()
for h in "${LOG_HOSTS[@]}"; do
    for rr in A AAAA; do
        while read -r addr; do
            [[ -n "$addr" ]] && LOG_ADDRS+=("$addr")
        done < <(dig +short "$h" "$rr" 2>/dev/null | grep -E '^[0-9a-fA-F:.]+$' || true)
    done
done
if [[ ${#LOG_ADDRS[@]} -eq 0 ]]; then
    echo "error: could not resolve any log host address; the check would prove nothing" >&2
    exit 2
fi
say "log host addresses: ${LOG_ADDRS[*]}"

xcrun simctl terminate booted "$BUNDLE" >/dev/null 2>&1 || true
PID=$(xcrun simctl launch booted "$BUNDLE" | awk -F': ' '{print $2}')
if [[ -z "$PID" ]]; then
    echo "error: could not launch $BUNDLE" >&2
    exit 2
fi
say "watching pid $PID for ${SECONDS_TO_WATCH}s"

SEEN=$(mktemp)
ADDRS=$(mktemp)
trap 'rm -f "$SEEN" "$ADDRS"' EXIT
printf '%s\n' "${LOG_ADDRS[@]}" > "$ADDRS"
end=$(( $(date +%s) + SECONDS_TO_WATCH ))
samples=0
while [[ $(date +%s) -lt $end ]]; do
    # NAME column looks like  10.0.0.5:51234->199.165.136.100:443 (ESTABLISHED)
    lsof -nP -a -p "$PID" -i 2>/dev/null | awk 'NR>1 {print $9}' | grep -- '->' \
        | sed -E 's/.*->//' >> "$SEEN" || true
    samples=$((samples + 1))
    # Re-resolve every ~10 s. The log hosts rotate between sibling addresses
    # (log.tailscale.com answered .100/::102 in one run and .101/::103 in the
    # next), so an address set taken once at startup can miss an upload to a
    # sibling the app happened to resolve.
    if (( samples % 20 == 0 )); then
        for h in "${LOG_HOSTS[@]}"; do
            dig +short "$h" A "$h" AAAA 2>/dev/null | grep -E '^[0-9a-fA-F:.]+$' >> "$ADDRS" || true
        done
    fi
    sleep 0.5
done
sort -u -o "$ADDRS" "$ADDRS"

say "$samples samples; distinct remote endpoints:"
sort -u "$SEEN" | sed 's/^/      /'

hits=0
while read -r addr; do
    # IPv6 remotes appear bracketed: [2606:...]:443
    if grep -qE "(^|\[)${addr//./\\.}(\]|:)" "$SEEN"; then
        say "CONNECTION TO LOG SERVICE: $addr"
        hits=$((hits + 1))
    fi
done < "$ADDRS"
# Belt and braces: log.tailscale.com's own ranges. Checked against the control
# plane, which lives in 192.200.0.0/24 and 2606:b740:49::/48, so these do not
# false-positive on normal node traffic.
if grep -qE '(^|\[)(199\.165\.136\.[0-9]+|2606:b740:1:20:[0-9a-f:]*)(\]|:)' "$SEEN"; then
    say "CONNECTION TO LOG SERVICE RANGE: $(grep -E '199\.165\.136\.|2606:b740:1:20:' "$SEEN" | sort -u | tr '\n' ' ')"
    hits=$((hits + 1))
fi

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
say "ok: no connection to ${LOG_HOSTS[*]} in ${SECONDS_TO_WATCH}s"
