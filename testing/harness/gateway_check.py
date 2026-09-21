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

from tls_accept import with_silent_client

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

    step("a client that connects and never speaks stalls nobody (tls_accept)")
    t0 = time.time()
    s, _, _, _ = with_silent_client(port, lambda: c.req("GET", "/"))
    check(s == 200 and time.time() - t0 < 5, "a request behind a silent client: %d after %.1f s" % (s, time.time() - t0))

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

    step("refresh rotates both cookies (and only those: the legacy clear is redemption's)")
    first = c.jar["mc_refresh_%s" % P]
    s, h, body, sets = c.req("POST", "/api/auth/refresh", {"Origin": ORIGIN})
    check(s == 200 and "session_exp" in json.loads(body), "refresh: %d %r" % (s, body))
    check(sorted(x.split("=", 1)[0] for x in sets) == ["mc_refresh_%s" % P, "mc_token_%s" % P],
          "rotation sets exactly the two auth cookies: %s" % sets)
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
    st, body = ws_status(port, ca, None, ORIGIN)
    check(st == 403 and b'"forbidden"' in body, "no session: an AUTH denial (JSON), got %d %r" % (st, body[:80]))
    st, body = ws_status(port, ca, w.jar, "https://evil.example")
    check(st == 403 and b"origin not allowed" in body, "foreign Origin: an ORIGIN denial, got %d %r" % (st, body[:80]))
    check(ws_status(port, ca, w.jar, ORIGIN, want_message=True)[0] == 101, "an authenticated WebSocket must open")

    step("a valid ?token= over a valid cookie re-redeems (the query token is validated first)")
    control(cport, "POST", "/__reset")
    q = Client(port, ca)
    q.req("GET", "/?token=" + control(cport, "POST", "/__mint?kind=cli")["link"])
    before = dict(q.jar)
    q.req("GET", "/?token=" + control(cport, "POST", "/__mint?kind=cli")["link"])
    check(control(cport, "GET", "/__state")["counters"]["redemptions"] == 2, "the second link must redeem")
    check(q.jar.get("mc_token_%s" % P) != before.get("mc_token_%s" % P), "and replace the access cookie")

    step("an exempt path never redeems a ?token=")
    e = Client(port, ca)
    s, _, _, sets = e.req("GET", "/manifest.json?token=" + control(cport, "POST", "/__mint?kind=cli")["link"])
    check(s == 200 and not sets, "manifest.json with a link: 200, no cookies (%s)" % sets)
    check(control(cport, "GET", "/__state")["counters"]["redemptions"] == 2, "no redemption on an exempt path")

    step("a link's window runs from mint: min(300 s, ttl)")
    short = control(cport, "POST", "/__mint?kind=cli&ttl=2")["link"]
    time.sleep(2.5)
    late = Client(port, ca)
    late.req("GET", "/?token=" + short)
    check(late.req("GET", "/api/auth/me")[0] == 403, "a link past min(300, ttl) must not redeem")

    step("a signed-out non-API POST is a 403 sign-in page with X-Auth-Required, not the shell")
    s, h, body, _ = late.req("POST", "/some/form", {"Origin": ORIGIN})
    check(s == 403 and h.get("X-Auth-Required") == "true" and b"Sign in" in body, "non-API POST: %d %s" % (s, h))

    step("logout-all (the revocation generation): access 403, refresh invalid_refresh, no cookie clear")
    control(cport, "POST", "/__reset")
    g = Client(port, ca)
    g.req("GET", "/?token=" + control(cport, "POST", "/__mint?kind=cli")["link"])
    control(cport, "POST", "/__logout-all")
    s, h, body, _ = g.req("GET", "/api/auth/me")
    check(s == 403 and json.loads(body).get("error") == "session revoked", "access after logout-all: %d %r" % (s, body))
    s, _, body, sets = g.req("POST", "/api/auth/refresh", {"Origin": ORIGIN})
    check(s == 401 and json.loads(body).get("error") == "invalid_refresh" and not sets,
          "refresh after logout-all: %d %r %s" % (s, body, sets))

    step("refresh order: a revoked QR chain after a restart is refresh_chain_revoked, not invalid_refresh")
    control(cport, "POST", "/__reset")
    rq = Client(port, ca)
    rq.req("GET", "/?token=" + control(cport, "POST", "/__mint?kind=qr")["link"])
    control(cport, "POST", "/__revoke")
    control(cport, "POST", "/__restart")
    s, _, body, _ = rq.req("POST", "/api/auth/refresh", {"Origin": ORIGIN})
    check(s == 401 and json.loads(body).get("error") == "refresh_chain_revoked", "revoked before boot: %d %r" % (s, body))

    step("a lost refresh response is recovered by the grace window (same client, < 60 s)")
    control(cport, "POST", "/__reset")
    d = Client(port, ca)
    d.req("GET", "/?token=" + control(cport, "POST", "/__mint?kind=cli")["link"])
    presented = d.jar["mc_refresh_%s" % P]
    control(cport, "POST", "/__drop-next-refresh")
    try:
        d.req("POST", "/api/auth/refresh", {"Origin": ORIGIN})
        lost = False
    except (OSError, http.client.HTTPException):
        lost = True
    check(lost, "the dropped refresh must fail at the connection level")
    check(d.jar["mc_refresh_%s" % P] == presented, "the client still holds the consumed token")
    s, _, _, _ = d.req("POST", "/api/auth/refresh", {"Origin": ORIGIN})
    st = control(cport, "GET", "/__state")
    check(s == 200 and st["counters"]["grace_reserves"] == 1 and not st["violations"],
          "retry inside grace: %d, grace %d, violations %s" % (s, st["counters"]["grace_reserves"], st["violations"]))

    step("...but after a restart the grace cache is gone: the retry revokes the chain")
    control(cport, "POST", "/__reset")
    d2 = Client(port, ca)
    d2.req("GET", "/?token=" + control(cport, "POST", "/__mint?kind=cli")["link"])
    control(cport, "POST", "/__drop-next-refresh")
    try:
        d2.req("POST", "/api/auth/refresh", {"Origin": ORIGIN})
    except (OSError, http.client.HTTPException):
        pass
    control(cport, "POST", "/__restart")
    s, _, body, _ = d2.req("POST", "/api/auth/refresh", {"Origin": ORIGIN})
    check(s == 401 and json.loads(body).get("error") == "refresh_chain_revoked", "retry after restart: %d %r" % (s, body))

    step("a restart drops open connections, and down=S refuses new ones for S seconds")
    control(cport, "POST", "/__reset")
    w2 = Client(port, ca)
    w2.req("GET", "/?token=" + control(cport, "POST", "/__mint?kind=cli")["link"])
    ws = open_ws(port, ca, w2.jar)
    control(cport, "POST", "/__restart?down=2")
    # Drain: messages sent before the restart may still be buffered. Dropped
    # means EOF or a reset within the deadline; a timeout means still open.
    closed, deadline = False, time.time() + 6
    ws.settimeout(1)
    while time.time() < deadline and not closed:
        try:
            closed = ws.recv(65536) == b""
        except socket.timeout:
            continue
        except OSError:
            closed = True
    check(closed, "the open WebSocket must be dropped by a restart")
    try:
        w2.req("GET", "/api/auth/me")
        refused = False
    except (OSError, http.client.HTTPException):
        refused = True
    check(refused, "a request while down must fail at the connection level")
    time.sleep(2.2)
    check(w2.req("GET", "/api/auth/me")[0] == 200, "after the downtime a CLI session works again")

    step("logout: revokes the chain and answers logged_out")
    control(cport, "POST", "/__reset")
    lo = Client(port, ca)
    lo.req("GET", "/?token=" + control(cport, "POST", "/__mint?kind=cli")["link"])
    kept = dict(lo.jar)
    s, _, body, _ = lo.req("POST", "/api/auth/logout", {"Origin": ORIGIN})
    check(s == 200 and json.loads(body) == {"logged_out": True}, "logout: %d %r" % (s, body))
    lo.jar = kept   # present the cookies logout just cleared, as a saved copy would
    s, _, body, _ = lo.req("POST", "/api/auth/refresh", {"Origin": ORIGIN})
    check(s == 401 and json.loads(body).get("error") == "refresh_chain_revoked", "the chain is revoked: %r" % body)

    step("rate limit: the 61st refresh within a minute is a 429 with Retry-After: 60")
    control(cport, "POST", "/__reset")
    r = Client(port, ca)
    codes = [r.req("POST", "/api/auth/refresh", {"Origin": ORIGIN}, cookies=False)[0] for _ in range(60)]
    check(codes == [401] * 60, "the first 60 should reach the handler (401, no cookie): %s" % codes)
    s, h, _, _ = r.req("POST", "/api/auth/refresh", {"Origin": ORIGIN}, cookies=False)
    check(s == 429 and h.get("Retry-After") == "60", "the 61st: want 429 + Retry-After: 60, got %d %s" % (s, h))

    control(cport, "POST", "/__reset")
    print("gateway check: ok (%d checks)" % n[0])


def open_ws(port, ca, jar):
    ctx = ssl.create_default_context(cafile=ca)
    s = ctx.wrap_socket(socket.create_connection(("127.0.0.1", port), timeout=10), server_hostname=HOST)
    key = base64.b64encode(os.urandom(16)).decode()
    lines = ["GET /api/ws HTTP/1.1", "Host: " + HOST, "Upgrade: websocket", "Connection: Upgrade",
             "Sec-WebSocket-Key: " + key, "Sec-WebSocket-Version: 13", "Origin: " + ORIGIN,
             "Cookie: " + "; ".join("%s=%s" % kv for kv in jar.items())]
    s.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
    head = b""
    while b"\r\n\r\n" not in head:
        head += s.recv(4096)
    if b" 101 " not in head.split(b"\r\n", 1)[0]:
        raise Fail("WebSocket did not open: %r" % head[:80])
    return s


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
    body = head.split(b"\r\n\r\n", 1)[1] if b"\r\n\r\n" in head else b""
    if status != 101:
        s.settimeout(2)
        try:
            while True:
                more = s.recv(4096)
                if not more:
                    break
                body += more
        except OSError:
            pass
        s.close()
        return status, body
    if want_message:
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
    return status, body


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
