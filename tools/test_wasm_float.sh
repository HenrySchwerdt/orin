#!/bin/sh
# Differential test of the wasm (orbit) float formatting/parsing against glibc. See runtime/platform/orbit/orin_float_orbit.c.
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/wasm
cc -O2 runtime/platform/orbit/tests/float_test.c -o build/wasm/float_test -lm
build/wasm/float_test
