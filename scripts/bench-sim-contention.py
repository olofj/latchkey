#!/usr/bin/env python3
"""How much do concurrent simulators slow each other's app launches? (F14 §9)

    scripts/bench-sim-contention.py [--n 1,2,4,6,8,12] [--iterations 10] [--keep]

F14's parallel harness is only worth building if N simulators launching at
once cost about what one does. This measures that and builds nothing.

WHAT IS MEASURED
----------------
L1's own fixed cost, not a stand-in for it: the gate test
`OfflineHarnessTests/testAFirstLaunchExplainsItself` (XCUITest launch with
`-TestStatusFixture` in NeedsLogin, wait for the gate's sign-in button, four
existence checks, terminate), run with `-test-iterations K` on each of N
dedicated simulators at once. The gate needs no node, no control plane, no
certificates and no fake dashboard. The one thing the test needs from the
harness is its setUp's reachability check and resets. A stub that answers 200
on the two control ports serves all N simulators, because the gate test
reads none of that state. Per iteration, from the xcresult activity timeline:

  launch     `Open` to the first UI query: XCUITest automation setup, spawn,
             the app's first frame and XCUITest's idle wait, i.e. launch to a
             usable native screen
  terminate  `Terminate` to `Tear Down`
  test       the whole iteration, which is what a launch costs a test in L1

CONFOUNDERS AND HOW THEY ARE KEPT OUT
-------------------------------------
- First boot: bench simulators are created and booted before anything is
  timed (their first boot is reported separately), the host is left to settle
  (see settle()), then a discarded warm-up round at the largest N runs on all
  of them. Every round starts only once host CPU is back near idle.
- Install: `test-without-building` installs the app and runner before the
  first iteration, and iteration 1 after an install is also the app's cold
  first launch, so iteration 1 of every run is dropped. Install is in no
  number reported.
- Overlap: xcodebuild instances start seconds apart. Only iterations that lie
  wholly inside the window where all N runs were iterating count toward N.
- Host: `iostat` samples CPU every second through each round, and swap,
  `kern.memorystatus_level`, vm_stat pageouts/swapouts and `pmset -g therm`
  are recorded before and after it. A final N=1 round repeats the first as a
  drift/thermal control.

Needs the Testing build products (`scripts/test-offline.sh --build` leaves
them). Results go to app/build/simbench-logs/<stamp>/: results.json,
report.md, one xcresult and log per simulator per round. Bench simulators are
named "Latchkey Bench k" and deleted afterwards unless --keep.
"""

import argparse
import glob
import http.server
import json
import os
import re
import statistics
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "app")
PRODUCTS = os.path.join(APP, "build", "DerivedData", "Build", "Products")
TEST = "LatchkeyUITests/OfflineHarnessTests/testAFirstLaunchExplainsItself"
TEST_ID = "OfflineHarnessTests/testAFirstLaunchExplainsItself()"
DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17"
CONTROL_PORTS = (8480, 1081)   # OfflineHarnessTests.dashboardControl / proxyControl


def run(*cmd, check=True):
    return subprocess.run(cmd, check=check, capture_output=True, text=True).stdout


def say(msg):
    print(f"==> {time.strftime('%H:%M:%S')} {msg}", flush=True)


# ------------------------------------------------------------------ stub ----
class Stub(http.server.BaseHTTPRequestHandler):
    def ok(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")

    do_GET = do_POST = ok

    def log_message(self, *args):
        pass


def start_stub():
    for port in CONTROL_PORTS:
        server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Stub)
        threading.Thread(target=server.serve_forever, daemon=True).start()


# ------------------------------------------------------------ simulators ----
def ios_runtime():
    runtimes = json.loads(run("xcrun", "simctl", "list", "runtimes", "-j"))["runtimes"]
    ios = [r for r in runtimes if r["platform"] == "iOS" and r["isAvailable"]]
    return max(ios, key=lambda r: [int(x) for x in r["version"].split(".")])["identifier"]


def bench_sims(count):
    """Create (or reuse) and boot `count` bench simulators; return their UDIDs
    and the seconds each took to boot."""
    devices = json.loads(run("xcrun", "simctl", "list", "devices", "-j"))["devices"]
    existing = {d["name"]: d["udid"] for ds in devices.values() for d in ds}
    runtime = ios_runtime()
    udids = []
    for k in range(1, count + 1):
        name = f"Latchkey Bench {k}"
        udid = existing.get(name) or run("xcrun", "simctl", "create", name, DEVICE_TYPE, runtime).strip()
        udids.append(udid)

    def boot(udid):
        t0 = time.monotonic()
        run("xcrun", "simctl", "bootstatus", udid, "-b")
        return time.monotonic() - t0

    with ThreadPoolExecutor(len(udids)) as pool:
        boots = list(pool.map(boot, udids))
    return udids, boots


# ------------------------------------------------------------ host probes ----
def host_snapshot():
    vm = run("vm_stat")
    counters = {}
    for key in ("Pageouts", "Swapouts", "Swapins"):
        m = re.search(rf"^{key}:\s+(\d+)", vm, re.M)
        counters[key.lower()] = int(m.group(1)) if m else None
    return {
        "memorystatus_level": int(run("sysctl", "-n", "kern.memorystatus_level").strip()),
        "swapusage": run("sysctl", "-n", "vm.swapusage").strip(),
        "therm": " | ".join(l.strip() for l in run("pmset", "-g", "therm").splitlines() if l.strip()),
        **counters,
    }


class CpuSampler:
    """`iostat -w 1` for the life of a round: user+system % per second."""

    def __init__(self):
        self.samples = []
        self.proc = subprocess.Popen(["iostat", "-n", "0", "-w", "1"],
                                     stdout=subprocess.PIPE, text=True)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            f = line.split()
            if len(f) == 6 and f[0].isdigit():
                self.samples.append((time.time(), int(f[0]) + int(f[1]), float(f[3])))

    def stop(self):
        self.proc.terminate()
        self.proc.wait()
        return self.samples[1:]   # iostat's first line is the since-boot average


def settle(ceiling, timeout):
    """Wait until host CPU busy has a 10 s median under `ceiling` %. A freshly
    booted simulator runs its daemons' first-boot work for minutes (the smoke
    run measured 67 % busy at N=1 against 12 % idle), which would otherwise
    land in whichever round comes first. Returns the seconds waited."""
    cpu = CpuSampler()
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        time.sleep(2)
        recent = [c[1] for c in cpu.samples[1:] if c[0] >= time.time() - 10]
        if len(recent) >= 8 and statistics.median(recent) < ceiling:
            break
    cpu.stop()
    return time.monotonic() - t0


# ----------------------------------------------------------------- rounds ----
def xctestrun():
    found = glob.glob(os.path.join(PRODUCTS, "*.xctestrun"))
    if not found:
        sys.exit(f"error: no .xctestrun in {PRODUCTS}; build first (scripts/test-offline.sh --build)")
    return max(found, key=os.path.getmtime)


def one_sim(testrun, udid, iterations, bundle, log):
    with open(log, "w") as out:
        rc = subprocess.run(
            ["xcodebuild", "test-without-building", "-xctestrun", testrun,
             "-destination", f"platform=iOS Simulator,id={udid}",
             "-resultBundlePath", bundle, "-only-testing:" + TEST,
             "-test-iterations", str(iterations), "-parallel-testing-enabled", "NO",
             "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "120"],
            stdout=out, stderr=subprocess.STDOUT).returncode
    return rc


def iterations_of(bundle):
    """Per iteration: absolute start/end and the launch/terminate/test spans."""
    tests = json.loads(run("xcrun", "xcresulttool", "get", "test-results", "tests",
                           "--path", bundle, "--compact"))
    durations = {}

    def walk(node):
        if node.get("nodeType") == "Repetition":
            durations[int(node["nodeIdentifier"])] = node["durationInSeconds"]
        for child in node.get("children", []):
            walk(child)

    for node in tests["testNodes"]:
        walk(node)
    acts = json.loads(run("xcrun", "xcresulttool", "get", "test-results", "activities",
                          "--path", bundle, "--test-id", TEST_ID, "--compact"))
    out = []
    for i, test_run in enumerate(acts["testRuns"], start=1):
        a = test_run["activities"]
        start = a[0]["startTime"]
        opened = next(x["startTime"] for x in a if x["title"].startswith("Open "))
        first_query = next(x["startTime"] for x in a if x["title"].startswith("Checking existence"))
        term = next(x["startTime"] for x in a if x["title"].startswith("Terminate "))
        down = next(x["startTime"] for x in a if x["title"] == "Tear Down")
        test = durations.get(i)
        out.append({"iteration": i, "start": start, "end": start + test, "test": test,
                    "launch": first_query - opened, "terminate": down - term})
    return out


def round_(label, testrun, udids, iterations, logdir, ceiling):
    waited = settle(ceiling, 120)
    say(f"round {label}: N={len(udids)}, {iterations} iterations each (settled {waited:.0f} s)")
    before = host_snapshot()
    cpu = CpuSampler()
    t0 = time.time()
    with ThreadPoolExecutor(len(udids)) as pool:
        futures = [pool.submit(one_sim, testrun, u, iterations,
                               os.path.join(logdir, f"{label}-sim{k}.xcresult"),
                               os.path.join(logdir, f"{label}-sim{k}.log"))
                   for k, u in enumerate(udids, start=1)]
        rcs = [f.result() for f in futures]
    wall = time.time() - t0
    samples = cpu.stop()
    after = host_snapshot()
    per_sim = [iterations_of(os.path.join(logdir, f"{label}-sim{k}.xcresult"))
               for k in range(1, len(udids) + 1)]
    return {"label": label, "n": len(udids), "rcs": rcs, "wall": wall, "t0": t0,
            "per_sim": per_sim, "cpu": samples, "before": before, "after": after}


def summarise(r):
    # The window in which every simulator was iterating: from the last
    # simulator's first iteration start to the first simulator's last end.
    lo = max(s[0]["start"] for s in r["per_sim"])
    hi = min(s[-1]["end"] for s in r["per_sim"])
    kept = [it for s in r["per_sim"] for it in s[1:] if it["start"] >= lo and it["end"] <= hi]
    dropped_first = [s[0] for s in r["per_sim"]]

    def stats(key, items):
        v = sorted(it[key] for it in items)
        if not v:
            return None
        q = statistics.quantiles(v, n=4) if len(v) > 1 else [v[0]] * 3
        return {"n": len(v), "median": statistics.median(v), "p25": q[0], "p75": q[2],
                "min": v[0], "max": v[-1]}

    busy = [c for c in r["cpu"] if lo <= c[0] <= hi]
    cores = os.cpu_count()
    return {
        "n": r["n"], "label": r["label"], "all_passed": all(rc == 0 for rc in r["rcs"]),
        "window_s": hi - lo,
        "test": stats("test", kept), "launch": stats("launch", kept),
        "terminate": stats("terminate", kept),
        "first_iteration_test": stats("test", dropped_first),
        # Iterations completed per second across all simulators, in the window.
        "throughput_per_s": len([it for s in r["per_sim"] for it in s
                                 if lo <= it["end"] <= hi]) / (hi - lo) if hi > lo else None,
        "cpu_busy_pct": {"median": statistics.median(c[1] for c in busy),
                         "max": max(c[1] for c in busy)} if busy else None,
        "cpu_busy_cores_median": statistics.median(c[1] for c in busy) * cores / 100 if busy else None,
        "load_1m_max": max((c[2] for c in busy), default=None),
        "memorystatus_level": [r["before"]["memorystatus_level"], r["after"]["memorystatus_level"]],
        "swapusage_after": r["after"]["swapusage"],
        "pageouts_delta": r["after"]["pageouts"] - r["before"]["pageouts"],
        "swapouts_delta": r["after"]["swapouts"] - r["before"]["swapouts"],
        "therm_after": r["after"]["therm"],
    }


def report(summaries, boots, idle):
    base = next(s for s in summaries if s["n"] == 1)
    lines = [
        f"Host: {os.cpu_count()} cores; idle CPU busy before start {idle:.0f} %. "
        f"Bench simulator first boot: {', '.join(f'{b:.0f}' for b in boots)} s.",
        "",
        "| round | N | kept | test median s (p25-p75, max) | launch median s (p25-p75) | terminate s "
        "| x N=1 | launches/s all sims | CPU busy med/max % | load 1m max | mem level before/after "
        "| pageouts | swapouts | therm |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for s in summaries:
        t, l, x = s["test"], s["launch"], s["terminate"]
        if not t:
            lines.append(f"| {s['label']} | {s['n']} | 0 | no iterations inside the overlap window |")
            continue
        lines.append(
            f"| {s['label']} | {s['n']} | {t['n']} | {t['median']:.2f} ({t['p25']:.2f}-{t['p75']:.2f}, {t['max']:.2f}) "
            f"| {l['median']:.2f} ({l['p25']:.2f}-{l['p75']:.2f}) | {x['median']:.2f} "
            f"| {t['median'] / base['test']['median']:.2f} | {s['throughput_per_s']:.3f} "
            f"| {s['cpu_busy_pct']['median']:.0f}/{s['cpu_busy_pct']['max']:.0f} | {s['load_1m_max']:.0f} "
            f"| {s['memorystatus_level'][0]}/{s['memorystatus_level'][1]} | {s['pageouts_delta']} "
            f"| {s['swapouts_delta']} | {'none recorded' if 'No thermal warning' in s['therm_after'] else s['therm_after']} |")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--n", default="1,2,4,6,8,12")
    ap.add_argument("--iterations", type=int, default=10)
    ap.add_argument("--keep", action="store_true", help="keep the bench simulators")
    args = ap.parse_args()
    ns = [int(x) for x in args.n.split(",")]
    logdir = os.path.join(APP, "build", "simbench-logs", time.strftime("%Y%m%d-%H%M%S"))
    os.makedirs(logdir)
    say(f"logs: {logdir}")
    testrun = xctestrun()
    start_stub()

    cpu = CpuSampler()
    time.sleep(6)
    idle = statistics.median(c[1] for c in cpu.stop())
    say(f"host CPU busy before start: {idle:.0f} %")

    say(f"creating and booting {max(ns)} bench simulators")
    udids, boots = bench_sims(max(ns))
    say("first boot s: " + ", ".join(f"{b:.1f}" for b in boots))
    ceiling = max(idle + 10, 25)
    waited = settle(ceiling, 600)
    say(f"post-boot settle: {waited:.0f} s to under {ceiling:.0f} % busy")
    try:
        # Warm-up: installs, first launches, dyld and WebKit caches on every
        # simulator. Discarded.
        round_("warmup", testrun, udids, 2, logdir, ceiling)
        rounds = [round_(f"n{n}", testrun, udids[:n], args.iterations, logdir, ceiling) for n in ns]
        rounds.append(round_("n1-control", testrun, udids[:1], args.iterations, logdir, ceiling))
        summaries = [summarise(r) for r in rounds]
        text = report(summaries, boots, idle)
        with open(os.path.join(logdir, "results.json"), "w") as f:
            json.dump({"rounds": rounds, "summaries": summaries, "boots": boots,
                       "idle_cpu_busy_pct": idle, "xctestrun": testrun}, f, indent=1)
        with open(os.path.join(logdir, "report.md"), "w") as f:
            f.write(text + "\n")
        print(text, flush=True)
        if not all(s["all_passed"] for s in summaries):
            say("WARNING: some runs failed; see the per-sim logs")
    finally:
        for u in udids:
            run("xcrun", "simctl", "shutdown", u, check=False)
            if not args.keep:
                run("xcrun", "simctl", "delete", u, check=False)
    say("done")


if __name__ == "__main__":
    main()
