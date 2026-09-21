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
  POST /__report    the page's self-report; stored per Host

Control routes (plain HTTP, 127.0.0.1:<control-port>):
  GET  /__state     {"reports": {host: latest report}, "requests": {host: n},
                     "paths": [recent "HOST METHOD PATH | USER-AGENT" lines]}
  POST /__reset     clear all of the above

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
import socket
import ssl
import struct
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

STATE_LOCK = threading.Lock()
REPORTS = {}          # host -> latest report dict
REQUESTS = {}         # host -> count of page-side requests
PATHS = deque(maxlen=200)


def host_of(handler):
    """The Host header without its port, lowercased."""
    h = (handler.headers.get("Host") or "").strip().lower()
    if h.startswith("["):                       # [::1]:8443
        return h.split("]")[0] + "]"
    return h.rsplit(":", 1)[0] if ":" in h else h


PAGE = """<!doctype html><meta charset=utf-8>
<meta name=viewport content="width=device-width">
<title>FAKE DASHBOARD</title>
<h1 id=title>FAKE DASHBOARD</h1>
<p id=wsstate>ws:idle</p><p id=sse>sse:idle</p><p id=echo></p>
<p><a id=away href="/redirect-away" style="font-size:22px">Redirect away</a></p>
<p><button id=signin style="font-size:22px"
   onclick="location.assign('/?token=OFFLINE-TEST-TOKEN-7f3a')">Sign in with token</button></p>
<script>
function report() {
  var s = {
    title: document.getElementById('title').textContent,
    ws: document.getElementById('wsstate').textContent,
    sse: document.getElementById('sse').textContent,
    echo: document.getElementById('echo').textContent,
    search: location.search,
    href_path: location.pathname,
    ts: Date.now()
  };
  fetch('/__report', {method: 'POST', body: JSON.stringify(s),
                      headers: {'Content-Type': 'application/json'}}).catch(function(){});
}
var ws = new WebSocket('wss://' + location.host + '/ws');
ws.onopen = function () { document.getElementById('wsstate').textContent = 'ws:open'; ws.send('ping'); report(); };
ws.onmessage = function (e) { document.getElementById('echo').textContent = 'echo:' + e.data; report(); };
ws.onclose = function () { document.getElementById('wsstate').textContent = 'ws:closed'; report(); };
var es = new EventSource('/events');
es.onmessage = function (e) { document.getElementById('sse').textContent = 'sse:' + e.data; };
report();
setInterval(report, 1000);
</script>"""


class Page(BaseHTTPRequestHandler):
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
        if path == "/ws":
            return self.ws()
        if path == "/events":
            return self.sse()
        if path == "/healthz":
            return self.body(b'{"ok":true}', "application/json")
        if path == "/redirect-away":
            self.send_response(302)
            self.send_header("Location", self.away_url)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        return self.body(PAGE.encode(), "text/html; charset=utf-8")

    def do_POST(self):
        self.count()
        if self.path != "/__report":
            return self.body(b"not found", "text/plain", 404)
        n = int(self.headers.get("Content-Length") or 0)
        try:
            data = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return self.body(b"bad json", "text/plain", 400)
        with STATE_LOCK:
            REPORTS[host_of(self)] = data
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
            return self.reply({"reports": REPORTS, "requests": REQUESTS, "paths": list(PATHS)})

    def do_POST(self):
        if self.path != "/__reset":
            return self.reply({"error": "not found"}, 404)
        with STATE_LOCK:
            REPORTS.clear()
            REQUESTS.clear()
            PATHS.clear()
        return self.reply({"ok": True})


class V6Server(ThreadingHTTPServer):
    address_family = socket.AF_INET6


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
    v4.socket = ctx.wrap_socket(v4.socket, server_side=True)
    servers = [v4]
    try:
        v6 = V6Server(("::1", a.port), Page)
        v6.socket = ctx.wrap_socket(v6.socket, server_side=True)
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
