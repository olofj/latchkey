"""A UI suite across N simulators at once (F14): the part every suite shares.

scripts/test-offline-shards.py (L1) and scripts/test-session-shards.py (the
session suite) each describe their suite as a Suite and call main(). Each
shard is the suite's own script, run as a worker on its own simulator
("Latchkey Shard k") against its own harness instance k (ports +100*k,
testing/harness/Makefile), with a list of tests: preflight, self-tests, the
tests, the log scans and the teardown are the serial path's own, not a copy.

  1. simulators  create and boot any shard simulator that is not booted,
                 one at a time, before anything is timed (a first boot is
                 20-23 s; twelve at once took minutes, F14 §9). They stay
                 booted for the next run: `sims down` shuts them down,
                 `sims delete` removes them, `sims` lists them.
  2. build       with --build, once, before the shards start; every shard
                 then runs test-without-building against the one .xctestrun.
                 N builds at once would race in one DerivedData.
  3. plan        the suite's tests, packed onto N shards longest first by its
                 durations file. Tests that must share a shard stay together.
  4. shards      all N at once, each in its own process group, each with a
                 time limit; a shard past it is killed and its harness
                 stopped.
  5. verdict     every test's result from its shard's xcresult and log,
                 under its own name, with its failure messages and the shard
                 and simulator it ran on. It passes only if each of the
                 suite's tests passed exactly once, every shard exited 0 and
                 still has its simulator booted, and the suite's own
                 cross-shard checks hold: a test that never reported (a
                 simulator that died, a harness that never came up) is a
                 failure, never a skip.

Logs: <log root>/<stamp>-shards/, one shard-k/ per shard (the worker's own
logs and xcresults), shard-k.out/.err (its output), results.json, tests.txt
(one `name result shard` line per test, sorted, to diff) and durations.txt
(this run's, in the durations file's format, to refresh it from).
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
PRODUCTS = os.path.join(APP, "build", "DerivedData", "Build", "Products")
DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17"
SIM_PREFIX = "Latchkey Shard "
MAX_SHARDS = 9         # harness instances 1-9; 0 is the serial path's


class Suite:
    """What differs between suites. Test ids are what the worker takes in
    LATCHKEY_SHARD_TESTS and what the durations file names."""
    name = ""
    worker = ""            # the suite's script, run once per shard
    log_root = ""          # app/build/<suite>-logs
    durations = ""         # "<seconds> <test id>" per line
    shards = 4             # the default N (LATCHKEY_SHARDS overrides)
    budget = 0             # seconds, for the sharded default
    unknown = 15.0         # a test missing from the durations file
    logs = ()              # the worker's xcodebuild logs in its log dir, by label
    teardown = ("harness-down",)   # make targets that stop an instance

    def tests(self):
        """([test ids], [[ids that must share a shard], ...])"""
        raise NotImplementedError

    def test_id(self, cls, name):
        raise NotImplementedError

    def weight(self, test, table):
        return table.get(test, self.unknown)

    def note(self, tests):
        """Said after a shard's line in the plan."""
        return ""

    def prepare(self):
        """Untimed, once, before the shards start."""

    def check(self, shards):
        """Failures of the suite's own cross-shard checks, as strings."""
        return []


def say(msg):
    print(f"::: {msg}", flush=True)


def run(*cmd, check=True):
    return subprocess.run(cmd, check=check, capture_output=True, text=True).stdout


def swift_tests(path):
    """(class, [test names]) in one XCTestCase file."""
    src = open(path).read()
    return os.path.basename(path).removesuffix(".swift"), re.findall(r"^\s*func (test[A-Za-z0-9_]*)\(", src, re.M)


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


def sims_up(n, prog):
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
            say(f"booting {name} (a first boot is ~20 s; it stays booted: {prog} sims down)")
            t0 = time.monotonic()
            run("xcrun", "simctl", "bootstatus", udid, "-b")
            print(f"    booted in {time.monotonic() - t0:.0f} s", flush=True)
        out.append((name, udid))
    return out


def sims_command(args, prog):
    sims = shard_sims()
    if args.action in (None, "status"):
        if not sims:
            print("no shard simulators")
        for k, name, udid, state in sims:
            print(f"{name:20} {state:9} {udid}")
    elif args.action == "up":
        sims_up(args.n or args.shards, prog)
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
def durations(path):
    table = {}
    for line in open(path):
        line = line.split("#", 1)[0].split()
        if len(line) == 2:
            table[line[1]] = float(line[0])
    return table


def plan(suite, n):
    names, groups = suite.tests()
    table = durations(suite.durations)
    missing = [t for t in names if t not in table]
    if missing:
        say(f"WARNING: no duration in {os.path.relpath(suite.durations, ROOT)} for "
            f"{', '.join(missing)}; planned at {suite.unknown:.0f} s each")
    grouped = {t for g in groups for t in g}
    units = [list(g) for g in groups] + [[t] for t in names if t not in grouped]

    def weight(unit):
        return sum(suite.weight(t, table) for t in unit)

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


def build(suite, sim_name):
    env = dict(os.environ, SIM_NAME=sim_name)
    env.pop("LATCHKEY_SHARD_TESTS", None)
    say(f"build, once for every shard (on {sim_name})")
    t0 = time.monotonic()
    if subprocess.run([suite.worker, "--serial", "--build-only"], env=env).returncode != 0:
        sys.exit("error: the build failed; no shard was started")
    return time.monotonic() - t0


# ---------------------------------------------------------------- shards ----
def start_shard(suite, k, shard, testrun, log_dir, n):
    env = dict(os.environ,
               LATCHKEY_INSTANCE=str(k), SIM_NAME=shard["sim"],
               LATCHKEY_SHARD=f"{k}/{n}", LATCHKEY_SHARD_TESTS=" ".join(shard["tests"]),
               LATCHKEY_XCTESTRUN=testrun, LATCHKEY_LOG_DIR=shard["dir"])
    out = open(os.path.join(log_dir, f"shard-{k}.out"), "w")
    err = open(os.path.join(log_dir, f"shard-{k}.err"), "w")
    # Its own process group, so a shard past its time limit goes with all of
    # its xcodebuild children.
    shard["proc"] = subprocess.Popen([suite.worker], env=env, stdout=out, stderr=err,
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
                for sig in (signal.SIGTERM, signal.SIGKILL):
                    try:
                        os.killpg(s["proc"].pid, sig)
                    except OSError:   # gone, or only zombies left in the group
                        pass
                    time.sleep(5)
                rc = s["proc"].wait()
                s["timed_out"] = True
            if rc is not None:
                s["rc"], s["elapsed"] = rc, elapsed
                del live[k]
                print(f"    shard {k} finished in {elapsed:.0f} s (exit {rc}"
                      f"{', killed at its time limit' if s.get('timed_out') else ''})", flush=True)


def xcresult_tests(suite, bundle):
    """id -> (result, seconds, [failure messages]) from one xcresult."""
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

    def walk(node, cls):
        if node.get("nodeType") == "Test Suite":
            cls = node["name"]
        if node.get("nodeType") == "Test Case":
            found[suite.test_id(cls, node["name"].removesuffix("()"))] = (
                node.get("result", "?"), node.get("durationInSeconds") or 0.0,
                [m for c in node.get("children", []) for m in failures(c)])
            return
        for c in node.get("children", []):
            walk(c, cls)

    for node in json.loads(got.stdout).get("testNodes", []):
        walk(node, None)
    return found


CASE = re.compile(r"^Test Case '-\[\w+\.(\w+) (test\w+)\]' (passed|failed) \((\d+\.\d+) seconds\)")
ERROR = re.compile(r"^(\S+:\d+): error: -\[\w+\.(\w+) (test\w+)\] : (.*)")


def log_tests(suite, shard_dir):
    """id -> (result, seconds, [failure messages]) from the xcodebuild logs
    as they were written. A shard killed at its time limit leaves an xcresult
    with nothing in it, and its log is then the only record of what ran."""
    found, errors = {}, {}
    for label in suite.logs:
        path = os.path.join(shard_dir, f"{label}.log")
        if not os.path.exists(path):
            continue
        for line in open(path, errors="replace"):
            m = ERROR.match(line)
            if m:
                t = suite.test_id(m.group(2), m.group(3))
                errors.setdefault(t, []).append(f"{m.group(1)}: {m.group(4).strip()}")
            m = CASE.match(line)
            if m:
                t = suite.test_id(m.group(1), m.group(2))
                found[t] = ("Passed" if m.group(3) == "passed" else "Failed",
                            float(m.group(4)), errors.get(t, []))
    return found


def sim_state(udid):
    for name, (u, state) in devices().items():
        if u == udid:
            return state
    return "gone"


# ----------------------------------------------------------------- main ----
def main(suite, doc):
    prog = os.path.relpath(sys.argv[0], ROOT)
    p = argparse.ArgumentParser(description=doc.split("\n")[0])
    p.add_argument("--shards", type=int, default=int(os.environ.get("LATCHKEY_SHARDS", suite.shards)))
    p.add_argument("--build", action="store_true")
    sub = p.add_subparsers(dest="cmd")
    s = sub.add_parser("sims", help="list, boot, shut down or delete the shard simulators")
    s.add_argument("action", nargs="?", choices=["status", "up", "down", "delete"])
    s.add_argument("n", nargs="?", type=int)
    args = p.parse_args()
    if args.cmd == "sims":
        return sims_command(args, prog)
    n = args.shards
    if not 2 <= n <= MAX_SHARDS:
        sys.exit(f"error: --shards must be 2-{MAX_SHARDS} (1 is {os.path.relpath(suite.worker, ROOT)} "
                 f"--serial), not {n}")

    stamp = time.strftime("%Y%m%d-%H%M%S")
    log_dir = os.path.join(suite.log_root, f"{stamp}-shards")
    os.makedirs(log_dir)

    # Untimed: simulators, the one build, the suite's own preparation.
    sims = sims_up(n, prog)
    build_s = build(suite, sims[0][0]) if args.build else None
    testrun = xctestrun()
    suite.prepare()

    start = time.monotonic()
    names, planned = plan(suite, n)
    shards = {}
    say(f"{suite.name} on {n} simulators: {len(names)} tests, "
        f"{os.path.relpath(testrun, ROOT)}")
    for k, (shard, (sim, udid)) in enumerate(zip(planned, sims), start=1):
        shard.update(sim=sim, udid=udid, dir=os.path.join(log_dir, f"shard-{k}"),
                     limit=2 * shard["planned"] + 300)
        shards[k] = shard
        print(f"    shard {k}  {sim:18}  instance {k}  {len(shard['tests']):2} tests  "
              f"planned {shard['planned']:5.0f} s{suite.note(shard['tests'])}")
    for k, shard in shards.items():
        start_shard(suite, k, shard, testrun, log_dir, n)
    say(f"running; logs in {log_dir}")
    wait_shards(shards)
    for k in shards:   # a shard killed at its limit could not stop its own harness
        for target in suite.teardown:
            subprocess.run(["make", "-C", HARNESS, "--no-print-directory", f"INSTANCE={k}",
                            *target.split()], capture_output=True)

    # ------------------------------------------------------------ verdict --
    results = {}
    for k, s in shards.items():
        got = log_tests(suite, s["dir"])
        for label in suite.logs:
            bundle = os.path.join(s["dir"], f"{label}.xcresult")
            for t, (result, secs, msgs) in xcresult_tests(suite, bundle).items():
                # The log's messages carry file:line; the xcresult's do not.
                got[t] = (result, secs, got.get(t, (0, 0, []))[2] or msgs)
        s["state_after"] = sim_state(s["udid"])
        for t in s["tests"]:
            result, secs, msgs = got.pop(t, ("Not run", 0.0, []))
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
    suite_errors = suite.check(shards)

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
        json.dump({"suite": suite.name, "shards": n, "elapsed": elapsed, "build": build_s,
                   "xctestrun": testrun,
                   "plan": {k: {"sim": s["sim"], "tests": s["tests"], "planned": s["planned"],
                                "elapsed": s["elapsed"], "rc": s["rc"]} for k, s in shards.items()},
                   "results": results, "suite_errors": suite_errors}, f, indent=1)

    # Failures last, each under its own name, so they are what is left on screen.
    for t, r in failed + not_run:
        print(f"\nFAILED {t}  (shard {r['shard']}, {r['sim']}, {r['result']})", flush=True)
        if r["result"] == "Not run":
            print(f"    it never reported a result; see the shard's failure below")
        for m in r["failures"] or ([] if r["result"] == "Not run" else ["(no failure message recorded)"]):
            print(f"    {m}")
    for t in missing:
        print(f"\nFAILED {t}  (planned on no shard: a bug in the plan)")
    for msg in suite_errors:
        print(f"\nFAILED {msg}")
    for k, s, why, err in shard_errors:
        print(f"\nFAILED shard {k} ({s['sim']}, instance {k}): exit {s['rc']}"
              + (f"; {'; '.join(why)}" if why else ""), flush=True)
        for line in err[-25:]:
            print(f"    {line}")
        print(f"    output: {os.path.join(log_dir, f'shard-{k}.out')}")

    bad = len(names) - passed
    tail = f"in {elapsed:.0f} s" + (f" (after a {build_s:.0f} s build)" if build_s else "")
    if bad or missing or extra or shard_errors or suite_errors:
        say(f"FAILED: {passed} of {len(names)} passed, {len(failed)} failed, {len(not_run)} not run, "
            f"{len(shard_errors)} shard(s) failed"
            + (f", {len(suite_errors)} check(s) failed" if suite_errors else "")
            + f", {tail} — logs in {log_dir}")
        return 1
    say(f"passed: {passed} of {len(names)} on {n} simulators {tail} (budget: {suite.budget}s)")
    if elapsed > suite.budget:
        say(f"WARNING: over the budget of {suite.budget} s")
    return 0
