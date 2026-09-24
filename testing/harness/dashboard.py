#!/usr/bin/env python3
"""Fake KiroCrew dashboard for the offline test harness (milestone M2).

Stdlib only. Serves HTTPS with the test CA's leaf on BOTH loopback families
(127.0.0.1 and ::1: dash.localtest.me resolves to both, and WebKit may try
either), plus a plain-HTTP control port on 127.0.0.1 for the tests.

Page routes (HTTPS):
  GET  /            the test page: opens a WebSocket and an EventSource, and
                    reports its own state to POST /__report (revision R13)
  GET  /ws          RFC 6455 echo
  GET  /events      SSE ticks
  GET  /healthz     {"ok":true}
  GET  /redirect-away   302 to another origin (R3: a blocked redirect must not
                    paint the error page over a working dashboard)
  GET  /?again      the page again, from its own "Open again" link: a
                    same-origin main-frame navigation a test can cause (R30)
  POST /__report    the page's self-report; stored per Host, stamped with the
                    time it was received (M6: "after the resume" needs a clock
                    the frozen app cannot have run)
  GET  /__inset-cover, /__inset-plain, /__inset-product
                    F9 §6's probes: report their computed env(safe-area-inset-*)
                    and viewport size to POST /__inset-report, with and without
                    viewport-fit=cover, and with the product's full viewport tag

Control routes (plain HTTP, 127.0.0.1:<control-port>):
  GET  /__state     {"reports": {host: latest report}, "requests": {host: n},
                     "paths": [recent "HOST METHOD PATH | USER-AGENT" lines],
                     "ws_open": n, "insets": {probe: latest inset report},
                     "root": "page"|"cover"|"plain"|"product"}
  POST /__reset     clear all of the above (not the modes)
  POST /__mode?front=502|0, ?root=cover|plain|product|page
                    answer the document 5xx on a live connection; or serve an
                    inset probe at / (the app loads only an origin)
  POST /__drop_ws   close every open WebSocket server-side, as a gateway
                    restart does; the page must reconnect by itself (M6.4)
  POST /__ws_push?text=T  send T as a text frame down every open WebSocket;
                    the page shows it as "echo:T" and reports. Two in a row
                    prove a surviving connection still carries traffic, not
                    just one last chunk (M6 review)

The page reconnects its WebSocket the way KiroCrew's does (PLAN M6.4): on
close, after 1 s, doubling, capped at 10 s, reset to 1 s when a connection
opens; each reconnect refetches (KiroCrew has no replay cursor, so anything
missed is recovered by HTTP). The report counts reconnects and refetches, so a
test can tell the page's own reconnect from an app-side reload (a reload is a
new `doc`). A reconnect attempt goes where every other request goes -- through
the app's proxy -- so the anti-leak counts (L1) stay at zero when it fails.

Why a server-side observation channel (R13): the accessibility tree is
unreliable for dynamic web content, and an evaluateJavaScript poll fights
XCUITest's idle detection. The page tells the server; the test asks the server.

Why per-Host request counts (R10): the anti-leak test must prove the
dashboard received ZERO requests for the negative-test origin. Counting by the
Host header distinguishes dash.localtest.me from dash.tail-scale.ts.net on one
listener.

  python3 dashboard.py --port 8443 --control-port 8480 --cert server.pem --key server.key
"""
import argparse
import base64
import hashlib
import json
import re
import socket
import ssl
import struct
import threading
import time
import urllib.parse
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from tls_accept import HandshakeInThread, wrap_listener

GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

STATE_LOCK = threading.Lock()
FRONT_STATUS = 0      # 0 = serve the page; 502/503/504/500 = answer that, live
REPORTS = {}          # host -> latest report dict
REQUESTS = {}         # host -> count of page-side requests
PATHS = deque(maxlen=200)
REPORT_SEQ = 0        # every stored report gets the next number
WS_OPEN = set()       # the handlers of WebSocket connections currently open
INSETS = {}           # probe name ("cover"/"plain") -> latest inset report
ROOT_PROBE = ""       # "" = / serves the page; "cover"/"plain" = that probe


def host_of(handler):
    """The Host header without its port, lowercased."""
    h = (handler.headers.get("Host") or "").strip().lower()
    if h.startswith("["):                       # [::1]:8443
        return h.split("]")[0] + "]"
    return h.rsplit(":", 1)[0] if ":" in h else h


# The viewport is the shipped frontend's, verbatim, and the body insets itself
# by env(safe-area-inset-*) as the frontend's chrome does (F10 §4.2). With the
# old bare `width=device-width` the fake never asked for edge-to-edge, so it
# could never be clipped by the Dynamic Island and L1 could not see F9.
# app/scripts/test-fixture-parity.swift fails when the two drift apart.
PAGE = """<!doctype html><meta charset=utf-8>
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, interactive-widget=resizes-content, viewport-fit=cover" />
<style>
body { margin: 0; padding: calc(8px + env(safe-area-inset-top)) calc(8px + env(safe-area-inset-right))
       calc(8px + env(safe-area-inset-bottom)) calc(8px + env(safe-area-inset-left)); }
</style>
<title>FAKE DASHBOARD</title>
<h1 id=title>FAKE DASHBOARD</h1>
<p id=wsstate>ws:idle</p><p id=sse>sse:idle</p><p id=echo></p>
<p><a id=away href="/redirect-away" style="font-size:22px">Redirect away</a></p>
<p><a id=again href="/?again" style="font-size:22px">Open again</a></p>
<p><button id=signin style="font-size:22px" onclick="signIn()">Sign in with token</button></p>
<script>
// A random id per document, so a test can tell a report from THIS page load
// from a stale one left by the previous page (M2 review: without it the
// sign-in test could pass on the old page's last report).
var DOC = Math.random().toString(36).slice(2);
// The sign-in URL is assembled here rather than written out, so neither the
// token nor 'token=' appears in the page source: a copy of the HTML in some
// WebKit cache must not trip the R1 disk scan as a false positive.
function signIn() {
  location.assign('/?' + 'tok' + 'en=' + ['OFFLINE', 'TEST', 'TOKEN', '7f3a'].join('-'));
}
// The page's own reconnect, as KiroCrew's (PLAN M6.4): on close, wait 1 s,
// doubling, capped at 10 s; reset to 1 s once a connection opens. Every
// reconnect refetches over HTTP, because the protocol has no replay cursor.
// The counters go in the report, so a test can tell this reconnect from an
// app-side reload: a reload starts a new document, and a new DOC.
var WS_OPENS = 0, RECONNECTS = 0, REFETCHES = 0, VISIBLE_FETCHES = 0, DELAY = 1000;
function set(id, text) { document.getElementById(id).textContent = text; }
function report() {
  var s = {
    doc: DOC,
    title: document.getElementById('title').textContent,
    ws: document.getElementById('wsstate').textContent,
    sse: document.getElementById('sse').textContent,
    echo: document.getElementById('echo').textContent,
    search: location.search,
    href_path: location.pathname,
    ws_opens: WS_OPENS,
    reconnects: RECONNECTS,
    refetches: REFETCHES,
    visible_fetches: VISIBLE_FETCHES,
    next_delay_ms: DELAY,
    ts: Date.now()
  };
  fetch('/__report', {method: 'POST', body: JSON.stringify(s),
                      headers: {'Content-Type': 'application/json'}}).catch(function(){});
}
// A fresh HTTP request, never from a cache: what KiroCrew does after a
// reconnect and when the page becomes visible again (PLAN 6.3).
function refetch() {
  return fetch('/healthz', {cache: 'no-store'})
    .then(function (r) { return r.ok; }).catch(function () { return false; });
}
function connect() {
  var ws = new WebSocket('wss://' + location.host + '/ws');
  ws.onopen = function () {
    WS_OPENS += 1;
    DELAY = 1000;
    set('wsstate', 'ws:open');
    ws.send('ping');
    if (WS_OPENS > 1) {
      refetch().then(function (ok) { if (ok) { REFETCHES += 1; } report(); });
    }
    report();
  };
  ws.onmessage = function (e) { set('echo', 'echo:' + e.data); report(); };
  ws.onclose = function () {
    set('wsstate', 'ws:closed');
    report();
    var wait = DELAY;
    DELAY = Math.min(DELAY * 2, 10000);
    setTimeout(function () { RECONNECTS += 1; connect(); }, wait);
  };
}
connect();
var es = new EventSource('/events');
es.onmessage = function (e) { set('sse', 'sse:' + e.data); };
document.addEventListener('visibilitychange', function () {
  if (document.visibilityState !== 'visible') { return; }
  refetch().then(function (ok) { if (ok) { VISIBLE_FETCHES += 1; } report(); });
});
report();
setInterval(report, 1000);
</script>"""


# F9 §6's probe pages: each reports the env(safe-area-inset-*) values WebKit
# computed for it, and its viewport size, to POST /__inset-report, and the
# control port shows the latest per probe under /__state's "insets". Numbers
# the page was told, not pixels off the screen. `cover` asks for edge-to-edge
# as the product does; `plain` does not, which pins the ordinary-page path
# (WebKit insets the viewport itself and reports env() as 0).
INSET_VIEWPORTS = {
    "cover": "width=device-width, viewport-fit=cover",
    "plain": "width=device-width",
    # The product's complete tag, verbatim from the installed index.html: the
    # discriminator between cover alone and interactive-widget=resizes-content.
    "product": "width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, "
               "interactive-widget=resizes-content, viewport-fit=cover",
}
INSET_PROBE = """<!doctype html><meta charset=utf-8>
<meta name=viewport content="%(viewport)s">
<title>INSET PROBE %(probe)s</title>
<style>
body { margin: 0; }
#probe { position: fixed; visibility: hidden; padding-top: env(safe-area-inset-top);
         padding-right: env(safe-area-inset-right); padding-bottom: env(safe-area-inset-bottom);
         padding-left: env(safe-area-inset-left); }
/* KiroCrew 0.7.0's own top-inset rule, verbatim from assets/src-*.css: every
   top-safe / p-safe utility reads var(--safe-area-top, env(...)), and the
   variable is 0 unless the page is an installed PWA. #kc measures what that
   rule resolves to in the app's web view (F9 §9). */
:root { --safe-area-top: 0px; }
@media (display-mode: standalone), (display-mode: fullscreen) {
  :root { --safe-area-top: env(safe-area-inset-top, 0px); } }
#kc { position: fixed; visibility: hidden; padding-top: var(--safe-area-top, env(safe-area-inset-top)); }
</style>
<h1 id=title>INSET PROBE %(probe)s</h1>
<div id=probe></div><div id=kc></div>
<script>
var DOC = Math.random().toString(36).slice(2), SEQ = 0;
function report() {
  var cs = getComputedStyle(document.getElementById('probe'));
  var s = {
    probe: '%(probe)s', doc: DOC, seq: ++SEQ,
    top: cs.paddingTop, right: cs.paddingRight, bottom: cs.paddingBottom, left: cs.paddingLeft,
    innerHeight: window.innerHeight, innerWidth: window.innerWidth,
    clientHeight: document.documentElement.clientHeight,
    visualViewportHeight: window.visualViewport ? window.visualViewport.height : null,
    kcTop: getComputedStyle(document.getElementById('kc')).paddingTop,
    displayMode: ['standalone', 'fullscreen', 'minimal-ui', 'browser'].filter(function (m) {
      return matchMedia('(display-mode: ' + m + ')').matches; }).join(',') || 'none',
    ts: Date.now()
  };
  fetch('/__inset-report', {method: 'POST', body: JSON.stringify(s),
                            headers: {'Content-Type': 'application/json'}}).catch(function(){});
}
window.addEventListener('resize', report);
report();
setInterval(report, 1000);
</script>"""


def inset_probe(probe):
    return INSET_PROBE % {"probe": probe, "viewport": INSET_VIEWPORTS[probe]}


class Page(HandshakeInThread, BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    away_url = "https://dash.localtest.me:8443/away-target"

    def log_message(self, fmt, *a):
        print("[dash] %s %s - %s" % (host_of(self), self.client_address[0], fmt % a), flush=True)

    def count(self):
        with STATE_LOCK:
            h = host_of(self)
            REQUESTS[h] = REQUESTS.get(h, 0) + 1
            # The User-Agent tells the app's WKWebView (no "Safari/" token)
            # from Mobile Safari, which the app hands other origins to (R3):
            # both can reach a loopback name like dash.localtest.me.
            ua = self.headers.get("User-Agent") or "-"
            PATHS.append("%s %s %s | %s" % (h, self.command, self.path, ua))

    def do_GET(self):
        self.count()
        path = self.path.split("?", 1)[0]
        # A 5xx on a LIVE connection, which is a different failure from every
        # other mode here. The others close, reset or blackhole, and all of
        # those raise an NSURLError the app can see. `tailscale serve`'s
        # reverse proxy has no error handler, so a stopped Kiro Crew answers
        # 502 with an empty body on a healthy port 443: TLS completes, no
        # NSURLError exists, and until F4 D10 the app committed that emptiness
        # as the document. Reproducing it needs a server that answers, so it
        # could not be tested with any mode the harness already had.
        if FRONT_STATUS and path in ("/", "/index.html"):
            self.send_response(FRONT_STATUS)
            # Go's httputil.ReverseProxy default error handler sends no body.
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path == "/ws":
            return self.ws()
        if path == "/events":
            return self.sse()
        if path == "/healthz":
            return self.body(b'{"ok":true}', "application/json")
        if path == "/away-target":
            # Where /redirect-away points. Deliberately inert -- no scripts, no
            # reports -- because Safari (which the app hands this origin to)
            # can load it: a live page here could post reports as
            # dash.localtest.me and impersonate the app (M2 review).
            return self.body(b"<!doctype html><title>away</title><p>away target</p>",
                             "text/html; charset=utf-8")
        if path == "/redirect-away":
            self.send_response(302)
            self.send_header("Location", self.away_url)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path in ("/__inset-cover", "/__inset-plain", "/__inset-product"):
            return self.body(inset_probe(path[len("/__inset-"):]).encode(), "text/html; charset=utf-8")
        # The app loads only a gateway's origin (GatewayAddress.persistable
        # drops any path), so a test reaches a probe by switching what / serves
        # from the control port: POST /__mode?root=cover.
        if ROOT_PROBE and path in ("/", "/index.html"):
            return self.body(inset_probe(ROOT_PROBE).encode(), "text/html; charset=utf-8")
        return self.body(PAGE.encode(), "text/html; charset=utf-8")

    def do_POST(self):
        self.count()
        if self.path not in ("/__report", "/__inset-report"):
            return self.body(b"not found", "text/plain", 404)
        n = int(self.headers.get("Content-Length") or 0)
        try:
            data = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return self.body(b"bad json", "text/plain", 400)
        # Stamped with the server's clock: "received after the app resumed"
        # cannot be judged by a timestamp the page took, and a frozen app
        # cannot forge a receive time.
        global REPORT_SEQ
        with STATE_LOCK:
            REPORT_SEQ += 1
            data["received_at"] = time.time()
            data["received_seq"] = REPORT_SEQ
            if self.path == "/__report":
                REPORTS[host_of(self)] = data
            elif data.get("probe") in INSET_VIEWPORTS:
                data["host"] = host_of(self)
                INSETS[data["probe"]] = data
            else:
                return self.body(b"unknown probe", "text/plain", 400)
        return self.body(b'{"ok":true}', "application/json")

    def body(self, b, ctype, status=200):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(b)

    def sse(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        try:
            for i in range(1000):
                self.wfile.write(("data: tick-%d\n\n" % i).encode())
                self.wfile.flush()
                time.sleep(0.5)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass
        self.close_connection = True

    def ws(self):
        k = self.headers.get("Sec-WebSocket-Key")
        if not k:
            return self.body(b"missing key", "text/plain", 400)
        acc = base64.b64encode(hashlib.sha1(k.encode() + GUID).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", acc)
        # Frames are written by this thread (echoes) and by /__ws_push's.
        self.ws_write_lock = threading.Lock()
        # Registered before the 101 goes out, so a client that sees the
        # upgrade can count on /__state's ws_open including it.
        with STATE_LOCK:
            WS_OPEN.add(self)
        self.end_headers()
        self.close_connection = True
        try:
            while True:
                op, payload = self.ws_read()
                if op == 0x8:
                    self.ws_write(0x8, b"")
                    return
                if op == 0x9:
                    self.ws_write(0xA, payload)
                    continue
                if op in (0x1, 0x2):
                    self.ws_write(op, b"echo:" + payload)
        except Exception:
            return
        finally:
            with STATE_LOCK:
                WS_OPEN.discard(self)

    def drop(self):
        """Cut this WebSocket's TCP connection from another thread, as a
        gateway restart does: no close frame, the client sees the FIN."""
        try:
            self.request.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    def push(self, text):
        """Send a text frame from another thread. False if the socket is gone."""
        try:
            self.ws_write(0x1, text.encode())
            return True
        except (OSError, ssl.SSLError):
            return False

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
        with self.ws_write_lock:
            self.wfile.write(h + payload)
            self.wfile.flush()


class Control(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

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
        with STATE_LOCK:
            return self.reply({"reports": REPORTS, "requests": REQUESTS, "paths": list(PATHS),
                               "ws_open": len(WS_OPEN), "front": FRONT_STATUS,
                               "insets": INSETS, "root": ROOT_PROBE or "page"})

    def do_POST(self):
        global FRONT_STATUS, ROOT_PROBE
        if self.path == "/__reset":
            with STATE_LOCK:
                REPORTS.clear()
                REQUESTS.clear()
                PATHS.clear()
                INSETS.clear()
            return self.reply({"ok": True})
        # POST /__mode?front=502 makes the document answer 5xx on a live
        # connection; front=0 restores it. Deliberately only the document, so
        # /__state and /__report keep working while the front is "down" and a
        # test can still read what happened.
        #
        # It belongs HERE, on the plain-HTTP control port, and not on the
        # dashboard itself: a UI test reaches the dashboard only through the
        # app's SOCKS proxy, so a switch served over TLS on :8443 is one the
        # test cannot operate. It was written on the dashboard handler first;
        # every test posted it to the control port, got a 404, and asserted
        # against a perfectly healthy server. The Makefile's `check` now proves
        # the switch works from this port, and the tests' own `post()` now fails
        # on a non-2xx instead of shrugging at one.
        path, _, query = self.path.partition("?")
        if path == "/__mode":
            q = urllib.parse.parse_qs(query)
            # root=cover|plain makes / serve that inset probe (F9 §6); root=page
            # restores the dashboard page. Independent of front=.
            if "root" in q:
                root = q["root"][0]
                if root not in ("page",) + tuple(INSET_VIEWPORTS):
                    return self.reply({"error": "root must be page, cover, plain or product"}, 400)
                ROOT_PROBE = "" if root == "page" else root
                if "front" not in q:
                    return self.reply({"ok": True, "front": FRONT_STATUS, "root": root})
            want = q.get("front", ["0"])[0]
            if not re.fullmatch(r"0|5[0-9][0-9]", want):
                return self.reply({"error": "front must be 0 or a 5xx status"}, 400)
            FRONT_STATUS = int(want)
            return self.reply({"ok": True, "front": FRONT_STATUS, "root": ROOT_PROBE or "page"})
        if self.path == "/__drop_ws":
            with STATE_LOCK:
                open_now = list(WS_OPEN)
            for h in open_now:
                h.drop()
            return self.reply({"ok": True, "dropped": len(open_now)})
        if path == "/__ws_push":
            text = urllib.parse.parse_qs(query).get("text", [""])[0]
            if not re.fullmatch(r"[A-Za-z0-9-]{1,32}", text):
                return self.reply({"error": "text must be 1-32 of [A-Za-z0-9-]"}, 400)
            with STATE_LOCK:
                open_now = list(WS_OPEN)
            pushed = sum(1 for h in open_now if h.push(text))
            return self.reply({"ok": True, "pushed": pushed})
        return self.reply({"error": "not found"}, 404)


class V6Server(ThreadingHTTPServer):
    address_family = socket.AF_INET6


def ws_drop_probe(port, control_port, ca):
    """Self-test (make check): an open WebSocket is counted by /__state, gets
    what POST /__ws_push sends, twice, and is cut by POST /__drop_ws within
    3 s. Exits non-zero otherwise."""
    import os
    import urllib.request
    ctx = ssl.create_default_context(cafile=ca)
    s = ctx.wrap_socket(socket.create_connection(("127.0.0.1", port), timeout=5),
                        server_hostname="dash.localtest.me")
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall(("GET /ws HTTP/1.1\r\nHost: dash.localtest.me\r\nUpgrade: websocket\r\n"
               "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % key).encode())
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = s.recv(1024)
        if not chunk:
            raise SystemExit("ws_drop_probe: no upgrade response")
        head += chunk
    if not head.startswith(b"HTTP/1.1 101"):
        raise SystemExit("ws_drop_probe: upgrade refused: %r" % head[:80])
    ctl = "http://127.0.0.1:%d" % control_port
    state = json.load(urllib.request.urlopen(ctl + "/__state", timeout=5))
    if state.get("ws_open", 0) < 1:
        raise SystemExit("ws_drop_probe: /__state does not count the open socket: %r" % state.get("ws_open"))
    s.settimeout(3)
    for text in ("probe-1", "probe-2"):
        req = urllib.request.Request(ctl + "/__ws_push?text=" + text, method="POST")
        pushed = json.load(urllib.request.urlopen(req, timeout=5)).get("pushed", 0)
        frame = b""
        want = bytes([0x81, len(text)]) + text.encode()
        while len(frame) < len(want):
            try:
                chunk = s.recv(len(want) - len(frame))
            except OSError:  # a timeout too: reported below, not as a traceback
                break
            if not chunk:
                break
            frame += chunk
        if pushed < 1 or frame != want:
            raise SystemExit("ws_drop_probe: /__ws_push %s: pushed %r, got %r" % (text, pushed, frame))
    reply = json.load(urllib.request.urlopen(urllib.request.Request(ctl + "/__drop_ws", method="POST"), timeout=5))
    if reply.get("dropped", 0) < 1:
        raise SystemExit("ws_drop_probe: /__drop_ws dropped nothing: %r" % reply)
    try:
        data = s.recv(16)
    except (ssl.SSLError, OSError):
        data = b""           # a reset is a cut too
    if data:
        raise SystemExit("ws_drop_probe: the socket was not cut; got %r" % data)
    s.close()
    state = json.load(urllib.request.urlopen(ctl + "/__state", timeout=5))
    if state.get("ws_open", 1) != 0:
        raise SystemExit("ws_drop_probe: a dropped socket is still counted: %r" % state.get("ws_open"))


def serve(server):
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    return t


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8443)
    ap.add_argument("--control-port", type=int, default=8480)
    ap.add_argument("--cert", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--away-url", default=Page.away_url,
                    help="where /redirect-away sends the browser (another origin)")
    a = ap.parse_args()
    Page.away_url = a.away_url

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(a.cert, a.key)

    v4 = ThreadingHTTPServer(("127.0.0.1", a.port), Page)
    v4.socket = wrap_listener(ctx, v4.socket)   # handshake per connection (tls_accept)
    servers = [v4]
    try:
        v6 = V6Server(("::1", a.port), Page)
        v6.socket = wrap_listener(ctx, v6.socket)
        servers.append(v6)
    except OSError as e:
        print("dashboard: no IPv6 loopback (%s); IPv4 only" % e, flush=True)
    control = ThreadingHTTPServer(("127.0.0.1", a.control_port), Control)
    servers.append(control)

    for s in servers:
        serve(s)
    print("dashboard https://127.0.0.1:%d/ and https://[::1]:%d/, control http://127.0.0.1:%d/__state"
          % (a.port, a.port, a.control_port), flush=True)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
