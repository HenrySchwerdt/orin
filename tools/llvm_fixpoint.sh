#!/bin/sh
# LLVM fixed point (ADR-0038 section 8, gate 2). Needs build/bootstrap/orin2 (tools/bootstrap.sh) and clang.
#
#   tools/llvm_fixpoint.sh            stage A: orin2 (C-built) compiles compiler/main.or with --backend=llvm -> a.ll;
#                                     clang links it -> orin2-llvm.
#                                     stage B: orin2-llvm compiles compiler/main.or to C (must equal stage2.c) and to
#                                     LLVM IR (must equal a.ll); clang links b.ll -> orin3-llvm.
#   tools/llvm_fixpoint.sh --deep     also stage C: orin3-llvm compiles to C and LLVM IR again (must still be equal).
#
# The output of a compiler does not depend on how the compiler itself was built, so the C-built and the LLVM-built
# compiler must emit byte-identical C and byte-identical .ll. A difference is a bug in the LLVM backend or its runtime.
# Environment: CLANG (default clang), LLVM_CFLAGS (default -O1 -w; the output does not depend on it, -O1 keeps CI short).
set -eu
cd "$(dirname "$0")/.."
DEEP=
case "${1:-}" in
  "") ;;
  --deep) DEEP=1 ;;
  *) echo "usage: $0 [--deep]" >&2; exit 2 ;;
esac
CLANG=${CLANG:-clang}
LLVM_CFLAGS=${LLVM_CFLAGS:--O1 -w}
B=build/bootstrap
O=build/llvm-fixpoint
for f in $B/orin2 $B/stage2.c; do
  [ -f "$f" ] || { echo "llvm_fixpoint: $f missing; run tools/bootstrap.sh first" >&2; exit 2; }
done
mkdir -p $O
T0=$(date +%s)
elapsed() { echo "$(( $(date +%s) - T0 )) s"; }
link() { $CLANG $LLVM_CFLAGS -I runtime/core "$1" runtime/core/orin_runtime.c runtime/platform/orin_platform.c runtime/core/orin_runtime_llvm.c -lm -o "$2"; }
same() {
  if cmp -s "$1" "$2"; then echo "[compare] $1 == $2 ($(wc -c < "$1") bytes)"
  else echo "[compare] FAIL: $1 and $2 differ" >&2; diff "$1" "$2" | head -20 >&2 || true; exit 1; fi
}

echo "[A] orin2 compiles compiler/main.or --backend=llvm; clang $LLVM_CFLAGS -> orin2-llvm ($(elapsed))"
$B/orin2 compile compiler/main.or --backend=llvm -o $O/a.ll
link $O/a.ll $O/orin2-llvm

echo "[B] orin2-llvm compiles compiler/main.or to C and to LLVM IR ($(elapsed))"
$O/orin2-llvm compile compiler/main.or -o $O/b.c
same $B/stage2.c $O/b.c
$O/orin2-llvm compile compiler/main.or --backend=llvm -o $O/b.ll
same $O/a.ll $O/b.ll

if [ -n "$DEEP" ]; then
  echo "[C] orin3-llvm (built from b.ll) compiles again ($(elapsed))"
  link $O/b.ll $O/orin3-llvm
  $O/orin3-llvm compile compiler/main.or -o $O/c.c
  same $B/stage2.c $O/c.c
  $O/orin3-llvm compile compiler/main.or --backend=llvm -o $O/c.ll
  same $O/a.ll $O/c.ll
fi
echo "[llvm-fixpoint] OK: C and LLVM output of the LLVM-built compiler equal those of the C-built compiler ($(elapsed))"
