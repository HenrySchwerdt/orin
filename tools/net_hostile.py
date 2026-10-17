#!/usr/bin/env python3
"""Hostile-peer checks of examples/http_server.or for tools/test_server_campaign.sh (ADR-0017, work package C5).

  net_hostile.py PORT REQUEST_MS SEND_MS WORKERS CHECK...      CHECK is one of: slowloris nonreading abrupt shutdown
The server runs with WORKERS workers, a request deadline of REQUEST_MS and a send deadline of SEND_MS.
  slowloris    2 * WORKERS clients drip a valid request one byte at a time, far slower than the deadline. Each must be cut off (408
               or a close) within REQUEST_MS plus slack of ITS first byte, so the server never waits longer than the deadline however
               slowly a peer writes; a healthy client that arrives meanwhile is answered within one deadline (it queues, it is not dropped)
  nonreading   WORKERS clients pipeline requests with big echoed bodies and never read: the server's sends block on full buffers and must
               give up at SEND_MS (the connection is closed, the worker freed); a healthy client is answered meanwhile (within
               SEND_MS plus slack) and afterwards at once
  abrupt       300 clients that connect and close, or reset, in the middle of a head, a body, or right after the request; the server
               still answers a healthy client afterwards
  shutdown     (needs the server started with admin = 1; ends it) a half-sent request is open, POST /shutdown is answered 200, the held
               request is still answered (408 at its deadline: served to the end, not dropped), a request on a connection opened
               after the shutdown is never served, and the port is refused once the server has exited
Exit status 0 when every check passed; one line per check, with the measured numbers."""
import socket
import struct
import sys
import threading
import time

port = int(sys.argv[1])
request_ms = int(sys.argv[2])
send_ms = int(sys.argv[3])
workers = int(sys.argv[4])
checks = sys.argv[5:]
SLACK = 2.5
failed = 0


def check(name, ok, detail=""):
    global failed
    print(("ok   " if ok else "FAIL ") + name + (" -- " + detail if detail else ""), flush=True)
    if not ok:
        failed += 1


def connect(rcvbuf=None):
    s = socket.socket()
    if rcvbuf:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
    s.settimeout(30)
    s.connect(("127.0.0.1", port))
    return s


def healthy():
    """Seconds until GET /health is answered with 200 ok, or None."""
    t = time.time()
    s = connect()
    s.sendall(b"GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    data = b""
    while True:
        c = s.recv(4096)
        if not c:
            break
        data += c
    s.close()
    return time.time() - t if data.startswith(b"HTTP/1.1 200") and data.endswith(b"ok\n") else None


def slowloris():
    n = workers * 2
    head = b"GET /health HTTP/1.1\r\nHost: x\r\nX-Pad: " + b"a" * 4000 + b"\r\n\r\n"
    res = [None] * n

    def drip(i):
        s = connect()
        t0 = time.time()
        sent = 0
        try:
            while time.time() - t0 < request_ms / 1000.0 + 6 and sent < len(head):
                s.sendall(head[sent:sent + 1])
                sent += 1
                s.settimeout(0.05)
                try:
                    c = s.recv(4096)
                    res[i] = (time.time() - t0, c[:15], sent)
                    return
                except socket.timeout:
                    pass
        except OSError:
            res[i] = (time.time() - t0, b"closed", sent)
            return
        res[i] = (time.time() - t0, b"none", sent)

    ts = [threading.Thread(target=drip, args=(i,)) for i in range(n)]
    for t in ts:
        t.start()
    time.sleep(0.3)
    h = healthy()      # all workers are (or will be) held by droppers: this client queues for a worker
    for t in ts:
        t.join()
    cut = [r for r in res if r and r[1] != b"none"]
    worst = max((r[0] for r in cut), default=0)
    # the deadline counts from the first byte; the queue adds the time a connection waits for a worker (one deadline per batch)
    batches = (n + workers - 1) // workers
    check("slowloris: %d droppers all cut off" % n, len(cut) == n, "%d of %d cut off" % (len(cut), n))
    check("slowloris: each cut off within its deadline (+queue) - slowest %.2f s, deadline %.2f s x %d batches" %
          (worst, request_ms / 1000.0, batches),
          worst <= batches * (request_ms / 1000.0 + SLACK))
    answers = {r[1] for r in cut}
    check("slowloris: answered 408 or closed (%s)" % ",".join(sorted(a.decode("latin1") for a in answers)),
          all(a.startswith(b"HTTP/1.1 408") or a == b"closed" or a == b"" for a in answers))
    check("slowloris: a healthy client is answered meanwhile (%.2f s)" % (h or -1),
          h is not None and h <= batches * (request_ms / 1000.0 + SLACK))
    h2 = healthy()
    check("slowloris: and at once afterwards (%.3f s)" % (h2 or -1), h2 is not None and h2 < 1.0)


def nonreading():
    body = b"x" * 60000
    req = b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n\r\n" % len(body) + body
    socks = []
    t0 = time.time()
    for _ in range(workers):
        s = connect(rcvbuf=4096)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)
        s.settimeout(0.2)
        try:
            for _ in range(90):      # 5.4 MB of echoes owed, nothing read
                s.sendall(req)
        except (socket.timeout, OSError):
            pass
        socks.append(s)
    time.sleep(0.3)
    h = healthy()     # every worker is stuck in a send: this client waits in the queue until a send deadline frees one
    check("nonreading: a healthy client is answered while %d peers hold their sends (%.2f s, send deadline %.2f s)" %
          (workers, h or -1, send_ms / 1000.0), h is not None and h <= send_ms / 1000.0 + SLACK)
    # now the peers: each connection must be closed by the server (EOF or reset) once its send gave up
    closed = 0
    for s in socks:
        s.settimeout(10)
        try:
            deadline = time.time() + 10
            while time.time() < deadline:
                c = s.recv(1 << 16)
                if not c:
                    closed += 1
                    break
        except OSError:
            closed += 1
        s.close()
    check("nonreading: the server closed all %d non-reading connections (%d did, %.1f s after the start)" %
          (workers, closed, time.time() - t0), closed == workers)
    h2 = healthy()
    check("nonreading: and serves at once afterwards (%.3f s)" % (h2 or -1), h2 is not None and h2 < 1.0)


def abrupt():
    for i in range(300):
        s = connect()
        k = i % 4
        try:
            if k == 0:
                s.sendall(b"GET /hea")
            elif k == 1:
                s.sendall(b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 1000\r\n\r\nabc")
            elif k == 2:
                s.sendall(b"GET /health HTTP/1.1\r\nHost: x\r\n\r\n")
            else:
                s.sendall(b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 60000\r\n\r\n" + b"y" * 20000)
            if i % 2:
                s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))   # close sends a reset
        except OSError:
            pass
        s.close()
    h = healthy()
    check("abrupt: 300 clients vanish mid-request (half closed, half reset); the server answers afterwards (%.3f s)" % (h or -1),
          h is not None and h < 3.0)


def shutdown():
    held = connect()
    held.sendall(b"GET /hea")
    time.sleep(0.2)
    s = connect()
    s.sendall(b"POST /shutdown HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    data = b""
    while True:
        c = s.recv(4096)
        if not c:
            break
        data += c
    check("shutdown: POST /shutdown answered 200", data.startswith(b"HTTP/1.1 200") and b"shutting down" in data)
    late = None
    try:
        l = connect()
        l.sendall(b"GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        l.settimeout(1.5)
        late = l.recv(100)
    except (socket.timeout, OSError):
        late = b""
    check("shutdown: a connection opened after the shutdown is not served", not late.startswith(b"HTTP/1.1 200"))
    held.settimeout(request_ms / 1000.0 + SLACK)
    try:
        got = held.recv(100)
    except OSError:
        got = b""
    check("shutdown: the request held open is served to the end (%s)" % got[:24].decode("latin1").strip(), got.startswith(b"HTTP/1.1 408"))
    t = time.time()
    refused = False
    while time.time() - t < 10:
        try:
            socket.create_connection(("127.0.0.1", port), timeout=1).close()
            time.sleep(0.1)
        except ConnectionRefusedError:
            refused = True
            break
        except OSError:
            time.sleep(0.1)
    check("shutdown: the port is refused once the server has exited (%.1f s)" % (time.time() - t), refused)


for c in checks:
    {"shutdown": shutdown, "slowloris": slowloris, "nonreading": nonreading, "abrupt": abrupt}[c]()
sys.exit(1 if failed else 0)
