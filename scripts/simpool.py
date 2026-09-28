#!/usr/bin/env python3
"""A host-bounded pool of simulator slots, shared by every worktree.

    scripts/simpool.py run [--want N] [--floor M] -- command [args...]
    scripts/simpool.py status              each slot: free or held, and by what
    scripts/simpool.py prune               shut down idle simulators outside the pool
    scripts/simpool.py mem [--every S]     memory of each pool simulator and of xcodebuild
    scripts/simpool.py sims [up [N] | down | delete]

The suite runners take their slots themselves, so a caller needs no lock of
its own and two worktrees can run suites at once: scripts/shards.py calls
acquire() for its shards, and a serial run on a pool simulator (SIM_NAME=
"Latchkey Shard k") holds slot k through scripts/lib-sim.sh.

WHY. Every simulator run used to queue on one global lock, so a one-test run
waited behind an eight-shard suite. What bounds how many simulators can run
at once is the host's memory, not its cores: a booted simulator idles at
about 2.5 GB of footprint and carries the app, WebKit and the test runner at
about 3 GB, and each xcodebuild driving one costs about 0.4 GB more
(measured 2026-09-26). SIZE slots fit in the 64 GB host
with room for a build and the rest of the machine.

SLOTS. Slot k (1..SIZE) is the simulator "Latchkey Shard k" and harness
instance k (ports +100*k in testing/harness and testing/tsnet-harness): one
slot is one simulator and one set of ports, so runs on different slots never
meet. Instance 0 and "iPhone 17" are outside the pool. `prune` (which `run`
does for every run) shuts down any booted simulator that is not a pool
device and has no test running in it, so the host never carries more booted
simulators than the pool has slots.

HOLDING. A slot is an exclusive flock(2) on <pool dir>/slot-k.lock. `run`
takes the locks, marks the descriptors inheritable, sets LATCHKEY_SLOTS
("2 5 7") and LATCHKEY_SLOT_FDS, and execs the command. Every process of the
run inherits the descriptors, and the kernel releases a lock only when the
last descriptor on it is closed: a crash, a kill -9, a killed process group,
all release the slot. Nothing is written to the lock files and there are no
pid files to go stale. A harness daemon that outlives a SIGKILLed run keeps
its slot, and rightly: its ports are in use until `make -C testing/harness
harness-down INSTANCE=k` (`status` names the holder).

ACQUIRING. A run asks for `want` slots and needs at least `floor`. A single
test, an ONLY_TESTS run and the one-simulator suites want 1; a sharded suite
wants its shard count and takes what is free, at least 2, so it neither
starves down to serial nor waits for the whole pool. A run whose floor is
met at once keeps what it got and does not queue, so a single test slips in
whenever a slot is free. One that cannot reach its floor lets go of anything
it took and waits on queue.lock, one waiter at a time: the head waiter holds
what it can and polls for the rest, and no one behind it holds anything, so
two suites can never each hold part of the pool waiting for the other's.

The pool dir is ~/Library/Caches/latchkey-simpool: the simulators are the
host's, not one clone's. LATCHKEY_SIMPOOL_DIR overrides it, for tests.
"""

import argparse
import ctypes
import fcntl
import json
import os
import re
import subprocess
import sys
import time

# The pool's size: how many simulators this host runs at once. See WHY above
# before changing it, and change it in one place -- every worktree's copy of this file must agree, or
# the bound is the largest of them.
SIZE = 8
SIM_PREFIX = "Latchkey Shard "
DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17"
# A process inside a simulator that means a test is using it: our app, its
# test runner, or XCTest's own agents. System apps (com.apple.*) do not count.
IN_USE = re.compile(r"UIKitApplication:net\.lixom\.|xctrunner|xctest", re.I)


def say(msg):
    print(f"::: simpool: {msg}", flush=True)


def run(*cmd, check=True):
    return subprocess.run(cmd, check=check, capture_output=True, text=True).stdout


def pool_dir():
    d = os.environ.get("LATCHKEY_SIMPOOL_DIR") or os.path.expanduser("~/Library/Caches/latchkey-simpool")
    os.makedirs(d, exist_ok=True)
    return d


def slot_name(k):
    return f"{SIM_PREFIX}{k}"


def slot_of(name):
    m = re.fullmatch(re.escape(SIM_PREFIX) + r"(\d+)", name)
    return int(m.group(1)) if m else None


def slot_fds():
    """The lock descriptors this process inherited from `run`, for a child
    that must keep holding the slots (subprocess closes the rest)."""
    return [int(x) for x in os.environ.get("LATCHKEY_SLOT_FDS", "").split()]


# ------------------------------------------------------------------- locks ----
def try_lock(path):
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except BlockingIOError:
        os.close(fd)
        return None


def slot_path(k):
    return os.path.join(pool_dir(), f"slot-{k}.lock")


def free_slots():
    """The slots nobody holds right now (each is probed and let go)."""
    out = []
    for k in range(1, SIZE + 1):
        fd = try_lock(slot_path(k))
        if fd is not None:
            os.close(fd)
            out.append(k)
    return out


def acquire(want, floor):
    """Hold `want` slots if they are free, at least `floor`. A run that gets
    its floor at once keeps what it got and goes, without queueing; one that
    does not lets go of everything, waits its turn on queue.lock, then holds
    what it can and polls for the rest. Returns ({slot: fd}, seconds waited)."""
    want = max(1, min(want, SIZE))
    floor = max(1, min(floor, want))
    held = {}

    def grab():
        for k in range(1, SIZE + 1):
            if len(held) >= want:
                break
            if k not in held:
                fd = try_lock(slot_path(k))
                if fd is not None:
                    held[k] = fd

    t0 = time.monotonic()
    grab()
    if len(held) >= floor:
        return held, 0.0
    # Under the floor: hold nothing while waiting for the queue, so two runs
    # can never each hold part of the pool waiting for the other's part.
    for fd in held.values():
        os.close(fd)
    held.clear()
    qpath = os.path.join(pool_dir(), "queue.lock")
    qfd = try_lock(qpath)
    if qfd is None:
        say(f"another run is waiting for slots; queued behind it ({len(free_slots())} of {SIZE} free)")
        qfd = os.open(qpath, os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(qfd, fcntl.LOCK_EX)
    told = None
    while True:
        grab()
        if len(held) >= floor:
            break
        now = time.monotonic()
        if told is None or now - told >= 60:
            have = f"holding {' '.join(map(str, sorted(held)))}, " if held else ""
            say(f"{have}waiting for {floor - len(held)} more slot(s) of {SIZE}, all held "
                f"({now - t0:.0f} s so far; scripts/simpool.py status shows by what)")
            told = now
        time.sleep(1)
    fcntl.flock(qfd, fcntl.LOCK_UN)
    os.close(qfd)
    return held, time.monotonic() - t0


# -------------------------------------------------------------- simulators ----
def devices():
    """name -> (udid, state) for every available simulator."""
    out = json.loads(run("xcrun", "simctl", "list", "devices", "available", "-j"))["devices"]
    return {d["name"]: (d["udid"], d["state"]) for ds in out.values() for d in ds}


def sim_state(udid):
    for name, (u, state) in devices().items():
        if u == udid:
            return state
    return "gone"


def shard_sims():
    """(k, name, udid, state) for every existing shard simulator, by k."""
    found = []
    for name, (udid, state) in devices().items():
        k = slot_of(name)
        if k is not None:
            found.append((k, name, udid, state))
    return sorted(found)


def ios_runtime():
    runtimes = json.loads(run("xcrun", "simctl", "list", "runtimes", "-j"))["runtimes"]
    ios = [r for r in runtimes if r["platform"] == "iOS" and r["isAvailable"]]
    if not ios:
        sys.exit("error: no iOS simulator runtime is installed")
    return max(ios, key=lambda r: [int(x) for x in r["version"].split(".")])["identifier"]


def ensure_devices(slots):
    """Create any pool simulator that does not exist. Booting is the run's:
    every runner does `simctl bootstatus -b` on its simulator."""
    have = devices()
    for k in slots:
        if slot_name(k) not in have:
            say(f"creating simulator {slot_name(k)}")
            run("xcrun", "simctl", "create", slot_name(k), DEVICE_TYPE, ios_runtime())


def sims_up(slots, prog="scripts/simpool.py"):
    """Create and boot the given slots' simulators, one at a time (a first
    boot is 20-23 s; twelve at once took minutes, F14 §9). Returns
    [(name, udid)] in slot order."""
    have = devices()
    out = []
    for k in slots:
        name = slot_name(k)
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



def sim_pids(udid):
    """pid -> label for every process running inside a booted simulator."""
    out = subprocess.run(["xcrun", "simctl", "spawn", udid, "launchctl", "list"],
                         capture_output=True, text=True).stdout
    pids = {}
    for line in out.splitlines():
        f = line.split()
        if len(f) >= 3 and f[0].isdigit():
            pids[int(f[0])] = f[2]
    return pids


def in_use(udid):
    return any(IN_USE.search(label) for label in sim_pids(udid).values())


def prune(quiet=False):
    """Shut down every booted simulator that is not a pool device and has no
    test running in it. Returns the names shut down."""
    pool = {slot_name(k) for k in range(1, SIZE + 1)}
    gone = []
    for name, (udid, state) in sorted(devices().items()):
        if state != "Booted" or name in pool:
            continue
        if in_use(udid):
            if not quiet:
                say(f"{name} is outside the pool but a test is running in it; left booted")
            continue
        subprocess.run(["xcrun", "simctl", "shutdown", udid], capture_output=True)
        say(f"shut down {name}: booted outside the pool, idle")
        gone.append(name)
    return gone


# ------------------------------------------------------------------ memory ----
_libc = None


def footprint(pid):
    """A process's phys_footprint in bytes (what Activity Monitor calls
    Memory), from proc_pid_rusage; None if it is gone or not ours."""
    global _libc
    if _libc is None:
        _libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    buf = ctypes.create_string_buffer(96)   # struct rusage_info_v0
    if _libc.proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(0), buf) != 0:
        return None
    return int.from_bytes(buf.raw[72:80], "little")   # ri_phys_footprint


def pgrep(name):
    out = subprocess.run(["pgrep", "-x", name], capture_output=True, text=True).stdout
    return [int(p) for p in out.split()]


def mem_sample():
    """One sample: host level, each booted simulator's footprint, xcodebuild's."""
    sims = []
    for name, (udid, state) in sorted(devices().items()):
        if state != "Booted":
            continue
        pids = sim_pids(udid)
        sizes = {p: footprint(p) or 0 for p in pids}
        top = sorted(sizes.items(), key=lambda kv: -kv[1])[:3]
        sims.append({"name": name, "in_pool": name in {slot_name(k) for k in range(1, SIZE + 1)},
                     "procs": len(pids), "mb": sum(sizes.values()) / 2**20,
                     "in_use": any(IN_USE.search(l) for l in pids.values()),
                     "top": [(pids[p].split("[")[0], s / 2**20) for p, s in top]})
    xcb = [footprint(p) or 0 for p in pgrep("xcodebuild")]
    return {
        "t": time.time(),
        "free_pct": int(run("sysctl", "-n", "kern.memorystatus_level").strip()),
        "swap": run("sysctl", "-n", "vm.swapusage").strip(),
        "sims": sims,
        "xcodebuild": {"n": len(xcb), "mb": sum(xcb) / 2**20},
    }


def cmd_mem(args):
    total_gb = int(run("sysctl", "-n", "hw.memsize")) / 2**30
    print(f"host: {total_gb:.0f} GB; pool SIZE={SIZE}", flush=True)
    while True:
        s = mem_sample()
        sims_mb = sum(x["mb"] for x in s["sims"])
        print(f"{time.strftime('%H:%M:%S')}  free {s['free_pct']:2d}%  swap [{s['swap']}]  "
              f"{len(s['sims'])} booted = {sims_mb:.0f} MB  xcodebuild x{s['xcodebuild']['n']} = "
              f"{s['xcodebuild']['mb']:.0f} MB", flush=True)
        for x in s["sims"]:
            tag = "" if x["in_pool"] else "  (outside the pool)"
            use = "in use" if x["in_use"] else "idle"
            top = ", ".join(f"{n}={m:.0f}" for n, m in x["top"])
            print(f"    {x['name']:20} {x['mb']:6.0f} MB  {x['procs']:3d} procs  {use:6}  {top}{tag}", flush=True)
        if not args.every:
            return 0
        time.sleep(args.every)


# ---------------------------------------------------------------- commands ----
def cmd_run(args):
    cmd = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not cmd:
        sys.exit("usage: simpool.py run [--want N] [--floor M] -- command [args...]")
    held, waited = acquire(args.want, args.floor)
    slots = sorted(held)
    ensure_devices(slots)
    prune(quiet=True)
    for fd in held.values():
        os.set_inheritable(fd, True)
    env = dict(os.environ,
               LATCHKEY_SLOTS=" ".join(map(str, slots)),
               LATCHKEY_SLOT_FDS=" ".join(str(held[k]) for k in slots))
    want = max(1, min(args.want, SIZE))
    say(f"slot{'s' if len(slots) > 1 else ''} {' '.join(map(str, slots))} of {SIZE}"
        + (f" (asked for {want}; the rest are held)" if len(slots) < want else "")
        + (f", after waiting {waited:.0f} s" if waited >= 1 else ""))
    os.execvpe(cmd[0], cmd, env)


def holders(path):
    """(pid, command) for every process holding the lock file open."""
    out = subprocess.run(["lsof", "-w", "-F", "pc", path], capture_output=True, text=True).stdout
    found, pid = [], None
    for line in out.splitlines():
        if line.startswith("p"):
            pid = int(line[1:])
        elif line.startswith("c") and pid is not None:
            found.append((pid, line[1:]))
    return found


def cmd_status(args):
    devs = devices()
    print(f"pool of {SIZE} slots in {pool_dir()}")
    for k in range(1, SIZE + 1):
        udid, state = devs.get(slot_name(k), (None, "missing"))
        fd = try_lock(slot_path(k))
        if fd is not None:
            os.close(fd)
            who = "free"
        else:
            hs = holders(slot_path(k))
            who = "held by " + (", ".join(f"{c}[{p}]" for p, c in hs[:4]) + (" ..." if len(hs) > 4 else "")
                                if hs else "a process lsof cannot see")
        print(f"  slot {k}  {slot_name(k):18} {state:9} {who}")
    qfd = try_lock(os.path.join(pool_dir(), "queue.lock"))
    if qfd is None:
        print("  a run is queued, waiting for slots")
    else:
        os.close(qfd)
    outside = [n for n, (u, s) in sorted(devs.items()) if s == "Booted" and slot_of(n) not in range(1, SIZE + 1)]
    if outside:
        print(f"  booted outside the pool: {', '.join(outside)} (scripts/simpool.py prune shuts idle ones down)")
    return 0


def cmd_prune(args):
    if not prune():
        print("nothing booted outside the pool")
    return 0


def sims_command(action, n, prog="scripts/simpool.py"):
    sims = shard_sims()
    if action in (None, "status"):
        if not sims:
            print("no shard simulators")
        for k, name, udid, state in sims:
            print(f"{name:20} {state:9} {udid}{'' if k <= SIZE else '  (outside the pool)'}")
    elif action == "up":
        n = min(n or SIZE, SIZE)
        sims_up(range(1, n + 1), prog)
    elif action in ("down", "delete"):
        for k, name, udid, state in sims:
            # A held slot is another run's simulator: the slot is taken for
            # the shutdown, and left alone if a run has it.
            fd = try_lock(slot_path(k)) if 1 <= k <= SIZE else None
            if 1 <= k <= SIZE and fd is None:
                print(f"{name}: a run holds its slot ({prog} status); left as it is")
                continue
            if state != "Shutdown":
                run("xcrun", "simctl", "shutdown", udid, check=False)
                print(f"shut down {name}")
            if action == "delete":
                run("xcrun", "simctl", "delete", udid)
                print(f"deleted {name}")
            if fd is not None:
                os.close(fd)
        if not sims:
            print("no shard simulators")
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", help="hold slots and exec a command under them")
    r.add_argument("--want", type=int, default=1, help="slots to take if free (default 1)")
    r.add_argument("--floor", type=int, default=None, help="slots to wait for (default: --want, capped at 2)")
    r.add_argument("command", nargs=argparse.REMAINDER)
    sub.add_parser("status", help="each slot: free or held, and by what")
    sub.add_parser("prune", help="shut down idle simulators outside the pool")
    m = sub.add_parser("mem", help="memory of each booted simulator and of xcodebuild")
    m.add_argument("--every", type=float, default=0, help="sample every S seconds until interrupted")
    s = sub.add_parser("sims", help="list, boot, shut down or delete the pool simulators")
    s.add_argument("action", nargs="?", choices=["status", "up", "down", "delete"])
    s.add_argument("n", nargs="?", type=int)
    args = p.parse_args()
    if args.cmd == "run":
        if args.floor is None:
            args.floor = min(args.want, 2)
        return cmd_run(args)
    if args.cmd == "sims":
        return sims_command(args.action, args.n)
    return {"status": cmd_status, "prune": cmd_prune, "mem": cmd_mem}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
