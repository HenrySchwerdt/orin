#!/bin/sh
# Tests of tooling/explorer (the code explorer, ADR-0050).
#   1. the embedded assets are generated from theme/explorer.{css,js}; the fixture snapshots and the diff are what
#      `orin graph` / `orin diff` write for tooling/explorer/testdata/shop/{base,head} today (so an OSIG change shows up here);
#   2. the @Test suites (explorer_test.or, business_test.or): escaping of hostile text on every page, no remote resources and no inline script, determinism,
#      slugs, the empty diff, refused inputs, the graph layout;
#   3. the `explore` program: its site for the fixture equals testdata/golden/ byte for byte, two runs are identical,
#      bad input fails with a diagnostic and writes nothing, and the site works offline (relative links only, all of them
#      resolve to a file of the site).
# Needs build/bootstrap/orin2 (tools/bootstrap.sh). Usage: tooling/explorer/test.sh
set -eu
cd "$(dirname "$0")/../.."
. tools/runtime_files.sh   # the runtime source list: tools/runtime-sources.txt
ORIN2=${ORIN2:-build/bootstrap/orin2}
T=tooling/explorer/testdata
B=build/explorer-test
rm -rf "$B"
mkdir -p "$B"
fail=0
bad() { echo "FAIL $1"; fail=1; }
ok() { echo "ok   $1"; }

tooling/explorer/gen_assets.sh --check && ok "explorer_css.or and explorer_js.or are generated from theme/" || bad "embedded assets are stale"
$ORIN2 graph $T/shop/base -o "$B/base.json" && $ORIN2 graph $T/shop/head -o "$B/head.json" \
  && $ORIN2 diff --base "$B/base.json" --head "$B/head.json" --format=json -o "$B/diff.json" || bad "orin graph / orin diff of the fixture"
cmp -s "$B/base.json" $T/shop.base.graph.json && cmp -s "$B/head.json" $T/shop.head.graph.json && cmp -s "$B/diff.json" $T/shop.diff.json \
  && ok "fixture snapshots and diff are current (testdata/regen.sh)" || bad "fixture snapshots or diff are stale: run tooling/explorer/testdata/regen.sh"
grep -q '"doc":"Price of `qty` items' $T/shop.head.graph.json && ok "the snapshot carries the documentation comments (osig/0.3)" || bad "no doc field in the snapshot"

out=$($ORIN2 test tooling/explorer/tests/explorer_test.or --runtime runtime/core 2>&1) \
  && ok "tooling/explorer tests: $(echo "$out" | tail -1)" || { echo "$out"; bad "tooling/explorer tests"; }

out=$($ORIN2 test tooling/explorer/tests/business_test.or --runtime runtime/core 2>&1) \
  && ok "business view tests (ADR-0051): $(echo "$out" | tail -1)" || { echo "$out"; bad "business view tests"; }

out=$($ORIN2 test tooling/explorer/tests/runs_test.or --runtime runtime/core 2>&1) \
  && ok "run history tests (ADR-0050 step 3): $(echo "$out" | tail -1)" || { echo "$out"; bad "run history tests"; }

$ORIN2 compile tooling/explorer -o "$B/ex.c"
cc -O1 -w $(rt_inc) "$B/ex.c" $(rt_src) -lm -o "$B/explore"
EX=$B/explore

"$EX" $T/shop.head.graph.json --diff $T/shop.diff.json --out "$B/site1" 2> /dev/null
if diff -r $T/golden "$B/site1" > "$B/golden.diff"; then ok "site for the fixture equals testdata/golden"; else head -20 "$B/golden.diff"; bad "site differs from testdata/golden (testdata/regen.sh after a deliberate change)"; fi
"$EX" $T/shop.head.graph.json --diff $T/shop.diff.json --out "$B/site2" 2> /dev/null
diff -r "$B/site1" "$B/site2" > /dev/null && ok "two runs are byte-identical" || bad "output is not deterministic"
"$EX" $T/shop.head.graph.json --out "$B/nodiff" 2> /dev/null
[ ! -e "$B/nodiff/diff.html" ] && ! grep -q 'href="diff.html"' "$B/nodiff/index.html" && ok "without --diff there is no changes page and no link to it" || bad "diff page without --diff"

# run history (--runs, ADR-0050 step 3): the processes page and runs.css equal testdata/golden-runs; every other page is the one of a
# site without a history; a single record file works; bad paths fail without writing
"$EX" $T/shop.head.graph.json --diff $T/shop.diff.json --runs $T/runs --out "$B/runs1" 2> /dev/null
cmp -s $T/golden-runs/processes.html "$B/runs1/processes.html" && cmp -s $T/golden-runs/assets/runs.css "$B/runs1/assets/runs.css" \
  && ok "--runs: processes page and runs.css equal testdata/golden-runs" || bad "--runs: differs from testdata/golden-runs (testdata/regen.sh after a deliberate change)"
same=1
for f in $(cd "$B/site1" && find . -type f | sort); do
  [ "$f" = ./processes.html ] || cmp -s "$B/site1/$f" "$B/runs1/$f" || { echo "--runs changed $f"; same=0; }
done
[ "$same" = 1 ] && [ ! -e "$B/site1/assets/runs.css" ] && ! grep -q runs.css "$B/site1/processes.html" \
  && ok "--runs changes only processes.html (+ assets/runs.css); without it there is no stylesheet and no link" || bad "--runs changed other files"
"$EX" $T/shop.head.graph.json --runs $T/runs/2026-10-16-9f83f16af402.json --out "$B/runs2" 2> /dev/null
grep -q 'Time per phase: compiler' "$B/runs2/processes.html" && ! grep -q 'class="rn-spark"' "$B/runs2/processes.html" \
  && ok "--runs FILE: a single record is a history of one run" || bad "--runs FILE"
if "$EX" $T/shop.head.graph.json --runs "$B/nonexistent" --out "$B/never3" > /dev/null 2> "$B/runs.err"; then bad "a missing --runs path must fail"; else
  grep -q "no such file" "$B/runs.err" && [ ! -e "$B/never3" ] && ok "--runs with a missing path: exit 1, diagnostic, nothing written" || bad "--runs missing path: output"; fi
mkdir -p "$B/emptyruns"
if "$EX" $T/shop.head.graph.json --runs "$B/emptyruns" --out "$B/never4" > /dev/null 2>&1; then bad "an empty --runs directory must fail"; else ok "--runs with a directory without records fails"; fi
if "$EX" $T/shop.head.graph.json --runs $T/shop.diff.json --out "$B/never5" > /dev/null 2>&1; then bad "a diff given as --runs must fail"; else ok "a diff is not a run history"; fi

for f in business.html usecases.html rules.html capabilities.html behaviour.html u/root-main.html assets/business.css; do
  [ -f "$B/site1/$f" ] || bad "business view: $f missing"
done
[ ! -e "$B/nodiff/behaviour.html" ] && ! grep -q 'href="behaviour.html"' "$B/nodiff/business.html" && [ -f "$B/nodiff/business.html" ] \
  && ok "business view: pages written; no behaviour page and no link to it without --diff" || bad "business view without --diff"
grep -q 'New rule: ' "$B/site1/behaviour.html" && grep -q 'may now read the clock' "$B/site1/behaviour.html" && grep -q 'must be zero or greater' "$B/site1/rules.html" \
  && ok "business view: rule sentences and behaviour changes in plain language" || bad "business view: expected sentences missing"

# every relative link and every stylesheet / script reference of every page resolves to a file of the site
python3 - "$B/site1" <<'PY' && ok "all links of the site resolve (offline, relative only)" || bad "dangling or absolute link"
import os, re, sys
root = sys.argv[1]
bad = []
for dp, _, fs in os.walk(root):
    for f in fs:
        if not f.endswith(".html"):
            continue
        p = os.path.join(dp, f)
        text = open(p, encoding="utf-8").read()
        for m in re.finditer(r'(?:href|src)="([^"]*)"', text):
            u = m.group(1)
            if u.startswith("#"):
                continue
            if "://" in u or u.startswith("//") or u.startswith("about:") or ":" in u.split("/")[0]:
                if "w3.org" not in u:
                    bad.append((p, u))
                continue
            target = os.path.normpath(os.path.join(dp, u.split("#")[0]))
            if not os.path.exists(target):
                bad.append((p, u))
for b in bad[:10]:
    print("dangling:", b)
sys.exit(1 if bad else 0)
PY

# bad input: exit 1, a diagnostic on stderr, nothing written
printf '{"schema": "osig/0.3", ' > "$B/broken.json"
if "$EX" "$B/broken.json" --out "$B/never" > /dev/null 2> "$B/broken.err"; then bad "broken snapshot must fail"; else
  grep -q "invalid JSON" "$B/broken.err" && [ ! -e "$B/never" ] && ok "broken snapshot: exit 1, diagnostic, nothing written" || bad "broken snapshot: output"; fi
"$EX" $T/shop.diff.json --out "$B/never2" > /dev/null 2>&1 && bad "a diff given as snapshot must fail" || ok "a diff is not a snapshot"
"$EX" > /dev/null 2>&1 && bad "no arguments must be a usage error" || ok "usage error without arguments"
"$EX" $T/shop.head.graph.json > /dev/null 2>&1 && bad "missing --out must be a usage error" || ok "usage error without --out"

[ "$fail" = 0 ] || { echo "tooling/explorer: FAILED"; exit 1; }
echo "tooling/explorer: all checks passed"
