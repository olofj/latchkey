#!/bin/bash
# Host tests for the L2 control-plane override (R17, R15).
#
#   1. isLoopback's cases.
#   2. With LATCHKEY_TEST_HOOKS: a loopback -TestControlURL is used, and anything
#      else is a crash rather than a silent fall-back to the real control plane.
#      A crash counts only if it is the override's own fatalError.
#   3. Without LATCHKEY_TEST_HOOKS: the argument is ignored.
#   4. Only the Testing configuration defines LATCHKEY_TEST_HOOKS, so (3) is what
#      Debug and Release actually get.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

cp scripts/test-control-plane.swift "$OUT/main.swift"
xcrun swiftc -D LATCHKEY_TEST_HOOKS App/TestHooks.swift App/Testing/TestControlPlane.swift \
    "$OUT/main.swift" -o "$OUT/hooks" 2>&1 | grep -v "^$" || true
xcrun swiftc App/TestHooks.swift App/Testing/TestControlPlane.swift \
    "$OUT/main.swift" -o "$OUT/nohooks" 2>&1 | grep -v "^$" || true

"$OUT/hooks"

fail=0
expect() {  # $1 = binary, $2 = expected output, rest = launch arguments
    local bin=$1 want=$2; shift 2
    local got
    if got=$("$OUT/$bin" print "$@" 2>"$OUT/stderr"); then :; else
        # Any crash is not enough: it must be the override refusing.
        if grep -q "TestControlURL" "$OUT/stderr"; then got="<crash>"; else got="<other failure>"; fi
    fi
    if [[ "$got" == "$want" ]]; then
        echo "  ok   $bin $* -> $want"
    else
        echo "  FAIL $bin $* -> $got (want $want)"; fail=1
    fi
}
echo "controlURLOverride (Testing configuration)"
expect hooks "<nil>"
expect hooks "http://127.0.0.1:8490" -TestControlURL http://127.0.0.1:8490
expect hooks "http://[::1]:8490" -TestControlURL "http://[::1]:8490"
expect hooks "<crash>" -TestControlURL https://controlplane.tailscale.com
expect hooks "<crash>" -TestControlURL http://127.0.0.1.nip.io:8490
expect hooks "<crash>" -TestControlURL ftp://127.0.0.1/
expect hooks "<crash>" -TestControlURL not-a-url
expect hooks "<crash>" -TestControlURL http://127.0.0.01:8490
expect hooks "<crash>" -TestControlURL "http://127.+0.+0.+1:8490"
expect hooks "<crash>" -TestControlURL http://127.0.0.1@evil.example:8490
expect hooks "<crash>" -TestControlURL ""
expect hooks "<crash>" -TestControlURL
expect hooks "<crash>" -TestControlURL=http://127.0.0.1:8490
echo "controlURLOverride (no test hooks: Debug, Release)"
expect nohooks "<nil>" -TestControlURL http://127.0.0.1:8490
expect nohooks "<nil>" -TestControlURL https://controlplane.tailscale.com
echo "LATCHKEY_TEST_HOOKS is defined only in the Testing configuration"
if python3 - Latchkey.xcodeproj/project.pbxproj <<'PY'
import re, sys
text = open(sys.argv[1]).read()
bad = []
for m in re.finditer(r"\n\t\t([0-9A-F]{24}) /\* (\w+) \*/ = \{\n\t\t\tisa = XCBuildConfiguration;(.*?)\n\t\t\};", text, re.S):
    if "LATCHKEY_TEST_HOOKS" in m.group(3) and m.group(2) != "Testing":
        bad.append(m.group(2))
found = text.count("LATCHKEY_TEST_HOOKS")
if bad or found == 0:
    print("  FAIL defined in: %s (occurrences: %d)" % (bad, found)); sys.exit(1)
print("  ok   only Testing (%d occurrence(s))" % found)
PY
then :; else fail=1; fi
[[ $fail -eq 0 ]] || { echo "control-plane override tests FAILED"; exit 1; }
echo "control-plane override tests passed"
