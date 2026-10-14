#!/usr/bin/env python3
"""Raw-socket checks of examples/http_server.or for tools/test_net.sh (curl cannot send half a request).

  net_checks.py PORT REQUEST_MS     keep-alive, pipelining, malformed requests, slowloris, throughput
Exit status 0 when every check passed; one line per check."""
import socket
import sys
import time

port = int(sys.argv[1])
request_ms = int(sys.argv[2])
failed = 0


def check(name, ok, detail=""):
    global failed
    print(("ok   " if ok else "FAIL ") + name + ((" -- " + detail) if (detail and not ok) else ""))
    if not ok:
        failed += 1


def connect(timeout=5.0):
    s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return s


def read_all(s, limit=1 << 20):
    data = b""
    while len(data) < limit:
        try:
            c = s.recv(65536)
        except (socket.timeout, ConnectionResetError):
            break
        if not c:
            break
        data += c
    return data


_left = {}


def read_response(s):
    """One response with Content-Length: (status, headers dict, body) or None; extra bytes stay buffered per socket."""
    buf = _left.pop(s.fileno(), b"")
    while b"\r\n\r\n" not in buf:
        c = s.recv(65536)
        if not c:
            return None
        buf += c
    head, rest = buf.split(b"\r\n\r\n", 1)
    lines = head.decode("latin-1").split("\r\n")
    status = int(lines[0].split(" ")[1])
    hdr = {}
    for l in lines[1:]:
        k, v = l.split(":", 1)
        hdr[k.strip().lower()] = v.strip()
    n = int(hdr.get("content-length", "0"))
    while len(rest) < n:
        c = s.recv(65536)
        if not c:
            return None
        rest += c
    _left[s.fileno()] = rest[n:]
    return status, hdr, rest[:n]


# keep-alive: several requests on one connection
s = connect()
ok = True
for i in range(5):
    s.sendall(b"GET /health HTTP/1.1\r\nHost: x\r\n\r\n")
    r = read_response(s)
    ok = ok and r is not None and r[0] == 200 and r[2] == b"ok\n"
check("keep-alive: 5 requests on one connection", ok)

# pipelining: two requests in one segment, answered in order
s.sendall(b"GET /health HTTP/1.1\r\nHost: x\r\n\r\nPOST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc")
r1, r2 = read_response(s), read_response(s)
check("pipelined requests answered in order", r1 and r1[0] == 200 and r2 and r2[0] == 200 and r2[2] == b"abc")
s.close()

# Connection: close is honoured and the answer arrives before the close
s = connect()
s.sendall(b"GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
data = read_all(s)
check("Connection: close: answer, then EOF", data.startswith(b"HTTP/1.1 200") and data.endswith(b"ok\n"))
s.close()

# a request split in many tiny segments still works (the deadline is generous enough)
s = connect()
req = b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"
for i in range(len(req)):
    s.sendall(req[i:i + 1])
    time.sleep(0.002)
r = read_response(s)
check("request sent byte by byte", r is not None and r[0] == 200 and r[2] == b"hello")
s.close()

# malformed requests get 400 and a clean close
for name, raw in [
    ("garbage", b"\x00\x01\x02 not http\r\n\r\n"),
    ("bare LF", b"GET /health HTTP/1.1\nHost: x\n\n"),
    ("two Content-Length", b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab"),
    ("smuggling CL+TE", b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"),
]:
    s = connect()
    s.sendall(raw)
    data = read_all(s)
    check("malformed (" + name + ") -> 400 and close", data.startswith(b"HTTP/1.1 400"), repr(data[:40]))
    s.close()

# limits
s = connect()
s.sendall(b"GET /" + b"a" * 3000 + b" HTTP/1.1\r\nHost: x\r\n\r\n")
check("request line over the limit -> 414", read_all(s).startswith(b"HTTP/1.1 414"))
s.close()
s = connect()
s.sendall(b"GET /health HTTP/1.1\r\nHost: x\r\n" + b"".join(b"X-%d: v\r\n" % i for i in range(60)) + b"\r\n")
check("too many headers -> 431", read_all(s).startswith(b"HTTP/1.1 431"))
s.close()
s = connect()
s.sendall(b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 70000\r\n\r\n" + b"z" * 70000)
check("body over the limit -> 413", read_all(s).startswith(b"HTTP/1.1 413"))
s.close()

# 64 KiB echo (the largest body the limits allow) is returned intact
s = connect()
body = bytes((i * 7) % 256 for i in range(65536))
s.sendall(b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 65536\r\nContent-Type: application/x-test\r\n\r\n" + body)
r = read_response(s)
check("64 KiB binary body echoed intact", r is not None and r[0] == 200 and r[2] == body and r[1].get("content-type") == "application/x-test")
s.close()

# slowloris: one byte every REQUEST_MS/4 never completes the head; the server must answer 408 and close by its deadline
s = connect(timeout=15.0)
start = time.time()
sent = 0
closed_at = None
answer = b""
try:
    s.sendall(b"GET /health HTTP/1.1\r\n")
    while time.time() - start < request_ms / 1000.0 * 6:
        time.sleep(request_ms / 4000.0)
        try:
            s.sendall(b"X-Drip: 1\r\n"[sent % 11:sent % 11 + 1])
            sent += 1
        except (BrokenPipeError, ConnectionResetError):
            break
        s.settimeout(0.01)
        try:
            c = s.recv(4096)
            if c:
                answer += c
            else:
                closed_at = time.time() - start
                break
        except socket.timeout:
            pass
        except ConnectionResetError:
            closed_at = time.time() - start
            break
except OSError:
    closed_at = time.time() - start
if closed_at is None:
    s.settimeout(2.0)
    answer += read_all(s)
    closed_at = time.time() - start
check("slowloris: dripping client cut off with 408 by the deadline",
      answer.startswith(b"HTTP/1.1 408") and closed_at < request_ms / 1000.0 * 4, "answer=%r closed_at=%.2fs" % (answer[:30], closed_at))
s.close()

# the server is still alive after all of that, and handles a normal request
s = connect()
s.sendall(b"GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
check("still serving after the abuse", read_all(s).startswith(b"HTTP/1.1 200"))
s.close()

# throughput on loopback, one keep-alive connection, sequential (indicative)
s = connect()
n = 3000
req = b"GET /health HTTP/1.1\r\nHost: x\r\n\r\n"
t0 = time.time()
for i in range(n):
    s.sendall(req)
    r = read_response(s)
    if r is None or r[1].get("connection") == "close":  # the server closes after 100 requests: reconnect
        s.close()
        s = connect()
dt = time.time() - t0
s.close()
print("throughput: %d requests in %.2fs = %.0f req/s (one keep-alive connection, python client)" % (n, dt, n / dt))

sys.exit(1 if failed else 0)
