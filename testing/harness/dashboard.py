#!/usr/bin/env python3
"""Smallest useful stand-in for the real dashboard: HTTPS static page +
WebSocket echo at /ws + SSE stream at /events.  Stdlib only.
  python3 dashboard.py --port 8443 --cert server.pem --key server.key
"""
import argparse, base64, hashlib, json, ssl, struct, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
PAGE = b"""<!doctype html><meta charset=utf-8><title>fake dashboard</title>
<h1 id=title>FAKE DASHBOARD</h1>
<p id=wsstate>ws:idle</p><p id=sse>sse:idle</p><p id=echo></p>
<script>
const ws = new WebSocket(`wss://${location.host}/ws`);
ws.onopen  = () => { document.getElementById('wsstate').textContent='ws:open'; ws.send('ping'); };
ws.onmessage = e => { document.getElementById('echo').textContent='echo:'+e.data; };
ws.onclose = () => { document.getElementById('wsstate').textContent='ws:closed'; };
const es = new EventSource('/events');
es.onmessage = e => { document.getElementById('sse').textContent='sse:'+e.data; };
</script>"""

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, fmt, *a):
        print("[dash] %s - %s" % (self.client_address[0], fmt % a), flush=True)

    def do_GET(self):
        if self.path == "/ws":            return self.ws()
        if self.path == "/events":        return self.sse()
        if self.path == "/healthz":       return self.body(b'{"ok":true}', "application/json")
        return self.body(PAGE, "text/html; charset=utf-8")

    def body(self, b, ctype):
        self.send_response(200); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def sse(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache"); self.send_header("Connection", "keep-alive")
        self.end_headers()
        try:
            for i in range(1000):
                self.wfile.write(f"data: tick-{i}\n\n".encode()); self.wfile.flush(); time.sleep(0.5)
        except (BrokenPipeError, ConnectionResetError): pass
        self.close_connection = True

    def ws(self):
        k = self.headers.get("Sec-WebSocket-Key")
        if not k: return self.body(b"missing key", "text/plain")
        acc = base64.b64encode(hashlib.sha1(k.encode() + GUID).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket"); self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", acc); self.end_headers()
        self.close_connection = True
        try:
            while True:
                op, payload = self.ws_read()
                if op == 0x8: self.ws_write(0x8, b""); return
                if op == 0x9: self.ws_write(0xA, payload); continue
                if op in (0x1, 0x2): self.ws_write(op, b"echo:" + payload)
        except Exception: return

    def ws_read(self):
        b1, b2 = self.rfile.read(2)
        op, masked, ln = b1 & 0x0F, b2 & 0x80, b2 & 0x7F
        if ln == 126:   ln = struct.unpack("!H", self.rfile.read(2))[0]
        elif ln == 127: ln = struct.unpack("!Q", self.rfile.read(8))[0]
        mask = self.rfile.read(4) if masked else b"\0\0\0\0"
        data = bytearray(self.rfile.read(ln))
        for i in range(ln): data[i] ^= mask[i % 4]
        return op, bytes(data)

    def ws_write(self, op, payload):
        h = bytes([0x80 | op])
        n = len(payload)
        if n < 126:     h += bytes([n])
        elif n < 1 << 16: h += bytes([126]) + struct.pack("!H", n)
        else:           h += bytes([127]) + struct.pack("!Q", n)
        self.wfile.write(h + payload); self.wfile.flush()

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1"); ap.add_argument("--port", type=int, default=8443)
    ap.add_argument("--cert", required=True); ap.add_argument("--key", required=True)
    a = ap.parse_args()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(a.cert, a.key)
    srv = ThreadingHTTPServer((a.host, a.port), H)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    print(f"dashboard https://{a.host}:{a.port}/", flush=True)
    srv.serve_forever()
