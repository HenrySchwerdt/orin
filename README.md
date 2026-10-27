# Orin benchmark history

Written by `.github/workflows/bench.yml` (nightly and manual runs on `main`); one JSON file per run in [`history/`](history/), charts rendered by `tooling/benchmarks` (`bench-report render`, no external services). The same data as a stand-alone page: [`report.html`](report.html). Metrics and methodology: `docs/benchmarks.md` on `main`. Do not edit this branch by hand.

13 runs, 2026-10-14 to 2026-10-27. Latest: [`7635a6de4b`](https://github.com/HenrySchwerdt/orin/commit/7635a6de4ba00d5f68f1c6355860428eaad22201).

Instruction counts are the regression metric: they are deterministic for single-threaded programs, while wall time on a shared runner moves by 10-25 % between identical binaries.

![Orin to C wall-time ratio per benchmark over time](charts/ratio_wall.svg)

![Orin to C executed-instruction ratio per benchmark over time](charts/ratio_instructions.svg)

![Self-compile instructions and wall time over time](charts/selfcompile.svg)

![Parallel speedup by worker threads](charts/parallel.svg)

## Latest run


Commit `7635a6de4b` (main), 2026-10-27T09:54:38Z. Machine: AMD EPYC 9V74 80-Core Processor, 4 cores, 15.6 GiB, Linux-6.17.0-1022-azure-x86_64-with-glibc2.39. Runs per cell: 5 (median after one warm-up).

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
| appends | 0.007 (0.007-0.007) | 0.006 (0.006-0.006) | 0.004 (0.004-0.005) | 0.005 (0.004-0.029) | 0.057 (0.047-0.060) | 0.003 (0.003-0.003) |
| bintrees | 0.323 (0.318-0.427) | 0.324 (0.320-0.326) | 0.453 (0.452-0.459) | 0.954 (0.948-0.966) | 0.166 (0.164-0.167) | 0.567 (0.564-0.587) |
| bytesstr | 0.027 (0.027-0.028) | 0.024 (0.023-0.024) | 0.015 (0.014-0.015) | 0.006 (0.005-0.021) | 0.057 (0.050-0.090) | 0.031 (0.029-0.032) |
| fib | 0.254 (0.254-0.254) | 0.281 (0.280-0.281) | 0.151 (0.151-0.151) | 0.514 (0.514-0.514) | 0.316 (0.311-0.433) | 0.271 (0.271-0.272) |
| html | 0.125 (0.124-0.127) | 0.102 (0.100-0.104) | 0.124 (0.124-0.124) | 0.177 (0.174-0.188) | n/a | n/a |
| html_hand | 0.100 (0.100-0.101) | 0.081 (0.077-0.082) | n/a | n/a | n/a | n/a |
| http_parse | 0.095 (0.094-0.111) | 0.081 (0.081-0.082) | n/a | n/a | n/a | n/a |
| mapfreq | 0.119 (0.119-0.119) | 0.120 (0.119-0.120) | 0.059 (0.056-0.060) | 0.083 (0.083-0.085) | n/a | n/a |
| mutres | 0.149 (0.149-0.149) | 0.116 (0.116-0.117) | 0.027 (0.027-0.027) | 0.036 (0.036-0.036) | 0.066 (0.066-0.070) | 0.033 (0.032-0.034) |
| nbody | 0.061 (0.061-0.061) | 0.064 (0.064-0.064) | 0.061 (0.061-0.061) | 0.072 (0.071-0.072) | n/a | n/a |
| pqueue | 0.126 (0.126-0.127) | 0.105 (0.105-0.105) | 0.057 (0.057-0.058) | 0.156 (0.154-0.157) | 0.166 (0.161-0.171) | 0.075 (0.074-0.075) |
| qsort_func | 0.170 (0.169-0.170) | 0.172 (0.170-0.175) | 0.182 (0.181-0.183) | 0.279 (0.271-0.289) | n/a | n/a |
| qsort_inplace | 0.092 (0.092-0.093) | 0.098 (0.095-0.101) | 0.070 (0.070-0.070) | 0.079 (0.079-0.167) | n/a | n/a |
| sieve | 0.084 (0.083-0.085) | 0.083 (0.082-0.084) | 0.078 (0.073-0.084) | 0.116 (0.109-0.120) | 0.128 (0.126-0.132) | 0.081 (0.076-0.083) |
| sortedmap | 0.204 (0.204-0.205) | 0.214 (0.214-0.215) | n/a | n/a | n/a | n/a |
| streams | 0.088 (0.087-0.088) | 0.078 (0.077-0.091) | n/a | n/a | n/a | n/a |
| strings | 0.061 (0.061-0.061) | 0.059 (0.058-0.059) | 0.052 (0.052-0.052) | 0.041 (0.039-0.043) | 0.153 (0.149-0.157) | 0.023 (0.023-0.024) |
| tasks | 3.709 (3.662-3.763) | 3.618 (3.577-3.719) | n/a | n/a | n/a | n/a |
| url | 0.299 (0.295-0.317) | 0.274 (0.263-0.279) | n/a | n/a | n/a | n/a |
| wordfreq | 0.097 (0.096-0.098) | 0.096 (0.096-0.097) | 0.082 (0.082-0.179) | 0.089 (0.088-0.093) | n/a | n/a |

### Ratio to C (wall-time median; lower is better, 1.00x = as fast as C)

| benchmark | Orin C/C | Orin LLVM/C | Go/C | Java/C | Rust/C |
|---|---:|---:|---:|---:|---:|
| appends | 1.55x | 1.32x | 1.17x | 13.01x | 0.76x |
| bintrees | 0.71x | 0.71x | 2.11x | 0.37x | 1.25x |
| bytesstr | 1.86x | 1.61x | 0.42x | 3.91x | 2.13x |
| fib | 1.68x | 1.86x | 3.41x | 2.10x | 1.80x |
| html | 1.01x | 0.82x | 1.43x | n/a | n/a |
| html_hand | n/a | n/a | n/a | n/a | n/a |
| http_parse | n/a | n/a | n/a | n/a | n/a |
| mapfreq | 2.01x | 2.02x | 1.41x | n/a | n/a |
| mutres | 5.46x | 4.25x | 1.33x | 2.41x | 1.21x |
| nbody | 1.00x | 1.06x | 1.18x | n/a | n/a |
| pqueue | 2.20x | 1.83x | 2.71x | 2.89x | 1.30x |
| qsort_func | 0.93x | 0.94x | 1.53x | n/a | n/a |
| qsort_inplace | 1.32x | 1.40x | 1.13x | n/a | n/a |
| sieve | 1.07x | 1.06x | 1.48x | 1.64x | 1.04x |
| sortedmap | n/a | n/a | n/a | n/a | n/a |
| streams | n/a | n/a | n/a | n/a | n/a |
| strings | 1.18x | 1.13x | 0.80x | 2.94x | 0.45x |
| tasks | n/a | n/a | n/a | n/a | n/a |
| url | n/a | n/a | n/a | n/a | n/a |
| wordfreq | 1.19x | 1.17x | 1.09x | n/a | n/a |

### CPU time (user + sys, median s) and peak RSS (MiB)

| benchmark | orin CPU | llvm CPU | c CPU | go CPU | java CPU | rust CPU | orin RSS | llvm RSS | c RSS | go RSS | java RSS | rust RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| appends | 0.007 | 0.006 | 0.004 | 0.006 | 0.075 | 0.003 | 4.6 | 4.8 | 4.9 | 11.5 | 58.6 | 5.2 |
| bintrees | 0.321 | 0.323 | 0.453 | 2.027 | 0.204 | 0.566 | 17.6 | 17.9 | 9.7 | 14.5 | 307.8 | 10.1 |
| bytesstr | 0.027 | 0.023 | 0.014 | 0.009 | 0.066 | 0.031 | 11.6 | 11.8 | 11.6 | 10.0 | 108.1 | 5.0 |
| fib | 0.254 | 0.280 | 0.151 | 0.515 | 0.326 | 0.271 | 1.6 | 1.9 | 1.6 | 3.4 | 47.6 | 2.0 |
| html | 0.125 | 0.102 | 0.124 | 0.232 | n/a | n/a | 3.9 | 4.2 | 2.2 | 8.2 | n/a | n/a |
| html_hand | 0.100 | 0.081 | n/a | n/a | n/a | n/a | 2.5 | 2.8 | n/a | n/a | n/a | n/a |
| http_parse | 0.095 | 0.081 | n/a | n/a | n/a | n/a | 1.7 | 2.0 | n/a | n/a | n/a | n/a |
| mapfreq | 0.118 | 0.119 | 0.059 | 0.093 | n/a | n/a | 11.4 | 11.6 | 5.2 | 9.9 | n/a | n/a |
| mutres | 0.149 | 0.116 | 0.027 | 0.036 | 0.091 | 0.033 | 1.6 | 1.9 | 1.6 | 3.4 | 48.0 | 2.1 |
| nbody | 0.060 | 0.064 | 0.060 | 0.072 | n/a | n/a | 1.9 | 1.9 | 2.0 | 3.4 | n/a | n/a |
| pqueue | 0.126 | 0.105 | 0.057 | 0.160 | 0.229 | 0.074 | 6.2 | 6.5 | 4.9 | 16.0 | 70.6 | 5.1 |
| qsort_func | 0.170 | 0.171 | 0.182 | 0.329 | n/a | n/a | 36.6 | 36.8 | 24.8 | 40.5 | n/a | n/a |
| qsort_inplace | 0.092 | 0.098 | 0.070 | 0.086 | n/a | n/a | 16.8 | 17.1 | 16.9 | 25.4 | n/a | n/a |
| sieve | 0.083 | 0.083 | 0.078 | 0.154 | 0.152 | 0.081 | 79.1 | 78.9 | 79.0 | 273.7 | 124.6 | 79.1 |
| sortedmap | 0.204 | 0.214 | n/a | n/a | n/a | n/a | 11.3 | 11.5 | n/a | n/a | n/a | n/a |
| streams | 0.087 | 0.078 | n/a | n/a | n/a | n/a | 42.7 | 41.7 | n/a | n/a | n/a | n/a |
| strings | 0.061 | 0.059 | 0.052 | 0.049 | 0.310 | 0.023 | 47.5 | 47.8 | 36.5 | 25.8 | 145.8 | 21.9 |
| tasks | 4.313 | 4.098 | n/a | n/a | n/a | n/a | 18.1 | 18.5 | n/a | n/a | n/a | n/a |
| url | 0.298 | 0.273 | n/a | n/a | n/a | n/a | 6.5 | 6.8 | n/a | n/a | n/a | n/a |
| wordfreq | 0.097 | 0.096 | 0.082 | 0.091 | n/a | n/a | 2.4 | 2.6 | 2.0 | 7.8 | n/a | n/a |

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
| parallel_collatz | 1 | 0.416 (0.416-0.419) | 0.416 | 1.00x | 100 % | 1.00x | same |
| parallel_collatz | 2 | 0.230 (0.229-0.231) | 0.428 | 1.81x | 91 % | 1.03x | same |
| parallel_collatz | 4 | 0.147 (0.147-0.150) | 0.514 | 2.82x | 71 % | 1.23x | same |
| streams_parallel | 1 | 0.412 (0.412-0.413) | 0.411 | 1.00x | 100 % | 1.00x | same |
| streams_parallel | 2 | 0.212 (0.212-0.213) | 0.413 | 1.94x | 97 % | 1.00x | same |
| streams_parallel | 4 | 0.143 (0.142-0.151) | 0.534 | 2.89x | 72 % | 1.30x | same |

Speedup = wall(1 thread) / wall(n); efficiency = speedup / n. CPU time that grows with n is overhead or oversubscription (more threads than free cores).

### Self-compile (orin2 compiles compiler/main.or)

| wall s (min-max) | CPU s | peak RSS MiB | instructions | output identical to stage2.c |
|---:|---:|---:|---:|---|
| 2.422 (2.367-2.461) | 4.047 | 400.5 | 28,929,325,676 | yes |


## All runs

| date | commit | ref | self-compile instructions | self-compile wall s | file |
|---|---|---|---:|---:|---|
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
