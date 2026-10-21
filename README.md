# Orin benchmark history

Written by `.github/workflows/bench.yml` (nightly and manual runs on `main`); one JSON file per run in [`history/`](history/), charts rendered by `tooling/benchmarks` (`bench-report render`, no external services). The same data as a stand-alone page: [`report.html`](report.html). Metrics and methodology: `docs/benchmarks.md` on `main`. Do not edit this branch by hand.

7 runs, 2026-10-14 to 2026-10-21. Latest: [`7635a6de4b`](https://github.com/HenrySchwerdt/orin/commit/7635a6de4ba00d5f68f1c6355860428eaad22201).

Instruction counts are the regression metric: they are deterministic for single-threaded programs, while wall time on a shared runner moves by 10-25 % between identical binaries.

![Orin to C wall-time ratio per benchmark over time](charts/ratio_wall.svg)

![Orin to C executed-instruction ratio per benchmark over time](charts/ratio_instructions.svg)

![Self-compile instructions and wall time over time](charts/selfcompile.svg)

![Parallel speedup by worker threads](charts/parallel.svg)

## Latest run


Commit `7635a6de4b` (main), 2026-10-21T09:16:22Z. Machine: AMD EPYC 9V45 96-Core Processor, 4 cores, 15.6 GiB, Linux-7.0.0-1017-azure-x86_64-with-glibc2.39. Runs per cell: 5 (median after one warm-up).

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
| appends | 0.005 (0.005-0.006) | 0.005 (0.005-0.007) | 0.004 (0.004-0.004) | 0.007 (0.007-0.008) | 0.060 (0.049-0.063) | 0.003 (0.003-0.003) |
| bintrees | 0.245 (0.235-0.251) | 0.241 (0.237-0.248) | 0.304 (0.298-0.315) | 0.726 (0.714-0.739) | 0.222 (0.221-0.237) | 0.399 (0.395-0.409) |
| bytesstr | 0.026 (0.025-0.031) | 0.022 (0.022-0.032) | 0.017 (0.017-0.018) | 0.006 (0.006-0.006) | 0.077 (0.076-0.080) | 0.032 (0.032-0.032) |
| fib | 0.200 (0.200-0.204) | 0.190 (0.190-0.191) | 0.108 (0.108-0.110) | 0.379 (0.374-0.385) | 0.275 (0.270-0.279) | 0.206 (0.204-0.207) |
| html | 0.089 (0.089-0.091) | 0.072 (0.072-0.073) | 0.085 (0.081-0.088) | 0.130 (0.127-0.132) | n/a | n/a |
| html_hand | 0.072 (0.071-0.073) | 0.056 (0.054-0.059) | n/a | n/a | n/a | n/a |
| http_parse | 0.068 (0.068-0.070) | 0.058 (0.057-0.059) | n/a | n/a | n/a | n/a |
| mapfreq | 0.095 (0.093-0.100) | 0.096 (0.094-0.097) | 0.050 (0.048-0.050) | 0.070 (0.067-0.072) | n/a | n/a |
| mutres | 0.094 (0.092-0.101) | 0.074 (0.073-0.074) | 0.021 (0.021-0.021) | 0.023 (0.023-0.024) | 0.061 (0.060-0.063) | 0.027 (0.027-0.027) |
| nbody | 0.045 (0.044-0.046) | 0.045 (0.045-0.046) | 0.043 (0.043-0.045) | 0.055 (0.049-0.059) | n/a | n/a |
| pqueue | 0.094 (0.093-0.120) | 0.080 (0.076-0.107) | 0.049 (0.048-0.049) | 0.129 (0.126-0.131) | 0.170 (0.157-0.173) | 0.057 (0.055-0.059) |
| qsort_func | 0.148 (0.143-0.149) | 0.145 (0.141-0.151) | 0.159 (0.158-0.163) | 0.250 (0.248-0.255) | n/a | n/a |
| qsort_inplace | 0.080 (0.079-0.083) | 0.084 (0.083-0.087) | 0.072 (0.070-0.073) | 0.082 (0.078-0.086) | n/a | n/a |
| sieve | 0.075 (0.075-0.115) | 0.073 (0.073-0.073) | 0.071 (0.070-0.071) | 0.168 (0.147-0.181) | 0.123 (0.120-0.127) | 0.071 (0.071-0.073) |
| sortedmap | 0.157 (0.156-0.161) | 0.164 (0.164-0.168) | n/a | n/a | n/a | n/a |
| streams | 0.081 (0.081-0.082) | 0.075 (0.073-0.078) | n/a | n/a | n/a | n/a |
| strings | 0.049 (0.049-0.051) | 0.047 (0.046-0.048) | 0.043 (0.043-0.045) | 0.046 (0.040-0.050) | 0.173 (0.168-0.182) | 0.021 (0.021-0.023) |
| tasks | 3.000 (2.971-3.082) | 3.035 (3.024-3.217) | n/a | n/a | n/a | n/a |
| url | 0.215 (0.211-0.217) | 0.186 (0.182-0.188) | n/a | n/a | n/a | n/a |
| wordfreq | 0.077 (0.076-0.079) | 0.073 (0.072-0.076) | 0.064 (0.064-0.065) | 0.079 (0.077-0.079) | n/a | n/a |

### Ratio to C (wall-time median; lower is better, 1.00x = as fast as C)

| benchmark | Orin C/C | Orin LLVM/C | Go/C | Java/C | Rust/C |
|---|---:|---:|---:|---:|---:|
| appends | 1.39x | 1.25x | 1.95x | 15.73x | 0.79x |
| bintrees | 0.81x | 0.79x | 2.39x | 0.73x | 1.31x |
| bytesstr | 1.47x | 1.27x | 0.34x | 4.45x | 1.84x |
| fib | 1.85x | 1.76x | 3.49x | 2.53x | 1.90x |
| html | 1.05x | 0.85x | 1.53x | n/a | n/a |
| html_hand | n/a | n/a | n/a | n/a | n/a |
| http_parse | n/a | n/a | n/a | n/a | n/a |
| mapfreq | 1.91x | 1.93x | 1.40x | n/a | n/a |
| mutres | 4.52x | 3.53x | 1.12x | 2.95x | 1.29x |
| nbody | 1.03x | 1.04x | 1.28x | n/a | n/a |
| pqueue | 1.93x | 1.63x | 2.63x | 3.47x | 1.15x |
| qsort_func | 0.93x | 0.91x | 1.57x | n/a | n/a |
| qsort_inplace | 1.12x | 1.17x | 1.15x | n/a | n/a |
| sieve | 1.06x | 1.04x | 2.38x | 1.74x | 1.01x |
| sortedmap | n/a | n/a | n/a | n/a | n/a |
| streams | n/a | n/a | n/a | n/a | n/a |
| strings | 1.15x | 1.09x | 1.07x | 4.00x | 0.49x |
| tasks | n/a | n/a | n/a | n/a | n/a |
| url | n/a | n/a | n/a | n/a | n/a |
| wordfreq | 1.19x | 1.14x | 1.23x | n/a | n/a |

### CPU time (user + sys, median s) and peak RSS (MiB)

| benchmark | orin CPU | llvm CPU | c CPU | go CPU | java CPU | rust CPU | orin RSS | llvm RSS | c RSS | go RSS | java RSS | rust RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| appends | 0.005 | 0.004 | 0.004 | 0.010 | 0.077 | 0.003 | 4.6 | 4.8 | 4.9 | 7.6 | 48.6 | 5.0 |
| bintrees | 0.245 | 0.240 | 0.303 | 1.568 | 0.261 | 0.398 | 17.6 | 17.9 | 9.7 | 13.1 | 300.9 | 10.2 |
| bytesstr | 0.025 | 0.022 | 0.017 | 0.008 | 0.091 | 0.032 | 11.6 | 11.8 | 11.7 | 6.2 | 104.4 | 4.9 |
| fib | 0.200 | 0.190 | 0.108 | 0.380 | 0.284 | 0.206 | 1.6 | 1.9 | 1.6 | 1.7 | 38.5 | 2.1 |
| html | 0.089 | 0.072 | 0.084 | 0.172 | n/a | n/a | 3.9 | 4.2 | 2.2 | 7.6 | n/a | n/a |
| html_hand | 0.071 | 0.056 | n/a | n/a | n/a | n/a | 2.5 | 2.9 | n/a | n/a | n/a | n/a |
| http_parse | 0.067 | 0.058 | n/a | n/a | n/a | n/a | 1.7 | 2.1 | n/a | n/a | n/a | n/a |
| mapfreq | 0.095 | 0.096 | 0.049 | 0.077 | n/a | n/a | 11.4 | 11.6 | 5.1 | 7.1 | n/a | n/a |
| mutres | 0.094 | 0.073 | 0.020 | 0.023 | 0.085 | 0.026 | 1.6 | 1.9 | 1.6 | 1.7 | 38.9 | 2.1 |
| nbody | 0.044 | 0.045 | 0.043 | 0.056 | n/a | n/a | 1.9 | 1.9 | 2.0 | 1.6 | n/a | n/a |
| pqueue | 0.094 | 0.079 | 0.049 | 0.135 | 0.216 | 0.056 | 6.2 | 6.5 | 4.9 | 14.6 | 62.0 | 5.1 |
| qsort_func | 0.147 | 0.145 | 0.159 | 0.305 | n/a | n/a | 36.5 | 36.8 | 23.8 | 37.1 | n/a | n/a |
| qsort_inplace | 0.080 | 0.084 | 0.071 | 0.092 | n/a | n/a | 16.8 | 17.1 | 16.9 | 24.5 | n/a | n/a |
| sieve | 0.074 | 0.073 | 0.070 | 0.279 | 0.142 | 0.071 | 77.8 | 78.1 | 77.7 | 231.7 | 115.9 | 78.3 |
| sortedmap | 0.157 | 0.163 | n/a | n/a | n/a | n/a | 11.3 | 11.5 | n/a | n/a | n/a | n/a |
| streams | 0.081 | 0.074 | n/a | n/a | n/a | n/a | 39.8 | 40.0 | n/a | n/a | n/a | n/a |
| strings | 0.049 | 0.047 | 0.043 | 0.059 | 0.327 | 0.021 | 46.2 | 46.5 | 34.7 | 23.5 | 139.5 | 19.9 |
| tasks | 3.488 | 3.507 | n/a | n/a | n/a | n/a | 14.2 | 14.5 | n/a | n/a | n/a | n/a |
| url | 0.215 | 0.185 | n/a | n/a | n/a | n/a | 6.5 | 6.8 | n/a | n/a | n/a | n/a |
| wordfreq | 0.077 | 0.073 | 0.064 | 0.081 | n/a | n/a | 2.4 | 2.6 | 2.0 | 6.5 | n/a | n/a |

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
| parallel_collatz | 1 | 0.394 (0.392-0.411) | 0.393 | 1.00x | 100 % | 1.00x | same |
| parallel_collatz | 2 | 0.229 (0.227-0.235) | 0.416 | 1.72x | 86 % | 1.06x | same |
| parallel_collatz | 4 | 0.143 (0.143-0.144) | 0.482 | 2.76x | 69 % | 1.23x | same |
| streams_parallel | 1 | 0.449 (0.439-0.465) | 0.448 | 1.00x | 100 % | 1.00x | same |
| streams_parallel | 2 | 0.233 (0.230-0.239) | 0.447 | 1.93x | 96 % | 1.00x | same |
| streams_parallel | 4 | 0.153 (0.150-0.156) | 0.548 | 2.94x | 73 % | 1.22x | same |

Speedup = wall(1 thread) / wall(n); efficiency = speedup / n. CPU time that grows with n is overhead or oversubscription (more threads than free cores).

### Self-compile (orin2 compiles compiler/main.or)

| wall s (min-max) | CPU s | peak RSS MiB | instructions | output identical to stage2.c |
|---:|---:|---:|---:|---|
| 2.146 (2.126-2.214) | 3.319 | 393.7 | 28,929,128,127 | yes |


## All runs

| date | commit | ref | self-compile instructions | self-compile wall s | file |
|---|---|---|---:|---:|---|
| 2026-10-21T09:16:22Z | `7635a6de4b` | main | 28,929,128,127 | 2.146 | [json](history/2026-10-21-7635a6de4ba0.json) |
| 2026-10-20T09:21:19Z | `7635a6de4b` | main | 28,924,224,488 | 2.688 | [json](history/2026-10-20-7635a6de4ba0.json) |
| 2026-10-19T09:49:07Z | `7635a6de4b` | main | 28,920,330,777 | 2.632 | [json](history/2026-10-19-7635a6de4ba0.json) |
| 2026-10-18T08:43:59Z | `7635a6de4b` | main | 28,927,449,240 | 2.360 | [json](history/2026-10-18-7635a6de4ba0.json) |
| 2026-10-17T08:29:19Z | `d0a17a9682` | main | 26,314,861,202 | 2.370 | [json](history/2026-10-17-d0a17a968285.json) |
| 2026-10-16T08:55:17Z | `9f83f16af4` | main | 24,496,056,957 | 2.438 | [json](history/2026-10-16-9f83f16af402.json) |
| 2026-10-14T17:32:27Z | `f837889af7` | main | 35,729,157,194 | 3.937 | [json](history/2026-10-14-f837889af7a9.json) |
