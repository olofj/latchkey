#!/usr/bin/env python3
"""Verify a scrubbed history: what must be gone is gone, what must stay stayed.

    scripts/history-verify.py [<real-tailnet-name>]

Exits non-zero and prints what it found if anything is wrong.

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
import subprocess
import sys

GONE = {
    "Latchkey": b"Latchkey", "Latchkey": b"Latchkey",
    "latchkey": b"latchkey", "latchkey": b"latchkey",
    "Latchkey": b"Latchkey", "Latchkey": b"Latchkey",
}
# A different product, and this app is its client: the history is correct to
# name it, and discovery matches on its manifest name. Its absence would mean
# the scrub ate it.
MUST_STAY = ("KiroCrew", b"KiroCrew")


def blobs(rev="HEAD"):
    objs = subprocess.run(["git", "rev-list", "--objects", rev],
                          capture_output=True, check=True).stdout.split(b"\n")
    names = b"\n".join(l.split(b" ")[0] for l in objs if l) + b"\n"
    meta = subprocess.run(["git", "cat-file", "--batch-check=%(objectname) %(objecttype)"],
                          input=names, capture_output=True).stdout.split(b"\n")
    return sorted({l.split()[0] for l in meta if l.endswith(b" blob")})


def main():
    tailnet = sys.argv[1].encode() if len(sys.argv) > 1 else None
    patterns = dict(GONE)
    if tailnet:
        patterns["the real tailnet name"] = tailnet
        label = tailnet.split(b".")[0]
        if label != tailnet:
            patterns["its bare first label"] = label

    ids = blobs()
    out = subprocess.run(["git", "cat-file", "--batch"],
                         input=b"\n".join(ids) + b"\n", capture_output=True).stdout
    hits = collections.Counter()
    kept = 0
    i = 0
    while i < len(out):
        nl = out.index(b"\n", i)
        size = int(out[i:nl].split()[2])
        body = out[nl + 1:nl + 1 + size]
        for name, pat in patterns.items():
            if pat in body:
                hits[name] += 1
        if MUST_STAY[1] in body:
            kept += 1
        i = nl + 1 + size + 1

    msgs = subprocess.run(["git", "log", "--format=%B%n%an%n%ae", "HEAD"],
                          capture_output=True).stdout
    msg_hits = {n: msgs.count(p) for n, p in patterns.items() if p in msgs}

    print(f"::: {len(ids)} unique blob(s) reachable from HEAD")
    bad = False
    for name in patterns:
        b, m = hits[name], msg_hits.get(name, 0)
        if b or m:
            print(f"  FAIL: {name}: {b} blob(s), {m} message occurrence(s)")
            bad = True
        else:
            print(f"  ok: {name} is gone")
    if kept == 0:
        print(f"  FAIL: {MUST_STAY[0]} is absent -- the scrub ate a name it had to keep")
        bad = True
    else:
        print(f"  ok: {MUST_STAY[0]} survives in {kept} blob(s)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
