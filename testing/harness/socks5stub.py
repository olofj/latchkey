#!/usr/bin/env python3
"""Minimal SOCKS5 proxy (CONNECT only, optional user/pass) for iOS proxy tests.
Writes one JSON line per proxied connection to the --journal file so a test can
assert traffic actually traversed the proxy.  Usage:
  python3 socks5stub.py --port 1080 --user tsnet --password secret --journal /tmp/j.ndjson
"""
import argparse, json, selectors, socket, struct, threading, time

J_LOCK = threading.Lock()

def journal(path, rec):
    if not path: return
    with J_LOCK, open(path, "a") as f:
        f.write(json.dumps(rec) + "\n"); f.flush()

def recvn(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c: raise EOFError
        b += c
    return b

def handle(c, args):
    try:
        ver, nm = struct.unpack("!BB", recvn(c, 2))
        methods = set(recvn(c, nm))
        need_auth = bool(args.user)
        if need_auth and 0x02 in methods:   c.sendall(b"\x05\x02")
        elif not need_auth and 0x00 in methods: c.sendall(b"\x05\x00")
        else:
            c.sendall(b"\x05\xff"); journal(args.journal, {"event":"auth_reject"}); return
        if need_auth:
            recvn(c, 1)
            u = recvn(c, recvn(c, 1)[0]).decode()
            p = recvn(c, recvn(c, 1)[0]).decode()
            ok = (u == args.user and p == args.password)
            c.sendall(b"\x01\x00" if ok else b"\x01\x01")
            journal(args.journal, {"event":"auth", "user":u, "ok":ok})
            if not ok: return
        v, cmd, _, atyp = struct.unpack("!BBBB", recvn(c, 4))
        if atyp == 1:   host = socket.inet_ntoa(recvn(c, 4))
        elif atyp == 3: host = recvn(c, recvn(c, 1)[0]).decode()
        else:           host = socket.inet_ntop(socket.AF_INET6, recvn(c, 16))
        port = struct.unpack("!H", recvn(c, 2))[0]
        journal(args.journal, {"event":"connect","host":host,"port":port,"ts":time.time()})
        # Stand in for MagicDNS: map fake tailnet names onto real local listeners.
        host, port = args.hostmap.get(f"{host}:{port}", (host, port))
        if args.blackhole:
            c.sendall(b"\x05\x05\x00\x01" + b"\x00"*6); return   # 0x05 = connection refused
        try:
            up = socket.create_connection((host, port), timeout=10)
        except OSError:
            c.sendall(b"\x05\x05\x00\x01" + b"\x00"*6); return
        c.sendall(b"\x05\x00\x00\x01" + socket.inet_aton("0.0.0.0") + struct.pack("!H", 0))
        pump(c, up)
    except Exception as e:
        journal(args.journal, {"event":"error","err":repr(e)})
    finally:
        try: c.close()
        except Exception: pass

def pump(a, b):
    sel = selectors.DefaultSelector()
    sel.register(a, selectors.EVENT_READ); sel.register(b, selectors.EVENT_READ)
    try:
        while True:
            for k, _ in sel.select(timeout=60):
                other = b if k.fileobj is a else a
                d = k.fileobj.recv(65536)
                if not d: return
                other.sendall(d)
    finally:
        sel.close(); b.close()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1"); ap.add_argument("--port", type=int, default=1080)
    ap.add_argument("--user"); ap.add_argument("--password")
    ap.add_argument("--journal"); ap.add_argument("--blackhole", action="store_true",
                    help="accept SOCKS but refuse every CONNECT (negative test)")
    ap.add_argument("--map", action="append", default=[], metavar="NAME:PORT=IP:PORT",
                    help="fake-MagicDNS mapping, repeatable")
    args = ap.parse_args()
    args.hostmap = {}
    for m in args.map:
        src, dst = m.split("="); ip, pt = dst.rsplit(":", 1)
        args.hostmap[src] = (ip, int(pt))
    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((args.host, args.port)); srv.listen(64)
    print(f"socks5 listening on {srv.getsockname()[0]}:{srv.getsockname()[1]}", flush=True)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=handle, args=(c, args), daemon=True).start()

if __name__ == "__main__": main()
