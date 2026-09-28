# Sourced by the suite runners: sim_setup NAME UDID boots a simulator and
# sets it up for the tests (scripts/simpool.py prepare).
#
# A serial run on a pool simulator ("Latchkey Shard k") first holds slot k of
# scripts/simpool.py, waiting if another run has it, so it never shares the
# simulator or harness instance k with a sharded run. The lock is taken on fd
# 9, which this shell and everything it starts keep open: it is released when
# the last of them exits, however they exit. A shard worker does not take it;
# its parent, scripts/shards.py, holds the slot for it.
LIB_SIM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

sim_setup() {
    local name=$1 udid=$2 k lock
    k=${name#Latchkey Shard }
    # A slot this run already holds through `simpool.py run` (LATCHKEY_SLOTS)
    # is not taken again: a second flock on it would wait for ourselves.
    if [[ "$k" != "$name" && "$k" =~ ^[0-9]+$ && -z "${LATCHKEY_SHARD_TESTS:-}" \
          && " ${LATCHKEY_SLOTS:-} " != *" $k "* ]]; then
        lock="${LATCHKEY_SIMPOOL_DIR:-$HOME/Library/Caches/latchkey-simpool}/slot-$k.lock"
        mkdir -p "$(dirname "$lock")"
        exec 9>>"$lock" || { echo "error: cannot open $lock" >&2; exit 1; }
        if ! python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)' 2>/dev/null; then
            printf '::: simpool: slot %s is held (scripts/simpool.py status); waiting for it\n' "$k"
            python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX)'
        fi
        printf '::: simpool: holding slot %s\n' "$k"
    fi
    xcrun simctl bootstatus "$udid" -b >/dev/null
    python3 "$LIB_SIM_ROOT/scripts/simpool.py" prepare "$udid"
}
