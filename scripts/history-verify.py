#!/usr/bin/env python3
"""Verify a scrubbed history: what must be gone is gone, what must stay stayed.

    scripts/history-verify.py [<real-tailnet-name>] [--rev <ref>]...

Exits non-zero and prints what it found if anything is wrong.

VERIFY EVERY PUBLISHABLE REF, NOT JUST THE ONE YOU ARE STANDING ON
------------------------------------------------------------------
The scrub rewrites `--all`; the first version of this checked only HEAD. This
repository has a second branch, `testflight`, in a linked worktree, and it is
NOT an ancestor of main -- three commits live only there. They were rewritten,
but nothing had measured them. With no --rev given, every local branch is
checked, so adding a branch cannot silently escape the check.

THE TAILNET CHECK DOES NOT NEED TO BE TOLD THE NAME
---------------------------------------------------
Passing the real name verifies that that exact string is gone, which is only as
good as the caller's memory of it. Every MagicDNS hostname has the shape
`<label>.ts.net`, so the stronger question is: which .ts.net names appear at
all? Any label outside the known-fictional allowlist is a finding, whether or
not the caller thought to name it.

WHY IT SCANS BLOBS RATHER THAN REVISIONS
----------------------------------------
The obvious check, `git grep <pattern> $(git rev-list HEAD)`, is O(commits x
files): it re-reads the same unchanged blob once per commit that contains it.
On this repository, with a vendored copy of tailscale in it, that is thousands
of re-reads per pattern and the check did not finish -- the first scrub's
"verification" step was killed partway and reported nothing at all, which is
worse than a slow check, because it looks like it passed.

Enumerating the UNIQUE blobs reachable from the branch and reading each once is
the same question asked in a way that terminates: ~4,500 blobs, seconds.

Commit messages are checked separately: a message is not a blob, and the first
version of this would have missed a name that appears only in prose.
"""

import collections
import re
import subprocess
import sys

# Every MagicDNS name in our own files, reviewed one at a time. Anything not
# here is a FAIL, which is the point: a real tailnet nobody thought to look for
# fails this check without having to be named in advance. (The vendored tree is
# exempt -- see `vendored` -- because upstream's test data is full of its own
# `*.ts.net` fixtures and R16 forbids rewriting it.)
TSNET_RE = re.compile(rb"(?i)\b[a-z0-9][a-z0-9_-]*\.ts\.net\b")
TSNET_ALLOWED = {
    # The two the rest of the repository already agrees on:
    # scripts/check-fixture-tailnets.sh and app/App/Testing/FixtureTailnetCheck.swift.
    b"tail-scale.ts.net",     # the harnesses' fake tailnet
    b"example.ts.net",        # illustrative, and what the scrub substitutes
    # Host unit-test fixtures: peers, gateways and hostnames invented to be sorted,
    # filtered and qualified. app/scripts/test-*.swift.
    b"a.ts.net", b"alpha.ts.net", b"zeta.ts.net", b"one.ts.net", b"two.ts.net",
    b"x.ts.net", b"h.ts.net", b"gateway.ts.net", b"gw.ts.net", b"host.ts.net",
    b"nas.ts.net", b"phone.ts.net", b"shared.ts.net", b"theirs.ts.net",
    b"other.ts.net", b"other-net.ts.net", b"corp.ts.net", b"tailnet.ts.net",
    # Named for the state they are in, so the assertion reads as a sentence.
    b"asleep.ts.net", b"stale.ts.net", b"gone.ts.net", b"tagged.ts.net",
    # Near-misses, invented to be REJECTED by a rule under test: a tailnet whose
    # name merely starts like the fixture's must not be treated as the fixture's.
    b"tailfoo.ts.net", b"evil-tailfoo.ts.net", b"something.ts.net",
    # The fixture-tailnet guard's own planted sample. It exists to be caught, in
    # scripts/check-fixture-tailnets.sh and its Swift twin's tests.
    b"some-real-net.ts.net", b"somereal.ts.net",
    # Documentation placeholders addressed to a reader: app/README.md.
    b"your-tailnet.ts.net",
    # Invented, in one UI-test comment describing a marker hostname. Verified
    # against the pre-scrub tree: it reads the same there, so it is someone's
    # invention and not a name the scrub mangled into looking invented.
    b"testgoblin.ts.net",
    # The owner's own machine, used DELIBERATELY as the canonical example gateway
    # in fourteen files, including strings the user sees ("Connecting to
    # byskebox…") and the GitHub issue template. It is a node name, not a tailnet:
    # far less identifying than the network it was on, and removing it would
    # rewrite F4's wording. Left in, as his call rather than mine -- but flagged
    # here so the decision is visible and not an oversight.
    b"byskebox.ts.net",
}

# The same rule the scrub uses, so the check cannot be blind in exactly the
# places the scrub was. It is a PATTERN and not a list of literals for a reason
# the list version taught the hard way: spelled out, the six literals made this
# file itself a hit, so the moment it was committed the verifier reported six
# blobs of contamination -- its own source -- and every real finding would have
# had to be picked out of that noise.
from product_names import OLD_RE_BYTES as GONE_RE     # noqa: E402
# A different product, and this app is its client: the history is correct to
# name it, and discovery matches on its manifest name. Its absence would mean
# the scrub ate it.
MUST_STAY = ("KiroCrew", b"KiroCrew")


def local_branches():
    out = subprocess.run(["git", "for-each-ref", "--format=%(refname:short)",
                          "refs/heads"], capture_output=True, check=True).stdout
    return [l.decode() for l in out.split(b"\n") if l]


def blobs(revs):
    """{blob sha: set of paths it has ever been stored at}.

    The paths are what make a failure actionable -- "3 blobs still name it" does
    not tell you what to scrub -- and they are how a vendored blob is told from
    one of ours.
    """
    objs = subprocess.run(["git", "rev-list", "--objects", *revs],
                          capture_output=True, check=True).stdout.split(b"\n")
    paths = collections.defaultdict(set)
    for line in objs:
        if not line:
            continue
        sha, _, path = line.partition(b" ")
        if path:
            paths[sha].add(path.decode("utf-8", "replace"))
    names = b"\n".join(paths) + b"\n"
    meta = subprocess.run(["git", "cat-file", "--batch-check=%(objectname) %(objecttype)"],
                          input=names, capture_output=True).stdout.split(b"\n")
    keep = {l.split()[0] for l in meta if l.endswith(b" blob")}
    return {sha: p for sha, p in paths.items() if sha in keep}


def vendored(paths):
    """True if every path this blob was ever stored at is upstream's.

    Upstream's own test data is full of `*.ts.net` fixtures -- velociraptor,
    optimistic-display, a few dozen more -- and R16 says not to touch it:
    rewriting upstream bytes corrupts the delta that makes our changes
    reviewable. So the MagicDNS allow-list does not apply inside the vendored
    tree. The product-name check still does, because our own files live there
    too.
    """
    return paths and all(p.startswith("app/ThirdParty/") for p in paths)


def main():
    argv = sys.argv[1:]
    revs, tailnets = [], []
    while argv:
        arg = argv.pop(0)
        if arg == "--rev":
            if not argv:
                print("error: --rev needs a ref", file=sys.stderr)
                return 2
            revs.append(argv.pop(0))
        else:
            tailnets.append(arg.encode())
    revs = revs or local_branches()

    literals = {}
    for tailnet in tailnets:
        literals[f"{tailnet.decode()} (a real tailnet)"] = tailnet
        label = tailnet.split(b".")[0]
        if label != tailnet:
            literals[f"{label.decode()} (its bare label)"] = label

    paths_of = blobs(revs)
    ids = sorted(paths_of)
    out = subprocess.run(["git", "cat-file", "--batch"],
                         input=b"\n".join(ids) + b"\n", capture_output=True).stdout
    where = collections.defaultdict(set)      # finding -> example paths
    counts = collections.Counter()
    tsnet = collections.defaultdict(set)      # magicdns name -> paths
    kept = 0
    i = 0
    while i < len(out):
        nl = out.index(b"\n", i)
        sha, _, size = out[i:nl].split()
        body = out[nl + 1:nl + 1 + int(size)]
        paths = paths_of.get(sha, set())
        for found in set(GONE_RE.findall(body)):
            counts["a former product name"] += 1
            where["a former product name"] |= paths
            break
        # Case-INSENSITIVELY, because the one occurrence that survived two scrubs
        # was `example.ts.net` in a test of case-insensitive URL handling, and
        # the previous version of this check looked for the lowercase literal --
        # the same blind spot the scrub had, so it confirmed nothing.
        low = body.lower()
        for name, pat in literals.items():
            if pat.lower() in low:
                counts[name] += 1
                where[name] |= paths
        if not vendored(paths):
            # Lower-cased before the allow-list comparison, not after being
            # found: `GW.Some-Real-Net.TS.NET` is the same tailnet as the
            # lowercase spelling, and scripts/check-fixture-tailnets.sh shipped
            # with exactly this bug -- it matched case-insensitively but compared
            # the raw match, so a mixed-case real name passed a check that
            # looked like it was checking.
            for found in {f.lower() for f in TSNET_RE.findall(body)}:
                tsnet[found] |= paths or {"(unnamed blob)"}
        if MUST_STAY[1] in body:
            kept += 1
        i = nl + 1 + int(size) + 1

    msgs = subprocess.run(["git", "log", "--format=%B%n%an%n%ae", *revs],
                          capture_output=True).stdout
    msg_hits = collections.Counter()
    if GONE_RE.search(msgs):
        msg_hits["a former product name"] = len(GONE_RE.findall(msgs))
    msgs_low = msgs.lower()
    for name, pat in literals.items():
        if pat.lower() in msgs_low:
            msg_hits[name] = msgs_low.count(pat.lower())
    # A commit message is not a blob. The tailnet name appeared in two of them,
    # and the first version of this check would have missed a name that lives
    # only in prose.
    for found in {f.lower() for f in TSNET_RE.findall(msgs)}:
        tsnet[found] |= {"(a commit message)"}

    def show(paths):
        listed = sorted(paths)[:3]
        more = f" (+{len(paths) - 3} more)" if len(paths) > 3 else ""
        return ", ".join(listed) + more

    print(f"::: {len(ids)} unique blob(s) reachable from {', '.join(revs)}")
    bad = False
    for name in ["a former product name", *literals]:
        b, m = counts[name], msg_hits.get(name, 0)
        if b or m:
            print(f"  FAIL: {name}: {b} blob(s), {m} message occurrence(s)")
            if where[name]:
                print(f"        at: {show(where[name])}")
            bad = True
        else:
            print(f"  ok: {name} is gone")

    unknown = {n: p for n, p in tsnet.items() if n not in TSNET_ALLOWED}
    if unknown:
        print(f"  FAIL: {len(unknown)} MagicDNS name(s) outside the allow-list, in our"
              f" own files. Each is either fictional -- add it to TSNET_ALLOWED with"
              f" its provenance -- or someone's real tailnet, and has to be scrubbed:")
        for name, paths in sorted(unknown.items()):
            print(f"        {name.decode():32} {show(paths)}")
        bad = True
    else:
        print(f"  ok: every MagicDNS name in our own files is a known-fictional one"
              f" ({len(tsnet)} distinct)")

    if kept == 0:
        print(f"  FAIL: {MUST_STAY[0]} is absent -- the scrub ate a name it had to keep")
        bad = True
    else:
        print(f"  ok: {MUST_STAY[0]} survives in {kept} blob(s)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
