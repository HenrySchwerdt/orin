# Orin benchmark history

Written by `.github/workflows/bench.yml` (nightly and manual runs on `main`); one JSON file per run in [`history/`](history/), charts rendered by `tooling/benchmarks` (`bench-report render`, no external services). The same data as a stand-alone page: [`report.html`](report.html). Metrics and methodology: `docs/benchmarks.md` on `main`. Do not edit this branch by hand.

6 runs, 2026-10-14 to 2026-10-20. Latest: [`7635a6de4b`](https://github.com/HenrySchwerdt/orin/commit/7635a6de4ba00d5f68f1c6355860428eaad22201).

Instruction counts are the regression metric: they are deterministic for single-threaded programs, while wall time on a shared runner moves by 10-25 % between identical binaries.

![Orin to C wall-time ratio per benchmark over time](charts/ratio_wall.svg)

![Orin to C executed-instruction ratio per benchmark over time](charts/ratio_instructions.svg)

![Self-compile instructions and wall time over time](charts/selfcompile.svg)

![Parallel speedup by worker threads](charts/parallel.svg)

## Latest run


Commit `7635a6de4b` (main), 2026-10-20T09:21:19Z. Machine: AMD EPYC 7763 64-Core Processor, 4 cores, 15.6 GiB, Linux-6.17.0-1022-azure-x86_64-with-glibc2.39. Runs per cell: 5 (median after one warm-up).

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
| appends | 0.008 (0.008-0.009) | 0.007 (0.007-0.007) | 0.005 (0.005-0.005) | 0.007 (0.006-0.011) | 0.069 (0.061-0.074) | 0.004 (0.004-0.005) |
| bintrees | 0.408 (0.403-0.466) | 0.397 (0.393-0.402) | 0.677 (0.674-0.822) | 1.292 (1.285-1.295) | 0.217 (0.214-0.224) | 0.705 (0.705-0.707) |
| bytesstr | 0.033 (0.033-0.033) | 0.028 (0.027-0.028) | 0.018 (0.017-0.019) | 0.008 (0.007-0.009) | 0.072 (0.065-0.078) | 0.035 (0.035-0.036) |
| fib | 0.296 (0.295-0.296) | 0.326 (0.325-0.326) | 0.198 (0.198-0.198) | 0.598 (0.597-0.599) | 0.426 (0.416-0.437) | 0.314 (0.314-0.317) |
| html | 0.165 (0.163-0.168) | 0.137 (0.135-0.139) | 0.168 (0.166-0.170) | 0.234 (0.226-0.258) | n/a | n/a |
| html_hand | 0.132 (0.128-0.138) | 0.102 (0.102-0.104) | n/a | n/a | n/a | n/a |
| http_parse | 0.129 (0.129-0.130) | 0.115 (0.115-0.116) | n/a | n/a | n/a | n/a |
| mapfreq | 0.155 (0.155-0.155) | 0.157 (0.157-0.159) | 0.074 (0.073-0.079) | 0.112 (0.111-0.112) | n/a | n/a |
| mutres | 0.173 (0.173-0.174) | 0.134 (0.134-0.135) | 0.032 (0.032-0.034) | 0.045 (0.045-0.045) | 0.084 (0.079-0.088) | 0.038 (0.038-0.039) |
| nbody | 0.070 (0.070-0.071) | 0.078 (0.078-0.079) | 0.070 (0.070-0.070) | 0.088 (0.088-0.102) | n/a | n/a |
| pqueue | 0.150 (0.148-0.151) | 0.126 (0.125-0.130) | 0.063 (0.063-0.064) | 0.191 (0.190-0.193) | 0.204 (0.193-0.215) | 0.089 (0.089-0.090) |
| qsort_func | 0.209 (0.205-0.210) | 0.206 (0.202-0.208) | 0.229 (0.228-0.229) | 0.340 (0.332-0.348) | n/a | n/a |
| qsort_inplace | 0.106 (0.105-0.107) | 0.107 (0.106-0.107) | 0.082 (0.082-0.083) | 0.092 (0.090-0.096) | n/a | n/a |
| sieve | 0.095 (0.094-0.096) | 0.098 (0.097-0.099) | 0.082 (0.079-0.087) | 0.135 (0.130-0.136) | 0.138 (0.134-0.138) | 0.087 (0.086-0.090) |
| sortedmap | 0.249 (0.247-0.257) | 0.265 (0.262-0.273) | n/a | n/a | n/a | n/a |
| streams | 0.107 (0.107-0.111) | 0.087 (0.086-0.088) | n/a | n/a | n/a | n/a |
| strings | 0.075 (0.075-0.076) | 0.070 (0.069-0.071) | 0.073 (0.073-0.073) | 0.055 (0.054-0.058) | 0.199 (0.197-0.201) | 0.028 (0.028-0.031) |
| tasks | 4.956 (4.756-5.012) | 4.962 (4.892-5.042) | n/a | n/a | n/a | n/a |
| url | 0.376 (0.375-0.377) | 0.342 (0.342-0.345) | n/a | n/a | n/a | n/a |
| wordfreq | 0.127 (0.127-0.130) | 0.125 (0.124-0.127) | 0.118 (0.112-0.119) | 0.111 (0.110-0.112) | n/a | n/a |

### Ratio to C (wall-time median; lower is better, 1.00x = as fast as C)

| benchmark | Orin C/C | Orin LLVM/C | Go/C | Java/C | Rust/C |
|---|---:|---:|---:|---:|---:|
| appends | 1.66x | 1.44x | 1.35x | 13.51x | 0.88x |
| bintrees | 0.60x | 0.59x | 1.91x | 0.32x | 1.04x |
| bytesstr | 1.87x | 1.58x | 0.44x | 4.06x | 2.01x |
| fib | 1.49x | 1.64x | 3.02x | 2.15x | 1.58x |
| html | 0.98x | 0.81x | 1.39x | n/a | n/a |
| html_hand | n/a | n/a | n/a | n/a | n/a |
| http_parse | n/a | n/a | n/a | n/a | n/a |
| mapfreq | 2.10x | 2.13x | 1.51x | n/a | n/a |
| mutres | 5.36x | 4.15x | 1.38x | 2.60x | 1.18x |
| nbody | 1.01x | 1.12x | 1.26x | n/a | n/a |
| pqueue | 2.37x | 2.00x | 3.03x | 3.24x | 1.41x |
| qsort_func | 0.91x | 0.90x | 1.49x | n/a | n/a |
| qsort_inplace | 1.29x | 1.30x | 1.12x | n/a | n/a |
| sieve | 1.15x | 1.20x | 1.65x | 1.69x | 1.07x |
| sortedmap | n/a | n/a | n/a | n/a | n/a |
| streams | n/a | n/a | n/a | n/a | n/a |
| strings | 1.03x | 0.96x | 0.75x | 2.73x | 0.39x |
| tasks | n/a | n/a | n/a | n/a | n/a |
| url | n/a | n/a | n/a | n/a | n/a |
| wordfreq | 1.08x | 1.07x | 0.95x | n/a | n/a |

### CPU time (user + sys, median s) and peak RSS (MiB)

| benchmark | orin CPU | llvm CPU | c CPU | go CPU | java CPU | rust CPU | orin RSS | llvm RSS | c RSS | go RSS | java RSS | rust RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| appends | 0.008 | 0.007 | 0.005 | 0.010 | 0.095 | 0.004 | 4.5 | 4.7 | 4.7 | 10.8 | 58.7 | 5.0 |
| bintrees | 0.406 | 0.397 | 0.676 | 2.824 | 0.274 | 0.705 | 17.5 | 17.7 | 9.5 | 14.4 | 307.8 | 10.1 |
| bytesstr | 0.033 | 0.028 | 0.017 | 0.011 | 0.086 | 0.035 | 11.5 | 11.7 | 11.5 | 9.9 | 109.5 | 4.8 |
| fib | 0.295 | 0.325 | 0.198 | 0.601 | 0.438 | 0.313 | 1.5 | 1.7 | 1.5 | 3.4 | 47.4 | 1.9 |
| html | 0.164 | 0.136 | 0.168 | 0.316 | n/a | n/a | 3.7 | 4.1 | 2.1 | 8.2 | n/a | n/a |
| html_hand | 0.132 | 0.102 | n/a | n/a | n/a | n/a | 2.4 | 2.7 | n/a | n/a | n/a | n/a |
| http_parse | 0.129 | 0.115 | n/a | n/a | n/a | n/a | 1.6 | 2.0 | n/a | n/a | n/a | n/a |
| mapfreq | 0.155 | 0.157 | 0.074 | 0.129 | n/a | n/a | 11.3 | 11.6 | 5.0 | 8.0 | n/a | n/a |
| mutres | 0.173 | 0.134 | 0.032 | 0.045 | 0.114 | 0.038 | 1.5 | 1.9 | 1.5 | 3.4 | 47.8 | 2.0 |
| nbody | 0.070 | 0.078 | 0.070 | 0.089 | n/a | n/a | 1.8 | 1.8 | 1.8 | 3.4 | n/a | n/a |
| pqueue | 0.149 | 0.126 | 0.063 | 0.197 | 0.271 | 0.089 | 6.1 | 6.3 | 4.7 | 16.1 | 70.4 | 5.0 |
| qsort_func | 0.208 | 0.205 | 0.228 | 0.409 | n/a | n/a | 36.4 | 36.7 | 23.6 | 40.6 | n/a | n/a |
| qsort_inplace | 0.106 | 0.106 | 0.082 | 0.099 | n/a | n/a | 16.7 | 17.0 | 16.8 | 29.8 | n/a | n/a |
| sieve | 0.094 | 0.098 | 0.082 | 0.182 | 0.167 | 0.087 | 78.5 | 78.8 | 78.9 | 226.1 | 124.6 | 79.6 |
| sortedmap | 0.249 | 0.265 | n/a | n/a | n/a | n/a | 11.1 | 11.4 | n/a | n/a | n/a | n/a |
| streams | 0.107 | 0.086 | n/a | n/a | n/a | n/a | 42.5 | 41.6 | n/a | n/a | n/a | n/a |
| strings | 0.075 | 0.069 | 0.073 | 0.064 | 0.416 | 0.028 | 48.3 | 47.8 | 34.5 | 22.9 | 145.6 | 21.8 |
| tasks | 5.463 | 5.515 | n/a | n/a | n/a | n/a | 18.0 | 18.4 | n/a | n/a | n/a | n/a |
| url | 0.376 | 0.342 | n/a | n/a | n/a | n/a | 6.4 | 6.7 | n/a | n/a | n/a | n/a |
| wordfreq | 0.127 | 0.125 | 0.117 | 0.114 | n/a | n/a | 2.2 | 2.6 | 1.9 | 7.9 | n/a | n/a |

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
| parallel_collatz | 1 | 0.495 (0.492-0.507) | 0.494 | 1.00x | 100 % | 1.00x | same |
| parallel_collatz | 2 | 0.272 (0.271-0.272) | 0.507 | 1.82x | 91 % | 1.02x | same |
| parallel_collatz | 4 | 0.179 (0.177-0.180) | 0.624 | 2.77x | 69 % | 1.26x | same |
| streams_parallel | 1 | 0.481 (0.479-0.483) | 0.480 | 1.00x | 100 % | 1.00x | same |
| streams_parallel | 2 | 0.248 (0.247-0.248) | 0.481 | 1.94x | 97 % | 1.00x | same |
| streams_parallel | 4 | 0.172 (0.172-0.174) | 0.645 | 2.79x | 70 % | 1.34x | same |

Speedup = wall(1 thread) / wall(n); efficiency = speedup / n. CPU time that grows with n is overhead or oversubscription (more threads than free cores).

### Self-compile (orin2 compiles compiler/main.or)

| wall s (min-max) | CPU s | peak RSS MiB | instructions | output identical to stage2.c |
|---:|---:|---:|---:|---|
| 2.688 (2.670-2.723) | 4.797 | 400.5 | 28,924,224,488 | yes |


## All runs

| date | commit | ref | self-compile instructions | self-compile wall s | file |
|---|---|---|---:|---:|---|
| 2026-10-20T09:21:19Z | `7635a6de4b` | main | 28,924,224,488 | 2.688 | [json](history/2026-10-20-7635a6de4ba0.json) |
| 2026-10-19T09:49:07Z | `7635a6de4b` | main | 28,920,330,777 | 2.632 | [json](history/2026-10-19-7635a6de4ba0.json) |
| 2026-10-18T08:43:59Z | `7635a6de4b` | main | 28,927,449,240 | 2.360 | [json](history/2026-10-18-7635a6de4ba0.json) |
| 2026-10-17T08:29:19Z | `d0a17a9682` | main | 26,314,861,202 | 2.370 | [json](history/2026-10-17-d0a17a968285.json) |
| 2026-10-16T08:55:17Z | `9f83f16af4` | main | 24,496,056,957 | 2.438 | [json](history/2026-10-16-9f83f16af402.json) |
| 2026-10-14T17:32:27Z | `f837889af7` | main | 35,729,157,194 | 3.937 | [json](history/2026-10-14-f837889af7a9.json) |
