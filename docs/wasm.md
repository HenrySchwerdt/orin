# WebAssembly: running Orin programs in Orbit

Orin compiles programs to WebAssembly modules for [Orbit](https://github.com/orin-lang/orbit), Orin's isolate runtime.
Design and measurements: [ADR-0055](decisions/0055-webassembly-target-orbit.md).

```sh
orin build --target=wasm64-orbit                   # -> build/dev/<name>.wasm (build/release/ with --release)
orbit inspect build/dev/hello.wasm                 # imports, exports, the capability manifest
orbit run build/dev/hello.wasm --grant log/v1 --invoke orin_main
```

Needs a clang with the WebAssembly backend and `wasm-ld`: the pinned LLVM (`orin toolchain install`) has both; on Ubuntu the
system `clang` plus the `lld` package also works (`CC=clang`).

## What the module looks like

- **wasm64** (Memory64), freestanding: no WASI, no libc imports. The only imports are Orbit capabilities the program reaches:
  `orbit:log/v1` (console output, trap messages) and `orbit:clock/v1` (time).
- **Exports:** `memory`; `orin_main() -> i32` runs `main` and returns the exit status; `orin_exit_status() -> i32` gives the
  status passed to `exit` after a trap (101 for an Orin trap such as an out-of-bounds index), or -1 for any other trap.
- **Manifest:** a custom section `orbit.manifest`, e.g. `{"abi":1,"requires":["log/v1"],"producer":"orin"}`, derived from the
  program's effects (`orin effects`). It describes what the program needs; Orbit grants nothing because of it.

## What works, and what does not

| Feature | On `wasm64-orbit` |
|---|---|
| the language, std collections, strings, floats, closures, generics, traps | as native (the conformance suites pass as modules) |
| `console.log`, stderr | one log record per line (stdout = info, stderr = error) |
| time (`std:time`, clocks) | `orbit:clock/v1`; the host may coarsen it |
| `process.args` | `["main"]`; no environment; stdin is empty |
| `std:fs`, `std:net`, process spawning | not available: the build fails with E0523 naming the effect and where it comes from |
| `std:task`, channels, `.parallel()` | not available yet (E0523); planned as sequential execution |

## Testing

`tools/test_wasm.sh` runs the conformance suites as WebAssembly modules under Node >= 24 (`tools/wasm_run.mjs` serves the same
two capabilities with Orbit's load-time checks), plus the differential tests of the WebAssembly L0 and its size budget. One
suite only: `NODE=node python3 tools/run_tests.py --orinc build/bootstrap/orin2 --target wasm64-orbit --suite all`.
