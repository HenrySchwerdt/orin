# Orin benchmark history

Written by `.github/workflows/bench.yml` (nightly and manual runs on `main`); one JSON file per run in [`history/`](history/), charts rendered by `tooling/benchmarks` (`bench-report render`, no external services). The same data as a stand-alone page: [`report.html`](report.html). Metrics and methodology: `docs/benchmarks.md` on `main`. Do not edit this branch by hand.

12 runs, 2026-10-14 to 2026-10-26. Latest: [`7635a6de4b`](https://github.com/HenrySchwerdt/orin/commit/7635a6de4ba00d5f68f1c6355860428eaad22201).

Instruction counts are the regression metric: they are deterministic for single-threaded programs, while wall time on a shared runner moves by 10-25 % between identical binaries.

![Orin to C wall-time ratio per benchmark over time](charts/ratio_wall.svg)

![Orin to C executed-instruction ratio per benchmark over time](charts/ratio_instructions.svg)

![Self-compile instructions and wall time over time](charts/selfcompile.svg)

![Parallel speedup by worker threads](charts/parallel.svg)

## Latest run


Commit `7635a6de4b` (main), 2026-10-26T09:51:57Z. Machine: AMD EPYC 9V74 80-Core Processor, 4 cores, 15.6 GiB, Linux-6.17.0-1022-azure-x86_64-with-glibc2.39. Runs per cell: 5 (median after one warm-up).

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
| appends | 0.007 (0.007-0.007) | 0.006 (0.006-0.006) | 0.004 (0.004-0.005) | 0.006 (0.005-0.007) | 0.059 (0.055-0.062) | 0.003 (0.003-0.004) |
| bintrees | 0.319 (0.318-0.322) | 0.321 (0.316-0.326) | 0.455 (0.454-0.456) | 0.956 (0.954-0.989) | 0.164 (0.162-0.168) | 0.564 (0.564-0.570) |
| bytesstr | 0.027 (0.027-0.027) | 0.023 (0.023-0.024) | 0.015 (0.014-0.015) | 0.006 (0.005-0.008) | 0.052 (0.049-0.054) | 0.031 (0.030-0.031) |
| fib | 0.254 (0.254-0.254) | 0.281 (0.281-0.281) | 0.151 (0.151-0.153) | 0.514 (0.514-0.514) | 0.319 (0.316-0.323) | 0.271 (0.271-0.271) |
| html | 0.124 (0.123-0.124) | 0.100 (0.099-0.103) | 0.124 (0.119-0.135) | 0.177 (0.171-0.180) | n/a | n/a |
| html_hand | 0.100 (0.100-0.103) | 0.079 (0.077-0.082) | n/a | n/a | n/a | n/a |
| http_parse | 0.094 (0.094-0.094) | 0.082 (0.081-0.082) | n/a | n/a | n/a | n/a |
| mapfreq | 0.118 (0.118-0.119) | 0.119 (0.119-0.119) | 0.057 (0.056-0.061) | 0.084 (0.083-0.088) | n/a | n/a |
| mutres | 0.149 (0.149-0.150) | 0.117 (0.116-0.118) | 0.027 (0.027-0.027) | 0.036 (0.036-0.036) | 0.068 (0.066-0.069) | 0.033 (0.032-0.033) |
| nbody | 0.061 (0.061-0.061) | 0.064 (0.064-0.065) | 0.061 (0.061-0.061) | 0.072 (0.072-0.072) | n/a | n/a |
| pqueue | 0.125 (0.124-0.125) | 0.102 (0.102-0.103) | 0.057 (0.057-0.058) | 0.153 (0.153-0.155) | 0.172 (0.165-0.172) | 0.074 (0.074-0.075) |
| qsort_func | 0.169 (0.166-0.170) | 0.172 (0.171-0.174) | 0.182 (0.181-0.183) | 0.278 (0.263-0.295) | n/a | n/a |
| qsort_inplace | 0.092 (0.092-0.092) | 0.100 (0.097-0.101) | 0.070 (0.070-0.070) | 0.079 (0.078-0.079) | n/a | n/a |
| sieve | 0.081 (0.081-0.081) | 0.082 (0.082-0.083) | 0.072 (0.072-0.117) | 0.110 (0.107-0.119) | 0.118 (0.116-0.184) | 0.082 (0.076-0.106) |
| sortedmap | 0.203 (0.203-0.204) | 0.214 (0.213-0.216) | n/a | n/a | n/a | n/a |
| streams | 0.088 (0.086-0.088) | 0.078 (0.077-0.078) | n/a | n/a | n/a | n/a |
| strings | 0.061 (0.061-0.062) | 0.059 (0.058-0.060) | 0.053 (0.052-0.053) | 0.042 (0.041-0.045) | 0.152 (0.147-0.155) | 0.022 (0.022-0.023) |
| tasks | 3.749 (3.719-3.763) | 3.671 (3.655-3.679) | n/a | n/a | n/a | n/a |
| url | 0.298 (0.296-0.300) | 0.263 (0.262-0.276) | n/a | n/a | n/a | n/a |
| wordfreq | 0.096 (0.095-0.097) | 0.096 (0.095-0.097) | 0.082 (0.082-0.082) | 0.089 (0.088-0.089) | n/a | n/a |

### Ratio to C (wall-time median; lower is better, 1.00x = as fast as C)

| benchmark | Orin C/C | Orin LLVM/C | Go/C | Java/C | Rust/C |
|---|---:|---:|---:|---:|---:|
| appends | 1.58x | 1.35x | 1.33x | 13.36x | 0.79x |
| bintrees | 0.70x | 0.71x | 2.10x | 0.36x | 1.24x |
| bytesstr | 1.85x | 1.58x | 0.38x | 3.54x | 2.13x |
| fib | 1.69x | 1.86x | 3.41x | 2.12x | 1.80x |
| html | 1.00x | 0.80x | 1.42x | n/a | n/a |
| html_hand | n/a | n/a | n/a | n/a | n/a |
| http_parse | n/a | n/a | n/a | n/a | n/a |
| mapfreq | 2.07x | 2.08x | 1.46x | n/a | n/a |
| mutres | 5.50x | 4.30x | 1.33x | 2.49x | 1.22x |
| nbody | 1.00x | 1.06x | 1.19x | n/a | n/a |
| pqueue | 2.18x | 1.78x | 2.67x | 3.00x | 1.29x |
| qsort_func | 0.93x | 0.94x | 1.53x | n/a | n/a |
| qsort_inplace | 1.31x | 1.43x | 1.12x | n/a | n/a |
| sieve | 1.12x | 1.14x | 1.52x | 1.63x | 1.13x |
| sortedmap | n/a | n/a | n/a | n/a | n/a |
| streams | n/a | n/a | n/a | n/a | n/a |
| strings | 1.15x | 1.11x | 0.79x | 2.87x | 0.42x |
| tasks | n/a | n/a | n/a | n/a | n/a |
| url | n/a | n/a | n/a | n/a | n/a |
| wordfreq | 1.18x | 1.17x | 1.08x | n/a | n/a |

### CPU time (user + sys, median s) and peak RSS (MiB)

| benchmark | orin CPU | llvm CPU | c CPU | go CPU | java CPU | rust CPU | orin RSS | llvm RSS | c RSS | go RSS | java RSS | rust RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| appends | 0.007 | 0.006 | 0.004 | 0.007 | 0.075 | 0.003 | 4.6 | 4.8 | 4.9 | 10.8 | 58.7 | 5.2 |
| bintrees | 0.319 | 0.321 | 0.454 | 2.031 | 0.203 | 0.564 | 17.6 | 17.9 | 9.7 | 14.3 | 307.9 | 10.1 |
| bytesstr | 0.027 | 0.023 | 0.014 | 0.008 | 0.066 | 0.031 | 11.5 | 11.9 | 11.6 | 9.9 | 108.0 | 5.0 |
| fib | 0.254 | 0.280 | 0.150 | 0.515 | 0.327 | 0.271 | 1.6 | 1.9 | 1.6 | 3.4 | 47.5 | 2.0 |
| html | 0.123 | 0.099 | 0.124 | 0.228 | n/a | n/a | 3.9 | 4.2 | 2.2 | 8.3 | n/a | n/a |
| html_hand | 0.100 | 0.079 | n/a | n/a | n/a | n/a | 2.5 | 2.8 | n/a | n/a | n/a | n/a |
| http_parse | 0.094 | 0.081 | n/a | n/a | n/a | n/a | 1.7 | 2.1 | n/a | n/a | n/a | n/a |
| mapfreq | 0.118 | 0.119 | 0.057 | 0.094 | n/a | n/a | 11.4 | 11.6 | 5.2 | 8.1 | n/a | n/a |
| mutres | 0.149 | 0.116 | 0.027 | 0.036 | 0.090 | 0.033 | 1.6 | 1.9 | 1.6 | 3.4 | 47.8 | 2.1 |
| nbody | 0.060 | 0.064 | 0.060 | 0.072 | n/a | n/a | 1.9 | 1.9 | 2.0 | 3.4 | n/a | n/a |
| pqueue | 0.125 | 0.102 | 0.057 | 0.157 | 0.227 | 0.074 | 6.2 | 6.5 | 4.9 | 16.0 | 70.5 | 5.1 |
| qsort_func | 0.169 | 0.172 | 0.182 | 0.327 | n/a | n/a | 36.5 | 36.8 | 23.7 | 40.3 | n/a | n/a |
| qsort_inplace | 0.091 | 0.100 | 0.070 | 0.086 | n/a | n/a | 16.8 | 17.2 | 17.0 | 31.5 | n/a | n/a |
| sieve | 0.081 | 0.082 | 0.072 | 0.153 | 0.137 | 0.081 | 79.4 | 79.6 | 78.5 | 219.8 | 124.5 | 79.1 |
| sortedmap | 0.203 | 0.214 | n/a | n/a | n/a | n/a | 11.3 | 11.5 | n/a | n/a | n/a | n/a |
| streams | 0.088 | 0.077 | n/a | n/a | n/a | n/a | 43.2 | 40.9 | n/a | n/a | n/a | n/a |
| strings | 0.061 | 0.059 | 0.053 | 0.049 | 0.307 | 0.022 | 47.3 | 47.8 | 36.5 | 25.1 | 145.5 | 21.9 |
| tasks | 4.297 | 4.119 | n/a | n/a | n/a | n/a | 18.2 | 18.5 | n/a | n/a | n/a | n/a |
| url | 0.297 | 0.263 | n/a | n/a | n/a | n/a | 6.5 | 6.8 | n/a | n/a | n/a | n/a |
| wordfreq | 0.096 | 0.095 | 0.082 | 0.090 | n/a | n/a | 2.4 | 2.6 | 2.0 | 7.9 | n/a | n/a |

### Executed instructions (valgrind; the regression metric)

| benchmark | Orin C | Orin LLVM | C | Orin C/C | Orin LLVM/C | note |
|---|---:|---:|---:|---:|---:|---|
| appends | 63,530,238 | 44,305,230 | 25,381,155 | 2.50x | 1.75x |  |
| bintrees | 4,457,305,570 | 4,319,515,260 | 7,242,293,433 | 0.62x | 0.60x |  |
| bytesstr | 349,907,901 | 259,441,192 | 178,695,497 | 1.96x | 1.45x |  |
| fib | 3,200,318,149 | 2,483,953,789 | 3,170,983,196 | 1.01x | 0.78x |  |
| html | 1,784,203,908 | 1,471,870,971 | 1,581,660,500 | 1.13x | 0.93x |  |
| html_hand | 1,332,890,919 | 987,886,037 | n/a | n/a | n/a |  |
| http_parse | 1,539,178,532 | 1,358,991,073 | n/a | n/a | n/a |  |
| mapfreq | 1,050,624,793 | 995,125,501 | 717,968,445 | 1.46x | 1.39x |  |
| mutres | 2,541,530,939 | 2,030,255,608 | 291,450,138 | 8.72x | 6.97x |  |
| nbody | 658,315,521 | 772,258,305 | 651,230,682 | 1.01x | 1.19x |  |
| pqueue | 1,411,252,294 | 1,344,413,165 | 355,213,580 | 3.97x | 3.78x |  |
| qsort_func | 1,329,379,223 | 1,269,367,671 | 1,528,677,747 | 0.87x | 0.83x |  |
| qsort_inplace | 576,878,278 | 521,077,518 | 273,751,945 | 2.11x | 1.90x |  |
| sieve | 410,343,299 | 456,726,111 | 191,756,528 | 2.14x | 2.38x |  |
| sortedmap | 1,356,615,067 | 1,358,427,082 | n/a | n/a | n/a |  |
| streams | 1,173,755,264 | 1,173,731,319 | n/a | n/a | n/a |  |
| strings | 647,532,817 | 559,940,890 | 685,893,540 | 0.94x | 0.82x |  |
| tasks | n/a | n/a | n/a | n/a | n/a | llvm skipped: multi-threaded (20,000 tasks, channels): valgrind serialises threads, so the count would include scheduler waits; orin skipped: multi-threaded (20,000 tasks, channels): valgrind serialises threads, so the count would include scheduler waits |
| url | 4,852,179,714 | 4,363,458,753 | n/a | n/a | n/a |  |
| wordfreq | 760,378,206 | 707,684,209 | 880,488,803 | 0.86x | 0.80x |  |

### Parallel speedup (std:task; worker threads = first argument of the program)

| benchmark | threads | wall s (min-max) | CPU s (user+sys) | speedup | efficiency | CPU vs 1 thread | output |
|---|---:|---:|---:|---:|---:|---:|---|
| parallel_collatz | 1 | 0.417 (0.416-0.418) | 0.416 | 1.00x | 100 % | 1.00x | same |
| parallel_collatz | 2 | 0.230 (0.230-0.230) | 0.428 | 1.81x | 91 % | 1.03x | same |
| parallel_collatz | 4 | 0.146 (0.146-0.148) | 0.512 | 2.85x | 71 % | 1.23x | same |
| streams_parallel | 1 | 0.412 (0.411-0.413) | 0.411 | 1.00x | 100 % | 1.00x | same |
| streams_parallel | 2 | 0.212 (0.212-0.212) | 0.412 | 1.94x | 97 % | 1.00x | same |
| streams_parallel | 4 | 0.142 (0.142-0.143) | 0.534 | 2.89x | 72 % | 1.30x | same |

Speedup = wall(1 thread) / wall(n); efficiency = speedup / n. CPU time that grows with n is overhead or oversubscription (more threads than free cores).

### Self-compile (orin2 compiles compiler/main.or)

| wall s (min-max) | CPU s | peak RSS MiB | instructions | output identical to stage2.c |
|---:|---:|---:|---:|---|
| 2.328 (2.312-2.416) | 3.962 | 399.7 | 28,898,057,347 | yes |


## All runs

| date | commit | ref | self-compile instructions | self-compile wall s | file |
|---|---|---|---:|---:|---|
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
