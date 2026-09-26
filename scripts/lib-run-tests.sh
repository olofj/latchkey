# Sourced by scripts/test-offline.sh and scripts/test-session.sh: one
# xcodebuild test-without-building pass, with a watchdog (F14).
#
# The caller sets APP, UDID, LOG_DIR, XCTESTRUN (empty: the project's own
# DerivedData) and TEST_ALLOWANCE (seconds per test).
#
# After a failure the test runner is relaunched for the rest, and xcodebuild
# can then sit for up to 600 s after the last test, waiting on the first
# runner (seen serially on 2026-09-23 and in a shard on 2026-09-25). So once
# every test of the pass has reported, or the runner has printed its closing
# summary (a test killed with its simulator never reports), and the log has
# been quiet for 60 s, xcodebuild is stopped and the pass fails, saying why.
run_tests() {   # $1 = label, $2 = tests in the pass, rest = -only-testing/-skip-testing args
    local label=$1 want=$2 log="$LOG_DIR/$1.log"; shift 2
    local from=(-project Latchkey.xcodeproj -scheme Latchkey -configuration Testing
                -derivedDataPath build/DerivedData)
    [[ -n "$XCTESTRUN" ]] && from=(-xctestrun "$XCTESTRUN")
    (cd "$APP" && exec xcodebuild test-without-building "${from[@]}" \
        -destination "platform=iOS Simulator,id=$UDID" -resultBundlePath "$LOG_DIR/$label.xcresult" \
        -parallel-testing-enabled NO -test-timeouts-enabled YES \
        -default-test-execution-time-allowance "$TEST_ALLOWANCE" "$@") > "$log" 2>&1 &
    local pid=$! size=-1 quiet=0 reported
    while kill -0 "$pid" 2>/dev/null; do
        sleep 2
        reported=$(grep -cE "^Test Case '.*' (passed|failed) \(" "$log")
        if [[ ( $reported -ge $want || $(grep -v '^\s*$' "$log" | tail -1) =~ ^[[:space:]]*Executed\ [0-9]+\ test ) \
              && $(stat -f %z "$log") == "$size" ]]; then
            quiet=$(( quiet + 2 ))
        else
            quiet=0; size=$(stat -f %z "$log")
        fi
        if [[ $quiet -ge 60 ]]; then
            echo "error: xcodebuild ($label) was still running 60 s after its tests finished" >&2
            echo "       ($reported of $want reported); stopped it (after a runner relaunch it" >&2
            echo "       can wait 600 s for nothing)" >&2
            kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
            return 1
        fi
    done
    wait "$pid"
}
