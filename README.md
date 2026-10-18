# Orin benchmark history

Written by `.github/workflows/bench.yml` (nightly and manual runs on `main`); one JSON file per run in [`history/`](history/), charts rendered by `tooling/benchmarks` (`bench-report render`, no external services). The same data as a stand-alone page: [`report.html`](report.html). Metrics and methodology: `docs/benchmarks.md` on `main`. Do not edit this branch by hand.

4 runs, 2026-10-14 to 2026-10-18. Latest: [`7635a6de4b`](https://github.com/HenrySchwerdt/orin/commit/7635a6de4ba00d5f68f1c6355860428eaad22201).

Instruction counts are the regression metric: they are deterministic for single-threaded programs, while wall time on a shared runner moves by 10-25 % between identical binaries.

![Orin to C wall-time ratio per benchmark over time](charts/ratio_wall.svg)

![Orin to C executed-instruction ratio per benchmark over time](charts/ratio_instructions.svg)

![Self-compile instructions and wall time over time](charts/selfcompile.svg)

![Parallel speedup by worker threads](charts/parallel.svg)

## Latest run


Commit `7635a6de4b` (main), 2026-10-18T08:43:59Z. Machine: AMD EPYC 9V74 80-Core Processor, 4 cores, 15.6 GiB, Linux-6.17.0-1022-azure-x86_64-with-glibc2.39. Runs per cell: 5 (median after one warm-up).

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
| appends | 0.007 (0.007-0.007) | 0.006 (0.006-0.006) | 0.004 (0.004-0.004) | 0.005 (0.005-0.006) | 0.054 (0.046-0.061) | 0.003 (0.003-0.003) |
| bintrees | 0.319 (0.318-0.323) | 0.324 (0.318-0.325) | 0.458 (0.455-0.747) | 0.953 (0.948-0.975) | 0.165 (0.163-0.168) | 0.567 (0.562-0.571) |
| bytesstr | 0.027 (0.027-0.028) | 0.023 (0.022-0.023) | 0.014 (0.013-0.014) | 0.006 (0.005-0.007) | 0.048 (0.048-0.050) | 0.031 (0.028-0.032) |
| fib | 0.254 (0.254-0.254) | 0.281 (0.281-0.281) | 0.151 (0.151-0.151) | 0.514 (0.512-0.515) | 0.311 (0.310-0.337) | 0.271 (0.271-0.271) |
| html | 0.126 (0.124-0.131) | 0.100 (0.099-0.102) | 0.123 (0.118-0.126) | 0.188 (0.179-0.202) | n/a | n/a |
| html_hand | 0.100 (0.100-0.101) | 0.080 (0.077-0.083) | n/a | n/a | n/a | n/a |
| http_parse | 0.094 (0.094-0.094) | 0.082 (0.081-0.082) | n/a | n/a | n/a | n/a |
| mapfreq | 0.122 (0.120-0.128) | 0.120 (0.120-0.124) | 0.057 (0.057-0.059) | 0.086 (0.084-0.086) | n/a | n/a |
| mutres | 0.149 (0.149-0.149) | 0.117 (0.116-0.142) | 0.028 (0.027-0.035) | 0.037 (0.036-0.052) | 0.069 (0.068-0.164) | 0.032 (0.032-0.033) |
| nbody | 0.061 (0.061-0.061) | 0.064 (0.064-0.064) | 0.061 (0.061-0.061) | 0.072 (0.072-0.073) | n/a | n/a |
| pqueue | 0.132 (0.128-0.147) | 0.107 (0.104-0.115) | 0.059 (0.057-0.060) | 0.159 (0.156-0.163) | 0.195 (0.187-0.212) | 0.075 (0.075-0.075) |
| qsort_func | 0.170 (0.166-0.173) | 0.173 (0.170-0.175) | 0.185 (0.182-0.186) | 0.276 (0.274-0.277) | n/a | n/a |
| qsort_inplace | 0.092 (0.092-0.093) | 0.099 (0.095-0.103) | 0.070 (0.070-0.070) | 0.078 (0.078-0.079) | n/a | n/a |
| sieve | 0.096 (0.092-0.102) | 0.091 (0.086-0.092) | 0.080 (0.077-0.083) | 0.121 (0.115-0.132) | 0.130 (0.127-0.137) | 0.084 (0.080-0.091) |
| sortedmap | 0.218 (0.204-0.226) | 0.222 (0.216-0.227) | n/a | n/a | n/a | n/a |
| streams | 0.088 (0.087-0.097) | 0.078 (0.078-0.078) | n/a | n/a | n/a | n/a |
| strings | 0.062 (0.061-0.136) | 0.060 (0.058-0.127) | 0.053 (0.053-0.054) | 0.041 (0.041-0.043) | 0.151 (0.145-0.152) | 0.024 (0.023-0.028) |
| tasks | 3.724 (3.693-3.741) | 3.646 (3.553-3.676) | n/a | n/a | n/a | n/a |
| url | 0.298 (0.296-0.299) | 0.263 (0.261-0.265) | n/a | n/a | n/a | n/a |
| wordfreq | 0.096 (0.096-0.097) | 0.096 (0.095-0.097) | 0.082 (0.082-0.083) | 0.089 (0.089-0.090) | n/a | n/a |

### Ratio to C (wall-time median; lower is better, 1.00x = as fast as C)

| benchmark | Orin C/C | Orin LLVM/C | Go/C | Java/C | Rust/C |
|---|---:|---:|---:|---:|---:|
| appends | 1.56x | 1.35x | 1.23x | 12.48x | 0.74x |
| bintrees | 0.70x | 0.71x | 2.08x | 0.36x | 1.24x |
| bytesstr | 1.96x | 1.67x | 0.42x | 3.48x | 2.21x |
| fib | 1.68x | 1.86x | 3.41x | 2.06x | 1.80x |
| html | 1.02x | 0.81x | 1.54x | n/a | n/a |
| html_hand | n/a | n/a | n/a | n/a | n/a |
| http_parse | n/a | n/a | n/a | n/a | n/a |
| mapfreq | 2.12x | 2.10x | 1.49x | n/a | n/a |
| mutres | 5.37x | 4.21x | 1.33x | 2.50x | 1.15x |
| nbody | 1.00x | 1.06x | 1.18x | n/a | n/a |
| pqueue | 2.24x | 1.82x | 2.70x | 3.31x | 1.27x |
| qsort_func | 0.92x | 0.94x | 1.49x | n/a | n/a |
| qsort_inplace | 1.31x | 1.41x | 1.11x | n/a | n/a |
| sieve | 1.20x | 1.14x | 1.51x | 1.63x | 1.06x |
| sortedmap | n/a | n/a | n/a | n/a | n/a |
| streams | n/a | n/a | n/a | n/a | n/a |
| strings | 1.17x | 1.13x | 0.78x | 2.84x | 0.45x |
| tasks | n/a | n/a | n/a | n/a | n/a |
| url | n/a | n/a | n/a | n/a | n/a |
| wordfreq | 1.18x | 1.17x | 1.09x | n/a | n/a |

### CPU time (user + sys, median s) and peak RSS (MiB)

| benchmark | orin CPU | llvm CPU | c CPU | go CPU | java CPU | rust CPU | orin RSS | llvm RSS | c RSS | go RSS | java RSS | rust RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| appends | 0.007 | 0.006 | 0.004 | 0.007 | 0.071 | 0.003 | 4.6 | 4.8 | 4.9 | 10.6 | 58.6 | 5.2 |
| bintrees | 0.318 | 0.324 | 0.457 | 2.017 | 0.204 | 0.566 | 17.6 | 17.9 | 9.7 | 14.4 | 308.0 | 10.2 |
| bytesstr | 0.027 | 0.023 | 0.014 | 0.009 | 0.063 | 0.031 | 11.6 | 11.9 | 11.7 | 10.0 | 108.0 | 5.0 |
| fib | 0.254 | 0.280 | 0.150 | 0.515 | 0.322 | 0.271 | 1.6 | 1.9 | 1.6 | 3.4 | 47.5 | 2.1 |
| html | 0.125 | 0.099 | 0.122 | 0.254 | n/a | n/a | 3.9 | 4.2 | 2.2 | 12.3 | n/a | n/a |
| html_hand | 0.100 | 0.080 | n/a | n/a | n/a | n/a | 2.5 | 2.8 | n/a | n/a | n/a | n/a |
| http_parse | 0.093 | 0.082 | n/a | n/a | n/a | n/a | 1.7 | 2.1 | n/a | n/a | n/a | n/a |
| mapfreq | 0.121 | 0.120 | 0.057 | 0.096 | n/a | n/a | 11.4 | 11.6 | 5.2 | 8.0 | n/a | n/a |
| mutres | 0.149 | 0.116 | 0.027 | 0.037 | 0.092 | 0.032 | 1.6 | 1.9 | 1.6 | 3.4 | 47.8 | 2.1 |
| nbody | 0.061 | 0.064 | 0.060 | 0.072 | n/a | n/a | 1.9 | 1.9 | 2.0 | 3.4 | n/a | n/a |
| pqueue | 0.132 | 0.107 | 0.059 | 0.163 | 0.254 | 0.075 | 6.2 | 6.5 | 4.9 | 15.9 | 70.5 | 5.1 |
| qsort_func | 0.170 | 0.173 | 0.185 | 0.324 | n/a | n/a | 36.5 | 36.7 | 24.6 | 43.0 | n/a | n/a |
| qsort_inplace | 0.092 | 0.099 | 0.070 | 0.085 | n/a | n/a | 16.8 | 17.1 | 17.0 | 29.4 | n/a | n/a |
| sieve | 0.095 | 0.091 | 0.079 | 0.159 | 0.154 | 0.084 | 79.1 | 79.4 | 78.5 | 245.7 | 124.6 | 79.6 |
| sortedmap | 0.217 | 0.221 | n/a | n/a | n/a | n/a | 11.3 | 11.5 | n/a | n/a | n/a | n/a |
| streams | 0.087 | 0.078 | n/a | n/a | n/a | n/a | 43.2 | 40.9 | n/a | n/a | n/a | n/a |
| strings | 0.061 | 0.059 | 0.053 | 0.049 | 0.304 | 0.023 | 47.5 | 47.8 | 36.5 | 25.5 | 145.6 | 20.1 |
| tasks | 4.367 | 4.210 | n/a | n/a | n/a | n/a | 18.1 | 18.6 | n/a | n/a | n/a | n/a |
| url | 0.297 | 0.262 | n/a | n/a | n/a | n/a | 6.5 | 6.8 | n/a | n/a | n/a | n/a |
| wordfreq | 0.096 | 0.095 | 0.082 | 0.091 | n/a | n/a | 2.4 | 2.6 | 2.0 | 7.9 | n/a | n/a |

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
| parallel_collatz | 1 | 0.417 (0.416-0.458) | 0.417 | 1.00x | 100 % | 1.00x | same |
| parallel_collatz | 2 | 0.230 (0.230-0.231) | 0.428 | 1.81x | 91 % | 1.03x | same |
| parallel_collatz | 4 | 0.147 (0.146-0.147) | 0.511 | 2.84x | 71 % | 1.23x | same |
| streams_parallel | 1 | 0.411 (0.411-0.413) | 0.411 | 1.00x | 100 % | 1.00x | same |
| streams_parallel | 2 | 0.212 (0.212-0.212) | 0.412 | 1.94x | 97 % | 1.00x | same |
| streams_parallel | 4 | 0.143 (0.142-0.143) | 0.534 | 2.88x | 72 % | 1.30x | same |

Speedup = wall(1 thread) / wall(n); efficiency = speedup / n. CPU time that grows with n is overhead or oversubscription (more threads than free cores).

### Self-compile (orin2 compiles compiler/main.or)

| wall s (min-max) | CPU s | peak RSS MiB | instructions | output identical to stage2.c |
|---:|---:|---:|---:|---|
| 2.360 (2.333-2.429) | 3.943 | 400.6 | 28,927,449,240 | yes |


## All runs

| date | commit | ref | self-compile instructions | self-compile wall s | file |
|---|---|---|---:|---:|---|
| 2026-10-18T08:43:59Z | `7635a6de4b` | main | 28,927,449,240 | 2.360 | [json](history/2026-10-18-7635a6de4ba0.json) |
| 2026-10-17T08:29:19Z | `d0a17a9682` | main | 26,314,861,202 | 2.370 | [json](history/2026-10-17-d0a17a968285.json) |
| 2026-10-16T08:55:17Z | `9f83f16af4` | main | 24,496,056,957 | 2.438 | [json](history/2026-10-16-9f83f16af402.json) |
| 2026-10-14T17:32:27Z | `f837889af7` | main | 35,729,157,194 | 3.937 | [json](history/2026-10-14-f837889af7a9.json) |
