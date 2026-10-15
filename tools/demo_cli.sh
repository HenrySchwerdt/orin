#!/bin/sh
# Real CLI output for visual review in a terminal. No screenshots or simulated output.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODE=${1:-all}
case "$MODE" in all|build|tests|errors) ;; *) echo 'usage: tools/demo_cli.sh [all|build|tests|errors]' >&2; exit 2;; esac
"$ROOT/tools/orin" --version >/dev/null
CLI=$ROOT/build/dev-install/bin/orin
mkdir -p "$ROOT/build"
DEMO=$(mktemp -d "$ROOT/build/cli-preview-XXXXXXXX")
cd "$DEMO"
"$CLI" init ledger --quiet
cd ledger
cat > tests/main_test.or <<'TESTS'
import { assertEq } from "std:test";

@Test
function depositIncreasesBalance(): void {
  assertEq(100 + 25, 125, "deposit");
}

@Test
function withdrawalDecreasesBalance(): void {
  assertEq(100 - 30, 70, "withdrawal");
}
TESTS
if [ "$MODE" = all ] || [ "$MODE" = build ]; then
  printf '\n$ orin build\n\n'
  "$CLI" build --color=always
  printf '\n$ orin build\n\n'
  "$CLI" build --color=always
fi
if [ "$MODE" = all ] || [ "$MODE" = tests ]; then
  printf '\n$ orin test\n\n'
  "$CLI" test --color=always
  cat > tests/payments_test.or <<'TESTS'
import { assertEq } from "std:test";

@Test
function rejectsNegativeAmount(): void {
  assertEq(90, 100, "balance must remain unchanged");
}
TESTS
  printf '\n$ orin test\n\n'
  "$CLI" test --color=always || [ "$?" = 1 ]
fi
if [ "$MODE" = all ] || [ "$MODE" = errors ]; then
  cat > broken.or <<'SOURCE'
function transfer(amount: int): void {
  console.log(amount.toString());
}

function main(): void {
  const amount = "42";
  transfer(amount);
}
SOURCE
  printf '\n$ orin check broken.or\n\n'
  "$CLI" check broken.or --color=always || [ "$?" = 1 ]
fi
printf '\nDemo project: %s\n' "$DEMO/ledger"
