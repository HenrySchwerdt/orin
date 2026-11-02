# Orin benchmark history

Written by `.github/workflows/bench.yml` (nightly and manual runs on `main`); one JSON file per run in [`history/`](history/), charts rendered by `tooling/benchmarks` (`bench-report render`, no external services). The same data as a stand-alone page: [`report.html`](report.html). Metrics and methodology: `docs/benchmarks.md` on `main`. Do not edit this branch by hand.

19 runs, 2026-10-14 to 2026-11-02. Latest: [`7635a6de4b`](https://github.com/HenrySchwerdt/orin/commit/7635a6de4ba00d5f68f1c6355860428eaad22201).

Instruction counts are the regression metric: they are deterministic for single-threaded programs, while wall time on a shared runner moves by 10-25 % between identical binaries.

![Orin to C wall-time ratio per benchmark over time](charts/ratio_wall.svg)

![Orin to C executed-instruction ratio per benchmark over time](charts/ratio_instructions.svg)

![Self-compile instructions and wall time over time](charts/selfcompile.svg)

![Parallel speedup by worker threads](charts/parallel.svg)

## Latest run


Commit `7635a6de4b` (main), 2026-11-02T12:12:00Z. Machine: AMD EPYC 9V74 80-Core Processor, 4 cores, 15.6 GiB, Linux-7.0.0-1017-azure-x86_64-with-glibc2.39. Runs per cell: 5 (median after one warm-up).

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
| appends | 0.007 (0.007-0.007) | 0.006 (0.006-0.006) | 0.005 (0.005-0.005) | 0.011 (0.009-0.027) | 0.063 (0.060-0.067) | 0.004 (0.004-0.004) |
| bintrees | 0.341 (0.336-0.354) | 0.345 (0.340-0.352) | 0.483 (0.473-0.487) | 1.023 (1.016-1.042) | 0.302 (0.296-0.312) | 0.587 (0.586-0.591) |
| bytesstr | 0.034 (0.033-0.035) | 0.029 (0.029-0.030) | 0.021 (0.020-0.021) | 0.008 (0.007-0.024) | 0.090 (0.087-0.102) | 0.033 (0.032-0.035) |
| fib | 0.264 (0.260-0.265) | 0.291 (0.286-0.291) | 0.153 (0.153-0.156) | 0.529 (0.520-0.537) | 0.336 (0.332-0.345) | 0.275 (0.273-0.278) |
| html | 0.129 (0.127-0.130) | 0.104 (0.101-0.105) | 0.125 (0.122-0.129) | 0.187 (0.179-0.201) | n/a | n/a |
| html_hand | 0.106 (0.104-0.109) | 0.083 (0.081-0.084) | n/a | n/a | n/a | n/a |
| http_parse | 0.097 (0.096-0.098) | 0.085 (0.084-0.086) | n/a | n/a | n/a | n/a |
| mapfreq | 0.125 (0.123-0.128) | 0.126 (0.122-0.127) | 0.064 (0.063-0.065) | 0.094 (0.093-0.095) | n/a | n/a |
| mutres | 0.157 (0.154-0.160) | 0.121 (0.117-0.143) | 0.028 (0.028-0.029) | 0.038 (0.038-0.039) | 0.070 (0.070-0.072) | 0.033 (0.032-0.033) |
| nbody | 0.061 (0.061-0.062) | 0.064 (0.064-0.065) | 0.061 (0.061-0.062) | 0.072 (0.071-0.073) | n/a | n/a |
| pqueue | 0.129 (0.128-0.132) | 0.111 (0.106-0.113) | 0.061 (0.059-0.063) | 0.166 (0.164-0.169) | 0.215 (0.189-0.219) | 0.077 (0.075-0.079) |
| qsort_func | 0.179 (0.178-0.181) | 0.184 (0.183-0.193) | 0.196 (0.191-0.203) | 0.326 (0.324-0.356) | n/a | n/a |
| qsort_inplace | 0.099 (0.098-0.100) | 0.108 (0.101-0.111) | 0.077 (0.076-0.078) | 0.096 (0.093-0.111) | n/a | n/a |
| sieve | 0.117 (0.113-0.119) | 0.115 (0.115-0.116) | 0.106 (0.103-0.108) | 0.234 (0.207-0.248) | 0.169 (0.161-0.170) | 0.108 (0.105-0.114) |
| sortedmap | 0.213 (0.207-0.214) | 0.222 (0.221-0.227) | n/a | n/a | n/a | n/a |
| streams | 0.112 (0.111-0.114) | 0.102 (0.100-0.103) | n/a | n/a | n/a | n/a |
| strings | 0.067 (0.066-0.071) | 0.064 (0.064-0.064) | 0.059 (0.058-0.061) | 0.058 (0.055-0.070) | 0.204 (0.199-0.225) | 0.028 (0.026-0.028) |
| tasks | 3.444 (3.428-3.545) | 3.408 (3.366-3.461) | n/a | n/a | n/a | n/a |
| url | 0.302 (0.301-0.324) | 0.269 (0.268-0.279) | n/a | n/a | n/a | n/a |
| wordfreq | 0.097 (0.097-0.098) | 0.096 (0.096-0.098) | 0.082 (0.082-0.083) | 0.095 (0.094-0.096) | n/a | n/a |

### Ratio to C (wall-time median; lower is better, 1.00x = as fast as C)

| benchmark | Orin C/C | Orin LLVM/C | Go/C | Java/C | Rust/C |
|---|---:|---:|---:|---:|---:|
| appends | 1.54x | 1.35x | 2.36x | 13.58x | 0.82x |
| bintrees | 0.70x | 0.71x | 2.12x | 0.62x | 1.21x |
| bytesstr | 1.66x | 1.42x | 0.39x | 4.34x | 1.61x |
| fib | 1.72x | 1.89x | 3.45x | 2.19x | 1.79x |
| html | 1.03x | 0.83x | 1.49x | n/a | n/a |
| html_hand | n/a | n/a | n/a | n/a | n/a |
| http_parse | n/a | n/a | n/a | n/a | n/a |
| mapfreq | 1.97x | 1.97x | 1.47x | n/a | n/a |
| mutres | 5.52x | 4.24x | 1.35x | 2.48x | 1.17x |
| nbody | 1.00x | 1.06x | 1.19x | n/a | n/a |
| pqueue | 2.10x | 1.81x | 2.70x | 3.50x | 1.25x |
| qsort_func | 0.91x | 0.94x | 1.67x | n/a | n/a |
| qsort_inplace | 1.29x | 1.40x | 1.25x | n/a | n/a |
| sieve | 1.10x | 1.09x | 2.21x | 1.60x | 1.02x |
| sortedmap | n/a | n/a | n/a | n/a | n/a |
| streams | n/a | n/a | n/a | n/a | n/a |
| strings | 1.14x | 1.10x | 0.99x | 3.48x | 0.47x |
| tasks | n/a | n/a | n/a | n/a | n/a |
| url | n/a | n/a | n/a | n/a | n/a |
| wordfreq | 1.18x | 1.17x | 1.16x | n/a | n/a |

### CPU time (user + sys, median s) and peak RSS (MiB)

| benchmark | orin CPU | llvm CPU | c CPU | go CPU | java CPU | rust CPU | orin RSS | llvm RSS | c RSS | go RSS | java RSS | rust RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| appends | 0.007 | 0.006 | 0.004 | 0.015 | 0.096 | 0.004 | 4.6 | 4.8 | 4.9 | 8.9 | 47.7 | 5.0 |
| bintrees | 0.340 | 0.345 | 0.483 | 2.154 | 0.346 | 0.587 | 17.6 | 17.9 | 9.7 | 12.2 | 301.1 | 10.1 |
| bytesstr | 0.034 | 0.029 | 0.020 | 0.011 | 0.106 | 0.033 | 11.6 | 11.8 | 11.7 | 7.1 | 104.4 | 4.9 |
| fib | 0.263 | 0.290 | 0.153 | 0.531 | 0.347 | 0.275 | 1.6 | 1.9 | 1.6 | 1.7 | 38.7 | 2.0 |
| html | 0.129 | 0.104 | 0.125 | 0.243 | n/a | n/a | 3.9 | 4.2 | 2.2 | 7.9 | n/a | n/a |
| html_hand | 0.105 | 0.083 | n/a | n/a | n/a | n/a | 2.5 | 2.9 | n/a | n/a | n/a | n/a |
| http_parse | 0.096 | 0.084 | n/a | n/a | n/a | n/a | 1.7 | 2.0 | n/a | n/a | n/a | n/a |
| mapfreq | 0.125 | 0.125 | 0.063 | 0.104 | n/a | n/a | 11.4 | 11.6 | 5.1 | 7.4 | n/a | n/a |
| mutres | 0.156 | 0.120 | 0.028 | 0.039 | 0.095 | 0.033 | 1.6 | 1.9 | 1.6 | 1.8 | 39.0 | 2.1 |
| nbody | 0.061 | 0.064 | 0.060 | 0.073 | n/a | n/a | 1.9 | 1.9 | 2.0 | 1.7 | n/a | n/a |
| pqueue | 0.129 | 0.111 | 0.061 | 0.174 | 0.267 | 0.077 | 6.2 | 6.5 | 4.9 | 15.0 | 61.9 | 5.2 |
| qsort_func | 0.178 | 0.184 | 0.195 | 0.413 | n/a | n/a | 36.5 | 36.7 | 23.8 | 43.5 | n/a | n/a |
| qsort_inplace | 0.099 | 0.108 | 0.077 | 0.116 | n/a | n/a | 16.8 | 17.1 | 16.9 | 26.0 | n/a | n/a |
| sieve | 0.116 | 0.115 | 0.105 | 0.344 | 0.191 | 0.108 | 77.8 | 78.1 | 77.7 | 185.9 | 116.0 | 78.4 |
| sortedmap | 0.213 | 0.222 | n/a | n/a | n/a | n/a | 11.3 | 11.5 | n/a | n/a | n/a | n/a |
| streams | 0.112 | 0.101 | n/a | n/a | n/a | n/a | 39.8 | 40.0 | n/a | n/a | n/a | n/a |
| strings | 0.066 | 0.064 | 0.058 | 0.072 | 0.389 | 0.027 | 46.2 | 46.5 | 34.7 | 21.3 | 139.5 | 19.9 |
| tasks | 4.037 | 3.956 | n/a | n/a | n/a | n/a | 14.2 | 14.5 | n/a | n/a | n/a | n/a |
| url | 0.302 | 0.268 | n/a | n/a | n/a | n/a | 6.5 | 6.8 | n/a | n/a | n/a | n/a |
| wordfreq | 0.096 | 0.096 | 0.082 | 0.097 | n/a | n/a | 2.4 | 2.6 | 2.0 | 6.7 | n/a | n/a |

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
| parallel_collatz | 1 | 0.425 (0.424-0.426) | 0.424 | 1.00x | 100 % | 1.00x | same |
| parallel_collatz | 2 | 0.252 (0.252-0.253) | 0.453 | 1.69x | 84 % | 1.07x | same |
| parallel_collatz | 4 | 0.159 (0.158-0.159) | 0.531 | 2.67x | 67 % | 1.25x | same |
| streams_parallel | 1 | 0.422 (0.421-0.422) | 0.422 | 1.00x | 100 % | 1.00x | same |
| streams_parallel | 2 | 0.222 (0.222-0.222) | 0.422 | 1.90x | 95 % | 1.00x | same |
| streams_parallel | 4 | 0.152 (0.152-0.153) | 0.544 | 2.78x | 69 % | 1.29x | same |

Speedup = wall(1 thread) / wall(n); efficiency = speedup / n. CPU time that grows with n is overhead or oversubscription (more threads than free cores).

### Self-compile (orin2 compiles compiler/main.or)

| wall s (min-max) | CPU s | peak RSS MiB | instructions | output identical to stage2.c |
|---:|---:|---:|---:|---|
| 2.587 (2.581-2.649) | 4.233 | 394.1 | 28,930,351,842 | yes |


## All runs

| date | commit | ref | self-compile instructions | self-compile wall s | file |
|---|---|---|---:|---:|---|
| 2026-11-02T12:12:00Z | `7635a6de4b` | main | 28,930,351,842 | 2.587 | [json](history/2026-11-02-7635a6de4ba0.json) |
| 2026-11-01T11:15:45Z | `7635a6de4b` | main | 28,919,490,355 | 2.724 | [json](history/2026-11-01-7635a6de4ba0.json) |
| 2026-10-31T10:26:16Z | `7635a6de4b` | main | 28,907,840,339 | 2.912 | [json](history/2026-10-31-7635a6de4ba0.json) |
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
