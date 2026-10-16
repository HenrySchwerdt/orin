#!/bin/sh
# Contract dogfooding (ADR-0015): build the compiler itself with `--check-contracts`, so that the
# @Requires / @Ensures / class @Invariant clauses of compiler/ become run-time traps, then
#   1. self-compile compiler/main.or with it: the output must be byte-identical to stage2.c (contracts
#      must not change what the compiler computes, and none may fire on the compiler's own sources),
#   2. run the conformance suites (all: run + errors + next) with it as the compiler under test: every
#      compilation of every test then executes the contracts of the compiler on that input.
# Needs build/bootstrap/orin2 and stage2.c (tools/bootstrap.sh). Usage: tools/test_compiler_contracts.sh [--quick]
#   --quick  only steps 1 and the default suite (tests/run + tests/errors)
set -eu
cd "$(dirname "$0")/.."
ORIN2=${ORIN2:-build/bootstrap/orin2}
B=build/contracts
SUITE=all
[ "${1:-}" = "--quick" ] && SUITE=default
mkdir -p "$B"
echo "[contracts] orin2 --check-contracts compiles compiler/main.or"
$ORIN2 compile compiler/main.or --check-contracts -o $B/orin_cc.c
cc -O2 -w -I runtime/core $B/orin_cc.c runtime/core/orin_runtime.c runtime/platform/orin_platform.c -lm -o $B/orin_cc
# Steps 1 and 2 are independent and run at the same time (the suite runs in parallel itself); the suite's output is
# held back and printed after step 1, so the output is in the same order as when they ran one after the other.
echo "[contracts] suite '$SUITE' with the contract-checked compiler" > $B/suite.out
ORIN_CONFORMANCE_BUILDER=$ORIN2 tools/conformance.sh --orinc $B/orin_cc --suite $SUITE >> $B/suite.out 2>&1 &
SUITE_PID=$!
echo "[contracts] contract-checked compiler self-compiles compiler/main.or"
if ! $B/orin_cc compile compiler/main.or -o $B/self.c; then kill $SUITE_PID 2>/dev/null || true; exit 1; fi
if cmp -s $B/self.c build/bootstrap/stage2.c; then
  echo "[contracts] output identical to stage2.c ($(wc -c < $B/self.c) bytes)"
else
  echo "[contracts] FAIL: output differs from stage2.c"; kill $SUITE_PID 2>/dev/null || true; exit 1
fi
suite_rc=0
wait $SUITE_PID || suite_rc=$?
cat $B/suite.out
[ $suite_rc = 0 ] || exit $suite_rc
# The verifier (compiler/vc) is part of the compiler: run its own tests with the contract-checked build, so that its
# contracts (and its class invariants) are checked on every verification condition it generates (ADR-0036).
if command -v z3 >/dev/null 2>&1; then
  echo "[contracts] contract-checked verifier: tools/test_verify_contracts.py"
  python3 tools/test_verify_contracts.py --require-z3 --orinc $B/orin_cc
fi
