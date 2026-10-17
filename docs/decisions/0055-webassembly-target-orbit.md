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
     from `memory.grow`); `include/` holds the matching `stdlib.h`, `string.h`, `errno.h`. The allocator has a 16-byte
     header per block (its size and the size of the block before it) and 16-byte aligned payloads. Blocks up to 64 KiB are
     powers of two with a free list per class (the fast path, as before). Larger blocks are rounded to 16 bytes, kept on a
     best-fit free list, split when the remainder is itself large, and merged with free neighbours; the block at the heap
     top grows in place with `memory.grow`, and freeing it lowers the top, so a growing array costs about its own size.
     `runtime/platform/orbit/tests/alloc_test.c` stresses it natively (see section 6);
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
   exist (the host grant is the policy). Files, processes and the network return `EPERM`. There is one thread, and tasks
   run on it one at a time, to completion, **when someone would otherwise block** (rev. 2026-10-17, "tasks"):
   `orin_platform_thread_create` only queues the task; `thread_join` of a queued task runs it; `monitor_wait` and
   `monitor_wait_until` give the thread to the next queued task (the monitor is released meanwhile and locked again
   afterwards) and return as a spurious wake-up, which the contract allows and every caller handles by re-checking in a loop;
   tasks nobody joined run when `orin_main` returns. A wait with nothing queued ends the module (`wasm64-orbit: deadlock: ...`,
   trap, status 134); a timed wait with nothing queued returns as timed out at once (the L0 has no way to sleep). Monitors know
   their owner, so a lock held by a context suspended lower on the stack is reported as that deadlock. The runtime keeps its
   per-task state (heap block, grants, files, the running task) in `__thread` objects, which one stack and one memory would
   share: the build compiles the runtime with `-D__thread=__attribute__((section("orin_tls")))` (tools/run_tests.py,
   dist/orin-cli.sh), which turns each into an ordinary object of one section, and the linker's `__start_orin_tls` /
   `__stop_orin_tls` bound that block. Starting a task saves the block, installs its pristine image (copied at the start of
   `orin_main`), runs the task and restores the block; the thread id and the bound wake source are switched the same way.
   This needs no atomics and no WebAssembly feature beyond bulk memory (the module still runs in Node and Orbit unchanged); the
   obvious alternative, `-matomics` TLS, was tried and rejected: wasm-ld (LLVM 18 and 19, non-shared memory) emits
   `__tls_base + absolute address`, which is out of bounds. The L0 refuses to create a task if the runtime's heap block is
   outside the section (a build without the flag). Cost: the block (about 90 KB, mostly zeros) is stored as data in every module, because a named section is
   not zero-filled (bss) by the linker. What this cannot do: **two tasks that need each other to run at the same
   time** (ping-pong over bounded channels, a producer that blocks on a full channel while its consumer waits for the next
   item) would need a second stack; they end with the deadlock line instead of hanging. **A task that traps** cannot be
   unwound to its join without the exception-handling proposal, so the whole module ends (`wasm64-orbit: a task trapped:
   <message>`, status 101), where natively the joiner sees the trap. Both print a line with the prefix `wasm64-orbit: `, which
   `tools/run_tests.py --target wasm64-orbit` reports as SKIP (with the reason) when the test's result differs. `exit` flushes, records the status and traps (no unwinding without the exception-handling proposal).
   Entry point: the export `orin_main() -> i32` runs `main` and returns the exit status; after a trap, the export
   `orin_exit_status() -> i32` returns the status passed to `exit` (101 for an Orin trap), or -1 for any other trap.

5. **The capability manifest comes from the effect analysis.** With `--target=wasm64-orbit` the compiler appends a custom
   section `orbit.manifest` = `{"abi":1,"requires":[...],"producer":"orin"}` (an assembler directive at the end of the C
   file). `requires` is derived from the transitive effects of `main` (`compiler/analysis/orbit.or`, table in
   [capabilities.md](../capabilities.md)): `Console.Write`/`Stdio.Write` -> `log/v1`, `Clock.Now` -> `clock/v1`; `log/v1` is
   always listed (a trap message goes to stderr). An effect the target does not provide (`Fs.*`, `Process.Spawn`, `Net.*`,
   `Stream.*`) fails the build with **E0523**; `Task.*` and `Channel.*` need no capability (decision 4), so they are listed as available and the evidence path, so a program never compiles into a
   module that would only fail at run time. An unresolved call (`Unknown.*`, e.g. calling a function value) is not an error:
   the guest can import only `log/v1` and `clock/v1`, so the manifest then lists both (a manifest must cover every import;
   listing one more is the safe over-approximation). The manifest **describes**; the host's grant authorises (Orbit rejects
   a module whose imports are not all listed, and instantiates only with every listed capability granted).

6. **Tests and CI.** `tools/run_tests.py --target wasm64-orbit` builds every conformance test as a module and runs it under
   Node >= 24 with `tools/wasm_run.mjs`, a 100-line host that serves the same two capabilities with Orbit's load-time checks
   (orbit-prefixed imports only, manifest covers imports). A test whose program needs an unavailable effect is SKIP, not a
   failure. `tools/test_wasm.sh` runs that, the float, builtins and allocator tests and the `orin_tls` check (decision 4); the
   CI job `wasm` runs it. State at acceptance: 1002 passed, 0 failed, 32 skipped (file system, network, tasks, stdin); with
   tasks and the large-block allocator (2026-10-17, PR 2): 1039 passed, 0 failed, 23 skipped (file system, network, stdin, and
   4 task tests that need interleaving or a trapping task, decision 4).

7. **Budget.** `runtime/platform/orbit/` is not part of a native binary, so it does not count against the native L0 budget
   (ADR-0054); it has its own ceiling of **1100 code lines** (counted like `tools/verify_platform.sh`). 805 at acceptance with
   a ceiling of 900; raised to 1100 with the large-block allocator and the task scheduler (988 lines), because both are
   needed for real programs (memory near native, `std:task`) and each is covered by its own test.
   Evidence instead of CBMC for now: the shared pure primitives keep their harnesses; the rest is covered by the conformance
   suite under WebAssembly and the three tests (float, builtins, allocator).

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
Orbit setting, reported to the Orbit project. Peak memory: sieve was 273 MB as WebAssembly vs 77 MB native, because the
first allocator (pure power-of-two classes) rounded the growing 80 MB array up and kept the smaller blocks. With the
large-block allocator (decision 3) the same sieve peaks at 130 MB under Node 24 (314 MB before; the module's memory also
holds the 1 MiB stack, the data and Node's own footprint), and runs 0.36 s instead of 0.48 s (best of 15) because the
array grows in place instead of being copied. bintrees, fib and nbody are unchanged within noise (best of 15: 0.742 s vs
0.720 s, 0.648 s vs 0.640 s, 0.218 s vs 0.219 s; peak RSS identical).

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

- **wasm32** would remove the Memory64 cost and open older browsers. Two variants were costed (2026-10-17):
  - *Cheap: 64-bit Orin values, 32-bit C pointers.* Slots, `usize` (ADR-0022) and the IR stay 64-bit; the C backend already
    casts every pointer through `uint64_t`/`uintptr_t`. What breaks is only the runtime's pointer-holding ABI fields
    (`OrinArray.items`, `FreeNode.next`, `SbClass.head`, the `OrinHeap` free-list heads, `dstack` in
    `runtime/core/orin_runtime.h`), which the Orin-written runtime (`heap.or`, `object.or`, `array.or`, `leaf.or`) reads with
    `load64`/`store64` at fixed offsets; for wasm32 they become 64-bit storage (a union with a zeroed high word), and the 13
    `_Static_assert`s at `orin_runtime.h:264-277` follow (they are the only errors when `orin_runtime.c` is compiled for
    wasm32). About 120-180 lines: ~80 in `runtime/core` plus the copy in `bootstrap/seed`, ~25 in the compiler (target
    name), the rest in this L0, the tools and docs. It saves the bounds checks, not memory (slots stay 8 bytes).
    **Planned**: the runtime change after R3e of the runtime-in-Orin work (ADR-0052), then `wasm32-orbit` here.
  - *Full: 32-bit `usize` and 4-byte slots.* A 4-byte slot cannot hold `i64`/`f64`, which breaks the IR's "slot = 64-bit
    scalar or reference"; about 60-100 files and 3-6k lines across compiler, runtime and std plus a new seed. Rejected.
- **Tasks**: done sequentially (decision 4). Left: tasks that need interleaving and tasks that trap need either stack switching
  (the WebAssembly stack-switching proposal; Orbit does not enable it) or the exception-handling proposal (a trapping task
  would unwind to its join); or a scheduler-backed task capability in Orbit.
- **Capabilities**: `random/v1` once std has a randomness effect; `kv/v1` and files once Orin has effects for them.
- **LLVM backend** for this target (triple and data layout per target).
- **Reactor services**: named exported handlers instead of one `orin_main`, `orbit_alloc` for host-to-guest payloads.
