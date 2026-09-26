#!/usr/bin/env python3
"""The session suite (M4) across N simulators at once (F14).

    scripts/test-session-shards.py [--shards N] [--build]
    scripts/test-session-shards.py sims [up N | down | delete]

scripts/test-session.sh runs this by default; `test-session.sh --serial` is
the one-simulator path. Each shard is test-session.sh itself, run as a
worker on its own simulator ("Latchkey Shard k", the ones L1 uses) against
its own harness instance k: stub proxy, fake dashboard and both fake
gateways on ports +100*k. How shards are booted, planned, run and judged is
scripts/shards.py, shared with L1; what is the session suite's own:

  - the plan     SessionTests and ShareTests, as Class/test, longest first
                 by scripts/session-durations.txt. Tests that share one
                 launch (a cached `…Run()` helper) stay together.
  - the bundle   the pinned KiroCrew wheel is fetched once, before the
                 shards start (or the desktop app's copy chosen, if it
                 passes the pin), rather than by every shard at once.
  - the log checks  R1, F3 and F6 scan each shard's container and unified
                 log, and a shard fails on anything they find. Their
                 positive controls (a redemption, WebKit data, each Share
                 line, a page loaded under the rule list) are only in the
                 logs of the shards whose tests produce them, so each shard
                 records its counts in evidence.txt and the run fails
                 unless every control was found on some shard -- as a
                 serial run requires of its one log.

Logs: app/build/session-logs/<stamp>-shards/ (see scripts/shards.py).
"""

import os
import subprocess
import sys

import shards

UITESTS = os.path.join(shards.APP, "UITests")
DESKTOP_DIST = ("/Applications/KiroCrew.app/Contents/Resources/backend-dist/kirocrew-backend-arm64/"
                "lib/python3.12/site-packages/kiro_crew/static/dist")
# test-session.sh's positive controls: key -> what none on any shard means.
CONTROLS = {
    "redemptions": "R1: no shard logged a redemption, so the link scans proved nothing",
    "webkit_files": "R1: no shard's app container held WebKit data, so the disk scans searched nothing",
    "share_sent": 'F3: no shard\'s unified log has a "Share: sent " line',
    "share_uploaded": 'F3: no shard\'s unified log has a "Share: uploaded " line',
    "share_swept": 'F3: no shard\'s unified log has a "Share: swept N item" line',
    "share_refused": 'F3: no shard\'s unified log has a "Share: refused ... over 50 MB" line',
    "fonts_preload": "F6: no shard logged a page under the rule list that names the fonts link, "
                     "so the fonts check proved nothing",
}


class Session(shards.Suite):
    name = "session"
    worker = os.path.join(shards.ROOT, "scripts", "test-session.sh")
    log_root = os.path.join(shards.APP, "build", "session-logs")
    durations = os.path.join(shards.ROOT, "scripts", "session-durations.txt")
    # Measured on the 20-core M1 Ultra, 39 tests, simulators booted and
    # settled: 319 s at N = 4, 276 s at 6, 234 s at 8 (F14 §9). Test time
    # runs 8 % over plan at 4 and 45 % at 8, far more than L1's launches,
    # but 8 still pays.
    shards = 8
    budget = 300
    unknown = 25.0
    logs = ("test",)
    teardown = ("gateway-down GW_NAME=gateway2", "gateway-down", "harness-down")

    def tests(self):
        names, groups = [], []
        for cls in ("SessionTests", "ShareTests"):
            path = os.path.join(UITESTS, f"{cls}.swift")
            _, tests = shards.swift_tests(path)
            names += [f"{cls}/{t}" for t in tests]
            groups += [[f"{cls}/{t}" for t in g] for g in shards.shared_runs(path, tests)]
        return names, groups

    def test_id(self, cls, name):
        return f"{cls}/{name}"

    def prepare(self):
        if os.environ.get("KIROCREW_DIST"):
            return
        got = subprocess.run(["make", "-C", shards.HARNESS, "--no-print-directory", "bundle"],
                             capture_output=True, text=True)
        if got.returncode == 0:
            return
        fake = os.path.join(shards.HARNESS, "fake_gateway.py")
        if os.path.isdir(DESKTOP_DIST) and subprocess.run(
                [sys.executable, fake, "--check-bundle", "--dist", DESKTOP_DIST],
                capture_output=True).returncode == 0:
            os.environ["KIROCREW_DIST"] = DESKTOP_DIST
            shards.say("the pinned wheel could not be fetched; serving the desktop app's copy, which matches the pin")
        # Otherwise every shard's own --check-bundle fails, and says why.

    def check(self, planned):
        found = {key: [] for key in CONTROLS}
        errors = []
        for k, s in planned.items():
            path = os.path.join(s["dir"], "evidence.txt")
            if not os.path.exists(path):
                errors.append(f"shard {k} recorded no log-check evidence (it stopped before its log checks)")
                continue
            for line in open(path):
                key, _, count = line.strip().partition(" ")
                if key in found and count.isdigit() and int(count) > 0:
                    found[key].append((k, int(count)))
        shards.say("log checks' positive controls, across the shards")
        for key, why in CONTROLS.items():
            if found[key]:
                print(f"    ok  {key:15} {sum(c for _, c in found[key]):5}  "
                      f"(shards {', '.join(str(k) for k, _ in found[key])})", flush=True)
            else:
                print(f"    NONE {key}", flush=True)
                errors.append(why)
        return errors


if __name__ == "__main__":
    sys.exit(shards.main(Session(), __doc__))
