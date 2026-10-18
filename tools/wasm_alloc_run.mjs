#!/usr/bin/env node
// Runs `run()` of a module built from runtime/platform/orbit/tests/alloc_test_wasm.c (tools/test_wasm.sh); exit 0 when it reports no failed check.
import { readFileSync } from 'node:fs';
const mod = new WebAssembly.Module(readFileSync(process.argv[2]));
const instance = new WebAssembly.Instance(mod, {});
const bad = Number(instance.exports.run());
process.stdout.write(`${process.argv[2]}: ${bad} failed checks\n`);
process.exit(bad === 0 ? 0 : 1);
