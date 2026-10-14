#!/bin/sh
# Tooling unit tests (JSON, analysis, LSP handler) built with the self-hosted compiler.
set -eu
cd "$(dirname "$0")/.."
ORIN2=${ORIN2:-build/bootstrap/orin2}
mkdir -p build
for t in path_test json_test analysis_test effects_test lsp_test verify_main package_test; do
  $ORIN2 compile compiler/tests/$t.or -o build/$t.c
  cc -O1 -w -I runtime build/$t.c runtime/orin_runtime.c platform/orin_platform.c -o build/$t
  ./build/$t
done
# diag + loader unit tests (@Test; `orin test` runs them with contract checking)
$ORIN2 test compiler/tests/loader_test.or --runtime runtime
$ORIN2 test compiler/tests/loader_classes_test.or --runtime runtime
# checker unit tests: the env / fnctx foundation (2a) and the body checker's classes (2b)
$ORIN2 test compiler/tests/check_env_test.or --runtime runtime
$ORIN2 test compiler/tests/check_body_test.or --runtime runtime
# lowering unit tests (3a): block builder, locals, owned scope, place walk, MIR spans, Lowerer end to end
$ORIN2 test compiler/tests/lower_test.or --runtime runtime
# syntax unit tests (3c): Lexer, Parser progress and spans, operator table, well-formedness predicates, garbage input
$ORIN2 test compiler/tests/syntax_test.or --runtime runtime
# parser error recovery: several syntax errors per file, first error unchanged, no cascades, cap, termination on garbage
$ORIN2 test compiler/tests/recovery_test.or --runtime runtime
python3 tools/test_recovery.py --orinc "$ORIN2"
$ORIN2 test compiler/tests/quality_test.or --runtime runtime
$ORIN2 test compiler/tests/doccomments_test.or --runtime runtime
# tooling unit tests (3e): JSON cursor / round trip, workspace, positions, index queries, LSP and MCP reply rule,
# MCP session, formatter layout and comment preservation
$ORIN2 test compiler/tests/tooling_test.or --runtime runtime
sh tools/test_resources.sh
sh tools/test_capabilities.sh
sh tools/test_net.sh
# Guard: every compiler unit test file must be run by some test script or CI step (an unwired test
# once failed unnoticed). Fails with the names of the unwired files.
unwired=""
for f in compiler/tests/*_test.or; do
  s=$(basename "$f" .or)
  grep -qw "$s" tools/*.sh tools/*.py .github/workflows/ci.yml || unwired="$unwired $s"
done
[ -z "$unwired" ] || { echo "unit test files not run by any test script:$unwired" >&2; exit 1; }
