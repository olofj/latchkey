#!/usr/bin/env python3
"""Host test of F19's review-gateway additions to fake_gateway.py (§7).

Starts its own fakes on free ports (the harness CA and leaf, host
gw.tail-scale.ts.net) and checks, each step able to fail:

  * off by default: a fake started without --demo-token refuses the token
  * the demo token redeems again and again, and survives /__restart,
    /__reset and /__logout-all; /__state never shows it
  * ordinary links are unchanged: a mint is still bound by its window
  * review_check.py passes against the demo fake (so the owner's check is
    itself exercised)
  * --content: the canned sessions, folders, user, transcripts and the
    canned reply
  * after --demo-until: the token, its access sessions and its refresh
    chains are all refused

    python3 demo_token_test.py [--fake path/to/fake_gateway.py]
"""
import argparse
import json
import os
import socket
import subprocess
import sys
import time
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
HARNESS = os.path.join(HERE, "..", "harness")
sys.path.insert(0, HARNESS)
from gateway_check import HOST, P, Client, control  # noqa: E402

CA = os.path.join(HARNESS, "ca.pem")
CONTENT = os.path.join(HERE, "demo_content.json")
TOKEN = "fk1.T3stT0kenForTheReviewGatewayOnly_x"   # this test's own; never deployed


class Fail(Exception):
    pass


def check(cond, what):
    if not cond:
        raise Fail(what)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def start(fake, *extra):
    port, cport = free_port(), free_port()
    log = open(os.path.join(os.environ.get("TMPDIR", "/tmp"), "demo_token_test.%d.log" % port), "w+")
    p = subprocess.Popen([sys.executable, fake, "--port", str(port), "--control-port", str(cport),
                          "--host", HOST, "--cert", os.path.join(HARNESS, "server.pem"),
                          "--key", os.path.join(HARNESS, "server.key")] + list(extra),
                         cwd=HARNESS, stdout=log, stderr=subprocess.STDOUT)
    for _ in range(100):
        if p.poll() is not None:
            log.seek(0)
            raise Fail("the fake exited: %s" % log.read())
        try:
            control(cport, "GET", "/__state")
            return p, port, cport
        except OSError:
            time.sleep(0.1)
    p.kill()
    raise Fail("the fake did not come up")


def signed_in(port, token):
    """A fresh jar redeems `token`; -> (client, redeemed?)."""
    c = Client(port, CA)
    c.req("GET", "/?token=" + token)
    return c, ("mc_token_%s" % P) in c.jar


def run(fake):
    n = [0]
    procs = []

    def step(what):
        n[0] += 1
        print("==> %d %s" % (n[0], what), flush=True)

    try:
        step("off by default: without --demo-token the token is refused")
        p, port, cport = start(fake)
        procs.append(p)
        _, ok = signed_in(port, TOKEN)
        check(not ok, "a fake without --demo-token accepted the demo token")
        check(control(cport, "GET", "/__state")["demo_until"] is None, "demo_until without a demo token")

        until = time.time() + 12
        p, port, cport = start(fake, "--demo-token", TOKEN, "--demo-until",
                               datetime.fromtimestamp(until, timezone.utc).isoformat(), "--content", CONTENT)
        procs.append(p)

        step("the demo token redeems three times, each a session of its own")
        jars = []
        for i in range(3):
            c, ok = signed_in(port, TOKEN)
            check(ok, "redemption %d refused" % (i + 1))
            s, _, _, _ = c.req("GET", "/api/auth/me")
            check(s == 200, "auth/me after redemption %d: %d" % (i + 1, s))
            jars.append(c)
        st = control(cport, "GET", "/__state")
        check(st["counters"]["demo_redemptions"] == 3, "demo_redemptions %r" % st["counters"])
        check(isinstance(st["demo_until"], float) and abs(st["demo_until"] - until) < 1,
              "demo_until %r" % (st["demo_until"],))

        step("its sessions end at the date, not 20 h on")
        s, _, body, _ = jars[0].req("GET", "/api/auth/me")
        check(json.loads(body)["session_exp"] <= until + 0.001, "session_exp %s > until" % body)

        step("it survives /__restart, /__reset and /__logout-all; /__state never shows it")
        for path in ("/__restart", "/__reset", "/__logout-all"):
            control(cport, "POST", path)
            _, ok = signed_in(port, TOKEN)
            check(ok, "refused after %s" % path)
        check(TOKEN not in json.dumps(control(cport, "GET", "/__state")), "/__state carries the token")

        step("ordinary links are unchanged: a 2 s mint is refused after 3 s, a restart forgets one")
        link = control(cport, "POST", "/__mint?kind=qr&ttl=2")["link"]
        time.sleep(3)
        _, ok = signed_in(port, link)
        check(not ok, "an ordinary link outlived its window")
        link = control(cport, "POST", "/__mint?kind=cli")["link"]
        control(cport, "POST", "/__restart")
        _, ok = signed_in(port, link)
        check(not ok, "an ordinary link survived a restart")

        step("review_check.py passes against this fake")
        env = dict(os.environ, REVIEW_DEMO_TOKEN=TOKEN)
        r = subprocess.run([sys.executable, os.path.join(HERE, "review_check.py"), "--connect",
                            "127.0.0.1:%d" % port, "--ca", CA, HOST], env=env, capture_output=True, text=True)
        check(r.returncode == 0 and "review check: ok" in r.stdout, "review_check: %s%s" % (r.stdout, r.stderr))
        check(TOKEN not in r.stdout + r.stderr, "review_check printed the token")

        step("--content: user, sessions, folders and transcripts")
        c, _ = signed_in(port, TOKEN)
        s, _, body, _ = c.req("GET", "/api/auth/me")
        check(json.loads(body)["user_id"] == "demo", "user %s" % body)
        s, _, body, _ = c.req("GET", "/api/chat/slots")
        slots = json.loads(body)
        check([x["key"] for x in slots] == ["garden-plan", "trip-notes", "essay-draft", "recipe-scaler"]
              and slots[0]["title"] == "Spring garden plan" and not any(x["running"] for x in slots)
              and slots[0]["last_message"], "slots %s" % body[:300])
        s, _, body, _ = c.req("GET", "/api/chat/folders")
        check([f["name"] for f in json.loads(body)] == ["Home", "Writing", "Code"], "folders %s" % body)
        s, _, body, _ = c.req("GET", "/api/chat/slots/garden-plan?limit=200")
        d = json.loads(body)
        check(s == 200 and len(d["messages"]) == 4 and d["messages"][0]["role"] == "user"
              and d["messages"][1]["cls"] == "msg msg-a" and d["has_more"] is False, "transcript %s" % body[:300])
        s, _, _, _ = c.req("GET", "/api/chat/slots/no-such-session")
        check(s == 404, "an unknown session's transcript: %d" % s)

        step("a message to a canned session is appended, with the canned reply")
        s, _, body, _ = c.req("POST", "/api/chat", {"Origin": "https://" + HOST, "Content-Type": "application/json"},
                              body=json.dumps({"slot": "essay-draft", "message": "hello"}))
        check(s == 200, "post: %d %s" % (s, body))
        s, _, body, _ = c.req("GET", "/api/chat/slots/essay-draft")
        m = json.loads(body)["messages"]
        check(len(m) == 4 and m[2]["content"] == "hello" and "demo dashboard" in m[3]["content"],
              "after a post: %s" % body[-400:])

        step("after the date: the token, its sessions and its refresh chains are refused")
        time.sleep(max(0, until - time.time()) + 1)
        before = control(cport, "GET", "/__state")["counters"]["demo_redemptions"]
        _, ok = signed_in(port, TOKEN)
        # Both: a late redemption into an already-dead session would look
        # like a refusal from the cookie alone (Max-Age=0).
        check(not ok and control(cport, "GET", "/__state")["counters"]["demo_redemptions"] == before,
              "the token redeemed after its date")
        s, h, _, _ = c.req("GET", "/api/auth/me")
        check(s == 403 and h.get("X-Auth-Required") == "true", "a demo session after the date: %d" % s)
        s, _, body, _ = c.req("POST", "/api/auth/refresh", {"Origin": "https://" + HOST})
        check(s == 401, "a demo chain refreshed after the date: %d %s" % (s, body))
    finally:
        for p in procs:
            p.terminate()
            p.wait()
    return n[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fake", default=os.path.join(HARNESS, "fake_gateway.py"))
    a = ap.parse_args()
    try:
        k = run(os.path.abspath(a.fake))
    except Fail as e:
        print("FAIL: %s" % e)
        print("demo token test: FAILED")
        sys.exit(1)
    print("demo token test: ok (%d checks)" % k)


if __name__ == "__main__":
    main()
