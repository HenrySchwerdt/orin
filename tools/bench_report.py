#!/usr/bin/env python3
"""Reports of benchmark results written by `tools/bench.py --json` (stdlib only; see docs/benchmarks.md "Benchmark workflow").

  python3 tools/bench_report.py summary RUN.json
      Markdown tables of one run (Orin vs C / Go / Java / Rust, ratios to C, instruction counts, parallel
      speedup, self-compile): the job summary of .github/workflows/bench.yml.

  python3 tools/bench_report.py compare --history DIR RUN.json
      Markdown diff of RUN.json against the newest earlier entries of DIR (for every benchmark the newest file that has
      it): the PR comment. A row is flagged as a regression when the executed instructions rise by more than 2 % or the
      wall-time median by more than 15 %. Always exits 0 (it reports, it does not gate).

  python3 tools/bench_report.py render --history DIR --out DIR [--repo owner/name]
      SVG charts (Orin/C ratio per benchmark over time, self-compile instructions and time over time, parallel speedup)
      and a README.md that embeds them: the front page of the `bench-results` branch.

History files are the JSON of bench.py, one per run, named <date>-<sha>.json; they are ordered by their "date" field.
"""
import argparse
import glob
import json
import math
import os
import sys
from xml.sax.saxutils import escape

INSTR_THRESHOLD = 0.02   # +2 % executed instructions = regression
WALL_THRESHOLD = 0.15    # +15 % wall-time median = regression (wall time on shared runners is noisy)
MARKER = "<!-- orin-bench-comment -->"
LANG_NAMES = {"orin": "Orin (C backend)", "llvm": "Orin (LLVM backend)", "c": "C", "go": "Go", "java": "Java", "rust": "Rust"}


# ---------------------------------------------------------------------------------------------- loading

def load(path):
    with open(path) as f:
        return json.load(f)


def load_history(d):
    runs = []
    for p in glob.glob(os.path.join(d, "*.json")):
        try:
            doc = load(p)
        except (OSError, ValueError) as e:
            print("skipping %s: %s" % (p, e), file=sys.stderr)
            continue
        doc["_file"] = os.path.basename(p)
        runs.append(doc)
    runs.sort(key=lambda r: (r.get("date", ""), r["_file"]))
    return runs


def wall(doc, bench, lang):
    c = doc.get("benchmarks", {}).get(bench, {}).get("langs", {}).get(lang, {})
    return c.get("wall_median")


def instr(doc, bench, lang):
    c = doc.get("benchmarks", {}).get(bench, {}).get("instructions", {}).get(lang, {})
    return c.get("count") if not c.get("args") else None   # counts on a reduced input are not comparable with others


def self_instr(doc):
    sc = doc.get("selfcompile") or {}
    return (sc.get("instructions") or {}).get("count")


def self_wall(doc):
    return (doc.get("selfcompile") or {}).get("wall_median")


# ---------------------------------------------------------------------------------------------- Markdown

def s3(x):
    return "n/a" if x is None else ("%.3f" % x if x < 100 else "%.1f" % x)


def big(n):
    return "n/a" if n is None else "{:,}".format(n)


def ratio(a, b):
    return "n/a" if a is None or b is None or b == 0 else "%.2fx" % (a / b)


def pct(new, old):
    if new is None or old is None or old == 0:
        return None
    return (new - old) / old


def fpct(p):
    return "n/a" if p is None else "%+.1f %%" % (100 * p)


def short(sha):
    return (sha or "?")[:10]


def header(doc):
    m = doc.get("machine", {})
    t = doc.get("tools", {})
    tools = "\n".join("- %s: `%s`" % (k, v) for k, v in sorted(t.items()) if v)
    return ("Commit `%s` (%s), %s. Machine: %s, %s cores, %s, %s. Runs per cell: %s (median after one warm-up)."
            "\n\n<details><summary>Tool versions</summary>\n\n%s\n\n</details>\n" %
            (short(doc.get("commit")), doc.get("ref") or "?", doc.get("date", "?"), m.get("cpu", "?"), m.get("cores", "?"),
             m.get("mem", "?"), m.get("os", "?"), doc.get("runs", "?"), tools))


def summary(doc):
    L = ["## Orin benchmarks", "", header(doc)]
    benches = doc.get("benchmarks", {})
    names = sorted(benches)
    langs = ["orin", "llvm", "c", "go", "java", "rust"]
    if names:
        L += ["### Wall time, seconds (median; min-max)", "",
              "| benchmark | " + " | ".join(LANG_NAMES[l] for l in langs) + " |",
              "|---|" + "---:|" * len(langs)]
        for n in names:
            cells = []
            for l in langs:
                c = benches[n]["langs"].get(l)
                if not c or c.get("wall_median") is None:
                    cells.append("n/a" if not c else "MISMATCH")
                else:
                    cells.append("%s (%s-%s)%s" % (s3(c["wall_median"]), s3(c["wall_min"]), s3(c["wall_max"]),
                                                   "" if c.get("output_matched", True) else " MISMATCH"))
            L.append("| %s | %s |" % (n, " | ".join(cells)))
        L += ["", "### Ratio to C (wall-time median; lower is better, 1.00x = as fast as C)", "",
              "| benchmark | Orin C/C | Orin LLVM/C | Go/C | Java/C | Rust/C |", "|---|---:|---:|---:|---:|---:|"]
        for n in names:
            c = wall(doc, n, "c")
            L.append("| %s | %s |" % (n, " | ".join(ratio(wall(doc, n, l), c) for l in ("orin", "llvm", "go", "java", "rust"))))
        L += ["", "### CPU time (user + sys, median s) and peak RSS (MiB)", "",
              "| benchmark | " + " | ".join("%s CPU" % l for l in langs) + " | " + " | ".join("%s RSS" % l for l in langs) + " |",
              "|---|" + "---:|" * (2 * len(langs))]
        for n in names:
            lg = benches[n]["langs"]
            cpu = [s3(lg.get(l, {}).get("cpu_median")) for l in langs]
            rss = ["n/a" if lg.get(l, {}).get("rss_kb") is None else "%.1f" % (lg[l]["rss_kb"] / 1024) for l in langs]
            L.append("| %s | %s | %s |" % (n, " | ".join(cpu), " | ".join(rss)))
        L.append("")
    if any(benches[n].get("instructions") for n in names) or self_instr(doc) is not None:
        L += ["### Executed instructions (valgrind; the regression metric)", "",
              "| benchmark | Orin C | Orin LLVM | C | Orin C/C | Orin LLVM/C | note |", "|---|---:|---:|---:|---:|---:|---|"]
        for n in names:
            ins = benches[n].get("instructions", {})
            if not ins:
                continue
            cnt = {l: ins.get(l, {}).get("count") for l in ("orin", "llvm", "c")}
            notes = sorted(set(["%s skipped: %s" % (l, d["skipped"]) for l, d in ins.items() if "skipped" in d] +
                               ["reduced input: %s" % " ".join(d["args"]) for d in ins.values() if d.get("args")]))
            L.append("| %s | %s | %s | %s | %s | %s | %s |" % (n, big(cnt["orin"]), big(cnt["llvm"]), big(cnt["c"]),
                                                             ratio(cnt["orin"], cnt["c"]), ratio(cnt["llvm"], cnt["c"]), "; ".join(notes)))
        L.append("")
    par = doc.get("parallel") or {}
    if par:
        L += ["### Parallel speedup (std:task; worker threads = first argument of the program)", "",
              "| benchmark | threads | wall s (min-max) | CPU s (user+sys) | speedup | efficiency | CPU vs 1 thread | output |",
              "|---|---:|---:|---:|---:|---:|---:|---|"]
        for n in sorted(par):
            for t, r in sorted(par[n]["threads"].items(), key=lambda kv: int(kv[0])):
                L.append("| %s | %s | %s (%s-%s) | %s | %s | %s | %s | %s |" % (
                    n, t, s3(r["wall_median"]), s3(r["wall_min"]), s3(r["wall_max"]), s3(r["cpu_median"]),
                    "n/a" if r.get("speedup") is None else "%.2fx" % r["speedup"],
                    "n/a" if r.get("efficiency") is None else "%.0f %%" % (100 * r["efficiency"]),
                    "n/a" if r.get("cpu_ratio") is None else "%.2fx" % r["cpu_ratio"],
                    "same" if r.get("output_matched") else "DIFFERS"))
        L += ["", "Speedup = wall(1 thread) / wall(n); efficiency = speedup / n. CPU time that grows with n is overhead or "
                  "oversubscription (more threads than free cores).", ""]
    sc = doc.get("selfcompile")
    if sc:
        si = sc.get("instructions") or {}
        L += ["### Self-compile (orin2 compiles compiler/main.or)", "",
              "| wall s (min-max) | CPU s | peak RSS MiB | instructions | output identical to stage2.c |", "|---:|---:|---:|---:|---|",
              "| %s (%s-%s) | %s | %.1f | %s | %s |" % (s3(sc["wall_median"]), s3(sc["wall_min"]), s3(sc["wall_max"]),
                                                     s3(sc["cpu_median"]), sc["rss_kb"] / 1024,
                                                     big(si.get("count")) if "skipped" not in si else "skipped: " + si["skipped"],
                                                     "yes" if sc.get("identical_to_stage2") else "no"), ""]
    if doc.get("mismatches"):
        L += ["**Output mismatches:** " + ", ".join(doc["mismatches"]), ""]
    return "\n".join(L) + "\n"


def compare(history, head):
    """Markdown comparison of head against the newest earlier entry per benchmark. Returns (text, regressions)."""
    base_runs = [r for r in history if r.get("commit") != head.get("commit")]

    def latest(getter):
        for r in reversed(base_runs):
            v = getter(r)
            if v is not None:
                return v, r
        return None, None

    rows, regressions, used = [], [], set()
    names = sorted(head.get("benchmarks", {}))
    for n in names:
        for l in ("orin", "llvm"):
            hi, hw = instr(head, n, l), wall(head, n, l)
            if hi is None and hw is None:
                continue
            bi, ri = latest(lambda r: instr(r, n, l))
            bw, rw = latest(lambda r: wall(r, n, l))
            rows.append((n, LANG_NAMES[l], bi, hi, bw, hw))
            used.update(x["_file"] for x in (ri, rw) if x)
    hi, hw = self_instr(head), self_wall(head)
    if hi is not None or hw is not None:
        bi, ri = latest(self_instr)
        bw, rw = latest(self_wall)
        rows.append(("selfcompile", "orin2", bi, hi, bw, hw))
        used.update(x["_file"] for x in (ri, rw) if x)

    L = [MARKER, "## Benchmark comparison", ""]
    newest = [r for r in base_runs if r["_file"] in used]
    if not base_runs:
        L += ["No `main` entry on the `bench-results` branch yet: nothing to compare against. The numbers of this run are in the "
              "job summary.", ""]
        return "\n".join(L) + "\n", []
    base_desc = ", ".join(sorted(set("`%s` (%s)" % (short(r.get("commit")), r.get("date", "?")[:10]) for r in newest))) or "n/a"
    L += ["Head `%s` against `main` %s. Regression thresholds: executed instructions **> +%d %%** (the reliable metric), "
          "wall-time median **> +%d %%** (noisy on shared runners). This comment reports only; it does not fail the job." %
          (short(head.get("commit")), base_desc, int(INSTR_THRESHOLD * 100), int(WALL_THRESHOLD * 100)), ""]
    table = ["| benchmark | binary | instructions main | instructions PR | change | wall main s | wall PR s | change | verdict |",
             "|---|---|---:|---:|---:|---:|---:|---:|---|"]
    for n, l, bi, hi, bw, hw in rows:
        di, dw = pct(hi, bi), pct(hw, bw)
        verdict = []
        if di is not None and di > INSTR_THRESHOLD:
            verdict.append("**regression (instructions)**")
        if dw is not None and dw > WALL_THRESHOLD:
            verdict.append("**regression (wall time)**")
        if di is not None and di < -INSTR_THRESHOLD:
            verdict.append("improvement")
        if verdict and verdict[0].startswith("**"):
            regressions.append((n, l, di, dw))
        table.append("| %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (n, l, big(bi), big(hi), fpct(di), s3(bw), s3(hw), fpct(dw),
                                                                       ", ".join(verdict) or "ok"))
    if regressions:
        L += ["**%d regression(s) flagged:** %s." % (len(regressions), ", ".join("%s / %s" % (n, l) for n, l, _, _ in regressions)), ""]
    else:
        L += ["No regression above the thresholds.", ""]
    L += table + [""]
    par = head.get("parallel") or {}
    if par:
        L += ["Parallel speedup of this run (informational): " + "; ".join(
            "%s %s" % (n, ", ".join("%s thr %.2fx" % (t, r["speedup"]) for t, r in sorted(par[n]["threads"].items(), key=lambda kv: int(kv[0]))
                                    if r.get("speedup") is not None)) for n in sorted(par)) + ".", ""]
    return "\n".join(L) + "\n", regressions


# ---------------------------------------------------------------------------------------------- SVG

# Categorical slots 1-3 of the reference palette (validated adjacent and all-pairs for three series, light and dark).
LIGHT = {"bg": "#fcfcfb", "border": "#d6d5d0", "ink": "#0b0b0b", "ink2": "#52514e", "grid": "#e4e3df", "ref": "#8a8984",
         "s1": "#2a78d6", "s2": "#eb6834", "s3": "#1baf7a"}
DARK = {"bg": "#1a1a19", "border": "#3a3a37", "ink": "#f0efec", "ink2": "#c3c2b7", "grid": "#2f2f2c", "ref": "#8a8984",
        "s1": "#3987e5", "s2": "#d95926", "s3": "#199e70"}
SERIES = ["s1", "s2", "s3"]
FONT = "-apple-system, 'Segoe UI', Helvetica, Arial, sans-serif"


def style():
    def rules(c):
        return ("svg{color-scheme:%s}.bg{fill:%s;stroke:%s}.t{fill:%s}.t2{fill:%s}.grid{stroke:%s}.ref{stroke:%s}"
                ".s1{stroke:%s;fill:%s}.s2{stroke:%s;fill:%s}.s3{stroke:%s;fill:%s}.ring{stroke:%s}" %
                ("light" if c is LIGHT else "dark", c["bg"], c["border"], c["ink"], c["ink2"], c["grid"], c["ref"],
                 c["s1"], c["s1"], c["s2"], c["s2"], c["s3"], c["s3"], c["bg"]))
    # The light surface is explicit, so the chart reads the same on GitHub's light and dark page; a viewer whose system is
    # in dark mode gets the dark steps of the same palette (both backgrounds and inks switch together).
    return "<style>%s text{font-family:%s}@media (prefers-color-scheme: dark){%s}</style>" % (rules(LIGHT), FONT, rules(DARK))


def nice_ticks(lo, hi, n=5):
    if hi <= lo:
        hi = lo + (abs(lo) or 1) * 0.1
        lo = lo - (abs(lo) or 1) * 0.1
    span = hi - lo
    raw = span / n
    mag = 10 ** math.floor(math.log10(raw))
    step = next(m * mag for m in (1, 2, 2.5, 5, 10) if m * mag >= raw)
    start = math.floor(lo / step) * step
    ticks = []
    v = start
    while v <= hi + step * 1e-9:
        ticks.append(round(v, 10))
        v += step
    if ticks[-1] < hi:
        ticks.append(round(ticks[-1] + step, 10))
    return ticks


def fmt_tick(v, unit=""):
    if abs(v) >= 1e9:
        s = "%gG" % round(v / 1e9, 3)
    elif abs(v) >= 1e6:
        s = "%gM" % round(v / 1e6, 3)
    else:
        s = "%g" % round(v, 3)
    return s + unit


class Svg:
    def __init__(self, w, h, title, desc):
        self.w, self.h = w, h
        self.parts = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" role="img" '
                      'aria-labelledby="title desc">' % (w, h, w, h),
                      "<title id=\"title\">%s</title><desc id=\"desc\">%s</desc>" % (escape(title), escape(desc)), style(),
                      '<rect class="bg" x="0.5" y="0.5" width="%d" height="%d" rx="6" stroke-width="1"/>' % (w - 1, h - 1)]

    def text(self, x, y, s, cls="t", size=12, anchor="start", weight="normal", rotate=None):
        tr = ' transform="rotate(%d %.1f %.1f)"' % (rotate, x, y) if rotate else ""
        self.parts.append('<text class="%s" x="%.1f" y="%.1f" font-size="%d" text-anchor="%s" font-weight="%s"%s>%s</text>' %
                          (cls, x, y, size, anchor, weight, tr, escape(s)))

    def add(self, s):
        self.parts.append(s)

    def done(self):
        return "\n".join(self.parts + ["</svg>"]) + "\n"


def legend(svg, x, y, items):
    """items: [(label, cls, dashed)]; one row, swatch = a 2px line with a marker."""
    for label, cls, dashed in items:
        dash = ' stroke-dasharray="5 4"' if dashed else ""
        svg.add('<line class="%s" x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke-width="2"%s/>' % (cls, x, y - 4, x + 22, y - 4, dash))
        if not dashed:
            svg.add('<circle class="%s ring" cx="%.1f" cy="%.1f" r="4" stroke-width="2"/>' % (cls, x + 11, y - 4))
        svg.text(x + 28, y, label, cls="t", size=12)
        x += 28 + 7.2 * len(label) + 18
    return x


def panel(svg, x, y, w, h, title, series, xlabels, ylabel, ref_line=None, ymin0=False, xtitle=None):
    """A line panel. series: [(cls, [(xi, value)], dashed)]; xlabels: list of strings indexed by xi."""
    svg.text(x, y + 13, title, size=13, weight="600")
    left, top, bottom = x + 52, y + 26, y + h - (34 if xtitle else 22)
    right = x + w - 8
    vals = [v for _, pts, _ in series for _, v in pts if v is not None]
    if ref_line is not None:
        vals.append(ref_line)
    if not vals:
        svg.text(x + w / 2, y + h / 2, "no data", cls="t2", anchor="middle")
        return
    lo, hi = min(vals), max(vals)
    if ymin0:
        lo = 0
    pad = (hi - lo) * 0.08 or abs(hi) * 0.05 or 1
    ticks = nice_ticks(lo if ymin0 else lo - pad, hi + pad, 4)
    y0, y1 = ticks[0], ticks[-1]
    n = max(len(xlabels), 1)

    def px(i):
        return left + 14 + (right - left - 28) * (0.5 if n == 1 else i / (n - 1))

    def py(v):
        return bottom - (bottom - top) * (v - y0) / ((y1 - y0) or 1)
    for t in ticks:
        svg.add('<line class="grid" x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke-width="1"/>' % (left, py(t), right, py(t)))
        svg.text(left - 6, py(t) + 4, fmt_tick(t), cls="t2", size=11, anchor="end")
    svg.text(x + 12, (top + bottom) / 2, ylabel, cls="t2", size=11, anchor="middle", rotate=-90)
    if ref_line is not None and y0 <= ref_line <= y1:
        svg.add('<line class="ref" x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke-width="1.5" stroke-dasharray="5 4"/>' %
                (left, py(ref_line), right, py(ref_line)))
    step = max(1, (n + 4) // 5)   # at most ~5 x labels
    for i, lab in enumerate(xlabels):
        if i % step == 0 or i == n - 1:
            svg.text(px(i), bottom + 15, lab, cls="t2", size=11, anchor="middle")
    if xtitle:
        svg.text((left + right) / 2, bottom + 30, xtitle, cls="t2", size=11, anchor="middle")
    for cls, pts, dashed in series:
        pts = [(i, v) for i, v in pts if v is not None]
        if not pts:
            continue
        if len(pts) > 1:
            d = " ".join("%s%.1f,%.1f" % ("M" if k == 0 else "L", px(i), py(v)) for k, (i, v) in enumerate(pts))
            svg.add('<path class="%s" d="%s" style="fill:none" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"%s/>' %
                    (cls, d, ' stroke-dasharray="5 4"' if dashed else ""))
        if not dashed:
            for i, v in pts:
                svg.add('<circle class="%s ring" cx="%.1f" cy="%.1f" r="4" stroke-width="2"><title>%s: %s</title></circle>' %
                        (cls, px(i), py(v), escape(xlabels[i]), fmt_tick(v)))


def run_label(r):
    return (r.get("date") or "?")[5:10] + " " + short(r.get("commit"))[:7]


def axis_labels(runs):
    return [(r.get("date") or "?")[5:10] for r in runs]


def chart_ratio(runs, metric):
    """Small multiples: one panel per benchmark with a C counterpart, Orin C/C and Orin LLVM/C over time."""
    getter = wall if metric == "wall" else instr
    names = sorted({n for r in runs for n in r.get("benchmarks", {}) if getter(r, n, "c")})
    cols, pw, ph = min(3, max(1, len(names))), 300, 190
    rows = max(1, (len(names) + cols - 1) // cols)
    W, H = cols * pw + 24, rows * ph + 92
    what = "wall-time median" if metric == "wall" else "executed instructions"
    title = "Orin / C ratio per benchmark over time (%s)" % what
    svg = Svg(W, H, title, "Small multiples, one per benchmark: the ratio of Orin (C backend) and Orin (LLVM backend) to C, "
                           "by %s, for every run on main. 1.0 (dashed) means as fast as C; lower is better." % what)
    svg.text(12, 24, title, size=15, weight="600")
    legend(svg, 12, 48, [("Orin (C backend) / C", "s1", False), ("Orin (LLVM backend) / C", "s2", False), ("1.0 = C", "ref", True)])
    labels = axis_labels(runs)
    if not names:
        svg.text(W / 2, H / 2, "no runs with %s yet" % what, cls="t2", anchor="middle")
    for k, n in enumerate(names):
        cx, cy = 12 + (k % cols) * pw, 64 + (k // cols) * ph
        ser = []
        for cls, lang in (("s1", "orin"), ("s2", "llvm")):
            pts = []
            for i, r in enumerate(runs):
                a, c = getter(r, n, lang), getter(r, n, "c")
                pts.append((i, a / c if a is not None and c else None))
            ser.append((cls, pts, False))
        panel(svg, cx, cy, pw - 12, ph - 8, n, ser, labels, "ratio to C", ref_line=1.0)
    return svg.done()


def chart_selfcompile(runs):
    labels = axis_labels(runs)
    W, H = 760, 300
    title = "Self-compile (orin2 compiles compiler/main.or) over time"
    svg = Svg(W, H, title, "Two panels: executed instructions (the regression metric) and wall-time median in seconds, "
                           "for every run on main.")
    svg.text(12, 24, title, size=15, weight="600")
    panel(svg, 12, 40, 360, 250, "Executed instructions", [("s1", [(i, self_instr(r)) for i, r in enumerate(runs)], False)],
          labels, "instructions", ymin0=False, xtitle="run date (MM-DD)")
    panel(svg, 388, 40, 360, 250, "Wall time, median (noisy)", [("s1", [(i, self_wall(r)) for i, r in enumerate(runs)], False)],
          labels, "seconds", ymin0=True, xtitle="run date (MM-DD)")
    return svg.done()


def chart_parallel(runs):
    """Left: speedup against threads in the latest run that has parallel data, with the ideal line. Right: speedup at the
    largest thread count over time. At most three benchmarks get a color (palette cap); more fold into panels of three."""
    with_par = [r for r in runs if r.get("parallel")]
    W, H = 760, 330
    title = "Parallel speedup (std:task, worker threads = first program argument)"
    svg = Svg(W, H, title, "Left: speedup over one thread against the number of worker threads in the latest run, with the "
                           "ideal linear speedup dashed. Right: speedup at the largest thread count for every run on main.")
    svg.text(12, 24, title, size=15, weight="600")
    if not with_par:
        svg.text(W / 2, H / 2, "no parallel results yet", cls="t2", anchor="middle")
        return svg.done()
    last = with_par[-1]
    names = sorted(last["parallel"])[:3]
    items = [(n, SERIES[k], False) for k, n in enumerate(names)] + [("ideal", "ref", True)]
    legend(svg, 12, 48, items)
    ts = sorted({int(t) for n in names for t in last["parallel"][n]["threads"]})
    ser = [(SERIES[k], [(ts.index(int(t)), r.get("speedup")) for t, r in last["parallel"][n]["threads"].items()], False)
           for k, n in enumerate(names)]
    ser = [(c, sorted(p), d) for c, p, d in ser]
    ser.append(("ref", [(i, t / ts[0]) for i, t in enumerate(ts)], True))
    panel(svg, 12, 60, 360, 262, "Latest run (%s)" % run_label(last), ser, [str(t) for t in ts], "speedup (x)",
          ymin0=True, xtitle="worker threads")
    tmax = str(ts[-1])
    hist = []
    for k, n in enumerate(names):
        pts = []
        for i, r in enumerate(with_par):
            row = (r.get("parallel", {}).get(n, {}).get("threads") or {}).get(tmax) or {}
            pts.append((i, row.get("speedup")))
        hist.append((SERIES[k], pts, False))
    panel(svg, 388, 60, 360, 262, "Speedup at %s threads over time" % tmax, hist, axis_labels(with_par), "speedup (x)",
          ymin0=True, xtitle="run date (MM-DD)")
    return svg.done()


def render(history_dir, out_dir, repo):
    runs = load_history(history_dir)
    os.makedirs(os.path.join(out_dir, "charts"), exist_ok=True)
    charts = [("ratio_wall.svg", chart_ratio(runs, "wall"), "Orin to C wall-time ratio per benchmark over time"),
              ("ratio_instructions.svg", chart_ratio(runs, "instructions"), "Orin to C executed-instruction ratio per benchmark over time"),
              ("selfcompile.svg", chart_selfcompile(runs), "Self-compile instructions and wall time over time"),
              ("parallel.svg", chart_parallel(runs), "Parallel speedup by worker threads")]
    for fname, text, _ in charts:
        with open(os.path.join(out_dir, "charts", fname), "w") as f:
            f.write(text)
    L = ["# Orin benchmark history", "",
         "Written by `.github/workflows/bench.yml` (nightly and manual runs on `main`); one JSON file per run in "
         "[`history/`](history/), charts rendered by `tools/bench_report.py render` (no external services). "
         "Metrics and methodology: `docs/benchmarks.md` on `main`. Do not edit this branch by hand.", ""]
    if not runs:
        L += ["No runs yet.", ""]
    else:
        last = runs[-1]
        sha = last.get("commit") or "?"
        link = "[`%s`](https://github.com/%s/commit/%s)" % (short(sha), repo, sha) if repo else "`%s`" % short(sha)
        L += ["%d runs, %s to %s. Latest: %s." % (len(runs), runs[0].get("date", "?")[:10], last.get("date", "?")[:10], link), ""]
        L += ["Instruction counts are the regression metric: they are deterministic for single-threaded programs, while wall "
              "time on a shared runner moves by 10-25 % between identical binaries.", ""]
    for fname, _, alt in charts:
        L += ["![%s](charts/%s)" % (alt, fname), ""]
    if runs:
        L += ["## Latest run", "", summary(runs[-1]).replace("## Orin benchmarks\n", "", 1)]
        L += ["## All runs", "", "| date | commit | ref | self-compile instructions | self-compile wall s | file |",
              "|---|---|---|---:|---:|---|"]
        for r in reversed(runs):
            L.append("| %s | `%s` | %s | %s | %s | [json](history/%s) |" % (r.get("date", "?"), short(r.get("commit")), r.get("ref") or "?",
                                                                       big(self_instr(r)), s3(self_wall(r)), r["_file"]))
        L.append("")
    with open(os.path.join(out_dir, "README.md"), "w") as f:
        f.write("\n".join(L))
    print("rendered %d runs: %s" % (len(runs), ", ".join(c[0] for c in charts)), file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("summary")
    s.add_argument("run")
    c = sub.add_parser("compare")
    c.add_argument("--history", required=True)
    c.add_argument("run")
    r = sub.add_parser("render")
    r.add_argument("--history", required=True)
    r.add_argument("--out", required=True)
    r.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    a = ap.parse_args()
    if a.cmd == "summary":
        sys.stdout.write(summary(load(a.run)))
    elif a.cmd == "compare":
        hist = load_history(a.history) if os.path.isdir(a.history) else []
        text, _ = compare(hist, load(a.run))
        sys.stdout.write(text)
    else:
        render(a.history, a.out, a.repo)


if __name__ == "__main__":
    main()
