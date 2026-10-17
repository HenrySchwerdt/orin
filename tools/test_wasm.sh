#!/bin/sh
# The wasm64-orbit target (ADR-0055) in one command, as CI runs it:
#   1. the float formatting / parsing of the WebAssembly L0 against glibc (tools/test_wasm_float.sh);
#   2. its compiler support routines (orin_builtins_orbit.c) against the native __int128 arithmetic and libm round;
#   3. the conformance suites built as WebAssembly modules and run under Node with the Orbit import contract
#      (tools/run_tests.py --target wasm64-orbit, tools/wasm_run.mjs); a test needing an effect the target lacks is SKIP;
#   4. the size budget of runtime/platform/orbit (900 code lines).
#
#   tools/test_wasm.sh [--orinc COMPILER]      default build/bootstrap/orin2; needs clang with the WebAssembly backend, wasm-ld
#                                              and Node >= 24 ($NODE, default node)
set -eu
cd "$(dirname "$0")/.."
ORINC=build/bootstrap/orin2
[ "${1:-}" != "--orinc" ] || ORINC=$2
NODE=${NODE:-node}
export NODE
major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
[ "$major" -ge 24 ] || { echo "test_wasm: Node >= 24 is required for memory64 and table64 (found: $major)" >&2; exit 1; }
command -v wasm-ld >/dev/null 2>&1 || { echo "test_wasm: wasm-ld is missing (install lld)" >&2; exit 1; }

echo "[wasm] float formatting and parsing vs glibc"
sh tools/test_wasm_float.sh
echo "[wasm] compiler support routines (128-bit helpers, round) vs the native compiler and libm"
mkdir -p build/wasm
cc -O1 runtime/platform/orbit/tests/i128_test.c -o build/wasm/i128_test -lm && build/wasm/i128_test
echo "[wasm] conformance suites as wasm64-orbit modules"
python3 tools/run_tests.py --orinc "$ORINC" --target wasm64-orbit --suite all
echo "[wasm] size budget of runtime/platform/orbit (ADR-0055: <= 900 code lines, counted like tools/verify_platform.sh)"
code=$(python3 - runtime/platform/orbit/*.c runtime/platform/orbit/include/*.h <<'PY'
import re, sys
n = 0
for f in sys.argv[1:]:
    t = re.sub(r'/\*.*?\*/', lambda m: '\n' * m.group(0).count('\n'), open(f).read(), flags=re.S)
    t = re.sub(r'//[^\n]*', '', t)
    n += sum(1 for l in t.split('\n') if l.strip())
print(n)
PY
)
echo "runtime/platform/orbit: $code code lines (budget 900)"
[ "$code" -le 900 ] || { echo "the WebAssembly L0 exceeds its size budget" >&2; exit 1; }
