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

TAILNETS=()
IPS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip) IPS+=("$2"); shift 2 ;;
        *)    TAILNETS+=("$1"); shift ;;
    esac
done
if [[ ${#TAILNETS[@]} -eq 0 && ${#IPS[@]} -eq 0 ]]; then
    echo "usage: scripts/history-scrub.sh <real-tailnet-name> [more...] [--ip <addr>]..." >&2
    echo "  e.g. scripts/history-scrub.sh something.ts.net older.ts.net --ip 203.0.113.9" >&2
    echo "  More than one tailnet, because more than one turned out to be in" >&2
    echo "  here: a tailnet the project had used earlier was still named in app" >&2
    echo "  code and in a commit message." >&2
    echo "  --ip takes a REAL observed address. Fixtures, resolvers and boundary" >&2
    echo "  values must NOT be passed: they are what the tests assert about." >&2
    exit 2
fi
TAILNET="${TAILNETS[*]}"

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
export SCRUB_IPS="${IPS[*]}"
export FILTER_BRANCH_SQUELCH_WARNING=1

git filter-branch --force --prune-empty \
    --tree-filter "python3 '$ROOT/scripts/history-scrub.py'" \
    --msg-filter "python3 '$ROOT/scripts/history-scrub.py' --message" \
    --tag-name-filter cat -- --all

AFTER_COUNT=$(git rev-list --count HEAD)
echo "::: rewritten: $BEFORE_COUNT commits -> $AFTER_COUNT"

# --- verify --------------------------------------------------------------
# Delegated to scripts/history-verify.py, which scans the UNIQUE blobs
# reachable from the branch and the commit messages. The check that used to
# live here ran `git grep` once per revision -- O(commits x files) on a
# repository carrying a vendored copy of tailscale -- and did not finish: the
# first scrub's verification was killed partway and printed nothing, which is
# worse than a slow check because it reads as success.
echo "::: verification"
VERIFY_ARGS=("${TAILNETS[@]}")
for ip in ${IPS[@]+"${IPS[@]}"}; do VERIFY_ARGS+=(--ip "$ip"); done
if ! python3 "$ROOT/scripts/history-verify.py" ${VERIFY_ARGS[@]+"${VERIFY_ARGS[@]}"}; then
    echo "::: FAILED -- the previous history is at $BACKUP and refs/original/" >&2
    exit 1
fi
echo "::: passed. Old history kept at $BACKUP and refs/original/ until you delete them."
