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

# F3 §4.6: the share's page-world requests and chunked upload, against a
# fake fetch, FormData and Blob.
cat > "$OUT/main.swift" <<'EOF6'
import Foundation
let payload = ["fetch": PageScriptSources.shareFetch, "stage": PageScriptSources.shareStageChunk,
               "upload": PageScriptSources.shareUpload]
print(String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!)
EOF6
xcrun swiftc -O App/Browser/PageScriptSources.swift "$OUT/main.swift" -o "$OUT/print-share"
"$OUT/print-share" | node scripts/test-share-scripts.js

# F15 §4a: the app bar's finger observer, run against a fake window.
cat > "$OUT/main.swift" <<'EOF5'
import Foundation
let payload = ["observer": PageScriptSources.appBarObserver]
print(String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!)
EOF5
xcrun swiftc -O App/Browser/PageScriptSources.swift "$OUT/main.swift" -o "$OUT/print-app-bar"
"$OUT/print-app-bar" | node scripts/test-app-bar-observer.js

# F9 §0.1: what the page-background reporter posts, parsed for the strip.
cat > "$OUT/main.swift" <<'EOF4'
var failed = 0
func check(_ css: String, _ want: (Double, Double, Double)?) {
    let got = PageScriptSources.opaqueRGB(fromCSS: css)
    let ok = (got == nil && want == nil)
        || (got != nil && want != nil && abs(got!.red - want!.0) < 1e-9
            && abs(got!.green - want!.1) < 1e-9 && abs(got!.blue - want!.2) < 1e-9)
    print("  \(ok ? "ok  " : "FAIL") \(css.isEmpty ? "(empty)" : css)")
    if !ok { failed += 1 }
}
check("rgb(32, 96, 160)", (32.0 / 255, 96.0 / 255, 160.0 / 255))
check("rgba(13, 15, 18, 1)", (13.0 / 255, 15.0 / 255, 18.0 / 255))
check("rgb(0 0 0)", (0, 0, 0))
check("rgba(0, 0, 0, 0)", nil)          // transparent: the app's background would show through
check("rgba(255, 255, 255, 0.5)", nil)  // translucent: matches nothing
check("", nil)                          // the page paints no canvas
check("oklch(0.2 0.01 250)", nil)       // not sRGB triplets: fall back, never guess
check("rgb(300, 0, 0)", nil)
check("rgb(1, 2)", nil)
print(failed == 0 ? "page background parse: all passed" : "page background parse: \(failed) FAILED")
if failed != 0 { fatalError() }
EOF4
xcrun swiftc -O App/Browser/PageScriptSources.swift "$OUT/main.swift" -o "$OUT/check-bg"
"$OUT/check-bg"
