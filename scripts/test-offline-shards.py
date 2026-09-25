#!/usr/bin/env python3
"""L1 across N simulators at once (F14 stage 2).

    scripts/test-offline-shards.py [--shards N] [--build]
    scripts/test-offline-shards.py sims [up N | down | delete]

scripts/test-offline.sh runs this by default; `test-offline.sh --serial` is
the one-simulator path. Each shard is test-offline.sh itself, run as a
worker on its own simulator ("Latchkey Shard k") against its own harness
instance k (ports +100*k, testing/harness/Makefile), with a list of tests:
preflight, the harness self-test, the tests, R1's scan and the teardown
are the serial path's own, not a copy of them.

  1. simulators  create and boot any shard simulator that is not booted,
                 one at a time, before anything is timed (a first boot is
                 20-23 s; twelve at once took minutes, F14 §9). They stay
                 booted for the next run: `sims down` shuts them down,
                 `sims delete` removes them, `sims` lists them.
  2. build       with --build, once, before the shards start; every shard
                 then runs test-without-building against the one .xctestrun.
                 N builds at once would race in one DerivedData.
  3. plan        the file's tests, packed onto N shards longest first by
                 scripts/l1-durations.txt. Tests that share one launch
                 (settledDefaultRun) stay together. The sign-in test and R1's
                 disk scan go to one shard, as its last pass.
  4. shards      all N at once, each in its own process group, each with a
                 time limit; a shard past it is killed and its harness
                 stopped.
  5. verdict     every test's result from its shard's xcresult, under its
                 own name, with its failure messages and the shard and
                 simulator it ran on. It passes only if each of the file's
                 tests passed exactly once and every shard exited 0: a test
                 that never reported (a simulator that died, a harness that
                 never came up) is a failure, never a skip.

Logs: app/build/offline-logs/<stamp>-shards/, one shard-k/ per shard (the
worker's own logs and xcresults), shard-k.out/.err (its output), results.json
and tests.txt (one `name result shard` line per test, sorted, to diff).
"""

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "app")
HARNESS = os.path.join(ROOT, "testing", "harness")
SWIFT = os.path.join(APP, "UITests", "OfflineHarnessTests.swift")
DURATIONS = os.path.join(ROOT, "scripts", "l1-durations.txt")
PRODUCTS = os.path.join(APP, "build", "DerivedData", "Build", "Products")
WORKER = os.path.join(ROOT, "scripts", "test-offline.sh")
DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17"
SIM_PREFIX = "Latchkey Shard "
SIGNIN = "testSignInTokenIsStrippedFromTheAddress"
SIGNIN_PASS = 6.0      # the second xcodebuild pass the sign-in test needs
UNKNOWN = 15.0         # a test missing from l1-durations.txt
MAX_SHARDS = 9         # harness instances 1-9; 0 is the serial path's
BUDGET = 240


def say(msg):
    print(f"::: {msg}", flush=True)


def run(*cmd, check=True):
    return subprocess.run(cmd, check=check, capture_output=True, text=True).stdout


# ------------------------------------------------------------ simulators ----
def devices():
    """name -> (udid, state) for every available simulator."""
    out = json.loads(run("xcrun", "simctl", "list", "devices", "available", "-j"))["devices"]
    return {d["name"]: (d["udid"], d["state"]) for ds in out.values() for d in ds}


def shard_sims():
    """(k, name, udid, state) for every existing shard simulator, by k."""
    found = []
    for name, (udid, state) in devices().items():
        m = re.fullmatch(re.escape(SIM_PREFIX) + r"(\d+)", name)
        if m:
            found.append((int(m.group(1)), name, udid, state))
    return sorted(found)


def ios_runtime():
    runtimes = json.loads(run("xcrun", "simctl", "list", "runtimes", "-j"))["runtimes"]
    ios = [r for r in runtimes if r["platform"] == "iOS" and r["isAvailable"]]
    if not ios:
        sys.exit("error: no iOS simulator runtime is installed")
    return max(ios, key=lambda r: [int(x) for x in r["version"].split(".")])["identifier"]


def sims_up(n):
    """Create and boot shards 1..n, one at a time. Returns [(name, udid)]."""
    have = devices()
    out = []
    for k in range(1, n + 1):
        name = f"{SIM_PREFIX}{k}"
        udid, state = have.get(name, (None, None))
        if udid is None:
            say(f"creating simulator {name}")
            udid = run("xcrun", "simctl", "create", name, DEVICE_TYPE, ios_runtime()).strip()
            state = "Shutdown"
        if state != "Booted":
            say(f"booting {name} (a first boot is ~20 s; it stays booted: "
                f"scripts/test-offline-shards.py sims down)")
            t0 = time.monotonic()
            run("xcrun", "simctl", "bootstatus", udid, "-b")
            print(f"    booted in {time.monotonic() - t0:.0f} s", flush=True)
        out.append((name, udid))
    return out


def sims_command(args):
    sims = shard_sims()
    if args.action in (None, "status"):
        if not sims:
            print("no shard simulators")
        for k, name, udid, state in sims:
            print(f"{name:20} {state:9} {udid}")
    elif args.action == "up":
        sims_up(args.n or default_shards())
    elif args.action in ("down", "delete"):
        for k, name, udid, state in sims:
            if state != "Shutdown":
                run("xcrun", "simctl", "shutdown", udid, check=False)
                print(f"shut down {name}")
            if args.action == "delete":
                run("xcrun", "simctl", "delete", udid)
                print(f"deleted {name}")
        if not sims:
            print("no shard simulators")


# ------------------------------------------------------------------ plan ----
def file_tests():
    """The file's test names, and the groups that must share a shard: tests
    whose body calls settledDefaultRun() share one launch, which only the
    first of them in a process pays."""
    src = open(SWIFT).read()
    names = re.findall(r"^\s*func (test[A-Za-z0-9_]*)\(", src, re.M)
    starts = [m.start() for m in re.finditer(r"^    (?:private |static |@\w+ )*func ", src, re.M)]
    shared = []
    for name in names:
        at = src.index(f"func {name}(")
        end = next((s for s in starts if s > at), len(src))
        if "settledDefaultRun()" in src[at:end]:
            shared.append(name)
    return names, [shared] if len(shared) > 1 else []


def durations():
    table = {}
    for line in open(DURATIONS):
        line = line.split("#", 1)[0].split()
        if len(line) == 2:
            table[line[1]] = float(line[0])
    return table


def plan(n):
    names, groups = file_tests()
    table = durations()
    missing = [t for t in names if t not in table]
    if missing:
        say(f"WARNING: no duration in {os.path.relpath(DURATIONS, ROOT)} for "
            f"{', '.join(missing)}; planned at {UNKNOWN:.0f} s each")
    grouped = {t for g in groups for t in g}
    units = [list(g) for g in groups] + [[t] for t in names if t not in grouped]

    def weight(unit):
        return sum(table.get(t, UNKNOWN) + (SIGNIN_PASS if t == SIGNIN else 0) for t in unit)

    shards = [{"tests": [], "planned": 0.0} for _ in range(n)]
    for unit in sorted(units, key=lambda u: (-weight(u), u[0])):
        lightest = min(shards, key=lambda s: s["planned"])
        lightest["tests"] += unit
        lightest["planned"] += weight(unit)
    for s in shards:
        s["tests"].sort()
    return names, shards


# ----------------------------------------------------------------- build ----
def xctestrun():
    found = [os.path.join(PRODUCTS, f) for f in os.listdir(PRODUCTS)
             if f.endswith(".xctestrun")] if os.path.isdir(PRODUCTS) else []
    if not found:
        sys.exit(f"error: no .xctestrun in {PRODUCTS}; run with --build")
    return max(found, key=os.path.getmtime)


def build(sim_name):
    env = dict(os.environ, SIM_NAME=sim_name)
    env.pop("LATCHKEY_SHARD_TESTS", None)
    say(f"build, once for every shard (on {sim_name})")
    t0 = time.monotonic()
    if subprocess.run([WORKER, "--serial", "--build-only"], env=env).returncode != 0:
        sys.exit("error: the build failed; no shard was started")
    return time.monotonic() - t0


# ---------------------------------------------------------------- shards ----
def start_shard(k, shard, testrun, log_dir, n):
    env = dict(os.environ,
               LATCHKEY_INSTANCE=str(k), SIM_NAME=shard["sim"],
               LATCHKEY_SHARD=f"{k}/{n}", LATCHKEY_SHARD_TESTS=" ".join(shard["tests"]),
               LATCHKEY_XCTESTRUN=testrun, LATCHKEY_LOG_DIR=shard["dir"])
    out = open(os.path.join(log_dir, f"shard-{k}.out"), "w")
    err = open(os.path.join(log_dir, f"shard-{k}.err"), "w")
    # Its own process group, so a shard past its time limit goes with all of
    # its xcodebuild children.
    shard["proc"] = subprocess.Popen([WORKER], env=env, stdout=out, stderr=err,
                                     start_new_session=True)
    shard["t0"] = time.monotonic()


def wait_shards(shards):
    live = dict(shards)
    while live:
        time.sleep(1)
        for k, s in list(live.items()):
            rc = s["proc"].poll()
            elapsed = time.monotonic() - s["t0"]
            if rc is None and elapsed > s["limit"]:
                os.killpg(s["proc"].pid, signal.SIGTERM)
                time.sleep(5)
                try:
                    os.killpg(s["proc"].pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                rc = s["proc"].wait()
                s["timed_out"] = True
            if rc is not None:
                s["rc"], s["elapsed"] = rc, elapsed
                del live[k]
                print(f"    shard {k} finished in {elapsed:.0f} s (exit {rc}"
                      f"{', killed at its time limit' if s.get('timed_out') else ''})", flush=True)


def xcresult_tests(bundle):
    """name -> (result, seconds, [failure messages]) from one xcresult."""
    if not os.path.isdir(bundle):
        return {}
    got = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "tests",
                          "--path", bundle, "--compact"], capture_output=True, text=True)
    if got.returncode != 0:
        return {}
    found = {}

    def failures(node):
        msgs = [node["name"]] if "Failure" in node.get("nodeType", "") else []
        for c in node.get("children", []):
            msgs += failures(c)
        return msgs

    def walk(node):
        if node.get("nodeType") == "Test Case":
            name = node["name"].removesuffix("()")
            found[name] = (node.get("result", "?"), node.get("durationInSeconds") or 0.0,
                           [m for c in node.get("children", []) for m in failures(c)])
            return
        for c in node.get("children", []):
            walk(c)

    for node in json.loads(got.stdout).get("testNodes", []):
        walk(node)
    return found


def log_failures(shard_dir, name):
    """A failed test's `error:` lines from the worker's xcodebuild log, for
    when the xcresult carries no message."""
    path = os.path.join(shard_dir, "test.log")
    if not os.path.exists(path):
        return []
    return [l.strip() for l in open(path, errors="replace")
            if " error: " in l and f" {name}]" in l][:10]


def sim_state(udid):
    for name, (u, state) in devices().items():
        if u == udid:
            return state
    return "gone"


# ----------------------------------------------------------------- main ----
def default_shards():
    return int(os.environ.get("LATCHKEY_SHARDS", "4"))


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--shards", type=int, default=default_shards())
    p.add_argument("--build", action="store_true")
    sub = p.add_subparsers(dest="cmd")
    s = sub.add_parser("sims", help="list, boot, shut down or delete the shard simulators")
    s.add_argument("action", nargs="?", choices=["status", "up", "down", "delete"])
    s.add_argument("n", nargs="?", type=int)
    args = p.parse_args()
    if args.cmd == "sims":
        return sims_command(args)
    n = args.shards
    if not 2 <= n <= MAX_SHARDS:
        sys.exit(f"error: --shards must be 2-{MAX_SHARDS} (1 is test-offline.sh --serial), not {n}")

    stamp = time.strftime("%Y%m%d-%H%M%S")
    log_dir = os.path.join(APP, "build", "offline-logs", f"{stamp}-shards")
    os.makedirs(log_dir)

    # Untimed: simulators, then the one build.
    sims = sims_up(n)
    build_s = build(sims[0][0]) if args.build else None
    testrun = xctestrun()

    start = time.monotonic()
    names, planned = plan(n)
    shards = {}
    say(f"L1 on {n} simulators: {len(names)} tests, "
        f"{os.path.relpath(testrun, ROOT)}")
    for k, (shard, (sim, udid)) in enumerate(zip(planned, sims), start=1):
        shard.update(sim=sim, udid=udid, dir=os.path.join(log_dir, f"shard-{k}"),
                     limit=2 * shard["planned"] + 300)
        shards[k] = shard
        print(f"    shard {k}  {sim:18}  instance {k}  {len(shard['tests']):2} tests  "
              f"planned {shard['planned']:5.0f} s{'  + R1 scan' if SIGNIN in shard['tests'] else ''}")
    for k, shard in shards.items():
        start_shard(k, shard, testrun, log_dir, n)
    say(f"running; logs in {log_dir}")
    wait_shards(shards)
    for k in shards:   # a shard killed at its limit could not stop its own harness
        subprocess.run(["make", "-C", HARNESS, "--no-print-directory", f"INSTANCE={k}",
                        "harness-down"], capture_output=True)

    # ------------------------------------------------------------ verdict --
    results = {}
    for k, s in shards.items():
        got = {}
        for bundle in ("suite.xcresult", "signin.xcresult"):
            got.update(xcresult_tests(os.path.join(s["dir"], bundle)))
        s["state_after"] = sim_state(s["udid"])
        for t in s["tests"]:
            result, secs, msgs = got.pop(t, ("Not run", 0.0, []))
            if result != "Passed" and not msgs:
                msgs = log_failures(s["dir"], t)
            results.setdefault(t, []).append(
                {"shard": k, "sim": s["sim"], "result": result, "seconds": secs, "failures": msgs})
        for t, (result, secs, msgs) in got.items():   # ran, but was not this shard's
            results.setdefault(t, []).append(
                {"shard": k, "sim": s["sim"], "result": f"{result} (unplanned)",
                 "seconds": secs, "failures": msgs})

    elapsed = time.monotonic() - start
    say("results")
    failed, not_run = [], []
    for t in sorted(results, key=str.lower):
        for r in results[t]:
            ok = r["result"] == "Passed" and len(results[t]) == 1
            print(f"    {'passed' if ok else r['result'].upper():8} {r['seconds']:5.1f} s  "
                  f"{t}  [shard {r['shard']}]", flush=True)
            if not ok:
                (not_run if r["result"] == "Not run" else failed).append((t, r))
    missing = [t for t in names if t not in results]
    extra = [t for t in results if t not in names]

    shard_errors = []
    for k, s in shards.items():
        why = []
        if s.get("timed_out"):
            why.append(f"killed after {s['limit']:.0f} s, its time limit")
        if s["state_after"] != "Booted":
            why.append(f"its simulator {s['sim']} is {s['state_after']} after the run")
        if s["rc"] != 0 or why:
            err = open(os.path.join(log_dir, f"shard-{k}.err"), errors="replace").read().splitlines()
            shard_errors.append((k, s, why, err))

    passed = sum(1 for t in names if len(results.get(t, [])) == 1 and results[t][0]["result"] == "Passed")
    with open(os.path.join(log_dir, "tests.txt"), "w") as f:
        for t in sorted(results):
            for r in results[t]:
                f.write(f"{t} {r['result'].replace(' ', '_')} shard-{r['shard']}\n")
    with open(os.path.join(log_dir, "durations.txt"), "w") as f:
        for t in names:
            for r in results.get(t, []):
                if r["result"] == "Passed":
                    f.write(f"{r['seconds']:.1f} {t}\n")
    with open(os.path.join(log_dir, "results.json"), "w") as f:
        json.dump({"shards": n, "elapsed": elapsed, "build": build_s, "xctestrun": testrun,
                   "plan": {k: {"sim": s["sim"], "tests": s["tests"], "planned": s["planned"],
                                "elapsed": s["elapsed"], "rc": s["rc"]} for k, s in shards.items()},
                   "results": results}, f, indent=1)

    # Failures last, each under its own name, so they are what is left on screen.
    for t, r in failed + not_run:
        print(f"\nFAILED {t}  (shard {r['shard']}, {r['sim']}, {r['result']})", flush=True)
        for m in r["failures"] or ["(no failure message recorded)"]:
            print(f"    {m}")
        if r["result"] == "Not run":
            print(f"    it never reported a result; see the shard's failure below")
    for t in missing:
        print(f"\nFAILED {t}  (planned on no shard: a bug in the plan)")
    for k, s, why, err in shard_errors:
        print(f"\nFAILED shard {k} ({s['sim']}, instance {k}): exit {s['rc']}"
              + (f"; {'; '.join(why)}" if why else ""), flush=True)
        for line in err[-25:]:
            print(f"    {line}")
        print(f"    output: {os.path.join(log_dir, f'shard-{k}.out')}")

    bad = len(names) - passed
    tail = f"in {elapsed:.0f} s" + (f" (after a {build_s:.0f} s build)" if build_s else "")
    if bad or missing or extra or shard_errors:
        say(f"FAILED: {passed} of {len(names)} passed, {len(failed)} failed, {len(not_run)} not run, "
            f"{len(shard_errors)} shard(s) failed, {tail} — logs in {log_dir}")
        return 1
    say(f"passed: {passed} of {len(names)} on {n} simulators {tail} (budget: {BUDGET}s)")
    if elapsed > BUDGET:
        say(f"WARNING: over the budget of {BUDGET} s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
