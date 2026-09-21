#!/usr/bin/env python3
"""Contract test: the fake gateway against a REAL KiroCrew gateway (R19, O7).

Owner-run. The agent that wrote this cannot run it against a real gateway: it
is policy-blocked from minting KiroCrew credentials (D10). Olof mints a
short-lived sign-in link for THIS test, and the script replays one auth
sequence against the real gateway and against the local fake, then diffs
what came back -- statuses, headers, error codes, cookie names and
attributes. A difference means the fake has drifted from real KiroCrew, and
every M4 test result is suspect until it is fixed.

The sequence (identical on both sides):
   1  GET  /api/auth/me, no cookies            -> 403 + X-Auth-Required
   2  GET  /?token=<link>                      -> the shell, both cookies set
   3  GET  /api/auth/me                        -> 200 {user_id, session_exp, refresh_exp}
   4  (wait for the access session to expire; the fake is told to expire it)
   5  GET  /api/auth/me                        -> 403 + X-Auth-Required
   6  POST /api/auth/refresh                   -> 200, both cookies rotated
   7  POST /api/auth/refresh                   -> 200, rotated again
   8  POST /api/auth/refresh, the token from 6's REQUEST (superseded, not the
      chain head)                              -> 401 refresh_chain_revoked + clear
   9  POST /api/auth/refresh, a foreign Origin -> 403 CSRF, text/plain
Five refresh calls in all: far below the refresh endpoint's shared 60/min.

Rules it keeps (R19):
  * The link comes from a FILE or an ENVIRONMENT VARIABLE, never an argument,
    so it never lands in shell history:
        KR_CONTRACT_LINK_FILE=/path/to/file   (the file holds the URL or token)
        KR_CONTRACT_LINK=<url-or-token>
    Nothing secret is printed: tokens and cookie values are redacted.
  * Its OWN fresh session: redeeming the link starts a new chain, and step 8
    revokes exactly that chain on purpose. Never feed it the phone's link.
  * A gateway on the SAME KiroCrew version as byskebox, and the version the
    fake pins (checked over /api/ws; a mismatch stops the run).
  * Mint the link with a short session, so step 4 does not wait for hours:
        kirocrew token --ttl 2m        (then run this within 5 minutes)

Usage (Olof):
  cd testing/harness && make gateway-up        # the fake, for the comparison
  KR_CONTRACT_LINK_FILE=~/kr-link.txt python3 contract_test.py \\
      --gateway https://byskebox.<tailnet>.ts.net
  make gateway-down
  # chonk's local gateway also works if its version matches:  --gateway http://127.0.0.1:5476

  python3 contract_test.py --fake-only         # the fake's side alone (what the agent can run)
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
from urllib.parse import urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fake_gateway import PINNED_VERSION  # noqa: E402


def redact(v):
    return "<%d chars>" % len(v) if v else "<empty>"


def link_from_environment():
    path = os.environ.get("KR_CONTRACT_LINK_FILE")
    if path:
        with open(os.path.expanduser(path)) as f:
            raw = f.read()
    else:
        raw = os.environ.get("KR_CONTRACT_LINK", "")
    raw = raw.strip()
    if not raw:
        sys.exit("error: set KR_CONTRACT_LINK_FILE (preferred) or KR_CONTRACT_LINK -- never pass the link as an argument")
    if "token=" in raw:
        raw = raw.split("token=", 1)[1].split("&", 1)[0].split()[0]
    return raw


class Side:
    """One gateway: HTTP(S) with a cookie jar and a normalized transcript."""

    def __init__(self, name, base, ca=None, connect_to=None):
        self.name, self.base = name, base.rstrip("/")
        u = urlsplit(self.base)
        self.scheme, self.host = u.scheme, u.hostname
        self.port = u.port or (443 if u.scheme == "https" else 80)
        self.hostheader = u.netloc
        self.connect_to = connect_to            # (ip, port) for the fake
        self.ctx = ssl.create_default_context(cafile=ca) if ca else ssl.create_default_context()
        self.jar = {}
        self.transcript = []

    def origin(self):
        return "%s://%s" % (self.scheme, self.hostheader)

    def request(self, method, path, headers=None, cookies=None):
        ip, port = self.connect_to or (self.host, self.port)
        raw = socket.create_connection((ip, port), timeout=20)
        if self.scheme == "https":
            raw = self.ctx.wrap_socket(raw, server_hostname=self.host)
        c = http.client.HTTPConnection(self.host, port, timeout=20)
        c.sock = raw
        h = {"Host": self.hostheader}
        jar = self.jar if cookies is None else cookies
        if jar:
            h["Cookie"] = "; ".join("%s=%s" % kv for kv in jar.items())
        h.update(headers or {})
        c.request(method, path, headers=h)
        r = c.getresponse()
        body = r.read()
        sets = r.headers.get_all("Set-Cookie") or []
        for s in sets:
            name, rest = s.split("=", 1)
            if "Max-Age=0" in s:
                self.jar.pop(name, None)
            else:
                self.jar[name] = rest.split(";", 1)[0]
        c.close()
        return r.status, r.headers, body, sets

    def record(self, step, status, headers, body, sets):
        ctype = (headers.get("Content-Type") or "").split(";")[0]
        entry = {"step": step, "status": status, "content_type": ctype,
                 "x_auth_required": headers.get("X-Auth-Required"),
                 "cookies": sorted(normalize_cookie(s) for s in sets)}
        if ctype == "application/json":
            try:
                j = json.loads(body)
                entry["json_keys"] = sorted(j.keys()) if isinstance(j, dict) else type(j).__name__
                if isinstance(j, dict) and "error" in j:
                    entry["error"] = j["error"] if j["error"] in KNOWN_ERRORS else "<prose>"
            except ValueError:
                entry["json_keys"] = "<unparseable>"
        self.transcript.append(entry)
        return entry


KNOWN_ERRORS = {"no_refresh_cookie", "invalid_refresh", "refresh_chain_revoked", "rate_limited",
                "Token required", "token expired", "bad_origin"}


def normalize_cookie(s):
    """Name (with the port generalized) and attributes; never the value.
    Max-Age is bucketed: 0, <=20h, <=30d."""
    parts = [p.strip() for p in s.split(";")]
    name = parts[0].split("=", 1)[0]
    for prefix in ("mc_token_", "mc_refresh_"):
        if name.startswith(prefix):
            name = prefix + "<port>"
    attrs = []
    for a in parts[1:]:
        k = a.split("=", 1)[0].lower()
        if k == "max-age":
            n = int(a.split("=", 1)[1])
            attrs.append("max-age=" + ("0" if n == 0 else "<=20h" if n <= 72000 else "<=30d" if n <= 2600000 else ">30d"))
        elif k in ("httponly", "secure"):
            attrs.append(k)
        elif k in ("path", "samesite", "domain"):
            attrs.append(a.lower())
        # expires and anything else: ignored (the serializer's choice)
    return name + " [" + ", ".join(sorted(attrs)) + "]"


def ws_version(side):
    """The gateway's KiroCrew version, from the first `dashboard` message."""
    ip, port = side.connect_to or (side.host, side.port)
    s = socket.create_connection((ip, port), timeout=20)
    if side.scheme == "https":
        s = side.ctx.wrap_socket(s, server_hostname=side.host)
    key = base64.b64encode(os.urandom(16)).decode()
    lines = ["GET /api/ws HTTP/1.1", "Host: " + side.hostheader, "Upgrade: websocket",
             "Connection: Upgrade", "Sec-WebSocket-Key: " + key, "Sec-WebSocket-Version: 13",
             "Origin: " + side.origin(),
             "Cookie: " + "; ".join("%s=%s" % kv for kv in side.jar.items())]
    s.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        buf += s.recv(4096)
    if b" 101 " not in buf.split(b"\r\n", 1)[0]:
        return None
    buf = buf.split(b"\r\n\r\n", 1)[1]
    deadline = time.time() + 15
    while time.time() < deadline:
        while len(buf) < 2:
            buf += s.recv(65536)
        ln, off = buf[1] & 0x7F, 2
        if ln == 126:
            while len(buf) < 4:
                buf += s.recv(65536)
            ln, off = int.from_bytes(buf[2:4], "big"), 4
        elif ln == 127:
            while len(buf) < 10:
                buf += s.recv(65536)
            ln, off = int.from_bytes(buf[2:10], "big"), 10
        while len(buf) < off + ln:
            buf += s.recv(65536)
        frame, buf = buf[off:off + ln], buf[off + ln:]
        try:
            msg = json.loads(frame)
        except ValueError:
            continue
        if msg.get("type") == "dashboard":
            s.close()
            return (msg.get("data") or {}).get("version")
    s.close()
    return None


def run_sequence(side, link, expire):
    """The nine steps. `expire` makes the access session stale (wait or tell)."""
    print("--- %s (%s)" % (side.name, side.base))
    say = lambda e: print("  %-2s %s %s" % (e["step"], e["status"], {k: v for k, v in e.items() if k not in ("step", "status")}))
    say(side.record("1", *side.request("GET", "/api/auth/me", cookies={})))
    say(side.record("2", *side.request("GET", "/?token=" + link)))
    status, headers, body, sets = side.request("GET", "/api/auth/me")
    say(side.record("3", status, headers, body, sets))
    if status != 200:
        sys.exit("error: %s did not accept the link (step 3: %d). Expired? Minted for another gateway?" % (side.name, status))
    version = ws_version(side)
    print("     version over /api/ws: %s (the fake pins %s)" % (version, PINNED_VERSION))
    if version != PINNED_VERSION:
        sys.exit("error: %s runs KiroCrew %s, the fake emulates %s -- compare like with like" % (side.name, version, PINNED_VERSION))
    expire(json.loads(body)["session_exp"])
    say(side.record("5", *side.request("GET", "/api/auth/me")))
    refresh_name = next((k for k in side.jar if k.startswith("mc_refresh_")), None)
    first_refresh = side.jar.get(refresh_name) if refresh_name else None
    origin = {"Origin": side.origin()}
    say(side.record("6", *side.request("POST", "/api/auth/refresh", origin)))
    say(side.record("7", *side.request("POST", "/api/auth/refresh", origin)))
    stale = dict(side.jar)
    if refresh_name and first_refresh:
        stale[refresh_name] = first_refresh
    say(side.record("8", *side.request("POST", "/api/auth/refresh", origin, cookies=stale)))
    say(side.record("9", *side.request("POST", "/api/auth/refresh", {"Origin": "https://contract-test.invalid"})))
    print("     (cookie values never printed; the refresh token presented in step 8 was %s)" % redact(first_refresh))
    return side.transcript


def main():
    ap = argparse.ArgumentParser(description="R19/O7 contract test", formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__)
    ap.add_argument("--gateway", help="the REAL gateway's origin, e.g. https://byskebox.<tailnet>.ts.net")
    ap.add_argument("--fake-port", type=int, default=8444)
    ap.add_argument("--fake-control-port", type=int, default=8481)
    ap.add_argument("--fake-only", action="store_true", help="run only the fake's side (no real gateway, no link)")
    a = ap.parse_args()

    fake = Side("fake", "https://gw.tail-scale.ts.net", ca=os.path.join(HERE, "ca.pem"),
                connect_to=("127.0.0.1", a.fake_port))
    ctl = "http://127.0.0.1:%d" % a.fake_control_port

    def post(path):
        req = urllib.request.Request(ctl + path, method="POST")
        with urllib.request.urlopen(req, timeout=5) as r:
            return json.loads(r.read())
    try:
        post("/__reset")
    except OSError:
        sys.exit("error: the fake gateway is not running (cd testing/harness && make gateway-up)")
    fake_link = post("/__mint?kind=cli")["link"]
    fake_t = run_sequence(fake, fake_link, lambda _exp: post("/__expire"))
    post("/__reset")
    if a.fake_only:
        print("fake side only: ok")
        return

    if not a.gateway:
        sys.exit("error: --gateway is required (or --fake-only)")
    link = link_from_environment()

    def wait_for_expiry(session_exp):
        wait = session_exp - time.time() + 2
        if wait > 330:
            sys.exit("error: the link's session lasts %d s; mint one with `kirocrew token --ttl 2m` so the test does not wait for hours" % wait)
        print("     waiting %d s for the access session to expire..." % max(0, wait))
        time.sleep(max(0, wait))
    real_t = run_sequence(Side("real", a.gateway), link, wait_for_expiry)

    print("--- diff (real vs fake)")
    diffs = 0
    for r, f in zip(real_t, fake_t):
        # Secure follows the scheme: an http:// gateway (chonk's loopback)
        # cannot set it, the fake is always https.
        if not a.gateway.startswith("https://"):
            f = dict(f, cookies=[c.replace("secure, ", "").replace(", secure", "") for c in f["cookies"]])
        for k in sorted(set(r) | set(f)):
            if r.get(k) != f.get(k):
                diffs += 1
                print("  step %s %s: real=%r fake=%r" % (r["step"], k, r.get(k), f.get(k)))
    if diffs:
        print("CONTRACT DRIFT: %d difference(s). Fix fake_gateway.py before trusting the M4 tests." % diffs)
        sys.exit(1)
    print("contract: the fake matches the real gateway on all %d steps" % len(real_t))


if __name__ == "__main__":
    main()
