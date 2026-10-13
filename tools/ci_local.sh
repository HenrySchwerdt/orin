#!/bin/sh
# Run the Linux `test` job of .github/workflows/ci.yml locally, step by step, stopping at the
# first failure. Prints one summary line per step. (formal/vscode/macos jobs are not included.)
set -eu
cd "$(dirname "$0")/.."
step() { name=$1; shift; printf '%-34s ' "$name"; out=$("$@" 2>&1) || { echo FAIL; echo "$out" | tail -30; exit 1; }; echo "$out" | tail -1; }
step "stage0 build"            sh -c 'cd bootstrap && cargo build --release -q && cargo test -q 2>&1 | grep "test result"'
step "stage0 suite"            python3 tools/run_tests.py --orinc bootstrap/target/release/orinb
step "stage0 suite (sanitize)" python3 tools/run_tests.py --orinc bootstrap/target/release/orinb --sanitize
step "parser diff"             python3 tools/diff_parsers.py
step "bootstrap (stage0 root)" ./tools/bootstrap.sh --from-stage0
cp build/bootstrap/stage2.c build/stage2-from-stage0.c
step "bootstrap (seed root)"   ./tools/bootstrap.sh
step "roots identical"         sh -c 'cmp build/stage2-from-stage0.c build/bootstrap/stage2.c && echo identical'
step "all suites (sanitize)"   python3 tools/run_tests.py --orinc build/bootstrap/orin2 --suite all --sanitize
step "package smoke"           ./tools/package.sh 0.0.0-ci linux-x86_64
step "diff backends"           python3 tools/diff_backends.py
step "all suites (llvm)"       python3 tools/run_tests.py --orinc build/bootstrap/orin2 --suite all --backend llvm
step "diff llvm"               python3 tools/diff_backends.py --mode llvm
step "diff builtins"           python3 tools/diff_backends.py --mode builtins
step "diff opt"                python3 tools/diff_backends.py --mode opt
step "formatter"               python3 tools/test_fmt.py
step "tooling"                 ./tools/test_tooling.sh
step "lsp"                     python3 tools/test_lsp.py
step "mcp"                     python3 tools/test_mcp.py
step "packages"                ./tools/test_packages.sh
step "verify all"              python3 tools/verify_all.py compiler/main.or
step "contract erasure"        python3 tools/test_contract_erasure.py --orinc build/bootstrap/orin2
step "annotation erasure"      python3 tools/test_annotation_erasure.py --orinc build/bootstrap/orin2
step "annotations, orin test"  python3 tools/test_annotations.py --orinc build/bootstrap/orin2
step "contract verification"   python3 tools/test_verify_contracts.py --require-z3 --orinc build/bootstrap/orin2
step "platform layer"         sh -c 'tools/check_platform_boundary.sh && tools/verify_platform.sh'
echo "ci_local: all steps passed"
