#!/usr/bin/env python3
"""Minimal SOCKS5 proxy (CONNECT, optional user/pass) for iOS proxy tests.

Stands in for tsnet's loopback SOCKS5 listener in the offline harness (M2).

Test affordances:
  --journal FILE   one JSON line per event, so a test can prove traffic
                   actually traversed the proxy
  --map A:P=B:Q    stand in for MagicDNS: CONNECT to A:P goes to B:Q
  --blackhole      authenticate, then refuse every CONNECT

Control port (plain HTTP on 127.0.0.1, --control-port), so one harness run can
serve every anti-leak variant (revision R10) without restarts:
  GET  /journal            events so far, as a JSON array
  POST /reset              clear the in-memory journal
  POST /mode?blackhole=1   refuse every CONNECT (0 to stop)
  POST /mode?stall=N       hold each CONNECT silent N seconds, then answer
                           general failure -- what tsnet does on dropped SYNs
  POST /close              stop listening: the proxy is GONE, connections are
                           refused at TCP level (the "stub killed" variant)
  POST /open               listen again

  python3 socks5stub.py --port 1080 --user tsnet --password s3cret \\
      --journal /tmp/j.ndjson --control-port 1081
"""
import argparse
import json
import re
import selectors
import socket
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

J_LOCK = threading.Lock()
EVENTS = []
STATE = {"blackhole": False, "listening": True, "stall": 0}
ARGS = None
LISTENER = {"sock": None}


def journal(rec):
    rec.setdefault("ts", time.time())
    with J_LOCK:
        EVENTS.append(rec)
        if ARGS.journal:
            with open(ARGS.journal, "a") as f:
                f.write(json.dumps(rec) + "\n")
                f.flush()


def recvn(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise EOFError
        b += c
    return b


def handle(c):
    try:
        _ver, nm = struct.unpack("!BB", recvn(c, 2))
        methods = set(recvn(c, nm))
        need_auth = bool(ARGS.user)
        if need_auth and 0x02 in methods:
            c.sendall(b"\x05\x02")
        elif not need_auth and 0x00 in methods:
            c.sendall(b"\x05\x00")
        else:
            c.sendall(b"\x05\xff")
            journal({"event": "auth_reject"})
            return
        if need_auth:
            recvn(c, 1)
            u = recvn(c, recvn(c, 1)[0]).decode()
            p = recvn(c, recvn(c, 1)[0]).decode()
            ok = (u == ARGS.user and p == ARGS.password)
            c.sendall(b"\x01\x00" if ok else b"\x01\x01")
            journal({"event": "auth", "user": u, "ok": ok})
            if not ok:
                return
        _v, _cmd, _, atyp = struct.unpack("!BBBB", recvn(c, 4))
        if atyp == 1:
            host = socket.inet_ntoa(recvn(c, 4))
        elif atyp == 3:
            host = recvn(c, recvn(c, 1)[0]).decode()
        else:
            host = socket.inet_ntop(socket.AF_INET6, recvn(c, 16))
        port = struct.unpack("!H", recvn(c, 2))[0]
        journal({"event": "connect", "host": host, "port": port,
                 "blackhole": STATE["blackhole"], "stall": STATE["stall"]})
        host, port = ARGS.hostmap.get("%s:%d" % (host, port), (host, port))
        if STATE["blackhole"]:
            c.sendall(b"\x05\x05\x00\x01" + b"\x00" * 6)   # 0x05 connection refused
            return
        # F4 §6: hold the socket silent, then answer 0x01 general failure --
        # tsnet's exact behaviour when the peer's SYNs are dropped (socks5.go
        # :219-232, replyCodeForDialError), at a duration the test picks. It is
        # the ONLY way to make the connecting state last long enough to assert
        # anything about: every other mode here fails at once, and a state
        # present for 300 ms is caught by luck or missed.
        if STATE["stall"]:
            time.sleep(STATE["stall"])
            c.sendall(b"\x05\x01\x00\x01" + b"\x00" * 6)   # 0x01 general failure
            return
        try:
            up = socket.create_connection((host, port), timeout=10)
        except OSError as e:
            journal({"event": "upstream_fail", "host": host, "port": port, "err": str(e)})
            c.sendall(b"\x05\x05\x00\x01" + b"\x00" * 6)
            return
        c.sendall(b"\x05\x00\x00\x01" + socket.inet_aton("0.0.0.0") + struct.pack("!H", 0))
        pump(c, up)
    except Exception as e:
        journal({"event": "error", "err": repr(e)})
    finally:
        try:
            c.close()
        except Exception:
            pass


def pump(a, b):
    sel = selectors.DefaultSelector()
    sel.register(a, selectors.EVENT_READ)
    sel.register(b, selectors.EVENT_READ)
    try:
        while True:
            for k, _ in sel.select(timeout=60):
                other = b if k.fileobj is a else a
                d = k.fileobj.recv(65536)
                if not d:
                    return
                other.sendall(d)
    finally:
        sel.close()
        b.close()


def listen():
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((ARGS.host, ARGS.port))
    srv.listen(64)
    LISTENER["sock"] = srv
    STATE["listening"] = True

    def accept_loop(s):
        while True:
            try:
                c, _ = s.accept()
            except OSError:
                return        # closed by /close
            threading.Thread(target=handle, args=(c,), daemon=True).start()

    threading.Thread(target=accept_loop, args=(srv,), daemon=True).start()


def close_listener():
    s = LISTENER["sock"]
    LISTENER["sock"] = None
    STATE["listening"] = False
    if s is not None:
        try:
            s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        s.close()


class Control(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        pass

    def reply(self, obj, status=200):
        b = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if urlparse(self.path).path == "/journal":
            with J_LOCK:
                return self.reply(list(EVENTS))
        if urlparse(self.path).path == "/state":
            return self.reply(dict(STATE, instance=ARGS.instance))
        return self.reply({"error": "not found"}, 404)

    def do_POST(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path == "/reset":
            with J_LOCK:
                EVENTS.clear()
            return self.reply({"ok": True})
        if u.path == "/mode":
            if "blackhole" in q:
                STATE["blackhole"] = q["blackhole"][0] == "1"
            if "stall" in q:
                want = q["stall"][0]
                if not re.fullmatch(r"\d{1,2}", want):
                    return self.reply({"error": "stall must be 0-99 seconds"}, 400)
                STATE["stall"] = int(want)
            return self.reply(STATE)
        if u.path == "/close":
            close_listener()
            return self.reply(STATE)
        if u.path == "/open":
            if LISTENER["sock"] is None:
                listen()
            return self.reply(STATE)
        return self.reply({"error": "not found"}, 404)


def main():
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=1080)
    ap.add_argument("--user")
    ap.add_argument("--password")
    ap.add_argument("--journal")
    ap.add_argument("--blackhole", action="store_true",
                    help="accept SOCKS but refuse every CONNECT (negative test)")
    ap.add_argument("--map", action="append", default=[], metavar="NAME:PORT=IP:PORT",
                    help="fake-MagicDNS mapping, repeatable")
    ap.add_argument("--control-port", type=int, default=0)
    ap.add_argument("--instance", default="0",
                    help="which harness instance this is (F14); GET /state reports it")
    ARGS = ap.parse_args()
    ARGS.hostmap = {}
    for m in ARGS.map:
        src, dst = m.split("=")
        ip, pt = dst.rsplit(":", 1)
        ARGS.hostmap[src] = (ip, int(pt))
    STATE["blackhole"] = ARGS.blackhole

    listen()
    print("socks5 listening on %s:%d" % (ARGS.host, ARGS.port), flush=True)
    if ARGS.control_port:
        ctl = ThreadingHTTPServer(("127.0.0.1", ARGS.control_port), Control)
        threading.Thread(target=ctl.serve_forever, daemon=True).start()
        print("socks5 control http://127.0.0.1:%d/journal" % ARGS.control_port, flush=True)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
