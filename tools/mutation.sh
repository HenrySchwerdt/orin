#!/bin/sh
# The mutation checks (tooling/mutation, an Orin package): builds it when needed and runs it. It replaces
# `python3 tools/mutate_std.py` and `python3 tools/mutate_ox.py` in CI and in the tools; the flags are the same, after the
# name of the check:
#
#   tools/mutation.sh std [--orinc COMPILER] [--module bytes|utf8|collections|http|net|text|html|taskcore] [--list]
#                         [--shard I/N] [-j N]
#   tools/mutation.sh ox  [--orinc COMPILER] [--cc CC] [--list] [--only NAME[,NAME]] [-j N]
#   tools/mutation.sh --build-only        build build/mutation/orin-mutation and stop
#   tools/mutation.sh --unit-tests        run the @Test unit tests of the package (tooling/mutation/tests)
#
# The checks are compiled by a trusted, already built compiler: $ORIN_MUTATION_BUILDER, else build/bootstrap/orin2, else
# build/dev/orin. It is never compiled by the compiler under test (--orinc), so a broken compiler cannot also break its judge.
# The build is skipped when the compiler, the package sources, the runtime and the platform layer are unchanged
# (build/mutation/stamp). `ox` runs the OX conformance tests of each mutated compiler with tools/conformance.sh, which is
# built first. docs/testing.md, "Mutation checks".
set -eu
cd "$(dirname "$0")/.."
. tools/runtime_files.sh   # the runtime source list: tools/runtime-sources.txt
OUT=build/mutation
RUNNER=$OUT/orin-mutation
BUILD_ONLY=
UNIT_TESTS=
if [ "${1:-}" = "--build-only" ]; then BUILD_ONLY=1; shift; fi
if [ "${1:-}" = "--unit-tests" ]; then UNIT_TESTS=1; shift; fi

BUILDER=${ORIN_MUTATION_BUILDER:-}
if [ -z "$BUILDER" ]; then
  for c in build/bootstrap/orin2 build/dev/orin; do
    if [ -x "$c" ]; then BUILDER=$c; break; fi
  done
fi
if [ -z "$BUILDER" ] || [ ! -x "$BUILDER" ]; then
  echo "mutation: no compiler to build the checks with (run tools/bootstrap.sh or tools/dev.sh, or set ORIN_MUTATION_BUILDER)" >&2
  exit 1
fi

if [ -n "$UNIT_TESTS" ]; then
  for f in tooling/mutation/tests/*_test.or; do
    out=$("$BUILDER" test "$f") || { echo "$out"; echo "mutation: unit tests failed in $f" >&2; exit 1; }
    echo "$f: $(echo "$out" | tail -1)"
  done
  exit 0
fi

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }
CC=${CC:-cc}
stamp=$({ echo "$CC"; cat "$BUILDER" tooling/mutation/orin.toml tooling/mutation/src/*.or \
  runtime/core/*.c runtime/core/*.h runtime/platform/*.c runtime/platform/*.h; } | sha256)
if [ ! -x "$RUNNER" ] || [ "$(cat "$OUT/stamp" 2>/dev/null || true)" != "$stamp" ]; then
  mkdir -p "$OUT"
  echo "[mutation] $BUILDER builds tooling/mutation -> $RUNNER" >&2
  "$BUILDER" compile tooling/mutation/src/main.or -o "$OUT/runner.c"
  $CC -O1 -w $(rt_inc) "$OUT/runner.c" $(rt_src) -lm -lpthread -o "$OUT/runner.tmp"
  mv "$OUT/runner.tmp" "$RUNNER"
  echo "$stamp" > "$OUT/stamp"
fi
if [ -n "$BUILD_ONLY" ]; then exit 0; fi
# the OX mutants are judged by the conformance runner: build it once here, not concurrently by the mutants
if [ "${1:-}" = "ox" ]; then ORIN_CONFORMANCE_BUILDER=$BUILDER tools/conformance.sh --build-only; fi
exec "$RUNNER" "$@"
