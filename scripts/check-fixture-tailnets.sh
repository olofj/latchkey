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
# skips a renamed file is worse than no guard. So is a file grep could not
# read, and so is a guard that cannot see its own planted name: the script
# proves itself on a mixed-case sample before it looks at anything else.
set -euo pipefail

ALLOWED='^(tail-scale|example)\.ts\.net$'
NAME_RE='[A-Za-z0-9_-]+\.ts\.net'

if [[ $# -eq 0 ]]; then
    echo "usage: $0 <file> [file...]" >&2
    exit 2
fi

# Every tailnet mentioned in the files -- the label before `.ts.net` -- matched
# case-INsensitively, lowercased, deduped. The -i is load-bearing: the first
# version matched case-sensitively and lowercased grep's OUTPUT, so
# `dash.SomeReal.TS.NET` never reached the tr at all and passed (review,
# 2026-09-23), while the Swift twin, app/App/Testing/FixtureTailnetCheck.swift,
# folded case correctly -- two halves of one rule disagreeing. Returns 2 when
# grep could not read a file: that is not "no names", and the two must not
# share a branch. (grep's own 1, no names at all, is fine.)
names_in() {  # files... -> names on stdout
    local rc=0
    grep -rhIoiE "$NAME_RE" "$@" | tr '[:upper:]' '[:lower:]' | sort -u || rc=$?
    [[ $rc -le 1 ]] || return 2
}

foreign_in() {  # names -> the ones outside the allow-list
    printf '%s\n' "$1" | grep -vE "$ALLOWED" | grep -v '^$' || true
}

# The guard proves itself first, on mixed case on both sides of the rule: the
# fixture names must pass in any case, and a foreign name must be caught in
# any case. The planted names are the Swift twin's test names, so a sweep of
# the repository for real tailnets already knows them.
selfcheck() {
    local dir found foreign rc=0
    dir=$(mktemp -d)
    printf 'gateway = "https://GW.Some-Real-Net.TS.NET/"\nfixture = "MIXED.Tail-Scale.TS.NET"\nplaceholder = "gw.Example.TS.NET"\n' \
        > "$dir/planted.txt"
    found=$(names_in "$dir/planted.txt") || rc=$?
    foreign=$(foreign_in "$found")
    rm -rf "$dir"
    if [[ $rc -ne 0 || "$foreign" != "some-real-net.ts.net" ]]; then
        echo "error: $0 failed its own check: on a planted sample it should flag exactly" >&2
        echo "       some-real-net.ts.net and pass the mixed-case fixture names; it flagged" >&2
        echo "       '${foreign:-nothing}' (grep status $rc). The guard is broken, so nothing it" >&2
        echo "       would say about your files can be trusted." >&2
        exit 2
    fi
}
selfcheck

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

rc=0
found=$(names_in "$@") || rc=$?
if [[ $rc -ne 0 ]]; then
    echo "error: $0 could not read every file it was given (grep's message is above)," >&2
    echo "       so 'no foreign tailnet named' is not established." >&2
    exit 2
fi
foreign=$(foreign_in "$found")

if [[ -n "$foreign" ]]; then
    echo "error: test config names a tailnet that is not a fixture tailnet:" >&2
    printf '         %s\n' $foreign >&2
    echo "       A real tailnet name here routes through this Mac's own VPN, so a" >&2
    echo "       leak would SUCCEED instead of failing. Use tail-scale.ts.net," >&2
    echo "       example.ts.net or localtest.me." >&2
    echo "       Files checked: $*" >&2
    exit 1
fi
