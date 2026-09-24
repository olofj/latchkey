#!/usr/bin/env bash
# Fail if any named file mentions a tailnet other than the fixtures'.
#
#   scripts/check-fixture-tailnets.sh <file> [file...]
#
# R10: a real tailnet name in a test config is how a leak turns into a pass. On
# a Mac running Tailscale, a real `*.ts.net` name resolves and routes through
# the host's own VPN, so a test that was supposed to prove "this connection is
# refused" instead proves nothing — it succeeded.
#
# This is an ALLOW-LIST, and that is the whole point. Until 2026-09-23 each
# suite grepped for one hardcoded string: the author's own tailnet. That guard
# protected exactly one person. Anyone else's real tailnet — a contributor's, a
# colleague's — passed a check that looked like it was checking. Naming what is
# permitted catches every real tailnet, including ones nobody has thought of.
#
# Permitted:
#   tail-scale.ts.net   the harnesses' fake tailnet (testing/tsnet-harness)
#   example.ts.net      RFC 2606-style illustrative names, for placeholders
#
# A missing file is an error, not a pass (M3 review): a guard that silently
# skips a renamed file is worse than no guard.
set -euo pipefail

ALLOWED='^(tail-scale|example)\.ts\.net$'

if [[ $# -eq 0 ]]; then
    echo "usage: $0 <file> [file...]" >&2
    exit 2
fi

missing=0
for f in "$@"; do
    if [[ ! -e "$f" ]]; then
        echo "error: $0: no such file: $f" >&2
        echo "       A guarded file was renamed or moved. Fix the caller rather" >&2
        echo "       than dropping it: an unchecked fixture is the hazard here." >&2
        missing=1
    fi
done
[[ $missing -eq 0 ]] || exit 1

# Every tailnet mentioned: the label before `.ts.net`, lowercased, deduped.
found=$(grep -rhIoE '[A-Za-z0-9_-]+\.ts\.net' "$@" 2>/dev/null \
        | tr '[:upper:]' '[:lower:]' | sort -u || true)

foreign=$(printf '%s\n' "$found" | grep -vE "$ALLOWED" | grep -v '^$' || true)

if [[ -n "$foreign" ]]; then
    echo "error: test config names a tailnet that is not a fixture tailnet:" >&2
    printf '         %s\n' $foreign >&2
    echo "       A real tailnet name here routes through this Mac's own VPN, so a" >&2
    echo "       leak would SUCCEED instead of failing. Use tail-scale.ts.net," >&2
    echo "       example.ts.net or localtest.me." >&2
    echo "       Files checked: $*" >&2
    exit 1
fi
