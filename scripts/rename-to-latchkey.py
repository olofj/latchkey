#!/usr/bin/env python3
"""Rename the product to Latchkey, everywhere this time.

    scripts/rename-to-latchkey.py            # dry run: what would change
    scripts/rename-to-latchkey.py --apply    # rewrite files and move paths
    scripts/rename-to-latchkey.py --check    # BIDIRECTIONAL verification

WHY THIS RENAME IS DIFFERENT FROM THE LAST ONE
----------------------------------------------
September's rename (`app/scripts/rename-to-latchkey.py`) deliberately FROZE
everything keyed to the app's identity -- the bundle id `net.lixom.latchkey`,
the os_log subsystem, `<Application Support>/Latchkey/` -- so the install kept
its container and therefore its tsnet node, its tailnet-lock signature and its
grants. That is why it cost nothing.

This one moves all of it, because the driver is not taste: "Kiro" is
trademark-encumbered and the name has to go from the published repository.
Olof has accepted the consequence explicitly: the app becomes a NEW node.
On first launch after this it will ask to log in again, need device approval,
need re-signing under tailnet lock, and need whatever grant its address range
has. The old node lingers in the admin console until removed. None of that is
recoverable by renaming back -- the container is keyed to the bundle id.

THE ONE THING THAT MUST SURVIVE, AND WHY IT IS DANGEROUS
--------------------------------------------------------
**Kiro Crew stays.** It is a different product -- an official Kiro project,
not ours and not being renamed -- and this app is its client, so the codebase
must keep naming it. Two places make that load-bearing rather than cosmetic:

  * `GatewayCandidates.manifestIsKiroCrew` matches the gateway's web-app
    manifest on the literal `"Kiro Crew"`. That string is how discovery
    RECOGNISES a gateway. Rewrite it and the app finds nothing, on every
    tailnet, with no error -- the sweep simply reports zero gateways.
  * `authProbeIsKiroCrew` pairs it with the `X-Auth-Required` header.

And `kirocrew` CONTAINS `kiro`. So a substitution aimed at our own old names
will reach inside it unless it is masked first. That is what PRESERVE is for,
and why `--check` looks in both directions: a run that leaves an old name
behind is obvious, but a run that quietly corrupts `KiroCrew` into
`Latchkeycrew` would pass a one-directional check and break discovery.

Never match a bare `kiro`. The pattern below always requires a whole former
product token: `kiro` plus a separator plus `roam` or `nomad`.

WHY THE RULES ARE A PATTERN AND NOT A TABLE OF LITERALS
------------------------------------------------------
The first version of this script carried a hand-written list of spellings. Two
things went wrong with that, both found afterwards:

1. **A spelling nobody listed.** The probe header the app sends -- now
   `X-Latchkey-Check` -- was Title-Case-Hyphenated, because that is what HTTP
   headers look like, and Title-Case-Hyphenated was the one shape the table did
   not have. It survived the rename, the history scrub and a passing `--check`:
   live in `PageScriptSources.swift`, asserted by a host test, on the wire.
   `docs/DECISIONS.md` records that the PREVIOUS rename of this same header
   missed `.js` files. It is a header that gets missed.

2. **The table could not survive the scrub.** A table of old spellings is a file
   full of old spellings, so `scripts/history-scrub.py` rewrote this script's own
   rules into `("Latchkey", "Latchkey")`. `--check` then read the NEW name as the
   forbidden token and flagged every correct file in the repository -- a guard
   that fails on everything is a guard nobody can use.

A pattern assembled from `kiro` (which KiroCrew legitimately contains) and
`roam`/`nomad` (ordinary words) fixes both: it matches every case and separator
without enumerating them, and it contains no forbidden spelling, so a scrub has
nothing to corrupt. It lives in `scripts/product_names.py`, shared with the
history scrub, because two copies of this rule is how the shapes drifted apart
in the first place.
"""

import argparse
import os
import subprocess
import sys

from product_names import LITERAL_SUBS, OLD_RE, PRESERVE, rewrite

# Paths to move, directories before their contents. SPENT: the project and
# xcconfig have been moved, and both sides of these entries now read Latchkey.
# Left as the record of what the move was, and harmless -- `run` skips entries
# whose source equals their destination. `moves()` also FINDS paths carrying a
# former token rather than relying on this list, so a file added later is caught.
MOVES = [
    ("app/Latchkey.xcodeproj", "app/Latchkey.xcodeproj"),
    ("app/Latchkey.xcconfig", "app/Latchkey.xcconfig"),
]

# The two earlier rename scripts are DELETED, not renamed. They are one-shot
# surgery scripts documenting renames that, after the history rewrite this
# change is part of, will not exist in the published history -- so keeping two
# files whose whole subject is the encumbered names defeats the point of
# removing them. This script stays as the record of the rename that did happen,
# including the Kiro Crew hazard, which is the part worth carrying forward.
DELETE = [
    "app/scripts/rename-to-latchkey.py",
    "app/scripts/rename-to-latchkey.py",
]

EXTENSIONS = {".swift", ".plist", ".xcscheme", ".pbxproj", ".sh", ".py", ".md",
              ".json", ".js", ".go", ".yml", ".yaml", ".xcconfig", ".entitlements",
              ".html", ".css", ".txt", ".cnf", ".mod", ".h", ".c", ".m"}
NAMED = {"Makefile", "makefile", ".gitignore", "LICENSE", "NOTICE", "AGENTS.md",
         "README", "CLAUDE.md"}
SKIP_DIRS = {".git", "build", "DerivedData", ".run", "node_modules", "__pycache__"}

# The vendored tree is upstream source with OUR files added to it. Only the
# files we added carry our name, and renaming them is a vendored change, which
# R16 says must be its own commit -- so this script reports them and does not
# move them. `git log -- app/ThirdParty/libtailscale` must stay the delta.
VENDORED = "app/ThirdParty"


def target_files(root):
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            if name in NAMED or os.path.splitext(name)[1] in EXTENSIONS:
                out.append(os.path.join(dirpath, name))
    return out


rewrite_body = rewrite          # the shared rule; see scripts/product_names.py


def run(root, apply, vendored_only=False):
    changed, vendored_hits = [], []
    for path in target_files(root):
        rel = os.path.relpath(path, root)
        if rel in DELETE:
            continue
        try:
            body = open(path, encoding="utf-8").read()
        except (UnicodeDecodeError, IsADirectoryError):
            continue
        new = rewrite_body(body)
        if new == body:
            continue
        if rel.startswith(VENDORED) != vendored_only:
            if rel.startswith(VENDORED):
                vendored_hits.append(rel)
            continue
        changed.append(rel)
        if apply:
            open(path, "w", encoding="utf-8").write(new)
    return changed, vendored_hits


def moves(root, apply, vendored_only=False):
    done = []
    if vendored_only:
        MOVES.clear()
    for src, dst in MOVES:
        if src == dst:
            continue
        s, d = os.path.join(root, src), os.path.join(root, dst)
        if not os.path.exists(s):
            continue
        done.append((src, dst))
        if apply:
            subprocess.run(["git", "-C", root, "mv", src, dst], check=True)
    # Files whose NAME carries an old token, found rather than listed, so a
    # file added later is not missed.
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [x for x in dirnames if x not in SKIP_DIRS]
        for name in filenames + dirnames:
            renamed = rewrite_body(name)
            if renamed == name:
                continue
            rel = os.path.relpath(os.path.join(dirpath, name), root)
            if rel.startswith(VENDORED) != vendored_only:
                continue
            if any(rel == s for s, _ in MOVES) or rel in DELETE:
                continue
            done.append((rel, os.path.join(os.path.dirname(rel), renamed)))
            if apply:
                subprocess.run(["git", "-C", root, "mv", rel,
                                os.path.join(os.path.dirname(rel), renamed)], check=True)
    return done


def all_text_files(root):
    """Every file that is plausibly text, regardless of extension.

    Deliberately WIDER than `target_files`: the rewriter is driven by an
    extension list, so anything outside it is silently not rewritten. If the
    checker shared that list it would be blind in exactly the same places --
    which is what happened to `app/NOTICE`, a file with no extension that kept
    the old name through a passing --check.
    """
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            p = os.path.join(dirpath, name)
            try:
                with open(p, "rb") as fh:
                    if b"\x00" in fh.read(4096):
                        continue          # binary
            except OSError:
                continue
            out.append(p)
    return out


def selfcheck():
    """Prove the rule before trusting anything it says. Returns problems.

    Two directions, on planted samples rather than on the repository, because a
    guard that cannot demonstrate itself is only an opinion:

      * every shape the old names were written in must be rewritten, including
        the Title-Case-Hyphenated one that survived a whole rename;
      * no preserved name may be touched -- `"Kiro Crew"` above all, because
        `GatewayCandidates` recognises a gateway by matching that literal, and
        corrupting it makes discovery find nothing with no error at all.

    The second direction replaced a derived check that had never once run: it
    compared each preserved name against `rewrite_body` OF that name, and
    `rewrite_body` masks preserved names first, so the two sides were equal by
    construction and the dict was always empty. It looked bidirectional for as
    long as nobody printed it.
    """
    bad = []
    planted = [
        ("Kiro" "Nomad", "Latchkey"),            # Swift and Go identifiers
        ("Kiro" " " "Roam", "Latchkey"),         # prose
        ("X-Kiro" "-Nomad" "-Check", "X-Latchkey-Check"),   # the HTTP header
        ("kiro" "-roam", "latchkey"),            # repository and directory names
        ("KIRO" "_NOMAD", "LATCHKEY"),           # shell and build variables
        ("KIRO" "_TEST_HOOKS", "LATCHKEY_TEST_HOOKS"),
    ]
    for sample, want in planted:
        got = rewrite_body(sample)
        if got != want:
            bad.append(f"the rule itself is wrong: {sample!r} -> {got!r}, expected {want!r}")
    for keep in PRESERVE:
        if rewrite_body(keep) != keep:
            bad.append(f"the rule eats a name that must survive: {keep!r} -> "
                       f"{rewrite_body(keep)!r}")
        if OLD_RE.search(keep):
            bad.append(f"the pattern reaches inside {keep!r} -- it has been loosened, "
                       "and discovery matches on that literal")
    return bad


def check(root):
    """Bidirectional. Neither an old name left behind nor a preserved one eaten."""
    bad = selfcheck()
    if bad:
        return bad + ["refusing to check the repository: the rule is broken, so "
                      "nothing it would say about your files can be trusted"]
    for path in all_text_files(root):
        rel = os.path.relpath(path, root)
        # NOTHING is exempt. The earlier version skipped the scrubbers, because
        # a table of old spellings necessarily contains old spellings -- and that
        # exemption is how the probe header and a mixed-case real tailnet name
        # both stayed hidden. Now that every rule is a pattern assembled from
        # harmless parts, no file needs to spell a forbidden name, so no file
        # gets a pass.
        try:
            body = open(path, encoding="utf-8").read()
        except (UnicodeDecodeError, IsADirectoryError):
            continue
        for hit in sorted({m.group(0) for m in OLD_RE.finditer(body)}):
            bad.append(f"{rel}: still carries a former product name ({hit!r})")
        for old, _ in LITERAL_SUBS:
            if old in body:
                bad.append(f"{rel}: still carries the old token {old!r}")
    # The fingerprint itself, by name, because it is the one that fails silently.
    fp = os.path.join(root, "app/App/Discovery/GatewayCandidates.swift")
    if os.path.exists(fp):
        body = open(fp, encoding="utf-8").read()
        if '"Kiro Crew"' not in body:
            bad.append("GatewayCandidates.swift no longer matches the manifest "
                       'literal "Kiro Crew" -- discovery would find nothing')
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    # R16: a vendored-tree change is its own commit, so its pass is its own run.
    ap.add_argument("--vendored", action="store_true",
                    help="rename ONLY inside app/ThirdParty (our added files there)")
    ap.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    a = ap.parse_args()

    if a.check:
        bad = check(a.root)
        for b in bad:
            print("  " + b)
        print(f"{'FAILED: ' + str(len(bad)) + ' problem(s)' if bad else 'check passed'}")
        return 1 if bad else 0

    changed, vendored = run(a.root, a.apply, a.vendored)
    mv = moves(a.root, a.apply, a.vendored)
    gone = [] if a.vendored else [d for d in DELETE if os.path.exists(os.path.join(a.root, d))]
    if a.apply:
        for d in gone:
            subprocess.run(["git", "-C", a.root, "rm", "-q", d], check=True)
    verb = "rewrote" if a.apply else "would rewrite"
    print(f"{verb} {len(changed)} file(s)")
    for rel in changed[:12]:
        print("    " + rel)
    if len(changed) > 12:
        print(f"    ... and {len(changed) - 12} more")
    print(f"{'moved' if a.apply else 'would move'} {len(mv)} path(s)")
    for s, d in mv:
        print(f"    {s} -> {d}")
    if gone:
        print(f"{'deleted' if a.apply else 'would delete'} {len(gone)} superseded script(s)")
        for d in gone:
            print("    " + d)
    if vendored:
        print(f"\nVENDORED, left for its own commit (R16): {len(vendored)} file(s)")
        for rel in vendored[:10]:
            print("    " + rel)
    return 0


if __name__ == "__main__":
    sys.exit(main())
