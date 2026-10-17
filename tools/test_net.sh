#!/bin/sh
# std:net loopback tests (ADR-0033), Linux and macOS: the example HTTP server on a real socket.
#   1. start examples/http_server.or on a free loopback port; curl: /health, echo, 404, 405
#   2. tools/net_checks.py: keep-alive, pipelining, malformed requests, limits, slowloris (timeout), throughput
#   3. an Orin client (tests/net/client.or) connects through a grant narrowed to the server's port: it works, and every
#      attempt to leave the granted scope (another port, another host, a widened narrowing) is refused
#   4. ORIN_DENY=net: the server cannot listen and says why; the client cannot connect
#   5. a program started with a listen grant for another port cannot be made to listen elsewhere (tests/next/run/net_loopback)
#   6. concurrent server (ADR-0017 Addendum C, examples/http_server_concurrent.or): a bounded worker pool fed by moved connections.
#      tools/net_concurrent.py (held connections do not block others, 408 at the deadline, a full pool queues instead of dropping,
#      many clients), an Orin client with 64 / 256 parallel tasks (spawnNet), the same server built with ThreadSanitizer when the
#      toolchain has it, and the library-level E0487 rules (tests/net/libcheck)
#   7. interruptible waits and operation-wide deadlines (ADR-0017 Addendum D, tests/net/interrupt.or): a task blocked in accept, recv, send
#      and connect wakes within a bound when its scope is cancelled from another task, a cancelled scope fails new calls at once, a
#      nested scope's cancel reaches only its own tasks, one deadline spans many small reads, writes and a hanging connect; plain and
#      under ThreadSanitizer when the toolchain has it
set -eu
cd "$(dirname "$0")/.."
. tools/runtime_files.sh   # the runtime source list: tools/runtime-sources.txt
ORIN2=${ORIN2:-build/bootstrap/orin2}
CC=${CC:-cc}
B=build/net
mkdir -p $B
fail() { echo "FAIL: $1" >&2; [ -f $B/server.err ] && tail -5 $B/server.err >&2; kill_server; exit 1; }
SERVER_PID=
kill_server() { if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=; fi; }
trap kill_server EXIT

build() { # source name
  $ORIN2 compile $1 -o $B/$2.c
  $CC -O2 -w $(rt_inc) $B/$2.c $(rt_src) -lm -o $B/$2
}
build examples/http_server.or http_server
build tests/net/client.or client

# start a server; $1 = request deadline in ms; sets PORT
start_server() {
  : > $B/server.err
  $B/http_server 0 0 "$1" 1 2> $B/server.err > $B/server.out &
  SERVER_PID=$!
  i=0
  while ! grep -q "listening on" $B/server.err; do
    i=$((i + 1)); [ $i -le 100 ] || fail "the server did not start"
    sleep 0.1
  done
  PORT=$(sed -n 's/.*listening on 127.0.0.1:\([0-9]*\).*/\1/p' $B/server.err | head -n1)
  [ -n "$PORT" ] || fail "no port in the server's output"
}

REQUEST_MS=800
start_server $REQUEST_MS
URL=http://127.0.0.1:$PORT

# 1. curl
[ "$(curl -s --max-time 5 $URL/health)" = "ok" ] || fail "GET /health"
[ "$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' $URL/health)" = 200 ] || fail "GET /health status"
[ "$(curl -s --max-time 5 -d 'hello echo' $URL/echo)" = "hello echo" ] || fail "POST /echo"
[ "$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' $URL/nope)" = 404 ] || fail "404"
[ "$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' -X POST -d x $URL/health)" = 405 ] || fail "405"
head -c 40000 /dev/urandom > $B/blob
curl -s --max-time 5 --data-binary @$B/blob -H 'Content-Type: application/octet-stream' $URL/echo -o $B/blob.back
cmp -s $B/blob $B/blob.back || fail "40 KB binary body echo"
echo "curl: ok"

# 2. raw sockets
python3 tools/net_checks.py $PORT $REQUEST_MS || fail "net_checks.py"

# 3. the Orin client with a narrowed grant
$B/client $PORT > $B/client.out 2>&1 || fail "client exited with an error: $(cat $B/client.out)"
grep -qx "health: status 200 body 3" $B/client.out || fail "client: GET /health: $(cat $B/client.out)"
grep -qx "granted connect: ok" $B/client.out || fail "client: granted connect"
grep -qx "other port: denied" $B/client.out || fail "client: a connect outside the granted port range was not refused"
grep -qx "other host: denied" $B/client.out || fail "client: a connect outside the granted host was not refused"
grep -qx "widened: denied" $B/client.out || fail "client: a widened narrowing was not refused"
! grep -q CONNECTED $B/client.out || fail "client reached a forbidden endpoint"
echo "client scope: ok"
kill_server

# 4. ORIN_DENY=net
set +e
ORIN_DENY=net $B/http_server 0 1 1000 > $B/deny.out 2> $B/deny.err
rc=$?
set -e
[ $rc = 0 ] || fail "denied server: exit $rc"
grep -q "cannot listen: permission denied.*ORIN_DENY" $B/deny.err || fail "denied server did not report the denial: $(cat $B/deny.err)"
! grep -q "listening on" $B/deny.err || fail "the denied server listened"
start_server 1000
set +e
ORIN_DENY=net $B/client $PORT > $B/deny_client.out 2>&1
rc=$?
set -e
[ $rc = 0 ] || fail "denied client: exit $rc"
grep -qx "granted connect: FAIL.*ORIN_DENY.*" $B/deny_client.out || fail "denied client was not refused: $(cat $B/deny_client.out)"
! grep -q "health: status" $B/deny_client.out || fail "denied client got a response"
kill_server
# the family is the only thing denied: a policy for another family does not stop the server
ORIN_DENY=fs,clock $B/http_server 0 1 1000 2> $B/ok.err > /dev/null &
SERVER_PID=$!
i=0; while ! grep -q "listening on" $B/ok.err; do i=$((i + 1)); [ $i -le 100 ] || fail "ORIN_DENY=fs,clock stopped the server"; sleep 0.1; done
kill_server
echo "ORIN_DENY=net: ok"

# 6. the concurrent server
build examples/http_server_concurrent.or http_server_concurrent
build tests/net/parallel_clients.or parallel_clients
WORKERS=4
start_concurrent() { # $1 = binary, $2 = workers; sets PORT
  : > $B/server.err
  $1 0 0 800 1 $2 8 2> $B/server.err > $B/server.out &
  SERVER_PID=$!
  i=0
  while ! grep -q "listening on" $B/server.err; do
    i=$((i + 1)); [ $i -le 100 ] || fail "the concurrent server did not start"
    sleep 0.1
  done
  PORT=$(sed -n 's/.*listening on 127.0.0.1:\([0-9]*\).*/\1/p' $B/server.err | head -n1)
  [ -n "$PORT" ] || fail "no port in the concurrent server's output"
}
start_concurrent $B/http_server_concurrent $WORKERS
[ "$(curl -s --max-time 5 http://127.0.0.1:$PORT/health)" = "ok" ] || fail "concurrent: GET /health"
python3 tools/net_concurrent.py $PORT 800 $WORKERS || fail "net_concurrent.py"
$B/parallel_clients $PORT 64 3000 > $B/parallel.out 2>&1 || fail "parallel_clients 64: $(cat $B/parallel.out)"
grep -qx "parallel: 64 ok" $B/parallel.out || fail "64 parallel clients: $(head -3 $B/parallel.out)"
$B/parallel_clients $PORT 256 40000 > $B/parallel.out 2>&1 || fail "parallel_clients 256: $(cat $B/parallel.out)"
grep -qx "parallel: 256 ok" $B/parallel.out || fail "256 parallel clients: $(head -3 $B/parallel.out)"
kill_server
echo "concurrent server: ok"

# the same server and the same load under ThreadSanitizer (skipped where the toolchain has no TSan)
echo 'int main(void){return 0;}' > $B/tsan_probe.c
if $CC -fsanitize=thread $B/tsan_probe.c -o $B/tsan_probe 2>/dev/null && $B/tsan_probe 2>/dev/null; then
  $ORIN2 compile examples/http_server_concurrent.or -o $B/hsc_tsan.c
  $CC -g -O1 -w -fsanitize=thread -I runtime/core $B/hsc_tsan.c runtime/core/orin_runtime.c runtime/platform/orin_platform.c -lm -lpthread -o $B/hsc_tsan
  TSAN_OPTIONS="halt_on_error=0 exitcode=66 log_path=$B/tsan" start_concurrent $B/hsc_tsan $WORKERS
  python3 tools/net_concurrent.py $PORT 800 $WORKERS || fail "net_concurrent.py under TSan"
  $B/parallel_clients $PORT 64 3000 > $B/parallel.out 2>&1 || fail "parallel_clients under TSan"
  grep -qx "parallel: 64 ok" $B/parallel.out || fail "64 parallel clients under TSan"
  kill_server
  ! ls $B/tsan.* >/dev/null 2>&1 || fail "ThreadSanitizer report: $(head -20 $B/tsan.* | head -30)"
  echo "concurrent server under ThreadSanitizer: ok"
else
  echo "concurrent server under ThreadSanitizer: skipped (no -fsanitize=thread)"
fi

# 7. interruptible waits and operation-wide deadlines
build tests/net/interrupt.or interrupt
timeout 120 $B/interrupt > $B/interrupt.out 2>&1 || fail "interrupt: $(cat $B/interrupt.out)"
grep -qx "interrupt: ok" $B/interrupt.out || fail "interrupt: $(cat $B/interrupt.out)"
cat $B/interrupt.out
echo "interruptible waits and deadlines: ok"
if $CC -fsanitize=thread $B/tsan_probe.c -o $B/tsan_probe 2>/dev/null && $B/tsan_probe 2>/dev/null; then
  $ORIN2 compile tests/net/interrupt.or -o $B/interrupt_tsan.c
  $CC -g -O1 -w -fsanitize=thread -I runtime/core $B/interrupt_tsan.c runtime/core/orin_runtime.c runtime/platform/orin_platform.c -lm -lpthread -o $B/interrupt_tsan
  rm -f $B/tsan_int.*
  TSAN_OPTIONS="halt_on_error=0 exitcode=66 log_path=$B/tsan_int" timeout 300 $B/interrupt_tsan > $B/interrupt_tsan.out 2>&1 || fail "interrupt under TSan: $(cat $B/interrupt_tsan.out)"
  grep -qx "interrupt: ok" $B/interrupt_tsan.out || fail "interrupt under TSan: $(cat $B/interrupt_tsan.out)"
  ! ls $B/tsan_int.* >/dev/null 2>&1 || fail "ThreadSanitizer report: $(head -20 $B/tsan_int.* | head -30)"
  echo "interruptible waits under ThreadSanitizer: ok"
else
  echo "interruptible waits under ThreadSanitizer: skipped (no -fsanitize=thread)"
fi

# library-level rules of the network handle moves: compiled from tests/net/libcheck so that the `$`-named files count as library code
for f in tests/net/libcheck/*.or; do
  want=$(sed -n '1s#// error: ##p' "$f")
  got=$(cd tests/net/libcheck && ../../../$ORIN2 compile "$(basename "$f")" -o ../../../$B/libcheck.c 2>&1 || true)
  echo "$got" | grep -q "error\[$want\]" || fail "$f: expected $want, got: $got"
done
echo "network handle move rules (E0487): ok"
echo "net ok"
