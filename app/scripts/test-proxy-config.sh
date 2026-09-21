#!/bin/bash
# Compile and run the ProxyConfiguration factory tests on the host (R12).
#
# Builds App/Network/ProxyConfigurationFactory.swift together with the REAL
# TSNet/TailnetProxyPolicy.swift, against the same TailscaleKit stubs as
# test-proxy-policy.sh, and asserts on the objects the app builds.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

sed 's/^import TailscaleKit$//' TSNet/TailnetProxyPolicy.swift > "$OUT/policy.swift"
sed 's/^import TailscaleKit$//' App/Network/StableProxyPolicy.swift > "$OUT/stable.swift"
cp scripts/test-proxy-config.swift "$OUT/main.swift"
xcrun swiftc -O \
    "$OUT/policy.swift" \
    "$OUT/stable.swift" \
    scripts/test-proxy-policy-stubs.swift \
    App/Network/ProxyConfigurationFactory.swift \
    "$OUT/main.swift" \
    -o "$OUT/proxy-config-tests"
"$OUT/proxy-config-tests"
