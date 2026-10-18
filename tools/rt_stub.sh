#!/bin/sh
# Build the object model stub for the C unit tests of the runtime (ADR-0052 Addendum A, step R3d.3).
#   tools/rt_stub.sh OUT.o [CFLAGS...]
# The allocator, destroy and make_unique of runtime/core are Orin functions (runtime/core/*.or); the code a program is compiled to
# defines their C names for the C shells. The unit tests of the runtime (runtime/core/tests/*.c) link only C files, so they link this
# object too: tools/rt_stub.or compiled to C by the self-hosted compiler ($ORIN2, default build/bootstrap/orin2)
# with `main` renamed and `--rt-wrappers` (ADR-0052 Addendum B section 3: the C-named test wrappers of the task interface, which normal
# programs do not carry; the list is empty until R3e.6 deletes the C monitor, transfer and task functions). CFLAGS (the sanitizer flags of the test) are used for the stub as well. Prints OUT.o.
set -eu
cd "$(dirname "$0")/.."
[ $# -ge 1 ] || { echo "usage: $0 OUT.o [CFLAGS...]" >&2; exit 2; }
OUT=$1; shift
ORIN2=${ORIN2:-build/bootstrap/orin2}
mkdir -p "$(dirname "$OUT")"
C="${OUT%.o}.c"
"$ORIN2" compile --rt-wrappers tools/rt_stub.or -o "$C"
${CC:-cc} -w -O1 -I runtime/core "$@" -Dmain=orin_rt_stub_main -c "$C" -o "$OUT"
echo "$OUT"
