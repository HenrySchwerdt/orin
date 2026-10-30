# Orin benchmark history

Written by `.github/workflows/bench.yml` (nightly and manual runs on `main`); one JSON file per run in [`history/`](history/), charts rendered by `tooling/benchmarks` (`bench-report render`, no external services). The same data as a stand-alone page: [`report.html`](report.html). Metrics and methodology: `docs/benchmarks.md` on `main`. Do not edit this branch by hand.

16 runs, 2026-10-14 to 2026-10-30. Latest: [`7635a6de4b`](https://github.com/HenrySchwerdt/orin/commit/7635a6de4ba00d5f68f1c6355860428eaad22201).

Instruction counts are the regression metric: they are deterministic for single-threaded programs, while wall time on a shared runner moves by 10-25 % between identical binaries.

![Orin to C wall-time ratio per benchmark over time](charts/ratio_wall.svg)

![Orin to C executed-instruction ratio per benchmark over time](charts/ratio_instructions.svg)

![Self-compile instructions and wall time over time](charts/selfcompile.svg)

![Parallel speedup by worker threads](charts/parallel.svg)

## Latest run


Commit `7635a6de4b` (main), 2026-10-30T10:52:47Z. Machine: AMD EPYC 9V45 96-Core Processor, 4 cores, 15.6 GiB, Linux-7.0.0-1017-azure-x86_64-with-glibc2.39. Runs per cell: 5 (median after one warm-up).

<details><summary>Tool versions</summary>

- cc: `cc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0`
- clang: `Ubuntu clang version 18.1.3 (1ubuntu1)`
- go: `go version go1.24.13 linux/amd64`
- java: `openjdk version "21.0.13" 2026-10-20 LTS`
- python: `3.12.3`
- rustc: `rustc 1.99.1 (58cf8f9c3 2026-10-13)`
- valgrind: `valgrind-3.22.0`

</details>

### Wall time, seconds (median; min-max)

| benchmark | Orin (C backend) | Orin (LLVM backend) | C | Go | Java | Rust |
|---|---:|---:|---:|---:|---:|---:|
| appends | 0.006 (0.006-0.014) | 0.005 (0.005-0.005) | 0.004 (0.004-0.006) | 0.008 (0.007-0.012) | 0.051 (0.050-0.062) | 0.003 (0.003-0.006) |
| bintrees | 0.253 (0.251-0.260) | 0.259 (0.258-0.266) | 0.335 (0.324-0.349) | 0.768 (0.754-0.776) | 0.234 (0.226-0.261) | 0.413 (0.409-0.461) |
| bytesstr | 0.026 (0.026-0.028) | 0.022 (0.021-0.023) | 0.017 (0.017-0.018) | 0.006 (0.006-0.006) | 0.076 (0.075-0.080) | 0.032 (0.032-0.033) |
| fib | 0.204 (0.201-0.209) | 0.190 (0.190-0.193) | 0.112 (0.109-0.132) | 0.382 (0.380-0.395) | 0.293 (0.278-0.326) | 0.208 (0.206-0.210) |
| html | 0.091 (0.091-0.095) | 0.074 (0.073-0.078) | 0.089 (0.086-0.091) | 0.142 (0.139-0.168) | n/a | n/a |
| html_hand | 0.070 (0.069-0.072) | 0.054 (0.054-0.055) | n/a | n/a | n/a | n/a |
| http_parse | 0.069 (0.069-0.070) | 0.060 (0.060-0.060) | n/a | n/a | n/a | n/a |
| mapfreq | 0.096 (0.095-0.097) | 0.096 (0.095-0.124) | 0.047 (0.046-0.050) | 0.068 (0.066-0.072) | n/a | n/a |
| mutres | 0.098 (0.096-0.100) | 0.076 (0.074-0.079) | 0.021 (0.021-0.023) | 0.023 (0.023-0.024) | 0.062 (0.061-0.066) | 0.026 (0.026-0.027) |
| nbody | 0.046 (0.045-0.047) | 0.045 (0.045-0.046) | 0.045 (0.044-0.045) | 0.059 (0.058-0.091) | n/a | n/a |
| pqueue | 0.105 (0.104-0.109) | 0.088 (0.086-0.101) | 0.050 (0.050-0.050) | 0.140 (0.137-0.144) | 0.201 (0.197-0.215) | 0.061 (0.061-0.063) |
| qsort_func | 0.160 (0.151-0.167) | 0.147 (0.146-0.149) | 0.168 (0.166-0.185) | 0.264 (0.260-0.273) | n/a | n/a |
| qsort_inplace | 0.085 (0.084-0.087) | 0.086 (0.085-0.088) | 0.074 (0.072-0.074) | 0.086 (0.083-0.088) | n/a | n/a |
| sieve | 0.078 (0.077-0.080) | 0.076 (0.074-0.083) | 0.073 (0.072-0.075) | 0.156 (0.149-0.174) | 0.133 (0.129-0.162) | 0.074 (0.073-0.076) |
| sortedmap | 0.163 (0.160-0.170) | 0.179 (0.170-0.190) | n/a | n/a | n/a | n/a |
| streams | 0.084 (0.084-0.087) | 0.074 (0.074-0.075) | n/a | n/a | n/a | n/a |
| strings | 0.050 (0.050-0.052) | 0.047 (0.046-0.047) | 0.044 (0.043-0.044) | 0.046 (0.041-0.047) | 0.188 (0.180-0.200) | 0.021 (0.021-0.022) |
| tasks | 3.080 (3.037-3.139) | 2.965 (2.924-3.047) | n/a | n/a | n/a | n/a |
| url | 0.220 (0.220-0.223) | 0.189 (0.188-0.191) | n/a | n/a | n/a | n/a |
| wordfreq | 0.079 (0.078-0.080) | 0.077 (0.076-0.079) | 0.068 (0.067-0.068) | 0.082 (0.081-0.087) | n/a | n/a |

### Ratio to C (wall-time median; lower is better, 1.00x = as fast as C)

| benchmark | Orin C/C | Orin LLVM/C | Go/C | Java/C | Rust/C |
|---|---:|---:|---:|---:|---:|
| appends | 1.45x | 1.19x | 1.80x | 12.28x | 0.74x |
| bintrees | 0.76x | 0.77x | 2.29x | 0.70x | 1.24x |
| bytesstr | 1.51x | 1.26x | 0.36x | 4.38x | 1.83x |
| fib | 1.83x | 1.70x | 3.42x | 2.62x | 1.87x |
| html | 1.02x | 0.82x | 1.59x | n/a | n/a |
| html_hand | n/a | n/a | n/a | n/a | n/a |
| http_parse | n/a | n/a | n/a | n/a | n/a |
| mapfreq | 2.04x | 2.06x | 1.44x | n/a | n/a |
| mutres | 4.70x | 3.64x | 1.11x | 2.96x | 1.27x |
| nbody | 1.03x | 1.02x | 1.33x | n/a | n/a |
| pqueue | 2.11x | 1.77x | 2.80x | 4.02x | 1.22x |
| qsort_func | 0.96x | 0.88x | 1.57x | n/a | n/a |
| qsort_inplace | 1.15x | 1.17x | 1.16x | n/a | n/a |
| sieve | 1.06x | 1.04x | 2.13x | 1.83x | 1.02x |
| sortedmap | n/a | n/a | n/a | n/a | n/a |
| streams | n/a | n/a | n/a | n/a | n/a |
| strings | 1.14x | 1.07x | 1.05x | 4.28x | 0.48x |
| tasks | n/a | n/a | n/a | n/a | n/a |
| url | n/a | n/a | n/a | n/a | n/a |
| wordfreq | 1.18x | 1.14x | 1.22x | n/a | n/a |

### CPU time (user + sys, median s) and peak RSS (MiB)

| benchmark | orin CPU | llvm CPU | c CPU | go CPU | java CPU | rust CPU | orin RSS | llvm RSS | c RSS | go RSS | java RSS | rust RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| appends | 0.006 | 0.005 | 0.004 | 0.010 | 0.079 | 0.003 | 4.6 | 4.8 | 4.9 | 7.1 | 48.0 | 5.2 |
| bintrees | 0.253 | 0.258 | 0.334 | 1.638 | 0.275 | 0.413 | 17.6 | 17.9 | 9.7 | 13.2 | 301.1 | 10.1 |
| bytesstr | 0.026 | 0.022 | 0.017 | 0.008 | 0.090 | 0.032 | 11.6 | 11.8 | 11.7 | 6.3 | 104.7 | 5.0 |
| fib | 0.203 | 0.190 | 0.111 | 0.383 | 0.296 | 0.208 | 1.6 | 1.9 | 1.6 | 1.8 | 38.6 | 2.1 |
| html | 0.091 | 0.073 | 0.089 | 0.188 | n/a | n/a | 3.9 | 4.2 | 2.2 | 7.5 | n/a | n/a |
| html_hand | 0.069 | 0.054 | n/a | n/a | n/a | n/a | 2.5 | 2.9 | n/a | n/a | n/a | n/a |
| http_parse | 0.069 | 0.059 | n/a | n/a | n/a | n/a | 1.7 | 2.1 | n/a | n/a | n/a | n/a |
| mapfreq | 0.095 | 0.096 | 0.047 | 0.075 | n/a | n/a | 11.4 | 11.6 | 5.1 | 7.3 | n/a | n/a |
| mutres | 0.098 | 0.075 | 0.021 | 0.023 | 0.083 | 0.026 | 1.6 | 1.9 | 1.6 | 1.6 | 39.0 | 2.2 |
| nbody | 0.045 | 0.045 | 0.044 | 0.059 | n/a | n/a | 1.9 | 1.9 | 2.0 | 1.8 | n/a | n/a |
| pqueue | 0.105 | 0.088 | 0.050 | 0.146 | 0.256 | 0.061 | 6.2 | 6.5 | 4.9 | 15.0 | 61.9 | 5.1 |
| qsort_func | 0.160 | 0.147 | 0.168 | 0.322 | n/a | n/a | 36.5 | 36.8 | 23.8 | 37.1 | n/a | n/a |
| qsort_inplace | 0.085 | 0.086 | 0.073 | 0.097 | n/a | n/a | 16.8 | 17.1 | 16.9 | 25.9 | n/a | n/a |
| sieve | 0.077 | 0.075 | 0.073 | 0.257 | 0.156 | 0.074 | 77.8 | 78.1 | 77.7 | 185.8 | 116.0 | 78.4 |
| sortedmap | 0.163 | 0.179 | n/a | n/a | n/a | n/a | 11.3 | 11.5 | n/a | n/a | n/a | n/a |
| streams | 0.083 | 0.074 | n/a | n/a | n/a | n/a | 39.8 | 40.0 | n/a | n/a | n/a | n/a |
| strings | 0.050 | 0.047 | 0.044 | 0.060 | 0.356 | 0.021 | 46.2 | 46.5 | 34.7 | 23.6 | 139.4 | 20.0 |
| tasks | 3.562 | 3.415 | n/a | n/a | n/a | n/a | 14.2 | 14.6 | n/a | n/a | n/a | n/a |
| url | 0.220 | 0.188 | n/a | n/a | n/a | n/a | 6.5 | 6.8 | n/a | n/a | n/a | n/a |
| wordfreq | 0.079 | 0.076 | 0.067 | 0.084 | n/a | n/a | 2.4 | 2.6 | 2.0 | 6.5 | n/a | n/a |

### Executed instructions (valgrind; the regression metric)

| benchmark | Orin C | Orin LLVM | C | Orin C/C | Orin LLVM/C | note |
|---|---:|---:|---:|---:|---:|---|
| appends | 63,530,238 | 44,305,230 | 25,381,131 | 2.50x | 1.75x |  |
| bintrees | 4,457,305,556 | 4,319,515,246 | 7,242,293,433 | 0.62x | 0.60x |  |
| bytesstr | 349,907,887 | 259,441,178 | 178,695,497 | 1.96x | 1.45x |  |
| fib | 3,200,318,149 | 2,483,953,789 | 3,170,983,187 | 1.01x | 0.78x |  |
| html | 1,784,203,884 | 1,471,870,947 | 1,581,660,500 | 1.13x | 0.93x |  |
| html_hand | 1,332,890,919 | 987,886,037 | n/a | n/a | n/a |  |
| http_parse | 1,539,178,551 | 1,358,991,092 | n/a | n/a | n/a |  |
| mapfreq | 1,050,624,793 | 995,125,501 | 717,968,421 | 1.46x | 1.39x |  |
| mutres | 2,541,530,953 | 2,030,255,622 | 291,450,138 | 8.72x | 6.97x |  |
| nbody | 658,315,521 | 772,258,305 | 651,230,691 | 1.01x | 1.19x |  |
| pqueue | 1,411,252,308 | 1,344,413,179 | 355,213,580 | 3.97x | 3.78x |  |
| qsort_func | 1,329,379,242 | 1,269,367,690 | 1,528,677,747 | 0.87x | 0.83x |  |
| qsort_inplace | 576,878,278 | 521,077,518 | 273,751,964 | 2.11x | 1.90x |  |
| sieve | 410,343,299 | 456,726,111 | 191,756,537 | 2.14x | 2.38x |  |
| sortedmap | 1,356,615,067 | 1,358,427,082 | n/a | n/a | n/a |  |
| streams | 1,173,755,264 | 1,173,731,319 | n/a | n/a | n/a |  |
| strings | 647,532,817 | 559,940,890 | 685,893,516 | 0.94x | 0.82x |  |
| tasks | n/a | n/a | n/a | n/a | n/a | llvm skipped: multi-threaded (20,000 tasks, channels): valgrind serialises threads, so the count would include scheduler waits; orin skipped: multi-threaded (20,000 tasks, channels): valgrind serialises threads, so the count would include scheduler waits |
| url | 4,852,179,714 | 4,363,458,753 | n/a | n/a | n/a |  |
| wordfreq | 760,378,192 | 707,684,195 | 880,488,803 | 0.86x | 0.80x |  |

### Parallel speedup (std:task; worker threads = first argument of the program)

| benchmark | threads | wall s (min-max) | CPU s (user+sys) | speedup | efficiency | CPU vs 1 thread | output |
|---|---:|---:|---:|---:|---:|---:|---|
| parallel_collatz | 1 | 0.395 (0.391-0.406) | 0.395 | 1.00x | 100 % | 1.00x | same |
| parallel_collatz | 2 | 0.230 (0.229-0.231) | 0.416 | 1.72x | 86 % | 1.05x | same |
| parallel_collatz | 4 | 0.143 (0.142-0.145) | 0.480 | 2.76x | 69 % | 1.21x | same |
| streams_parallel | 1 | 0.439 (0.430-0.452) | 0.439 | 1.00x | 100 % | 1.00x | same |
| streams_parallel | 2 | 0.236 (0.234-0.237) | 0.452 | 1.86x | 93 % | 1.03x | same |
| streams_parallel | 4 | 0.150 (0.149-0.151) | 0.543 | 2.93x | 73 % | 1.24x | same |

Speedup = wall(1 thread) / wall(n); efficiency = speedup / n. CPU time that grows with n is overhead or oversubscription (more threads than free cores).

### Self-compile (orin2 compiles compiler/main.or)

| wall s (min-max) | CPU s | peak RSS MiB | instructions | output identical to stage2.c |
|---:|---:|---:|---:|---|
| 2.245 (2.191-2.250) | 3.491 | 393.9 | 28,929,137,893 | yes |


## All runs

| date | commit | ref | self-compile instructions | self-compile wall s | file |
|---|---|---|---:|---:|---|
| 2026-10-30T10:52:47Z | `7635a6de4b` | main | 28,929,137,893 | 2.245 | [json](history/2026-10-30-7635a6de4ba0.json) |
| 2026-10-29T10:57:02Z | `7635a6de4b` | main | 28,928,714,860 | 2.725 | [json](history/2026-10-29-7635a6de4ba0.json) |
| 2026-10-28T10:34:30Z | `7635a6de4b` | main | 28,927,700,571 | 2.775 | [json](history/2026-10-28-7635a6de4ba0.json) |
| 2026-10-27T09:54:38Z | `7635a6de4b` | main | 28,929,325,676 | 2.422 | [json](history/2026-10-27-7635a6de4ba0.json) |
| 2026-10-26T09:51:57Z | `7635a6de4b` | main | 28,898,057,347 | 2.328 | [json](history/2026-10-26-7635a6de4ba0.json) |
| 2026-10-25T09:10:57Z | `7635a6de4b` | main | 28,925,568,576 | 2.594 | [json](history/2026-10-25-7635a6de4ba0.json) |
| 2026-10-24T08:51:56Z | `7635a6de4b` | main | 28,924,241,295 | 2.708 | [json](history/2026-10-24-7635a6de4ba0.json) |
| 2026-10-23T09:21:38Z | `7635a6de4b` | main | 28,928,848,177 | 2.577 | [json](history/2026-10-23-7635a6de4ba0.json) |
| 2026-10-22T09:18:06Z | `7635a6de4b` | main | 28,927,908,288 | 1.939 | [json](history/2026-10-22-7635a6de4ba0.json) |
| 2026-10-21T09:16:22Z | `7635a6de4b` | main | 28,929,128,127 | 2.146 | [json](history/2026-10-21-7635a6de4ba0.json) |
| 2026-10-20T09:21:19Z | `7635a6de4b` | main | 28,924,224,488 | 2.688 | [json](history/2026-10-20-7635a6de4ba0.json) |
| 2026-10-19T09:49:07Z | `7635a6de4b` | main | 28,920,330,777 | 2.632 | [json](history/2026-10-19-7635a6de4ba0.json) |
| 2026-10-18T08:43:59Z | `7635a6de4b` | main | 28,927,449,240 | 2.360 | [json](history/2026-10-18-7635a6de4ba0.json) |
| 2026-10-17T08:29:19Z | `d0a17a9682` | main | 26,314,861,202 | 2.370 | [json](history/2026-10-17-d0a17a968285.json) |
| 2026-10-16T08:55:17Z | `9f83f16af4` | main | 24,496,056,957 | 2.438 | [json](history/2026-10-16-9f83f16af402.json) |
| 2026-10-14T17:32:27Z | `f837889af7` | main | 35,729,157,194 | 3.937 | [json](history/2026-10-14-f837889af7a9.json) |
