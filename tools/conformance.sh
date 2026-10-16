#!/bin/sh
# The conformance test runner (tooling/conformance, an Orin package): builds it when needed and runs it.
# It replaces `python3 tools/run_tests.py` in CI and in the tools; the flags are the same:
#
#   tools/conformance.sh [--orinc COMPILER] [--cc CC] [--filter SUBSTR] [-j N] [--sanitize]
#                        [--suite default|next|all] [--backend c|llvm] [--assert-facts]
#   tools/conformance.sh --build-only        build build/conformance/orin-conformance and stop
#   tools/conformance.sh --unit-tests        run the @Test unit tests of the runner (tooling/conformance/tests)
#
# The runner is compiled by a trusted, already built compiler: $ORIN_CONFORMANCE_BUILDER, else build/bootstrap/orin2,
# else build/dev/orin. It is never compiled by the compiler under test (--orinc), so a broken compiler cannot also
# break its judge. The build is skipped when the compiler, the runner sources, the runtime and the platform layer are
# unchanged (build/conformance/stamp). tools/run_tests.py stays in the repository as the independent oracle:
# tools/check_conformance_parity.py compares the two (docs/testing.md, "Conformance runner").
set -eu
cd "$(dirname "$0")/.."
OUT=build/conformance
RUNNER=$OUT/orin-conformance
BUILD_ONLY=
UNIT_TESTS=
if [ "${1:-}" = "--build-only" ]; then BUILD_ONLY=1; shift; fi
if [ "${1:-}" = "--unit-tests" ]; then UNIT_TESTS=1; shift; fi

BUILDER=${ORIN_CONFORMANCE_BUILDER:-}
if [ -z "$BUILDER" ]; then
  for c in build/bootstrap/orin2 build/dev/orin; do
    if [ -x "$c" ]; then BUILDER=$c; break; fi
  done
fi
if [ -z "$BUILDER" ] || [ ! -x "$BUILDER" ]; then
  echo "conformance: no compiler to build the runner with (run tools/bootstrap.sh or tools/dev.sh, or set ORIN_CONFORMANCE_BUILDER)" >&2
  exit 1
fi

if [ -n "$UNIT_TESTS" ]; then
  for f in tooling/conformance/tests/*_test.or; do
    out=$("$BUILDER" test "$f") || { echo "$out"; echo "conformance: unit tests failed in $f" >&2; exit 1; }
    echo "$f: $(echo "$out" | tail -1)"
  done
  exit 0
fi

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }
CC=${CC:-cc}
stamp=$({ echo "$CC"; cat "$BUILDER" tooling/conformance/orin.toml tooling/conformance/src/*.or \
  runtime/*.c runtime/*.h platform/*.c platform/*.h; } | sha256)
if [ ! -x "$RUNNER" ] || [ "$(cat "$OUT/stamp" 2>/dev/null || true)" != "$stamp" ]; then
  mkdir -p "$OUT"
  echo "[conformance] $BUILDER builds tooling/conformance -> $RUNNER" >&2
  "$BUILDER" compile tooling/conformance/src/main.or -o "$OUT/runner.c"
  $CC -O1 -w -I runtime "$OUT/runner.c" runtime/orin_runtime.c platform/orin_platform.c -lm -o "$OUT/runner.tmp"
  mv "$OUT/runner.tmp" "$RUNNER"
  echo "$stamp" > "$OUT/stamp"
fi
if [ -n "$BUILD_ONLY" ]; then exit 0; fi
exec "$RUNNER" "$@"
