#!/bin/sh
# Tooling unit tests (JSON, analysis, LSP handler) built with the self-hosted compiler.
# Usage: tools/test_tooling.sh [-j N]
#   The cases below are independent and run in parallel (-j N, default: $ORIN_JOBS, else the CPU count); their output is
#   printed in the listed order and the run stops at the first failing case in that order, as the sequential script did.
set -eu
cd "$(dirname "$0")/.."
ORIN2=${ORIN2:-build/bootstrap/orin2}
export ORIN2

# one compiled unit test (run by tools/parallel.py): --unit NAME
if [ "${1:-}" = "--unit" ]; then
  t=$2
  $ORIN2 compile compiler/tests/$t.or -o build/$t.c
  cc -O1 -w -I runtime build/$t.c runtime/orin_runtime.c platform/orin_platform.c -o build/$t
  exec ./build/$t
fi
JOBS=
case "${1:-}" in
  "") ;;
  -j) JOBS="-j $2" ;;
  -j*) JOBS="-j ${1#-j}" ;;
  *) echo "usage: $0 [-j N]" >&2; exit 2 ;;
esac
mkdir -p build
# one line per case, in the order of the output; `first:` starts a slow case before the others (tools/parallel.py)
{
  echo 'python3 tools/test_execution.py --orinc "$ORIN2"'
  for t in path_test json_test analysis_test effects_test lsp_test verify_main package_test; do
    echo "sh tools/test_tooling.sh --unit $t"
  done
  echo '$ORIN2 test compiler/tests/terminal_test.or --runtime runtime'
  # diag + loader unit tests (@Test; `orin test` runs them with contract checking)
  echo '$ORIN2 test compiler/tests/loader_test.or --runtime runtime'
  echo '$ORIN2 test compiler/tests/loader_classes_test.or --runtime runtime'
  # checker unit tests: the env / fnctx foundation (2a) and the body checker's classes (2b)
  echo '$ORIN2 test compiler/tests/check_env_test.or --runtime runtime'
  echo '$ORIN2 test compiler/tests/check_body_test.or --runtime runtime'
  # lowering unit tests (3a): block builder, locals, owned scope, place walk, MIR spans, Lowerer end to end
  echo '$ORIN2 test compiler/tests/lower_test.or --runtime runtime'
  # fusion of array pipelines (ADR-0038 §2): recognisers, chain analysis, verifier on fused MIR
  echo '$ORIN2 test compiler/tests/fuse_test.or --runtime runtime'
  # optimiser and code generator unit tests (3d): passes, inference, pruning, emitters, symbol tables, rule 8
  echo '$ORIN2 test compiler/tests/opt_test.or --runtime runtime'
  echo '$ORIN2 test compiler/tests/emit_test.or --runtime runtime'
  # unboxing (ADR-0038 step 1): the eligibility rule, the verifier's aggregate rules, both backends, the pair release fix
  echo '$ORIN2 test compiler/tests/unbox_test.or --runtime runtime'
  # syntax unit tests (3c): Lexer, Parser progress and spans, operator table, well-formedness predicates, garbage input
  echo '$ORIN2 test compiler/tests/syntax_test.or --runtime runtime'
  # parser error recovery: several syntax errors per file, first error unchanged, no cascades, cap, termination on garbage
  echo '$ORIN2 test compiler/tests/recovery_test.or --runtime runtime'
  echo 'python3 tools/test_recovery.py --orinc "$ORIN2"'
  # verifier unit tests (3b): ownership lattice, State / Worklist / Transfer / Fixpoint, reports, MIR + HIR predicates
  echo '$ORIN2 test compiler/tests/verify_test.or --runtime runtime'
  echo '$ORIN2 test compiler/tests/quality_test.or --runtime runtime'
  echo '$ORIN2 test compiler/tests/doccomments_test.or --runtime runtime'
  # tooling unit tests (3e): JSON cursor / round trip, workspace, positions, index queries, LSP and MCP reply rule,
  # MCP session, formatter layout and comment preservation
  echo '$ORIN2 test compiler/tests/tooling_test.or --runtime runtime'
  echo "first: sh tools/test_resources.sh"
  echo "first: sh tools/test_capabilities.sh"
  echo "first: sh tools/test_net.sh"
} | python3 tools/parallel.py $JOBS
# Guard: every compiler unit test file must be run by some test script or CI step (an unwired test
# once failed unnoticed). Fails with the names of the unwired files.
unwired=""
for f in compiler/tests/*_test.or; do
  s=$(basename "$f" .or)
  grep -qw "$s" tools/*.sh tools/*.py .github/workflows/ci.yml || unwired="$unwired $s"
done
[ -z "$unwired" ] || { echo "unit test files not run by any test script:$unwired" >&2; exit 1; }
