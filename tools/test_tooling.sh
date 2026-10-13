#!/bin/sh
# Tooling unit tests (JSON, analysis, LSP handler) built with the self-hosted compiler.
set -eu
cd "$(dirname "$0")/.."
ORIN2=${ORIN2:-build/bootstrap/orin2}
mkdir -p build
for t in json_test analysis_test lsp_test verify_main package_test; do
  $ORIN2 compile compiler/tests/$t.or -o build/$t.c
  cc -O1 -w -I runtime build/$t.c runtime/orin_runtime.c platform/orin_platform.c -o build/$t
  ./build/$t
done
