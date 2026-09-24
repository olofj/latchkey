#!/bin/bash
# Run the injected page scripts under Node against a fake window (R2).
#
# Compiles App/Browser/PageScriptSources.swift on the host, prints the script
# source, and feeds it to scripts/test-page-scripts.js -- so what is tested is
# the exact text the app injects, not a copy.
#
# Node is a host-test dependency: the token strip (R2), the session bridge
# (M4.2, R22) and the fetch body (R32) are tested only here. Until 2026-09-23
# a machine without it printed SKIP and exited 0, so those three suites
# vanished while `make test-policy` -- and scripts/test-all.sh's "ok host
# tests" -- stayed green (review). A missing interpreter is a failure that
# names the remedy.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v node >/dev/null 2>&1; then
    echo "error: the page script checks need node, which is not installed (brew install node)." >&2
    echo "       Without it the token-strip, session-bridge and fetch-timeout suites do not run," >&2
    echo "       and a host-test pass would not mean what it says." >&2
    exit 1
fi

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
cat > "$OUT/main.swift" <<'EOF'
print(PageScriptSources.stripSignInToken)
EOF
xcrun swiftc -O App/Browser/PageScriptSources.swift "$OUT/main.swift" -o "$OUT/print-scripts"
"$OUT/print-scripts" | node scripts/test-page-scripts.js

# The session bridge (M4.2, R22): both scripts as JSON, run against a fake page.
cat > "$OUT/main.swift" <<'EOF2'
import Foundation
let payload = ["bridge": PageScriptSources.sessionBridge,
               "reveal": PageScriptSources.revealSessionBanner,
               "styleID": PageScriptSources.bannerStyleID]
print(String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!)
EOF2
xcrun swiftc -O App/Browser/PageScriptSources.swift "$OUT/main.swift" -o "$OUT/print-bridge"
"$OUT/print-bridge" | node scripts/test-session-bridge.js

# The app's own page-world requests (M4's check, R32's sign-out): the fetch
# body, run against a fake fetch.
cat > "$OUT/main.swift" <<'EOF3'
import Foundation
let payload = ["fetchBody": PageScriptSources.sessionFetch]
print(String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!)
EOF3
xcrun swiftc -O App/Browser/PageScriptSources.swift "$OUT/main.swift" -o "$OUT/print-fetch"
"$OUT/print-fetch" | node scripts/test-session-fetch.js
