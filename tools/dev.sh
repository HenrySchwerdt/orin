#!/bin/sh
# The fast local iteration loop (docs/testing.md, "Fast local loop and parallel tests").
#
#   tools/dev.sh [build]              build build/dev/orin from the current tree: ONE self-compile of compiler/main.or by
#                                     build/bootstrap/orin2 (or, if that is missing, by the seed compiler orin0), C at -O1
#   tools/dev.sh test [SUITE|FILE|SUBSTR]
#                                     build, then the conformance tests with build/dev/orin: a suite (default, next, all;
#                                     default: all), one test file (tests/run/x.or, tests/next/errors/y/main.or) or every
#                                     test whose name contains SUBSTR
#   tools/dev.sh std [MODULE|FILE]    build, then the provable std tests (tools/test_std.sh) with build/dev/orin: all, those
#                                     of one module (bytes, utf8, collections, http, text, task, taskcore, net, seq) or one file
#   tools/dev.sh tooling              build, then the tooling unit tests, LSP, MCP, OSIG and effects tests with build/dev/orin
#
# Every test step runs its cases in parallel: -j N / ORIN_JOBS=N (default: the CPU count). The build is skipped when no
# input changed since the last one (build/dev/stamp).
#
# This loop is for iterating. It is NOT the check required before a pull request: build/dev/orin is a stage-1 compiler
# (the current sources compiled once by an older compiler), so it does not show that the compiler reproduces itself. Before
# a PR run the full bootstrap, which checks the three-stage fixed point (stage2.c == stage3.c) and runs the conformance
# suite, and then the suites your change touches with build/bootstrap/orin2:
#     tools/bootstrap.sh
#     tools/conformance.sh --suite all; tools/test_std.sh; tools/test_tooling.sh; ...
set -eu
cd "$(dirname "$0")/.."
. tools/runtime_files.sh   # the runtime source list: tools/runtime-sources.txt
D=build/dev
B=build/bootstrap
CC=${CC:-cc}
usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

JOBS=
CMD=build
ARG=
while [ $# -gt 0 ]; do
  case "$1" in
    -j) JOBS="-j $2"; shift ;;
    -j*) JOBS="-j ${1#-j}" ;;
    -h|--help|help) usage ;;
    build|test|std|tooling) CMD=$1 ;;
    -*) usage ;;
    *) [ -z "$ARG" ] || usage; ARG=$1 ;;
  esac
  shift
done
[ -n "$JOBS" ] && export ORIN_JOBS="${JOBS#-j }"

now() { date +%s; }
build() {
  mkdir -p $D
  if ! python3 tools/embed_prelude.py --check >/dev/null; then
    python3 tools/embed_prelude.py   # the embedded library/ sources are stale: regenerate (commit the result)
  fi
  if [ -x $B/orin2 ]; then host=$B/orin2; else
    [ -x $B/orin0 ] || { echo "[dev] no $B/orin2: building the seed compiler"; ./tools/bootstrap.sh --seed-only >/dev/null; }
    host=$B/orin0
  fi
  # inputs of the build: the compiler and every source it embeds, the runtime, and the compiler that builds it
  stamp=$(cat "$host" $(find compiler library runtime -type f | LC_ALL=C sort) | cksum)
  if [ -x $D/orin ] && [ "$(cat $D/stamp 2>/dev/null)" = "$stamp" ]; then
    echo "[dev] $D/orin is up to date"
    return
  fi
  t0=$(now)
  echo "[dev] $host compiles compiler/main.or -> $D/orin (cc -O1)"
  $host compile compiler/main.or -o $D/orin.c
  $CC -O1 -w $(rt_inc) $D/orin.c $(rt_src) -lm -o $D/orin.tmp
  mv $D/orin.tmp $D/orin
  echo "$stamp" > $D/stamp
  echo "[dev] built $D/orin in $(( $(now) - t0 )) s"
}

build
export ORIN2=$D/orin
t0=$(now)
case "$CMD" in
  build) exit 0 ;;
  test)
    case "${ARG:-all}" in
      default|next|all) tools/conformance.sh --orinc $D/orin --suite "${ARG:-all}" ;;
      *)
        f=${ARG#tests/}; f=${f%/main.or}; f=${f%.or}
        tools/conformance.sh --orinc $D/orin --suite all --filter "$f" ;;
    esac ;;
  std)
    case "$ARG" in
      "") files= ;;
      *.or) files=$ARG ;;
      collections) files="tests/std/collections_test.or tests/std/sorted_btree_test.or" ;;
      *) files=$(ls tests/std/"$ARG"*_test.or tests/std/expect_trap/"$ARG"_*.or 2>/dev/null || true)
         [ -n "$files" ] || { echo "[dev] no std tests for '$ARG'" >&2; exit 2; } ;;
    esac
    tools/test_std.sh $files ;;
  tooling)
    tools/test_tooling.sh
    tools/protocol.sh lsp --orin $D/orin
    tools/protocol.sh mcp --orin $D/orin
    tools/clitests.sh osig --orin $D/orin
    python3 tools/test_effects.py --orin $D/orin ;;
esac
echo "[dev] $CMD done in $(( $(now) - t0 )) s (with $D/orin; before a PR: tools/bootstrap.sh)"
