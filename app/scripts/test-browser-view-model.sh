#!/bin/bash
# Host tests for App/Browser/BrowserViewModel.swift's pure parts: the web
# view configuration every dashboard page is built from (D1: no egress but
# the gateway), and how a navigation error is categorised and described
# (F4's rule: a SOCKS failure is never a "URL format error").
#
# Compiles the REAL view model on the host. It needs WebKit, which macOS
# has; the UIKit-only parts are behind canImport and drop out. TSNetModel,
# AppDiagnostics and the TailscaleKit status types are stubbed to the fields
# the view model reads; everything else it uses is the app's own source.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
cp scripts/test-browser-view-model.swift "$OUT/main.swift"
# `import TailscaleKit` is stripped: the stubs provide those types instead.
for f in App/Browser/BrowserViewModel.swift App/Browser/HomePageAvailability.swift TSNet/TailnetProxyPolicy.swift; do
    sed 's/^import TailscaleKit$//' "$f" > "$OUT/$(basename "$f")"
done
# -O and the app's isolation flags, as the other host tests (AGENTS.md).
if ! xcrun swiftc -O -swift-version 6 -strict-concurrency=complete -default-isolation MainActor \
        "$OUT/BrowserViewModel.swift" "$OUT/HomePageAvailability.swift" "$OUT/TailnetProxyPolicy.swift" \
        App/Browser/PageScripts.swift App/Browser/PageScriptSources.swift App/Browser/PopupCatcher.swift \
        App/Browser/GatewayAddress.swift App/Browser/NavigationPolicy.swift \
        App/Browser/TailnetHostnameQualifier.swift App/Browser/ContentProcessRecovery.swift \
        App/Browser/PageState.swift App/Browser/PageFailureText.swift \
        App/Session/SessionManager.swift App/Session/TokenInput.swift App/Session/DashboardSignOut.swift \
        App/Network/SocksRelayPolicy.swift App/Logging/LogRedaction.swift App/TestHooks.swift \
        scripts/test-proxy-policy-stubs.swift scripts/test-socks-relay-stubs.swift \
        scripts/test-browser-view-model-stubs.swift \
        "$OUT/main.swift" -o "$OUT/browser-view-model-tests" > "$OUT/build.log" 2>&1; then
    cat "$OUT/build.log" >&2
    echo "error: the browser view model host tests do not compile" >&2
    exit 1
fi
"$OUT/browser-view-model-tests"
