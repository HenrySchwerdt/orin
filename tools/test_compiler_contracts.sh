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
cc -O2 -w -I runtime $B/orin_cc.c runtime/orin_runtime.c platform/orin_platform.c -lm -o $B/orin_cc
echo "[contracts] contract-checked compiler self-compiles compiler/main.or"
$B/orin_cc compile compiler/main.or -o $B/self.c
if cmp -s $B/self.c build/bootstrap/stage2.c; then
  echo "[contracts] output identical to stage2.c ($(wc -c < $B/self.c) bytes)"
else
  echo "[contracts] FAIL: output differs from stage2.c"; exit 1
fi
echo "[contracts] suite '$SUITE' with the contract-checked compiler"
python3 tools/run_tests.py --orinc $B/orin_cc --suite $SUITE
# The verifier (compiler/vc) is part of the compiler: run its own tests with the contract-checked build, so that its
# contracts (and its class invariants) are checked on every verification condition it generates (ADR-0035).
if command -v z3 >/dev/null 2>&1; then
  echo "[contracts] contract-checked verifier: tools/test_verify_contracts.py"
  python3 tools/test_verify_contracts.py --require-z3 --orinc $B/orin_cc
fi
