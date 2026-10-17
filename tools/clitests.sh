#!/bin/sh
# The CLI test harness (tooling/clitests, an Orin package): builds it when needed and runs it.
# It replaces `python3 tools/test_osig.py` and `python3 tools/test_fmt.py` in CI and in the tools; the flags are the same:
#
#   tools/clitests.sh osig [--orin PATH] [--update]                   orin graph / orin diff (OSIG) against tests/osig
#   tools/clitests.sh fmt [--orin2 PATH] [--no-build] [--jobs N] [-v]  orin fmt and orin check --format=json
#   tools/clitests.sh --build-only        build build/clitests/orin-clitests and stop
#   tools/clitests.sh --unit-tests        run the @Test unit tests of the harness (tooling/clitests/tests)
#
# `osig` tests the compiler named by --orin (default build/bootstrap/orin2). `fmt` builds compiler/main.or and
# compiler/tests/parse_main.or with --orin2 (default build/bootstrap/orin2) into build/fmt/ first, like the Python script.
#
# The harness is compiled by a trusted, already built compiler: $ORIN_CLITESTS_BUILDER, else build/bootstrap/orin2,
# else build/dev/orin. It is never compiled by the compiler under test (--orin), so a broken compiler cannot also
# break its judge. The build is skipped when the compiler, the harness sources, the runtime and the platform layer are
# unchanged (build/clitests/stamp).
set -eu
cd "$(dirname "$0")/.."
. tools/runtime_files.sh   # the runtime source list: tools/runtime-sources.txt
OUT=build/clitests
RUNNER=$OUT/orin-clitests
BUILD_ONLY=
UNIT_TESTS=
if [ "${1:-}" = "--build-only" ]; then BUILD_ONLY=1; shift; fi
if [ "${1:-}" = "--unit-tests" ]; then UNIT_TESTS=1; shift; fi

BUILDER=${ORIN_CLITESTS_BUILDER:-}
if [ -z "$BUILDER" ]; then
  for c in build/bootstrap/orin2 build/dev/orin; do
    if [ -x "$c" ]; then BUILDER=$c; break; fi
  done
fi
if [ -z "$BUILDER" ] || [ ! -x "$BUILDER" ]; then
  echo "clitests: no compiler to build the harness with (run tools/bootstrap.sh or tools/dev.sh, or set ORIN_CLITESTS_BUILDER)" >&2
  exit 1
fi

if [ -n "$UNIT_TESTS" ]; then
  for f in tooling/clitests/tests/*_test.or; do
    out=$("$BUILDER" test "$f") || { echo "$out"; echo "clitests: unit tests failed in $f" >&2; exit 1; }
    echo "$f: $(echo "$out" | tail -1)"
  done
  exit 0
fi

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }
CC=${CC:-cc}
stamp=$({ echo "$CC"; cat "$BUILDER" tooling/clitests/orin.toml tooling/clitests/src/*.or \
  runtime/core/*.c runtime/core/*.h runtime/platform/*.c runtime/platform/*.h; } | sha256)
if [ ! -x "$RUNNER" ] || [ "$(cat "$OUT/stamp" 2>/dev/null || true)" != "$stamp" ]; then
  mkdir -p "$OUT"
  echo "[clitests] $BUILDER builds tooling/clitests -> $RUNNER" >&2
  "$BUILDER" compile tooling/clitests/src/main.or -o "$OUT/runner.c"
  $CC -O1 -w $(rt_inc) "$OUT/runner.c" $(rt_src) -lm -o "$OUT/runner.tmp"
  mv "$OUT/runner.tmp" "$RUNNER"
  echo "$stamp" > "$OUT/stamp"
fi
if [ -n "$BUILD_ONLY" ]; then exit 0; fi
exec "$RUNNER" "$@"
