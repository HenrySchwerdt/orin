#!/usr/bin/env python3
"""Exercises a running examples/projects/notes-service. Stdlib only.

Usage: python3 tools/notes_service_client.py PORT CONNECTIONS

Opens exactly CONNECTIONS connections to 127.0.0.1:PORT (the server's connection budget; it exits after serving that many) and
prints one line per check, "ok   NAME" or "FAIL NAME: detail". Exit status 0 only if every check passed.
"""
import http.client
import json
import sys
import threading

port = int(sys.argv[1])
budget = int(sys.argv[2])
used = 0
used_lock = threading.Lock()
bad = 0


def report(name, cond, detail=""):
    global bad
    if not cond:
        bad += 1
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else ": " + detail), flush=True)


def connect():
    global used
    with used_lock:
        used += 1
    return http.client.HTTPConnection("127.0.0.1", port, timeout=15)


def call(method, path, body=None, headers=None):
    """One request on its own connection: (status, content type, body text)."""
    c = connect()
    try:
        h = {"Connection": "close"}
        h.update(headers or {})
        c.request(method, path, body=body, headers=h)
        r = c.getresponse()
        return r.status, r.getheader("Content-Type"), r.read().decode()
    finally:
        c.close()


def post(title, text):
    return call("POST", "/notes", json.dumps({"title": title, "text": text}), {"Content-Type": "application/json"})


s, ct, b = call("GET", "/health")
report("health: 200 and JSON", s == 200 and ct == "application/json" and json.loads(b) == {"status": "ok"}, repr((s, ct, b)))

s, _, b = call("GET", "/notes")
report("list: empty at the start", s == 200 and json.loads(b) == [], repr((s, b)))

s, _, b = post("milk", "2 litres")
report("create: 201 and the note", s == 201 and json.loads(b) == {"id": 1, "title": "milk", "text": "2 litres"}, repr((s, b)))

s, _, b = call("GET", "/notes/1")
report("get: the note by id", s == 200 and json.loads(b) == {"id": 1, "title": "milk", "text": "2 litres"}, repr((s, b)))

s, _, b = post("café \"quoted\"", "line\nbreak ☃")
n = json.loads(b) if s == 201 else {}
report("create: unicode, quotes and newlines survive a round trip", s == 201 and n.get("id") == 2 and n.get("title") == "café \"quoted\"" and n.get("text") == "line\nbreak ☃", repr((s, b)))

s, _, b = call("GET", "/notes/2")
report("get: the unicode note again", s == 200 and json.loads(b) == n, repr((s, b)))

for name, method, path, body, want in (
    ("missing note", "GET", "/notes/99", None, 404),
    ("bad id", "GET", "/notes/abc", None, 400),
    ("unknown path", "GET", "/nope", None, 404),
    ("wrong method on /notes", "DELETE", "/notes", None, 405),
    ("wrong method on /health", "POST", "/health", "{}", 405),
    ("body is not JSON", "POST", "/notes", "{\"title\":", 400),
    ("missing member", "POST", "/notes", "{\"title\":\"x\"}", 400),
    ("unknown member", "POST", "/notes", "{\"title\":\"x\",\"text\":\"y\",\"z\":1}", 400),
    ("wrong member type", "POST", "/notes", "{\"title\":1,\"text\":\"y\"}", 400),
    ("empty title", "POST", "/notes", "{\"title\":\"\",\"text\":\"y\"}", 400),
    ("title too long", "POST", "/notes", json.dumps({"title": "t" * 101, "text": ""}), 400),
):
    s, ct, b = call(method, path, body)
    ok = s == want and ct == "application/json" and "error" in json.loads(b)
    report("errors: " + name + " is " + str(want), ok, repr((s, ct, b)))

s, _, b = call("GET", "/notes")
report("errors left the store alone", s == 200 and [x["id"] for x in json.loads(b)] == [1, 2], repr((s, b)))

# Keep-alive: three requests on ONE connection (it counts once against the budget).
c = connect()
try:
    seen = []
    for path in ("/health", "/notes/1", "/notes"):
        c.request("GET", path)
        r = c.getresponse()
        seen.append((r.status, r.read()))
    report("keep-alive: three requests on one connection", [x[0] for x in seen] == [200, 200, 200], repr(seen))
finally:
    c.close()

# Concurrency: 8 writers x 5 notes each at the same time. Every note gets its own id, none is lost.
WRITERS, EACH = 8, 5
results = []
results_lock = threading.Lock()


def writer(k):
    for i in range(EACH):
        s, _, b = post("w%d-%d" % (k, i), "body")
        with results_lock:
            results.append((s, json.loads(b) if s == 201 else None))


threads = [threading.Thread(target=writer, args=(k,)) for k in range(WRITERS)]
for t in threads:
    t.start()
for t in threads:
    t.join(60)
ids = sorted(r[1]["id"] for r in results if r[0] == 201)
report("concurrent: %d writes all answered 201" % (WRITERS * EACH), len(results) == WRITERS * EACH and len(ids) == WRITERS * EACH, repr(results[:3]))
report("concurrent: ids are unique and consecutive", ids == list(range(3, 3 + WRITERS * EACH)), repr(ids))
s, _, b = call("GET", "/notes")
listed = json.loads(b)
report("concurrent: the list holds every note, in id order", s == 200 and [x["id"] for x in listed] == list(range(1, 3 + WRITERS * EACH)), repr([x["id"] for x in listed]))
titles = {x["title"] for x in listed}
report("concurrent: no write was lost or duplicated", all("w%d-%d" % (k, i) in titles for k in range(WRITERS) for i in range(EACH)), "")

# Use up the rest of the budget so that the server exits by itself.
if used > budget:
    report("budget: client stayed within %d connections" % budget, False, "used %d" % used)
while used < budget:
    call("GET", "/health")
report("budget: exactly %d connections used" % budget, used == budget, "used %d" % used)
sys.exit(1 if bad else 0)
