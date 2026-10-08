#!/bin/bash
# Compile and run the media-capture-policy unit tests on the host (F23 W2).
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

cp scripts/test-media-capture-policy.swift "$OUT/main.swift"
xcrun swiftc -O \
    App/Browser/MediaCapturePolicy.swift \
    App/Browser/GatewayAddress.swift \
    "$OUT/main.swift" \
    -o "$OUT/media-capture-policy-tests"
"$OUT/media-capture-policy-tests"
