# ADR-0055: The WebAssembly target `wasm64-orbit`

Status: accepted (2026-10-17; decided by Claude under the owner's standing instruction to decide design questions with a
recommendation and document them; Henry can overturn it). Implements roadmap item 8 ([roadmap.md](../roadmap.md)) for the
Orbit runtime ([orin-lang/orbit](https://github.com/orin-lang/orbit)). Follows the Orbit host ABI v1
(orbit `docs/host-abi.md`) and the integration contract (orbit `docs/orin-integration.md`, option A). Adds a second L0
implementation next to the native one ([ADR-0013](0013-self-hosted-runtime.md), [ADR-0054](0054-l0-platform-budget-for-concurrency.md)).

## Question

Orin programs should run as WebAssembly modules in Orbit, Orin's isolate runtime, with the same behaviour as natively, and
the module should state which capabilities it needs (derived from the effect analysis, [ADR-0037](0037-effect-inference.md)).
What does the compiler emit, which memory width, which C library and which host interface?

## Decision

1. **Target name `wasm64-orbit`, C backend, clang.** `orin compile --target=wasm64-orbit` and
   `orin build --target=wasm64-orbit` (artifact `build/<profile>/<name>.wasm`). The generated C is the same as for the native
   target plus a manifest (point 5); clang compiles it with `--target=wasm64-unknown-unknown -mbulk-memory -ffreestanding
   -nostdlib` and links with wasm-ld (`--no-entry --stack-first -z stack-size=1048576`). The pinned LLVM 19.1.7
   (`orin toolchain install`) contains both, so the target needs no new toolchain; a system clang with the WebAssembly backend
   and `wasm-ld` (Ubuntu: `lld`) works too. The LLVM backend is not supported for this target yet (its `.ll` carries the
   native triple and data layout); `--backend=llvm` with the target is a usage error.

2. **wasm64 (Memory64), not wasm32.** The runtime assumes 64-bit pointers: `runtime/core/orin_runtime.h` statically asserts
   `sizeof(void *) == 8` and the heap block layout that `runtime/core/heap.or` reads at fixed offsets (R3d), and the IR's
   `usize` is 64-bit. wasm32 would need a target-dependent `usize` in the compiler and pointer-width-dependent layouts in the
   Orin-written runtime (owned by the runtime-in-Orin work, ADR-0052); wasm64 needs neither. Orbit accepts both widths and its
   ABI passes every pointer as `i64` anyway. The cost, measured (section "Measurements"): Memory64 loses Wasmtime's
   guard-page bounds-check elision (explicit checks per access) and is less widely supported in browsers (Node needs >= 24).
   A later wasm32 path is open (see "Later").

3. **No libc, no WASI: an own freestanding L0.** `runtime/platform/orbit/` replaces `runtime/platform/orin_platform.c`:
   - `orin_platform_orbit.c` implements every function of `orin_platform.h` over two Orbit imports,
     `orbit:log/v1 write` and `orbit:clock/v1 now_unix_nanos / monotonic_nanos`;
   - `orin_libc_orbit.c` is the C library the header and the runtime need (allocator, `mem*`, `strlen`; no imports, memory
     from `memory.grow`); `include/` holds the matching `stdlib.h`, `string.h`, `errno.h`;
   - `orin_float_orbit.c` is the exact `%.*e` formatting and correctly rounded `strtod`/`strtof` (big-integer arithmetic,
     byte-identical to glibc: `tools/test_wasm_float.sh`, 16.6 million checks, 0 mismatches);
   - `orin_builtins_orbit.c` holds the compiler support routines clang calls for operations without a WebAssembly
     instruction (`__multi3` and the 128-bit shifts of the integer-kind checks, `round`).
   The pure L0 primitives (`mem_find`, `fmt_*`, `policy_parse`, `path_normalize`, `path_within`, `millis_split`) moved
   unchanged into `runtime/platform/orin_platform_pure.h`, which both implementations `#include`, so the CBMC-checked code is
   shared, not copied.
   Why not wasi-libc: wasi-libc has no wasm64 build, and WASI preview 1 has ambient `environ_get`, `clock_time_get` and
   `random_get` that Orbit refuses to link (Orbit ADR-0003); its restricted WASI shim (`wasi_p1/v1`) is wasm32-only. With an
   own L0 the module's import list is exactly the capabilities the program reaches: wasm-ld drops dead imports, so a program
   that never reads the clock does not import it.

4. **Behaviour of the L0, fail closed.** stdout and stderr become log records (one per line; stdout = info, stderr = error,
   partial lines on flush). Arguments are `["main"]`, the environment is empty, stdin is at end of input, `ORIN_DENY` does not
   exist (the host grant is the policy). Files, processes and the network return `EPERM`. There is one thread: a task runs to
   completion inside `orin_platform_thread_create`; a monitor wait that nobody could notify traps with a message instead of
   deadlocking. `exit` flushes, records the status and traps (no unwinding without the exception-handling proposal).
   Entry point: the export `orin_main() -> i32` runs `main` and returns the exit status; after a trap, the export
   `orin_exit_status() -> i32` returns the status passed to `exit` (101 for an Orin trap), or -1 for any other trap.

5. **The capability manifest comes from the effect analysis.** With `--target=wasm64-orbit` the compiler appends a custom
   section `orbit.manifest` = `{"abi":1,"requires":[...],"producer":"orin"}` (an assembler directive at the end of the C
   file). `requires` is derived from the transitive effects of `main` (`compiler/analysis/orbit.or`, table in
   [capabilities.md](../capabilities.md)): `Console.Write`/`Stdio.Write` -> `log/v1`, `Clock.Now` -> `clock/v1`; `log/v1` is
   always listed (a trap message goes to stderr). An effect the target does not provide (`Fs.*`, `Process.Spawn`, `Net.*`,
   `Stream.*`, `Task.*`, `Channel.*`) fails the build with **E0523** and the evidence path, so a program never compiles into a
   module that would only fail at run time. An unresolved call (`Unknown.*`, e.g. calling a function value) is not an error:
   the guest can import only `log/v1` and `clock/v1`, so the manifest then lists both (a manifest must cover every import;
   listing one more is the safe over-approximation). The manifest **describes**; the host's grant authorises (Orbit rejects
   a module whose imports are not all listed, and instantiates only with every listed capability granted).

6. **Tests and CI.** `tools/run_tests.py --target wasm64-orbit` builds every conformance test as a module and runs it under
   Node >= 24 with `tools/wasm_run.mjs`, a 100-line host that serves the same two capabilities with Orbit's load-time checks
   (orbit-prefixed imports only, manifest covers imports). A test whose program needs an unavailable effect is SKIP, not a
   failure. `tools/test_wasm.sh` runs that, the float differential test and the builtins differential test; the CI job
   `wasm` runs it. State at acceptance: 1002 passed, 0 failed, 32 skipped (file system, network, tasks, stdin).

7. **Budget.** `runtime/platform/orbit/` is not part of a native binary, so it does not count against the native L0 budget
   (ADR-0054); it has its own ceiling of **900 code lines** (counted like `tools/verify_platform.sh`; 805 at acceptance).
   Evidence instead of CBMC for now: the shared pure primitives keep their harnesses; the rest is covered by the conformance
   suite under WebAssembly and the two differential tests.

## Measurements (2026-10-17, one Linux x86_64 container, best of 3, wall time)

Orin benchmarks (`bench/*/main.or`), native C backend `-O2` vs the same program as `wasm64-orbit`:

| program | native | Orbit (wasmtime 49) | Orbit without fuel metering | Node 24 (V8) |
|---|---:|---:|---:|---:|
| hello (startup) | 0.001 s | 0.048 s | 0.058 s | 0.073 s |
| fib | 0.361 s | 1.458 s | 0.825 s | 0.678 s |
| bintrees | 0.481 s | 1.383 s | 1.151 s | 0.788 s |
| sieve | 0.177 s | 0.519 s | 0.418 s | 0.564 s |
| nbody | 0.059 s | 0.221 s | 0.203 s | 0.273 s |

Orbit compiles the module and meters fuel on every run (`consume_fuel(true)`); without fuel fib is 1.8x faster. That is an
Orbit setting, reported to the Orbit project. Peak memory: sieve 273 MB as WebAssembly vs 77 MB native, because the
power-of-two allocator rounds the growing 80 MB array up and keeps the smaller blocks (see "Later").

The cost of Memory64 itself, isolated from Orin: the C reference programs (`bench/*/main.c`) built freestanding as wasm32 and
as wasm64 with the same clang flags, run by `wasmtime run` (29.0.1, no fuel):

| program | wasm32 | wasm64 | wasm64 / wasm32 |
|---|---:|---:|---:|
| fib | 0.350 s | 0.411 s | +17 % |
| bintrees | 0.623 s | 0.809 s | +30 % |
| sieve | 0.368 s | 0.320 s | -13 % |
| nbody | 0.071 s | 0.099 s | +39 % (short run, startup dominates) |

So Memory64 costs roughly 15-40 % on pointer-heavy code today; fuel metering costs more than that.

## Later

- **wasm32** would remove the Memory64 cost and open older browsers. It needs: a target-dependent `usize`/pointer width in
  the compiler's type layout and both backends; the heap block layout and the `_Static_assert`s in `runtime/core` made
  width-dependent (the Orin-written heap reads fixed offsets); and the L0 (`orin_libc_orbit.c` class limit) for 32-bit
  `size_t`. Estimated as a multi-PR change across compiler and runtime; worth it once Orbit density measurements show the
  bounds checks matter.
- **Allocator**: grow the top block in place and split large classes, to bring sieve-like programs near native memory.
- **Tasks**: run `std:task` sequentially (Orbit integration request 5) and lift E0523 for `Task.*`/`Channel.*` where the
  program cannot deadlock; or a scheduler-backed task capability in Orbit.
- **Capabilities**: `random/v1` once std has a randomness effect; `kv/v1` and files once Orin has effects for them.
- **LLVM backend** for this target (triple and data layout per target).
- **Reactor services**: named exported handlers instead of one `orin_main`, `orbit_alloc` for host-to-guest payloads.
