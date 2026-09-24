#!/usr/bin/env python3
"""Rewrite one checked-out tree during `git filter-branch --tree-filter`.

Not run by hand. `scripts/history-scrub.sh` drives it.

WHAT COMES OUT OF HISTORY, AND WHY
----------------------------------
1. **The owner's real tailnet names.** They are the one genuine secret in this
   repository: they name his private networks, and the repository is about to be
   published. Replaced with a placeholder rather than deleted, so the sentences
   around them still parse. Plural, and case-insensitive, both learned the hard
   way -- see `tailnet_patterns` below.

2. **Both former product names.** The name was trademark-encumbered, which is
   why the product was renamed at all; leaving 390 commits full of it in a
   public repository would keep exactly the exposure the rename was meant to
   remove.

WHAT STAYS, DELIBERATELY
------------------------
* **Kiro Crew**, in 51 commits. A different product -- an official Kiro
  project, not ours -- and this app is its client, so the history is *correct*
  to name it. It is also load-bearing in the code: discovery recognises a
  gateway by matching the manifest literal. The substitution rule lives in
  `scripts/product_names.py`, shared with `scripts/rename-to-latchkey.py`: one
  definition, because the first version of this script had its own copy, the two
  drifted, and a spelling the rename missed was a spelling this missed too.

  That shared rule is a PATTERN, not a table of spellings, for a reason this
  script caused: a table of old spellings is a file full of old spellings, so an
  earlier run of this scrub rewrote both scripts' own rules into
  `("Latchkey", "Latchkey")` and left the rename tool's `--check` reporting every
  correctly-named file in the repository as contaminated.

* **Every IP address.** Surveyed before writing this: every address in the
  history outside the vendored tree is a test fixture, a documentation example,
  a well-known public resolver, Tailscale's own DERP range, or an endpoint
  deliberately named in `check-no-log-upload.sh` so the app can be asserted
  never to talk to it. None is the owner's. Addresses in the vendored tree are
  upstream's own test data and rewriting them would corrupt the R16 delta. The
  owner's rule -- tsnet-side 100.x may stay, real ones may not -- is satisfied
  by there being no real ones.

A NOTE ON WHAT THIS COSTS
-------------------------
After this, the history reads as though the project was always called Latchkey.
That is a mild fiction, and it is the point: the encumbered name has to be
absent, not merely superseded. The rename commits themselves become empty --
both sides of their diffs say Latchkey -- and `--prune-empty` drops them.
"""

import os
import re
import sys

from product_names import rewrite

# Space-separated, because more than one real tailnet turned out to be in here.
REAL_TAILNETS = [t for t in os.environ.get("SCRUB_TAILNET", "").split() if t]
PLACEHOLDER = "example.ts.net"

SKIP_DIRS = {".git", "build", "DerivedData", "node_modules", "__pycache__", ".run"}


def tailnet_patterns(names):
    """Case-INSENSITIVE patterns for each name and its bare first label.

    The `re.IGNORECASE` is the whole lesson of the second scrub. The first two
    runs used `str.replace`, which is case-sensitive, and one occurrence survived
    all of it:

        expectEqual(GatewayAddress.origin(of: "HTTPS://Box.Tail-Scale.TS.net/"), ...

    -- a test of case-insensitive origin normalisation, which is exactly the kind
    of test that spells a hostname in mixed case. (The tailnet there was the real
    one; shown with the fixture name because an example written with the real name
    is an example this scrub flattens into lowercase, taking the point with it.) It sat in the history through
    two rewrites and a verification that reported "0 blobs", because the
    verification looked for the same lowercase literal the scrub did. Both halves
    of a rule agreeing on the same blind spot is not confirmation.

    `scripts/check-fixture-tailnets.sh` already carried this scar: its comment
    records matching case-insensitively but comparing the raw match, so
    `dash.SomeReal.TS.NET` passed a check that looked like it was checking.

    The longest name first, so a full domain is replaced before its own label can
    eat the start of it.
    """
    out = []
    for name in sorted(names, key=len, reverse=True):
        out.append((re.compile(re.escape(name), re.IGNORECASE), PLACEHOLDER))
        label = name.split(".")[0]
        if label and label != name:
            # The bare label appears in greps, comments and guard patterns. The
            # first run replaced only the full domain and left 304 blobs carrying
            # it, which is no less identifying.
            out.append((re.compile(re.escape(label), re.IGNORECASE),
                        PLACEHOLDER.split(".")[0]))
    return out


TAILNET_SUBS = tailnet_patterns(REAL_TAILNETS)


def scrub(text):
    text = rewrite(text)
    for pattern, replacement in TAILNET_SUBS:
        text = pattern.sub(replacement, text)
    return text


def main():
    # `--message`: filter-branch's --msg-filter hands the commit message on
    # stdin and takes the replacement on stdout. Messages need scrubbing as much
    # as blobs do -- the tailnet name appears in two of them, and most of the
    # product-name occurrences in this history are in prose, not code.
    if "--message" in sys.argv:
        sys.stdout.write(scrub(sys.stdin.read()))
        return 0

    renames = []
    for dirpath, dirnames, filenames in os.walk(".", topdown=True):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            path = os.path.join(dirpath, name)
            try:
                with open(path, "rb") as fh:
                    raw = fh.read()
            except OSError:
                continue
            if b"\x00" in raw[:8192]:
                continue                      # binary: PNGs, archives, keys
            try:
                text = raw.decode("utf-8")
            except UnicodeDecodeError:
                continue
            new = scrub(text)
            if new != text:
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(new)
        # Paths carrying the name, deepest first so a parent rename cannot
        # invalidate a child's path mid-walk.
        for name in filenames + dirnames:
            renamed = scrub(name)
            if renamed != name:
                renames.append((os.path.join(dirpath, name),
                                os.path.join(dirpath, renamed)))
    for src, dst in sorted(renames, key=lambda p: -p[0].count(os.sep)):
        if not os.path.exists(src):
            continue
        # COLLISIONS. Two sibling files can scrub to one name: the history has a
        # commit holding both former renaming scripts, one per former product
        # name, and both become `rename-to-latchkey.py`. The first version of this
        # simply skipped a rename whose destination existed -- so the loser KEPT
        # its old name, and `app/scripts/rename-to-<old>.py` stayed a path in the
        # published history through two rewrites. A path is as public as a blob.
        #
        # Suffixing is not pretty, and it is the only option that keeps every
        # name clean without deleting a file the commit legitimately had.
        target, seq = dst, 1
        stem, ext = os.path.splitext(dst)
        while os.path.exists(target) and os.path.abspath(target) != os.path.abspath(src):
            seq += 1
            target = f"{stem}-{seq}{ext}"
        if os.path.abspath(target) != os.path.abspath(src):
            os.rename(src, target)
    return 0


if __name__ == "__main__":
    sys.exit(main())
