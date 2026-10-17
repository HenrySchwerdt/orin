#!/usr/bin/env python3
"""Builds, tests and runs the example projects under examples/projects/. Stdlib only.

Usage: python3 tools/test_example_projects.py [--orinc build/bootstrap/orin2] [--cc cc]

For each project (a package with an orin.toml):
* builds it (`orin compile DIR`, then the C compiler and the runtime) and runs its unit tests (`orin test` on every
  tests/*_test.or; the exit status must be 0);
* wc: for every testdata/NAME.in runs the program with the arguments of NAME.args (split on blanks) and the input on
  stdin, and compares stdout with NAME.out and the exit status with NAME.exit (default 0);
* notes-service: starts it on port 0 with a connection budget, waits for "listening on 127.0.0.1:PORT" on stderr, runs
  tools/notes_service_client.py against it (statuses, bodies, 16 concurrent writers) and checks that the server exits
  by itself with status 0 once the budget is used. A timeout or any failure kills the server.
"""
import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from runtime_files import rt_inc, rt_src  # the runtime source list: tools/runtime-sources.txt

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECTS = os.path.join("examples", "projects")
CONNECTIONS = 64            # the notes-service connection budget; the client uses exactly this many
failures = []
passed = 0


def run(args, timeout=300, stdin=b""):
    r = subprocess.run(args, cwd=ROOT, input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    return r.returncode, r.stdout, r.stderr


def text(b):
    return b.decode("utf-8", "replace")


def check(name, cond, detail=""):
    global passed
    if cond:
        passed += 1
        print("ok   " + name)
    else:
        failures.append(name)
        print("FAIL " + name + ("\n     " + detail.replace("\n", "\n     ") if detail else ""))


def build(orin, cc, project, out):
    """Compiles examples/projects/NAME to out/NAME; returns the executable path or None."""
    src = os.path.join(PROJECTS, project)
    c_file = os.path.join(out, project + ".c")
    rc, so, se = run([orin, "compile", src, "-o", c_file])
    if rc != 0:
        check(project + ": compiles", False, text(se))
        return None
    exe = os.path.join(out, project)
    rc, so, se = run([cc, "-O1", "-w", *rt_inc(), c_file, *rt_src(), "-lm", "-pthread", "-o", exe])
    check(project + ": builds", rc == 0, text(se))
    return exe if rc == 0 else None


def unit_tests(orin, project):
    tests = sorted(glob.glob(os.path.join(ROOT, PROJECTS, project, "tests", "*_test.or")))
    check(project + ": has unit tests", len(tests) > 0)
    for t in tests:
        rel = os.path.relpath(t, ROOT)
        rc, so, se = run([orin, "test", rel])
        last = text(so).strip().splitlines()[-1:] or [""]
        check(project + ": " + os.path.basename(t) + " (" + last[0] + ")", rc == 0 and " 0 failed" in last[0], text(so) + text(se))


def read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def wc_cases(exe):
    data = os.path.join(ROOT, PROJECTS, "wc", "testdata")
    cases = sorted(glob.glob(os.path.join(data, "*.in")))
    check("wc: has test data", len(cases) >= 10)
    for inp in cases:
        base = inp[:-3]
        name = os.path.basename(base)
        argv = read_bytes(base + ".args").decode().split() if os.path.exists(base + ".args") else []
        want_rc = int(read_bytes(base + ".exit").decode()) if os.path.exists(base + ".exit") else 0
        rc, so, se = run([exe] + argv, stdin=read_bytes(inp), timeout=30)
        want = read_bytes(base + ".out")
        check("wc: " + name, rc == want_rc and so == want,
              "exit %d (want %d)\nstdout %r\nwant   %r\nstderr %r" % (rc, want_rc, so, want, se))
    # a few properties that are better computed than stored
    big = b"word " * 200000 + b"\n"
    rc, so, se = run([exe], stdin=big, timeout=60)
    check("wc: one megabyte on stdin", rc == 0 and so.split() == [b"1", b"200000", b"1000001"], text(so) + text(se))


def notes_service(exe, out):
    log_path = os.path.join(out, "notes-service.stderr")
    log = open(log_path, "wb")
    proc = subprocess.Popen([exe, "0", str(CONNECTIONS)], cwd=ROOT, stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=log)
    try:
        port = None
        deadline = time.time() + 20
        while time.time() < deadline and proc.poll() is None:
            m = re.search(r"listening on 127\.0\.0\.1:(\d+)", text(read_bytes(log_path)))
            if m:
                port = int(m.group(1))
                break
            time.sleep(0.05)
        check("notes-service: listens on a free loopback port", port is not None, text(read_bytes(log_path)))
        if port is None:
            return
        rc, so, se = run([sys.executable, "-I", os.path.join("tools", "notes_service_client.py"), str(port), str(CONNECTIONS)], timeout=120)
        for line in text(so).splitlines():
            if line.startswith("ok   ") or line.startswith("FAIL "):
                name, _, detail = line[5:].partition(": ")
                check(name, line.startswith("ok"), detail)
        check("notes-service: client finished", rc == 0, text(so) + text(se))
        try:
            code = proc.wait(timeout=30)
            check("notes-service: exits by itself after its connection budget", code == 0, "exit status %s" % code)
        except subprocess.TimeoutExpired:
            check("notes-service: exits by itself after its connection budget", False, "still running after 30 s")
        log.flush()
        err = text(read_bytes(log_path))
        check("notes-service: served every connection", "accepted %d, served %d" % (CONNECTIONS, CONNECTIONS) in err, err)
    finally:
        if proc.poll() is None:
            proc.kill()
        proc.wait()
        log.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--orinc", default=os.path.join("build", "bootstrap", "orin2"))
    ap.add_argument("--cc", default=os.environ.get("CC", "cc"))
    a = ap.parse_args()
    orin = a.orinc if os.path.isabs(a.orinc) else os.path.join(ROOT, a.orinc)
    if not os.access(orin, os.X_OK):
        print("test_example_projects: compiler %s not found (run tools/bootstrap.sh)" % orin, file=sys.stderr)
        sys.exit(2)
    out = os.path.join(ROOT, "build", "example_projects")
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)

    for project in ("wc", "notes-service"):
        exe = build(orin, a.cc, project, out)
        unit_tests(orin, project)
        if exe is None:
            continue
        if project == "wc":
            wc_cases(exe)
        else:
            notes_service(exe, out)

    print("\n%d passed, %d failed" % (passed, len(failures)))
    if failures:
        print("failed: " + ", ".join(failures))
        sys.exit(1)


if __name__ == "__main__":
    main()
