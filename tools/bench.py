#!/usr/bin/env python3
"""Orin benchmark driver (stdlib only). See docs/benchmarks.md and spec/11.

Usage: python3 tools/bench.py [--runs N] [--only name,name] [--orinc build/bootstrap/orin2]
                              [--out results.md] [--no-selfcompile]

For every directory bench/<name>/ containing main.or / main.go / main.c it
  * builds Orin (orinc -> C -> cc -O2 with runtime/orin_runtime.c), Go (go build) and C (cc -O2),
  * runs each binary once to verify that the stdout (the checksum lines) is identical,
  * runs each binary N times (plus one unrecorded warm-up) and records wall time and peak RSS
    (ru_maxrss of the child, via wait4),
  * runs the Orin binary once more with ORIN_STATS=1 to collect the runtime counters.
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


def run_once(cmd, env=None):
    """Run cmd; return (wall_seconds, max_rss_kb, returncode, stdout, stderr)."""
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
    _, status, _ru = os.wait4(p.pid, 0)
    wall = time.perf_counter() - t0
    try:
        maxrss = int(open(rssfile).read())
    except (OSError, ValueError):
        maxrss = 0
    os.close(out_r)
    os.close(err_r)
    p.returncode = os.waitstatus_to_exitcode(status)
    return (wall, maxrss, p.returncode, b"".join(bufs["out"]), b"".join(bufs["err"]))


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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--only", default="")
    ap.add_argument("--orinc", default=os.path.join("build", "bootstrap", "orin2"))
    ap.add_argument("--out", default="")
    ap.add_argument("--no-selfcompile", action="store_true")
    args = ap.parse_args()
    orinc = os.path.join(ROOT, args.orinc)
    if not os.path.exists(orinc):
        sys.exit("missing %s; run ./tools/bootstrap.sh first" % orinc)
    for tool in ("cc", "go"):
        if not shutil.which(tool):
            sys.exit("missing tool: " + tool)
    os.makedirs(BUILD, exist_ok=True)
    sh(["cc", "-O2", "tools/rss_probe.c", "-o", PROBE])
    only = [x for x in args.only.split(",") if x]
    names = sorted(d for d in os.listdir(BENCH) if os.path.isfile(os.path.join(BENCH, d, "main.or")))
    if only:
        names = [n for n in names if n in only]

    info = machine_info()
    results = {}  # name -> {lang: {...}}
    stats = {}
    mismatches = []
    rt = [os.path.join(ROOT, "runtime", "orin_runtime.c")]
    for name in names:
        src = os.path.join("bench", name)
        out = os.path.join("build", "bench", name)
        os.makedirs(os.path.join(ROOT, out), exist_ok=True)
        builds = {
            "orin": [[orinc, "compile", src + "/main.or", "-o", out + "/orin.c"],
                     ["cc"] + CFLAGS + ["-I", "runtime", out + "/orin.c", "runtime/orin_runtime.c", "-o", out + "/orin"]],
            "go": [["go", "build", "-o", out + "/go", src + "/main.go"]],
            "c": [["cc"] + CFLAGS + [src + "/main.c", "-o", out + "/c"]],
        }
        res = {}
        for lang, cmds in builds.items():
            bt = timed_build(cmds)
            res[lang] = {"exe": os.path.join(ROOT, out, lang), "build_s": bt}
        # verify outputs
        ref = None
        for lang in ("c", "go", "orin"):
            _, _, rc, so, se = run_once([res[lang]["exe"]])
            if rc != 0:
                sys.exit("%s/%s exited %d: %s" % (name, lang, rc, se.decode("utf-8", "replace")))
            if ref is None:
                ref = so
            elif so != ref:
                mismatches.append((name, lang))
                print("CHECKSUM MISMATCH in %s (%s)" % (name, lang), file=sys.stderr)
            res[lang]["output"] = so.decode()
        for lang in ("orin", "go", "c"):
            r = res[lang]
            r["raw"], r["stripped"] = sizes(r["exe"])
            run_once([r["exe"]])  # warm-up
            walls, rss = [], []
            for _ in range(args.runs):
                w, m, rc, so, se = run_once([r["exe"]])
                walls.append(w)
                rss.append(m)
            r["wall"] = median_range(walls)
            r["rss_kb"] = statistics.median(rss)
            print("%-14s %-5s median %ss" % (name, lang, fmt_s(r["wall"][0])), file=sys.stderr)
        _, _, _, _, se = run_once([res["orin"]["exe"]], env={"ORIN_STATS": "1"})
        stats[name] = json.loads(se.decode().strip().splitlines()[-1])["orin_stats"]
        results[name] = res

    # self-hosting workload
    selfc = None
    if not args.no_selfcompile and not only:
        out = os.path.join("build", "bench", "selfcompile")
        os.makedirs(os.path.join(ROOT, out), exist_ok=True)
        # rebuild orin2 from its own C with the *current* runtime so counters are available.
        stage = os.path.join(out, "orin2_cur")
        bt = timed_build([[orinc, "compile", "compiler/main.or", "-o", out + "/orin2_cur.c"],
                          ["cc"] + CFLAGS + ["-I", "runtime", out + "/orin2_cur.c", "runtime/orin_runtime.c", "-o", stage]])
        cmd = [os.path.join(ROOT, stage), "compile", "compiler/main.or", "-o", out + "/out.c"]
        run_once(cmd)
        walls, rss = [], []
        for _ in range(args.runs):
            w, m, rc, so, se = run_once(cmd)
            if rc != 0:
                sys.exit("selfcompile failed: " + se.decode("utf-8", "replace"))
            walls.append(w)
            rss.append(m)
        digest = hashlib.sha256(open(os.path.join(ROOT, out, "out.c"), "rb").read()).hexdigest()
        ref = os.path.join(ROOT, "build", "bootstrap", "stage2.c")
        same = os.path.exists(ref) and hashlib.sha256(open(ref, "rb").read()).hexdigest() == digest
        _, _, _, _, se = run_once(cmd, env={"ORIN_STATS": "1"})
        st = json.loads(se.decode().strip().splitlines()[-1])["orin_stats"]
        selfc = {"wall": median_range(walls), "rss_kb": statistics.median(rss), "stats": st, "same": same,
                 "size": sizes(os.path.join(ROOT, stage)), "build_s": bt,
                 "csize": os.path.getsize(os.path.join(ROOT, out, "out.c"))}
        print("selfcompile median %ss" % fmt_s(selfc["wall"][0]), file=sys.stderr)
        orinb = os.path.join(ROOT, "bootstrap", "target", "release", "orinb")
        if os.path.exists(orinb):
            cmd = [orinb, "compile", "build/bootstrap/stage0-src/compiler/main.or", "-o", out + "/out_stage0.c"]
            run_once(cmd)
            walls, rss = [], []
            for _ in range(args.runs):
                w, m, rc, so, se = run_once(cmd)
                walls.append(w)
                rss.append(m)
            selfc["stage0"] = {"wall": median_range(walls), "rss_kb": statistics.median(rss),
                               "size": sizes(orinb)}

    # ------------------------------------------------------------ Markdown
    L = []
    L.append("Machine: %s, %s cores, %s RAM; %s; %s; %s; runs per cell: %d (median, after 1 warm-up)." %
             (info["cpu"], info["cores"], info["mem"], info["os"], info["cc"], info["go"], args.runs))
    L.append("")
    L.append("### Wall time, seconds (median; min-max in parentheses)")
    L.append("")
    L.append("| benchmark | Orin | Go | C | Orin/Go | Orin/C |")
    L.append("|---|---:|---:|---:|---:|---:|")
    for n in names:
        r = results[n]
        cells = ["%s (%s-%s)" % (fmt_s(r[l]["wall"][0]), fmt_s(r[l]["wall"][1]), fmt_s(r[l]["wall"][2])) for l in ("orin", "go", "c")]
        L.append("| %s | %s | %s | %s | %.2fx | %.2fx |" % (
            n, cells[0], cells[1], cells[2], r["orin"]["wall"][0] / r["go"]["wall"][0], r["orin"]["wall"][0] / r["c"]["wall"][0]))
    if selfc:
        w = selfc["wall"]
        L.append("| selfcompile (orin2 compiles compiler/main.or) | %s (%s-%s) | - | - | - | - |" % (fmt_s(w[0]), fmt_s(w[1]), fmt_s(w[2])))
        if "stage0" in selfc:
            w = selfc["stage0"]["wall"]
            L.append("| selfcompile, reference: Rust stage-0 `orinb` | %s (%s-%s) | - | - | - | - |" % (fmt_s(w[0]), fmt_s(w[1]), fmt_s(w[2])))
    L.append("")
    L.append("### Peak RSS, MiB (median of ru_maxrss; ~1 MiB process-startup floor)")
    L.append("")
    L.append("| benchmark | Orin | Go | C |")
    L.append("|---|---:|---:|---:|")
    for n in names:
        r = results[n]
        L.append("| %s | %s |" % (n, " | ".join("%.1f" % (r[l]["rss_kb"] / 1024) for l in ("orin", "go", "c")) + " "))
    if selfc:
        extra = " | - | - |"
        L.append("| selfcompile (orin2) | %.1f%s" % (selfc["rss_kb"] / 1024, extra))
        if "stage0" in selfc:
            L.append("| selfcompile (Rust orinb) | %.1f%s" % (selfc["stage0"]["rss_kb"] / 1024, extra))
    L.append("")
    L.append("### Binary size, KiB (unstripped / stripped) and build time, seconds (single run)")
    L.append("")
    L.append("| benchmark | Orin | Go | C | Orin build | Go build | C build |")
    L.append("|---|---:|---:|---:|---:|---:|---:|")
    def sz(r):
        return "%.0f / %s" % (r["raw"] / 1024, "%.0f" % (r["stripped"] / 1024) if r["stripped"] else "n/a")
    for n in names:
        r = results[n]
        L.append("| %s | %s | %s | %s | %.2f | %.2f | %.2f |" % (
            n, sz(r["orin"]), sz(r["go"]), sz(r["c"]), r["orin"]["build_s"], r["go"]["build_s"], r["c"]["build_s"]))
    if selfc:
        raw, stripped = selfc["size"]
        L.append("| orin2 compiler binary | %.0f / %s | - | - | %.2f | - | - |" % (
            raw / 1024, "%.0f" % (stripped / 1024) if stripped else "n/a", selfc["build_s"]))
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
    L.append("Checksums: %s." % ("all outputs identical across Orin/Go/C" if not mismatches else
                                  "MISMATCH in " + ", ".join("%s/%s" % m for m in mismatches)))
    text = "\n".join(L) + "\n"
    print(text)
    if args.out:
        with open(os.path.join(ROOT, args.out), "w") as f:
            f.write(text)
    sys.exit(1 if mismatches else 0)


if __name__ == "__main__":
    main()
