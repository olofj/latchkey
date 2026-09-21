#!/bin/bash
# Compile and run the gateway-address unit tests on the host (revision R2).
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

cp scripts/test-gateway-address.swift "$OUT/main.swift"
xcrun swiftc -O \
    App/Browser/GatewayAddress.swift \
    "$OUT/main.swift" \
    -o "$OUT/gateway-address-tests"
"$OUT/gateway-address-tests"
