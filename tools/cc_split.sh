#!/bin/sh
# Build an executable from the split C that `orin compile X.or -o BASE.c --split N` writes (BASE.h, BASE.data.c,
# BASE.0.c .. BASE.<N-1>.c), compiling the translation units, the runtime and the platform layer in parallel.
#
#   tools/cc_split.sh BASE.c OUT [CFLAGS...] [-- LDFLAGS...]
#
# $CC (default cc) and $JOBS (default: the CPU count) apply. The objects go next to the sources and are removed after
# the link. Used by tools/bootstrap.sh, tools/dev.sh and tools/test_split.sh.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
base=${1%.c}
out=$2
shift 2
cflags=
ldflags=
inld=
for a in "$@"; do
  if [ "$a" = "--" ]; then inld=1; continue; fi
  if [ -n "$inld" ]; then ldflags="$ldflags $a"; else cflags="$cflags $a"; fi
done
CC=${CC:-cc}
JOBS=${JOBS:-$( (nproc || sysctl -n hw.ncpu) 2>/dev/null || echo 2)}
units=$(ls "$base".data.c "$base".[0-9]*.c)
objs=
for u in $units; do objs="$objs ${u%.c}.o"; done
objs="$objs $base.rt0.o $base.rt1.o"
{
  for u in $units; do echo "$u ${u%.c}.o"; done
  echo "$here/runtime/core/orin_runtime.c $base.rt0.o"
  echo "$here/runtime/platform/orin_platform.c $base.rt1.o"
} | CC=$CC CFLAGS=$cflags RTINC="$here/runtime/core" xargs -P "$JOBS" -L 1 sh -c '$CC $CFLAGS -I "$RTINC" -c "$0" -o "$1"'
$CC $cflags $objs $ldflags -o "$out"
rm -f $objs
