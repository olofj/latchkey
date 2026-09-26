#!/usr/bin/env python3
"""Host test of the review gateway's socket activation (F19, docs/REVIEW-GATEWAY.md).

On the VM, latchkey-review-gateway.socket (Accept=no) holds 127.0.0.1:8444
and starts the service on the first connection, passing the listening
socket as systemd does: fd 3, LISTEN_FDS=1, LISTEN_PID=<the service's pid>.
There is no systemd here, so this test does the same by hand: it binds and
listens, puts the socket on fd 3 of an `sh` that sets LISTEN_PID=$$ and
execs the fake. Each step able to fail:

  * activated: a connection made BEFORE the fake starts (Apple's first
    probe, queued in the backlog) is answered; the demo token redeems; the
    session outlives later connections (one process, state in memory); the
    fake listens on the inherited socket and nothing else, and has no
    control port (--no-control)
  * LISTEN_PID naming another process: the fds are not taken, and the fake
    binds --port itself, as before
  * an inherited fd that is not a listening socket: refused at start
  * started directly with --no-control: serves, and no control port

    python3 socket_activation_test.py [--fake path/to/fake_gateway.py]
"""
import argparse
import http.client
import os
import socket
import ssl
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
HARNESS = os.path.join(HERE, "..", "harness")
sys.path.insert(0, HARNESS)
from gateway_check import HOST, P, Client  # noqa: E402

CA = os.path.join(HARNESS, "ca.pem")
CONTENT = os.path.join(HERE, "demo_content.json")
TOKEN = "fk1.T3stT0kenForTheReviewGatewayOnly_x"   # this test's own; never deployed
UNTIL = (datetime.now(timezone.utc) + timedelta(days=1)).date().isoformat()

# fd 3 := the socket, then exec with LISTEN_PID = this shell's pid (exec keeps it).
SYSTEMD_ISH = 'exec 3<&"$LK_FD" && export LISTEN_PID="${LK_PID:-$$}" LISTEN_FDS=1 && exec "$@"'


class Fail(Exception):
    pass


def check(cond, what):
    if not cond:
        raise Fail(what)


def listener():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    s.listen(16)
    return s


def free_port():
    s = listener()
    p = s.getsockname()[1]
    s.close()
    return p


def refused(port):
    try:
        socket.create_connection(("127.0.0.1", port), 1).close()
        return False
    except OSError:
        return True


def fake_args(fake, port, *extra):
    return [sys.executable, fake, "--port", str(port), "--host", HOST,
            "--cert", os.path.join(HARNESS, "server.pem"), "--key", os.path.join(HARNESS, "server.key"),
            "--demo-token", TOKEN, "--demo-until", UNTIL, "--content", CONTENT] + list(extra)


def spawn(args, sock=None, listen_pid=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith("LISTEN_")}
    spawn.n += 1
    log = open(os.path.join(os.environ.get("TMPDIR", "/tmp"), "socket_activation_test.%d.%d.log"
                            % (os.getpid(), spawn.n)), "w+")
    if sock is None:
        p = subprocess.Popen(args, cwd=HARNESS, env=env, stdout=log, stderr=subprocess.STDOUT)
    else:
        env["LK_FD"] = str(sock.fileno())
        if listen_pid is not None:
            env["LK_PID"] = str(listen_pid)
        p = subprocess.Popen(["/bin/sh", "-c", SYSTEMD_ISH, "sh"] + args, cwd=HARNESS, env=env,
                             pass_fds=(sock.fileno(),), stdout=log, stderr=subprocess.STDOUT)
    p.log = log
    return p


spawn.n = 0


def output(p):
    p.log.seek(0)
    return p.log.read()


def wait_serving(p, port):
    for _ in range(150):
        if p.poll() is not None:
            raise Fail("the fake exited: %s" % output(p))
        try:
            if Client(port, CA).req("GET", "/api/auth/me")[0] == 403:
                return
        except OSError:
            pass
        time.sleep(0.1)
    raise Fail("the fake did not serve on %d" % port)


def listening(pid):
    """The TCP addresses process `pid` listens on, as lsof names them."""
    r = subprocess.run(["lsof", "-nP", "-a", "-p", str(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"],
                       capture_output=True, text=True)
    return {line[1:] for line in r.stdout.splitlines() if line.startswith("n")}


def first_probe(raw):
    """GET /api/auth/me on a TCP connection made before the server existed."""
    ctx = ssl.create_default_context(cafile=CA)
    raw.settimeout(15)
    c = http.client.HTTPSConnection("127.0.0.1", 0, context=ctx, timeout=15)
    c.sock = ctx.wrap_socket(raw, server_hostname=HOST)
    c.request("GET", "/api/auth/me", headers={"Host": HOST})
    r = c.getresponse()
    r.read()
    c.close()
    return r.status, r.getheader("X-Auth-Required")


def run(fake):
    n = [0]
    procs = []

    def step(what):
        n[0] += 1
        print("==> %d %s" % (n[0], what), flush=True)

    try:
        step("activated: the first connection, made before the fake starts, is answered")
        sock = listener()
        port = sock.getsockname()[1]
        early = socket.create_connection(("127.0.0.1", port), 5)   # queued; nobody accepts yet
        cport = free_port()
        p = spawn(fake_args(fake, port, "--control-port", str(cport), "--no-control"), sock)
        procs.append(p)
        try:
            status, auth = first_probe(early)
        except OSError as e:
            raise Fail("the first probe got no answer (%s): %s" % (e, output(p)[-400:]))
        check(status == 403 and auth, "the first probe: %s, X-Auth-Required %r" % (status, auth))
        check("(from systemd)" in output(p), "the banner does not say the socket came from systemd: %s" % output(p))

        step("activated: the demo token redeems, and the session lives on in the one process")
        c = Client(port, CA)
        c.req("GET", "/?token=" + TOKEN)
        check(("mc_token_%s" % P) in c.jar, "the demo token was not redeemed on the inherited socket")
        for i in range(5):
            s, _, _, _ = Client(port, CA).req("GET", "/api/auth/me")
            check(s == 403, "a fresh client %d: %d" % (i, s))
        s, _, _, _ = c.req("GET", "/api/auth/me")
        check(s == 200, "the session after other connections: %d" % s)
        check(p.poll() is None, "the fake exited while idle: %s" % output(p))

        step("activated: the inherited socket is its only listener; no control port")
        names = listening(p.pid)
        check(names == {"127.0.0.1:%d" % port}, "the fake listens on %s, expected only 127.0.0.1:%d"
              % (sorted(names), port))
        check(refused(cport), "the control port %d answers under --no-control" % cport)
        p.kill()
        p.wait()
        sock.close()

        step("LISTEN_PID of another process: the fds are left alone and --port is bound as before")
        sock = listener()
        own = free_port()
        p = spawn(fake_args(fake, own, "--no-control"), sock, listen_pid=1)
        procs.append(p)
        wait_serving(p, own)
        stray = socket.create_connection(("127.0.0.1", sock.getsockname()[1]), 5)
        stray.settimeout(2)
        stray.sendall(b"\x16\x03\x01\x00\x05hello")
        try:
            got = stray.recv(1)
        except socket.timeout:
            got = None
        check(got is None, "the fake took a socket whose LISTEN_PID was not its own")
        stray.close()
        p.kill()
        p.wait()
        sock.close()

        step("an inherited fd that is not a listening socket is refused")
        plain = socket.socket()
        p = spawn(fake_args(fake, free_port(), "--no-control"), plain)
        procs.append(p)
        try:
            rc = p.wait(20)
        except subprocess.TimeoutExpired:
            rc = None
        check(rc not in (None, 0) and "not a listening" in output(p),
              "a non-listening fd: exit %r, %s" % (rc, output(p)[-300:]))
        plain.close()

        step("started directly with --no-control: it serves, and no control port")
        port, cport = free_port(), free_port()
        p = spawn(fake_args(fake, port, "--control-port", str(cport), "--no-control"))
        procs.append(p)
        wait_serving(p, port)
        check(refused(cport), "the control port %d answers under --no-control" % cport)
        check("control off" in output(p), "the banner does not say the control port is off")
        return n[0]
    finally:
        for p in procs:
            if p.poll() is None:
                p.kill()
                p.wait()
            p.log.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--fake", default=os.path.join(HARNESS, "fake_gateway.py"))
    a = ap.parse_args()
    try:
        k = run(os.path.abspath(a.fake))
    except Fail as e:
        print("FAIL: %s" % e)
        sys.exit(1)
    print("socket activation test: ok (%d checks)" % k)


if __name__ == "__main__":
    main()
