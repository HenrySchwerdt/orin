#!/bin/sh
# Server acceptance campaign (work package C5; docs/roadmaps/async-concurrency.md "Server acceptance campaign", ADR-0017 Addenda B-D).
# Runs against examples/http_server.or, the concurrent server (a bounded worker pool fed by moved connections), built for both
# backends (C and LLVM) and, where the toolchain has them, under ThreadSanitizer and AddressSanitizer + UBSan:
#   1. client load      1, 64 and 1,024 concurrent clients (tests/net/parallel_clients.or, one task and one connection each); every
#                       answer is the one for its own request, none is dropped; the server's descriptor count returns to its baseline
#   2. hostile peers    tools/net_hostile.py: slowloris (cut off at the request deadline), non-reading peers (cut off at the send
#                       deadline, the worker freed), clients that vanish or reset mid-request
#   3. cancellation     tests/net/storm.or: 192 tasks blocked in accept, recv and send, a scope cancelled at once, three rounds; all wake
#      storms           with Cancelled within a bound; the process's descriptor count after the storms equals the one before
#   4. graceful         POST /shutdown (admin mode) cancels the accepting scope's CancelToken: the connection held open is still served,
#      shutdown         the server exits with status 0 having served everything it accepted, and the port is then refused
#   5. parity           the C and the LLVM build give the same results (checked line by line, the same load and the same checks)
#   6. sanitizers       ThreadSanitizer: 64-client load, hostile peers, shutdown, the storm. ASan + UBSan: the same. Skipped, with a
#                       message, where the toolchain does not have them
# The whole campaign takes about a minute and a half on a 4-core machine. 1,024 clients need ~1,100 descriptors in the client process:
# the script raises `ulimit -n` and skips that load, with a message, if it cannot. Results go to build/campaign/results.txt.
#   tools/test_server_campaign.sh [--quick]     --quick: no 1,024-client load and no sanitizers
# Linux and macOS (the descriptor checks need /proc and are skipped elsewhere; the accept backlog of macOS is capped at 128 and the
# client retries a connect that was reset, see tests/net/parallel_clients.or).
set -eu
cd "$(dirname "$0")/.."
. tools/runtime_files.sh
ORIN2=${ORIN2:-build/bootstrap/orin2}
CC=${CC:-cc}
B=build/campaign
rm -rf $B
mkdir -p $B
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1
RESULTS=$B/results.txt
: > $RESULTS
SERVER_PID=
kill_server() { if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=; fi; }
fail() { echo "FAIL: $1" >&2; for f in $B/server.err; do [ -f $f ] && tail -8 $f >&2; done; kill_server; exit 1; }
trap kill_server EXIT
note() { echo "$1"; echo "$1" >> $RESULTS; }
now_ms() { python3 -c 'import time; print(int(time.monotonic()*1000))'; }

# --- descriptors: 1,024 clients need more than the usual soft limit of 1,024 (or 256 on macOS)
NEED_FDS=4096
if [ "$(ulimit -n)" != unlimited ] && [ "$(ulimit -n)" -lt $NEED_FDS ]; then
  ulimit -n $NEED_FDS 2>/dev/null || ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
fi
FDS=$(ulimit -n)
BIG=1
if [ "$QUICK" = 1 ]; then BIG=0; note "skipped: 1,024-client load (--quick)"; fi
if [ "$FDS" != unlimited ] && [ "$FDS" -lt 1600 ]; then
  BIG=0
  note "skipped: 1,024-client load (ulimit -n is $FDS and cannot be raised to 1,600 or more)"
fi
if [ -d /proc/self/fd ]; then HAVE_PROC=1; else HAVE_PROC=0; note "descriptor counts skipped: no /proc"; fi
nfds() { ls /proc/$1/fd 2>/dev/null | wc -l; }

# --- the toolchain: sanitizers
ARCH=$(uname -m)
TSAN_RUN=""
if command -v setarch >/dev/null 2>&1 && setarch "$ARCH" -R true >/dev/null 2>&1; then TSAN_RUN="setarch $ARCH -R"; fi
echo 'int main(void){return 0;}' > $B/probe.c
HAVE_TSAN=0; HAVE_ASAN=0; HAVE_LLVM=0
if [ "$QUICK" = 0 ]; then
  if $CC -fsanitize=thread $B/probe.c -o $B/probe_t 2>/dev/null && $TSAN_RUN $B/probe_t 2>/dev/null; then HAVE_TSAN=1; fi
  if $CC -fsanitize=address,undefined $B/probe.c -o $B/probe_a 2>/dev/null && $B/probe_a 2>/dev/null; then HAVE_ASAN=1; fi
fi
LLVM_CC=${LLVM_CC:-clang}
if command -v $LLVM_CC >/dev/null 2>&1 && $LLVM_CC -x c -c $B/probe.c -o $B/probe_l.o 2>/dev/null; then HAVE_LLVM=1; fi
[ $HAVE_LLVM = 1 ] || note "skipped: LLVM backend (no clang)"
[ "$QUICK" = 1 ] || [ $HAVE_TSAN = 1 ] || note "skipped: ThreadSanitizer (no usable -fsanitize=thread)"
[ "$QUICK" = 1 ] || [ $HAVE_ASAN = 1 ] || note "skipped: AddressSanitizer (no usable -fsanitize=address,undefined)"

# --- builds (in parallel)
T0=$(now_ms)
build_c() { # source name [extra cc flags]
  src=$1; name=$2; shift 2
  $ORIN2 compile $src -o $B/$name.c && $CC -O2 -w $(rt_inc) $B/$name.c $(rt_src) -lm -lpthread "$@" -o $B/$name
}
build_ll() {
  src=$1; name=$2
  $ORIN2 compile $src --backend=llvm -o $B/$name.ll && $LLVM_CC -O2 -w $(rt_inc) $B/$name.ll $(rt_src) $(rt_llvm) -lm -lpthread -o $B/$name
}
build_san() { # source name flags...
  src=$1; name=$2; shift 2
  $ORIN2 compile $src -o $B/$name.c && $CC -g -O1 -w "$@" $(rt_inc) $B/$name.c $(rt_src) -lm -lpthread -o $B/$name
}
build_c examples/http_server.or srv_c &
build_c tests/net/parallel_clients.or clients &
build_c tests/net/storm.or storm_c &
if [ $HAVE_LLVM = 1 ]; then build_ll examples/http_server.or srv_ll & build_ll tests/net/storm.or storm_ll & fi
wait
if [ $HAVE_TSAN = 1 ]; then
  build_san examples/http_server.or srv_tsan -fsanitize=thread &
  build_san tests/net/storm.or storm_tsan -fsanitize=thread &
fi
if [ $HAVE_ASAN = 1 ]; then
  build_san examples/http_server.or srv_asan -fsanitize=address,undefined -fno-sanitize-recover=undefined &
  build_san tests/net/storm.or storm_asan -fsanitize=address,undefined -fno-sanitize-recover=undefined &
fi
wait
for f in srv_c clients storm_c; do [ -x $B/$f ] || fail "build of $f failed"; done
[ $HAVE_LLVM = 0 ] || for f in srv_ll storm_ll; do [ -x $B/$f ] || fail "LLVM build of $f failed"; done
[ $HAVE_TSAN = 0 ] || for f in srv_tsan storm_tsan; do [ -x $B/$f ] || fail "TSan build of $f failed"; done
[ $HAVE_ASAN = 0 ] || for f in srv_asan storm_asan; do [ -x $B/$f ] || fail "ASan build of $f failed"; done
note "builds: $(( ($(now_ms) - T0) / 1000 )) s"

WORKERS=8
QUEUE=16
REQUEST_MS=800
SEND_MS=1500
# start_server BINARY [ENV...]: sets PORT and SERVER_PID
PFX=   # a command prefix (setarch -R for ThreadSanitizer)
start_server() {
  bin=$1; shift
  : > $B/server.err
  env "$@" $PFX $bin 0 0 $REQUEST_MS 0 $WORKERS $QUEUE 1 $SEND_MS 2> $B/server.err > $B/server.out &
  SERVER_PID=$!
  i=0
  while ! grep -q "listening on" $B/server.err; do
    i=$((i + 1)); [ $i -le 200 ] || fail "the server $bin did not start"
    sleep 0.1
  done
  PORT=$(sed -n 's/.*listening on 127.0.0.1:\([0-9]*\).*/\1/p' $B/server.err | head -n1)
  [ -n "$PORT" ] || fail "no port in the server's output"
}
# stop_server TAG: asks for the graceful shutdown (it has happened already when the shutdown check ran), waits, checks the status
stop_server() {
  i=0
  while kill -0 $SERVER_PID 2>/dev/null; do
    i=$((i + 1)); [ $i -le 300 ] || fail "$1: the server did not exit within 30 s of the shutdown"
    sleep 0.1
  done
  rc=0; wait $SERVER_PID || rc=$?
  SERVER_PID=
  [ $rc = 0 ] || fail "$1: the server exited with status $rc: $(tail -5 $B/server.err)"
  grep -Eq "^accepted ([0-9]+), served \1\$" $B/server.err || fail "$1: accepted != served at shutdown: $(tail -3 $B/server.err)"
}
# load TAG N BODY: N parallel clients, every answer checked
load() {
  t=$(now_ms)
  timeout 90 $B/clients $PORT $2 $3 > $B/load.out 2>&1 || fail "$1: $2 clients: $(head -3 $B/load.out)"
  grep -qx "parallel: $2 ok" $B/load.out || fail "$1: $2 clients: $(head -3 $B/load.out)"
  d=$(( $(now_ms) - t ))
  note "$1: $2 clients ok in $d ms"
}
# loads TAG: 1, 64 and (if possible) 1,024 clients, and the descriptors of the server before and after
loads() {
  tag=$1; maxn=$2
  [ $HAVE_PROC = 0 ] || before=$(nfds $SERVER_PID)
  load $tag 1 100
  load $tag 64 2000
  if [ "$maxn" = 1024 ]; then load $tag 1024 300; fi
  if [ $HAVE_PROC = 1 ]; then
    sleep 1   # the workers close their last connections
    after=$(nfds $SERVER_PID)
    [ "$after" -le "$before" ] || fail "$tag: the server leaked descriptors under load ($before before, $after after)"
    note "$tag: server descriptors $before before, $after after the load"
  fi
}
hostile() { # TAG, then checks
  tag=$1; shift
  python3 tools/net_hostile.py $PORT $REQUEST_MS $SEND_MS $WORKERS "$@" > $B/hostile.out 2>&1 || { cat $B/hostile.out >&2; fail "$tag: hostile peers ($*)"; }
  sed "s/^/$tag: /" $B/hostile.out | tee -a $RESULTS
  if [ $HAVE_PROC = 1 ] && [ "$1" != shutdown ]; then
    sleep 1
    n=$(nfds $SERVER_PID)
    [ "$n" -le "$FD_BASE" ] || fail "$tag: the server holds $n descriptors after the hostile peers ($FD_BASE at the start)"
  fi
}
storm() { # TAG BINARY N ROUNDS [ENV...]
  tag=$1; bin=$2; n=$3; rounds=$4; shift 4
  env "$@" $PFX $bin $n $rounds > $B/storm.out 2>&1 &
  sp=$!
  i=0
  while ! grep -q fds-start $B/storm.out 2>/dev/null; do i=$((i + 1)); [ $i -le 200 ] || { kill $sp 2>/dev/null; fail "$tag: storm did not start"; }; sleep 0.1; done
  [ $HAVE_PROC = 0 ] || f0=$(nfds $sp)
  i=0
  while ! grep -q fds-end $B/storm.out 2>/dev/null; do i=$((i + 1)); [ $i -le 900 ] || { kill $sp 2>/dev/null; fail "$tag: storm hung: $(cat $B/storm.out)"; }; sleep 0.1; done
  [ $HAVE_PROC = 0 ] || f1=$(nfds $sp)
  rc=0; wait $sp || rc=$?
  grep -qx "storm: ok" $B/storm.out || fail "$tag: $(cat $B/storm.out)"
  [ $rc = 0 ] || fail "$tag: the storm exited with status $rc"
  sed "s/^round/$tag: round/" $B/storm.out | grep ": round" | tee -a $RESULTS
  if [ $HAVE_PROC = 1 ]; then
    [ "$f1" -le "$f0" ] || fail "$tag: the storm leaked descriptors ($f0 before, $f1 after)"
    note "$tag: process descriptors $f0 before the storms, $f1 after"
  fi
}

# one full pass against a server binary
campaign() { # TAG BINARY maxClients [ENV...]
  tag=$1; bin=$2; maxn=$3; shift 3
  start_server $bin "$@"
  [ "$(curl -s --max-time 5 http://127.0.0.1:$PORT/health)" = "ok" ] || fail "$tag: GET /health"
  [ $HAVE_PROC = 0 ] || FD_BASE=$(nfds $SERVER_PID)
  loads $tag $maxn
  hostile $tag slowloris nonreading abrupt
  hostile $tag shutdown
  stop_server $tag
  note "$tag: graceful shutdown: exit 0, accepted == served"
}
quick_campaign() { # TAG BINARY [ENV...]: the sanitizer pass: 64 clients, slowloris, abrupt peers, shutdown
  tag=$1; bin=$2; shift 2
  start_server $bin "$@"
  [ "$(curl -s --max-time 10 http://127.0.0.1:$PORT/health)" = "ok" ] || fail "$tag: GET /health"
  [ $HAVE_PROC = 0 ] || FD_BASE=$(nfds $SERVER_PID)
  load $tag 64 2000
  hostile $tag slowloris abrupt
  hostile $tag shutdown
  stop_server $tag
}

N1024=$([ $BIG = 1 ] && echo 1024 || echo 64)
campaign "C" $B/srv_c $N1024
storm "C storm" $B/storm_c 192 3
if [ $HAVE_LLVM = 1 ]; then
  campaign "LLVM" $B/srv_ll $N1024
  storm "LLVM storm" $B/storm_ll 192 3
  # parity: the same checks produced the same lines (numbers aside)
  strip() { sed -E "s/^$1( storm)?: //; s/[0-9]+(\.[0-9]+)? (ms|s)/N/g; s/[0-9]+\.[0-9]+/N/g"; }
  grep -E "^C( storm)?: " $RESULTS | strip C | grep -v "descriptors\|builds" | sort > $B/parity.c
  grep -E "^LLVM( storm)?: " $RESULTS | strip LLVM | grep -v "descriptors\|builds" | sort > $B/parity.ll
  diff $B/parity.c $B/parity.ll > $B/parity.diff || { cat $B/parity.diff >&2; fail "C and LLVM results differ"; }
  note "parity: the C and LLVM builds produced the same $(wc -l < $B/parity.c | tr -d ' ') result lines"
fi
if [ $HAVE_TSAN = 1 ]; then
  rm -f $B/tsan.*
  PFX="$TSAN_RUN"
  quick_campaign "TSan" $B/srv_tsan TSAN_OPTIONS="halt_on_error=0 exitcode=66 log_path=$B/tsan"
  storm "TSan storm" $B/storm_tsan 32 2 TSAN_OPTIONS="halt_on_error=0 exitcode=66 log_path=$B/tsan"
  ! ls $B/tsan.* >/dev/null 2>&1 || fail "ThreadSanitizer report: $(head -30 $B/tsan.* | head -40)"
  PFX=
  note "TSan: no report"
fi
if [ $HAVE_ASAN = 1 ]; then
  quick_campaign "ASan" $B/srv_asan ASAN_OPTIONS="detect_leaks=1:abort_on_error=0:exitcode=67" UBSAN_OPTIONS="print_stacktrace=1"
  storm "ASan storm" $B/storm_asan 48 2 ASAN_OPTIONS="detect_leaks=1:exitcode=67" UBSAN_OPTIONS="print_stacktrace=1"
  note "ASan+UBSan: no report"
fi
note "campaign ok ($(( ($(now_ms) - T0) / 1000 )) s in all)"
echo "server campaign ok"
