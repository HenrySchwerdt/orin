#!/usr/bin/env node
// A minimal Orbit host for tests (ADR-0055): runs an Orin program built with `--target=wasm64-orbit` or `--target=wasm32-orbit` under Node (>= 24, for
// memory64 and table64) with the same import contract as Orbit (orin-lang/orbit, docs/host-abi.md), so the conformance
// suite can run in CI without building Orbit. It is NOT a sandbox and NOT Orbit: Orbit is the runtime; this only serves
// the two capabilities the target uses.
//
//   node tools/wasm_run.mjs <module.wasm> [--deny log/v1|clock/v1]...
//
// Like Orbit it fails closed at load: every import must be an `orbit:` capability it serves with the right shape, and when
// the module carries an `orbit.manifest` section every imported capability must be listed there (exit 2 otherwise).
// orbit:log/v1 write: level >= 4 (error) goes to stderr, everything else to stdout, one line per record.
// Exit status: the result of `orin_main`; after a trap, the status the program passed to exit (export orin_exit_status,
// e.g. 101 for an Orin trap), or 134 for any other trap (stack overflow, out-of-bounds access, abort).
import { readFileSync, writeSync } from 'node:fs';

const [file, ...rest] = process.argv.slice(2);
if (!file) {
  process.stderr.write('usage: node tools/wasm_run.mjs <module.wasm> [--deny CAP]...\n');
  process.exit(2);
}
const denied = new Set();
for (let i = 0; i < rest.length; i++) {
  if (rest[i] === '--deny' && i + 1 < rest.length) denied.add(rest[++i]);
  else { process.stderr.write(`wasm_run: unknown argument ${rest[i]}\n`); process.exit(2); }
}
const fail = (msg) => { process.stderr.write(`wasm_run: ${msg}\n`); process.exit(2); };

let mod;
try { mod = new WebAssembly.Module(readFileSync(file)); } catch (e) { fail(`invalid module: ${e.message}`); }

let memory;
const decoder = new TextDecoder('utf-8', { fatal: true });
const write = (fd, text) => writeSync(fd, text);
const start = process.hrtime.bigint();
const caps = {
  'log/v1': {
    write(level, ptr, len) {
      if (level < 0 || level > 4) return -1;
      const p = Number(ptr), n = Number(len);
      if (p < 0 || n < 0 || n > 16384 || p + n > memory.buffer.byteLength) return -1;
      let text;
      try { text = decoder.decode(new Uint8Array(memory.buffer, p, n)); } catch { return -1; }
      write(level >= 4 ? 2 : 1, text + '\n');
      return 0;
    },
  },
  'clock/v1': {
    now_unix_nanos: () => BigInt(Date.now()) * 1000000n,
    monotonic_nanos: () => process.hrtime.bigint() - start,
  },
};
const manifest = WebAssembly.Module.customSections(mod, 'orbit.manifest');
let listed = null;
if (manifest.length > 1) fail('more than one orbit.manifest section');
if (manifest.length === 1) {
  try { listed = new Set(JSON.parse(new TextDecoder().decode(manifest[0])).requires); } catch (e) { fail(`bad manifest: ${e.message}`); }
}
const imports = {};
for (const imp of WebAssembly.Module.imports(mod)) {
  const m = /^orbit:([a-z]+\/v[0-9]+)$/.exec(imp.module);
  if (!m || imp.kind !== 'function' || !(m[1] in caps) || !(imp.name in caps[m[1]])) {
    fail(`unknown import ${imp.module}.${imp.name} (${imp.kind})`);
  }
  if (listed && !listed.has(m[1])) fail(`manifest mismatch: ${m[1]} is imported but not listed`);
  if (denied.has(m[1])) fail(`capability not granted: ${m[1]}`);
  (imports[imp.module] ??= {})[imp.name] = caps[m[1]][imp.name];
}
// the engine checks the signatures at instantiation: a wrong shape fails with a LinkError

let instance;
try { instance = new WebAssembly.Instance(mod, imports); } catch (e) { fail(`instantiate failed: ${e.message}`); }
memory = instance.exports.memory;
if (!(memory instanceof WebAssembly.Memory) || typeof instance.exports.orin_main !== 'function') {
  fail('the module exports no memory or no orin_main');
}
let status;
try {
  status = instance.exports.orin_main();
} catch (e) {
  if (!(e instanceof WebAssembly.RuntimeError)) throw e;
  status = typeof instance.exports.orin_exit_status === 'function' ? instance.exports.orin_exit_status() : -1;
  if (status < 0) {
    write(2, `trap: ${e.message}\n`);
    status = 134;
  }
}
process.exitCode = status;
