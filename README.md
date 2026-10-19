# Orin benchmark history

Written by `.github/workflows/bench.yml` (nightly and manual runs on `main`); one JSON file per run in [`history/`](history/), charts rendered by `tooling/benchmarks` (`bench-report render`, no external services). The same data as a stand-alone page: [`report.html`](report.html). Metrics and methodology: `docs/benchmarks.md` on `main`. Do not edit this branch by hand.

5 runs, 2026-10-14 to 2026-10-19. Latest: [`7635a6de4b`](https://github.com/HenrySchwerdt/orin/commit/7635a6de4ba00d5f68f1c6355860428eaad22201).

Instruction counts are the regression metric: they are deterministic for single-threaded programs, while wall time on a shared runner moves by 10-25 % between identical binaries.

![Orin to C wall-time ratio per benchmark over time](charts/ratio_wall.svg)

![Orin to C executed-instruction ratio per benchmark over time](charts/ratio_instructions.svg)

![Self-compile instructions and wall time over time](charts/selfcompile.svg)

![Parallel speedup by worker threads](charts/parallel.svg)

## Latest run


Commit `7635a6de4b` (main), 2026-10-19T09:49:07Z. Machine: AMD EPYC 7763 64-Core Processor, 4 cores, 15.6 GiB, Linux-6.17.0-1022-azure-x86_64-with-glibc2.39. Runs per cell: 5 (median after one warm-up).

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
| appends | 0.009 (0.009-0.009) | 0.008 (0.008-0.008) | 0.005 (0.005-0.005) | 0.007 (0.006-0.009) | 0.065 (0.061-0.071) | 0.004 (0.004-0.004) |
| bintrees | 0.405 (0.401-0.407) | 0.396 (0.392-0.397) | 0.538 (0.537-0.540) | 1.291 (1.285-1.296) | 0.215 (0.212-0.215) | 0.714 (0.712-0.729) |
| bytesstr | 0.033 (0.033-0.034) | 0.029 (0.028-0.029) | 0.018 (0.017-0.019) | 0.009 (0.007-0.010) | 0.067 (0.064-0.072) | 0.036 (0.035-0.036) |
| fib | 0.296 (0.295-0.296) | 0.326 (0.326-0.326) | 0.198 (0.198-0.198) | 0.599 (0.598-0.604) | 0.421 (0.416-0.435) | 0.314 (0.313-0.314) |
| html | 0.164 (0.163-0.165) | 0.136 (0.136-0.139) | 0.169 (0.166-0.172) | 0.232 (0.228-0.239) | n/a | n/a |
| html_hand | 0.128 (0.127-0.132) | 0.102 (0.098-0.102) | n/a | n/a | n/a | n/a |
| http_parse | 0.129 (0.128-0.129) | 0.115 (0.115-0.116) | n/a | n/a | n/a | n/a |
| mapfreq | 0.154 (0.154-0.155) | 0.156 (0.155-0.157) | 0.076 (0.073-0.077) | 0.111 (0.110-0.112) | n/a | n/a |
| mutres | 0.173 (0.173-0.174) | 0.134 (0.134-0.138) | 0.032 (0.031-0.032) | 0.044 (0.044-0.045) | 0.085 (0.081-0.089) | 0.038 (0.038-0.038) |
| nbody | 0.070 (0.070-0.071) | 0.078 (0.078-0.079) | 0.070 (0.070-0.070) | 0.088 (0.086-0.089) | n/a | n/a |
| pqueue | 0.154 (0.150-0.159) | 0.131 (0.129-0.142) | 0.065 (0.064-0.065) | 0.193 (0.187-0.198) | 0.212 (0.197-0.216) | 0.089 (0.089-0.090) |
| qsort_func | 0.207 (0.206-0.209) | 0.205 (0.204-0.212) | 0.229 (0.229-0.230) | 0.340 (0.340-0.346) | n/a | n/a |
| qsort_inplace | 0.105 (0.105-0.106) | 0.107 (0.106-0.108) | 0.081 (0.081-0.081) | 0.091 (0.089-0.093) | n/a | n/a |
| sieve | 0.088 (0.086-0.090) | 0.089 (0.088-0.094) | 0.077 (0.074-0.079) | 0.122 (0.112-0.125) | 0.126 (0.125-0.129) | 0.080 (0.077-0.082) |
| sortedmap | 0.248 (0.247-0.254) | 0.258 (0.257-0.261) | n/a | n/a | n/a | n/a |
| streams | 0.105 (0.105-0.106) | 0.082 (0.082-0.083) | n/a | n/a | n/a | n/a |
| strings | 0.072 (0.072-0.073) | 0.070 (0.069-0.071) | 0.073 (0.072-0.074) | 0.055 (0.052-0.057) | 0.204 (0.192-0.207) | 0.028 (0.027-0.028) |
| tasks | 4.869 (4.803-4.933) | 4.884 (4.711-4.947) | n/a | n/a | n/a | n/a |
| url | 0.373 (0.372-0.376) | 0.340 (0.339-0.341) | n/a | n/a | n/a | n/a |
| wordfreq | 0.127 (0.126-0.128) | 0.125 (0.125-0.125) | 0.112 (0.110-0.113) | 0.110 (0.109-0.111) | n/a | n/a |

### Ratio to C (wall-time median; lower is better, 1.00x = as fast as C)

| benchmark | Orin C/C | Orin LLVM/C | Go/C | Java/C | Rust/C |
|---|---:|---:|---:|---:|---:|
| appends | 1.70x | 1.50x | 1.31x | 12.42x | 0.85x |
| bintrees | 0.75x | 0.74x | 2.40x | 0.40x | 1.33x |
| bytesstr | 1.83x | 1.57x | 0.48x | 3.64x | 1.97x |
| fib | 1.49x | 1.64x | 3.02x | 2.13x | 1.58x |
| html | 0.97x | 0.81x | 1.37x | n/a | n/a |
| html_hand | n/a | n/a | n/a | n/a | n/a |
| http_parse | n/a | n/a | n/a | n/a | n/a |
| mapfreq | 2.02x | 2.05x | 1.45x | n/a | n/a |
| mutres | 5.49x | 4.26x | 1.40x | 2.71x | 1.20x |
| nbody | 1.00x | 1.11x | 1.25x | n/a | n/a |
| pqueue | 2.39x | 2.02x | 2.98x | 3.28x | 1.38x |
| qsort_func | 0.90x | 0.89x | 1.48x | n/a | n/a |
| qsort_inplace | 1.29x | 1.32x | 1.12x | n/a | n/a |
| sieve | 1.14x | 1.16x | 1.59x | 1.63x | 1.04x |
| sortedmap | n/a | n/a | n/a | n/a | n/a |
| streams | n/a | n/a | n/a | n/a | n/a |
| strings | 0.99x | 0.96x | 0.75x | 2.79x | 0.38x |
| tasks | n/a | n/a | n/a | n/a | n/a |
| url | n/a | n/a | n/a | n/a | n/a |
| wordfreq | 1.14x | 1.12x | 0.99x | n/a | n/a |

### CPU time (user + sys, median s) and peak RSS (MiB)

| benchmark | orin CPU | llvm CPU | c CPU | go CPU | java CPU | rust CPU | orin RSS | llvm RSS | c RSS | go RSS | java RSS | rust RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| appends | 0.009 | 0.008 | 0.005 | 0.009 | 0.097 | 0.004 | 4.5 | 4.7 | 4.7 | 10.9 | 58.6 | 5.0 |
| bintrees | 0.405 | 0.395 | 0.537 | 2.822 | 0.265 | 0.713 | 17.5 | 17.7 | 9.5 | 14.3 | 307.9 | 10.0 |
| bytesstr | 0.033 | 0.028 | 0.018 | 0.014 | 0.085 | 0.036 | 11.4 | 11.6 | 11.5 | 9.9 | 108.1 | 4.8 |
| fib | 0.295 | 0.326 | 0.198 | 0.601 | 0.432 | 0.313 | 1.5 | 1.8 | 1.5 | 3.4 | 47.5 | 2.0 |
| html | 0.163 | 0.136 | 0.169 | 0.310 | n/a | n/a | 3.7 | 4.0 | 2.1 | 8.4 | n/a | n/a |
| html_hand | 0.127 | 0.101 | n/a | n/a | n/a | n/a | 2.4 | 2.8 | n/a | n/a | n/a | n/a |
| http_parse | 0.129 | 0.115 | n/a | n/a | n/a | n/a | 1.6 | 1.9 | n/a | n/a | n/a | n/a |
| mapfreq | 0.154 | 0.156 | 0.076 | 0.126 | n/a | n/a | 11.3 | 11.5 | 5.1 | 8.0 | n/a | n/a |
| mutres | 0.173 | 0.134 | 0.031 | 0.045 | 0.117 | 0.038 | 1.5 | 1.7 | 1.5 | 3.4 | 47.8 | 2.1 |
| nbody | 0.070 | 0.078 | 0.070 | 0.089 | n/a | n/a | 1.8 | 1.8 | 1.8 | 3.4 | n/a | n/a |
| pqueue | 0.154 | 0.130 | 0.064 | 0.199 | 0.278 | 0.089 | 6.1 | 6.4 | 4.7 | 16.0 | 70.3 | 5.0 |
| qsort_func | 0.206 | 0.204 | 0.229 | 0.410 | n/a | n/a | 36.4 | 36.6 | 23.6 | 41.0 | n/a | n/a |
| qsort_inplace | 0.105 | 0.107 | 0.081 | 0.098 | n/a | n/a | 16.7 | 17.1 | 16.8 | 29.6 | n/a | n/a |
| sieve | 0.087 | 0.089 | 0.077 | 0.170 | 0.154 | 0.080 | 78.5 | 78.8 | 78.3 | 305.9 | 124.6 | 79.6 |
| sortedmap | 0.248 | 0.258 | n/a | n/a | n/a | n/a | 11.1 | 11.4 | n/a | n/a | n/a | n/a |
| streams | 0.105 | 0.082 | n/a | n/a | n/a | n/a | 43.0 | 40.8 | n/a | n/a | n/a | n/a |
| strings | 0.072 | 0.070 | 0.073 | 0.067 | 0.411 | 0.027 | 47.4 | 48.6 | 35.4 | 25.6 | 145.7 | 21.8 |
| tasks | 5.431 | 5.423 | n/a | n/a | n/a | n/a | 18.0 | 18.4 | n/a | n/a | n/a | n/a |
| url | 0.373 | 0.340 | n/a | n/a | n/a | n/a | 6.4 | 6.7 | n/a | n/a | n/a | n/a |
| wordfreq | 0.127 | 0.125 | 0.111 | 0.113 | n/a | n/a | 2.2 | 2.6 | 1.9 | 7.8 | n/a | n/a |

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
| parallel_collatz | 1 | 0.493 (0.491-0.493) | 0.492 | 1.00x | 100 % | 1.00x | same |
| parallel_collatz | 2 | 0.270 (0.270-0.272) | 0.506 | 1.82x | 91 % | 1.03x | same |
| parallel_collatz | 4 | 0.178 (0.177-0.179) | 0.622 | 2.77x | 69 % | 1.26x | same |
| streams_parallel | 1 | 0.479 (0.479-0.480) | 0.479 | 1.00x | 100 % | 1.00x | same |
| streams_parallel | 2 | 0.248 (0.247-0.249) | 0.481 | 1.93x | 97 % | 1.00x | same |
| streams_parallel | 4 | 0.172 (0.172-0.173) | 0.645 | 2.79x | 70 % | 1.35x | same |

Speedup = wall(1 thread) / wall(n); efficiency = speedup / n. CPU time that grows with n is overhead or oversubscription (more threads than free cores).

### Self-compile (orin2 compiles compiler/main.or)

| wall s (min-max) | CPU s | peak RSS MiB | instructions | output identical to stage2.c |
|---:|---:|---:|---:|---|
| 2.632 (2.612-2.676) | 4.733 | 400.4 | 28,920,330,777 | yes |


## All runs

| date | commit | ref | self-compile instructions | self-compile wall s | file |
|---|---|---|---:|---:|---|
| 2026-10-19T09:49:07Z | `7635a6de4b` | main | 28,920,330,777 | 2.632 | [json](history/2026-10-19-7635a6de4ba0.json) |
| 2026-10-18T08:43:59Z | `7635a6de4b` | main | 28,927,449,240 | 2.360 | [json](history/2026-10-18-7635a6de4ba0.json) |
| 2026-10-17T08:29:19Z | `d0a17a9682` | main | 26,314,861,202 | 2.370 | [json](history/2026-10-17-d0a17a968285.json) |
| 2026-10-16T08:55:17Z | `9f83f16af4` | main | 24,496,056,957 | 2.438 | [json](history/2026-10-16-9f83f16af402.json) |
| 2026-10-14T17:32:27Z | `f837889af7` | main | 35,729,157,194 | 3.937 | [json](history/2026-10-14-f837889af7a9.json) |
