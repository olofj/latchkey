#!/usr/bin/env python3
"""A fake KiroCrew gateway that serves the REAL 0.7.1 frontend (PLAN M4.1, R19).

Testing the app's session handling against a page we wrote would be circular:
the refresh scheduler, the 403 interceptor, the `mc-auth-*` events and the
`#mc-session-expired` banner exist only in KiroCrew's real bundles. So this
serves the pinned wheel's `kiro_crew/static/dist` byte for byte -- pinned,
with the server code the emulation was read from, and refusing to start on a
mismatch -- and emulates the server side of the auth contract as read from
the 0.7.1 source (re-read against 0.6.0's on 2026-09-25). Nothing of
KiroCrew's is run or imported (D10): the credentials here are opaque test
strings this fake invents, meaningless to a real gateway.

What is emulated (server source references are to kiro_crew/dashboard/):

  * Middleware order: Host allowlist (hostname only) -> CSRF (mutating
    methods) -> auth. Host and CSRF failures are text/plain 403s WITHOUT
    X-Auth-Required (server.py:681-792, 4869-4896, origin.py:342).
  * Auth-exempt paths return before any credential is looked at, so a
    `?token=` on one is not redeemed (token_auth.py:2819-2861).
  * Credentials: a `?token=` is validated FIRST. A valid link mints an access
    session and a NEW refresh chain and sets both cookies on whatever the
    route returns (`/` -> index.html, 200, no redirect) -- even over a valid
    cookie. An invalid link falls back to the cookie; without a valid cookie
    the link's failure stands (token_auth.py:2863-2941, 3045-3310).
  * Links: redeemable for min(300 s, ttl) from MINT, re-redeemable inside
    that window; the session runs to mint + ttl (token_auth.py:870, 3005). A
    restart forgets unredeemed links.
  * Cookies `mc_token_<P>` (HttpOnly; Max-Age; Path=/; SameSite=Lax; Secure)
    and `mc_refresh_<P>` (Path=/api/auth, 30 d sliding). <P> is the Host
    header's port, or the LISTEN port when the Host has none -- behind
    `tailscale serve` that is 5476 (token_auth.py:1395-1411). Redemption also
    clears the legacy `mc_token`; rotation does not (token_auth.py:3188,
    auth_refresh.py:598-602, 714-717).
  * Denials: 403 + `X-Auth-Required: true`; JSON {"error","code"} on /api/*,
    an HTML sign-in page elsewhere. GET/HEAD outside the data prefixes gets
    the SPA shell instead, so the SPA can boot and refresh
    (token_auth.py:606-700, 3370).
  * `GET /api/auth/me` -> {"user_id","session_exp","refresh_exp","token_accepted",
    "owner_ok"} (auth_refresh.py:418-436; the last two new in 0.7.x).
  * `POST /api/auth/refresh`, in the real order: rate limit (60 per sliding
    60 s per remote; 429 + Retry-After: 60) -> 401 no_refresh_cookie ->
    unknown/expired -> 401 invalid_refresh -> revoked chain -> 401
    refresh_chain_revoked + refresh-cookie clear -> revocation generation or
    `boot` mismatch -> 401 invalid_refresh (no clear) -> a superseded token is
    forgiven only as the chain head, from the same remote, within 60 s (the
    same tokens re-served); any other reuse revokes the chain
    (auth_refresh.py:440-719, refresh_tokens.py:343-390, 718-767).
  * `boot`: QR-shaped links (and everything minted from them) are
    boot-bound; CLI links are not, so their sessions survive a restart (R24).
  * Revocation generation (`kirocrew logout`): `/__logout-all` bumps it --
    every access session and refresh token is refused (token_auth.py:1357).
  * `POST /api/auth/logout`: revokes the chain, denylists the access cookie,
    clears both, answers {"logged_out": true} (auth_refresh.py:799-858).
    Counted as `logouts`, and as `logout_revocations` when a refresh cookie
    came along (the app's sign-out, R32, must show up as both).
  * /api/ws: auth before the upgrade, Origin check, then `slots` and a
    `dashboard` message every 5 s with a constant version (ws.py:378-662).
    Not sent: 0.7.x's owner-only `members_subscribed` frame, which nothing
    at boot waits for; client frames (`slot_read`, subscriptions) are read
    and dropped.
  * Not emulated: `POST /api/sandbox-doc` and `GET /sandbox-doc/<id>/<tok>`
    (handlers/sandbox_doc.py:135-259), nor the page-wide CSP headers
    (server.py:1089-1147, 1328-1429). The SPA's widget frames get a 404
    here, so F6's same-origin widget case is L1's, not this suite's.
  * F3's share routes, with the shapes read from 0.6.0 (and unchanged in
    0.7.0 and 0.7.1; handlers/files.py:1510, chat_handlers.py:393):
    GET /api/chat/slots (a bare array, serialize_slots' fields),
    GET /api/chat/folders, POST /api/upload/file (multipart part `file`, the
    50 MB limit and the extension allowlist, `%PDF-` for .pdf, {"paths"}),
    POST /api/chat ({"ok","slot"}; a busy slot {"ok","queued","queue_id"}).
    Where the real gateway SILENTLY CREATES a session for an unknown slot,
    this fake records a VIOLATION and answers 404, so the trap fails a test
    instead of making a stray session. A message naming an
    `[attached_file N] <path>` this fake never returned is a violation too.
    The WebSocket's `slots` message carries the same list.
  * The startup endpoints the SPA needs (theme/boot, ui-prefs,
    kiro-prerequisite); every other authenticated /api path is a 404 JSON.
    Unknown paths are recorded, so a gap in this fake shows up in /__state.

R25's hazard is tracked, not just emulated: every reuse of a superseded
refresh token outside the grace window is recorded as a LINEAGE VIOLATION.

F19's review gateway (docs/REVIEW-GATEWAY.md), both OFF unless configured:
  * `--demo-token T --demo-until DATE`: one fixed sign-in link, redeemable
    again and again (a real link: once, within 300 s) until DATE and never
    after. Its sessions and refresh chains end at DATE too. It is the fake's
    own string, never a KiroCrew credential; a restart, `/__reset` and
    `/__logout-all` keep it, and no control endpoint reveals it. DATE is at
    most 90 days out, so there is no unexpiring token.
  * `--content FILE`: canned sessions, folders, transcripts and a user name
    (testing/review/demo_content.json), served as the list, the folders and
    `GET /api/chat/slots/<key>`. A message posted to a canned session is
    appended with the file's canned reply.

Control (plain HTTP on 127.0.0.1:<control-port>):
  POST /__mint?kind=cli|qr[&ttl=S]   -> {"link", "url"}: a fresh sign-in link
                               (0.7.x fixes a real QR at 3600 s; a qr `ttl`
                               is test-only, tailnet_mobile.py:893-912)
  POST /__expire               expire every access session now (the 403 path)
  POST /__revoke               revoke every refresh chain, as reuse detection
                               does; access sessions stay valid
  POST /__logout-all           bump the revocation generation, as `kirocrew
                               logout` does: access AND refresh refused
  POST /__restart[?down=S]     a gateway restart: new boot id; forget links
                               and grace caches; drop every open connection;
                               optionally refuse connections for S seconds
  POST /__drop-next-refresh[?restart=1]
                               the next refresh is carried out (the token is
                               consumed) but its response is lost; with
                               restart=1 the gateway restarts at that instant,
                               so no retry can reach the grace cache first
                               (0.7.x's page retries within a second)
  POST /__config?expire_in=S   access TTL for sessions minted/rotated from now
  POST /__reset                forget everything (a fresh gateway)
  POST /__slots?keys=a,b[&busy=b]   the live sessions (F3), and which are busy
  POST /__upload-limit?bytes=N the upload limit (default 50 MB)
  POST /__csrf-deny?on=1       refuse POST /api/chat and /api/upload/file as
                               a CSRF failure (the 8443 origin case, F1 §4a)
  POST /__app-signed-out[?on=0]
                               refuse the app's own requests (X-Latchkey-Share,
                               X-Latchkey-Check) as a signed-out gateway does,
                               403 + X-Auth-Required, until the next sign-in
                               link is redeemed; the page's own requests are
                               served, so the page cannot notice first
  POST /__slow?slots=S&post=S  hold a share's GET /api/chat/slots for S
                               seconds before answering, and a POST /api/chat
                               for S seconds AFTER it is recorded (the
                               gateway has the message; the answer is late)
  GET  /__state                counters, violations, recent requests, unknown paths
  `--no-control` leaves the control port out entirely (the review gateway).

Socket activation (F19's review gateway): when systemd passes listening
sockets (LISTEN_PID is this process, LISTEN_FDS=n, fds 3..3+n-1), the page is
served on those and on nothing else; --port only names the origin then.
Without them it binds 127.0.0.1 and ::1 itself, as the suites expect.

  python3 fake_gateway.py --port 8444 --control-port 8481 --cert server.pem \\
      --key server.key --host gw.tail-scale.ts.net [--expire-in SECONDS]
  python3 fake_gateway.py --check-bundle      (the R19 pin and smoke test)
  python3 fake_gateway.py --new-demo-token    (print a fresh demo token)
"""
import argparse
import base64
import email.parser
import email.policy
import re
import hashlib
import json
import mimetypes
import os
import posixpath
import secrets
import socket
import ssl
import struct
import sys
import threading
import time
import urllib.request
from datetime import datetime, timedelta, timezone
import zipfile
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from tls_accept import HandshakeInThread, wrap_listener
from urllib.parse import parse_qs, urlsplit

# ---------------------------------------------------------------- the pin --
# What this fake emulates. A different version, bundle or server auth code is
# a hard failure, not a warning: the fake's semantics were read from THESE
# files, and drift would make every test answer the wrong question.
#
# The fixture is ONE released wheel, fetched from KiroCrew's own CDN (the URL
# its signed per-version manifest, cli/stable/<v>/cli-manifest.json, names)
# and held to the sha256 below -- the manifest's own. It is read in place:
# nothing is extracted, installed, run or imported. It used to be whatever the
# venv or the desktop app had installed, which KiroCrew upgrades under us: the
# suite then refused to start for as long as nobody re-pinned (0.6.0 -> 0.7.0
# on 2026-09-24), and the F6 session tests sat committed and unrun.
# To move the pin: fetch the new wheel and its manifest, re-read the auth code
# against this file, update the fake, re-pin (--print-pins), and have Olof
# re-run O7.
# KIROCREW_DIST names an installed copy instead (a package's static/dist, e.g.
# the desktop app's) for a machine without the wheel. It moves where the files
# are read from, never what they must be: the pins below still decide.
PINNED_VERSION = "0.7.1"
PINNED_WHEEL_URL = "https://download.crew.kiro.dev/cli/stable/0.7.1/kirocrew-0.7.1-py3-none-any.whl"
PINNED_WHEEL_SHA256 = "dfb4a31c1d606390e21c659a44f240b1c24700728770a1685ec94d300267f461"
WHEEL_CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".cache",
                           os.path.basename(PINNED_WHEEL_URL))
DEFAULT_DIST = os.environ.get("KIROCREW_DIST") or WHEEL_CACHE
PINNED_FILES = {
    # The frontend. index.html names every other asset by content hash, so
    # pinning it pins the entry graph; the three bundles carry the auth code.
    "static/dist/index.html": "a72d684fff1ec557faa89842c08bfea77a82ae33c4ba3cb1b5a4fbb516df095a",
    "static/dist/assets/main-BkIou08w.js": "81cc0a9ffd1bc543b296c432c23605357a0c13d92a6b4688165368935bb831da",
    "static/dist/assets/client-D5eTcPHC.js": "341acbee9bd048f07a7fa85bf292942a99625eb3e25ae9887e2178b8be8b3bd1",
    "static/dist/assets/App-e17PGpKz.js": "e840f8e3b4afdbb99acab5d3a3c2d5bf0c9978ac0e982e6c40e81f6d385f1425",
    # The server code the emulation was read from (M4 review: a same-version
    # rebuild could change these while the frontend stays byte-identical).
    "dashboard/token_auth.py": "801eb10ac6125273a730090fa446e2b09188db1a6ac2143951b935b887ec96c8",
    "dashboard/refresh_tokens.py": "14fcfe0b41a7f24921249d19376b4649a70a93e8440248cebec9fe45669f25ae",
    "dashboard/server.py": "48b7abbc7d091c1dca7dd305fec737735b122d3ec7319b35442543c185ed8cf9",
    "dashboard/origin.py": "399ae7eb3b88c8a96c2ce2c3616eb15e709d08c73f8674dbd861d56aae9ea71d",
    "dashboard/urls.py": "94024af4519c6e82be0f12d90a021eb995d8f227c3581122c9fa95b82994756f",
    "dashboard/ws.py": "d7e1eb391b4a8b9a59a37baf922339984d550ed3e6e4486a19813bcb47939948",
    "dashboard/boot_id.py": "731c0285aa0b8420aef1f4deea60f087ba9eab7498e16e9fc0a4ddb839a29a8d",
    "dashboard/revocation_gen.py": "9b1d49a298540939baa57d3aaf553a279174f80e480fea4ee584fdc9323f5f62",
    "dashboard/tailnet.py": "caf43abea9d53706ffada936e9628da845aee88f8160ae219802481fe4a70a05",
    "dashboard/handlers/auth_refresh.py": "2b6a0ff9fd3e573ac22a38a0c3440264220b40a684151adf6a09734a250a0a89",
    "dashboard/handlers/tailnet_mobile.py": "d3e684f63e8493b1d702ec6e57e333313292a8bf5c430474ee19c9d8e04ba803",
    "dashboard/handlers/core.py": "401db947a55dfcce456e5b00baf5e71f0aa55c292bceef61b809c206a79a3653",
}
# What the app depends on (R19's smoke test): the events it listens for, the
# banner it hides, and the terminal refresh error it must survive.
REQUIRED_STRINGS = {
    "static/dist/assets/client-D5eTcPHC.js": ["mc-auth-required", "mc-auth-cleared", "mc-session-expired",
                                              "X-Auth-Required", "/api/auth/refresh"],
    "static/dist/assets/main-BkIou08w.js": ["refresh_chain_revoked", "/api/auth/me"],
}

GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
LINK_WINDOW = 300            # a sign-in link is redeemable for min(this, ttl)
ACCESS_TTL = 72000           # 20 h: the cap, and what every rotation re-mints
REFRESH_TTL = 2592000        # 30 d, sliding
QR_SESSION_TTL = 3600        # the QR default
GRACE_SECS = 60
RATE_LIMIT = 60              # refreshes per sliding 60 s, per remote
LINK_SET_MAX = 50
DEMO_TOKEN_RE = re.compile(r"fk1\.[A-Za-z0-9_-]{32,}")   # the shape mint_link gives
DEMO_MAX_DAYS = 90           # a TestFlight build's life; renew, never unexpiring
TRANSCRIPT_MAX = 200         # canned transcripts stop growing here
# With --content only: empty answers where the page shows a 404 as a red
# error ("Session controls unavailable" is GET /api/apps; the instance chip's
# warning is GET /api/instances). Shapes from client-D5eTcPHC.js/App-*.js.
CONTENT_EMPTY = {"/api/apps": {"apps": []}, "/api/instances": {"instances": []}}

# F3: the share routes (dashboard/handlers/files.py, dashboard/chat_handlers.py).
MAX_UPLOAD = 50 * 1024 * 1024
DEFAULT_SLOTS = ["obsidian", "notes", "plan"]
SLOT_INFO = {"obsidian": ("Obsidian vault", "f-notes"), "notes": ("Reading notes", "f-notes"),
             "plan": ("Weekly plan", "f-work")}
FOLDERS = [{"id": "f-notes", "name": "Notes", "history_count": 0},
           {"id": "f-work", "name": "Work", "history_count": 0}]
UPLOAD_EXT = set((".png .jpg .jpeg .gif .webp .bmp .svg .txt .md .json .excalidraw .har .yaml .yml .xml "
                  ".csv .log .py .js .ts .tsx .jsx .html .css .sh .bash .rb .go .rs .java .c .cpp .h .hpp "
                  ".pdf .doc .docx .xls .xlsx .ppt .pptx .odt .ods .odp .rtf .zip .tar .gz "
                  ".mp4 .m4v .mov .webm").split())

EXEMPT_PREFIXES = ("/assets/", "/static/", "/fonts/", "/vendor/", "/artifact-app/", "/sandbox-doc/")
EXEMPT_EXACT = {"/logo.png", "/favicon.ico", "/manifest.json", "/sw.js", "/pcm-worklet.js",
                "/api/token/local", "/api/shutdown", "/api/logout", "/api/theme/boot",
                "/api/health", "/api/live", "/api/ready"}
EXEMPT_POST = {"/api/auth/refresh", "/api/auth/logout"}
# GET/HEAD of anything under these is a data request: no SPA shell for it.
SHELL_EXCLUDED_PREFIXES = ("/api/", "/v1/", "/assets/", "/static/", "/sprites/", "/vendor/",
                           "/fonts/", "/app-assets/", "/artifact-app/", "/sandbox-doc/", "/feature-videos/")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


class Bundle:
    """The kiro_crew package's files, read-only, by path under `kiro_crew/`:
    from the pinned wheel (a zip, read in place) or from an installed
    package's `static/dist` directory. Nothing is extracted or executed."""

    def __init__(self, source):
        self.source = source
        self.lock = threading.Lock()
        self.cache = {}
        self.zip = None
        if os.path.isfile(source):
            self.zip = zipfile.ZipFile(source)
            self.names = set(self.zip.namelist())
            self.root = None
        else:
            self.root = os.path.dirname(os.path.dirname(os.path.abspath(source)))

    def read(self, rel):
        """kiro_crew/<rel>'s bytes, or None if there is no such file."""
        rel = posixpath.normpath(rel)
        if rel.startswith(("../", "/")) or rel in (".", ".."):
            return None
        with self.lock:
            if rel in self.cache:
                return self.cache[rel]
            if self.zip is not None:
                name = "kiro_crew/" + rel
                data = self.zip.read(name) if name in self.names else None
            else:
                p = os.path.join(self.root, *rel.split("/"))
                data = None
                if os.path.isfile(p):
                    with open(p, "rb") as f:
                        data = f.read()
            self.cache[rel] = data
            return data

    def version(self):
        """The kirocrew version, from the dist-info beside the package."""
        if self.zip is not None:
            metas = [n for n in self.names if n.startswith("kirocrew-") and n.endswith(".dist-info/METADATA")]
            text = self.zip.read(metas[0]).decode() if len(metas) == 1 else ""
        else:
            site, text = os.path.dirname(self.root), ""
            for name in os.listdir(site):
                if name.startswith("kirocrew-") and name.endswith(".dist-info"):
                    with open(os.path.join(site, name, "METADATA")) as f:
                        text = f.read()
        for line in text.splitlines():
            if line.startswith("Version:"):
                return line.split(":", 1)[1].strip()
        return None


def fetch_wheel():
    """Download the pinned wheel into WHEEL_CACHE, verified before it lands."""
    if os.path.isfile(WHEEL_CACHE) and sha256_file(WHEEL_CACHE) == PINNED_WHEEL_SHA256:
        return "cached"
    os.makedirs(os.path.dirname(WHEEL_CACHE), exist_ok=True)
    tmp = WHEEL_CACHE + ".part"
    with urllib.request.urlopen(PINNED_WHEEL_URL, timeout=120) as r, open(tmp, "wb") as f:
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
    got = sha256_file(tmp)
    if got != PINNED_WHEEL_SHA256:
        os.unlink(tmp)
        raise SystemExit("error: %s has sha256 %s, pinned %s" % (PINNED_WHEEL_URL, got, PINNED_WHEEL_SHA256))
    os.replace(tmp, WHEEL_CACHE)
    return "fetched"


def check_bundle(dist):
    """The R19 pin and smoke test. Returns a list of problems (empty = ok)."""
    if not os.path.exists(dist):
        return ["%s does not exist (make bundle fetches the pinned wheel)" % dist]
    problems = []
    b = Bundle(dist)
    if b.zip is not None and sha256_file(dist) != PINNED_WHEEL_SHA256:
        problems.append("%s is not the pinned wheel (sha256 %s)" % (dist, PINNED_WHEEL_SHA256[:12]))
    v = b.version()
    if v != PINNED_VERSION:
        problems.append("the bundle is KiroCrew %s, the fake was written against %s" % (v, PINNED_VERSION))
    if b.read("BUILD_VERSION") is not None:
        problems.append("a BUILD_VERSION stamp is present: not the pinned release build")
    for rel, want in PINNED_FILES.items():
        data = b.read(rel)
        if data is None:
            problems.append("%s is missing" % rel)
        elif hashlib.sha256(data).hexdigest() != want:
            problems.append("%s changed (sha256 %s, pinned %s)"
                            % (rel, hashlib.sha256(data).hexdigest()[:12], want[:12]))
    for rel, needles in REQUIRED_STRINGS.items():
        body = b.read(rel)
        if body is None:
            continue
        for n in needles:
            if n.encode() not in body:
                problems.append("%s no longer contains %r" % (rel, n))
    return problems


# ------------------------------------------------------------------ state --
# ------------------------------------------------- the review gateway (F19) --
def parse_demo_until(s, now=None):
    """`--demo-until`: a date (the demo ends at the END of that day, UTC) or
    an ISO date-time with a zone. -> epoch seconds. Refuses the past and
    anything more than DEMO_MAX_DAYS out."""
    now = time.time() if now is None else now
    try:
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", s):
            dt = datetime.strptime(s, "%Y-%m-%d").replace(tzinfo=timezone.utc) + timedelta(days=1)
        else:
            dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
            if dt.tzinfo is None:
                raise ValueError("no time zone")
    except ValueError as e:
        raise SystemExit("error: --demo-until %r: %s (YYYY-MM-DD, or ISO with a zone)" % (s, e))
    until = dt.timestamp()
    if until <= now:
        raise SystemExit("error: --demo-until %s is already past" % s)
    if until > now + DEMO_MAX_DAYS * 86400 + 86400:
        raise SystemExit("error: --demo-until %s is more than %d days out" % (s, DEMO_MAX_DAYS))
    return until


def load_content(path):
    """`--content`: the canned dashboard, checked here so a typo fails at
    start rather than as a blank page in front of a reviewer."""
    with open(path, encoding="utf-8") as f:
        c = json.load(f)
    folders = [{"id": d["id"], "name": d["name"], "history_count": 0} for d in c.get("folders", [])]
    ids = {d["id"] for d in folders}
    slots = []
    for s in c["slots"]:
        if not re.fullmatch(r"[a-z0-9-]+", s["key"]) or s["key"].startswith("member-"):
            raise SystemExit("error: %s: slot key %r" % (path, s["key"]))
        if s.get("folder_id") not in ids | {None}:
            raise SystemExit("error: %s: slot %s names folder %r" % (path, s["key"], s.get("folder_id")))
        msgs = s.get("messages", [])
        for m in msgs:
            if m.get("role") not in ("user", "assistant") or not isinstance(m.get("content"), str):
                raise SystemExit("error: %s: slot %s: a message needs role user|assistant and content"
                                 % (path, s["key"]))
        slots.append({"key": s["key"], "title": s["title"], "folder_id": s.get("folder_id"), "messages": msgs})
    if not slots or len({s["key"] for s in slots}) != len(slots):
        raise SystemExit("error: %s: no slots, or a key twice" % path)
    return {"user_id": c.get("user_id", "demo"), "folders": folders, "slots": slots,
            "reply": c.get("reply", "")}


def iso(t):
    return datetime.fromtimestamp(t, timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


class Gateway:
    """All server-side auth state. One lock; every method takes it."""

    def __init__(self, expire_in, cookie_port, demo=None, content=None):
        self.lock = threading.Lock()
        self.default_expire_in = expire_in
        self.cookie_port = cookie_port
        # F19: (token, until) or None. Configuration, not state: a restart,
        # /__reset and /__logout-all keep it.
        self.demo = demo
        self.content = content
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
                         "app_auth_checks": 0, "shell_loads": 0, "restarts": 0,
                         "logouts": 0, "logout_revocations": 0}
        self.violations = []     # R25: superseded refresh token used outside grace
        self.requests = deque(maxlen=300)
        self.unknown = {}        # path -> count: routes this fake does not implement
        # F3: the share routes.
        self.slot_keys = list(DEFAULT_SLOTS)
        self.busy = {"plan"}
        self.upload_limit = MAX_UPLOAD
        self.csrf_deny = False
        self.app_signed_out = False
        self.slow_slots = 0.0
        self.slow_post = 0.0
        self.uploads = {}        # returned path -> bytes
        self.posts = []          # {"slot", "message", "item", "at"}
        self.navigations = []    # {"sid", "prefill"} for GET /chat?...
        for k in ("slot_lists", "share_posts", "share_uploads", "upload_bytes", "share_denials",
                  "app_signed_out_denials", "demo_redemptions"):
            self.counters[k] = 0
        # The dashboard's contents: the suites' three sessions, or F19's
        # canned ones. Transcripts exist only with --content.
        self.user_id = "olof"
        self.slot_info = dict(SLOT_INFO)
        self.folders = FOLDERS
        self.transcripts = {}    # key -> [{"role", "content", "ts", "cls"}]
        if self.content:
            now = time.time()
            self.user_id = self.content["user_id"]
            self.folders = self.content["folders"]
            self.slot_keys = [s["key"] for s in self.content["slots"]]
            self.busy = set()
            self.slot_info = {s["key"]: (s["title"], s["folder_id"]) for s in self.content["slots"]}
            for s in self.content["slots"]:
                # "ago" (minutes) keeps a months-old file looking like last night's work.
                self.transcripts[s["key"]] = [
                    {"role": m["role"], "content": m["content"],
                     "ts": iso(now - 60 * m.get("ago", 0)),
                     "cls": "msg msg-u" if m["role"] == "user" else "msg msg-a"}
                    for m in s["messages"]]

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
            until = None
            if self.demo and secrets.compare_digest(link.encode(), self.demo[0].encode()):
                # F19's demo token: a CLI link minted at every redemption,
                # so the 300 s window never runs out -- but the date does.
                until = self.demo[1]
                if now > until:
                    return None, "token expired"
                rec = {"mint": now, "ttl": ACCESS_TTL, "kind": "cli", "gen": self.gen}
            if rec is None:
                return None, "no active sessions" if link.startswith("fk1.") else "malformed token"
            if now > rec["mint"] + min(LINK_WINDOW, rec["ttl"]):
                return None, "token expired"
            if rec["gen"] < self.gen:
                return None, "session revoked"
            boot = self.boot if rec["kind"] == "qr" else None
            chain = secrets.token_hex(8)
            self.chains[chain] = {"revoked": False, "consumed": set(), "head": None, "last": None,
                                  "until": until}
            exp = now + self.expire_in if self.expire_in else rec["mint"] + rec["ttl"]
            if until:
                exp = min(exp, until)
                self.counters["demo_redemptions"] += 1
            access = self._new_session(boot, chain, exp, self.gen)
            rt = self._new_refresh(boot, chain, self.gen)
            self.counters["redemptions"] += 1
            self.app_signed_out = False     # signing in again ends /__app-signed-out
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
            # The real order (refresh_tokens.py:743-766): revoked chain, then
            # the revocation generation, then boot.
            if chain["revoked"]:
                self.counters["refresh_401"] += 1
                return 401, {"error": "refresh_chain_revoked"}, None, True, False
            if rec["gen"] < self.gen or (rec["boot"] and rec["boot"] != self.boot):
                self.counters["refresh_401"] += 1
                return 401, {"error": "invalid_refresh"}, None, False, False
            until = chain.get("until")
            if until and now > until:
                # A demo chain ends with its token's date (F19).
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
            if until:
                ttl = min(ttl, until - now)
            access = self._new_session(rec["boot"], rec["chain"], now + ttl, rec["gen"])
            rt2 = self._new_refresh(rec["boot"], rec["chain"], rec["gen"])
            body = {"refreshed_at": now, "session_exp": now + ttl, "refresh_exp": now + REFRESH_TTL}
            tokens = (access, rt2, ttl)
            chain["last"] = {"remote": remote, "at": now, "body": body, "tokens": tokens}
            self.counters["rotations"] += 1
            drop = self.drop_next_refresh      # False, "drop" or "restart"
            self.drop_next_refresh = False
            if drop:
                self.counters["refresh_dropped"] += 1
            return 200, body, tokens, False, drop

    def logout(self, access, rt):
        """`POST /api/auth/logout`. Counted apart: `logouts` is every call,
        `logout_revocations` those that carried a refresh cookie and so
        revoked a chain -- the app's sign-out (R32) must be the latter, or
        its fetch left the cookies out and the gateway kept the session."""
        with self.lock:
            self.counters["logouts"] += 1
            self.sessions.pop(access or "", None)
            rec = self.refresh.get(rt or "")
            if rec:
                self.chains[rec["chain"]]["revoked"] = True
                self.counters["logout_revocations"] += 1

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
                    "posts": list(self.posts), "navigations": list(self.navigations),
                    "slots": list(self.slot_keys), "busy": sorted(self.busy),
                    "uploads": dict(self.uploads),
                    "cookie_port": self.cookie_port,
                    # When the demo token stops, never the token itself.
                    "demo_until": self.demo[1] if self.demo else None}

    def slots(self):
        """serialize_slots' shape (state.py:7515 in 0.7.1), newest first."""
        with self.lock:
            keys, busy, info = list(self.slot_keys), set(self.busy), dict(self.slot_info)
            last = {k: t[-1] for k, t in self.transcripts.items() if t}
        now = time.time()
        out = []
        for i, k in enumerate(keys):
            title, folder = info.get(k, (k.capitalize(), None))
            at = now - 60 * (i + 1)
            if k in last:
                at = datetime.fromisoformat(last[k]["ts"].replace("Z", "+00:00")).timestamp()
            out.append({"key": k, "title": title, "folder_id": folder, "agent": "kiro", "mode": "",
                        "surface": "", "running": k in busy, "queue_depth": 1 if k in busy else 0,
                        "last_activity_ts": at, "last_message": k in last and last[k]["content"][:120] or "",
                        "memory_mode": "global", "pinned": False, "subagents_running": 0})
        return out

    def transcript(self, key):
        """`GET /api/chat/slots/<key>`'s shape (chat_handlers.py:2650-2672), or
        None: only --content's sessions have one."""
        with self.lock:
            msgs = list(self.transcripts.get(key) or [])
            title = self.slot_info.get(key, (key, None))[0]
        if not msgs:
            return None
        return {"key": key, "title": title, "running": False, "stopping": False, "messages": msgs,
                "queue": [], "total": len(msgs), "has_more": False, "next_before": 0}

    def converse(self, key, message):
        """A message posted to a canned session, and the file's canned reply."""
        now = time.time()
        with self.lock:
            t = self.transcripts.get(key)
            if t is None:
                return
            t.append({"role": "user", "content": message, "ts": iso(now), "cls": "msg msg-u"})
            if self.content.get("reply"):
                t.append({"role": "assistant", "content": self.content["reply"], "ts": iso(now),
                          "cls": "msg msg-a"})
            del t[:-TRANSCRIPT_MAX]

    def violation(self, why, **kw):
        with self.lock:
            self.violations.append(dict({"at": time.time(), "why": why}, **kw))

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
    bundle = None             # Bundle
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
        # A request refused before its body was read (CSRF, auth) must still
        # have it read: left on a keep-alive connection, it is parsed as the
        # NEXT request's first line, which then fails as a 501 (found by F3's
        # prefill test: a 403'd POST /api/chat broke the navigation after it).
        self.body()
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

    def share_denied(self):
        """A 403 to one of the app's share requests (F3's L2 ordering check)."""
        if self.headers.get("X-Latchkey-Share"):
            self.gw.count("share_denials")

    def body(self):
        if getattr(self, "_body", None) is None:
            n = int(self.headers.get("Content-Length") or 0)
            self._body = self.rfile.read(n) if n > 0 else b""
        return self._body

    def deny(self, path, reason):
        """No valid credential. GET/HEAD navigations get the SPA shell (so it
        can boot and refresh); everything else a 403 + X-Auth-Required."""
        if self.is_shell_request(path):
            return self.serve_file("/index.html")
        self.gw.count("denials")
        self.share_denied()
        if path.startswith("/api/"):
            return self.json(403, {"error": reason, "code": "forbidden"},
                             extra=[("X-Auth-Required", "true")])
        return self.send(403, "<!doctype html><title>Sign in</title><p>Sign in to Kiro Crew.</p>",
                         "text/html; charset=utf-8", extra=[("X-Auth-Required", "true")])

    def serve_file(self, path, cookies=()):
        rel = "index.html" if path in ("/", "/index.html") else path.lstrip("/")
        data = self.bundle.read("static/dist/" + rel)
        if data is None:
            # Client-side routes get the shell, as the real SPA fallback does.
            if "." not in posixpath.basename(path) and not path.startswith(SHELL_EXCLUDED_PREFIXES):
                rel = "index.html"
                data = self.bundle.read("static/dist/index.html")
            else:
                return self.send(404, "not found", "text/plain")
        if rel.endswith("index.html"):
            self.gw.count("shell_loads")
        ctype = mimetypes.guess_type(rel)[0] or "application/octet-stream"
        if rel.endswith((".js", ".mjs")):
            ctype = "text/javascript; charset=utf-8"
        cache = "public, max-age=31536000, immutable" if path.startswith("/assets/") else None
        return self.send(200, data, ctype, cookies=cookies, cache=cache)

    def exempt(self, path):
        return (path.startswith(EXEMPT_PREFIXES) or path in EXEMPT_EXACT
                or (self.command == "POST" and path in EXEMPT_POST)
                or (path.startswith("/icon-") and path.endswith(".png")))

    # -- the middleware chain --
    def handle_any(self):
        self._body = None
        u = urlsplit(self.path)
        path, query = u.path, parse_qs(u.query)
        self.gw.record("%s %s%s" % (self.command, path, "?…" if u.query else ""))
        if self.command == "GET" and path == "/chat" and "sid" in query:
            with self.gw.lock:
                self.gw.navigations.append({"sid": query["sid"][0], "prefill": "prefill" in query})

        # 1. Host allowlist, by name (health endpoints exempt).
        if self.host_name() not in self.allowed_hosts and path not in ("/api/health", "/api/live", "/api/ready"):
            return self.send(403, "Host header not allowed.", "text/plain; charset=utf-8")
        # 2. CSRF for mutating methods: Origin, else Referer, else loopback peer only.
        if (self.command == "POST" and path in ("/api/chat", "/api/upload/file")
                and self.gw.csrf_deny):
            self.share_denied()
            return self.send(403, "CSRF check failed: request origin not allowed.", "text/plain; charset=utf-8")
        if self.command in ("POST", "PUT", "DELETE", "PATCH"):
            origin = self.headers.get("Origin")
            if origin is None and self.headers.get("Referer"):
                ref = urlsplit(self.headers["Referer"])
                origin = "%s://%s" % (ref.scheme, ref.netloc)
            loopback = self.client_address[0] in ("127.0.0.1", "::1")
            if (origin is None and not loopback) or (origin is not None and origin not in self.allowed_origins):
                self.share_denied()
                return self.send(403, "CSRF check failed: request origin not allowed.", "text/plain; charset=utf-8")
        cookies = self.cookies()
        port = self.cookie_port()
        # 3. Exempt paths: no credential is looked at, and none is redeemed.
        if self.exempt(path):
            return self.route(path, None, None, cookies, port, [])
        # /__app-signed-out: the app's own requests find the session gone
        # while the page's are served, so the page cannot notice first.
        if self.gw.app_signed_out and (self.headers.get("X-Latchkey-Share")
                                       or self.headers.get("X-Latchkey-Check")):
            self.gw.count("app_signed_out_denials")
            return self.deny(path, "token expired")
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
            # 0.7.1: token_accepted is true only when THIS request's ?token=
            # authenticated it (a redemption sets new cookies; a failed link
            # that fell back to the cookie does not); owner_ok is true for
            # the owner's own browser session (auth_refresh.py:418-436).
            return self.json(200, {"user_id": self.gw.user_id, "session_exp": session["exp"],
                                   "refresh_exp": self.gw.refresh_exp(cookies.get("mc_refresh_%s" % port)),
                                   "token_accepted": bool(new_cookies), "owner_ok": True},
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
                if drop == "restart":
                    self.gw.restart()
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
        if path == "/api/chat/slots" and m == "GET":
            if self.headers.get("X-Latchkey-Share"):
                self.gw.count("slot_lists")
                time.sleep(self.gw.slow_slots)
            return self.json(200, self.gw.slots(), cookies=new_cookies)
        if path == "/api/chat/folders" and m == "GET":
            return self.json(200, self.gw.folders, cookies=new_cookies)
        if path.startswith("/api/chat/slots/") and m == "GET":
            # F19's canned transcripts; without --content this stays a 404.
            detail = self.gw.transcript(path[len("/api/chat/slots/"):])
            if detail is not None:
                return self.json(200, detail, cookies=new_cookies)
        if self.gw.content and m == "GET" and path in CONTENT_EMPTY:
            return self.json(200, CONTENT_EMPTY[path], cookies=new_cookies)
        if path == "/api/upload/file" and m == "POST":
            return self.upload()
        if path == "/api/chat" and m == "POST":
            return self.chat_post()
        if path.startswith("/api/"):
            self.gw.record_unknown("%s %s" % (m, path))
            return self.json(404, {"error": "not found"}, cookies=new_cookies)
        if path in ("/logo.png", "/favicon.ico") and m in ("GET", "HEAD"):
            # Served from static/, outside dist (handlers/core.py:429-437):
            # a 404 here is one of "the gateway's own assets failed" (F6).
            return self.send(200, self.bundle.read("static/kirocrew-logo.png"), "image/png")
        if m in ("GET", "HEAD"):
            return self.serve_file(path, cookies=new_cookies)
        self.gw.record_unknown("%s %s" % (m, path))
        return self.send(404, "not found", "text/plain")

    do_GET = do_HEAD = do_POST = do_PUT = do_DELETE = do_PATCH = handle_any

    # -- F3: upload and send --
    def upload(self):
        raw = self.body()
        ctype = self.headers.get("Content-Type") or ""
        msg = email.parser.BytesParser(policy=email.policy.HTTP).parsebytes(
            b"Content-Type: " + ctype.encode() + b"\r\n\r\n" + raw)
        files = [p for p in (msg.iter_parts() if msg.is_multipart() else [])
                 if p.get_param("name", header="content-disposition") == "file"]
        if not files:
            return self.json(400, {"error": "No files uploaded"})
        part = files[0]
        name = part.get_filename() or "file"
        data = part.get_payload(decode=True) or b""
        ext = os.path.splitext(name)[1].lower()
        if ext not in UPLOAD_EXT:
            return self.json(400, {"error": "Unsupported file type: %s" % ext, "code": "unsupported_file_type"})
        limit = self.gw.upload_limit
        if len(data) > limit:
            return self.json(413, {"error": "File too large (max %dMB)" % (limit // (1024 * 1024))})
        if ext == ".pdf" and not data.startswith(b"%PDF-"):
            return self.json(400, {"error": "File content does not match its type: %s" % ext})
        safe = "".join(c if c.isalnum() or c in "_.-" else "_" for c in name)
        path = "/srv/kirocrew/uploads/%s/%s" % (secrets.token_hex(6), safe)
        with self.gw.lock:
            self.gw.uploads[path] = len(data)
            if self.headers.get("X-Latchkey-Share"):
                self.gw.counters["share_uploads"] += 1
                self.gw.counters["upload_bytes"] += len(data)
        return self.json(200, {"paths": [path]})

    def chat_post(self):
        try:
            body = json.loads(self.body() or b"{}")
        except ValueError:
            return self.json(400, {"error": "invalid JSON"})
        slot, message = body.get("slot"), (body.get("message") or "").strip()
        if not slot:
            return self.json(400, {"error": "slot is required (this fake; the real gateway picks one)"})
        if not message:
            return self.json(400, {"error": "message is required", "code": "message_required"})
        if slot.startswith("member-"):
            return self.json(409, {"error": "member slot reserved", "code": "member_slot_reserved"})
        with self.gw.lock:
            listed, busy = slot in self.gw.slot_keys, slot in self.gw.busy
            uploaded = set(self.gw.uploads)
        item = self.headers.get("X-Latchkey-Share")
        if not listed:
            # The real gateway would CREATE this session (chat_handlers.py:515-517).
            self.gw.violation("post to a slot not in the list: the real gateway would create it",
                              slot=slot, item=item)
            return self.json(404, {"error": "no such slot (the real gateway would have created one)"})
        for mt in re.finditer(r"\[attached_file (\d+)\][ \t]+(\S+)", message):
            if mt.group(2) not in uploaded:
                self.gw.violation("an [attached_file] path this gateway never returned", item=item)
                return self.json(400, {"error": "attached file not found"})
        with self.gw.lock:
            self.gw.posts.append({"slot": slot, "message": message, "item": item, "at": time.time()})
            if item:
                self.gw.counters["share_posts"] += 1
        self.gw.converse(slot, message)
        time.sleep(self.gw.slow_post)
        if busy:
            return self.json(200, {"ok": True, "queued": True, "queue_id": "q-" + secrets.token_hex(4)})
        return self.json(200, {"ok": True, "slot": slot, "mid": "m-" + secrets.token_hex(4)})

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
                    self.ws_write(0x1, json.dumps({"type": "slots", "data": self.gw.slots()}).encode())
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
        if u.path == "/__slots":
            keys = [k for k in ",".join(q.get("keys") or [""]).split(",") if k]
            with self.gw.lock:
                self.gw.slot_keys = keys
                self.gw.busy = {k for k in ",".join(q.get("busy") or [""]).split(",") if k}
            return self.reply({"ok": True, "slots": keys})
        if u.path == "/__upload-limit":
            with self.gw.lock:
                self.gw.upload_limit = int(num("bytes", MAX_UPLOAD))
            return self.reply({"ok": True})
        if u.path == "/__csrf-deny":
            with self.gw.lock:
                self.gw.csrf_deny = num("on") != 0
            return self.reply({"ok": True})
        if u.path == "/__app-signed-out":
            with self.gw.lock:
                self.gw.app_signed_out = num("on", 1) != 0
            return self.reply({"ok": True})
        if u.path == "/__slow":
            with self.gw.lock:
                self.gw.slow_slots, self.gw.slow_post = num("slots"), num("post")
            return self.reply({"ok": True})
        if u.path == "/__drop-next-refresh":
            with self.gw.lock:
                self.gw.drop_next_refresh = "restart" if num("restart") else "drop"
            return self.reply({"ok": True})
        actions = {"/__expire": self.gw.expire_all, "/__revoke": self.gw.revoke_chains,
                   "/__logout-all": self.gw.logout_all, "/__reset": self.gw.reset}
        if u.path in actions:
            actions[u.path]()
            return self.reply({"ok": True})
        return self.reply({"error": "not found"}, 404)


class V6Server(ThreadingHTTPServer):
    address_family = socket.AF_INET6


SD_LISTEN_FDS_START = 3


def inherited_listeners():
    """The listening sockets systemd passed (sd_listen_fds(3)), or [].

    Only when LISTEN_PID is this process: the variables leak to anything a
    service execs, and a child must not take its parent's sockets. They are
    unset either way, as sd_listen_fds(unset_environment=1) does."""
    pid, n = os.environ.pop("LISTEN_PID", ""), os.environ.pop("LISTEN_FDS", "")
    os.environ.pop("LISTEN_FDNAMES", None)
    if not (pid.isdigit() and int(pid) == os.getpid() and n.isdigit()):
        return []
    socks = []
    for fd in range(SD_LISTEN_FDS_START, SD_LISTEN_FDS_START + int(n)):
        os.set_inheritable(fd, False)
        s = socket.socket(fileno=fd)   # family and type from the fd itself
        try:
            listens = s.getsockopt(socket.SOL_SOCKET, socket.SO_ACCEPTCONN) != 0
        except OSError:   # macOS has no SO_ACCEPTCONN (the tests); bound will do
            listens = s.family in (socket.AF_INET, socket.AF_INET6) and s.getsockname()[1] != 0
        if s.type != socket.SOCK_STREAM or not listens:
            sys.exit("fake_gateway: inherited fd %d is not a listening stream socket (Accept=no, ListenStream=)" % fd)
        socks.append(s)
    return socks


def server_on(sock, handler):
    """A ThreadingHTTPServer on an already bound and listening socket."""
    srv = ThreadingHTTPServer(sock.getsockname()[:2], handler, bind_and_activate=False)
    srv.socket.close()
    srv.socket = sock
    srv.server_address = sock.getsockname()
    srv.server_name, srv.server_port = srv.server_address[0], srv.server_address[1]
    return srv


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--port", type=int, default=8444)
    ap.add_argument("--control-port", type=int, default=8481)
    ap.add_argument("--no-control", action="store_true",
                    help="no control port at all (the review gateway: it is a test affordance)")
    ap.add_argument("--cert")
    ap.add_argument("--key")
    ap.add_argument("--host", default="gw.tail-scale.ts.net", help="the gateway's public host name")
    ap.add_argument("--cookie-port", type=int, default=5476,
                    help="the listen port being emulated (names the cookies when Host has no port)")
    ap.add_argument("--expire-in", type=int, default=0, help="access-session TTL in seconds (0 = real defaults)")
    ap.add_argument("--dist", default=DEFAULT_DIST,
                    help="the pinned wheel (default) or an installed package's static/dist")
    ap.add_argument("--fetch", action="store_true", help="download the pinned wheel (verified) and exit")
    ap.add_argument("--check-bundle", action="store_true", help="run the pin/smoke test and exit")
    ap.add_argument("--print-pins", action="store_true", help="print the bundle's file hashes and exit")
    # F19's review gateway. The token may come from the environment, so a
    # service's command line (and `ps`) does not carry it.
    ap.add_argument("--demo-token", default=os.environ.get("FAKE_GATEWAY_DEMO_TOKEN") or None,
                    help="a reusable sign-in link (fk1.<32+ chars>; or $FAKE_GATEWAY_DEMO_TOKEN)")
    ap.add_argument("--demo-until", help="the demo token's last day, YYYY-MM-DD (UTC), at most %d days out"
                    % DEMO_MAX_DAYS)
    ap.add_argument("--new-demo-token", action="store_true", help="print a fresh demo token and exit")
    ap.add_argument("--content", help="canned sessions and transcripts (testing/review/demo_content.json)")
    a = ap.parse_args()

    if a.new_demo_token:
        print("fk1." + secrets.token_urlsafe(24))
        return
    demo = None
    if a.demo_token or a.demo_until:
        if not (a.demo_token and a.demo_until):
            ap.error("--demo-token and --demo-until go together")
        if not DEMO_TOKEN_RE.fullmatch(a.demo_token):
            ap.error("the demo token must look like fk1.<32 or more of A-Z a-z 0-9 _ -> (--new-demo-token)")
        demo = (a.demo_token, parse_demo_until(a.demo_until))
    content = load_content(a.content) if a.content else None

    if a.fetch:
        print("pinned wheel: %s (KiroCrew %s, sha256 %s)" % (fetch_wheel(), PINNED_VERSION, PINNED_WHEEL_SHA256[:12]))
        return
    if a.print_pins:
        b = Bundle(a.dist)
        print("version:", b.version())
        for rel in PINNED_FILES:
            data = b.read(rel)
            print('    "%s": "%s",' % (rel, hashlib.sha256(data).hexdigest() if data is not None else "MISSING"))
        return
    problems = check_bundle(a.dist)
    if a.check_bundle:
        for p in problems:
            print("FAIL:", p)
        print("bundle check: %s" % ("ok (KiroCrew %s, %d pinned files, from %s)"
                                    % (PINNED_VERSION, len(PINNED_FILES), a.dist) if not problems else "FAILED"))
        sys.exit(1 if problems else 0)
    if problems:
        print("fake_gateway: refusing to start -- the bundle is not the pinned one:", file=sys.stderr)
        for p in problems:
            print("  " + p, file=sys.stderr)
        sys.exit(2)
    if not (a.cert and a.key):
        ap.error("--cert and --key are required")
    inherited = inherited_listeners()
    if inherited:
        a.port = inherited[0].getsockname()[1]   # the origin is where systemd listens

    gw = Gateway(a.expire_in, a.cookie_port, demo, content)
    Page.gw = Control.gw = gw
    Page.bundle = Bundle(a.dist)
    Page.allowed_hosts = {a.host, "127.0.0.1", "localhost", "[::1]"}
    Page.allowed_origins = {"https://%s" % a.host, "https://127.0.0.1:%d" % a.port,
                            "https://localhost:%d" % a.port}
    Control.public_origin = "https://%s" % a.host

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(a.cert, a.key)
    servers = []
    if inherited:
        pages = [server_on(s, Page) for s in inherited]
    else:
        pages = [ThreadingHTTPServer(("127.0.0.1", a.port), Page)]
        try:
            pages.append(V6Server(("::1", a.port), Page))
        except OSError:
            pass
    for s in pages:
        s.socket = wrap_listener(ctx, s.socket)   # handshake per connection (tls_accept)
        servers.append(s)
    if not a.no_control:
        servers.append(ThreadingHTTPServer(("127.0.0.1", a.control_port), Control))
    for s in servers:
        threading.Thread(target=s.serve_forever, daemon=True).start()
    print("fake gateway (KiroCrew %s) https://%s -> %s, control %s, cookies mc_*_%d, expire-in %s"
          % (PINNED_VERSION, a.host,
             ", ".join("%s:%d%s" % (s.server_address[0], s.server_address[1], " (from systemd)" if inherited else "")
                       for s in pages),
             "off" if a.no_control else ":%d" % a.control_port, a.cookie_port, a.expire_in or "default"),
          flush=True)
    if demo:
        print("demo token on, until %s; content %s" % (iso(demo[1]), a.content or "none"), flush=True)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
