#!/bin/sh
# std:net loopback tests (ADR-0033), Linux and macOS: the example HTTP server on a real socket.
#   1. start examples/http_server.or on a free loopback port; curl: /health, echo, 404, 405
#   2. tools/net_checks.py: keep-alive, pipelining, malformed requests, limits, slowloris (timeout), throughput
#   3. an Orin client (tests/net/client.or) connects through a grant narrowed to the server's port: it works, and every
#      attempt to leave the granted scope (another port, another host, a widened narrowing) is refused
#   4. ORIN_DENY=net: the server cannot listen and says why; the client cannot connect
#   5. a program started with a listen grant for another port cannot be made to listen elsewhere (tests/next/run/net_loopback)
set -eu
cd "$(dirname "$0")/.."
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
  $CC -O2 -w -I runtime/core $B/$2.c runtime/core/orin_runtime.c runtime/platform/orin_platform.c -lm -o $B/$2
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
echo "net ok"
