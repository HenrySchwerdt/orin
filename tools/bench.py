#!/usr/bin/env python3
"""Orin benchmark driver (stdlib only). See docs/benchmarks.md and spec/11.

Usage: python3 tools/bench.py [--runs N] [--only name,name] [--orinc build/bootstrap/orin2]
                              [--out results.md] [--no-selfcompile] [--json results.json]
                              [--instructions [--instr-langs orin,llvm,c] [--instr-timeout S]]
                              [--threads 1,2,4] [--no-parallel]

--only takes benchmark names; `selfcompile` in the list also runs the self-compile (without --only it always runs).
--json writes the machine-readable result (schema in docs/benchmarks.md, read by tools/bench_report.py and the
benchmark workflow .github/workflows/bench.yml). --instructions adds executed-instruction counts under valgrind (the
regression metric). The parallel section runs bench/parallel_* and bench/streams_parallel with 1, 2 and 4 worker threads.

For every directory bench/<name>/ containing main.or / main.go / main.c it
  * builds Orin (orinc -> C -> cc -O2 with runtime/orin_runtime.c), Orin-LLVM (orinc --backend=llvm
    -> .ll -> clang -O2 with the runtime; skipped without clang), Go (go build) and C (cc -O2),
  * runs each binary once to verify that the stdout (the checksum lines) is identical,
  * runs each binary N times (plus one unrecorded warm-up) and records wall time and peak RSS
    (ru_maxrss of the child, via wait4),
  * runs a second Orin binary, built with -DORIN_STATS_ENABLED, once with ORIN_STATS=1 to collect the runtime counters.
A benchmark may have no Go and / or C counterpart (std:http, std:collections: bench/http_parse, bench/sortedmap); it is
then an Orin-only row (n/a in the other columns, no output cross-check).
It also times "orin2 compiles compiler/main.or" (the self-hosting workload) and prints Markdown.
"""
import argparse
import hashlib
import json
import os
import platform
import shutil
import statistics
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BENCH = os.path.join(ROOT, "bench")
BUILD = os.path.join(ROOT, "build", "bench")
CFLAGS = ["-O2", "-w"]
PROBE = os.path.join(BUILD, "rss_probe")
HAVE_CLANG = shutil.which("clang") is not None
LANGS = ("orin", "llvm", "go", "c") if HAVE_CLANG else ("orin", "go", "c")
HAVE_JAVA = shutil.which("java") is not None and shutil.which("javac") is not None
HAVE_RUST = shutil.which("rustc") is not None
JAVA_FLAGS = ["-XX:+UseParallelGC"]
WARM_REPS = 8   # Java: repetitions inside one JVM (bench/*/Main.java takes N as its argument)


def sh(cmd, **kw):
    r = subprocess.run(cmd, cwd=kw.pop("cwd", ROOT), stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kw)
    if r.returncode != 0:
        sys.exit("command failed: %s\n%s" % (" ".join(cmd), r.stderr.decode("utf-8", "replace")))
    return r


def timed_build(cmds):
    t = time.perf_counter()
    for c in cmds:
        sh(c)
    return time.perf_counter() - t


def run_measure(cmd, env=None):
    """Run cmd; return (wall_seconds, max_rss_kb, returncode, stdout, stderr, user_seconds, sys_seconds).

    CPU times are the rusage of the rss_probe process as returned by wait4: on Linux that includes the
    reaped child (the benchmark) and all its threads; the probe's own share is a few microseconds."""
    e = dict(os.environ)
    e.pop("ORIN_STATS", None)
    if env:
        e.update(env)
    rssfile = os.path.join(BUILD, "rss.txt")
    cmd = [PROBE, rssfile] + cmd
    out_r, out_w = os.pipe()
    err_r, err_w = os.pipe()
    t0 = time.perf_counter()
    p = subprocess.Popen(cmd, cwd=ROOT, stdout=out_w, stderr=err_w, env=e)
    os.close(out_w)
    os.close(err_w)
    # Drain pipes in threads-free fashion: outputs are small (a few lines); read after wait4 could
    # block if a pipe fills (64 KiB), so read first via non-blocking-safe communicate-like loop.
    import selectors
    sel = selectors.DefaultSelector()
    sel.register(out_r, selectors.EVENT_READ, "out")
    sel.register(err_r, selectors.EVENT_READ, "err")
    bufs = {"out": [], "err": []}
    open_fds = 2
    while open_fds:
        for key, _ in sel.select():
            data = os.read(key.fd, 65536)
            if data:
                bufs[key.data].append(data)
            else:
                sel.unregister(key.fd)
                open_fds -= 1
    _, status, ru = os.wait4(p.pid, 0)
    wall = time.perf_counter() - t0
    try:
        maxrss = int(open(rssfile).read())
    except (OSError, ValueError):
        maxrss = 0
    os.close(out_r)
    os.close(err_r)
    p.returncode = os.waitstatus_to_exitcode(status)
    return (wall, maxrss, p.returncode, b"".join(bufs["out"]), b"".join(bufs["err"]), ru.ru_utime, ru.ru_stime)


def run_once(cmd, env=None):
    """Run cmd; return (wall_seconds, max_rss_kb, returncode, stdout, stderr)."""
    return run_measure(cmd, env)[:5]


def measure(cmd, runs, env=None, check=None):
    """One unrecorded warm-up, then `runs` runs. Returns the summary dict stored per language / thread count:
    wall (median, min, max), user / sys / cpu (user + sys) medians in seconds, rss_kb (median)."""
    run_measure(cmd, env)
    walls, users, syss, rss = [], [], [], []
    for _ in range(runs):
        w, m, rc, so, se, u, sy = run_measure(cmd, env)
        if check:
            check(rc, so, se)
        walls.append(w)
        users.append(u)
        syss.append(sy)
        rss.append(m)
    return {"wall": median_range(walls), "user": statistics.median(users), "sys": statistics.median(syss),
            "cpu": statistics.median([u + sy for u, sy in zip(users, syss)]), "rss_kb": statistics.median(rss)}


def sizes(path):
    raw = os.path.getsize(path)
    stripped = None
    if shutil.which("strip"):
        tmp = path + ".stripped"
        r = subprocess.run(["strip", "-o", tmp, path], stderr=subprocess.DEVNULL)
        if r.returncode == 0:
            stripped = os.path.getsize(tmp)
            os.remove(tmp)
    return raw, stripped


def median_range(xs):
    return statistics.median(xs), min(xs), max(xs)


def fmt_s(x):
    return "%.3f" % x if x < 100 else "%.1f" % x


def machine_info():
    cpu = "?"
    try:
        for line in open("/proc/cpuinfo"):
            if line.startswith("model name"):
                cpu = line.split(":", 1)[1].strip()
                break
    except OSError:
        pass
    mem = "?"
    try:
        for line in open("/proc/meminfo"):
            if line.startswith("MemTotal"):
                mem = "%.1f GiB" % (int(line.split()[1]) / 1048576)
                break
    except OSError:
        pass
    ver = lambda c: subprocess.run(c, stdout=subprocess.PIPE, stderr=subprocess.STDOUT).stdout.decode().splitlines()[0]
    return {
        "cpu": cpu,
        "cores": os.cpu_count(),
        "mem": mem,
        "os": platform.platform(),
        "cc": ver(["cc", "--version"]),
        "go": ver(["go", "version"]),
    }


def tool_versions():
    """Versions of every tool that can influence a number (None when the tool is not installed)."""
    def ver(cmd):
        if not shutil.which(cmd[0]):
            return None
        try:
            r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
        except (OSError, subprocess.TimeoutExpired):
            return None
        lines = [l for l in r.stdout.decode("utf-8", "replace").splitlines() if l.strip() and not l.startswith("Picked up ")]
        return lines[0].strip() if lines else None
    return {
        "cc": ver(["cc", "--version"]),
        "clang": ver(["clang", "--version"]),
        "go": ver(["go", "version"]),
        "java": ver(["java", "-version"]),
        "rustc": ver(["rustc", "--version"]),
        "valgrind": ver(["valgrind", "--version"]),
        "python": platform.python_version(),
    }


def git_info():
    """Commit and ref; BENCH_COMMIT / BENCH_REF (set by the workflow) win over the checkout's own view."""
    def g(*a):
        r = subprocess.run(["git"] + list(a), cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return r.stdout.decode().strip() if r.returncode == 0 else None
    return {"commit": os.environ.get("BENCH_COMMIT") or g("rev-parse", "HEAD"),
            "ref": os.environ.get("BENCH_REF") or g("rev-parse", "--abbrev-ref", "HEAD"),
            "dirty": bool(g("status", "--porcelain", "--untracked-files=no"))}


# ------------------------------------------------------------------ instruction counts (--instructions)
#
# Wall time on a shared runner moves by +-25% between identical binaries (docs/benchmarks.md); the number of executed
# instructions of a deterministic single-threaded program does not. `--instructions` runs each Orin binary (C and LLVM
# backend), the C reference and the self-compile once under `valgrind --tool=cachegrind --cache-sim=no` (the cheapest
# valgrind tool that counts instructions; about 20-50x slower than native) and records "I refs".
#
# Per-benchmark convention (files next to main.or):
#   instructions.args   whitespace-separated arguments passed to the program for this run only, so a program that is too
#                       slow under valgrind can run a smaller input; the count is then not comparable with the wall-time
#                       input, and the JSON records the arguments.
#   instructions.skip   do not count; the first line is the reason recorded in the JSON.
# Multi-threaded programs (the parallel benchmarks) are skipped automatically: valgrind serialises threads and the counts
# would include the spinning of whoever waits. A run over --instr-timeout seconds is recorded as skipped.

def bench_file(name, fname):
    p = os.path.join(BENCH, name, fname)
    return open(p).read() if os.path.isfile(p) else None


def count_instructions(cmd, timeout):
    """Return (count, None) or (None, reason)."""
    log = os.path.join(BUILD, "cachegrind.log")
    vg = ["valgrind", "--tool=cachegrind", "--cache-sim=no", "--cachegrind-out-file=/dev/null", "--log-file=" + log] + cmd
    e = dict(os.environ)
    e.pop("ORIN_STATS", None)
    t0 = time.perf_counter()
    try:
        r = subprocess.run(vg, cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=e, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, "timeout: more than %d s under valgrind" % timeout
    if r.returncode != 0:
        return None, "exit status %d under valgrind" % r.returncode
    for line in open(log):
        if "I refs:" in line or "I   refs:" in line:
            n = int(line.split(":", 1)[1].strip().replace(",", ""))
            print("    instructions %-10s %15s  (%.0f s under valgrind)" % (os.path.basename(cmd[0]), "{:,}".format(n),
                                                                          time.perf_counter() - t0), file=sys.stderr)
            return n, None
    return None, "no 'I refs' line in the valgrind log"


# ------------------------------------------------------------------ parallel benchmarks
#
# bench/parallel_<name>/ and bench/streams_parallel/ are parallel benchmarks. Convention: the program takes the number
# of worker threads as its FIRST command-line argument (std:task has no thread pool and no global knob: one task is one
# OS thread, so the worker count is the `parts` of `parallelMap` or the number of tasks the program spawns), and the same
# number is also in the environment as ORIN_BENCH_THREADS for programs that read it there. The output must not depend on
# the count (checked against the 1-thread run). Programs whose worker count is the `parallel()` pool's read ORIN_THREADS,
# which is set too; PAR_ARGV gives the argv of those that pick a workload by their first argument. A parallel directory without main.go / main.c is measured only in the
# parallel section; one with counterparts is also a normal row (run without arguments).

def is_parallel(name):
    return name.startswith("parallel_") or name == "streams_parallel"


# Parallel benchmarks that do not follow the argument convention: their argv in the parallel section. Their worker count is
# the `parallel()` pool's, which reads ORIN_THREADS (set for every parallel run). bench/streams_parallel picks its workload by
# its first argument; `parheavy` is the compute-bound one, where a speedup can show.
PAR_ARGV = {"streams_parallel": ["parheavy"]}


def par_cmd(exe, name, threads):
    return [exe] + PAR_ARGV.get(name, [str(threads)])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--only", default="")
    ap.add_argument("--orinc", default=os.path.join("build", "bootstrap", "orin2"))
    ap.add_argument("--out", default="")
    ap.add_argument("--no-selfcompile", action="store_true")
    ap.add_argument("--json", default="", help="also write the machine-readable results (schema: docs/benchmarks.md)")
    ap.add_argument("--instructions", action="store_true",
                    help="count executed instructions of the Orin binaries, the C reference and the self-compile under valgrind")
    ap.add_argument("--instr-langs", default="orin,llvm,c", help="languages counted by --instructions (default orin,llvm,c)")
    ap.add_argument("--instr-timeout", type=int, default=900, help="seconds per valgrind run before it is skipped")
    ap.add_argument("--threads", default="1,2,4", help="worker counts of the parallel section (default 1,2,4)")
    ap.add_argument("--no-parallel", action="store_true", help="skip the parallel section")
    args = ap.parse_args()
    orinc = os.path.join(ROOT, args.orinc)
    if not os.path.exists(orinc):
        sys.exit("missing %s; run ./tools/bootstrap.sh first" % orinc)
    for tool in ("cc", "go"):
        if not shutil.which(tool):
            sys.exit("missing tool: " + tool)
    if args.instructions and not shutil.which("valgrind"):
        sys.exit("missing tool: valgrind (needed by --instructions)")
    os.makedirs(BUILD, exist_ok=True)
    sh(["cc", "-O2", "tools/rss_probe.c", "-o", PROBE])
    only = [x for x in args.only.split(",") if x]
    all_names = sorted(d for d in os.listdir(BENCH) if os.path.isfile(os.path.join(BENCH, d, "main.or")))
    if only:
        all_names = [n for n in all_names if n in only]
    # parallel-only directories (no Go / C counterpart) are measured in the parallel section, not as a normal row
    names = [n for n in all_names if not is_parallel(n) or
             any(os.path.isfile(os.path.join(BENCH, n, f)) for f in ("main.go", "main.c"))]
    par_names = [] if args.no_parallel else [n for n in all_names if is_parallel(n)]
    threads = [int(x) for x in args.threads.split(",") if x]
    instr_langs = [x for x in args.instr_langs.split(",") if x]
    run_selfcompile = not args.no_selfcompile and (not only or "selfcompile" in only)

    info = machine_info()
    instr = {}    # name -> {lang: {"count": n, "args": [..]} | {"skipped": reason}}
    matched = {}  # name -> {lang: bool}
    results = {}  # name -> {lang: {...}}
    extras = {}   # name -> {"java": .., "rust": ..}
    stats = {}
    mismatches = []
    rt = [os.path.join(ROOT, "runtime", "orin_runtime.c")]
    for name in names:
        src = os.path.join("bench", name)
        out = os.path.join("build", "bench", name)
        os.makedirs(os.path.join(ROOT, out), exist_ok=True)
        builds = {
            "orin": [[orinc, "compile", src + "/main.or", "-o", out + "/orin.c"],
                     ["cc"] + CFLAGS + ["-I", "runtime", out + "/orin.c", "runtime/orin_runtime.c", "platform/orin_platform.c", "-lm", "-o", out + "/orin"]],
            "go": [["go", "build", "-o", out + "/go", src + "/main.go"]],
            "c": [["cc"] + CFLAGS + [src + "/main.c", "-lm", "-o", out + "/c"]],
        }
        if HAVE_CLANG:
            builds["llvm"] = [[orinc, "compile", src + "/main.or", "--backend=llvm", "-o", out + "/orin_llvm.ll"],
                              ["clang"] + CFLAGS + ["-I", "runtime", out + "/orin_llvm.ll", "runtime/orin_runtime.c", "platform/orin_platform.c",
                                                    "runtime/orin_runtime_llvm.c", "-lm", "-o", out + "/llvm"]]
        res = {}
        have = {"orin": True, "llvm": HAVE_CLANG,
                "go": os.path.isfile(os.path.join(ROOT, src, "main.go")), "c": os.path.isfile(os.path.join(ROOT, src, "main.c"))}
        present = [l for l in LANGS if have[l]]
        for lang, cmds in builds.items():
            if not have[lang]:
                continue
            bt = timed_build(cmds)
            res[lang] = {"exe": os.path.join(ROOT, out, lang), "build_s": bt}
        # verify outputs
        ref = None
        matched[name] = {}
        for lang in [l for l in ("c", "go", "orin", "llvm") if l in res]:
            _, _, rc, so, se = run_once([res[lang]["exe"]])
            if rc != 0:
                sys.exit("%s/%s exited %d: %s" % (name, lang, rc, se.decode("utf-8", "replace")))
            matched[name][lang] = True
            if ref is None:
                ref = so
            elif so != ref:
                matched[name][lang] = False
                mismatches.append((name, lang))
                print("CHECKSUM MISMATCH in %s (%s)" % (name, lang), file=sys.stderr)
            res[lang]["output"] = so.decode()
        for lang in present:
            r = res[lang]
            r["raw"], r["stripped"] = sizes(r["exe"])
            r.update(measure([r["exe"]], args.runs))
            print("%-14s %-5s median %ss" % (name, lang, fmt_s(r["wall"][0])), file=sys.stderr)
        if args.instructions:
            instr[name] = {}
            skip = bench_file(name, "instructions.skip")
            iargs = (bench_file(name, "instructions.args") or "").split()
            for lang in instr_langs:
                if lang not in res:
                    continue
                if skip is not None:
                    instr[name][lang] = {"skipped": (skip.strip().splitlines() or ["instructions.skip"])[0]}
                    continue
                n, why = count_instructions([res[lang]["exe"]] + iargs, args.instr_timeout)
                instr[name][lang] = ({"count": n, "args": iargs} if iargs else {"count": n}) if n is not None else {"skipped": why}
        # the counters are a build-time option (-DORIN_STATS_ENABLED); the timed binary is built without them, so the counter run
        # uses a second binary of the same C
        sh(["cc"] + CFLAGS + ["-DORIN_STATS_ENABLED", "-I", "runtime", out + "/orin.c", "runtime/orin_runtime.c", "platform/orin_platform.c",
                              "-lm", "-o", out + "/orin_stats"])
        _, _, _, _, se = run_once([os.path.join(ROOT, out, "orin_stats")], env={"ORIN_STATS": "1"})
        stats[name] = json.loads(se.decode().strip().splitlines()[-1])["orin_stats"]
        results[name] = res
        # Java and Rust counterparts (only where the toolchain is installed and the source exists)
        ex = {}
        ref_out = res["orin"]["output"].encode()
        if HAVE_RUST and os.path.isfile(os.path.join(ROOT, src, "main.rs")):
            timed_build([["rustc", "-O", "-o", out + "/rust", src + "/main.rs"]])
            ex["rust"] = {"exe": os.path.join(ROOT, out, "rust")}
        if HAVE_JAVA and os.path.isfile(os.path.join(ROOT, src, "Main.java")):
            jdir = os.path.join(ROOT, out, "java_classes")
            os.makedirs(jdir, exist_ok=True)
            sh(["javac", "-d", jdir, os.path.join(src, "Main.java")])
            wrapper = os.path.join(ROOT, out, "java")
            with open(wrapper, "w") as f:
                f.write("#!/bin/sh\nexec java %s -cp %s Main \"$@\" 2>/dev/null\n" % (" ".join(JAVA_FLAGS), jdir))
            os.chmod(wrapper, 0o755)
            ex["java"] = {"exe": wrapper}
        for lang, r in ex.items():
            _, _, rc, so, se = run_once([r["exe"]])
            matched[name][lang] = rc == 0 and so == ref_out
            if rc != 0 or so != ref_out:
                mismatches.append((name, lang))
                print("CHECKSUM MISMATCH in %s (%s)" % (name, lang), file=sys.stderr)
                continue
            r.update(measure([r["exe"]], args.runs))
            if lang == "java":
                # warmed-up time: the last repetition of WARM_REPS inside one JVM (stderr of the real java, not the wrapper)
                p = subprocess.run(["java"] + JAVA_FLAGS + ["-cp", os.path.join(ROOT, out, "java_classes"), "Main", str(WARM_REPS)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                reps = [int(l.split()[2]) for l in p.stderr.decode().splitlines() if l.startswith("rep ")]
                r["warm_ms"] = reps
            print("%-14s %-5s median %ss" % (name, lang, fmt_s(r["wall"][0])), file=sys.stderr)
        extras[name] = ex

    # self-hosting workload
    selfc = None
    if run_selfcompile:
        out = os.path.join("build", "bench", "selfcompile")
        os.makedirs(os.path.join(ROOT, out), exist_ok=True)
        # rebuild orin2 from its own C with the *current* runtime (timed build: no counters; a second build with them follows)
        stage = os.path.join(out, "orin2_cur")
        bt = timed_build([[orinc, "compile", "compiler/main.or", "-o", out + "/orin2_cur.c"],
                          ["cc"] + CFLAGS + ["-I", "runtime", out + "/orin2_cur.c", "runtime/orin_runtime.c", "platform/orin_platform.c", "-o", stage]])
        cmd = [os.path.join(ROOT, stage), "compile", "compiler/main.or", "-o", out + "/out.c"]

        def check_self(rc, so, se):
            if rc != 0:
                sys.exit("selfcompile failed: " + se.decode("utf-8", "replace"))
        selfc = measure(cmd, args.runs, check=check_self)
        digest = hashlib.sha256(open(os.path.join(ROOT, out, "out.c"), "rb").read()).hexdigest()
        ref = os.path.join(ROOT, "build", "bootstrap", "stage2.c")
        same = os.path.exists(ref) and hashlib.sha256(open(ref, "rb").read()).hexdigest() == digest
        sh(["cc"] + CFLAGS + ["-DORIN_STATS_ENABLED", "-I", "runtime", out + "/orin2_cur.c", "runtime/orin_runtime.c",
                              "platform/orin_platform.c", "-o", out + "/orin2_stats"])
        _, _, _, _, se = run_once([os.path.join(ROOT, out, "orin2_stats")] + cmd[1:], env={"ORIN_STATS": "1"})
        st = json.loads(se.decode().strip().splitlines()[-1])["orin_stats"]
        selfc.update({"stats": st, "same": same, "size": sizes(os.path.join(ROOT, stage)), "build_s": bt,
                      "csize": os.path.getsize(os.path.join(ROOT, out, "out.c"))})
        print("selfcompile median %ss" % fmt_s(selfc["wall"][0]), file=sys.stderr)
        if args.instructions:
            n, why = count_instructions(cmd, args.instr_timeout)
            selfc["instructions"] = {"count": n} if n is not None else {"skipped": why}

    # parallel section: every parallel benchmark with 1, 2, 4 worker threads (see is_parallel)
    par = {}  # name -> {threads: {...}}
    for name in par_names:
        src = os.path.join("bench", name)
        out = os.path.join("build", "bench", name)
        os.makedirs(os.path.join(ROOT, out), exist_ok=True)
        timed_build([[orinc, "compile", src + "/main.or", "-o", out + "/orin.c"],
                     ["cc"] + CFLAGS + ["-pthread", "-I", "runtime", out + "/orin.c", "runtime/orin_runtime.c",
                                        "platform/orin_platform.c", "-lm", "-o", out + "/orin"]])
        exe = os.path.join(ROOT, out, "orin")
        rows = {}
        ref_out = None
        for t in threads:
            cmd = par_cmd(exe, name, t)
            env = {"ORIN_BENCH_THREADS": str(t), "ORIN_THREADS": str(t)}
            _, _, rc, so, se = run_once(cmd, env=env)
            if rc != 0:
                sys.exit("%s with %d threads exited %d: %s" % (name, t, rc, se.decode("utf-8", "replace")))
            ok = True
            if ref_out is None:
                ref_out = so
            elif so != ref_out:
                ok = False
                mismatches.append((name, "threads=%d" % t))
                print("CHECKSUM MISMATCH in %s (%d threads vs %d)" % (name, t, threads[0]), file=sys.stderr)
            row = measure(cmd, args.runs, env=env)
            row["matched"] = ok
            rows[t] = row
            print("%-14s %d thr median %ss cpu %ss" % (name, t, fmt_s(row["wall"][0]), fmt_s(row["cpu"])), file=sys.stderr)
        base = rows[threads[0]]
        for t, row in rows.items():
            # speedup against the first count (1 by default); efficiency = speedup / (t / first count)
            row["speedup"] = base["wall"][0] / row["wall"][0] if row["wall"][0] > 0 else None
            row["efficiency"] = row["speedup"] / (t / threads[0]) if row["speedup"] else None
            row["cpu_ratio"] = row["cpu"] / base["cpu"] if base["cpu"] > 0 else None
        par[name] = rows
        if args.instructions:
            instr[name] = {"orin": {"skipped": "multi-threaded (parallel benchmark); valgrind serialises threads"}}

    # ------------------------------------------------------------ Markdown
    L = []
    L.append("Machine: %s, %s cores, %s RAM; %s; %s; %s; runs per cell: %d (median, after 1 warm-up)." %
             (info["cpu"], info["cores"], info["mem"], info["os"], info["cc"], info["go"], args.runs))
    L.append("")
    L.append("### Wall time, seconds (median; min-max in parentheses)")
    L.append("")
    L.append("| benchmark | Orin (C backend) | Orin (LLVM backend) | Go | C | Orin-C/Go | Orin-C/C | Orin-LLVM/Go | Orin-LLVM/C |")
    L.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for n in names:
        r = results[n]
        cm = {l: ("%s (%s-%s)" % (fmt_s(r[l]["wall"][0]), fmt_s(r[l]["wall"][1]), fmt_s(r[l]["wall"][2])) if l in r else "n/a") for l in ("orin", "llvm", "go", "c")}

        def ratio(a, b):
            return "%.2fx" % (r[a]["wall"][0] / r[b]["wall"][0]) if a in r and b in r else "n/a"
        L.append("| %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
            n, cm["orin"], cm["llvm"], cm["go"], cm["c"], ratio("orin", "go"), ratio("orin", "c"), ratio("llvm", "go"), ratio("llvm", "c")))
    if selfc:
        w = selfc["wall"]
        L.append("| selfcompile (orin2 compiles compiler/main.or) | %s (%s-%s) | - | - | - | - | - | - | - |" % (fmt_s(w[0]), fmt_s(w[1]), fmt_s(w[2])))
    L.append("")
    L.append("### Peak RSS, MiB (median of ru_maxrss; ~1 MiB process-startup floor)")
    L.append("")
    L.append("| benchmark | " + " | ".join(LANGS) + " |")
    L.append("|---|" + "---:|" * len(LANGS))
    for n in names:
        r = results[n]
        L.append("| %s | %s |" % (n, " | ".join(("%.1f" % (r[l]["rss_kb"] / 1024)) if l in r else "n/a" for l in LANGS) + " "))
    if selfc:
        extra = " |" + " - |" * (len(LANGS) - 1)
        L.append("| selfcompile (orin2) | %.1f%s" % (selfc["rss_kb"] / 1024, extra))
    L.append("")
    L.append("### Binary size, KiB (unstripped / stripped) and build time, seconds (single run)")
    L.append("")
    L.append("| benchmark | " + " | ".join(LANGS) + " | " + " | ".join(l + " build" for l in LANGS) + " |")
    L.append("|---|" + "---:|" * (2 * len(LANGS)))
    def sz(r):
        return "%.0f / %s" % (r["raw"] / 1024, "%.0f" % (r["stripped"] / 1024) if r["stripped"] else "n/a")
    for n in names:
        r = results[n]
        L.append("| %s | %s | %s |" % (n, " | ".join(sz(r[l]) if l in r else "n/a" for l in LANGS), " | ".join(("%.2f" % r[l]["build_s"]) if l in r else "n/a" for l in LANGS)))
    if selfc:
        raw, stripped = selfc["size"]
        L.append("| orin2 compiler binary | %.0f / %s |%s %.2f |%s" % (
            raw / 1024, "%.0f" % (stripped / 1024) if stripped else "n/a", " - |" * (len(LANGS) - 1), selfc["build_s"],
            " - |" * (len(LANGS) - 1)))
    L.append("")
    if any(extras.values()):
        L.append("### Java (OpenJDK, %s) and Rust (rustc -O): same programs, wall time of the whole process in seconds (median; min-max)" % " ".join(JAVA_FLAGS))
        L.append("")
        L.append("| benchmark | Orin (C backend) | Java cold | Java warm (last of %d reps in one JVM, ms) | Rust | Java RSS MiB | Rust RSS MiB | Orin RSS MiB |" % WARM_REPS)
        L.append("|---|---:|---:|---:|---:|---:|---:|---:|")
        for n in names:
            ex = extras.get(n, {})
            if not ex:
                continue
            def cell(l):
                if l not in ex or "wall" not in ex[l]:
                    return "n/a"
                w = ex[l]["wall"]
                return "%s (%s-%s)" % (fmt_s(w[0]), fmt_s(w[1]), fmt_s(w[2]))
            warm = "%d (reps: %s)" % (ex["java"]["warm_ms"][-1], " ".join(str(x) for x in ex["java"]["warm_ms"])) if "java" in ex and ex["java"].get("warm_ms") else "n/a"
            rss = lambda l: ("%.1f" % (ex[l]["rss_kb"] / 1024)) if l in ex and "rss_kb" in ex[l] else "n/a"
            L.append("| %s | %s | %s | %s | %s | %s | %s | %.1f |" % (n, fmt_s(results[n]["orin"]["wall"][0]), cell("java"), warm, cell("rust"),
                                                                    rss("java"), rss("rust"), results[n]["orin"]["rss_kb"] / 1024))
        L.append("")
        if HAVE_JAVA:
            hello = os.path.join(ROOT, "build", "bench", "hello_java")
            os.makedirs(hello, exist_ok=True)
            with open(os.path.join(hello, "Hello.java"), "w") as f:
                f.write("public class Hello { public static void main(String[] a) { System.out.println(\"hi\"); } }\n")
            sh(["javac", "-d", hello, os.path.join(hello, "Hello.java")])
            jw = []
            jr = []
            for _ in range(args.runs + 1):
                w, m, rc, so, se = run_once(["java"] + JAVA_FLAGS + ["-cp", hello, "Hello"])
                jw.append(w)
                jr.append(m)
            cw = []
            for _ in range(args.runs + 1):
                w, m, rc, so, se = run_once([os.path.join(ROOT, "build", "bench", "fib", "c")])
                cw.append(w)
            L.append("Startup: `java Hello` (JVM start, class load, print, exit) %s s median, %.1f MiB peak RSS. The native columns carry a ~1 MiB process-startup floor of RSS "
                     "(see Methodology)." % (fmt_s(statistics.median(jw[1:])), statistics.median(jr[1:]) / 1024))
            L.append("")
    L.append("### Orin runtime counters (ORIN_STATS=1; one run)")
    L.append("")
    cols = ["alloc_total", "alloc_string", "alloc_array", "alloc_struct", "retains", "releases",
            "cow_copies", "cow_inplace", "array_grows", "string_grows", "peak_live_objs", "peak_live_bytes"]
    L.append("| benchmark | " + " | ".join(cols) + " |")
    L.append("|---|" + "---:|" * len(cols))
    for n in names:
        L.append("| %s | %s |" % (n, " | ".join("{:,}".format(stats[n][c]) for c in cols)))
    if selfc:
        L.append("| selfcompile | %s |" % " | ".join("{:,}".format(selfc["stats"][c]) for c in cols))
    L.append("")
    if selfc:
        L.append("selfcompile output C is %s bytes and %s the committed-bootstrap stage2.c." %
                 ("{:,}".format(selfc["csize"]), "identical to" if selfc["same"] else "NOT identical to"))
        L.append("")
    if instr or (selfc and "instructions" in selfc):
        L.append("### Executed instructions (valgrind cachegrind, one run; the regression metric)")
        L.append("")
        L.append("| benchmark | " + " | ".join(instr_langs) + " | " + " | ".join("%s/c" % l for l in instr_langs if l != "c") + " |")
        L.append("|---|" + "---:|" * (2 * len(instr_langs) - (1 if "c" in instr_langs else 0)))

        def icell(d):
            if not d:
                return "n/a"
            if d.get("count") is None:
                return "skipped"
            return "{:,}".format(d["count"]) + (" (args %s)" % " ".join(d["args"]) if d.get("args") else "")
        for n in sorted(instr):
            d = instr[n]
            c = d.get("c", {}).get("count")
            rat = ["%.2fx" % (d[l]["count"] / c) if c and d.get(l, {}).get("count") else "n/a" for l in instr_langs if l != "c"]
            L.append("| %s | %s | %s |" % (n, " | ".join(icell(d.get(l)) for l in instr_langs), " | ".join(rat)))
        if selfc and "instructions" in selfc:
            pad = " - |" * (len(instr_langs) - 1) + " - |" * (len(instr_langs) - (1 if "c" in instr_langs else 0))
            L.append("| selfcompile | %s |%s" % (icell(selfc["instructions"]), pad))
        skipped = [(n, l, d["skipped"]) for n in sorted(instr) for l, d in instr[n].items() if "skipped" in d]
        if skipped:
            L.append("")
            L.append("Skipped: " + "; ".join("%s/%s (%s)" % s for s in skipped) + ".")
        L.append("")
    if par:
        L.append("### Parallel speedup (worker threads = first argument; median wall time; CPU = user + sys)")
        L.append("")
        L.append("| benchmark | threads | wall s (min-max) | CPU s | speedup | efficiency | CPU / CPU(1) | output |")
        L.append("|---|---:|---:|---:|---:|---:|---:|---|")
        for n in sorted(par):
            for t, row in sorted(par[n].items()):
                w = row["wall"]
                L.append("| %s | %d | %s (%s-%s) | %s | %.2fx | %.0f%% | %.2f | %s |" % (
                    n, t, fmt_s(w[0]), fmt_s(w[1]), fmt_s(w[2]), fmt_s(row["cpu"]), row["speedup"] or 0,
                    100 * (row["efficiency"] or 0), row["cpu_ratio"] or 0, "same" if row["matched"] else "DIFFERS"))
        L.append("")
        L.append("Machine has %s cores; with more threads than free cores the speedup flattens while CPU time stays the same or grows "
                 "(oversubscription shows as CPU / CPU(1) > 1)." % info["cores"])
        L.append("")
    L.append("Checksums: %s." % ("all outputs identical across the languages of every benchmark (Orin-only rows have no counterpart)" if not mismatches else
                                  "MISMATCH in " + ", ".join("%s/%s" % m for m in mismatches)))
    text = "\n".join(L) + "\n"
    print(text)
    if args.out:
        with open(os.path.join(ROOT, args.out), "w") as f:
            f.write(text)
    if args.json:
        doc = to_json(args, info, names, results, extras, matched, stats, instr, selfc, par, mismatches, only)
        with open(os.path.join(ROOT, args.json) if not os.path.isabs(args.json) else args.json, "w") as f:
            json.dump(doc, f, indent=1, sort_keys=True)
            f.write("\n")
    sys.exit(1 if mismatches else 0)


JSON_SCHEMA = 1


def to_json(args, info, names, results, extras, matched, stats, instr, selfc, par, mismatches, only):
    """The machine-readable result (--json); documented in docs/benchmarks.md "JSON schema". Times in seconds."""
    def cell(r, ok):
        return {"wall_median": r["wall"][0], "wall_min": r["wall"][1], "wall_max": r["wall"][2],
                "user_median": r["user"], "sys_median": r["sys"], "cpu_median": r["cpu"],
                "rss_kb": r["rss_kb"], "output_matched": ok}
    benches = {}
    for n in names:
        langs = {}
        for l, r in list(results[n].items()) + list(extras.get(n, {}).items()):
            if "wall" in r:
                langs[l] = cell(r, matched.get(n, {}).get(l, True))
                if "build_s" in r:
                    langs[l]["build_s"] = r["build_s"]
                if r.get("warm_ms"):
                    langs[l]["java_warm_ms"] = r["warm_ms"]
            else:
                langs[l] = {"output_matched": matched.get(n, {}).get(l, False)}
        benches[n] = {"langs": langs, "orin_stats": stats.get(n), "instructions": instr.get(n, {})}
    sc = None
    if selfc:
        sc = cell(selfc, selfc["same"])
        sc["identical_to_stage2"] = sc.pop("output_matched")
        sc["instructions"] = selfc.get("instructions", {})
        sc["orin_stats"] = selfc["stats"]
    parallel = {}
    for n, rows in par.items():
        parallel[n] = {"threads": {str(t): dict(cell(r, r["matched"]), speedup=r["speedup"], efficiency=r["efficiency"],
                                                cpu_ratio=r["cpu_ratio"]) for t, r in rows.items()},
                       "instructions": instr.get(n, {})}
    machine = {"cpu": info["cpu"], "cores": info["cores"], "mem": info["mem"], "os": info["os"],
               "runner": os.environ.get("RUNNER_NAME")}
    g = git_info()
    return {"schema": JSON_SCHEMA,
            "date": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "commit": g["commit"], "ref": g["ref"], "dirty": g["dirty"],
            "runs": args.runs, "only": only, "machine": machine, "tools": tool_versions(),
            "benchmarks": benches, "selfcompile": sc, "parallel": parallel,
            "mismatches": ["%s/%s" % m for m in mismatches]}


if __name__ == "__main__":
    main()
