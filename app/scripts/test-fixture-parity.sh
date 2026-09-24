#!/bin/bash
# Host test for F10 §4.2: the fake dashboard's layout-relevant declarations
# match the installed KiroCrew frontend's (scripts/test-fixture-parity.swift).
# Reads the frontend, never runs it; skips loudly when it is not installed.
set -euo pipefail

cd "$(dirname "$0")/.."
DIST="${KIRO_CREW_DIST:-$HOME/.kiro/crew-venv/lib/python3.12/site-packages/kiro_crew/static/dist}"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
cp scripts/test-fixture-parity.swift "$OUT/main.swift"
xcrun swiftc -O "$OUT/main.swift" -o "$OUT/fixture-parity"
"$OUT/fixture-parity" ../testing/harness/dashboard.py "$DIST"
