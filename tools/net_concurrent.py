#!/usr/bin/env python3
"""Concurrency checks of examples/http_server_concurrent.or for tools/test_net.sh (ADR-0017 Addendum C).

  net_concurrent.py PORT REQUEST_MS WORKERS
The server was started with WORKERS worker tasks and a request deadline of REQUEST_MS.
  1. WORKERS-1 silent / half-sent connections do not stop other clients: a request on a fresh connection is answered at once
  2. the held connections get 408 when the request deadline passes (a slow client costs a worker for the deadline, no more)
  3. with ALL workers held, further clients are not dropped: they wait in the queue and are answered when a worker is free
  4. many clients at once (WORKERS * 4 threads, 5 requests each), every answer is the one for its own request
Exit status 0 when every check passed; one line per check."""
import socket
import sys
import threading
import time

port = int(sys.argv[1])
request_ms = int(sys.argv[2])
workers = int(sys.argv[3])
failed = 0
lock = threading.Lock()


def check(name, ok, detail=""):
    global failed
    print(("ok   " if ok else "FAIL ") + name + ((" -- " + detail) if (detail and not ok) else ""))
    if not ok:
        failed += 1


def connect(timeout=10.0):
    s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return s


def read_response(s):
    data = b""
    while b"\r\n\r\n" not in data:
        c = s.recv(65536)
        if not c:
            return data
        data += c
    head, _, rest = data.partition(b"\r\n\r\n")
    n = 0
    for line in head.split(b"\r\n")[1:]:
        k, _, v = line.partition(b":")
        if k.strip().lower() == b"content-length":
            n = int(v)
    while len(rest) < n:
        c = s.recv(65536)
        if not c:
            break
        rest += c
    return head + b"\r\n\r\n" + rest


def request(path, body=None, close=True):
    s = connect()
    try:
        if body is None:
            msg = b"GET " + path + b" HTTP/1.1\r\nHost: x\r\n" + (b"Connection: close\r\n" if close else b"") + b"\r\n"
        else:
            msg = (b"POST " + path + b" HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Length: " + str(len(body)).encode()
                   + b"\r\n\r\n" + body)
        s.sendall(msg)
        return read_response(s)
    finally:
        s.close()


# 1. hold WORKERS-1 workers with a half request each
held = []
for i in range(workers - 1):
    s = connect()
    s.sendall(b"GET /hea")
    held.append(s)
time.sleep(0.3)
t0 = time.time()
ok = True
for i in range(5):
    r = request(b"/health")
    ok = ok and r.startswith(b"HTTP/1.1 200") and r.endswith(b"ok\n")
check("a free worker answers while %d connections are held" % (workers - 1), ok)
check("... without waiting for the held connections", time.time() - t0 < request_ms / 1000.0)

# 2. the held connections time out with 408
time.sleep(request_ms / 1000.0 + 0.5)
got = 0
for s in held:
    s.settimeout(5.0)
    try:
        r = read_response(s)
        if r.startswith(b"HTTP/1.1 408"):
            got += 1
    except OSError:
        pass
    s.close()
check("held connections get 408 at the request deadline", got == len(held), "%d of %d" % (got, len(held)))

# 3. hold ALL workers, queue more clients: they are answered after the deadline
held = []
for i in range(workers):
    s = connect()
    s.sendall(b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nab")
    held.append(s)
time.sleep(0.3)
results = {}


def queued(i):
    try:
        r = request(b"/echo", b"queued %d" % i)
        results[i] = r.endswith(b"queued %d" % i) and r.startswith(b"HTTP/1.1 200")
    except OSError as e:
        results[i] = False


threads = [threading.Thread(target=queued, args=(i,)) for i in range(6)]
for t in threads:
    t.start()
time.sleep(0.2)
check("clients behind a full pool have no answer yet", len(results) == 0)
for t in threads:
    t.join(30)
check("... and all 6 are answered once workers free up (none dropped)", len(results) == 6 and all(results.values()), str(results))
for s in held:
    s.close()

# 4. many clients at once
errors = []


def hammer(i):
    try:
        for j in range(5):
            body = b"c%d r%d " % (i, j) + b"x" * (200 + i)
            r = request(b"/echo", body)
            if not (r.startswith(b"HTTP/1.1 200") and r.endswith(body)):
                with lock:
                    errors.append((i, j))
    except OSError as e:
        with lock:
            errors.append((i, str(e)))


threads = [threading.Thread(target=hammer, args=(i,)) for i in range(workers * 4)]
t0 = time.time()
for t in threads:
    t.start()
for t in threads:
    t.join(60)
check("%d clients x 5 requests, each answer matches its request" % (workers * 4), not errors, str(errors[:3]))
print("     %.2f s" % (time.time() - t0))
sys.exit(1 if failed else 0)
