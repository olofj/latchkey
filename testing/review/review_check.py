#!/usr/bin/env python3
"""The review gateway check (F19 §5.2 step 4, §7): run it before every
submission, from any node on the review tailnet.

It asks what Latchkey asks, the way Latchkey asks it:

  1  TLS: the certificate is trusted by the SYSTEM store for <host> (ATS,
     R28). A private CA passes in the simulator and fails on a real phone.
  2  GET /manifest.json, redirects not followed -> 200, JSON named
     "Kiro Crew" (GatewayCandidates.manifestIsKiroCrew)
  3  GET /api/auth/me, no cookies -> 403 + X-Auth-Required: true (R26).
     2 and 3 together are discovery's recognition pair.
  4  GET /?token=<demo token>, twice, each in a fresh cookie jar -> the
     shell and an mc_token_* cookie both times: the token is reusable
  5  GET /api/auth/me with that cookie -> 200 (the session works)
  6  GET /api/ws with the page's Origin -> 101 (the proxy carries WebSocket)
  7  GET /?token=<a made-up token> -> no cookie (the gateway is not
     accepting anything at all)

The demo token comes from the environment or a file, never an argument, so
it stays out of shell history:
    REVIEW_DEMO_TOKEN=fk1....           or
    REVIEW_DEMO_TOKEN_FILE=/etc/latchkey-review/env  (a DEMO_TOKEN=... line
                                                      or the bare token)

    python3 review_check.py demo.<tailnet>.ts.net
    python3 review_check.py --connect 127.0.0.1:8444 --ca ../harness/ca.pem \\
        gw.tail-scale.ts.net                       (a local fake, for tests)

Exit 0 only if every check passed. Nothing secret is printed.
"""
import argparse
import base64
import http.client
import json
import os
import re
import secrets
import socket
import ssl
import sys
import time


class Fail(Exception):
    pass


def check(cond, what):
    if not cond:
        raise Fail(what)


def demo_token():
    tok = os.environ.get("REVIEW_DEMO_TOKEN")
    path = os.environ.get("REVIEW_DEMO_TOKEN_FILE")
    if not tok and path:
        with open(path, encoding="utf-8") as f:
            text = f.read()
        m = re.search(r"^\s*(?:FAKE_GATEWAY_)?DEMO_TOKEN=(\S+)", text, re.M)
        tok = m.group(1) if m else text.strip()
    if not tok:
        raise SystemExit("error: set REVIEW_DEMO_TOKEN or REVIEW_DEMO_TOKEN_FILE")
    return tok.strip().strip("'\"")


class Client:
    def __init__(self, host, connect, ctx):
        self.host, self.ctx = host, ctx
        self.addr = (connect.rsplit(":", 1)[0], int(connect.rsplit(":", 1)[1])) if connect else (host, 443)
        self.jar = {}

    def conn(self):
        raw = socket.create_connection(self.addr, timeout=10)
        return self.ctx.wrap_socket(raw, server_hostname=self.host)

    def req(self, path, headers=None):
        c = http.client.HTTPSConnection(self.host, 443, context=self.ctx, timeout=10)
        c.sock = self.conn()
        h = {"Host": self.host}
        if self.jar:
            h["Cookie"] = "; ".join("%s=%s" % kv for kv in self.jar.items())
        h.update(headers or {})
        c.request("GET", path, headers=h)
        r = c.getresponse()
        body = r.read()
        for s in r.headers.get_all("Set-Cookie") or []:
            name, rest = s.split("=", 1)
            if "Max-Age=0" not in s:
                self.jar[name] = rest.split(";", 1)[0]
        c.close()
        return r.status, r.headers, body


def run(host, connect, ca):
    ctx = ssl.create_default_context(cafile=ca) if ca else ssl.create_default_context()
    n = [0]

    def step(what):
        n[0] += 1
        print("==> %d %s" % (n[0], what), flush=True)

    step("TLS: the certificate for %s is trusted%s" % (host, " (by %s)" % ca if ca else " by the system store"))
    try:
        s = Client(host, connect, ctx).conn()
        s.close()
    except (ssl.SSLError, ssl.CertificateError) as e:
        raise Fail("TLS: %s" % e)
    except OSError as e:
        raise Fail("cannot reach %s: %s (is the host up, and this node on the review tailnet?)"
                   % (connect or host + ":443", e))

    step('GET /manifest.json -> 200, named "Kiro Crew"')
    st, _, body = Client(host, connect, ctx).req("/manifest.json")
    try:
        name = json.loads(body).get("name")
    except ValueError:
        name = None
    check(st == 200 and name == "Kiro Crew", "manifest: %d, name %r" % (st, name))

    step("GET /api/auth/me, no cookies -> 403 + X-Auth-Required: true")
    st, h, _ = Client(host, connect, ctx).req("/api/auth/me")
    check(st == 403 and h.get("X-Auth-Required") == "true",
          "auth probe: %d, X-Auth-Required %r" % (st, h.get("X-Auth-Required")))

    tok = demo_token()
    step("the demo token redeems, twice, each in a fresh cookie jar")
    last = None
    for i in (1, 2):
        c = Client(host, connect, ctx)
        st, _, _ = c.req("/?token=" + tok)
        got = [k for k in c.jar if k.startswith("mc_token_")]
        check(st == 200 and got, "redemption %d: %d, cookies %s (expired, or not this gateway's token?)"
              % (i, st, sorted(c.jar)))
        last = c

    step("GET /api/auth/me with the demo session -> 200")
    st, _, body = last.req("/api/auth/me")
    check(st == 200, "auth/me with the session: %d" % st)
    me = json.loads(body)
    print("    user %r, session ends in %.1f h" % (me.get("user_id"), (me.get("session_exp", 0) - time.time()) / 3600))

    step("GET /api/ws with the page's Origin -> 101 Switching Protocols")
    s = last.conn()
    key = base64.b64encode(secrets.token_bytes(16)).decode()
    s.sendall(("GET /api/ws HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nOrigin: https://%s\r\nCookie: %s\r\n\r\n"
               % (host, key, host, "; ".join("%s=%s" % kv for kv in last.jar.items()))).encode())
    line = s.recv(4096).split(b"\r\n", 1)[0]
    s.close()
    check(line.startswith(b"HTTP/1.1 101"), "websocket: %r" % line)

    step("a made-up token is refused (no session cookie)")
    c = Client(host, connect, ctx)
    c.req("/?token=fk1." + secrets.token_urlsafe(24))
    check(not [k for k in c.jar if k.startswith("mc_token_")], "a made-up token was accepted: %s" % sorted(c.jar))
    return n[0]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("host", help="the gateway's MagicDNS name, <GATEWAY_HOST>")
    ap.add_argument("--connect", help="HOST:PORT to connect to instead of <host>:443 (local tests)")
    ap.add_argument("--ca", help="trust this CA instead of the system store (local tests only)")
    a = ap.parse_args()
    try:
        k = run(a.host.rstrip(".").lower(), a.connect, a.ca)
    except Fail as e:
        print("FAIL: %s" % e)
        print("review check: FAILED")
        sys.exit(1)
    print("review check: ok (%d checks)" % k)


if __name__ == "__main__":
    main()
