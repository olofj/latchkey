#!/usr/bin/env python3
"""A fake KiroCrew gateway that serves the REAL 0.6.0 frontend (PLAN M4.1, R19).

Testing the app's session handling against a page we wrote would be circular:
the refresh scheduler, the 403 interceptor, the `mc-auth-*` events and the
`#mc-session-expired` banner exist only in KiroCrew's real bundles. So this
serves the installed `kiro_crew/static/dist` byte for byte -- pinned, with the
server code the emulation was read from, and refusing to start on a mismatch
-- and emulates the server side of the auth contract as read from the
installed 0.6.0 source. Nothing of KiroCrew's is run or imported (D10): the
credentials here are opaque test strings this fake invents, meaningless to a
real gateway.

What is emulated (server source references are to kiro_crew/dashboard/):

  * Middleware order: Host allowlist (hostname only) -> CSRF (mutating
    methods) -> auth. Host and CSRF failures are text/plain 403s WITHOUT
    X-Auth-Required (server.py:627-705, origin.py:344).
  * Auth-exempt paths return before any credential is looked at, so a
    `?token=` on one is not redeemed (token_auth.py:2559-2601).
  * Credentials: a `?token=` is validated FIRST. A valid link mints an access
    session and a NEW refresh chain and sets both cookies on whatever the
    route returns (`/` -> index.html, 200, no redirect) -- even over a valid
    cookie. An invalid link falls back to the cookie; without a valid cookie
    the link's failure stands (token_auth.py:2603-2681, 2785-3037).
  * Links: redeemable for min(300 s, ttl) from MINT, re-redeemable inside
    that window; the session runs to mint + ttl (token_auth.py:828, 2745). A
    restart forgets unredeemed links.
  * Cookies `mc_token_<P>` (HttpOnly; Max-Age; Path=/; SameSite=Lax; Secure)
    and `mc_refresh_<P>` (Path=/api/auth, 30 d sliding). <P> is the Host
    header's port, or the LISTEN port when the Host has none -- behind
    `tailscale serve` that is 5476 (token_auth.py:1353-1369). Redemption also
    clears the legacy `mc_token`; rotation does not (token_auth.py:2915,
    auth_refresh.py:557-561, 673-676).
  * Denials: 403 + `X-Auth-Required: true`; JSON {"error","code"} on /api/*,
    an HTML sign-in page elsewhere. GET/HEAD outside the data prefixes gets
    the SPA shell instead, so the SPA can boot and refresh
    (token_auth.py:599-687, 3097).
  * `GET /api/auth/me` -> {"user_id","session_exp","refresh_exp"}.
  * `POST /api/auth/refresh`, in the real order: rate limit (60 per sliding
    60 s per remote; 429 + Retry-After: 60) -> 401 no_refresh_cookie ->
    unknown/expired -> 401 invalid_refresh -> revoked chain -> 401
    refresh_chain_revoked + refresh-cookie clear -> revocation generation or
    `boot` mismatch -> 401 invalid_refresh (no clear) -> a superseded token is
    forgiven only as the chain head, from the same remote, within 60 s (the
    same tokens re-served); any other reuse revokes the chain
    (auth_refresh.py:398-678, refresh_tokens.py:345-392, 720-769).
  * `boot`: QR-shaped links (and everything minted from them) are
    boot-bound; CLI links are not, so their sessions survive a restart (R24).
  * Revocation generation (`kirocrew logout`): `/__logout-all` bumps it --
    every access session and refresh token is refused (token_auth.py:1315).
  * `POST /api/auth/logout`: revokes the chain, denylists the access cookie,
    clears both, answers {"logged_out": true} (auth_refresh.py:760-820).
  * /api/ws: auth before the upgrade, Origin check, then `slots` and a
    `dashboard` message every 5 s with a constant version (ws.py:513-753).
  * The startup endpoints the SPA needs (theme/boot, ui-prefs,
    kiro-prerequisite); every other authenticated /api path is a 404 JSON.
    Unknown paths are recorded, so a gap in this fake shows up in /__state.

R25's hazard is tracked, not just emulated: every reuse of a superseded
refresh token outside the grace window is recorded as a LINEAGE VIOLATION.

Control (plain HTTP on 127.0.0.1:<control-port>):
  POST /__mint?kind=cli|qr[&ttl=S]   -> {"link", "url"}: a fresh sign-in link
  POST /__expire               expire every access session now (the 403 path)
  POST /__revoke               revoke every refresh chain, as reuse detection
                               does; access sessions stay valid
  POST /__logout-all           bump the revocation generation, as `kirocrew
                               logout` does: access AND refresh refused
  POST /__restart[?down=S]     a gateway restart: new boot id; forget links
                               and grace caches; drop every open connection;
                               optionally refuse connections for S seconds
  POST /__drop-next-refresh    the next refresh is carried out (the token is
                               consumed) but its response is lost
  POST /__config?expire_in=S   access TTL for sessions minted/rotated from now
  POST /__reset                forget everything (a fresh gateway)
  GET  /__state                counters, violations, recent requests, unknown paths

  python3 fake_gateway.py --port 8444 --control-port 8481 --cert server.pem \\
      --key server.key --host gw.tail-scale.ts.net [--expire-in SECONDS]
  python3 fake_gateway.py --check-bundle      (the R19 pin and smoke test)
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

from tls_accept import HandshakeInThread, wrap_listener
from urllib.parse import parse_qs, urlsplit

# ---------------------------------------------------------------- the pin --
# What this fake emulates. A different installed version, bundle or server
# auth code is a hard failure, not a warning: the fake's semantics were read
# from THESE files, and drift would make every test answer the wrong question.
# After a KiroCrew upgrade: re-read the auth code, update the fake, re-pin
# (--print-pins), and have Olof re-run O7.
DEFAULT_DIST = os.path.expanduser(
    "~/.kiro/crew-venv/lib/python3.12/site-packages/kiro_crew/static/dist")
PINNED_VERSION = "0.6.0"
PINNED_FILES = {
    # The frontend. index.html names every other asset by content hash, so
    # pinning it pins the entry graph; the three bundles carry the auth code.
    "static/dist/index.html": "def6d3f52bf2c26a7fe42e6982b551670a86a05921a030c4d228d3fe1be83d95",
    "static/dist/assets/main-BhsK4HoM.js": "c18250a3aa212370725fe5697951d0f8abe893718afbb2d420ba4d68e89c8b36",
    "static/dist/assets/client-oM83i081.js": "ff2ba1fbb605a5b8212bcd7b43e02b1fd41c4a9b432352f6d37f194265a8db3d",
    "static/dist/assets/App-GOBYv73C.js": "7bd964479ec2b520645db9a30bad7d99b2d22a01eda36ed447b841b70fe43fa2",
    # The server code the emulation was read from (M4 review: a same-version
    # rebuild could change these while the frontend stays byte-identical).
    "dashboard/token_auth.py": "6ccc836c2a25ce20efd8e4bde85c1afe47acba7ddeed7082c147ab966c56127a",
    "dashboard/refresh_tokens.py": "70049328c17e81a03452379748e8d84e72eafaca02bcfed69873036eb37a8b33",
    "dashboard/server.py": "b4b7c94e27143d711e9542c934aba2e3999ff73bf984c19c42584d25a7a6e539",
    "dashboard/origin.py": "9ebaa0b46850f1f8d45a854690ac93521a43b370ba8c37ec699101b710c8bac1",
    "dashboard/urls.py": "7ff8341ab3a7fb88c7107c7309f8175dc10f504a195faa31286ce1bdf6ec72c1",
    "dashboard/ws.py": "722228f7e012f36de8455ed520c686a340dbf882116d0fb25becc16fe500f682",
    "dashboard/boot_id.py": "731c0285aa0b8420aef1f4deea60f087ba9eab7498e16e9fc0a4ddb839a29a8d",
    "dashboard/revocation_gen.py": "9b1d49a298540939baa57d3aaf553a279174f80e480fea4ee584fdc9323f5f62",
    "dashboard/tailnet.py": "87d6e7aa460361674ede650d84a5ac133fefd0ef54ae58a52682e00d323eaf3d",
    "dashboard/handlers/auth_refresh.py": "6f3cabae9adb06ffe30fce71366cc88514281c01d9558ae26b5420e1a9e71047",
    "dashboard/handlers/tailnet_mobile.py": "5671fa16af6fe1a46d77824b7ccf7644c34ba36b930f81ee68f58af55dd62b19",
    "dashboard/handlers/core.py": "16f0cefda3db6dda298a4860acbd318b61a5f96fc1e50d08ee43d189f5cc48de",
}
# What the app depends on (R19's smoke test): the events it listens for, the
# banner it hides, and the terminal refresh error it must survive.
REQUIRED_STRINGS = {
    "static/dist/assets/client-oM83i081.js": ["mc-auth-required", "mc-auth-cleared", "mc-session-expired",
                                              "X-Auth-Required", "/api/auth/refresh"],
    "static/dist/assets/main-BhsK4HoM.js": ["refresh_chain_revoked", "/api/auth/me"],
}

GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
LINK_WINDOW = 300            # a sign-in link is redeemable for min(this, ttl)
ACCESS_TTL = 72000           # 20 h: the cap, and what every rotation re-mints
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
# GET/HEAD of anything under these is a data request: no SPA shell for it.
SHELL_EXCLUDED_PREFIXES = ("/api/", "/v1/", "/assets/", "/static/", "/sprites/", "/vendor/",
                           "/fonts/", "/app-assets/", "/artifact-app/", "/sandbox-doc/")


def package_root(dist):
    return os.path.dirname(os.path.dirname(dist))


def dist_version(dist):
    """The installed kirocrew version, from the dist-info next to the package."""
    site = os.path.dirname(package_root(dist))
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
    root = package_root(dist)
    v = dist_version(dist)
    if v != PINNED_VERSION:
        problems.append("installed KiroCrew is %s, the fake was written against %s" % (v, PINNED_VERSION))
    if os.path.exists(os.path.join(root, "BUILD_VERSION")):
        problems.append("a BUILD_VERSION stamp is present: not the pinned release build")
    for rel, want in PINNED_FILES.items():
        p = os.path.join(root, rel)
        if not os.path.exists(p):
            problems.append("%s is missing" % rel)
        elif sha256(p) != want:
            problems.append("%s changed (sha256 %s, pinned %s)" % (rel, sha256(p)[:12], want[:12]))
    for rel, needles in REQUIRED_STRINGS.items():
        p = os.path.join(root, rel)
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
        self.connections = set()     # open client sockets, dropped by a restart
        self.reset()

    def reset(self):
        # A fresh gateway: including the expiry, so one test's /__config
        # cannot leak into the next.
        self.expire_in = self.default_expire_in
        self.boot = secrets.token_hex(16)
        self.gen = 0
        self.down_until = 0.0
        self.drop_next_refresh = False
        self.links = {}          # link -> {"mint", "ttl", "kind", "gen"}  (in memory, bounded)
        self.sessions = {}       # access -> {"exp", "boot", "chain", "gen"}
        self.refresh = {}        # refresh -> {"exp", "boot", "chain", "gen"}
        self.chains = {}         # id -> {"revoked", "consumed", "head", "last": {...}}
        self.rate = {}           # remote -> deque of times
        self.counters = {"redemptions": 0, "rotations": 0, "grace_reserves": 0,
                         "refresh_401": 0, "refresh_429": 0, "refresh_dropped": 0,
                         "denials": 0, "ws_opens": 0, "auth_me_ok": 0,
                         "app_auth_checks": 0, "shell_loads": 0, "restarts": 0}
        self.violations = []     # R25: superseded refresh token used outside grace
        self.requests = deque(maxlen=300)
        self.unknown = {}        # path -> count: routes this fake does not implement

    def count(self, name):
        with self.lock:
            self.counters[name] = self.counters.get(name, 0) + 1

    # -- minting (control API only) --
    def mint_link(self, kind, ttl=None):
        link = "fk1." + secrets.token_urlsafe(24)
        ttl = ttl or (QR_SESSION_TTL if kind == "qr" else ACCESS_TTL)
        with self.lock:
            self.links[link] = {"mint": time.time(), "ttl": min(ttl, ACCESS_TTL), "kind": kind, "gen": self.gen}
            while len(self.links) > LINK_SET_MAX:
                self.links.pop(next(iter(self.links)))
        return link

    def _new_session(self, boot, chain, exp, gen):
        access = "fa." + secrets.token_urlsafe(24)
        self.sessions[access] = {"exp": exp, "boot": boot, "chain": chain, "gen": gen}
        return access

    def _new_refresh(self, boot, chain, gen):
        rt = "fr." + secrets.token_urlsafe(24)
        self.refresh[rt] = {"exp": time.time() + REFRESH_TTL, "boot": boot, "chain": chain, "gen": gen}
        return rt

    def redeem(self, link):
        """-> ((access, refresh, session_exp), None) or (None, reason)."""
        now = time.time()
        with self.lock:
            rec = self.links.get(link)
            if rec is None:
                return None, "no active sessions" if link.startswith("fk1.") else "malformed token"
            if now > rec["mint"] + min(LINK_WINDOW, rec["ttl"]):
                return None, "token expired"
            if rec["gen"] < self.gen:
                return None, "session revoked"
            boot = self.boot if rec["kind"] == "qr" else None
            chain = secrets.token_hex(8)
            self.chains[chain] = {"revoked": False, "consumed": set(), "head": None, "last": None}
            exp = now + self.expire_in if self.expire_in else rec["mint"] + rec["ttl"]
            access = self._new_session(boot, chain, exp, self.gen)
            rt = self._new_refresh(boot, chain, self.gen)
            self.counters["redemptions"] += 1
            return (access, rt, exp), None

    def check_access(self, access):
        """-> (session, None) or (None, reason)."""
        with self.lock:
            s = self.sessions.get(access) if access else None
            if s is None:
                return None, "Token required" if not access else "invalid signature"
            if s["gen"] < self.gen:
                return None, "session revoked"
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
        """The refresh endpoint's core.
        -> (status, body, tokens-to-set or None, clear_refresh, drop_response)."""
        now = time.time()
        with self.lock:
            q = self.rate.setdefault(remote, deque())
            while q and q[0] < now - 60:
                q.popleft()
            if len(q) >= RATE_LIMIT:
                self.counters["refresh_429"] += 1
                return 429, {"error": "rate_limited"}, None, False, False
            q.append(now)
            if not rt:
                self.counters["refresh_401"] += 1
                return 401, {"error": "no_refresh_cookie"}, None, False, False
            rec = self.refresh.get(rt)
            if rec is None or rec["exp"] < now:
                self.counters["refresh_401"] += 1
                return 401, {"error": "invalid_refresh"}, None, False, False
            chain = self.chains[rec["chain"]]
            # The real order (refresh_tokens.py:745-768): revoked chain, then
            # the revocation generation, then boot.
            if chain["revoked"]:
                self.counters["refresh_401"] += 1
                return 401, {"error": "refresh_chain_revoked"}, None, True, False
            if rec["gen"] < self.gen or (rec["boot"] and rec["boot"] != self.boot):
                self.counters["refresh_401"] += 1
                return 401, {"error": "invalid_refresh"}, None, False, False
            if rt in chain["consumed"]:
                last = chain["last"]
                if (rt == chain["head"] and last and last["remote"] == remote
                        and now - last["at"] <= GRACE_SECS):
                    self.counters["grace_reserves"] += 1
                    return 200, last["body"], last["tokens"], False, False
                chain["revoked"] = True
                self.violations.append({"at": now, "chain": rec["chain"],
                                        "why": "superseded refresh token reused outside the grace window"})
                self.counters["refresh_401"] += 1
                return 401, {"error": "refresh_chain_revoked"}, None, True, False
            # Success: consume, rotate, remember for the grace window.
            chain["consumed"].add(rt)
            chain["head"] = rt
            ttl = self.expire_in or ACCESS_TTL
            access = self._new_session(rec["boot"], rec["chain"], now + ttl, rec["gen"])
            rt2 = self._new_refresh(rec["boot"], rec["chain"], rec["gen"])
            body = {"refreshed_at": now, "session_exp": now + ttl, "refresh_exp": now + REFRESH_TTL}
            tokens = (access, rt2, ttl)
            chain["last"] = {"remote": remote, "at": now, "body": body, "tokens": tokens}
            self.counters["rotations"] += 1
            drop = self.drop_next_refresh
            self.drop_next_refresh = False
            if drop:
                self.counters["refresh_dropped"] += 1
            return 200, body, tokens, False, drop

    def logout(self, access, rt):
        with self.lock:
            self.sessions.pop(access or "", None)
            rec = self.refresh.get(rt or "")
            if rec:
                self.chains[rec["chain"]]["revoked"] = True

    def expire_all(self):
        with self.lock:
            for s in self.sessions.values():
                s["exp"] = 0

    def revoke_chains(self):
        with self.lock:
            for c in self.chains.values():
                c["revoked"] = True

    def logout_all(self):
        """`kirocrew logout`: bump the revocation generation."""
        with self.lock:
            self.gen += 1
            self.links.clear()

    def restart(self, down=0.0):
        """A gateway restart: new boot id; the in-memory link set and grace
        caches are lost, and every open connection drops. Persisted state
        (chains, consumed tokens, the generation) survives, so unbound
        sessions keep working."""
        with self.lock:
            self.boot = secrets.token_hex(16)
            self.links.clear()
            for c in self.chains.values():
                c["last"] = None
            self.down_until = time.time() + down
            self.counters["restarts"] += 1
            conns = list(self.connections)
        for s in conns:
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def is_down(self):
        with self.lock:
            return time.time() < self.down_until

    def snapshot(self):
        with self.lock:
            return {"boot": self.boot, "gen": self.gen, "counters": dict(self.counters),
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
class Page(HandshakeInThread, BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    gw = None                 # Gateway
    dist = DEFAULT_DIST
    allowed_hosts = set()     # host NAMES (the real check ignores the port)
    allowed_origins = set()

    def log_message(self, fmt, *a):
        pass

    # Track the connection, so a restart can drop it; refuse while "down".
    def setup(self):
        super().setup()
        with self.gw.lock:
            self.gw.connections.add(self.connection)

    def finish(self):
        try:
            super().finish()
        finally:
            with self.gw.lock:
                self.gw.connections.discard(self.connection)

    def handle(self):
        if self.gw.is_down():
            # A gateway mid-restart: accept, then close without a word.
            self.close_connection = True
            return
        super().handle()

    # -- helpers --
    def host_header(self):
        return (self.headers.get("Host") or "").strip().lower()

    def host_name(self):
        h = self.host_header()
        if h.startswith("["):
            return h.split("]", 1)[0] + "]"
        return h.rsplit(":", 1)[0] if ":" in h else h

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

    def auth_cookies(self, access, rt, access_ttl, legacy_clear=False, clear_refresh=False):
        p = self.cookie_port()
        hs = []
        if access:
            hs.append("mc_token_%s=%s; HttpOnly; Max-Age=%d; Path=/; SameSite=Lax%s"
                      % (p, access, max(0, min(int(access_ttl), ACCESS_TTL)), self.secure()))
        if legacy_clear:
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

    def is_shell_request(self, path):
        return self.command in ("GET", "HEAD") and not path.startswith(SHELL_EXCLUDED_PREFIXES)

    def deny(self, path, reason):
        """No valid credential. GET/HEAD navigations get the SPA shell (so it
        can boot and refresh); everything else a 403 + X-Auth-Required."""
        if self.is_shell_request(path):
            return self.serve_file("/index.html")
        self.gw.count("denials")
        if path.startswith("/api/"):
            return self.json(403, {"error": reason, "code": "forbidden"},
                             extra=[("X-Auth-Required", "true")])
        return self.send(403, "<!doctype html><title>Sign in</title><p>Sign in to Kiro Crew.</p>",
                         "text/html; charset=utf-8", extra=[("X-Auth-Required", "true")])

    def serve_file(self, path, cookies=()):
        rel = "index.html" if path in ("/", "/index.html") else path.lstrip("/")
        full = os.path.normpath(os.path.join(self.dist, rel))
        if not full.startswith(os.path.normpath(self.dist) + os.sep) or not os.path.isfile(full):
            # Client-side routes get the shell, as the real SPA fallback does.
            if "." not in os.path.basename(path) and not path.startswith(SHELL_EXCLUDED_PREFIXES):
                full = os.path.join(self.dist, "index.html")
            else:
                return self.send(404, "not found", "text/plain")
        if full.endswith("index.html"):
            self.gw.count("shell_loads")
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

        # 1. Host allowlist, by name (health endpoints exempt).
        if self.host_name() not in self.allowed_hosts and path not in ("/api/health", "/api/live", "/api/ready"):
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
        cookies = self.cookies()
        port = self.cookie_port()
        # 3. Exempt paths: no credential is looked at, and none is redeemed.
        if self.exempt(path):
            return self.route(path, None, None, cookies, port, [])
        # 4. The query token first; the cookie only as a fallback.
        access = cookies.get("mc_token_%s" % port)
        link = (query.get("token") or [None])[0]
        new_cookies = []
        if link:
            minted, reason = self.gw.redeem(link)
            if minted:
                access, rt, exp = minted
                new_cookies = self.auth_cookies(access, rt, exp - time.time(), legacy_clear=True)
                return self.route(path, self.gw.check_access(access)[0], access, cookies, port, new_cookies)
            session, cookie_reason = self.gw.check_access(access) if access else (None, None)
            if session is None:
                return self.deny(path, reason)
            return self.route(path, session, access, cookies, port, [])
        session, reason = self.gw.check_access(access)
        if session is None:
            return self.deny(path, reason)
        return self.route(path, session, access, cookies, port, [])

    def route(self, path, session, access, cookies, port, new_cookies):
        m = self.command
        if path == "/api/auth/me" and m == "GET":
            self.gw.count("auth_me_ok")
            if self.headers.get("X-Latchkey-Check"):
                self.gw.count("app_auth_checks")
            return self.json(200, {"user_id": "olof", "session_exp": session["exp"],
                                   "refresh_exp": self.gw.refresh_exp(cookies.get("mc_refresh_%s" % port))},
                             cookies=new_cookies)
        if path == "/api/auth/refresh" and m == "POST":
            status, body, tokens, clear, drop = self.gw.rotate(cookies.get("mc_refresh_%s" % port),
                                                               self.client_address[0])
            if drop:
                # The refresh happened; the client never hears about it.
                self.close_connection = True
                try:
                    self.connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                return None
            extra = [("Retry-After", "60")] if status == 429 else []
            cks = self.auth_cookies(tokens[0], tokens[1], tokens[2]) if tokens else []
            if clear:
                cks += self.auth_cookies(None, None, 0, clear_refresh=True)
            return self.json(status, body, extra=extra, cookies=cks)
        if path == "/api/auth/logout" and m == "POST":
            self.gw.logout(cookies.get("mc_token_%s" % port), cookies.get("mc_refresh_%s" % port))
            return self.json(200, {"logged_out": True}, cookies=[
                'mc_refresh_%s=""; Max-Age=0; Path=/api/auth' % port,
                'mc_token_%s=""; Max-Age=0; Path=/' % port])
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
        self.gw.count("ws_opens")
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
        head = self.rfile.read(2)
        if len(head) < 2:
            raise EOFError
        b1, b2 = head
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
        num = lambda k, d=0: float((q.get(k) or [d])[0])
        if u.path == "/__mint":
            kind = (q.get("kind") or ["cli"])[0]
            if kind not in ("cli", "qr"):
                return self.reply({"error": "kind is cli or qr"}, 400)
            link = self.gw.mint_link(kind, int(num("ttl")) or None)
            return self.reply({"link": link, "url": "%s/?token=%s" % (self.public_origin, link)})
        if u.path == "/__config":
            with self.gw.lock:
                self.gw.expire_in = int(num("expire_in"))
            return self.reply({"ok": True, "expire_in": self.gw.expire_in})
        if u.path == "/__restart":
            self.gw.restart(num("down"))
            return self.reply({"ok": True})
        if u.path == "/__drop-next-refresh":
            with self.gw.lock:
                self.gw.drop_next_refresh = True
            return self.reply({"ok": True})
        actions = {"/__expire": self.gw.expire_all, "/__revoke": self.gw.revoke_chains,
                   "/__logout-all": self.gw.logout_all, "/__reset": self.gw.reset}
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
    ap.add_argument("--print-pins", action="store_true", help="print the installed files' hashes and exit")
    a = ap.parse_args()

    if a.print_pins:
        print("version:", dist_version(a.dist))
        for rel in PINNED_FILES:
            print('    "%s": "%s",' % (rel, sha256(os.path.join(package_root(a.dist), rel))))
        return
    problems = check_bundle(a.dist)
    if a.check_bundle:
        for p in problems:
            print("FAIL:", p)
        print("bundle check: %s" % ("ok (KiroCrew %s, %d pinned files)" % (PINNED_VERSION, len(PINNED_FILES))
                                    if not problems else "FAILED"))
        sys.exit(1 if problems else 0)
    if problems:
        print("fake_gateway: refusing to start -- the installed KiroCrew is not the pinned one:", file=sys.stderr)
        for p in problems:
            print("  " + p, file=sys.stderr)
        sys.exit(2)
    if not (a.cert and a.key):
        ap.error("--cert and --key are required")

    gw = Gateway(a.expire_in, a.cookie_port)
    Page.gw = Control.gw = gw
    Page.dist = a.dist
    Page.allowed_hosts = {a.host, "127.0.0.1", "localhost", "[::1]"}
    Page.allowed_origins = {"https://%s" % a.host, "https://127.0.0.1:%d" % a.port,
                            "https://localhost:%d" % a.port}
    Control.public_origin = "https://%s" % a.host

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(a.cert, a.key)
    servers = []
    v4 = ThreadingHTTPServer(("127.0.0.1", a.port), Page)
    v4.socket = wrap_listener(ctx, v4.socket)   # handshake per connection (tls_accept)
    servers.append(v4)
    try:
        v6 = V6Server(("::1", a.port), Page)
        v6.socket = wrap_listener(ctx, v6.socket)
        servers.append(v6)
    except OSError:
        pass
    servers.append(ThreadingHTTPServer(("127.0.0.1", a.control_port), Control))
    for s in servers:
        threading.Thread(target=s.serve_forever, daemon=True).start()
    print("fake gateway (KiroCrew %s) https://%s -> 127.0.0.1:%d, control :%d, cookies mc_*_%d, expire-in %s"
          % (PINNED_VERSION, a.host, a.port, a.control_port, a.cookie_port, a.expire_in or "default"), flush=True)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
