#!/bin/sh
# The wasm64-orbit and wasm32-orbit targets (ADR-0055) in one command, as CI runs it:
#   1. the float formatting / parsing of the WebAssembly L0 against glibc (tools/test_wasm_float.sh);
#   2. its compiler support routines (orin_builtins_orbit.c) against the native __int128 arithmetic and libm round;
#   3. the conformance suites built as WebAssembly modules and run under Node with the Orbit import contract
#      (tools/run_tests.py --target wasm64-orbit / wasm32-orbit, tools/wasm_run.mjs), once per width; a test needing an effect the target lacks is SKIP,
#      and so is a test whose tasks need to run at the same time or trap (the L0 ends the module with a `wasm{32,64}-orbit: <reason>` line);
#   4. the size budget of runtime/platform/orbit (1100 code lines).
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
echo "[wasm] allocator of the WebAssembly L0 (random malloc/calloc/realloc/free, growth pattern) on a fake heap"
cc -O2 -Wno-attributes runtime/platform/orbit/tests/alloc_test.c -o build/wasm/alloc_test && build/wasm/alloc_test
if echo 'int main(void){return 0;}' | cc -m32 -x c - -o build/wasm/m32_probe 2>/dev/null && build/wasm/m32_probe; then
  echo "[wasm] the same allocator test as a 32-bit program (size_t = 4 bytes, as on wasm32)"
  cc -m32 -O2 -Wno-attributes runtime/platform/orbit/tests/alloc_test.c -o build/wasm/alloc_test32 && build/wasm/alloc_test32
fi
for W in wasm32 wasm64; do
  echo "[wasm] allocator on its real target ($W: real memory.grow; sizes beyond the address space fail instead of wrapping)"
  clang --target=$W-unknown-unknown -mbulk-memory -ffreestanding -nostdlib -O2 -Wall -Wno-unused-function -Iruntime/platform/orbit/include \
    runtime/platform/orbit/tests/alloc_test_wasm.c -Wl,--no-entry -Wl,--export=run -o build/wasm/alloc_test_$W.wasm
  "$NODE" tools/wasm_alloc_run.mjs build/wasm/alloc_test_$W.wasm
done
for W in wasm32 wasm64; do
  echo "[wasm] every __thread object of the runtime lands in the section orin_tls ($W; the L0 switches tasks by copying that block)"
  clang --target=$W-unknown-unknown -mbulk-memory -ffreestanding -nostdlib -O2 -w -Iruntime/platform/orbit/include -Iruntime/core \
    '-D__thread=__attribute__((section("orin_tls")))' -S runtime/core/orin_runtime.c -o build/wasm/runtime-$W.s
  grep -q 'orin_tls' build/wasm/runtime-$W.s || { echo "test_wasm: the runtime has no orin_tls section ($W)" >&2; exit 1; }
  ! grep -q '\.t\(bss\|data\)\|thread_local' build/wasm/runtime-$W.s || { echo "test_wasm: the runtime has thread-local data outside orin_tls ($W)" >&2; exit 1; }
done
echo "[wasm] the RtTask layout orin_platform_thread_exit reads (trapped at 8, msg at 24; fixed-width fields, so the same on both widths) still matches runtime/core/orin_runtime.c"
grep -Pzq 'uint64_t tok;[^\n]*\n\s*int trapped;[^\n]*\n\s*uint64_t done_mon;[^\n]*\n\s*char msg\[TASK_MSG\];' runtime/core/orin_runtime.c ||
  { echo "test_wasm: RtTask changed: adapt orin_platform_thread_exit in runtime/platform/orbit/orin_platform_orbit.c" >&2; exit 1; }
for T in wasm64-orbit wasm32-orbit; do
  echo "[wasm] conformance suites as $T modules"
  python3 tools/run_tests.py --orinc "$ORINC" --target $T --suite all
done
echo "[wasm] size budget of runtime/platform/orbit (ADR-0055: <= 1100 code lines, counted like tools/verify_platform.sh)"
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
echo "runtime/platform/orbit: $code code lines (budget 1100)"
[ "$code" -le 1100 ] || { echo "the WebAssembly L0 exceeds its size budget" >&2; exit 1; }
