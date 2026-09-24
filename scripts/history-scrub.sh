#!/usr/bin/env bash
# Rewrite the whole history: remove the owner's real tailnet name and both
# former product names. See scripts/history-scrub.py for what goes, what stays
# and why.
#
#   scripts/history-scrub.sh <real-tailnet-name>
#
# The tailnet name is an ARGUMENT, never a constant in these files. They are
# committed, and the whole point of the rewrite is that the name is absent from
# the published repository -- baking it into the scrubber would put it straight
# back, in the one file guaranteed to be read.
#
# This is a one-way operation on every commit. It is safe to run here only
# because nothing has been pushed: there is no clone to diverge from, and no
# force-push to explain to anyone. Run it before the first push, which is the
# whole reason it is happening now.
#
# It leaves the previous history reachable as refs/original/refs/heads/main
# until you delete it, and tags a backup as well. Verify, then clean up:
#
#   git for-each-ref --format='%(refname)' refs/original | \
#       xargs -n1 git update-ref -d
#   git reflog expire --expire=now --all && git gc --prune=now --aggressive
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TAILNET="${1:-}"
if [[ -z "$TAILNET" ]]; then
    echo "usage: scripts/history-scrub.sh <real-tailnet-name>" >&2
    echo "  e.g. scripts/history-scrub.sh something.ts.net" >&2
    exit 2
fi

# --- refuse to run on anything but a clean, unpushed, idle repository --------
if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree is dirty; commit or stash first" >&2
    exit 1
fi
if git rev-parse --verify --quiet origin/main >/dev/null; then
    echo "error: origin/main exists, so this history has been published." >&2
    echo "       Rewriting it now means a force-push and a diverged clone." >&2
    exit 1
fi
if pgrep -f 'scripts/test-(offline|tailnet|session|discovery|lifecycle|all)\.sh' >/dev/null; then
    echo "error: a test suite is running; it reads this repository" >&2
    exit 1
fi

BEFORE_COUNT=$(git rev-list --count HEAD)
BACKUP="backup/pre-scrub-$(date +%Y%m%d-%H%M%S)"
git tag "$BACKUP"
echo "::: tagged the current history as $BACKUP ($BEFORE_COUNT commits)"

# --- the rewrite -------------------------------------------------------------
# A TREE filter, not an index filter: the substitutions are on file CONTENTS,
# and an index filter cannot see them. It is the slow one -- every commit is
# checked out -- which for a few hundred commits is minutes, and this runs once.
#
# --prune-empty drops the commits that become no-ops, which is exactly what the
# rename commits become: both sides of their diffs end up saying Latchkey.
export SCRUB_TAILNET="$TAILNET"
export FILTER_BRANCH_SQUELCH_WARNING=1

git filter-branch --force --prune-empty \
    --tree-filter "python3 '$ROOT/scripts/history-scrub.py'" \
    --msg-filter "python3 '$ROOT/scripts/history-scrub.py' --message" \
    --tag-name-filter cat -- --all

AFTER_COUNT=$(git rev-list --count HEAD)
echo "::: rewritten: $BEFORE_COUNT commits -> $AFTER_COUNT"

# --- verify, and say so in terms of what was supposed to happen --------------
fail=0
check_absent() {  # label, pattern
    local n
    n=$(git grep -I -l "$2" $(git rev-list --all) -- 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$n" != "0" ]]; then
        echo "  FAIL: $1 still present in $n blob(s)" >&2
        fail=1
    else
        echo "  ok: $1 is gone"
    fi
}
echo "::: verification"
check_absent "the real tailnet name" "$TAILNET"
for p in Latchkey Latchkey latchkey latchkey Latchkey Latchkey; do
    check_absent "$p" "$p"
done

# The other direction: what must have SURVIVED. A scrub that ate Kiro Crew
# would pass every check above and break discovery on every tailnet.
kept=$(git grep -I -l "KiroCrew" $(git rev-list --all) -- 2>/dev/null | wc -l | tr -d ' ')
if [[ "$kept" == "0" ]]; then
    echo "  FAIL: KiroCrew is gone from history; it is a different product and" >&2
    echo "        discovery matches on its manifest name" >&2
    fail=1
else
    echo "  ok: KiroCrew survives in $kept blob(s)"
fi

if [[ $fail -ne 0 ]]; then
    echo "::: FAILED -- the old history is still at $BACKUP" >&2
    exit 1
fi
echo "::: passed. Old history kept at $BACKUP and refs/original/ until you delete them."
