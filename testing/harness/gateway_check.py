#!/usr/bin/env python3
"""Host-side contract self-test for fake_gateway.py (M4, R19).

Runs against a live fake gateway (`make gateway-check` starts and stops one)
and asserts the server-side behaviour the app's tests will lean on, one
numbered check at a time. Each check can fail; a failure names what the
fake got wrong. This is also the shape `contract_test.py` (R19, owner-run,
O7) replays against a REAL gateway, so the two can be diffed.

Requests go to 127.0.0.1:<port> with SNI and Host `gw.tail-scale.ts.net` --
no port in the Host, as behind `tailscale serve`, so the cookies must be
named for the emulated listen port (5476), not 8444.
"""
import argparse
import base64
import http.client
import json
import os
import socket
import ssl
import sys
import time
import urllib.request

HOST = "gw.tail-scale.ts.net"
ORIGIN = "https://" + HOST
P = "5476"


class Fail(Exception):
    pass


def check(cond, what):
    if not cond:
        raise Fail(what)


class Client:
    def __init__(self, port, ca):
        self.port = port
        self.ctx = ssl.create_default_context(cafile=ca)
        self.jar = {}

    def req(self, method, path, headers=None, host=HOST, cookies=True):
        c = http.client.HTTPSConnection("127.0.0.1", self.port, context=self.ctx, timeout=10)
        # SNI and certificate check against the gateway's public name.
        c.sock = self.ctx.wrap_socket(socket.create_connection(("127.0.0.1", self.port), timeout=10),
                                      server_hostname=HOST)
        h = {"Host": host}
        if cookies and self.jar:
            h["Cookie"] = "; ".join("%s=%s" % kv for kv in self.jar.items())
        h.update(headers or {})
        c.request(method, path, headers=h)
        r = c.getresponse()
        body = r.read()
        sets = r.headers.get_all("Set-Cookie") or []
        for s in sets:
            name, rest = s.split("=", 1)
            value = rest.split(";", 1)[0]
            if "Max-Age=0" in s:
                self.jar.pop(name, None)
            else:
                self.jar[name] = value
        c.close()
        return r.status, dict(r.headers), body, sets


def control(port, method, path):
    req = urllib.request.Request("http://127.0.0.1:%d%s" % (port, path), method=method)
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read() or b"{}")


def run(port, cport, ca):
    n = [0]

    def step(what):
        n[0] += 1
        print("==> %2d %s" % (n[0], what), flush=True)

    control(cport, "POST", "/__reset")
    c = Client(port, ca)

    step("signed out: the shell loads (200), the API denies with 403 + X-Auth-Required")
    s, h, body, _ = c.req("GET", "/")
    check(s == 200 and b"<title>Kiro Crew</title>" in body, "GET / should serve the real index.html; got %d" % s)
    s, h, body, _ = c.req("GET", "/api/auth/me")
    check(s == 403 and h.get("X-Auth-Required") == "true", "stale /api/auth/me: want 403 + header, got %d %s" % (s, h))
    check(json.loads(body).get("code") == "forbidden", "denial body: %r" % body)

    step("a foreign Host is refused before auth (text/plain 403, no X-Auth-Required)")
    s, h, body, _ = c.req("GET", "/api/auth/me", host="evil.example")
    check(s == 403 and "X-Auth-Required" not in h and b"Host header not allowed" in body,
          "foreign Host: %d %s %r" % (s, h, body))

    step("redemption: ?token= sets both cookies, named for the listen port (Host has none)")
    link = control(cport, "POST", "/__mint?kind=cli")["link"]
    s, h, body, sets = c.req("GET", "/?token=" + link)
    check(s == 200 and b"<title>Kiro Crew</title>" in body, "redemption should return the shell, got %d" % s)
    tok = [x for x in sets if x.startswith("mc_token_%s=" % P)]
    ref = [x for x in sets if x.startswith("mc_refresh_%s=" % P)]
    check(tok and ref, "want mc_token_%s and mc_refresh_%s; got %s" % (P, P, sets))
    for attr in ("HttpOnly", "Path=/;", "SameSite=Lax", "Secure", "Max-Age="):
        check(attr in tok[0] + ";", "access cookie lacks %s: %s" % (attr, tok[0]))
    check("Path=/api/auth" in ref[0] and "HttpOnly" in ref[0], "refresh cookie attributes: %s" % ref[0])

    step("signed in: /api/auth/me is 200 with session_exp")
    s, h, body, _ = c.req("GET", "/api/auth/me")
    me = json.loads(body)
    check(s == 200 and me.get("session_exp", 0) > time.time(), "auth/me: %d %r" % (s, body))

    step("the link is re-redeemable inside its window (a second, independent chain)")
    c2 = Client(port, ca)
    s, _, _, sets2 = c2.req("GET", "/?token=" + link)
    check(any(x.startswith("mc_token_%s=" % P) for x in sets2), "second redemption set no cookie")

    step("refresh: a bad Origin is the CSRF 403 (text/plain), not a JSON error")
    s, h, body, _ = c.req("POST", "/api/auth/refresh", {"Origin": "https://evil.example"})
    check(s == 403 and b"CSRF check failed" in body, "bad Origin: %d %r" % (s, body))

    step("refresh rotates both cookies")
    first = c.jar["mc_refresh_%s" % P]
    s, h, body, sets = c.req("POST", "/api/auth/refresh", {"Origin": ORIGIN})
    check(s == 200 and "session_exp" in json.loads(body), "refresh: %d %r" % (s, body))
    second = c.jar["mc_refresh_%s" % P]
    check(second != first, "the refresh token did not rotate")

    step("grace: re-presenting the just-superseded token (chain head, same client, < 60 s) re-serves the SAME tokens")
    c.jar["mc_refresh_%s" % P] = first
    s, h, body, sets = c.req("POST", "/api/auth/refresh", {"Origin": ORIGIN})
    check(s == 200, "grace re-serve: %d %r" % (s, body))
    check(c.jar["mc_refresh_%s" % P] == second, "grace must re-serve the same refresh token")
    check(control(cport, "GET", "/__state")["counters"]["grace_reserves"] == 1, "grace not counted")

    step("rotate again, then reuse the FIRST token (no longer the head): chain revoked, cookie cleared, violation recorded")
    s, _, _, _ = c.req("POST", "/api/auth/refresh", {"Origin": ORIGIN})
    check(s == 200, "second rotation: %d" % s)
    c.jar["mc_refresh_%s" % P] = first
    s, h, body, sets = c.req("POST", "/api/auth/refresh", {"Origin": ORIGIN})
    check(s == 401 and json.loads(body).get("error") == "refresh_chain_revoked", "reuse: %d %r" % (s, body))
    check(any(x.startswith('mc_refresh_%s=""' % P) and "Max-Age=0" in x for x in sets), "revoked: cookie not cleared: %s" % sets)
    v = control(cport, "GET", "/__state")["violations"]
    check(len(v) == 1, "want exactly one lineage violation, got %s" % v)

    step("no refresh cookie: 401 no_refresh_cookie")
    s, _, body, _ = c.req("POST", "/api/auth/refresh", {"Origin": ORIGIN})
    check(s == 401 and json.loads(body).get("error") == "no_refresh_cookie", "no cookie: %d %r" % (s, body))

    step("the access session outlives its revoked chain (the real server does not revoke access)")
    s, _, _, _ = c.req("GET", "/api/auth/me")
    check(s == 200, "access after revocation: %d" % s)

    step("expiry: every access session expired -> 403 + X-Auth-Required on the API, shell on /")
    control(cport, "POST", "/__expire")
    s, h, _, _ = c2.req("GET", "/api/auth/me")
    check(s == 403 and h.get("X-Auth-Required") == "true", "expired: %d" % s)
    s, _, body, _ = c2.req("GET", "/")
    check(s == 200 and b"<title>Kiro Crew</title>" in body, "expired GET / should be the shell")

    step("...and the refresh path recovers it (c2's chain is intact)")
    s, _, _, _ = c2.req("POST", "/api/auth/refresh", {"Origin": ORIGIN})
    check(s == 200, "refresh after expiry: %d" % s)
    s, _, _, _ = c2.req("GET", "/api/auth/me")
    check(s == 200, "auth/me after refresh: %d" % s)

    step("restart (R24): a QR-shaped session ends; a CLI-shaped one survives")
    control(cport, "POST", "/__reset")
    cli, qr = Client(port, ca), Client(port, ca)
    cli.req("GET", "/?token=" + control(cport, "POST", "/__mint?kind=cli")["link"])
    qr.req("GET", "/?token=" + control(cport, "POST", "/__mint?kind=qr")["link"])
    check(cli.req("GET", "/api/auth/me")[0] == 200 and qr.req("GET", "/api/auth/me")[0] == 200, "both signed in")
    stale_link = control(cport, "POST", "/__mint?kind=cli")["link"]
    control(cport, "POST", "/__restart")
    check(cli.req("GET", "/api/auth/me")[0] == 200, "a CLI session must survive a restart")
    s, h, body, _ = qr.req("GET", "/api/auth/me")
    check(s == 403 and b"restart" in body, "a QR session must end at a restart: %d %r" % (s, body))
    s, _, body, _ = qr.req("POST", "/api/auth/refresh", {"Origin": ORIGIN})
    check(s == 401 and json.loads(body).get("error") == "invalid_refresh", "QR refresh after restart: %d %r" % (s, body))
    fresh = Client(port, ca)
    fresh.req("GET", "/?token=" + stale_link)
    check(fresh.req("GET", "/api/auth/me")[0] == 403, "a restart forgets unredeemed links")

    step("revocation: every chain revoked -> refresh_chain_revoked")
    control(cport, "POST", "/__revoke")
    s, _, body, _ = cli.req("POST", "/api/auth/refresh", {"Origin": ORIGIN})
    check(s == 401 and json.loads(body).get("error") == "refresh_chain_revoked", "revoked: %d %r" % (s, body))

    step("WebSocket: auth before the upgrade, Origin checked, then a slots message")
    control(cport, "POST", "/__reset")
    w = Client(port, ca)
    w.req("GET", "/?token=" + control(cport, "POST", "/__mint?kind=cli")["link"])
    check(ws_status(port, ca, None, ORIGIN) == 403, "a WebSocket without a session must be refused")
    check(ws_status(port, ca, w.jar, "https://evil.example") == 403, "a foreign Origin must be refused")
    check(ws_status(port, ca, w.jar, ORIGIN, want_message=True) == 101, "an authenticated WebSocket must open")

    step("rate limit: the 61st refresh within a minute is a 429 with Retry-After: 60")
    control(cport, "POST", "/__reset")
    r = Client(port, ca)
    codes = [r.req("POST", "/api/auth/refresh", {"Origin": ORIGIN}, cookies=False)[0] for _ in range(61)]
    check(codes[:60] == [401] * 60, "the first 60 should reach the handler (401, no cookie): %s" % codes[:60])
    s, h, _, _ = r.req("POST", "/api/auth/refresh", {"Origin": ORIGIN}, cookies=False)
    check(s == 429 and h.get("Retry-After") == "60", "want 429 + Retry-After: 60, got %d %s" % (s, h))

    control(cport, "POST", "/__reset")
    print("gateway check: ok (%d checks)" % n[0])


def ws_status(port, ca, jar, origin, want_message=False):
    ctx = ssl.create_default_context(cafile=ca)
    s = ctx.wrap_socket(socket.create_connection(("127.0.0.1", port), timeout=10), server_hostname=HOST)
    key = base64.b64encode(os.urandom(16)).decode()
    lines = ["GET /api/ws HTTP/1.1", "Host: " + HOST, "Upgrade: websocket", "Connection: Upgrade",
             "Sec-WebSocket-Key: " + key, "Sec-WebSocket-Version: 13", "Origin: " + origin]
    if jar:
        lines.append("Cookie: " + "; ".join("%s=%s" % kv for kv in jar.items()))
    s.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = s.recv(4096)
        if not chunk:
            break
        head += chunk
    status = int(head.split(b" ", 2)[1])
    if status == 101 and want_message:
        rest = head.split(b"\r\n\r\n", 1)[1]
        while len(rest) < 2:
            rest += s.recv(4096)
        ln = rest[1] & 0x7F
        while len(rest) < 2 + ln:
            rest += s.recv(4096)
        msg = json.loads(rest[2:2 + ln])
        if msg.get("type") != "slots":
            raise Fail("first WebSocket message should be slots, got %r" % msg)
    s.close()
    return status


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8444)
    ap.add_argument("--control-port", type=int, default=8481)
    ap.add_argument("--ca", required=True)
    a = ap.parse_args()
    try:
        run(a.port, a.control_port, a.ca)
    except Fail as e:
        print("FAIL:", e)
        sys.exit(1)


if __name__ == "__main__":
    main()
