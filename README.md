# Orin benchmark history

Written by `.github/workflows/bench.yml` (nightly and manual runs on `main`); one JSON file per run in [`history/`](history/), charts rendered by `tooling/benchmarks` (`bench-report render`, no external services). The same data as a stand-alone page: [`report.html`](report.html). Metrics and methodology: `docs/benchmarks.md` on `main`. Do not edit this branch by hand.

8 runs, 2026-10-14 to 2026-10-22. Latest: [`7635a6de4b`](https://github.com/HenrySchwerdt/orin/commit/7635a6de4ba00d5f68f1c6355860428eaad22201).

Instruction counts are the regression metric: they are deterministic for single-threaded programs, while wall time on a shared runner moves by 10-25 % between identical binaries.

![Orin to C wall-time ratio per benchmark over time](charts/ratio_wall.svg)

![Orin to C executed-instruction ratio per benchmark over time](charts/ratio_instructions.svg)

![Self-compile instructions and wall time over time](charts/selfcompile.svg)

![Parallel speedup by worker threads](charts/parallel.svg)

## Latest run


Commit `7635a6de4b` (main), 2026-10-22T09:18:06Z. Machine: AMD EPYC 9V45 96-Core Processor, 4 cores, 15.6 GiB, Linux-6.17.0-1022-azure-x86_64-with-glibc2.39. Runs per cell: 5 (median after one warm-up).

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
| appends | 0.005 (0.005-0.005) | 0.004 (0.004-0.004) | 0.003 (0.003-0.003) | 0.004 (0.003-0.005) | 0.049 (0.042-0.051) | 0.003 (0.003-0.003) |
| bintrees | 0.230 (0.228-0.239) | 0.241 (0.237-0.243) | 0.301 (0.296-0.361) | 0.691 (0.681-0.715) | 0.120 (0.118-0.122) | 0.374 (0.368-0.378) |
| bytesstr | 0.019 (0.019-0.019) | 0.015 (0.015-0.016) | 0.011 (0.011-0.011) | 0.004 (0.004-0.005) | 0.042 (0.042-0.046) | 0.025 (0.025-0.026) |
| fib | 0.187 (0.186-0.193) | 0.177 (0.176-0.180) | 0.109 (0.099-0.131) | 0.352 (0.351-0.358) | 0.261 (0.250-0.291) | 0.191 (0.191-0.193) |
| html | 0.083 (0.082-0.086) | 0.067 (0.066-0.070) | 0.081 (0.079-0.081) | 0.128 (0.125-0.147) | n/a | n/a |
| html_hand | 0.068 (0.066-0.101) | 0.051 (0.050-0.051) | n/a | n/a | n/a | n/a |
| http_parse | 0.065 (0.065-0.065) | 0.055 (0.055-0.056) | n/a | n/a | n/a | n/a |
| mapfreq | 0.087 (0.087-0.088) | 0.088 (0.088-0.090) | 0.044 (0.042-0.047) | 0.060 (0.058-0.061) | n/a | n/a |
| mutres | 0.091 (0.090-0.092) | 0.072 (0.072-0.074) | 0.020 (0.020-0.020) | 0.022 (0.021-0.022) | 0.055 (0.051-0.056) | 0.024 (0.024-0.024) |
| nbody | 0.042 (0.042-0.043) | 0.042 (0.042-0.042) | 0.042 (0.042-0.042) | 0.054 (0.054-0.055) | n/a | n/a |
| pqueue | 0.089 (0.087-0.091) | 0.073 (0.072-0.074) | 0.045 (0.045-0.046) | 0.114 (0.111-0.119) | 0.125 (0.120-0.128) | 0.051 (0.051-0.052) |
| qsort_func | 0.134 (0.130-0.138) | 0.131 (0.127-0.137) | 0.148 (0.147-0.150) | 0.214 (0.208-0.221) | n/a | n/a |
| qsort_inplace | 0.075 (0.075-0.075) | 0.076 (0.076-0.076) | 0.064 (0.064-0.065) | 0.070 (0.068-0.071) | n/a | n/a |
| sieve | 0.051 (0.050-0.052) | 0.051 (0.050-0.052) | 0.049 (0.049-0.052) | 0.070 (0.069-0.076) | 0.082 (0.081-0.084) | 0.048 (0.047-0.051) |
| sortedmap | 0.149 (0.145-0.172) | 0.150 (0.149-0.152) | n/a | n/a | n/a | n/a |
| streams | 0.058 (0.057-0.062) | 0.050 (0.049-0.050) | n/a | n/a | n/a | n/a |
| strings | 0.043 (0.043-0.044) | 0.043 (0.041-0.043) | 0.038 (0.037-0.039) | 0.031 (0.029-0.032) | 0.124 (0.120-0.130) | 0.016 (0.016-0.018) |
| tasks | 3.103 (3.089-3.185) | 3.074 (3.027-3.152) | n/a | n/a | n/a | n/a |
| url | 0.199 (0.196-0.209) | 0.169 (0.168-0.171) | n/a | n/a | n/a | n/a |
| wordfreq | 0.080 (0.077-0.111) | 0.073 (0.071-0.074) | 0.064 (0.064-0.065) | 0.075 (0.075-0.076) | n/a | n/a |

### Ratio to C (wall-time median; lower is better, 1.00x = as fast as C)

| benchmark | Orin C/C | Orin LLVM/C | Go/C | Java/C | Rust/C |
|---|---:|---:|---:|---:|---:|
| appends | 1.39x | 1.20x | 1.19x | 14.52x | 0.78x |
| bintrees | 0.77x | 0.80x | 2.30x | 0.40x | 1.24x |
| bytesstr | 1.71x | 1.36x | 0.36x | 3.83x | 2.28x |
| fib | 1.72x | 1.63x | 3.24x | 2.40x | 1.76x |
| html | 1.03x | 0.83x | 1.59x | n/a | n/a |
| html_hand | n/a | n/a | n/a | n/a | n/a |
| http_parse | n/a | n/a | n/a | n/a | n/a |
| mapfreq | 1.99x | 2.02x | 1.36x | n/a | n/a |
| mutres | 4.62x | 3.65x | 1.10x | 2.77x | 1.23x |
| nbody | 1.00x | 1.00x | 1.29x | n/a | n/a |
| pqueue | 1.96x | 1.62x | 2.53x | 2.77x | 1.13x |
| qsort_func | 0.90x | 0.89x | 1.45x | n/a | n/a |
| qsort_inplace | 1.17x | 1.18x | 1.09x | n/a | n/a |
| sieve | 1.04x | 1.04x | 1.42x | 1.68x | 0.98x |
| sortedmap | n/a | n/a | n/a | n/a | n/a |
| streams | n/a | n/a | n/a | n/a | n/a |
| strings | 1.13x | 1.12x | 0.82x | 3.27x | 0.43x |
| tasks | n/a | n/a | n/a | n/a | n/a |
| url | n/a | n/a | n/a | n/a | n/a |
| wordfreq | 1.24x | 1.13x | 1.16x | n/a | n/a |

### CPU time (user + sys, median s) and peak RSS (MiB)

| benchmark | orin CPU | llvm CPU | c CPU | go CPU | java CPU | rust CPU | orin RSS | llvm RSS | c RSS | go RSS | java RSS | rust RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| appends | 0.004 | 0.004 | 0.003 | 0.005 | 0.058 | 0.002 | 4.6 | 4.8 | 4.9 | 9.8 | 58.7 | 5.1 |
| bintrees | 0.230 | 0.241 | 0.300 | 1.498 | 0.151 | 0.373 | 17.6 | 17.9 | 9.7 | 14.4 | 307.8 | 10.1 |
| bytesstr | 0.019 | 0.015 | 0.011 | 0.005 | 0.055 | 0.025 | 11.6 | 11.9 | 11.7 | 7.8 | 108.2 | 5.0 |
| fib | 0.187 | 0.176 | 0.108 | 0.352 | 0.269 | 0.191 | 1.6 | 1.9 | 1.6 | 3.4 | 47.5 | 2.0 |
| html | 0.083 | 0.067 | 0.081 | 0.168 | n/a | n/a | 3.9 | 4.2 | 2.2 | 8.3 | n/a | n/a |
| html_hand | 0.068 | 0.050 | n/a | n/a | n/a | n/a | 2.5 | 2.9 | n/a | n/a | n/a | n/a |
| http_parse | 0.065 | 0.055 | n/a | n/a | n/a | n/a | 1.7 | 2.1 | n/a | n/a | n/a | n/a |
| mapfreq | 0.087 | 0.088 | 0.043 | 0.067 | n/a | n/a | 11.4 | 11.6 | 5.2 | 9.8 | n/a | n/a |
| mutres | 0.091 | 0.072 | 0.020 | 0.022 | 0.072 | 0.024 | 1.6 | 1.9 | 1.6 | 3.4 | 47.8 | 2.1 |
| nbody | 0.042 | 0.042 | 0.042 | 0.055 | n/a | n/a | 1.9 | 1.9 | 2.0 | 3.4 | n/a | n/a |
| pqueue | 0.088 | 0.073 | 0.045 | 0.118 | 0.175 | 0.051 | 6.2 | 6.5 | 4.9 | 16.0 | 70.5 | 5.1 |
| qsort_func | 0.134 | 0.130 | 0.148 | 0.259 | n/a | n/a | 36.5 | 36.8 | 23.7 | 38.6 | n/a | n/a |
| qsort_inplace | 0.075 | 0.075 | 0.064 | 0.076 | n/a | n/a | 16.8 | 17.1 | 16.9 | 23.5 | n/a | n/a |
| sieve | 0.050 | 0.050 | 0.049 | 0.111 | 0.100 | 0.047 | 79.1 | 79.7 | 79.0 | 187.6 | 124.6 | 79.1 |
| sortedmap | 0.149 | 0.150 | n/a | n/a | n/a | n/a | 11.3 | 11.5 | n/a | n/a | n/a | n/a |
| streams | 0.058 | 0.049 | n/a | n/a | n/a | n/a | 42.7 | 41.4 | n/a | n/a | n/a | n/a |
| strings | 0.043 | 0.042 | 0.038 | 0.035 | 0.255 | 0.016 | 47.5 | 47.8 | 36.5 | 25.6 | 145.2 | 20.9 |
| tasks | 3.471 | 3.396 | n/a | n/a | n/a | n/a | 18.2 | 18.6 | n/a | n/a | n/a | n/a |
| url | 0.198 | 0.169 | n/a | n/a | n/a | n/a | 6.5 | 6.8 | n/a | n/a | n/a | n/a |
| wordfreq | 0.079 | 0.072 | 0.064 | 0.076 | n/a | n/a | 2.4 | 2.6 | 2.0 | 7.8 | n/a | n/a |

### Executed instructions (valgrind; the regression metric)

| benchmark | Orin C | Orin LLVM | C | Orin C/C | Orin LLVM/C | note |
|---|---:|---:|---:|---:|---:|---|
| appends | 63,530,224 | 44,305,216 | 25,381,155 | 2.50x | 1.75x |  |
| bintrees | 4,457,305,570 | 4,319,515,260 | 7,242,293,433 | 0.62x | 0.60x |  |
| bytesstr | 349,907,901 | 259,441,192 | 178,695,497 | 1.96x | 1.45x |  |
| fib | 3,200,318,135 | 2,483,953,775 | 3,170,983,196 | 1.01x | 0.78x |  |
| html | 1,784,203,908 | 1,471,870,971 | 1,581,660,500 | 1.13x | 0.93x |  |
| html_hand | 1,332,890,919 | 987,886,037 | n/a | n/a | n/a |  |
| http_parse | 1,539,178,546 | 1,358,991,087 | n/a | n/a | n/a |  |
| mapfreq | 1,050,624,779 | 995,125,487 | 717,968,445 | 1.46x | 1.39x |  |
| mutres | 2,541,530,953 | 2,030,255,622 | 291,450,124 | 8.72x | 6.97x |  |
| nbody | 658,315,521 | 772,258,305 | 651,230,696 | 1.01x | 1.19x |  |
| pqueue | 1,411,252,308 | 1,344,413,179 | 355,213,566 | 3.97x | 3.78x |  |
| qsort_func | 1,329,379,237 | 1,269,367,685 | 1,528,677,733 | 0.87x | 0.83x |  |
| qsort_inplace | 576,878,278 | 521,077,518 | 273,751,959 | 2.11x | 1.90x |  |
| sieve | 410,343,299 | 456,726,111 | 191,756,542 | 2.14x | 2.38x |  |
| sortedmap | 1,356,615,067 | 1,358,427,082 | n/a | n/a | n/a |  |
| streams | 1,173,755,250 | 1,173,731,305 | n/a | n/a | n/a |  |
| strings | 647,532,803 | 559,940,876 | 685,893,540 | 0.94x | 0.82x |  |
| tasks | n/a | n/a | n/a | n/a | n/a | llvm skipped: multi-threaded (20,000 tasks, channels): valgrind serialises threads, so the count would include scheduler waits; orin skipped: multi-threaded (20,000 tasks, channels): valgrind serialises threads, so the count would include scheduler waits |
| url | 4,852,179,700 | 4,363,458,739 | n/a | n/a | n/a |  |
| wordfreq | 760,378,206 | 707,684,209 | 880,488,803 | 0.86x | 0.80x |  |

### Parallel speedup (std:task; worker threads = first argument of the program)

| benchmark | threads | wall s (min-max) | CPU s (user+sys) | speedup | efficiency | CPU vs 1 thread | output |
|---|---:|---:|---:|---:|---:|---:|---|
| parallel_collatz | 1 | 0.386 (0.384-0.387) | 0.386 | 1.00x | 100 % | 1.00x | same |
| parallel_collatz | 2 | 0.211 (0.210-0.217) | 0.395 | 1.83x | 91 % | 1.02x | same |
| parallel_collatz | 4 | 0.130 (0.128-0.131) | 0.460 | 2.97x | 74 % | 1.19x | same |
| streams_parallel | 1 | 0.426 (0.425-0.442) | 0.426 | 1.00x | 100 % | 1.00x | same |
| streams_parallel | 2 | 0.220 (0.219-0.222) | 0.430 | 1.94x | 97 % | 1.01x | same |
| streams_parallel | 4 | 0.139 (0.138-0.139) | 0.527 | 3.07x | 77 % | 1.24x | same |

Speedup = wall(1 thread) / wall(n); efficiency = speedup / n. CPU time that grows with n is overhead or oversubscription (more threads than free cores).

### Self-compile (orin2 compiles compiler/main.or)

| wall s (min-max) | CPU s | peak RSS MiB | instructions | output identical to stage2.c |
|---:|---:|---:|---:|---|
| 1.939 (1.834-2.009) | 3.062 | 399.2 | 28,927,908,288 | yes |


## All runs

| date | commit | ref | self-compile instructions | self-compile wall s | file |
|---|---|---|---:|---:|---|
| 2026-10-22T09:18:06Z | `7635a6de4b` | main | 28,927,908,288 | 1.939 | [json](history/2026-10-22-7635a6de4ba0.json) |
| 2026-10-21T09:16:22Z | `7635a6de4b` | main | 28,929,128,127 | 2.146 | [json](history/2026-10-21-7635a6de4ba0.json) |
| 2026-10-20T09:21:19Z | `7635a6de4b` | main | 28,924,224,488 | 2.688 | [json](history/2026-10-20-7635a6de4ba0.json) |
| 2026-10-19T09:49:07Z | `7635a6de4b` | main | 28,920,330,777 | 2.632 | [json](history/2026-10-19-7635a6de4ba0.json) |
| 2026-10-18T08:43:59Z | `7635a6de4b` | main | 28,927,449,240 | 2.360 | [json](history/2026-10-18-7635a6de4ba0.json) |
| 2026-10-17T08:29:19Z | `d0a17a9682` | main | 26,314,861,202 | 2.370 | [json](history/2026-10-17-d0a17a968285.json) |
| 2026-10-16T08:55:17Z | `9f83f16af4` | main | 24,496,056,957 | 2.438 | [json](history/2026-10-16-9f83f16af402.json) |
| 2026-10-14T17:32:27Z | `f837889af7` | main | 35,729,157,194 | 3.937 | [json](history/2026-10-14-f837889af7a9.json) |
