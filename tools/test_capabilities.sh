#!/bin/sh
# Capability grants (ADR-0021 Stage A, ADR-0027): behaviour the conformance runner cannot set up because it needs
# an environment variable (the host policy ORIN_DENY), stdin or an exit status check.
#   1. control run: nothing denied, every family works;
#   2. ORIN_DENY=<family>: an operation that returns a Result reports Err("... denied by the host policy"), every
#      other operation traps with exit status 101 and the "capability denied" message, and the command never runs;
#   3. a malformed ORIN_DENY (typo, space, empty element, upper case) traps at start: a typo never silently allows;
#   4. both backends (C and, when clang is available, LLVM).
set -eu
cd "$(dirname "$0")/.."
ORIN2=${ORIN2:-build/bootstrap/orin2}
CC=${CC:-cc}
mkdir -p build/tests build/capabilities

fail() { echo "FAIL: $1" >&2; exit 1; }

build() { # backend name
  b=$1; n=$2
  if [ "$b" = llvm ]; then
    $ORIN2 compile tests/next/deny/$n.or --backend=llvm -o build/capabilities/$n.$b.ll
    $CC -O1 -w -I runtime build/capabilities/$n.$b.ll runtime/orin_runtime.c runtime/orin_runtime_llvm.c platform/orin_platform.c -lm -o build/capabilities/$n.$b
  else
    $ORIN2 compile tests/next/deny/$n.or -o build/capabilities/$n.$b.c
    $CC -O1 -w -I runtime build/capabilities/$n.$b.c runtime/orin_runtime.c platform/orin_platform.c -lm -o build/capabilities/$n.$b
  fi
}

# expect backend name env-value expected-exit stdout-substring stderr-substring
expect() {
  b=$1; n=$2; deny=$3; want_rc=$4; want_out=$5; want_err=$6
  out=build/capabilities/$n.$b.out; err=build/capabilities/$n.$b.err
  set +e
  if [ -n "$deny" ]; then
    ORIN_DENY="$deny" build/capabilities/$n.$b >$out 2>$err </dev/null
  else
    env -u ORIN_DENY build/capabilities/$n.$b >$out 2>$err <tests/next/deny/all_ok.or
  fi
  rc=$?
  set -e
  [ "$rc" = "$want_rc" ] || fail "$b $n ORIN_DENY='$deny': exit $rc, expected $want_rc"
  [ -z "$want_out" ] || grep -qF -- "$want_out" $out || fail "$b $n ORIN_DENY='$deny': stdout lacks '$want_out'"
  [ -z "$want_err" ] || grep -qF -- "$want_err" $err || fail "$b $n ORIN_DENY='$deny': stderr lacks '$want_err'"
}

backends=c
if command -v clang >/dev/null 2>&1; then backends="c llvm"; CC=clang; fi

for b in $backends; do
  for n in all_ok fs_open fs_exists process_args process_shell stdio_read clock_now net_listen; do build $b $n; done

  # 1. control run: everything works (stdin is the file itself: readLine finds a line)
  expect $b all_ok "" 0 "fs true" ""
  expect $b all_ok "" 0 "process 0 0" ""
  expect $b all_ok "" 0 "stdio true" ""
  expect $b all_ok "" 0 "clock true" ""
  expect $b fs_open "" 0 "read: ok" ""
  expect $b fs_open "" 0 "done" ""

  # 2. fs denied: Results are Err, the program keeps running
  expect $b fs_open fs 0 "read: cannot read 'tests/next/deny/fs_open.or': denied by the host policy (ORIN_DENY)" ""
  expect $b fs_open fs 0 "write: cannot write 'build/tests/deny_out.txt': denied by the host policy (ORIN_DENY)" ""
  expect $b fs_open fs 0 "open: cannot open 'tests/next/deny/fs_open.or': denied by the host policy (ORIN_DENY)" ""
  expect $b fs_open fs 0 "done" ""
  expect $b fs_open all 0 "read: cannot read" ""
  expect $b fs_open "clock,fs" 0 "read: cannot read" ""
  # a family that is not denied is unaffected
  expect $b fs_open process,stdio,clock,net 0 "read: ok" ""

  # ... but a bool cannot carry a denial: exists traps
  expect $b fs_exists fs 101 "before" "trap: capability denied: fs exists: denied by the host policy (ORIN_DENY)"
  expect $b fs_exists clock 0 "true" ""
  # process
  expect $b process_args process 101 "before" "trap: capability denied: process args"
  expect $b process_shell process 101 "before" "trap: capability denied: process shell"
  if grep -q "SHELL RAN" build/capabilities/process_shell.$b.out; then fail "$b: a denied shell command ran"; fi
  expect $b process_shell fs 0 "0" ""
  # stdio, clock
  expect $b stdio_read stdio 101 "before" "trap: capability denied: stdio readLine"
  expect $b clock_now clock 101 "before" "trap: capability denied: clock nowMillis"
  expect $b clock_now all 101 "before" "trap: capability denied: clock nowMillis"

  # network (ADR-0033): ORIN_DENY=net refuses listen / connect / resolve with an Err (no trap), other families are unaffected
  expect $b net_listen "" 0 "listen: ok" ""
  expect $b net_listen "" 0 "inside the listener scope" ""
  expect $b net_listen net 0 "listen: permission denied: outside the granted network scope, or denied by the host policy (ORIN_DENY)" ""
  expect $b net_listen net 0 "connect: denied" ""
  expect $b net_listen all 0 "resolve: permission denied" ""
  expect $b net_listen net 0 "done" ""
  if grep -q "inside the listener scope" build/capabilities/net_listen.$b.out; then fail "$b: a denied listener scope ran its body"; fi
  expect $b net_listen fs,process,stdio,clock 0 "listen: ok" ""

  # 3. a malformed policy is rejected as a whole, before any user code runs
  for bad in bogus "fs," ",fs" "fs, process" "FS" "fss" "fs;process"; do
    expect $b fs_open "$bad" 101 "" "trap: invalid ORIN_DENY"
    [ ! -s build/capabilities/fs_open.$b.out ] || fail "$b: user code ran under the malformed policy '$bad'"
  done
done
echo "capabilities ok ($backends)"
