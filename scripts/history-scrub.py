#!/usr/bin/env python3
"""Rewrite one checked-out tree during `git filter-branch --tree-filter`.

Not run by hand. `scripts/history-scrub.sh` drives it.

WHAT COMES OUT OF HISTORY, AND WHY
----------------------------------
1. **The owner's real tailnet name.** It is the one genuine secret in this
   repository: it names his private network, and the repository is about to be
   published. Replaced with a placeholder rather than deleted, so the sentences
   around it still parse.

2. **Both former product names.** The name was trademark-encumbered, which is
   why the product was renamed at all; leaving 390 commits full of it in a
   public repository would keep exactly the exposure the rename was meant to
   remove.

WHAT STAYS, DELIBERATELY
------------------------
* **Kiro Crew**, in 51 commits. A different product -- an official Kiro
  project, not ours -- and this app is its client, so the history is *correct*
  to name it. It is also load-bearing in the code: discovery recognises a
  gateway by matching the manifest literal. Its lowercase spelling contains our
  old name, so it is masked before substitution, exactly as
  `scripts/rename-to-latchkey.py` does.

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
import sys

REAL_TAILNET = os.environ.get("SCRUB_TAILNET", "")
PLACEHOLDER = "example.ts.net"

PRESERVE = [
    "KiroCrew", "Kiro Crew", "kirocrew", "kiro_crew", "KIROCREW", "KIRO_CREW",
    "kiro-crew",
    "aperture-plus", "aperture-ios-authkey", "APERTURE_AUTHKEY",
    "APERTURE_EPHEMERAL", "tailscale/aperture",
]

SUBS = [
    ("Latchkey", "Latchkey"),
    ("Latchkey", "Latchkey"),
    ("Latchkey", "Latchkey"),
    ("Latchkey", "Latchkey"),
    ("Latchkey", "Latchkey"),
    ("Latchkey", "Latchkey"),
    ("LATCHKEY", "LATCHKEY"),
    ("LATCHKEY", "LATCHKEY"),
    ("LATCHKEY_TEST_HOOKS", "LATCHKEY_TEST_HOOKS"),
    ("latchkey", "latchkey"),
    ("latchkey", "latchkey"),
    ("latchkey", "latchkey"),
    ("latchkey", "latchkey"),
]

SKIP_DIRS = {".git", "build", "DerivedData", "node_modules", "__pycache__", ".run"}


def scrub(text):
    for i, keep in enumerate(PRESERVE):
        text = text.replace(keep, f"\x00P{i}\x00")
    for old, new in SUBS:
        text = text.replace(old, new)
    for i, keep in enumerate(PRESERVE):
        text = text.replace(f"\x00P{i}\x00", keep)
    if REAL_TAILNET:
        # The full MagicDNS domain FIRST, then the bare first label. The label
        # alone appears in greps, comments and guard patterns -- the first run
        # of this scrub replaced only the full domain and left 304 blobs
        # carrying the bare name, which is no less identifying.
        text = text.replace(REAL_TAILNET, PLACEHOLDER)
        label = REAL_TAILNET.split(".")[0]
        if label and label != REAL_TAILNET:
            text = text.replace(label, PLACEHOLDER.split(".")[0])
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
        if os.path.exists(src) and not os.path.exists(dst):
            os.rename(src, dst)
    return 0


if __name__ == "__main__":
    sys.exit(main())
