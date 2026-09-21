#!/usr/bin/env bash
# Bootstrap a Latchkey working tree: clone the aperture-plus fork into app/
# and check out its two levels of submodules.
#
# Idempotent. Safe to re-run on an existing tree — it only fixes up what is
# missing or mis-pointed.
#
# Why this script exists rather than a plain `git submodule update --init
# --recursive`: upstream declares both submodules with `url = .`, and the
# commits they pin live as unreferenced objects inside the aperture-plus
# repository itself. Git resolves a relative submodule URL against the
# superproject's `origin` remote, and docs/PLAN.md §4.2 renames origin ->
# upstream, after which `.` degrades to a local filesystem path and the clone
# fails with "fatal: transport 'file' not allowed". See docs/DECISIONS.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO_ROOT/app"
UPSTREAM_URL="https://github.com/tailscale/aperture-plus"
UPSTREAM_SHA="dba05551d3577825ecc44ca8dd0645c9eaca1f8c"

say() { printf '::: %s\n' "$*"; }

if [ ! -d "$APP_DIR/.git" ]; then
    say "Cloning $UPSTREAM_URL -> app/"
    git clone "$UPSTREAM_URL" "$APP_DIR"
    git -C "$APP_DIR" remote rename origin upstream
    # Work happens directly on `main` -- single developer, no topic branches
    # (docs/DECISIONS.md). Pin it to the fork point, and stop it tracking
    # upstream/main so a bare `git pull` cannot drag in upstream changes and a
    # bare `git push` does not try to write to tailscale/aperture-plus. Upstream
    # merges are deliberate: `git merge upstream/main`.
    git -C "$APP_DIR" checkout -q -B main "$UPSTREAM_SHA"
    git -C "$APP_DIR" branch --unset-upstream main
else
    say "app/ already exists; leaving its history alone"
fi

# Level 1: ThirdParty/libtailscale. Rewrite the relative URL if it is still
# upstream's `.` (a no-op once the fork has committed the absolute URL).
if grep -qE '^[[:space:]]*url = \.$' "$APP_DIR/.gitmodules" 2>/dev/null; then
    say "Rewriting .gitmodules relative URL -> $UPSTREAM_URL"
    # BSD and GNU sed disagree about -i; write through a temp file instead.
    sed "s|^[[:space:]]*url = \.$|\turl = $UPSTREAM_URL|" \
        "$APP_DIR/.gitmodules" > "$APP_DIR/.gitmodules.tmp"
    mv "$APP_DIR/.gitmodules.tmp" "$APP_DIR/.gitmodules"
fi
git -C "$APP_DIR" submodule sync --quiet
say "Checking out ThirdParty/libtailscale"
git -C "$APP_DIR" submodule update --init ThirdParty/libtailscale

# Level 2: tailscale-patched, nested inside libtailscale. Its .gitmodules is
# upstream libtailscale's file, so override the URL in local git config rather
# than diverging a second repository.
LT="$APP_DIR/ThirdParty/libtailscale"
say "Checking out tailscale-patched"
git -C "$LT" config submodule.tailscale-patched.url "$UPSTREAM_URL"
git -C "$LT" submodule update --init --recursive

say "Submodule state:"
git -C "$APP_DIR" submodule status --recursive

cat <<'EOF'

Next:
    cd app
    make framework     # TailscaleKit.xcframework (needs Go; slow the first time)
    make app           # simulator build
    make test-policy   # host-only unit tests, ~2s
EOF
