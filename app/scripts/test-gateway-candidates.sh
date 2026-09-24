#!/bin/bash
# Host tests for gateway discovery's peer filter and fingerprint (M5, R26),
# and for the manual-entry gate: a typed gateway is accepted only if the
# REAL split-tunnel policy carries it, so TailnetProxyPolicy is compiled in
# (its TailscaleKit import stripped, the proxy tests' stubs standing in).
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
cp scripts/test-gateway-candidates.swift "$OUT/main.swift"
sed 's/^import TailscaleKit$//' TSNet/TailnetProxyPolicy.swift > "$OUT/policy.swift"
xcrun swiftc -O App/Discovery/GatewayCandidates.swift "$OUT/policy.swift" \
    scripts/test-proxy-policy-stubs.swift "$OUT/main.swift" -o "$OUT/candidates-tests"
"$OUT/candidates-tests"
