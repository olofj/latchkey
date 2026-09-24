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

Never add a bare `kiro` -> `latchkey` rule. Every rule below names a WHOLE
former product token.
"""

import argparse
import os
import subprocess
import sys

# Masked before any substitution and restored afterwards.
PRESERVE = [
    # The product this app is a client of. See the header.
    "KiroCrew", "Kiro Crew", "kirocrew", "kiro_crew", "KIROCREW", "KIRO_CREW",
    "kiro-crew",
    # Upstream's identity, inherited with the fork and not ours to rename.
    # `~/.aperture-ios-authkey` is a real path on the owner's machine and the
    # two APERTURE_* variables are read by upstream-shared code.
    "aperture-plus", "aperture-ios-authkey", "APERTURE_AUTHKEY",
    "APERTURE_EPHEMERAL", "tailscale/aperture",
]

# Applied in order, longest first, once PRESERVE is masked. Both former
# product names are here: the tree still carries `Latchkey` in the container
# path and the vendored file names, and `Latchkey` everywhere else.
SUBS = [
    ("Latchkey", "Latchkey"),
    ("Latchkey", "Latchkey"),
    ("Latchkey", "Latchkey"),
    ("Latchkey", "Latchkey"),
    # Mixed-case spellings that occur in Go identifiers. `Latchkey` (capital K,
    # lowercase r) was missed on the first vendored pass and survived as
    # `TestLatchkeyLocalLog...`; --check skipped the vendored tree, so only a
    # hand grep caught it. Both are listed now and --check covers that tree.
    ("Latchkey", "Latchkey"),
    ("Latchkey", "Latchkey"),
    ("LATCHKEY", "LATCHKEY"),
    ("LATCHKEY", "LATCHKEY"),
    # The compile flag. It has no NOMAD/ROAM in it, so it needs its own rule.
    ("LATCHKEY_TEST_HOOKS", "LATCHKEY_TEST_HOOKS"),
    ("latchkey", "latchkey"),
    ("latchkey", "latchkey"),
    ("latchkey", "latchkey"),
    ("latchkey", "latchkey"),
    ("LatchkeyUITests", "LatchkeyUITests"),   # after the bare forms, harmless
]

# Paths to move, directories before their contents.
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


def rewrite_body(body):
    for i, keep in enumerate(PRESERVE):
        body = body.replace(keep, f"\x00P{i}\x00")
    for old, new in SUBS:
        body = body.replace(old, new)
    for i, keep in enumerate(PRESERVE):
        body = body.replace(f"\x00P{i}\x00", keep)
    return body


def run(root, apply, vendored_only=False):
    changed, vendored_hits = [], []
    for path in target_files(root):
        rel = os.path.relpath(path, root)
        if rel in DELETE or rel.endswith("rename-to-latchkey.py"):
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


def check(root):
    """Bidirectional. Neither an old name left behind nor a preserved one eaten."""
    bad = []
    old_tokens = [o for o, _ in SUBS]
    # A corrupted preserved literal: what PRESERVE would look like if the
    # substitutions HAD reached inside it. Derived, so a new PRESERVE entry is
    # covered automatically.
    corrupted = {rewrite_body(k): k for k in PRESERVE if rewrite_body(k) != k}
    for path in all_text_files(root):
        rel = os.path.relpath(path, root)
        if rel.endswith("rename-to-latchkey.py"):
            continue
        try:
            body = open(path, encoding="utf-8").read()
        except (UnicodeDecodeError, IsADirectoryError):
            continue
        for tok in old_tokens:
            if tok in body:
                bad.append(f"{rel}: still carries the old token {tok!r}")
        for wrong, right in corrupted.items():
            if wrong in body:
                bad.append(f"{rel}: {right!r} was corrupted into {wrong!r} -- "
                           "discovery matches on that literal")
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
