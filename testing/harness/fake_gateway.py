#!/usr/bin/env python3
"""A fake KiroCrew gateway that serves the REAL 0.6.0 frontend (PLAN M4.1, R19).

Testing the app's session handling against a page we wrote would be circular:
the refresh scheduler, the 403 interceptor, the `mc-auth-*` events and the
`#mc-session-expired` banner exist only in KiroCrew's real bundles. So this
serves the installed `kiro_crew/static/dist` byte for byte -- pinned by version
and hash, and refusing to start on a mismatch -- and emulates the server side
of the auth contract, as read from the installed 0.6.0 source. Nothing of
KiroCrew's is run or imported (D10): the credentials here are opaque test
strings this fake invents, meaningless to a real gateway.

What is emulated (server source references are to kiro_crew/dashboard/):

  * Middleware order: Host allowlist -> CSRF (mutating methods) -> auth.
    Host and CSRF failures are text/plain 403s WITHOUT X-Auth-Required
    (server.py:627-705).
  * Redemption: `?token=<link>` on ANY request is a credential. A valid link
    mints an access session and a NEW refresh chain and sets them as cookies
    on whatever the route returns; `/` returns index.html, 200, no redirect
    (token_auth.py:2603-3061). A link is re-redeemable until its 300 s window
    ends; a restart forgets unredeemed links.
  * Cookies `mc_token_<P>` (HttpOnly; Max-Age; Path=/; SameSite=Lax; Secure)
    and `mc_refresh_<P>` (Path=/api/auth, ~30 d). <P> is the Host header's
    port, or the LISTEN port when the Host has none -- behind `tailscale
    serve` that is 5476 (token_auth.py:1353-1369). --cookie-port sets the
    listen port being emulated.
  * Denials: 403 + `X-Auth-Required: true`, JSON {"error","code"} on /api/*;
    GET/HEAD of a non-API path gets the SPA shell instead (token_auth.py:3097).
  * `GET /api/auth/me` -> {"user_id","session_exp","refresh_exp"}.
  * `POST /api/auth/refresh`: 60/min sliding rate limit per remote (429 +
    Retry-After: 60), checked first; 401 no_refresh_cookie; 401
    invalid_refresh (no cookie clear; also a boot mismatch); 401
    refresh_chain_revoked + refresh-cookie clear; a superseded token is
    forgiven only if it is the chain head, from the same remote, within 60 s
    (the cached body and the SAME tokens are re-served); any other reuse
    revokes the chain (auth_refresh.py:398-678, refresh_tokens.py:345-392).
  * `boot`: QR-shaped links (and everything minted from them) are
    boot-bound; `POST /__restart` changes the boot id. CLI-shaped links are
    not, so their sessions survive a restart (R24).
  * /api/ws: auth before the upgrade, Origin check, then `slots` and a
    `dashboard` message every 5 s with a constant version (ws.py:513-753).
  * The startup endpoints the SPA needs (theme/boot, ui-prefs,
    kiro-prerequisite); every other authenticated /api path is a 404 JSON.
    Unknown paths are recorded, so a gap in this fake shows up in /__state.

R25's hazard is tracked, not just emulated: every reuse of a superseded
refresh token outside the grace window is recorded as a LINEAGE VIOLATION.
Tests assert there are none.

Control (plain HTTP on 127.0.0.1:<control-port>):
  POST /__mint?kind=cli|qr     -> {"link", "url"}: a fresh sign-in link
  POST /__expire               expire every access session now (the 403 path)
  POST /__revoke               revoke every refresh chain (the terminal path)
  POST /__restart              new boot id; forget links, pins, grace caches
  POST /__reset                forget everything (a fresh gateway)
  POST /__config?expire_in=N   access TTL for sessions minted/rotated from now
  GET  /__state                counters, violations, recent requests, unknown paths

  python3 fake_gateway.py --port 8444 --control-port 8481 --cert server.pem \
      --key server.key --host gw.tail-scale.ts.net [--expire-in SECONDS]
  python3 fake_gateway.py --check-bundle      (the R19 smoke test)
"""
import argparse
import base64
import hashlib
import json
import mimetypes
import os
import secrets
import socket
import ssl
import struct
import sys
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

# ---------------------------------------------------------------- the pin --
# The bundle this fake emulates. A different installed version or bundle is a
# hard failure, not a warning: the fake's semantics were read from THIS
# version, and a drifted bundle would make every test answer the wrong
# question. After a KiroCrew upgrade: re-read the auth code, update the fake,
# re-pin (sha256 of each file below), and have Olof re-run O7.
DEFAULT_DIST = os.path.expanduser(
    "~/.kiro/crew-venv/lib/python3.12/site-packages/kiro_crew/static/dist")
PINNED_VERSION = "0.6.0"
PINNED_FILES = {
    # From the installed bundle (--print-pins). index.html names every other
    # asset by content hash, so pinning it pins the entry graph; the three
    # bundles are the ones carrying the auth code.
    "index.html": "def6d3f52bf2c26a7fe42e6982b551670a86a05921a030c4d228d3fe1be83d95",
    "assets/main-BhsK4HoM.js": "c18250a3aa212370725fe5697951d0f8abe893718afbb2d420ba4d68e89c8b36",
    "assets/client-oM83i081.js": "ff2ba1fbb605a5b8212bcd7b43e02b1fd41c4a9b432352f6d37f194265a8db3d",
    "assets/App-GOBYv73C.js": "7bd964479ec2b520645db9a30bad7d99b2d22a01eda36ed447b841b70fe43fa2",
}
# What the app depends on (R19's smoke test): the events it listens for, the
# banner it hides, and the terminal refresh error it must survive.
REQUIRED_STRINGS = {
    "assets/client-oM83i081.js": ["mc-auth-required", "mc-auth-cleared", "mc-session-expired",
                                  "X-Auth-Required", "/api/auth/refresh"],
    "assets/main-BhsK4HoM.js": ["refresh_chain_revoked", "/api/auth/me"],
}

GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
LINK_WINDOW = 300            # seconds a sign-in link can be redeemed
ACCESS_TTL = 72000           # 20 h: every rotation re-mints this
REFRESH_TTL = 2592000        # 30 d, sliding
QR_SESSION_TTL = 3600        # the QR default
GRACE_SECS = 60
RATE_LIMIT = 60              # refreshes per sliding 60 s, per remote
LINK_SET_MAX = 50

EXEMPT_PREFIXES = ("/assets/", "/static/", "/fonts/", "/vendor/", "/artifact-app/", "/sandbox-doc/")
EXEMPT_EXACT = {"/logo.png", "/favicon.ico", "/manifest.json", "/sw.js", "/pcm-worklet.js",
                "/api/token/local", "/api/shutdown", "/api/logout", "/api/theme/boot",
                "/api/health", "/api/live", "/api/ready"}
EXEMPT_POST = {"/api/auth/refresh", "/api/auth/logout"}


def dist_version(dist):
    """The installed kirocrew version, from the dist-info next to the package."""
    site = os.path.dirname(os.path.dirname(os.path.dirname(dist)))
    for name in os.listdir(site):
        if name.startswith("kirocrew-") and name.endswith(".dist-info"):
            with open(os.path.join(site, name, "METADATA")) as f:
                for line in f:
                    if line.startswith("Version:"):
                        return line.split(":", 1)[1].strip()
    return None


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def check_bundle(dist):
    """The R19 pin and smoke test. Returns a list of problems (empty = ok)."""
    problems = []
    v = dist_version(dist)
    if v != PINNED_VERSION:
        problems.append("installed KiroCrew is %s, the fake was written against %s" % (v, PINNED_VERSION))
    for rel, want in PINNED_FILES.items():
        p = os.path.join(dist, rel)
        if not os.path.exists(p):
            problems.append("%s is missing from the bundle" % rel)
        elif not want:
            problems.append("%s has no pinned hash (run --print-pins)" % rel)
        elif sha256(p) != want:
            problems.append("%s changed (sha256 %s, pinned %s)" % (rel, sha256(p)[:12], want[:12]))
    for rel, needles in REQUIRED_STRINGS.items():
        p = os.path.join(dist, rel)
        if not os.path.exists(p):
            continue
        with open(p, "rb") as f:
            body = f.read()
        for n in needles:
            if n.encode() not in body:
                problems.append("%s no longer contains %r" % (rel, n))
    return problems


# ------------------------------------------------------------------ state --
class Gateway:
    """All server-side auth state. One lock; every method takes it."""

    def __init__(self, expire_in, cookie_port):
        self.lock = threading.Lock()
        self.default_expire_in = expire_in
        self.cookie_port = cookie_port
        self.reset()

    def reset(self):
        # A fresh gateway: including the expiry, so one test's /__config
        # cannot leak into the next.
        self.expire_in = self.default_expire_in
        self.boot = secrets.token_hex(16)
        self.links = {}          # link -> {"exp", "kind"}  (in memory, bounded)
        self.sessions = {}       # access -> {"exp", "boot", "chain"}
        self.refresh = {}        # refresh -> {"exp", "boot", "chain"}
        self.chains = {}         # id -> {"revoked", "consumed", "head", "last": {...}}
        self.rate = {}           # remote -> deque of times
        self.counters = {"redemptions": 0, "rotations": 0, "grace_reserves": 0,
                         "refresh_401": 0, "refresh_429": 0, "denials": 0, "ws_opens": 0,
                         "auth_me_ok": 0}
        self.violations = []     # R25: superseded refresh token used outside grace
        self.requests = deque(maxlen=300)
        self.unknown = {}        # path -> count: routes this fake does not implement

    # -- minting (control API only) --
    def mint_link(self, kind):
        link = "fk1." + secrets.token_urlsafe(24)
        with self.lock:
            self.links[link] = {"exp": time.time() + LINK_WINDOW, "kind": kind}
            while len(self.links) > LINK_SET_MAX:
                self.links.pop(next(iter(self.links)))
        return link

    def _access_ttl(self, kind):
        if self.expire_in:
            return self.expire_in
        return QR_SESSION_TTL if kind == "qr" else ACCESS_TTL

    def _new_session(self, kind, boot, chain, ttl):
        access = "fa." + secrets.token_urlsafe(24)
        self.sessions[access] = {"exp": time.time() + ttl, "boot": boot, "chain": chain}
        return access

    def _new_refresh(self, boot, chain):
        rt = "fr." + secrets.token_urlsafe(24)
        self.refresh[rt] = {"exp": time.time() + REFRESH_TTL, "boot": boot, "chain": chain}
        return rt

    def redeem(self, link):
        """-> (access, refresh, session_exp) or (None, reason)."""
        with self.lock:
            rec = self.links.get(link)
            if rec is None:
                return None, "no active sessions" if link.startswith("fk1.") else "malformed token"
            if rec["exp"] < time.time():
                return None, "token expired"
            boot = self.boot if rec["kind"] == "qr" else None
            chain = secrets.token_hex(8)
            self.chains[chain] = {"revoked": False, "consumed": set(), "head": None, "last": None}
            ttl = self._access_ttl(rec["kind"])
            access = self._new_session(rec["kind"], boot, chain, ttl)
            rt = self._new_refresh(boot, chain)
            self.counters["redemptions"] += 1
            return (access, rt, self.sessions[access]["exp"]), None

    def check_access(self, access):
        """-> (session, None) or (None, reason)."""
        with self.lock:
            s = self.sessions.get(access) if access else None
            if s is None:
                return None, "Token required" if not access else "invalid signature"
            if s["boot"] and s["boot"] != self.boot:
                return None, "session ended at gateway restart"
            if s["exp"] < time.time():
                return None, "token expired"
            return s, None

    def refresh_exp(self, rt):
        with self.lock:
            r = self.refresh.get(rt or "")
            return r["exp"] if r else 0.0

    def rotate(self, rt, remote):
        """The refresh endpoint's core. -> (status, body, cookies-to-set, clear_refresh)."""
        now = time.time()
        with self.lock:
            q = self.rate.setdefault(remote, deque())
            while q and q[0] < now - 60:
                q.popleft()
            if len(q) >= RATE_LIMIT:
                self.counters["refresh_429"] += 1
                return 429, {"error": "rate_limited"}, None, False
            q.append(now)
            if not rt:
                self.counters["refresh_401"] += 1
                return 401, {"error": "no_refresh_cookie"}, None, False
            rec = self.refresh.get(rt)
            if rec is None or rec["exp"] < now or (rec["boot"] and rec["boot"] != self.boot):
                self.counters["refresh_401"] += 1
                return 401, {"error": "invalid_refresh"}, None, False
            chain = self.chains[rec["chain"]]
            if chain["revoked"]:
                self.counters["refresh_401"] += 1
                return 401, {"error": "refresh_chain_revoked"}, None, True
            if rt in chain["consumed"]:
                last = chain["last"]
                if (rt == chain["head"] and last and last["remote"] == remote
                        and now - last["at"] <= GRACE_SECS):
                    self.counters["grace_reserves"] += 1
                    return 200, last["body"], last["tokens"], False
                chain["revoked"] = True
                self.violations.append({"at": now, "chain": rec["chain"],
                                        "why": "superseded refresh token reused outside the grace window"})
                self.counters["refresh_401"] += 1
                return 401, {"error": "refresh_chain_revoked"}, None, True
            # Success: consume, rotate, remember for the grace window.
            chain["consumed"].add(rt)
            chain["head"] = rt
            ttl = self.expire_in or ACCESS_TTL
            access = self._new_session("rotation", rec["boot"], rec["chain"], ttl)
            rt2 = self._new_refresh(rec["boot"], rec["chain"])
            body = {"refreshed_at": now, "session_exp": now + ttl, "refresh_exp": now + REFRESH_TTL}
            tokens = (access, rt2, ttl)
            chain["last"] = {"remote": remote, "at": now, "body": body, "tokens": tokens}
            self.counters["rotations"] += 1
            return 200, body, tokens, False

    def logout(self, access):
        with self.lock:
            self.sessions.pop(access or "", None)

    def expire_all(self):
        with self.lock:
            for s in self.sessions.values():
                s["exp"] = 0

    def revoke_all(self):
        with self.lock:
            for c in self.chains.values():
                c["revoked"] = True

    def restart(self):
        """A gateway restart: new boot id; the in-memory link set, IP pins and
        grace caches are lost. Persisted state (sessions' signing secret,
        chains) survives, so unbound sessions keep working."""
        with self.lock:
            self.boot = secrets.token_hex(16)
            self.links.clear()
            for c in self.chains.values():
                c["last"] = None

    def snapshot(self):
        with self.lock:
            return {"boot": self.boot, "counters": dict(self.counters),
                    "violations": list(self.violations), "requests": list(self.requests),
                    "unknown": dict(self.unknown), "expire_in": self.expire_in,
                    "cookie_port": self.cookie_port}

    def record(self, line):
        with self.lock:
            self.requests.append(line)

    def record_unknown(self, path):
        with self.lock:
            self.unknown[path] = self.unknown.get(path, 0) + 1


# --------------------------------------------------------------- handlers --
class Page(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    gw = None                 # Gateway
    dist = DEFAULT_DIST
    allowed_hosts = set()
    allowed_origins = set()

    def log_message(self, fmt, *a):
        pass

    # -- helpers --
    def host_header(self):
        return (self.headers.get("Host") or "").strip().lower()

    def cookie_port(self):
        h = self.host_header()
        if h.startswith("["):
            rest = h.split("]", 1)[1]
            port = rest[1:] if rest.startswith(":") else ""
        else:
            port = h.rsplit(":", 1)[1] if ":" in h else ""
        return port if port.isdigit() else str(self.gw.cookie_port)

    def cookies(self):
        out = {}
        for part in (self.headers.get("Cookie") or "").split(";"):
            if "=" in part:
                k, v = part.strip().split("=", 1)
                out[k] = v
        return out

    def secure(self):
        return "; Secure"      # always HTTPS here

    def auth_cookie_headers(self, access, rt, access_ttl, clear_refresh=False):
        p = self.cookie_port()
        hs = []
        if access:
            hs.append("mc_token_%s=%s; HttpOnly; Max-Age=%d; Path=/; SameSite=Lax%s"
                      % (p, access, min(int(access_ttl), 72000), self.secure()))
            hs.append('mc_token=""; Max-Age=0; Path=/')
        if rt:
            hs.append("mc_refresh_%s=%s; HttpOnly; Max-Age=%d; Path=/api/auth; SameSite=Lax%s"
                      % (p, rt, REFRESH_TTL, self.secure()))
        if clear_refresh:
            hs.append('mc_refresh_%s=""; Max-Age=0; Path=/api/auth' % p)
        return hs

    def send(self, status, body, ctype, extra=(), cookies=(), cache=None):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache or "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "strict-origin-when-cross-origin")
        self.send_header("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
        for k, v in extra:
            self.send_header(k, v)
        for c in cookies:
            self.send_header("Set-Cookie", c)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def json(self, status, obj, extra=(), cookies=()):
        self.send(status, json.dumps(obj), "application/json; charset=utf-8", extra, cookies)

    def deny(self, path, reason):
        with self.gw.lock:
            self.gw.counters["denials"] += 1
        if path.startswith("/api/"):
            return self.json(403, {"error": reason, "code": "forbidden"},
                             extra=[("X-Auth-Required", "true")])
        # A non-API GET/HEAD gets the SPA shell, which then asks /api/auth/me.
        return self.serve_file("/index.html")

    def serve_file(self, path, cookies=()):
        rel = "index.html" if path in ("/", "/index.html") else path.lstrip("/")
        full = os.path.normpath(os.path.join(self.dist, rel))
        if not full.startswith(os.path.normpath(self.dist) + os.sep) or not os.path.isfile(full):
            # Client-side routes get the shell, as the real SPA fallback does.
            if "." not in os.path.basename(path) and not path.startswith("/api/"):
                full = os.path.join(self.dist, "index.html")
            else:
                return self.send(404, "not found", "text/plain")
        ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
        if full.endswith((".js", ".mjs")):
            ctype = "text/javascript; charset=utf-8"
        cache = "public, max-age=31536000, immutable" if path.startswith("/assets/") else None
        with open(full, "rb") as f:
            data = f.read()
        return self.send(200, data, ctype, cookies=cookies, cache=cache)

    def exempt(self, path):
        return (path.startswith(EXEMPT_PREFIXES) or path in EXEMPT_EXACT
                or (self.command == "POST" and path in EXEMPT_POST)
                or (path.startswith("/icon-") and path.endswith(".png")))

    # -- the middleware chain --
    def handle_any(self):
        u = urlsplit(self.path)
        path, query = u.path, parse_qs(u.query)
        self.gw.record("%s %s%s" % (self.command, path, "?…" if u.query else ""))

        # 1. Host allowlist (health endpoints exempt).
        if self.host_header() not in self.allowed_hosts and path not in ("/api/health", "/api/live", "/api/ready"):
            return self.send(403, "Host header not allowed.", "text/plain; charset=utf-8")
        # 2. CSRF for mutating methods: Origin, else Referer, else loopback peer only.
        if self.command in ("POST", "PUT", "DELETE", "PATCH"):
            origin = self.headers.get("Origin")
            if origin is None and self.headers.get("Referer"):
                ref = urlsplit(self.headers["Referer"])
                origin = "%s://%s" % (ref.scheme, ref.netloc)
            loopback = self.client_address[0] in ("127.0.0.1", "::1")
            if (origin is None and not loopback) or (origin is not None and origin not in self.allowed_origins):
                return self.send(403, "CSRF check failed: request origin not allowed.", "text/plain; charset=utf-8")
        # 3. Auth.
        cookies = self.cookies()
        port = self.cookie_port()
        access = cookies.get("mc_token_%s" % port)
        new_cookies = []
        session, reason = self.gw.check_access(access)
        link = (query.get("token") or [None])[0]
        if link and session is None:
            minted, why = self.gw.redeem(link)
            if minted:
                a, rt, exp = minted
                access, session = a, self.gw.check_access(a)[0]
                new_cookies = self.auth_cookie_headers(a, rt, exp - time.time())
            else:
                reason = why
        if session is None and not self.exempt(path):
            return self.deny(path, reason)
        return self.route(path, session, access, cookies, port, new_cookies)

    def route(self, path, session, access, cookies, port, new_cookies):
        m = self.command
        if path == "/api/auth/me" and m == "GET":
            with self.gw.lock:
                self.gw.counters["auth_me_ok"] += 1
            return self.json(200, {"user_id": "olof", "session_exp": session["exp"],
                                   "refresh_exp": self.gw.refresh_exp(cookies.get("mc_refresh_%s" % port))},
                             cookies=new_cookies)
        if path == "/api/auth/refresh" and m == "POST":
            status, body, tokens, clear = self.gw.rotate(cookies.get("mc_refresh_%s" % port),
                                                         self.client_address[0])
            extra = [("Retry-After", "60")] if status == 429 else []
            cks = self.auth_cookie_headers(tokens[0], tokens[1], tokens[2]) if tokens else []
            if clear:
                cks += self.auth_cookie_headers(None, None, 0, clear_refresh=True)
            return self.json(status, body, extra=extra, cookies=cks)
        if path == "/api/auth/logout" and m == "POST":
            self.gw.logout(access)
            return self.json(200, {"ok": True}, cookies=[
                'mc_token_%s=""; Max-Age=0; Path=/' % port,
                'mc_refresh_%s=""; Max-Age=0; Path=/api/auth' % port])
        if path == "/api/theme/boot":
            return self.json(200, {"mode": "", "color": "", "language": "", "onboarded": True,
                                   "import_onboarded": True, "privacy_acked": True})
        if path == "/api/ui-prefs":
            return self.json(200, {"prefs": {}} if m == "GET" else {"ok": True}, cookies=new_cookies)
        if path == "/api/kiro-prerequisite":
            return self.json(200, {"ready": True}, cookies=new_cookies)
        if path in ("/api/health", "/api/live", "/api/ready"):
            return self.json(200, {"ok": True})
        if path == "/api/ws":
            return self.websocket()
        if path.startswith("/api/"):
            self.gw.record_unknown("%s %s" % (m, path))
            return self.json(404, {"error": "not found"}, cookies=new_cookies)
        if m in ("GET", "HEAD"):
            return self.serve_file(path, cookies=new_cookies)
        self.gw.record_unknown("%s %s" % (m, path))
        return self.send(404, "not found", "text/plain")

    do_GET = do_HEAD = do_POST = do_PUT = do_DELETE = do_PATCH = handle_any

    # -- /api/ws --
    def websocket(self):
        origin = self.headers.get("Origin")
        loopback = self.client_address[0] in ("127.0.0.1", "::1")
        if (origin is None and not loopback) or (origin is not None and origin not in self.allowed_origins):
            return self.send(403, "WebSocket origin not allowed", "text/plain")
        k = self.headers.get("Sec-WebSocket-Key")
        if not k:
            return self.send(400, "missing key", "text/plain")
        acc = base64.b64encode(hashlib.sha1(k.encode() + GUID).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", acc)
        self.end_headers()
        self.close_connection = True
        with self.gw.lock:
            self.gw.counters["ws_opens"] += 1
        stop = threading.Event()
        wlock = threading.Lock()

        def push():
            try:
                with wlock:
                    self.ws_write(0x1, json.dumps({"type": "slots", "data": []}).encode())
                while not stop.wait(5):
                    with wlock:
                        self.ws_write(0x1, json.dumps({"type": "dashboard",
                                                       "data": {"version": PINNED_VERSION}}).encode())
            except Exception:
                stop.set()
        threading.Thread(target=push, daemon=True).start()
        try:
            while not stop.is_set():
                op, payload = self.ws_read()
                if op == 0x8:
                    with wlock:
                        self.ws_write(0x8, b"")
                    break
                if op == 0x9:
                    with wlock:
                        self.ws_write(0xA, payload)
        except Exception:
            pass
        stop.set()

    def ws_read(self):
        b1, b2 = self.rfile.read(2)
        op, masked, ln = b1 & 0x0F, b2 & 0x80, b2 & 0x7F
        if ln == 126:
            ln = struct.unpack("!H", self.rfile.read(2))[0]
        elif ln == 127:
            ln = struct.unpack("!Q", self.rfile.read(8))[0]
        mask = self.rfile.read(4) if masked else b"\0\0\0\0"
        data = bytearray(self.rfile.read(ln))
        for i in range(ln):
            data[i] ^= mask[i % 4]
        return op, bytes(data)

    def ws_write(self, op, payload):
        h = bytes([0x80 | op])
        n = len(payload)
        if n < 126:
            h += bytes([n])
        elif n < 1 << 16:
            h += bytes([126]) + struct.pack("!H", n)
        else:
            h += bytes([127]) + struct.pack("!Q", n)
        self.wfile.write(h + payload)
        self.wfile.flush()


class Control(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    gw = None
    public_origin = ""

    def log_message(self, fmt, *a):
        pass

    def reply(self, obj, status=200):
        b = json.dumps(obj, indent=1).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path != "/__state":
            return self.reply({"error": "not found"}, 404)
        return self.reply(self.gw.snapshot())

    def do_POST(self):
        u = urlsplit(self.path)
        q = parse_qs(u.query)
        if u.path == "/__mint":
            kind = (q.get("kind") or ["cli"])[0]
            if kind not in ("cli", "qr"):
                return self.reply({"error": "kind is cli or qr"}, 400)
            link = self.gw.mint_link(kind)
            return self.reply({"link": link, "url": "%s/?token=%s" % (self.public_origin, link)})
        if u.path == "/__config":
            # The access-session TTL for sessions minted or rotated from now on.
            with self.gw.lock:
                self.gw.expire_in = int((q.get("expire_in") or ["0"])[0])
            return self.reply({"ok": True, "expire_in": self.gw.expire_in})
        actions = {"/__expire": self.gw.expire_all, "/__revoke": self.gw.revoke_all,
                   "/__restart": self.gw.restart, "/__reset": self.gw.reset}
        if u.path in actions:
            actions[u.path]()
            return self.reply({"ok": True})
        return self.reply({"error": "not found"}, 404)


class V6Server(ThreadingHTTPServer):
    address_family = socket.AF_INET6


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--port", type=int, default=8444)
    ap.add_argument("--control-port", type=int, default=8481)
    ap.add_argument("--cert")
    ap.add_argument("--key")
    ap.add_argument("--host", default="gw.tail-scale.ts.net", help="the gateway's public host name")
    ap.add_argument("--cookie-port", type=int, default=5476,
                    help="the listen port being emulated (names the cookies when Host has no port)")
    ap.add_argument("--expire-in", type=int, default=0, help="access-session TTL in seconds (0 = real defaults)")
    ap.add_argument("--dist", default=DEFAULT_DIST)
    ap.add_argument("--check-bundle", action="store_true", help="run the pin/smoke test and exit")
    ap.add_argument("--print-pins", action="store_true", help="print the installed bundle's hashes and exit")
    a = ap.parse_args()

    if a.print_pins:
        print("version:", dist_version(a.dist))
        for rel in PINNED_FILES:
            print('    "%s": "%s",' % (rel, sha256(os.path.join(a.dist, rel))))
        return
    problems = check_bundle(a.dist)
    if a.check_bundle:
        for p in problems:
            print("FAIL:", p)
        print("bundle check: %s" % ("ok (KiroCrew %s)" % PINNED_VERSION if not problems else "FAILED"))
        sys.exit(1 if problems else 0)
    if problems:
        print("fake_gateway: refusing to start -- the installed bundle is not the pinned one:", file=sys.stderr)
        for p in problems:
            print("  " + p, file=sys.stderr)
        sys.exit(2)
    if not (a.cert and a.key):
        ap.error("--cert and --key are required")

    gw = Gateway(a.expire_in, a.cookie_port)
    Page.gw = Control.gw = gw
    Page.dist = a.dist
    Page.allowed_hosts = {a.host, "127.0.0.1:%d" % a.port, "localhost:%d" % a.port, "[::1]:%d" % a.port}
    Page.allowed_origins = {"https://%s" % a.host, "https://127.0.0.1:%d" % a.port,
                            "https://localhost:%d" % a.port}
    Control.public_origin = "https://%s" % a.host

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(a.cert, a.key)
    servers = []
    v4 = ThreadingHTTPServer(("127.0.0.1", a.port), Page)
    v4.socket = ctx.wrap_socket(v4.socket, server_side=True)
    servers.append(v4)
    try:
        v6 = V6Server(("::1", a.port), Page)
        v6.socket = ctx.wrap_socket(v6.socket, server_side=True)
        servers.append(v6)
    except OSError:
        pass
    servers.append(ThreadingHTTPServer(("127.0.0.1", a.control_port), Control))
    for s in servers:
        threading.Thread(target=s.serve_forever, daemon=True).start()
    print("fake gateway (KiroCrew %s bundle) https://%s -> 127.0.0.1:%d, control :%d, cookies mc_*_%d, expire-in %s"
          % (PINNED_VERSION, a.host, a.port, a.control_port, a.cookie_port, a.expire_in or "default"), flush=True)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
