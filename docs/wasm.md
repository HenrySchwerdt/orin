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
| `std:task`, channels, `.parallel()` | run, one task at a time, to completion, inside the one WebAssembly thread (see below) |

## Tasks and channels: one at a time

A WebAssembly instance has one thread, so the module runs `std:task` tasks one after the other, each to completion. `spawn`
only queues a task. A queued task runs when someone would otherwise block: `join` of it, or any wait on a channel, scope or
monitor (the waiting task gives the thread to the next queued task and re-checks its condition afterwards); tasks nobody
joined run before `main` ends. So these work as natively: spawn-and-join, `scope`, `.parallel()` (with one core), channels
whose sender never waits for the receiver (the capacity is large enough, or the producer is joined before the consumer
reads), fan-out and fan-in.

Two things do not work, and both end the module with a line that starts with `wasm64-orbit: ` on stderr instead of
hanging or giving a wrong answer:

- **Interleaving.** A task that waits for something only a task suspended below it can produce (ping-pong over bounded
  channels, a producer that blocks on a full channel while the consumer waits for the next item) cannot be resumed
  without stack switching: `wasm64-orbit: deadlock: ...`, trap, exit status 134.
- **A task that traps.** Natively the trap ends the task and the joiner sees it (`panic reaches join`). WebAssembly cannot
  unwind the task's frames, so the whole module ends: `wasm64-orbit: a task trapped: <message>`, exit status 101.

Because the spawned closure is an unresolved callback to the effect analysis, the manifest of a program that spawns tasks
also lists `clock/v1` (the module still imports only what it uses). Timed waits do not sleep: with nothing queued a timed wait returns as timed out at once, so a program that waits for a
deadline sees it early. How it is built (ADR-0055, decision 4): the runtime keeps per-task state in `__thread` objects; the
build turns each into an ordinary object of the section `orin_tls` (`-D__thread=__attribute__((section("orin_tls")))`), so
they form one block, and the L0 saves that block, installs its pristine image, runs the task and restores the block. No
atomics or WebAssembly threads are involved (the module needs no extra WebAssembly feature).

## Testing

`tools/test_wasm.sh` runs the conformance suites as WebAssembly modules under Node >= 24 (`tools/wasm_run.mjs` serves the same
two capabilities with Orbit's load-time checks), plus the differential tests of the WebAssembly L0 and its size budget. One
suite only: `NODE=node python3 tools/run_tests.py --orinc build/bootstrap/orin2 --target wasm64-orbit --suite all`.
