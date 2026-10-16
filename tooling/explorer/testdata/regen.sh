#!/bin/sh
# Regenerate the snapshots, the diff and the golden site of the explorer tests from the fixture packages shop/base and
# shop/head (run after a deliberate change of the explorer, the OSIG schema or the fixtures; review `git diff`).
# Usage: tooling/explorer/testdata/regen.sh
set -eu
cd "$(dirname "$0")/../../.."
ORIN2=${ORIN2:-build/bootstrap/orin2}
T=tooling/explorer/testdata
$ORIN2 graph $T/shop/base -o $T/shop.base.graph.json
$ORIN2 graph $T/shop/head -o $T/shop.head.graph.json
$ORIN2 diff --base $T/shop.base.graph.json --head $T/shop.head.graph.json --format=json -o $T/shop.diff.json
$ORIN2 compile tooling/explorer -o build/explorer/ex.c
cc -O1 -w -I runtime build/explorer/ex.c runtime/orin_runtime.c platform/orin_platform.c -lm -o build/explorer/explore
rm -rf $T/golden
build/explorer/explore $T/shop.head.graph.json --diff $T/shop.diff.json --out $T/golden
