#!/usr/bin/env python3
"""L1 across N simulators at once (F14 stage 2).

    scripts/test-offline-shards.py [--shards N] [--build]
    scripts/test-offline-shards.py sims [up N | down | delete]

scripts/test-offline.sh runs this by default; `test-offline.sh --serial` is
the one-simulator path. Each shard is test-offline.sh itself, run as a
worker on its own simulator ("Latchkey Shard k") against its own harness
instance k. How shards are booted, planned, run and judged is
scripts/shards.py, shared with the session suite; what is L1's own:

  - the plan     OfflineHarnessTests' tests, longest first by
                 scripts/l1-durations.txt. Tests that share one launch
                 (settledDefaultRun) stay together. The sign-in test and R1's
                 disk scan go to one shard, as its last pass, whose weight
                 includes that second xcodebuild pass.
  - the verdict  from each shard's suite and signin passes.

Logs: app/build/offline-logs/<stamp>-shards/ (see scripts/shards.py).
"""

import os
import re
import sys

import shards

SWIFT = os.path.join(shards.APP, "UITests", "OfflineHarnessTests.swift")
SIGNIN = "testSignInTokenIsStrippedFromTheAddress"
SIGNIN_PASS = 6.0      # the second xcodebuild pass the sign-in test needs


class L1(shards.Suite):
    name = "L1"
    worker = os.path.join(shards.ROOT, "scripts", "test-offline.sh")
    log_root = os.path.join(shards.APP, "build", "offline-logs")
    durations = os.path.join(shards.ROOT, "scripts", "l1-durations.txt")
    budget = 240
    logs = ("suite", "signin")

    def tests(self):
        """The file's test names, and the groups that must share a shard:
        tests whose body calls settledDefaultRun() share one launch, which
        only the first of them in a process pays."""
        src = open(SWIFT).read()
        _, names = shards.swift_tests(SWIFT)
        starts = [m.start() for m in re.finditer(r"^    (?:private |static |@\w+ )*func ", src, re.M)]
        shared = []
        for name in names:
            at = src.index(f"func {name}(")
            end = next((s for s in starts if s > at), len(src))
            if "settledDefaultRun()" in src[at:end]:
                shared.append(name)
        return names, [shared] if len(shared) > 1 else []

    def test_id(self, cls, name):
        return name

    def weight(self, test, table):
        return table.get(test, self.unknown) + (SIGNIN_PASS if test == SIGNIN else 0)

    def note(self, tests):
        return "  + R1 scan" if SIGNIN in tests else ""


if __name__ == "__main__":
    sys.exit(shards.main(L1(), __doc__))
