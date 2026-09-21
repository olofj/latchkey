#!/bin/bash
# Run the injected page scripts under Node against a fake window (R2).
#
# Compiles App/Browser/PageScriptSources.swift on the host, prints the script
# source, and feeds it to scripts/test-page-scripts.js -- so what is tested is
# the exact text the app injects, not a copy.
#
# Node is not otherwise a build dependency, so a machine without it skips
# these checks with a notice rather than failing the host-test suite.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v node >/dev/null 2>&1; then
    echo "SKIP: page script checks need node, which is not installed"
    exit 0
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
