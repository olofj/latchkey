#!/bin/bash
# Run the TestFlight notes tests on the host (F26 §6): throwaway git
# repositories and a fake App Store Connect, no network, no simulator.
set -euo pipefail

cd "$(dirname "$0")"
python3 test-tf-notes.py
