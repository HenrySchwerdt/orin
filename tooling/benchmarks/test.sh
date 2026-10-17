#!/bin/sh
# Tests of tooling/reports and tooling/benchmarks (ADR-0047 phase 6, first report family).
#   1. tooling/reports: the theme asset is in sync with its CSS, and its @Test suite passes (escaping, empty states, number formats).
#   2. tooling/benchmarks: the bench-report tool is built and every case of testdata/ is diffed byte for byte against
#      testdata/golden/. The golden Markdown, SVG and README files were produced by the Python tool this program replaced
#      (tools/bench_report.py, same inputs; the README differs only in the one sentence that names the generating tool);
#      golden/*/report.html is the reviewed output of the Orin report.
# Needs build/bootstrap/orin2 (tools/bootstrap.sh). Usage: tooling/benchmarks/test.sh
set -eu
cd "$(dirname "$0")/../.."
. tools/runtime_files.sh   # the runtime source list: tools/runtime-sources.txt
ORIN2=${ORIN2:-build/bootstrap/orin2}
T=tooling/benchmarks/testdata
G=$T/golden
B=build/bench-report-test
rm -rf "$B"
mkdir -p "$B"
fail=0
bad() { echo "FAIL $1"; fail=1; }
ok() { echo "ok   $1"; }

tooling/reports/gen_theme.sh --check && ok "theme_css.or is generated from theme/report.css" || bad "theme_css.or is stale"
out=$($ORIN2 test tooling/reports/tests/report_test.or --runtime runtime/core 2>&1) \
  && ok "tooling/reports tests: $(echo "$out" | tail -1)" || { echo "$out"; bad "tooling/reports tests"; }

$ORIN2 compile tooling/benchmarks -o "$B/br.c"
cc -O1 -w $(rt_inc) "$B/br.c" $(rt_src) -lm -o "$B/bench-report"
BR=$B/bench-report

# case NAME HISTORY-DIR RUN-FILE
case_of() {
  n=$1; h=$2; r=$3
  if [ -f "$G/$n/summary.md" ]; then
    "$BR" summary "$r" > "$B/$n.summary.md" && cmp -s "$B/$n.summary.md" "$G/$n/summary.md" && ok "$n: summary" || bad "$n: summary differs from golden"
  fi
  "$BR" compare --history "$h" "$r" > "$B/$n.compare.md"
  cmp -s "$B/$n.compare.md" "$G/$n/compare.md" && ok "$n: compare (exit 0)" || bad "$n: compare differs from golden"
  "$BR" render --history "$h" --out "$B/$n" --repo HenrySchwerdt/orin 2> "$B/$n.render.log"
  if diff -r -x compare.md -x summary.md "$G/$n" "$B/$n" > "$B/$n.diff"; then ok "$n: render (charts, README.md, report.html)"; else head -20 "$B/$n.diff"; bad "$n: render differs from golden"; fi
}

case_of real $T/history $T/history/2026-10-16-9f83f16af402.json
case_of multi $T/multi/history $T/multi/head.json
case_of evil $T/evil/history $T/evil/head.json
case_of invalid $T/invalid/history $T/history/2026-10-16-9f83f16af402.json
grep -q "skipping .*0-broken.json" "$B/invalid.render.log" && ok "invalid: the broken history file is reported and skipped" || bad "invalid: no skip message"

# empty history: a directory without runs (git does not keep empty directories)
mkdir -p "$B/emptyhist"
"$BR" compare --history "$B/emptyhist" $T/history/2026-10-16-9f83f16af402.json > "$B/empty.compare.md"
cmp -s "$B/empty.compare.md" "$G/empty/compare.md" && ok "empty: compare" || bad "empty: compare differs from golden"
"$BR" render --history "$B/emptyhist" --out "$B/empty" --repo HenrySchwerdt/orin 2> /dev/null
diff -r -x compare.md "$G/empty" "$B/empty" > /dev/null && ok "empty: render (no runs yet)" || bad "empty: render differs from golden"
# a missing history directory behaves like an empty one for compare
"$BR" compare --history "$B/nonexistent" $T/history/2026-10-16-9f83f16af402.json | cmp -s - "$G/empty/compare.md" && ok "missing history directory" || bad "missing history directory"

# the run file itself must be valid: fail closed with exit 1 and nothing on stdout
printf '{"benchmarks": ' > "$B/broken.json"
if "$BR" summary "$B/broken.json" > "$B/broken.out" 2> "$B/broken.err"; then bad "invalid JSON run must fail"; else
  [ ! -s "$B/broken.out" ] && grep -q "invalid JSON" "$B/broken.err" && ok "invalid JSON run: exit 1, diagnostic on stderr" || bad "invalid JSON run: output"; fi
printf '[]' > "$B/array.json"
"$BR" summary "$B/array.json" > /dev/null 2>&1 && bad "non-object run must fail" || ok "non-object run: exit 1"
"$BR" > /dev/null 2>&1 && bad "no arguments must be a usage error" || ok "usage error without arguments"

# escaping (the Markdown files carry names verbatim, as the Python tool did; GitHub sanitises Markdown): the hostile benchmark name is text everywhere and never markup
if grep -q '<script' "$B/evil/report.html" "$B"/evil/charts/*.svg 2>/dev/null; then bad "evil: raw <script> in the output"; else ok "evil: no raw <script> in report.html or the SVG charts"; fi
grep -q '&lt;script&gt;&amp;"' "$B/evil/charts/ratio_wall.svg" && grep -q '&lt;script&gt;&amp;&quot;&#39;' "$B/evil/report.html" \
  && ok "evil: the name is escaped in both contexts" || bad "evil: escaped name missing"

# the page works offline: no remote resources, no scripts
if grep -Eq '<script|<link|<img|https?://[^"]*\.(css|js)' "$B/real/report.html"; then bad "report.html loads something"; else ok "report.html is self-contained (no script, link, img)"; fi

[ "$fail" = 0 ] || { echo "tooling/benchmarks: FAILED"; exit 1; }
echo "tooling/benchmarks: all checks passed"
