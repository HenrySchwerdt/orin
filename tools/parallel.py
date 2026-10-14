#!/usr/bin/env python3
"""Run independent test cases in parallel with deterministic output (docs/testing.md, "Fast local loop and parallel tests").

Library (imported by the Python test tools):
    add_jobs_arg(ap)              adds -j/--jobs N (default: $ORIN_JOBS, else the CPU count)
    ordered_map(fn, items, jobs)  yields fn(item) in the order of items, while up to `jobs` run at once
Every case is a subprocess, so a thread per running case is enough: the threads only wait.

Command line (used by the shell test scripts):
    python3 tools/parallel.py [-j N] [--keep-going] < commands
reads one shell command per line, runs them in parallel with `sh -c` and prints each command's combined
stdout+stderr in input order, as soon as it and every earlier command are done. Without --keep-going it stops
at the first failing command in input order: its output is printed, nothing after it, the commands still running are
killed and the exit status is that command's. The output is then the same as that of the sequential loop
`for c in commands; do sh -c "$c" || exit; done` (stderr is merged into stdout). With -j 1 it is that loop.
A line `first: CMD` is started before the lines without the prefix (a slow case); its output keeps its place.
"""
import argparse
import os
import signal
import subprocess
import sys
import threading
from concurrent.futures import ThreadPoolExecutor


FIRST = "first: "


def default_jobs():
    v = os.environ.get("ORIN_JOBS", "")
    if v.strip():
        try:
            return max(1, int(v))
        except ValueError:
            sys.exit("ORIN_JOBS must be a number, got %r" % v)
    return os.cpu_count() or 4


def add_jobs_arg(ap):
    ap.add_argument("-j", "--jobs", type=int, default=default_jobs(),
                    help="parallel cases (default: $ORIN_JOBS, else the CPU count; 1 = sequential)")


def ordered_map(fn, items, jobs, first=()):
    """fn(item) for every item, yielded in item order; up to `jobs` calls run at the same time.
    `first`: indices of items to start before the others (slow cases); the order of the results is unchanged."""
    items = list(items)
    if jobs <= 1:
        for it in items:
            yield fn(it)
        return
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        early = set(first)
        order = list(first) + [i for i in range(len(items)) if i not in early]
        futs = [None] * len(items)
        for i in order:
            futs[i] = pool.submit(fn, items[i])
        try:
            for f in futs:
                yield f.result()
        finally:
            for f in futs:
                f.cancel()


class _Runner:
    def __init__(self):
        self.stop = threading.Event()
        self.lock = threading.Lock()
        self.procs = set()

    def run(self, cmd):
        if self.stop.is_set():
            return None, b""
        # own process group, so that a stop kills the command's children too
        p = subprocess.Popen(["sh", "-c", cmd], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, start_new_session=True)
        with self.lock:
            self.procs.add(p)
            if self.stop.is_set():  # stopped while starting: kill_all may have missed it
                os.killpg(p.pid, signal.SIGKILL)
        out, _ = p.communicate()
        with self.lock:
            self.procs.discard(p)
        return p.returncode, out

    def kill_all(self):
        self.stop.set()
        with self.lock:
            for p in self.procs:
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except OSError:
                    pass


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    add_jobs_arg(ap)
    ap.add_argument("--keep-going", action="store_true", help="run every command; exit 1 if any failed")
    a = ap.parse_args()
    cmds = [l.rstrip("\n") for l in sys.stdin if l.strip()]
    first = [i for i, c in enumerate(cmds) if c.startswith(FIRST)]
    cmds = [c[len(FIRST):] if c.startswith(FIRST) else c for c in cmds]
    r = _Runner()
    status = 0
    out = sys.stdout.buffer
    results = ordered_map(r.run, cmds, a.jobs, first)
    try:
        for rc, text in results:
            out.write(text)
            out.flush()
            if rc:
                if not a.keep_going:
                    status = rc if rc > 0 else 1
                    break
                status = 1
    finally:
        r.kill_all()      # first kill what still runs, then wait for the pool's threads
        results.close()
    return status


if __name__ == "__main__":
    sys.exit(main())
