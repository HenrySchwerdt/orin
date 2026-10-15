#!/bin/sh
# Resource handles (ADR-0025): properties the conformance runner cannot see.
#   1. a trap / process.exit inside a scope: the runtime's exit hook flushes and closes the file, so the bytes
#      written before the trap are on disk;
#   2. ORIN_STATS: every opened file was closed (file_opens == file_closes) and no heap object leaks.
set -eu
cd "$(dirname "$0")/.."
ORIN2=${ORIN2:-build/bootstrap/orin2}
mkdir -p build/tests build/resources

build() { # name
  $ORIN2 compile tests/next/run/$1.or -o build/resources/$1.c
  cc -O1 -w -DORIN_STATS_ENABLED -I runtime build/resources/$1.c runtime/orin_runtime.c platform/orin_platform.c -lm -o build/resources/$1
}

fail() { echo "FAIL: $1" >&2; exit 1; }

# 1. exit hook
rm -f build/tests/fs_trap_in_scope.txt build/tests/fs_exit_in_scope.txt
build fs_trap_in_scope
set +e
build/resources/fs_trap_in_scope >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 101 ] || fail "trap exit status $rc, expected 101"
[ "$(cat build/tests/fs_trap_in_scope.txt)" = "written before the trap" ] || fail "bytes written before a trap were lost"
build fs_exit_in_scope
set +e
build/resources/fs_exit_in_scope >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 3 ] || fail "process.exit status $rc, expected 3"
[ "$(cat build/tests/fs_exit_in_scope.txt)" = "written before exit" ] || fail "bytes written before process.exit were lost"

# 2. counters
for t in fs_stream_basic fs_scope_errors fs_borrowed_handles fs_copy_two_files fs_many_files; do
  build $t
  stats=$(ORIN_STATS=1 build/resources/$t 2>&1 >/dev/null </dev/null | grep orin_stats)
  opens=$(echo "$stats" | sed 's/.*"file_opens":\([0-9]*\).*/\1/')
  closes=$(echo "$stats" | sed 's/.*"file_closes":\([0-9]*\).*/\1/')
  live=$(echo "$stats" | sed 's/.*"live_objs_at_exit":\(-*[0-9]*\).*/\1/')
  [ -n "$opens" ] && [ "$opens" -gt 0 ] || fail "$t: no file_opens counter"
  [ "$opens" = "$closes" ] || fail "$t: $opens files opened but $closes closed"
  [ "$live" = 0 ] || fail "$t: $live live objects at exit"
done
echo "resources: exit hook and counters ok"
