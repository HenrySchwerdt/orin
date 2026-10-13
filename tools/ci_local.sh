#!/bin/sh
# Run the Linux `test` job of .github/workflows/ci.yml locally, step by step, stopping at the
# first failure. Prints one summary line per step. (formal/vscode/macos jobs are not included.)
set -eu
cd "$(dirname "$0")/.."
step() { name=$1; shift; printf '%-34s ' "$name"; out=$("$@" 2>&1) || { echo FAIL; echo "$out" | tail -30; exit 1; }; echo "$out" | tail -1; }
step "bootstrap (seed root)"   ./tools/bootstrap.sh
step "all suites (sanitize)"   python3 tools/run_tests.py --orinc build/bootstrap/orin2 --suite all --sanitize
step "package smoke"           ./tools/package.sh 0.0.0-ci linux-x86_64
step "all suites (llvm)"       python3 tools/run_tests.py --orinc build/bootstrap/orin2 --suite all --backend llvm
step "diff llvm"               python3 tools/diff_backends.py --mode llvm
step "diff builtins"           python3 tools/diff_backends.py --mode builtins
step "diff opt"                python3 tools/diff_backends.py --mode opt
step "formatter"               python3 tools/test_fmt.py
step "tooling"                 ./tools/test_tooling.sh
step "lsp"                     python3 tools/test_lsp.py
step "mcp"                     python3 tools/test_mcp.py
step "packages"                ./tools/test_packages.sh
step "osig graph/diff"         python3 tools/test_osig.py --orin build/bootstrap/orin2
step "compiler contracts"      tools/test_compiler_contracts.sh
step "verify all"              python3 tools/verify_all.py compiler/main.or
step "contract erasure"        python3 tools/test_contract_erasure.py --orinc build/bootstrap/orin2
step "annotation erasure"      python3 tools/test_annotation_erasure.py --orinc build/bootstrap/orin2
step "annotations, orin test"  python3 tools/test_annotations.py --orinc build/bootstrap/orin2
step "provable std (tests+mutants)" tools/test_std.sh --mutate
step "contract verification"   python3 tools/test_verify_contracts.py --require-z3 --orinc build/bootstrap/orin2
step "platform layer"         sh -c 'tools/check_platform_boundary.sh && tools/verify_platform.sh'
step "runtime unit tests"      sh -c 'cc -g -fsanitize=address,undefined -I runtime runtime/tests/runtime_test.c runtime/orin_runtime.c platform/orin_platform.c -lm -o build/runtime_test && build/runtime_test'
step "mutation corpus"         python3 tools/mutate_mir.py
# The differential test needs Lean (the CI `formal` job); skipped when elan/lake is not installed.
if PATH="$HOME/.elan/bin:$PATH" command -v lake >/dev/null 2>&1; then
  step "formal (check.sh, exe)"  sh -c 'export PATH="$HOME/.elan/bin:$PATH"; cd formal && ./check.sh | tail -1 && lake build orin_check | tail -1'
  step "diff verifier vs Lean"   python3 tools/diff_verifier_lean.py
else
  echo "diff verifier vs Lean      SKIPPED (lake not installed; runs in the CI formal job)"
fi
echo "ci_local: all steps passed"
