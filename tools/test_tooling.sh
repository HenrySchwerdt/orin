#!/bin/sh
# Tooling unit tests (JSON, analysis, LSP handler) built with the self-hosted compiler.
set -eu
cd "$(dirname "$0")/.."
ORIN2=${ORIN2:-build/bootstrap/orin2}
mkdir -p build
for t in path_test json_test analysis_test lsp_test verify_main package_test; do
  $ORIN2 compile compiler/tests/$t.or -o build/$t.c
  cc -O1 -w -I runtime build/$t.c runtime/orin_runtime.c platform/orin_platform.c -o build/$t
  ./build/$t
done
# diag + loader unit tests (@Test; `orin test` runs them with contract checking)
$ORIN2 test compiler/tests/loader_test.or --runtime runtime
# checker unit tests: the env / fnctx foundation (2a) and the body checker's classes (2b)
$ORIN2 test compiler/tests/check_env_test.or --runtime runtime
$ORIN2 test compiler/tests/check_body_test.or --runtime runtime
$ORIN2 test compiler/tests/quality_test.or --runtime runtime
sh tools/test_resources.sh
sh tools/test_capabilities.sh
