# Benchmarks

Status: first measurement infrastructure (spec 11, "Benchmark groups" 1, 2 and 5 only: CPU, memory,
compiler UX). No service, concurrency or token-cost benchmarks exist yet. Everything below is
from one machine and one run of `python3 tools/bench.py`; it is a baseline for tracking, not a
claim about Orin in general.

## Methodology

- **Programs**: `bench/<name>/main.or` (Orin-B), `main.go` (Go 1.24) and `main.c` (C, `cc -O2`)
  implement the same algorithm on the same input. Each prints a few checksum lines; `tools/bench.py`
  fails if stdout differs between the three. Inputs are fixed constants in the sources (no args).
- **Builds**: Orin = `build/bootstrap/orin2 compile` to C, then `cc -O2 -w -I runtime` with
  `runtime/orin_runtime.c` (no LTO, runtime is a separate translation unit); Go = `go build`
  (default flags); C = `cc -O2 -w`. Same `cc` for Orin and C.
- **Measurement**: one unrecorded warm-up run, then 5 runs; median wall time (min-max shown) from
  `perf_counter` around the process; peak RSS is `ru_maxrss` of the child, obtained through the small
  helper `tools/rss_probe.c` (`/usr/bin/time` is not installed; Python's own fork would inflate
  `ru_maxrss`). RSS has a ~1 MiB process-startup floor. Binary sizes are file sizes (also with `strip`).
  Build times are a single, uncached-for-C/Orin but Go-build-cache-warm measurement and are only indicative.
- **Orin counters**: `ORIN_STATS=1 ./prog` prints a one-line JSON summary to stderr at exit (allocations by
  kind, frees, retains, releases, COW copies vs in-place `make_unique` hits, array/string growth
  reallocations, peak live objects/bytes, `file_opens`/`file_closes` of the resource handles of ADR-0025). Counters are plain increments compiled in always.
  **Per allocation site** (opt-in, not compiled into normal builds): `orin2 compile --stats-sites` plus a runtime built with
  `-DORIN_SITE_STATS`, then `ORIN_STATS=sites` reports allocations, bytes, retains, releases and COW copies per MIR instruction;
  `tools/alloc_census.py` runs it on every benchmark, the HTTP server and the self-compile (docs/perf/alloc-census.md).
  `retains`/`releases` count non-immortal objects only; `releases` includes the children released while
  destroying an object. Bytes are object + buffer capacity (approximate, not RSS).
- **Algorithm equivalences and deliberate choices** (no cherry-picking: where a choice favours one side it is listed):
  - `fib`: naive recursion, `fib(40)`. Orin traps on overflow (checked arithmetic); Go and C do not.
  - `sieve`: 10,000,000 flags as 8-byte ints (not bytes) in all languages, grown by `push`/`append`.
  - `bintrees`: complete binary trees; Orin uses a tagged union `Leaf | Node(Tree, Tree)`; Go/C use a
    node struct with nil children; C frees explicitly, Go uses its GC, Orin uses RC.
  - `strings`: 500,000 appends, `split(",")` into separately allocated parts, `join(";")`, parse.
    Go uses `strings.Builder` (naive `+=` is quadratic in Go).
  - `wordfreq`: 1M generated words into a hand-built table (1024 buckets of record arrays, linear scan).
    No maps in any language.
  - `qsort_func`: out-of-place 3-way quicksort building fresh arrays (the natural functional style;
    Orin-B function parameters are immutable). `qsort_inplace`: iterative Lomuto with an explicit stack
    (Go and C copy the input first because Orin does a COW copy on first write).
  - `selfcompile`: `orin2 compile compiler/main.or` (~222 KB of Orin source, output 720 KB of C), the
    only realistic workload; it has no Go/C counterpart. (The reference row for the Rust stage-0
    compiler was dropped when Stage 0 was retired; see docs/bootstrap.md.) `cc` time is not included.
- **Limits**: 4 shared vCPUs in a VM, so run-to-run noise is visible in the min-max ranges; Go's GC runs on
  other cores and its wall time does not include that CPU time. No confidence intervals beyond min-max.
  Spec 11 asks for latency distributions, CPU time and Rust/Koka comparisons; those are not done.
  Reproduce with `./tools/bootstrap.sh && python3 tools/bench.py --out build/bench/results.md`.

## Results

Machine: Intel(R) Xeon(R) Processor @ 2.80GHz, 4 cores, 15.7 GiB RAM; Linux-6.18.44-fc-v114-x86_64-with-glibc2.39; cc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0; go version go1.24.7 linux/amd64; runs per cell: 5 (median, after 1 warm-up).

### Wall time, seconds (median; min-max in parentheses)

| benchmark | Orin | Go | C | Orin/Go | Orin/C |
|---|---:|---:|---:|---:|---:|
| bintrees | 1.228 (1.119-1.378) | 1.537 (1.434-1.753) | 0.659 (0.604-0.715) | 0.80x | 1.86x |
| fib | 0.604 (0.582-0.748) | 0.648 (0.636-0.685) | 0.228 (0.225-0.256) | 0.93x | 2.65x |
| qsort_func | 0.668 (0.637-0.746) | 0.952 (0.877-0.984) | 0.309 (0.272-0.341) | 0.70x | 2.16x |
| qsort_inplace | 0.297 (0.268-0.325) | 0.238 (0.208-0.339) | 0.127 (0.102-0.136) | 1.25x | 2.34x |
| sieve | 0.402 (0.365-0.426) | 1.501 (1.299-1.761) | 0.278 (0.270-0.320) | 0.27x | 1.44x |
| strings | 0.188 (0.156-0.231) | 0.164 (0.146-0.181) | 0.081 (0.075-0.104) | 1.15x | 2.32x |
| wordfreq | 0.234 (0.218-0.253) | 0.142 (0.138-0.152) | 0.115 (0.105-0.129) | 1.65x | 2.04x |
| selfcompile (orin2 compiles compiler/main.or) | 0.101 (0.085-0.123) | - | - | - | - |

### Peak RSS, MiB (median of ru_maxrss; ~1 MiB process-startup floor)

| benchmark | Orin | Go | C |
|---|---:|---:|---:|
| bintrees | 17.5 | 13.6 | 9.5  |
| fib | 1.5 | 1.8 | 1.5  |
| qsort_func | 49.4 | 74.0 | 23.7  |
| qsort_inplace | 16.8 | 31.0 | 16.8  |
| sieve | 77.5 | 256.3 | 77.6  |
| strings | 46.2 | 23.4 | 34.6  |
| wordfreq | 2.2 | 6.6 | 1.9  |
| selfcompile (orin2) | 15.4 | - | - |

### Binary size, KiB (unstripped / stripped) and build time, seconds (single run)

| benchmark | Orin | Go | C | Orin build | Go build | C build |
|---|---:|---:|---:|---:|---:|---:|
| bintrees | 32 / 26 | 2175 / 1413 | 20 / 18 | 0.41 | 0.10 | 0.18 |
| fib | 31 / 26 | 2174 / 1413 | 16 / 14 | 0.35 | 0.07 | 0.08 |
| qsort_func | 32 / 26 | 2175 / 1413 | 16 / 14 | 0.42 | 0.06 | 0.08 |
| qsort_inplace | 31 / 26 | 2175 / 1413 | 16 / 14 | 0.43 | 0.09 | 0.08 |
| sieve | 31 / 26 | 2174 / 1413 | 16 / 14 | 0.46 | 0.15 | 0.13 |
| strings | 32 / 27 | 2208 / 1433 | 16 / 14 | 0.45 | 0.10 | 0.11 |
| wordfreq | 32 / 26 | 2175 / 1413 | 16 / 14 | 0.45 | 0.06 | 0.08 |
| orin2 compiler binary | 366 / 324 | - | - | 7.25 | - | - |

### Orin runtime counters (ORIN_STATS=1; one run)

| benchmark | alloc_total | alloc_string | alloc_array | alloc_struct | retains | releases | cow_copies | cow_inplace | array_grows | string_grows | peak_live_objs | peak_live_bytes |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| bintrees | 33,405,923 | 36 | 0 | 33,405,887 | 33,126,270 | 66,532,193 | 0 | 0 | 0 | 0 | 262,142 | 12,582,816 |
| fib | 2 | 2 | 0 | 0 | 0 | 2 | 0 | 0 | 0 | 0 | 2 | 92 |
| qsort_func | 2,388,910 | 4 | 2,388,906 | 0 | 955,563 | 3,344,473 | 0 | 25,099,007 | 1,783,059 | 0 | 164 | 55,859,744 |
| qsort_inplace | 1,355,403 | 4 | 3 | 1,355,396 | 2 | 1,355,405 | 1 | 28,614,441 | 24 | 0 | 4 | 16,389,304 |
| sieve | 3 | 2 | 1 | 0 | 0 | 3 | 0 | 32,850,054 | 23 | 0 | 2 | 134,217,776 |
| strings | 3,000,015 | 2,500,014 | 1 | 500,000 | 500,003 | 3,500,018 | 0 | 0 | 17 | 19 | 500,007 | 39,885,282 |
| wordfreq | 2,006,031 | 2,000,006 | 1,025 | 5,000 | 1,013,073 | 3,019,104 | 0 | 2,996,024 | 1,351 | 0 | 11,027 | 545,699 |
| selfcompile | 1,023,409 | 224,110 | 89,656 | 709,643 | 1,738,601 | 2,762,010 | 21,146 | 141,546 | 47,207 | 7,842 | 179,900 | 11,300,788 |

selfcompile output C is 720,122 bytes and identical to the committed-bootstrap stage2.c.

Checksums: all outputs identical across Orin/Go/C.

## Discussion (what the data supports)

Orin (compiled through C with `-O2`) is between 1.4x and 2.7x slower than the equivalent C program on all
seven kernels, and relative to Go it ranges from 0.27x (faster) to 1.65x (slower). The Go comparison
is not uniform: Orin is faster on `sieve`, `qsort_func`, `bintrees` and `fib`, slower on `qsort_inplace`,
`wordfreq` and roughly level on `strings`. The "between Go and Rust" aspiration of spec 11 is not
demonstrated by this data: Orin is behind C everywhere here, and behind Go on 2-3 of 7. (Rust was not measured.)
The sieve result favours Orin mostly because Go's `append` growth creates garbage and a 256 MiB RSS; it is
not evidence of a faster inner loop (Orin is 1.4x C there).

Observations tied to counters:

1. **Allocation churn for temporaries (boxed Option, strings).** `qsort_inplace` does 1.36M struct
   allocations although the program never builds a record: they are the `Option<usize>` objects returned
   by `stack.pop()`. `strings` allocates 2.5M strings for 500k iterations (the temporaries of
   `"item" + i.toString() + ","`), `wordfreq` 2.0M strings for 1M words. These benchmarks are 1.15x-1.65x Go
   and ~2-2.3x C. Everything non-scalar, including Option and Result, is a heap object (ADR-0002).
2. **RC traffic and per-node allocation.** `bintrees` performs 33.4M allocations, 33.1M retains and
   66.5M releases (about one retain/release pair per node beyond the allocation/free itself, i.e. the
   conservative borrowed/owned convention is not eliminating pairs). It is 1.86x C but 0.80x Go, whose
   allocator+GC is also not cheap. Peak live objects are 262k, so the cost is traffic, not retention.
3. **Out-of-line runtime calls and checked arithmetic on scalar paths.** `sieve` and `qsort_inplace`
   do 32.9M and 28.6M `orin_make_unique` calls that all take the in-place path (`cow_copies` is 0 and 1):
   every `a[i] = v` and `push` pays a call into a separate translation unit (no inlining without LTO) plus
   bounds and uniqueness checks. `fib` has no allocation at all (2 objects) and is still 2.65x C, so
   checked arithmetic (`__builtin_*_overflow` plus branch) and codegen shape alone cost 2.7x there; Go is at
   0.93x of Orin on the same function. I have not isolated how much of the `fib` gap is overflow checks
   versus other codegen choices.

Further data points: `qsort_func` incurs 1.78M array growth reallocations (`push` into three fresh
arrays per call, capacity not pre-sized) and uses 2x C's RSS; the COW machinery itself is cheap in these
programs (`cow_copies` is 0-1 except in the compiler, where 21k copies of 163k make_unique calls occur).
The self-compile workload allocates 1.02M objects and performs 1.74M retains; the compiler binary built
by Orin takes 0.10 s (the Rust stage-0 compiler, since retired, took 0.04 s on the same source when this
was measured; not a like-for-like comparison of implementations). Binary size is a strength of the C-emitting design for small programs
(31 KiB vs 2.2 MiB for Go) but this mostly reflects Go's bundled runtime. Orin's end-to-end build time
(0.4 s, dominated by `cc`) is slower than a warm `go build` here; the Go number benefits from its build cache.

## Suggested optimizations (hypotheses, not yet tested)

- Inline fast paths of `orin_make_unique`, `orin_array_at`, `orin_array_slot_ptr`, `orin_array_push` into
  the header (or build with `-flto`), and hoist uniqueness checks out of loops.
- Avoid materialising `Option` for `pop().unwrap()` / `get(i).unwrap()` patterns (fuse in codegen, or
  represent `Option<scalar>` unboxed).
- Verified retain/release elision for borrowed-then-stored constructor arguments (spec 11 optimization order step 3),
  starting with `Node(make(..), make(..))`-style owned temporaries; add a freelist/size-class allocator for
  small structs.
- Fuse string concatenation chains (`a + b + c`) into one allocation; pre-size array growth for `filter`-like push loops.
- Use unchecked arithmetic where range analysis proves no overflow (never weakening safety), and measure how
  much of `fib`'s gap overflow checks account for (e.g. by building with checks stubbed out, for diagnosis only).

## Runtime fast-path optimization (runtime-only; before/after)

Changes (only `runtime/orin_runtime.{h,c}`; no semantic, ABI, trap-message or counter changes; stats counters
are bit-identical on all benchmarks except the self-compile row, whose input differs slightly because the
compiler source was merged forward):

- `orin_make_unique`, `orin_array_at`, `orin_array_slot_ptr` and `orin_array_push` are now `static inline`
  in the header; slow paths are out of line (`orin_make_unique_slow`, `orin_array_push_grow`). Same checks,
  same trap messages.
- `orin_trap` is `noreturn, cold`; all trap branches (checked arithmetic, bounds, division) use
  `__builtin_expect(..., 0)`; retain/dup/release get likely/unlikely hints.
- Size-class freelists for struct objects (0-8 slots) and array headers, recycled in `orin_struct_new` /
  `orin_array_new` / `orin_destroy`. Disabled automatically under AddressSanitizer / MSan
  (`__SANITIZE_ADDRESS__`, `__has_feature`) or with `-DORIN_NO_FREELIST`, so `--sanitize` runs still see real
  malloc/free. Freed objects are recycled, never returned to malloc (RSS follows the high-water mark of live objects).

Method: `python3 tools/bench.py` (5 runs, median) on the same machine, once before and once after, each a full
run (Go and C columns are untouched code and show the machine's run-to-run noise: e.g. Go bintrees 2.03 s vs
2.82 s, wordfreq C 0.111 vs 0.128). Differences under about 15% should be read as noise.

| benchmark | before Orin (s) | after Orin (s) | Orin/C before | Orin/C after |
|---|---:|---:|---:|---:|
| bintrees | 1.547 | 1.130 | 1.86x | 1.38x |
| fib | 0.615 | 0.597 | 2.74x | 2.67x |
| qsort_func | 0.592 | 0.387 | 2.03x | 1.14x |
| qsort_inplace | 0.289 | 0.218 | 2.29x | 1.94x |
| sieve | 0.500 | 0.439 | 1.75x | 1.24x |
| strings | 0.249 | 0.188 | 2.06x | 1.74x |
| wordfreq | 0.199 | 0.335 | 1.80x | 2.61x |
| selfcompile | 0.108 | 0.098 | - | - |

Honest reading: bintrees, qsort_func and qsort_inplace (struct/array allocation churn, in-place writes) improve
clearly; sieve and strings modestly. `fib` does not move: its generated code was already the optimal
checked-add shape (`add; jo` with the trap in a cold section). Compiling `fib` with the overflow checks removed
by hand takes 0.37 s vs 0.58 s, so the checks cost roughly 0.2 s of the 0.35 s gap to C; the rest is GCC inlining
recursion in plain C. That is a compiler (range analysis) matter, not a runtime one. `wordfreq` shows a slower
median (0.199 -> 0.335 s) in this run although its allocation profile is dominated by strings, which the freelist
does not touch and the C/Go columns of the same run also drifted; A separate re-run of only `wordfreq` (9 runs) gave 0.225 s
(0.208-0.362) for Orin, with Go and C also slower than in the first run, so it looks like noise, not a regression
(before: 0.199 s).


## MIR optimiser: owned parameters, last-use moves, RC cancellation (ADR-0010)

Method: `python3 tools/bench.py` (5 runs, median), once with the pre-change `orin2` and once with the
optimising `orin2`, same machine, back to back. The machine was noisy (the untouched C/Go columns moved by
up to 75%, e.g. C bintrees 0.69 s vs 1.22 s), so wall times of the Orin column are not comparable between the
two runs; the runtime counters are deterministic and are the reliable evidence. Benchmark checksums are
identical in both runs.

| benchmark | retains before -> after | releases before -> after | cow_copies | peak_live_bytes before -> after |
|---|---:|---:|---:|---:|
| bintrees | 0 -> 0 | 33,405,907 -> 33,405,907 | 0 -> 0 | 12,582,816 -> 12,582,816 |
| fib | 0 -> 0 | 2 -> 2 | 0 -> 0 | 108 -> 108 |
| qsort_func | 477,782 -> 1 | 2,866,692 -> 2,388,911 | 0 -> 0 | 55,859,744 -> 28,520,120 |
| qsort_inplace | 1 -> 1 | 1,355,404 -> 1,355,404 | 1 -> 1 | 16,389,304 -> 16,389,304 |
| sieve | 0 -> 0 | 3 -> 3 | 0 -> 0 | 134,217,776 -> 134,217,776 |
| strings | 0 -> 0 | 2,500,013 -> 2,500,013 | 0 -> 0 | 39,885,237 -> 39,885,237 |
| wordfreq | 6,025 -> 5,001 | 2,012,056 -> 2,011,032 | 0 -> 0 | 595,615 -> 595,615 |

Wall times (noisy run, Orin median s, before -> after): bintrees 0.993 -> 1.242, fib 0.304 -> 0.451,
qsort_func 0.410 -> 0.438, qsort_inplace 0.192 -> 0.251, sieve 0.344 -> 0.411, strings 0.159 -> 0.232,
wordfreq 0.227 -> 0.242. Benchmarks whose counters did not change generate identical C, so these differences are
pure machine noise (the C reference column slowed down by a similar factor); only `qsort_func` (all 477k retains and
about 0.48M releases removed, peak live bytes halved) is actually affected. No benchmark got slower in work done.

Quadratic case (tests/next/run/owned_param_linear.or: `st = add(st, i)` x 200,000, `add` does `let t = s; t.items.push(x)`):
`--no-opt`: cow_copies 400,000, retains 400,000, allocs 400,005, array_grows 200,000 (quadratic: it exceeds the
10 s test timeout under ASan); optimised: cow_copies 0, retains 0, allocs 5, cow_inplace 600,000 (linear, milliseconds).

Self-compile (orin2 compiling compiler/main.or), same binary, 5 runs each: 2.45 s with `--no-opt`, 4.7 s with the
optimiser, i.e. the optimiser pass itself costs about 0.45 s per compile of the 2.5 MB-C compiler (roughly +90%;
its flow-insensitive alias relation and per-parameter liveness are unoptimised Orin). Counters for that compile:
retains 21.7M -> 40.8M, cow_copies 216k -> 371k (the extra work is the optimiser's own array traffic).
Generated C size of the compiler: 2,014,725 bytes with `--no-opt`, 2,071,261 with optimisation (+2.8%; extra
temporaries and release edges), and the optimisation does not change the benchmark programs' C size noticeably.
In the compiler's own run the optimised compiler is not measurably faster as a program yet (it has few owned-parameter
patterns); the gain is asymptotic (state-threading code) rather than constant-factor.


## LLVM IR backend (ADR-0006): C backend vs LLVM backend vs Go vs C

Method: `python3 tools/bench.py` (5 runs, median after 1 warm-up), 4-core 2.8 GHz Xeon VM, Ubuntu clang 18.1.3
(`clang -O2 -w` on the emitted `.ll` plus `runtime/orin_runtime.c` and the shim `runtime/orin_runtime_llvm.c`),
gcc 13.3 for the C backend and the C reference, Go 1.24.7. The VM was noisy (min-max ranges of 20-40% within one
cell), so differences below roughly 25% are not significant. Checksums are identical across all columns.

| benchmark | Orin (C backend) | Orin (LLVM backend) | Go | C | Orin-C/Go | Orin-C/C | Orin-LLVM/Go | Orin-LLVM/C |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| bintrees | 1.564 (1.356-1.604) | 1.318 (0.999-1.371) | 3.552 (3.244-3.934) | 0.816 (0.779-0.897) | 0.44x | 1.92x | 0.37x | 1.61x |
| fib | 0.504 (0.358-0.514) | 1.026 (0.880-1.231) | 0.789 (0.759-0.900) | 0.483 (0.427-0.513) | 0.64x | 1.04x | 1.30x | 2.12x |
| qsort_func | 0.571 (0.436-0.636) | 0.623 (0.586-0.677) | 1.105 (0.913-1.365) | 0.467 (0.376-0.520) | 0.52x | 1.22x | 0.56x | 1.33x |
| qsort_inplace | 0.431 (0.312-0.484) | 0.283 (0.218-0.367) | 0.328 (0.268-0.447) | 0.263 (0.209-0.328) | 1.31x | 1.64x | 0.86x | 1.07x |
| sieve | 0.570 (0.536-0.634) | 0.465 (0.402-0.492) | 1.288 (0.948-1.540) | 0.457 (0.379-0.572) | 0.44x | 1.25x | 0.36x | 1.02x |
| strings | 0.303 (0.244-0.387) | 0.373 (0.306-0.443) | 0.174 (0.125-0.280) | 0.186 (0.113-0.239) | 1.74x | 1.63x | 2.14x | 2.01x |
| wordfreq | 0.436 (0.376-0.496) | 0.254 (0.244-0.436) | 0.207 (0.171-0.389) | 0.213 (0.139-0.223) | 2.11x | 2.04x | 1.23x | 1.19x |

Notes.
- The LLVM backend emits the hot runtime operations (retain/release, make_unique fast path, field/array slot
  access, array push, checked arithmetic via `llvm.*.with.overflow`) as `alwaysinline` IR, so they are optimised
  together with the program; everything else calls the C runtime. It therefore does **not** maintain the
  `ORIN_STATS` retain/release/cow-in-place counters (allocation counters, which live in the C runtime, still work).
- LLVM wins where the code is dominated by inlinable field/array/RC traffic (bintrees, qsort_inplace, sieve,
  wordfreq) and loses on `fib` (about 2x slower than gcc: gcc inlines the recursion two levels deep, LLVM keeps
  the checked-add after both calls; the IR itself is optimal, the sub overflow check is proven away) and `strings`
  (dominated by runtime calls, no inlining across the C/IR boundary without LTO). Closing these is a runtime-in-IR
  (spec 19) / LTO matter, not an emitter one.
- Binary size: 36 KiB (30 KiB stripped) vs 32 (26) for the C backend. The compiler built through LLVM
  (`orin compile compiler/main.or --backend=llvm`, 8.1 MB of `.ll`, `clang -O2` about 20 s) is 729 KiB vs 1056 KiB
  and compiles `compiler/main.or` in 1.2-1.6 s, the same as the C-built one within noise (1.5 s). It reproduces the
  C backend's `stage3.c` byte for byte, and its own `--backend=llvm` output is byte-identical to the `.ll` it was
  built from (fixed point).

## R1: library string/number functions in Orin (spec 19, ADR-0013)

What changed: `split`, `trim`, `indexOf`, `includes`, `startsWith`, `endsWith`, `parseInt`,
`int/usize/bool.toString()` and `string[].join` are no longer runtime C calls but Orin functions of the std
prelude (`std/`), compiled with every program (only the reachable ones are emitted). `orin_str_char_code_at` became
`static inline`. Method: `tools/bench.py` with the pre-change `orin2` (copy of the binary built before R1) against the
R1 `orin2`, same machine, back to back; the machine was shared and busy (load average 6-16 on 4 vCPUs, other
jobs running), so only differences well above the Go/C columns' own drift are meaningful.

| benchmark | before Orin median (s) | after Orin median (s) | note |
|---|---:|---:|---|
| strings (9 runs) | 0.164 (0.151-0.195) | 0.178 (0.154-0.217) | Go column of the same two runs: 0.131 vs 0.164 |
| strings (15 runs, repeated twice) | 0.161 / 0.165 | 0.168 / 0.177 | +4% to +7%: within the 15% bar, consistent sign |
| wordfreq (9 runs) | 0.233 (0.209-0.296) | 0.175 (0.169-0.199) | faster; `toString` of small ints no longer allocates (immortal one-char strings) |
| selfcompile: `orin2` built with `--c-builtins` vs with the prelude, 14 runs each | 1.082 (1.004-1.467) | 1.163 (0.981-1.362) | +7% median, ranges overlap; same workload, the compiler itself uses these functions heavily |

Counters (deterministic): strings: allocations 2,500,013 -> 2,500,003, `cow_inplace` 0 -> 500,001 (appends into
the freshly built `join`/`toString` strings are in place), `string_grows` 20 -> 40, peak live bytes 39.9 MB -> 42.4 MB
(`join` grows its result geometrically instead of allocating the exact size once, so it keeps spare capacity);
wordfreq: allocations 2,006,031 -> 2,003,865, peak live bytes unchanged. Peak RSS unchanged (strings 46.2 -> 45.9
MiB, wordfreq 2.4 -> 2.2 MiB). The generated C of the compiler grows from 2,834,084 to 2,850,660 bytes.

Reading: no regression above 15%. The only plausible slowdown (strings, a few percent) comes from `join` (repeated
append instead of one exact-size allocation) and from `int.toString()` going through a per-digit `fromCharCode` +
append instead of one `snprintf`; `split` and `indexOf` use a first-byte scan in Orin where C used `memmem`, which
did not show up in these workloads (short separators). Likely follow-ups: a runtime primitive to build a string
from a byte array (would let `join`/`toString` allocate once), and inlining of `substring`/`fromCharCode`.

## Floats and Map (ADR-0018)

Two benchmarks were added: `nbody` (5 bodies, 1,000,000 steps, `float[]` struct-of-arrays, `sqrt` from
`std:math`) and `mapfreq` (1,000,000 `Map<string, int>` updates over 50,000 keys; Go `map`, C open-addressing
table). Same machine and method as above (3 runs, median, `-O2`, programs link with `-lm`); all four outputs are
byte-identical.

| benchmark | Orin C backend (s) | Orin LLVM (s) | Go (s) | C (s) | Orin-C/Go | Orin-C/C |
|---|---:|---:|---:|---:|---:|---:|
| nbody | 0.344 | 0.321 | 0.228 | 0.197 | 1.51x | 1.75x |
| mapfreq | 0.749 | 0.783 | 0.471 | 0.472 | 1.59x | 1.59x |

Counters: nbody 13 allocations in total (floats are unboxed scalars, 75,000,003 in-place array updates, 0 COW copies);
mapfreq 0 COW copies (a unique map is updated in place through the owned-parameter optimisation), peak 8.0 MB.
The Map is Orin prelude code (hash table over arrays), not a C object.

## R2: L0 platform layer (spec 19, ADR-0013)

What changed: every libc/OS call of the runtime now goes through `platform/orin_platform.{h,c}`. Memory and
`mem_*` primitives are `static inline` wrappers in the header (same machine code as before); `console.log` is one
call `orin_platform_write_line` (was `fwrite_unlocked` + `putc_unlocked`); `int/usize.toString` use a hand-written
decimal formatter instead of `snprintf`; the `ORIN_STATS` report is assembled without printf. Method:
`tools/bench.py` with the pre-R2 tree (`git archive` of the parent, same `orin2` binary) against the R2 tree,
back to back, 9 runs (plus a 25-run repeat of qsort_func and strings); shared 4-vCPU machine with other jobs, so
the Go/C columns drifted by 20-30% between runs.

| benchmark | before Orin median (s) | after Orin median (s) | note |
|---|---:|---:|---|
| bintrees | 1.842 | 1.732 | |
| fib | 0.564 | 0.535 | |
| qsort_func (9 runs) | 0.643 | 0.700 | C column of the same runs 0.575 -> 0.603 |
| qsort_func (25 runs) | 0.640 | 0.756 | C column 0.584 -> 0.471: the machine, not the runtime, moved |
| qsort_inplace | 0.393 | 0.360 | |
| sieve | 0.672 | 0.659 | |
| strings (9 runs) | 0.388 | 0.306 | |
| strings (25 runs) | 0.364 | 0.264 | |
| wordfreq | 0.410 | 0.336 | |
| selfcompile (`orin2` compiles `compiler/main.or`) | 2.683 | 2.183 | |

Counters (deterministic) are identical before and after for every benchmark (allocations, retains/releases,
cow, grows, peak bytes); peak RSS unchanged. The only unfavourable medians (qsort_func) coincide with
a 20% swing of the C reference and with identical counters and identical hot-path code (qsort_func performs no
I/O in its loop), so no regression above 5% is claimed or observed; the measurement noise of this machine is
larger than that bar, which is why the argument rests on the counters and on the code being unchanged.

## Cost of the field bounds checks (shape-confusion backstop)

Change measured: every struct/variant slot access checks `kind == struct && index < nslots` (runtime inline
accessors, `orin_mir_struct_*`, LLVM `@orinl_slot`), array slot access and push check `kind == array`;
initialising stores into a fresh `orin_struct_new` stay unchecked (docs/assurance.md F-shape). Same machine as above.

Method: the base (the commit before the change) and the changed tree were bootstrapped separately.
`tools/bench.py --runs 7` was run base, new, base, new (two rounds each, 7 runs per cell after one warm-up).
Then the already built benchmark binaries were run alternately base/new (15 runs each, interleaved, to cancel
drift), and selfcompile (`orin2 compile compiler/main.or`) was run interleaved 10 times per session.

Interleaved A/B of the built benchmark binaries, median seconds; ratio = new / base:

| benchmark | C base | C new | C ratio | LLVM base | LLVM new | LLVM ratio |
|---|---:|---:|---:|---:|---:|---:|
| bintrees | 1.077 | 1.031 | 0.96 | 0.788 | 0.830 | 1.05 |
| fib | 0.326 | 0.319 | 0.98 | 0.562 | 0.538 | 0.96 |
| mapfreq | 0.358 | 0.372 | 1.04 | 0.279 | 0.299 | 1.07 |
| nbody | 0.217 | 0.226 | 1.04 | 0.166 | 0.209 | 1.27 |
| qsort_func | 0.410 | 0.415 | 1.01 | 0.408 | 0.397 | 0.97 |
| qsort_inplace | 0.190 | 0.199 | 1.05 | 0.153 | 0.165 | 1.08 |
| sieve | 0.340 | 0.353 | 1.04 | 0.322 | 0.331 | 1.03 |
| strings | 0.185 | 0.186 | 1.01 | 0.158 | 0.161 | 1.02 |
| wordfreq | 0.219 | 0.201 | 0.92 | 0.199 | 0.198 | 1.00 |

Noise: the min-max range of one cell is 20-40% of its median on this shared VM, so differences below about 10%
are not distinguishable from noise. The two `bench.py` rounds disagree with each other by up to 30% per cell in
both directions (C-backend strings 0.63x and 1.05x, qsort_inplace 0.99x and 1.28x). Reading: the checks are not
measurable on the micro-benchmarks (C backend: all ratios within -8%..+5%). LLVM `nbody` (float records, hot field
loads) is the one consistent outlier (+27% interleaved; +12% and -0.5% in the two `bench.py` rounds), so budget
up to about 25% on field-heavy numeric loops.

selfcompile (the realistic pointer-chasing workload: the compiler walking ASTs and MIR), interleaved: base
3.10-3.69 s median, new 3.82-4.51 s median across separate sessions, **+22% to +24%** (`bench.py` rounds, less
controlled: 1.53x and 1.39x). Ablation in one session (the changed `stage2.c` built with a modified runtime
header): full check 1.23x, `nslots` check only 1.13x, `kind | nslots` as one branch 1.23x. The kind check is about
10 points of the cost; it was kept because without it a string or array read as a struct passes the `nslots` test.

Peak RSS is unchanged; binary size changes by a few hundred bytes (inline checks, one out-of-line trap function).

Elision: none on reads. Unchecked `orin_struct_init` is used only for the initialising stores that follow
`orin_struct_new(tag, n, ...)` for the same instruction (`IStructNew` operands, closure and interface construction,
variant payloads in the legacy codegen), where the index is a loop counter below the constant `n` passed to the
allocation; the LLVM closure/interface constructors use the same reasoning (`slotGep`). Everything else is checked,
including `IPutField` (a put after a take) and struct-literal/update stores in the legacy codegen.

## Concurrency stage 0 (ADR-0017): cost of the thread-local runtime state

Per-task heap state (`__thread` counters, free lists, work stack) replaced globals. Same generated C, old runtime (commit d55461c) vs
current, executed instructions (callgrind): fib 1.0000, sieve 1.0000, nbody 1.0000, strings 1.0138, wordfreq 1.0132, mapfreq 1.0159,
qsort_func 1.0143, bintrees 1.0197. The counters use the `local-exec` TLS model (one instruction per update); with the default model
the cost was up to 1.05. Task micro-benchmarks (`bench/tasks`) and the rest: docs/concurrency.md "Measurements".

## Streams: closure inlining and fusion (ADR-0038 §2)

`bench/streams/main.or`: `filter -> map -> reduce` over 5,000,000 ints, 10 times, as a hand-written loop (`loop`) and as an
array-API chain with arrow functions (`chain`); the time includes building the input once. C backend, `cc -O2`, 9 interleaved
runs, median (min-max); CPU = user + system. The machine was shared (load average 15 while measuring), so the wall times are
about twice the CPU times; compare the CPU column.

| | loop wall | loop CPU | chain wall | chain CPU | chain / loop (CPU) |
|---|---:|---:|---:|---:|---:|
| before (baseline compiler, prelude functions with closure calls) | 0.274 (0.233-0.329) | 0.117 | 0.954 (0.792-1.113) | 0.456 | 3.9x |
| after (fused into one loop) | 0.221 (0.206-0.268) | 0.107 | 0.252 (0.216-0.290) | 0.109 | 1.02x |

The fused chain is the loop: no intermediate arrays, no closure objects, no indirect calls. `--no-fuse` gives the old numbers.

## Streams, parallel (ADR-0039)

`bench/streams_parallel/main.or`, the first argument picks: `seq` / `par` = the chain above without and with `parallel()`;
`seqheavy` / `parheavy` = the Collatz step count of 1..2,000,000 summed (about 100 steps per element, compute-bound). Same
build, 5 interleaved runs, median; ORIN_THREADS sets the worker count. 4 vCPUs, **load average 16 while measuring**.

| variant | threads | wall | CPU |
|---|---:|---:|---:|
| seq | - | 0.263 | 0.118 |
| par | 1 | 0.282 | 0.124 |
| par | 2 | 0.343 | 0.129 |
| par | 4 | 0.348 | 0.132 |
| seqheavy | - | 1.509 | 0.671 |
| parheavy | 1 | 1.616 | 0.743 |
| parheavy | 2 | 1.605 | 0.712 |
| parheavy | 4 | 1.660 | 0.721 |

**No speedup is claimed.** With a load average of 16 on 4 cores the process got about half of one core (wall is twice CPU even
for the sequential run), so more threads could not run at the same time. What the numbers do show: the CPU time of the parallel
runs is within 10 % of the sequential one, so chunking, lending the input (no copy) and the pool cost little; the results are
identical for every thread count. Repeat on an idle machine: `ORIN_THREADS=4 ./streams_parallel parheavy` against `seqheavy`.
## Performance defects found while building the std: fixes and re-measurement

Context: the std (`std:bytes`, `std:http`, `std:collections`) exposed four defects of the compiler and runtime, each of which cost a
factor of 2 to 1000 in a realistic program. All four are fixed without changing semantics or weakening a check; the optimiser
changes are verified by the MIR ownership verifier like every other pass (docs/mir.md v1.10). Machine: the shared 4-vCPU VM, **load
average 5-16 from other workers during these runs**, so every number is a median of 5-9 runs with the min-max range, and where the
generated C is byte-identical before and after (bintrees, fib, mapfreq, nbody, qsort_*, sieve, strings, wordfreq) the A/B
differences below are pure noise and show its size: up to +-25% (sieve 0.436 s vs 0.555 s from identical C).

### Fix 1: `x = x + e` on a field, an element or a nested place, and `x = x.concat(e)`

Cause: for a local string the lowering already turned `s = s + t` into an append. For `r.s = r.s + t`, `this.s = this.s + t`,
`rs[i].s = ..` the value was computed first (`getfield; dup; strappend`), so the string had two owners (the field and the
temporary) and `strappend` copied it: quadratic. `a = a.concat(b)` always allocated a new array. Fix (compiler/opt only, no
lowering change): `opt/inplace.or` and `opt/chains.or` rewrite "read a slot, retain it, store it back" into take / put of the slot
(the existing hole discipline of `x.a.push(v)`), at any depth, and `a = a.concat(b)` (local, field, element) into the new
instruction `arrayextend` (runtime `orin_array_extend`: in place when unique, otherwise a copy, amortised O(len b)).

| measurement (same machine, A/B) | before | after |
|---|---:|---:|
| 100,000 one-byte appends, `s = s + t` local / `s += t` | 0 ms / 4 ms | 1 ms / 1 ms |
| 100,000 appends, `r.s = r.s + t` (record field) | 277 ms | 1 ms |
| 100,000 appends, `this.s = this.s + t` (class field) | 137 ms | 1 ms |
| 20,000 `a = a.concat([i])` | 310-590 ms | 1 ms |
| bench/appends (200k string appends to a local, a field, a class field, an element; 100k array concats to a local and a field) | 74.4 s (one run) | 0.013 s (0.012-0.014) |

Tests: `tests/next/run/append_in_place.or` (value semantics with copies, aliasing operands, nesting, 50,000 appends),
`runtime/tests/runtime_test.c` (`orin_array_extend`), `compiler/tests/verify_main.or` (`IArrayExtend` rules).

### Fix 2: a mutating method that returns a value

Cause, two parts. (a) `this.r.next()` on a field copied the receiver on every call: the field and the call argument both
owned it, the callee's `makeunique` copied (`cow_copies` 6,000,000 for 12,000,000 calls). The take / put rewrite above removes that.
(b) The lowered function returns a fresh record `{ self, value }` that the caller destructures and releases: an allocation, a
retain and a release per call. `opt/pairs.or` turns a function whose every `return` builds such a record into an **in/out function**
(MIR v1.10: parameter 0 is also an output, `T f(OrinObj *l0, .., OrinObj **out)` in C) and scalar-replaces the record at the call
sites; if the record escapes it is rebuilt there, so the change is local and safe. Verified by the verifier (new rules, hand-written
cases, two new mutation classes: 41,368 mutants, 0 survivors).

| measurement | before | after |
|---|---:|---:|
| 3M calls `r.next()` (mutating, scalar result), top level | 126 ms | 15 ms |
| 3M calls `q.stepRet()` (calls `this.r.next()`), nested | 360 ms | 28 ms |
| same work with void methods (the old workaround), top level / nested | 25 / 137 ms | 26 / 25 ms |
| allocations, 12M calls | 15,000,016 | 16 |
| bench/mutres (4 x 10M calls) | 2.06 s (1.76-2.25) | 0.33 s (0.24-0.54) |
| bench/http_parse (std:http, see below) | 0.968 s (0.796-1.243) | 0.470 s (0.414-0.584) |
| http_parse counters: cow_copies / retains / allocations | 798,954 / 36.0M / 5.26M | 0 / 9.0M / 3.88M |
| bench/sortedmap (SortedMap<int>, 200k inserts, lookups, floors, removals, drain) | 1.128 s (0.910-1.400) | 0.719 s (0.638-1.008) |
| bench/pqueue (PriorityQueue, 1.2M operations) | 0.599 s (0.484-0.763) | 0.507 s (0.475-0.639) |

Earlier interleaved run of http_parse on a quieter machine: 0.716 -> 0.378 s (1.9x). Tests: `tests/next/run/mutating_result.or` (scalar and
reference results, discarded results, conditions, fields of fields, elements, a result that is the old receiver, recursion, `?`,
generic classes, copies taken before the call), all 805 existing conformance programs.

### Fix 3: bulk bytes <-> string

`bytesToString(a: u8[], start, len): string` and `stringToBytes(s): u8[]` are built-ins over the runtime object model
(`orin_bytes_to_string`, `orin_string_to_bytes`, contracts in `runtime/orin_runtime.h`; bounds are checked ("slice out of range"), an
element above 255 or a non-u8 array traps instead of being truncated; no platform call, so the boundary check is unchanged).
std:bytes (`toRawString`, `bytesFromString`, `ByteBuilder.appendString`) and std:http (`sliceString`) use them. bench/bytesstr
(1 MiB, 40 round trips through `bytesFromString` / `toRawString`): **1.322 s (1.115-1.520) -> 0.157 s (0.077-0.187)**, 8.4x. Tests:
`tests/next/run/bytes_string_bulk.or`, `bytes_string_bulk_trap_range.or`, runtime unit tests, the std suites.

### Fix 4 (found on the way): the verifier scanned all locals on every definition

gprof of `orin verify compiler/main.or`: `killBorrows` (a scan over all locals, 1.07M calls) and `joinState` (an allocation per join) were
48% of the verifier's time. Defining a Dead or scalar local cannot invalidate a borrow (borrows die whenever their source dies), so the
scan is skipped there, and the fixpoint joins without allocating when the join changes nothing. Result: the verify phase is about 10-15%
faster, but **`orin2 compile compiler/main.or` CPU time is unchanged** (5.37 s before, 5.35 s after, medians of 7 interleaved runs,
user+sys, under the load above): the new optimiser passes cost about what the verifier saved. The compiler's own sources are
already written with `+=`, `push` and `void` methods, so it gains nothing from fixes 1-3 (121 of its methods become in/out functions;
`cow_copies` 1.61M -> 1.58M).

### Re-measurement of every benchmark (tools/bench.py, 5 runs, median; min-max in parentheses)

Orin = the compiler of this change; Go 1.24.7, gcc 13.3 `-O2`, clang 18 (LLVM backend), OpenJDK 21 `-XX:+UseParallelGC`, rustc 1.97
`-O`. Rows without a Go / C column (http_parse, sortedmap) have no counterpart (Go's net/http parses a different grammar, Go has no
ordered map). Java rows come with the warm-up repetitions of one JVM (all eight, in ms): the first repetition is the cold one.
The `selfcompile` row of this run (7.47 s) was taken at load average 5-16; the unloaded figure is the 4.95 s of the baseline run
(5.37 s CPU for both compilers under load, above). Check sums are identical in all languages.

Before (baseline run of this change, same machine, quieter: load 1-4; this is `main` + the std:http branch, `tools/bench.py` before any fix):

#### Wall time, seconds (median; min-max in parentheses)

| benchmark | Orin (C backend) | Orin (LLVM backend) | Go | C | Orin-C/Go | Orin-C/C | Orin-LLVM/Go | Orin-LLVM/C |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| bintrees | 1.381 (1.217-1.555) | 0.846 (0.781-0.974) | 2.656 (2.383-3.002) | 0.920 (0.606-0.959) | 0.52x | 1.50x | 0.32x | 0.92x |
| fib | 0.445 (0.367-0.469) | 0.787 (0.628-0.848) | 0.714 (0.625-0.748) | 0.266 (0.203-0.392) | 0.62x | 1.67x | 1.10x | 2.96x |
| mapfreq | 0.596 (0.371-0.657) | 0.326 (0.305-0.451) | 0.289 (0.220-0.451) | 0.182 (0.109-0.200) | 2.06x | 3.27x | 1.13x | 1.79x |
| nbody | 0.210 (0.196-0.315) | 0.281 (0.197-0.348) | 0.130 (0.106-0.175) | 0.107 (0.075-0.121) | 1.62x | 1.97x | 2.17x | 2.64x |
| qsort_func | 0.407 (0.392-0.447) | 0.531 (0.447-0.552) | 0.924 (0.811-1.038) | 0.294 (0.269-0.364) | 0.44x | 1.39x | 0.57x | 1.81x |
| qsort_inplace | 0.206 (0.186-0.247) | 0.183 (0.171-0.228) | 0.238 (0.180-0.278) | 0.133 (0.116-0.150) | 0.87x | 1.56x | 0.77x | 1.38x |
| sieve | 0.392 (0.330-0.423) | 0.340 (0.308-0.372) | 1.011 (0.891-1.271) | 0.306 (0.287-0.321) | 0.39x | 1.28x | 0.34x | 1.11x |
| strings | 0.162 (0.157-0.180) | 0.208 (0.160-0.228) | 0.150 (0.106-0.219) | 0.120 (0.095-0.130) | 1.08x | 1.36x | 1.39x | 1.74x |
| wordfreq | 0.198 (0.193-0.278) | 0.213 (0.199-0.242) | 0.168 (0.148-0.197) | 0.143 (0.116-0.154) | 1.18x | 1.39x | 1.26x | 1.49x |
| selfcompile (orin2 compiles compiler/main.or) | 4.953 (4.778-5.419) | - | - | - | - | - | - | - |


After:

#### Wall time, seconds (median; min-max in parentheses)

| benchmark | Orin (C backend) | Orin (LLVM backend) | Go | C | Orin-C/Go | Orin-C/C | Orin-LLVM/Go | Orin-LLVM/C |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| appends | 0.042 (0.036-0.064) | 0.029 (0.014-0.041) | 0.036 (0.017-0.076) | 0.034 (0.029-0.040) | 1.19x | 1.24x | 0.80x | 0.84x |
| bintrees | 1.905 (1.739-2.275) | 1.312 (1.228-1.691) | 3.947 (3.431-4.337) | 1.520 (1.439-1.763) | 0.48x | 1.25x | 0.33x | 0.86x |
| bytesstr | 0.174 (0.114-0.220) | 0.246 (0.190-0.313) | 0.082 (0.060-0.198) | 0.229 (0.152-0.252) | 2.12x | 0.76x | 2.99x | 1.07x |
| fib | 0.535 (0.516-0.652) | 0.894 (0.731-0.999) | 0.793 (0.742-0.873) | 0.462 (0.453-0.516) | 0.68x | 1.16x | 1.13x | 1.94x |
| http_parse | 0.537 (0.460-0.693) | 0.355 (0.348-0.501) | n/a | n/a | n/a | n/a | n/a | n/a |
| mapfreq | 0.641 (0.601-0.687) | 0.425 (0.366-0.696) | 0.301 (0.239-0.350) | 0.139 (0.106-0.296) | 2.13x | 4.62x | 1.41x | 3.06x |
| mutres | 0.259 (0.238-0.331) | 0.216 (0.182-0.240) | 0.080 (0.068-0.088) | 0.048 (0.037-0.075) | 3.25x | 5.42x | 2.71x | 4.52x |
| nbody | 0.361 (0.194-0.486) | 0.357 (0.282-0.378) | 0.151 (0.104-0.164) | 0.126 (0.098-0.181) | 2.39x | 2.86x | 2.36x | 2.83x |
| pqueue | 0.656 (0.566-0.667) | 0.389 (0.334-0.426) | 0.428 (0.340-0.470) | 0.120 (0.109-0.209) | 1.53x | 5.48x | 0.91x | 3.25x |
| qsort_func | 0.492 (0.416-0.578) | 0.564 (0.461-0.605) | 1.111 (0.979-1.148) | 0.349 (0.341-0.621) | 0.44x | 1.41x | 0.51x | 1.62x |
| qsort_inplace | 0.319 (0.246-0.456) | 0.234 (0.208-0.377) | 0.368 (0.212-0.468) | 0.184 (0.152-0.211) | 0.87x | 1.73x | 0.64x | 1.27x |
| sieve | 0.528 (0.460-0.580) | 0.469 (0.450-0.523) | 1.124 (1.095-1.316) | 0.468 (0.415-0.519) | 0.47x | 1.13x | 0.42x | 1.00x |
| sortedmap | 1.039 (0.961-1.592) | 1.184 (1.097-1.327) | n/a | n/a | n/a | n/a | n/a | n/a |
| strings | 0.279 (0.182-0.376) | 0.344 (0.155-0.384) | 0.199 (0.118-0.373) | 0.240 (0.228-0.260) | 1.40x | 1.16x | 1.72x | 1.43x |
| wordfreq | 0.312 (0.242-0.387) | 0.352 (0.255-0.539) | 0.419 (0.360-0.534) | 0.171 (0.161-0.359) | 0.74x | 1.83x | 0.84x | 2.06x |
| selfcompile (orin2 compiles compiler/main.or) | 7.473 (6.833-7.576) | - | - | - | - | - | - | - |

#### Peak RSS, MiB (median of ru_maxrss; ~1 MiB process-startup floor)

| benchmark | orin | llvm | go | c |
|---|---:|---:|---:|---:|
| appends | 4.4 | 4.7 | 11.2 | 4.8  |
| bintrees | 17.4 | 17.7 | 19.7 | 9.6  |
| bytesstr | 11.4 | 11.6 | 9.3 | 11.7  |
| fib | 1.4 | 1.7 | 1.8 | 1.6  |
| http_parse | 1.6 | 1.9 | n/a | n/a  |
| mapfreq | 10.4 | 10.6 | 8.7 | 5.1  |
| mutres | 1.4 | 1.7 | 1.8 | 1.6  |
| nbody | 1.8 | 1.7 | 1.8 | 1.8  |
| pqueue | 6.0 | 6.2 | 16.0 | 4.8  |
| qsort_func | 35.3 | 35.6 | 76.6 | 23.8  |
| qsort_inplace | 16.6 | 16.8 | 32.3 | 16.8  |
| sieve | 77.6 | 77.8 | 294.1 | 77.6  |
| sortedmap | 9.1 | 9.4 | n/a | n/a  |
| strings | 46.0 | 46.2 | 32.7 | 34.7  |
| wordfreq | 2.3 | 2.5 | 7.1 | 2.0  |
| selfcompile (orin2) | 130.4 | - | - | - |

#### Java (OpenJDK, -XX:+UseParallelGC) and Rust (rustc -O): same programs, wall time of the whole process in seconds (median; min-max)

| benchmark | Orin (C backend) | Java cold | Java warm (last of 8 reps in one JVM, ms) | Rust | Java RSS MiB | Rust RSS MiB | Orin RSS MiB |
|---|---:|---:|---:|---:|---:|---:|---:|
| appends | 0.042 | 0.177 (0.136-0.308) | 7 (reps: 180 12 12 12 14 27 9 7) | 0.020 (0.012-0.023) | 50.3 | 5.0 | 4.4 |
| bintrees | 1.905 | 0.672 (0.508-0.876) | 357 (reps: 631 579 562 567 321 635 470 357) | 1.952 (1.659-2.407) | 269.4 | 10.1 | 17.4 |
| bytesstr | 0.174 | 0.408 (0.258-0.493) | 18 (reps: 99 23 42 21 20 46 55 18) | 0.131 (0.107-0.203) | 96.1 | 5.0 | 11.4 |
| fib | 0.535 | 0.816 (0.728-0.972) | 792 (reps: 728 837 708 687 697 720 757 792) | 0.432 (0.380-0.493) | 39.2 | 2.1 | 1.4 |
| mutres | 0.259 | 0.235 (0.178-0.272) | 20 (reps: 75 72 38 33 31 19 22 20) | 0.051 (0.042-0.055) | 39.2 | 2.1 | 1.4 |
| pqueue | 0.656 | 0.740 (0.664-0.915) | 361 (reps: 819 864 564 366 323 445 312 361) | 0.198 (0.183-0.311) | 62.9 | 5.2 | 6.0 |
| sieve | 0.528 | 0.632 (0.454-0.862) | 389 (reps: 773 609 458 496 488 400 395 389) | 0.439 (0.367-0.633) | 116.6 | 78.4 | 77.6 |
| strings | 0.279 | 1.068 (0.767-1.207) | 74 (reps: 880 464 388 308 151 352 193 74) | 0.127 (0.120-0.172) | 130.9 | 19.9 | 46.0 |

Startup: `java Hello` (JVM start, class load, print, exit) 0.074 s median, 38.1 MiB peak RSS. The native columns carry a ~1 MiB process-startup floor of RSS (see Methodology).

Reading the Java rows: Java wins where its JIT and GC pay off over a long run (bintrees warm 357 ms against Orin 1.9 s, which
frees every node by reference counting; pqueue warm 361 ms) and loses the whole-process comparison on short programs (cold start
0.07 s for `Hello`, 38 MiB RSS; fib 0.82 s cold against 0.54 s; strings 1.07 s against 0.28 s). RSS is where it differs most: Java
40-270 MiB against Orin 1.4-78 MiB on the same programs (sieve 117 vs 78 MiB because both use 8-byte flags; bintrees 269 vs 17 MiB).
Rust and C are within noise of each other and ahead of Orin by 1.1x-5.5x on the allocation-heavy rows (mutres 5.4x, pqueue 5.5x
against C, mapfreq 4.6x), i.e. the gap that remains is the object model, not the std.

### Backends: ADR-0038 step 1 (attributes)

The LLVM backend marks every generated function's parameters `noundef`, references `nonnull`, results `noundef` / `nonnull` (all values
are initialised and no reference is null; `nounwind` was already on every function). `memory(none)` / `readonly` / `willreturn` were not
added: the MIR has no purity or termination information, and a function with checked arithmetic or a bounds check can trap (call
`orin_trap`, which writes and exits), so `memory(none)` would let LLVM delete a trap whose result is unused. Measured effect on the LLVM
column: none distinguishable from noise (fib 0.894 s vs 0.787 s in the baseline run, bintrees 1.31 vs 0.85 s, at a load average of 5-16
against 1-4); `diff_backends.py --mode llvm` and the LLVM suites pass. The C backend has no equivalent attributes that the language
guarantees (the C compilers already see `static` functions).

### Backends: ADR-0038 §8 gate 1 (LLVM against C, executed instructions)

Gate 1 asks for the LLVM backend to be at least on par with the C backend on every benchmark, judged by executed instructions
(valgrind `cachegrind --cache-sim=no`, "I refs", one run, the `instructions.args` inputs; C backend = `orin2 compile` + `cc -O2` (gcc 13.3),
LLVM = `--backend=llvm` + `clang -O2` (clang 18.1), same runtime sources). Wall time was not used (shared machine). `tasks` (skipped) and the
parallel benchmarks are not counted. "Before" is `origin/main` at the start of the change, "after" the change; the C column moves a little
because the same change also removes a `memset` call from `orin_struct_new` (see below).

| benchmark | C before | LLVM before | LLVM/C before | C after | LLVM after | LLVM/C after |
|---|---:|---:|---:|---:|---:|---:|
| appends | 126.4 M | 127.6 M | 1.009 | 126.4 M | 127.6 M | 1.009 |
| bintrees | 7,135.1 M | 7,437.5 M | 1.042 | 6,801.0 M | 6,835.6 M | 1.005 |
| bytesstr | 507.1 M | 423.3 M | 0.835 | 507.1 M | 423.3 M | 0.835 |
| fib | 3,200.4 M | 4,802.1 M | **1.501** | 3,200.4 M | 2,484.0 M | 0.776 |
| http_parse | 2,243.8 M | 2,252.8 M | 1.004 | 2,230.4 M | 1,907.5 M | 0.855 |
| mapfreq | 2,031.9 M | 2,123.7 M | 1.045 | 2,021.9 M | 1,979.4 M | 0.979 |
| mutres | 3,390.3 M | 2,632.8 M | 0.777 | 3,390.3 M | 2,602.8 M | 0.768 |
| nbody | 2,397.4 M | 1,997.3 M | 0.833 | 2,397.4 M | 2,046.3 M | 0.854 |
| pqueue | 2,263.9 M | 2,025.3 M | 0.895 | 2,227.9 M | 2,111.2 M | 0.948 |
| qsort_func | 2,381.9 M | 2,377.6 M | 0.998 | 2,381.9 M | 2,378.6 M | 0.999 |
| qsort_inplace | 980.5 M | 817.5 M | 0.834 | 966.9 M | 829.6 M | 0.858 |
| sieve | 658.9 M | 492.5 M | 0.747 | 658.9 M | 502.5 M | 0.763 |
| sortedmap | 1,871.7 M | 1,729.2 M | 0.924 | 1,853.3 M | 1,788.2 M | 0.965 |
| streams | 1,183.8 M | 1,250.5 M | 1.056 | 1,183.8 M | 1,173.8 M | 0.992 |
| strings | 1,310.2 M | 1,350.5 M | 1.031 | 1,305.2 M | 1,266.0 M | 0.970 |
| wordfreq | 1,500.1 M | 1,488.5 M | 0.992 | 1,500.1 M | 1,434.8 M | 0.956 |

Root causes (the checked-arithmetic lowering itself, `llvm.*.with.overflow` + branch, was already optimal: the optimised IR of `fib` is the same
add/jo sequence gcc emits):

1. **A trap call blocks shrink-wrapping.** Every trap was `call @orin_trap` + `unreachable` inside an `alwaysinline` helper. A call in a block
   with no return needs a stack frame, so LLVM hoisted the whole prologue (3 pushes, 3 pops) above the `n < 2` test: every call of `fib`,
   including the leaf calls (about 60 % of all), paid it. Now the trap is written at function level as the function's own return,
   `%t = tail call <ret> @orinl_trap_<i|p|f|v>(msg); ret %t` (four tiny shims in `runtime/orin_runtime_llvm.c` that call `orin_trap`).
   That is a `jmp` with no frame, the check blocks stay out of the frame, and the prologue moves to the slow path. Checked `+ - *`, `/ %`, negation, the
   range / conversion guards, struct slot checks, array slot / push kind and bounds checks, and `charCodeAt` are therefore expanded in the function
   instead of called as prelude helpers (the helpers remain for `unwrap_or` and `array_new`). The check keeps its `llvm.*.with.overflow` form, so the
   `nsw` / `nuw` facts after a check survive. `fib`: 4,802 M to 3,809 M.
2. **Partial inlining of the recursion guard.** gcc splits `fib` (`-fipa-split`: `fib.part.0`) so the `n < 2` test runs in the caller and only
   non-trivial calls happen; LLVM `-O2` does not (`-enable-partial-inlining` is not part of the default pipeline and changed nothing). The backend now does
   the split itself for a small (at most 8 blocks, 12 locals), directly self-recursive function with scalar parameters and result whose entry block is
   cheap scalar code ending in a branch to a block that only returns: an `alwaysinline` wrapper `f` (entry block, return block, tail call) and the
   original code as `f.body`. `fib`: 3,809 M to 2,484 M.
3. **`charCodeAt` was an out-of-line call** to the shim `orinl_str_char_code_at` (the C backend inlines the header function): now inline. `mapfreq`
   2,124 M to 1,992 M, `strings` 1,350 M to 1,273 M.
4. **`x * 2` checked as a range test.** InstCombine rewrites `smul.with.overflow(x, 2)` into `x + 2^62 < 0` plus a separate `add` (3 + 1 instructions
   against gcc's `imul; jo`). A multiplication by the literal 2 is now emitted as `x + x` with the same check and message. `streams` 1,241 M to 1,174 M.
5. **Runtime, both backends:** `orin_struct_new` zeroed the slots with `memset(p, 0, n * 8)`; clang calls glibc `memset` for the variable length
   (367 M instructions in `bintrees`), gcc inlined it. Up to four slots are now cleared with plain stores. `bintrees` C 7,135 M to 6,801 M, LLVM
   7,437 M to 6,836 M.

Behaviour is unchanged: same checks in the same order, same messages (two moved into the fixed message table: the wrong-shape message and the
`charCodeAt` message), same exit status 101; `diff_backends.py --mode llvm`, the LLVM suites and the tooling tests pass.

**Still above 1.0:** `appends` (+0.9 %) and `bintrees` (+0.5 %). In both, every function the backend generates is at or below the C backend's count; the
difference is in the C runtime compiled by clang instead of gcc: `orin_destroy` costs clang about 45 % more instructions per call in `appends`
(10.4 M against 15.0 M; clang materialises the thread-local addresses of `orin_stats`, `fl_*` and `g_live` in the prologue and spills them) and
`orin_str_append` 10 % more (25.6 M against 28.0 M). Not a backend problem; to be closed by restructuring the thread-local state of the
runtime (one `__thread` struct) or by a lighter `orin_destroy` entry. Gate 1 is therefore met on 14 of 16 benchmarks and missed by under 1 % on two.

Cost of the change on the LLVM column: the check blocks now return instead of ending in `unreachable`, so LLVM no longer knows the path is dead after a
trap; a few loops got 2-4 % longer (`pqueue` 2,025 M to 2,111 M, `sieve` 492 M to 502 M, `nbody` 1,997 M to 2,046 M, `sortedmap` 1,729 M to 1,788 M), all still
below the C backend.

### Further defects, not fixed (listed, in the order of expected gain)

* **Option / Result / pair results still allocate** (`pop()`, `get()`, `indexOf`, `Some(x)`): 1.69M of http_parse's 3.88M allocations, 2 per
  `PriorityQueue.pop`. Needs unboxed `Option<scalar>` (the "unboxing" lever); the in/out receiver of fix 2 is the first instance of the mechanism.
* **RC traffic**: http_parse still does 9.0M retains and 12.9M releases for 3.9M allocations, bintrees 33M releases; elision of borrowed-then-stored
  pairs and escape analysis for non-escaping records are the levers (ADR-0010 only handles owned parameters and last uses).
* `std:http` `toLowerAscii` and `std:bytes` `toHex` build one 1-character string per byte and join them (no fast path when there is no
  upper-case letter); a `u8[]` map + `bytesToString` would do. `Bytes.concat` copies through a `push` loop.
* The verifier allocates one `LState` record per `setLs` (11M structs per self-compile) and `joinState` is O(locals) per edge: a flat int
  encoding would halve the verify phase; `orin_destroy` is 14-17% of the compiler's profile (freelist covers structs of 0-8 slots only).
* `x = t + x` (prepend) and `x = f(x)` for a non-mutating `f` with a borrowed parameter are inherently copying; `s.split` /
  `join` / `int.toString` are prelude Orin with a call per byte.
* Checked-arithmetic overhead on `fib` and the field bounds checks (+22% on self-compile, see above) need range analysis / a shape-checking verifier.

What remains for the big levers: unboxing (Option/Result of scalars, small records, the pair of fix 2 generalised to any fresh record
returned and destructured), reference-count elision (borrowed-to-owned retains that the callee only reads, release-after-last-use
pairs across loop iterations, `bintrees`-style constructor chains) and escape analysis (stack allocation of records that never leave a
function; with it `Some(x)` for `pop().unwrap()` disappears). Each is a MIR pass with its verifier rules, in the style of `opt/pairs.or`.


## HTML rendering

`bench/html` renders a 2000-row product table (`<tr>` with an id, an even / odd class, an HTML-escaped name, a price, an
escaped and URL-sanitised link, and a checkbox that is `disabled` for every third row) 400 times from scratch, sums the
page lengths (about 144.6 MB in all) and hashes the last page. Every 7th name contains `<b>&"sale"</b> it's` (all five
characters are escaped) and every 11th URL is `javascript:alert(i)`, which the Go `html/template`-style rule replaces by
`about:invalid#orin-unsafe-url`. All programs print byte-identical `bytes`, `hash` and `head` lines.

- `bench/html/main.or`: **OX** markup with `std:html` (ADR-0043, ADR-0044), a `Row` and a `Page` component; each component is one fused buffer.
- `bench/html_hand/main.or`: the same page **hand-written** in Orin, plain concatenation into one accumulating string
  (`out += ...`) with the same `std:html` `escape` / `safeUrl` (Orin-only row).
- `bench/html/main.c`: one growing buffer, `memcpy`, an escape loop copying runs; `main.go`: `strings.Builder`.

4-core Xeon 2.8 GHz VM with other work running (wall times are noisy; the instruction counts are the metric):

| program | Orin C backend | Orin LLVM backend | Go | C |
|---|---:|---:|---:|---:|
| executed instructions, OX (`html`) | 3.99 G | 3.88 G | | 1.58 G |
| executed instructions, hand-written Orin (`html_hand`) | 4.71 G | 4.63 G | | |
| wall, OX (5 runs, median) | 0.415 s | 0.412 s | 0.449 s | 0.206 s |
| allocations, OX: strings / `Html` records | 2.74 M / 0.80 M | | | |
| allocations, hand-written: strings | 5.03 M | | | |

OX executes 15 % fewer instructions than the hand-written concatenation and allocates 30 % fewer objects: its static
parts are merged at compile time and appended into one buffer, while `out += a + b + c` builds a temporary per
operator. It is 2.5x the instructions of C. What remains, in order (ADR-0043 "Not done"): geometric re-growth of each
buffer (`string_grows` 4.2 M; a capacity hint from the known static length), the temporary string of every converted
integer and escaped value, and one `Html` record plus a second copy per row (component fusion, `map` + `joinAll`).
The generic provider mechanism (ADR-0044) changed none of this: re-measured on the OX branch the counts are identical
(3,991,618,263 / 4,711,876,261 instructions, same allocation counters), since `std:html`'s rules are applied at compile
time and its `@Inline` functions are the same calls as before.

## Benchmark workflow (CI), metrics and history

`.github/workflows/bench.yml` runs `tools/bench.py` on a GitHub-hosted `ubuntu-latest` runner (4 vCPUs, shared) with Go 1.24
(`actions/setup-go`), Temurin Java 21 (`actions/setup-java`), stable Rust (the preinstalled rustup), the preinstalled clang
and valgrind from apt, after the seed bootstrap of `tools/bootstrap.sh`. It does not run on every push.

### Triggering it

| how | what runs | where the result goes |
|---|---|---|
| nightly, 03:57 UTC on `main` (`schedule`) | everything, 5 runs per cell | job summary, artifact `bench-results`, appended to the `bench-results` branch |
| Actions tab -> bench -> "Run workflow" (`workflow_dispatch`) | inputs: `runs` (default 5) and `only` (comma-separated names, empty = all; `selfcompile` in the list adds the self-compile) | as above; a manual run on `main` is also appended to the history, a run on another branch is not |
| add the label `bench` to a pull request (`pull_request: labeled`) | everything for the PR's merge commit | job summary, artifact, and one PR comment comparing with `main` (edited in place when the label is added again or the run is re-run) |

Locally the same numbers come from
`python3 tools/bench.py --runs 1 --only fib,sieve --json build/bench/x.json --instructions` and
`python3 tools/bench_report.py summary build/bench/x.json`.

Permissions are least privilege: the workflow token is `contents: read`; only the `history` job has `contents: write` (to
push to `bench-results`) and only the `compare` job has `pull-requests: write` (to comment). A pull request from a fork gets
a read-only token, so its comparison is only in the job summary. Nothing has to be configured in the repository settings;
the `bench` label is created the first time someone types it in a pull request's label menu.

### Metrics (per benchmark and language, in the JSON written by `--json`)

| field | meaning |
|---|---|
| `wall_median`, `wall_min`, `wall_max` | wall time of the whole process (seconds), `runs` runs after one unrecorded warm-up |
| `user_median`, `sys_median`, `cpu_median` | user, system and user + system CPU time of the process and all its threads (`wait4` rusage, seconds). CPU above wall means parallel work (Go's GC, the JVM's JIT and GC threads, std:task workers) |
| `rss_kb` | peak resident set (`ru_maxrss`, KiB, median); ~1 MiB process-startup floor |
| `output_matched` | stdout identical to the reference (C, else the first language built); a mismatch fails the workflow after the upload |
| `instructions.<lang>.count` | executed instructions (valgrind `cachegrind --cache-sim=no`, "I refs"), one run, for `orin` (C backend), `llvm` and `c`; `args` is set when a reduced input was used, `skipped` holds the reason when the program was not counted |
| `orin_stats` | the runtime counters of `ORIN_STATS=1` |
| `selfcompile` | the same fields for `orin2 compile compiler/main.or`, plus `identical_to_stage2` and its instruction count |
| `parallel.<name>.threads.<n>` | the same timing fields with `n` worker threads, plus `speedup` = wall(1) / wall(n), `efficiency` = speedup / n, `cpu_ratio` = CPU(n) / CPU(1) |

The top level records `commit`, `ref`, `date` (UTC), `runs`, `only`, `machine` (CPU model, core count, memory, OS, runner),
`tools` (cc, clang, go, java, rustc, valgrind, python versions) and `mismatches`; `schema` is 1.

**Why instruction counts are the regression metric.** On a shared runner the wall time of a byte-identical binary moves by
10-25 % between runs (the A/B runs above show +-25 % on `sieve` from identical C), so a 5 % regression is invisible in it.
The number of executed instructions of a single-threaded, deterministic program is the same on every run and every runner
(it changes with the compiler, the runtime and the C compiler version, which the JSON records), so a change of more than 2 %
is a real change in the code that runs. It does not see cache misses, branch mispredictions or memory-bandwidth effects, which
is why the wall time is still reported and compared with a wide (15 %) threshold. valgrind costs 20-50x the native time; the
whole instruction pass is a few minutes. Conventions for a benchmark that is too slow under valgrind: a file
`bench/<name>/instructions.args` holds arguments for a smaller input (the JSON records them and the PR comparison does not
compare such counts with full-size ones), `bench/<name>/instructions.skip` holds the reason to skip it; a run over
`--instr-timeout` (900 s) is skipped with that reason. Multi-threaded programs (`bench/tasks`, the parallel benchmarks) are
skipped, because valgrind serialises threads.

**Parallel speedup.** `bench/parallel_*/` and `bench/streams_parallel/` (picked up automatically when present) take the
number of worker threads as their first command-line argument; `tools/bench.py` also sets `ORIN_BENCH_THREADS`. std:task has
no thread pool, every task is one OS thread, so for `bench/parallel_*` the worker count is the `parts` argument of
`parallelMap` (or the number of tasks the program spawns). `bench/streams_parallel` uses `parallel()`, whose pool reads
`ORIN_THREADS` (also set); it picks its workload by its first argument and runs `parheavy` in this section (`PAR_ARGV` in
`tools/bench.py`; before 2026-10-15 it got the thread count as its workload argument and measured the default workload
with the default pool size). Each program runs with 1, 2 and 4 threads (`--threads`); the output
must not depend on the count. `bench/parallel_collatz` is the Collatz-steps map of `examples/parallel_map.or` over
1..2,000,000 with deterministic output. With more threads than free cores the speedup flattens; `cpu_ratio` above 1 shows the
cost of copying chunks, joining and oversubscription.

### The job summary and the PR comment

The job summary has: wall time of Orin (C and LLVM backend), C, Go, Java and Rust; ratios to C; CPU time and RSS; executed
instructions with the Orin/C ratios; the parallel table (wall, CPU, speedup, efficiency); the self-compile (time, CPU, RSS,
instructions). The PR comment (`tools/bench_report.py compare`) is one table per Orin binary and benchmark plus the
self-compile: instructions on `main` and on the PR, wall time on `main` and on the PR, the changes, and a verdict:
**regression (instructions)** above +2 %, **regression (wall time)** above +15 %, *improvement* below -2 % instructions. The
baseline of each row is the newest `main` entry of the history that has that row. The comment only reports; the job does not
fail on a regression.

### History: the `bench-results` branch

An orphan branch of this repository, created by the first run on `main` and only fast-forwarded afterwards (commits by
`github-actions[bot]`, with the workflow's `GITHUB_TOKEN`):

    history/<YYYY-MM-DD>-<sha12>.json   one bench.py --json result per run on main
    charts/ratio_wall.svg               Orin (C / LLVM backend) / C wall-time ratio per benchmark over time (small multiples)
    charts/ratio_instructions.svg       the same ratio by executed instructions (stable)
    charts/selfcompile.svg              self-compile instructions and wall time over time
    charts/parallel.svg                 speedup by worker threads (latest run, with the ideal line) and at 4 threads over time
    README.md                           the charts, the latest run's tables, the list of runs

`tools/bench_report.py render --history history --out .` regenerates the charts and the README (stdlib only). Opening the
branch on GitHub shows the README with the charts; no GitHub Pages. The SVGs have their own light background, axis titles, a
legend and a `<title>` / `<desc>`; under a dark system color scheme they switch to the dark steps of the same palette.
