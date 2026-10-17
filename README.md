# Orin benchmark history

Written by `.github/workflows/bench.yml` (nightly and manual runs on `main`); one JSON file per run in [`history/`](history/), charts rendered by `tooling/benchmarks` (`bench-report render`, no external services). The same data as a stand-alone page: [`report.html`](report.html). Metrics and methodology: `docs/benchmarks.md` on `main`. Do not edit this branch by hand.

3 runs, 2026-10-14 to 2026-10-17. Latest: [`d0a17a9682`](https://github.com/HenrySchwerdt/orin/commit/d0a17a9682851c10e7fee7836fc562f4a9a93e4e).

Instruction counts are the regression metric: they are deterministic for single-threaded programs, while wall time on a shared runner moves by 10-25 % between identical binaries.

![Orin to C wall-time ratio per benchmark over time](charts/ratio_wall.svg)

![Orin to C executed-instruction ratio per benchmark over time](charts/ratio_instructions.svg)

![Self-compile instructions and wall time over time](charts/selfcompile.svg)

![Parallel speedup by worker threads](charts/parallel.svg)

## Latest run


Commit `d0a17a9682` (main), 2026-10-17T08:29:19Z. Machine: AMD EPYC 7763 64-Core Processor, 4 cores, 15.6 GiB, Linux-6.17.0-1022-azure-x86_64-with-glibc2.39. Runs per cell: 5 (median after one warm-up).

<details><summary>Tool versions</summary>

- cc: `cc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0`
- clang: `Ubuntu clang version 18.1.3 (1ubuntu1)`
- go: `go version go1.24.13 linux/amd64`
- java: `openjdk version "21.0.12.1" 2026-08-18 LTS`
- python: `3.12.3`
- rustc: `rustc 1.99.1 (58cf8f9c3 2026-10-13)`
- valgrind: `valgrind-3.22.0`

</details>

### Wall time, seconds (median; min-max)

| benchmark | Orin (C backend) | Orin (LLVM backend) | C | Go | Java | Rust |
|---|---:|---:|---:|---:|---:|---:|
| appends | 0.009 (0.009-0.009) | 0.007 (0.007-0.008) | 0.005 (0.005-0.007) | 0.007 (0.006-0.008) | 0.068 (0.058-0.078) | 0.005 (0.004-0.005) |
| bintrees | 0.404 (0.400-0.405) | 0.397 (0.396-0.409) | 0.538 (0.537-0.541) | 1.294 (1.279-1.299) | 0.216 (0.213-0.221) | 0.707 (0.706-0.716) |
| bytesstr | 0.035 (0.032-0.041) | 0.028 (0.028-0.028) | 0.018 (0.017-0.019) | 0.006 (0.006-0.009) | 0.067 (0.062-0.068) | 0.035 (0.035-0.036) |
| fib | 0.321 (0.318-0.327) | 0.275 (0.274-0.277) | 0.198 (0.198-0.201) | 0.601 (0.598-0.605) | 0.425 (0.418-0.435) | 0.314 (0.313-0.314) |
| html | 0.171 (0.171-0.173) | 0.144 (0.142-0.145) | 0.174 (0.167-0.183) | 0.236 (0.231-0.258) | n/a | n/a |
| html_hand | 0.132 (0.131-0.135) | 0.106 (0.105-0.109) | n/a | n/a | n/a | n/a |
| http_parse | 0.133 (0.133-0.134) | 0.114 (0.112-0.115) | n/a | n/a | n/a | n/a |
| mapfreq | 0.154 (0.153-0.154) | 0.155 (0.153-0.157) | 0.074 (0.073-0.079) | 0.112 (0.111-0.113) | n/a | n/a |
| mutres | 0.174 (0.173-0.174) | 0.134 (0.134-0.135) | 0.033 (0.032-0.034) | 0.045 (0.044-0.045) | 0.085 (0.081-0.089) | 0.038 (0.038-0.038) |
| nbody | 0.070 (0.070-0.070) | 0.078 (0.078-0.079) | 0.070 (0.070-0.070) | 0.088 (0.086-0.088) | n/a | n/a |
| pqueue | 0.148 (0.148-0.149) | 0.127 (0.125-0.127) | 0.064 (0.063-0.064) | 0.188 (0.187-0.190) | 0.204 (0.198-0.209) | 0.090 (0.089-0.090) |
| qsort_func | 0.209 (0.205-0.210) | 0.204 (0.201-0.208) | 0.228 (0.226-0.229) | 0.342 (0.333-0.359) | n/a | n/a |
| qsort_inplace | 0.106 (0.105-0.106) | 0.106 (0.106-0.107) | 0.081 (0.081-0.081) | 0.090 (0.090-0.094) | n/a | n/a |
| sieve | 0.092 (0.087-0.094) | 0.095 (0.095-0.100) | 0.081 (0.080-0.084) | 0.138 (0.130-0.149) | 0.143 (0.137-0.146) | 0.085 (0.085-0.109) |
| sortedmap | 0.251 (0.245-0.253) | 0.261 (0.259-0.263) | n/a | n/a | n/a | n/a |
| streams | 0.108 (0.107-0.109) | 0.095 (0.094-0.095) | n/a | n/a | n/a | n/a |
| strings | 0.073 (0.072-0.073) | 0.071 (0.070-0.072) | 0.073 (0.073-0.074) | 0.055 (0.052-0.058) | 0.207 (0.199-0.215) | 0.028 (0.028-0.037) |
| tasks | 4.950 (4.918-5.076) | 4.944 (4.781-5.107) | n/a | n/a | n/a | n/a |
| url | 0.384 (0.383-0.386) | 0.320 (0.318-0.320) | n/a | n/a | n/a | n/a |
| wordfreq | 0.125 (0.124-0.126) | 0.126 (0.125-0.135) | 0.111 (0.110-0.123) | 0.110 (0.110-0.112) | n/a | n/a |

### Ratio to C (wall-time median; lower is better, 1.00x = as fast as C)

| benchmark | Orin C/C | Orin LLVM/C | Go/C | Java/C | Rust/C |
|---|---:|---:|---:|---:|---:|
| appends | 1.68x | 1.45x | 1.40x | 13.17x | 0.88x |
| bintrees | 0.75x | 0.74x | 2.41x | 0.40x | 1.31x |
| bytesstr | 1.90x | 1.53x | 0.36x | 3.68x | 1.92x |
| fib | 1.62x | 1.39x | 3.03x | 2.14x | 1.58x |
| html | 0.99x | 0.83x | 1.36x | n/a | n/a |
| html_hand | n/a | n/a | n/a | n/a | n/a |
| http_parse | n/a | n/a | n/a | n/a | n/a |
| mapfreq | 2.08x | 2.10x | 1.52x | n/a | n/a |
| mutres | 5.32x | 4.12x | 1.38x | 2.60x | 1.17x |
| nbody | 1.00x | 1.12x | 1.25x | n/a | n/a |
| pqueue | 2.34x | 2.00x | 2.96x | 3.21x | 1.41x |
| qsort_func | 0.92x | 0.90x | 1.50x | n/a | n/a |
| qsort_inplace | 1.30x | 1.31x | 1.12x | n/a | n/a |
| sieve | 1.13x | 1.17x | 1.70x | 1.76x | 1.04x |
| sortedmap | n/a | n/a | n/a | n/a | n/a |
| streams | n/a | n/a | n/a | n/a | n/a |
| strings | 1.00x | 0.97x | 0.75x | 2.85x | 0.39x |
| tasks | n/a | n/a | n/a | n/a | n/a |
| url | n/a | n/a | n/a | n/a | n/a |
| wordfreq | 1.13x | 1.13x | 0.99x | n/a | n/a |

### CPU time (user + sys, median s) and peak RSS (MiB)

| benchmark | orin CPU | llvm CPU | c CPU | go CPU | java CPU | rust CPU | orin RSS | llvm RSS | c RSS | go RSS | java RSS | rust RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| appends | 0.008 | 0.007 | 0.005 | 0.010 | 0.097 | 0.004 | 4.5 | 4.7 | 4.7 | 9.8 | 58.6 | 5.0 |
| bintrees | 0.403 | 0.396 | 0.538 | 2.818 | 0.271 | 0.707 | 17.5 | 17.7 | 9.5 | 14.4 | 307.9 | 10.1 |
| bytesstr | 0.034 | 0.028 | 0.018 | 0.009 | 0.084 | 0.035 | 11.5 | 11.7 | 11.5 | 9.8 | 108.1 | 4.8 |
| fib | 0.320 | 0.274 | 0.198 | 0.603 | 0.439 | 0.313 | 1.5 | 1.8 | 1.5 | 3.4 | 47.4 | 2.0 |
| html | 0.171 | 0.144 | 0.173 | 0.317 | n/a | n/a | 3.7 | 4.1 | 2.1 | 8.4 | n/a | n/a |
| html_hand | 0.131 | 0.106 | n/a | n/a | n/a | n/a | 2.4 | 2.8 | n/a | n/a | n/a | n/a |
| http_parse | 0.133 | 0.112 | n/a | n/a | n/a | n/a | 1.6 | 2.0 | n/a | n/a | n/a | n/a |
| mapfreq | 0.153 | 0.155 | 0.074 | 0.127 | n/a | n/a | 11.3 | 11.6 | 5.1 | 10.0 | n/a | n/a |
| mutres | 0.173 | 0.134 | 0.032 | 0.046 | 0.115 | 0.038 | 1.5 | 1.8 | 1.5 | 3.4 | 47.7 | 2.1 |
| nbody | 0.070 | 0.078 | 0.070 | 0.088 | n/a | n/a | 1.8 | 1.8 | 1.8 | 3.4 | n/a | n/a |
| pqueue | 0.148 | 0.127 | 0.063 | 0.193 | 0.276 | 0.089 | 6.1 | 6.4 | 4.7 | 16.1 | 70.3 | 5.0 |
| qsort_func | 0.209 | 0.204 | 0.227 | 0.408 | n/a | n/a | 36.4 | 36.8 | 23.6 | 40.6 | n/a | n/a |
| qsort_inplace | 0.105 | 0.106 | 0.081 | 0.102 | n/a | n/a | 16.7 | 17.1 | 16.8 | 31.9 | n/a | n/a |
| sieve | 0.092 | 0.095 | 0.081 | 0.185 | 0.172 | 0.085 | 79.0 | 79.4 | 78.4 | 316.1 | 124.5 | 79.6 |
| sortedmap | 0.250 | 0.261 | n/a | n/a | n/a | n/a | 11.1 | 11.4 | n/a | n/a | n/a | n/a |
| streams | 0.108 | 0.095 | n/a | n/a | n/a | n/a | 41.0 | 40.8 | n/a | n/a | n/a | n/a |
| strings | 0.072 | 0.070 | 0.072 | 0.062 | 0.419 | 0.028 | 47.4 | 47.7 | 36.4 | 23.7 | 145.6 | 20.8 |
| tasks | 5.573 | 5.461 | n/a | n/a | n/a | n/a | 15.9 | 16.4 | n/a | n/a | n/a | n/a |
| url | 0.383 | 0.319 | n/a | n/a | n/a | n/a | 6.4 | 6.7 | n/a | n/a | n/a | n/a |
| wordfreq | 0.125 | 0.125 | 0.111 | 0.113 | n/a | n/a | 2.2 | 2.5 | 1.9 | 7.8 | n/a | n/a |

### Executed instructions (valgrind; the regression metric)

| benchmark | Orin C | Orin LLVM | C | Orin C/C | Orin LLVM/C | note |
|---|---:|---:|---:|---:|---:|---|
| appends | 63,529,216 | 44,304,947 | 25,381,155 | 2.50x | 1.75x |  |
| bintrees | 4,457,304,562 | 4,319,515,014 | 7,242,293,433 | 0.62x | 0.60x |  |
| bytesstr | 349,906,893 | 259,440,923 | 178,695,497 | 1.96x | 1.45x |  |
| fib | 3,200,317,127 | 2,483,953,529 | 3,170,983,196 | 1.01x | 0.78x |  |
| html | 1,784,202,882 | 1,471,870,551 | 1,581,660,500 | 1.13x | 0.93x |  |
| html_hand | 1,332,889,893 | 987,885,617 | n/a | n/a | n/a |  |
| http_parse | 1,539,177,520 | 1,359,012,626 | n/a | n/a | n/a |  |
| mapfreq | 1,050,623,771 | 995,125,218 | 717,968,445 | 1.46x | 1.39x |  |
| mutres | 2,541,529,945 | 2,030,255,376 | 291,450,124 | 8.72x | 6.97x |  |
| nbody | 658,314,420 | 772,257,961 | 651,230,696 | 1.01x | 1.19x |  |
| pqueue | 1,411,251,300 | 1,344,412,910 | 355,213,566 | 3.97x | 3.78x |  |
| qsort_func | 1,329,378,229 | 1,269,367,416 | 1,528,677,733 | 0.87x | 0.83x |  |
| qsort_inplace | 576,877,270 | 521,077,249 | 273,751,959 | 2.11x | 1.90x |  |
| sieve | 410,342,291 | 456,725,842 | 191,756,542 | 2.14x | 2.38x |  |
| sortedmap | 1,356,614,059 | 1,358,426,813 | n/a | n/a | n/a |  |
| streams | 1,173,754,242 | 1,173,731,036 | n/a | n/a | n/a |  |
| strings | 647,531,795 | 559,940,607 | 685,893,540 | 0.94x | 0.82x |  |
| tasks | n/a | n/a | n/a | n/a | n/a | llvm skipped: multi-threaded (20,000 tasks, channels): valgrind serialises threads, so the count would include scheduler waits; orin skipped: multi-threaded (20,000 tasks, channels): valgrind serialises threads, so the count would include scheduler waits |
| url | 4,852,178,692 | 4,363,458,470 | n/a | n/a | n/a |  |
| wordfreq | 760,377,198 | 707,683,940 | 880,488,803 | 0.86x | 0.80x |  |

### Parallel speedup (std:task; worker threads = first argument of the program)

| benchmark | threads | wall s (min-max) | CPU s (user+sys) | speedup | efficiency | CPU vs 1 thread | output |
|---|---:|---:|---:|---:|---:|---:|---|
| parallel_collatz | 1 | 0.482 (0.481-0.483) | 0.481 | 1.00x | 100 % | 1.00x | same |
| parallel_collatz | 2 | 0.266 (0.266-0.268) | 0.496 | 1.81x | 90 % | 1.03x | same |
| parallel_collatz | 4 | 0.189 (0.188-0.194) | 0.658 | 2.55x | 64 % | 1.37x | same |
| streams_parallel | 1 | 0.485 (0.485-0.486) | 0.485 | 1.00x | 100 % | 1.00x | same |
| streams_parallel | 2 | 0.250 (0.250-0.251) | 0.486 | 1.94x | 97 % | 1.00x | same |
| streams_parallel | 4 | 0.164 (0.164-0.165) | 0.613 | 2.96x | 74 % | 1.26x | same |

Speedup = wall(1 thread) / wall(n); efficiency = speedup / n. CPU time that grows with n is overhead or oversubscription (more threads than free cores).

### Self-compile (orin2 compiles compiler/main.or)

| wall s (min-max) | CPU s | peak RSS MiB | instructions | output identical to stage2.c |
|---:|---:|---:|---:|---|
| 2.370 (2.349-2.395) | 4.202 | 349.8 | 26,314,861,202 | yes |


## All runs

| date | commit | ref | self-compile instructions | self-compile wall s | file |
|---|---|---|---:|---:|---|
| 2026-10-17T08:29:19Z | `d0a17a9682` | main | 26,314,861,202 | 2.370 | [json](history/2026-10-17-d0a17a968285.json) |
| 2026-10-16T08:55:17Z | `9f83f16af4` | main | 24,496,056,957 | 2.438 | [json](history/2026-10-16-9f83f16af402.json) |
| 2026-10-14T17:32:27Z | `f837889af7` | main | 35,729,157,194 | 3.937 | [json](history/2026-10-14-f837889af7a9.json) |
