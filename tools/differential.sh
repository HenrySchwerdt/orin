#!/bin/sh
# The differential harness (tooling/differential, an Orin package): builds it when needed and runs it.
# It replaces `python3 tools/diff_backends.py` and `python3 tools/diff_compilers.py` in CI and in the tools; the flags are the same:
#
#   tools/differential.sh --mode opt|llvm|builtins|fuse [--orinc COMPILER] [--cc CC] [--filter SUBSTR] [--sanitize]
#                         [--shard I/N] [--list]
#   tools/differential.sh compilers BASE_ORIN NEW_ORIN
#   tools/differential.sh --build-only        build build/differential/orin-differential and stop
#   tools/differential.sh --unit-tests        run the @Test unit tests of the harness (tooling/differential/tests)
#
# The harness is compiled by a trusted, already built compiler: $ORIN_DIFFERENTIAL_BUILDER, else build/bootstrap/orin2,
# else build/dev/orin. It is never compiled by the compiler under test (--orinc), so a broken compiler cannot also
# break its judge. The build is skipped when the compiler, the harness sources, the runtime and the platform layer are
# unchanged (build/differential/stamp).
set -eu
cd "$(dirname "$0")/.."
OUT=build/differential
RUNNER=$OUT/orin-differential
BUILD_ONLY=
UNIT_TESTS=
if [ "${1:-}" = "--build-only" ]; then BUILD_ONLY=1; shift; fi
if [ "${1:-}" = "--unit-tests" ]; then UNIT_TESTS=1; shift; fi

BUILDER=${ORIN_DIFFERENTIAL_BUILDER:-}
if [ -z "$BUILDER" ]; then
  for c in build/bootstrap/orin2 build/dev/orin; do
    if [ -x "$c" ]; then BUILDER=$c; break; fi
  done
fi
if [ -z "$BUILDER" ] || [ ! -x "$BUILDER" ]; then
  echo "differential: no compiler to build the harness with (run tools/bootstrap.sh or tools/dev.sh, or set ORIN_DIFFERENTIAL_BUILDER)" >&2
  exit 1
fi

if [ -n "$UNIT_TESTS" ]; then
  for f in tooling/differential/tests/*_test.or; do
    out=$("$BUILDER" test "$f") || { echo "$out"; echo "differential: unit tests failed in $f" >&2; exit 1; }
    echo "$f: $(echo "$out" | tail -1)"
  done
  exit 0
fi

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }
CC=${CC:-cc}
stamp=$({ echo "$CC"; cat "$BUILDER" tooling/differential/orin.toml tooling/differential/src/*.or \
  runtime/core/*.c runtime/core/*.h runtime/platform/*.c runtime/platform/*.h; } | sha256)
if [ ! -x "$RUNNER" ] || [ "$(cat "$OUT/stamp" 2>/dev/null || true)" != "$stamp" ]; then
  mkdir -p "$OUT"
  echo "[differential] $BUILDER builds tooling/differential -> $RUNNER" >&2
  "$BUILDER" compile tooling/differential/src/main.or -o "$OUT/runner.c"
  $CC -O1 -w -I runtime/core "$OUT/runner.c" runtime/core/orin_runtime.c runtime/platform/orin_platform.c -lm -o "$OUT/runner.tmp"
  mv "$OUT/runner.tmp" "$RUNNER"
  echo "$stamp" > "$OUT/stamp"
fi
if [ -n "$BUILD_ONLY" ]; then exit 0; fi
exec "$RUNNER" "$@"
