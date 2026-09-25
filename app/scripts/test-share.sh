#!/bin/bash
# Host tests for F3's pure parts: the inbox item, its policy, the share URL,
# the message and the gateway's answers (F3 §7).
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
cp scripts/test-share.swift "$OUT/main.swift"
# -O, as the other host tests: they catch optimizer-only bugs (AGENTS.md).
if ! xcrun swiftc -O App/Share/Inbox/ShareItem.swift App/Share/Inbox/ShareInboxPolicy.swift \
        App/Share/Inbox/ShareInboxStore.swift App/Workspace/BackupExclusion.swift \
        App/Share/ShareURL.swift App/Share/ShareMessage.swift App/Share/ShareOutcome.swift \
        "$OUT/main.swift" -o "$OUT/share-tests" > "$OUT/build.log" 2>&1; then
    cat "$OUT/build.log" >&2
    echo "error: the share host tests do not compile" >&2
    exit 1
fi
"$OUT/share-tests"
