#!/bin/sh
# Checks the tutorial (docs/tutorial/, examples/tutorial/) against a compiler.
#
#   tools/test_tutorial.sh [COMPILER]       COMPILER defaults to $ORIN, else build/bootstrap/orin2
#
# 1. Programs. Every examples/tutorial/NAME.or is built and run; its stdout must equal NAME.out. Optional files:
#      NAME.args          program arguments (one line, split on blanks)
#      NAME.exit          expected exit status of the run (default 0)
#      NAME.test.out      `orin test NAME.or` must print this on stdout (status from NAME.test.exit, default 0)
#      NAME.verify.out    `orin verify --contracts NAME.or` must print this (status from NAME.verify.exit, default 0);
#                         skipped with a message when z3 is not on PATH
#    A directory examples/tutorial/DIR with an orin.toml is a package: it is built from the directory and its stdout
#    compared with DIR/expected.out; every DIR/tests/*_test.or is run with `test`, the outputs concatenated and compared
#    with DIR/expected.test.out.
# 2. Markdown. In docs/tutorial/*.md a line `<!-- file: PATH -->` directly before a code fence says that the fence holds
#    exactly the file PATH (byte-identical). Every .or file and orin.toml under examples/tutorial must be shown in at
#    least one chapter that way (the .out files are shown where a chapter prints the expected output).
#
# Everything runs from the repository root. Exit status 0 only if nothing failed.
set -u
cd "$(dirname "$0")/.."
ORIN=${1:-${ORIN:-build/bootstrap/orin2}}
CC=${CC:-cc}
if [ ! -x "$ORIN" ]; then echo "test_tutorial: compiler $ORIN not found (run tools/bootstrap.sh)" >&2; exit 2; fi
. tools/runtime_files.sh
RT_INC=$(rt_inc)
RT_SRC=$(rt_src)
WORK=build/tutorial
rm -rf "$WORK"; mkdir -p "$WORK"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0; skip=0

ok()   { pass=$((pass + 1)); echo "ok    $1"; }
bad()  { fail=$((fail + 1)); echo "FAIL  $1: $2"; }
skp()  { skip=$((skip + 1)); echo "skip  $1: $2"; }
code() { if [ -f "$1" ]; then cat "$1"; else echo 0; fi; }

# build ENTRY NAME: compile with $ORIN and link with the C runtime into $WORK/NAME.exe
build() {
  "$ORIN" compile "$1" -o "$WORK/$2.c" 2> "$WORK/$2.compile.err" || return 1
  # shellcheck disable=SC2086
  $CC -O1 -w $RT_INC "$WORK/$2.c" $RT_SRC -lm -pthread -o "$WORK/$2.exe" 2> "$WORK/$2.cc.err" || return 1
}

# expect LABEL EXPECTED_FILE ACTUAL_FILE
expect() {
  if cmp -s "$2" "$3"; then ok "$1"; else bad "$1" "stdout differs from $2"; diff "$2" "$3" | head -10 | sed 's/^/        /'; fi
}

# run_check LABEL EXPECTED_STATUS ACTUAL_STATUS
status_is() { [ "$2" = "$3" ] || { bad "$1" "exit status $3, expected $2"; return 1; }; }

run_program() { # NAME ENTRY EXPECTED_OUT ARGS_FILE_OR_EMPTY EXIT_FILE
  name=$1
  if ! build "$2" "$name"; then bad "$name" "build failed"; head -5 "$WORK/$name.compile.err" "$WORK/$name.cc.err" 2>/dev/null | sed 's/^/        /'; return; fi
  pargs=; [ -n "$4" ] && [ -f "$4" ] && pargs=$(cat "$4")
  # shellcheck disable=SC2086
  "$WORK/$name.exe" $pargs > "$WORK/$name.stdout" 2> "$WORK/$name.stderr" < /dev/null
  rc=$?
  status_is "run $name" "$(code "$5")" "$rc" || return
  expect "run $name" "$3" "$WORK/$name.stdout"
}

mkdir -p "$WORK/out"

# ---- 1. programs ----------------------------------------------------------------------------------------------
for src in examples/tutorial/*.or; do
  [ -f "$src" ] || continue
  base=${src%.or}; name=$(basename "$base")
  if [ -f "$base.out" ]; then
    run_program "$name" "$src" "$base.out" "$base.args" "$base.exit"
  fi
  if [ -f "$base.test.out" ]; then
    "$ORIN" test "$src" > "$WORK/$name.test.stdout" 2> "$WORK/$name.test.stderr" < /dev/null; rc=$?
    status_is "test $name" "$(code "$base.test.exit")" "$rc" && expect "test $name" "$base.test.out" "$WORK/$name.test.stdout"
  fi
  if [ -f "$base.verify.out" ]; then
    if command -v z3 >/dev/null 2>&1; then
      "$ORIN" verify --contracts "$src" > "$WORK/$name.verify.stdout" 2> "$WORK/$name.verify.stderr" < /dev/null; rc=$?
      status_is "verify $name" "$(code "$base.verify.exit")" "$rc" && expect "verify $name" "$base.verify.out" "$WORK/$name.verify.stdout"
    else
      skp "verify $name" "z3 is not on PATH"
    fi
  fi
done

for dir in examples/tutorial/*/; do
  dir=${dir%/}
  [ -f "$dir/orin.toml" ] || continue
  name=$(basename "$dir")
  # the dependency lock is checked in; a build never changes it
  run_program "$name" "$dir" "$dir/expected.out" "" ""
  if [ -f "$dir/expected.test.out" ]; then
    : > "$WORK/$name.test.stdout"
    trc=0
    for t in "$dir"/tests/*_test.or; do
      "$ORIN" test "$t" >> "$WORK/$name.test.stdout" 2>> "$WORK/$name.test.stderr" < /dev/null || trc=1
    done
    status_is "test $name" 0 "$trc" && expect "test $name" "$dir/expected.test.out" "$WORK/$name.test.stdout"
  fi
done

# ---- 2. markdown ----------------------------------------------------------------------------------------------
# awk writes each fenced block that follows a `<!-- file: PATH -->` line to $TMP/blockN and lists "N PATH md:line".
: > "$TMP/shown"
for md in docs/tutorial/*.md; do
  [ -f "$md" ] || continue
  awk -v dir="$TMP" -v md="$md" '
    BEGIN { n = 0; want = ""; inblock = 0 }
    {
      if (inblock) {
        if ($0 ~ /^```/) { inblock = 0; close(out); next }
        print $0 > out; next
      }
      if (want != "" && $0 ~ /^```/) {
        n++; out = dir "/block" n; printf "" > out; inblock = 1
        print n "\t" want "\t" md ":" NR >> (dir "/manifest"); want = ""; next
      }
      if ($0 ~ /^<!-- file: .* -->[ \t]*$/) {
        want = $0; sub(/^<!-- file: /, "", want); sub(/ -->[ \t]*$/, "", want); next
      }
      want = ""
    }
    END { if (inblock) print "unterminated code block in " md > "/dev/stderr" }
  ' "$md"
  # blocks are numbered per md file, so check them before the next file
  if [ -f "$TMP/manifest" ]; then
    while IFS="$(printf '\t')" read -r n path where; do
      if [ ! -f "$path" ]; then bad "$where" "marker names $path, which does not exist"
      elif cmp -s "$TMP/block$n" "$path"; then ok "$where $path"; echo "$path" >> "$TMP/shown"
      else bad "$where" "code block differs from $path"; diff "$path" "$TMP/block$n" | head -6 | sed 's/^/        /'; fi
    done < "$TMP/manifest"
    rm -f "$TMP/manifest"
  fi
  rm -f "$TMP"/block* 2>/dev/null
done

# every example source must appear in a chapter
for f in $(find examples/tutorial -type f \( -name '*.or' -o -name orin.toml \) | sort); do
  grep -qx "$f" "$TMP/shown" || bad "$f" "not shown in any docs/tutorial chapter (add a <!-- file: $f --> block)"
done

echo
echo "tutorial: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
