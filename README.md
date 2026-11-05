# Orin benchmark history

Written by `.github/workflows/bench.yml` (nightly and manual runs on `main`); one JSON file per run in [`history/`](history/), charts rendered by `tooling/benchmarks` (`bench-report render`, no external services). The same data as a stand-alone page: [`report.html`](report.html). Metrics and methodology: `docs/benchmarks.md` on `main`. Do not edit this branch by hand.

22 runs, 2026-10-14 to 2026-11-05. Latest: [`7635a6de4b`](https://github.com/HenrySchwerdt/orin/commit/7635a6de4ba00d5f68f1c6355860428eaad22201).

Instruction counts are the regression metric: they are deterministic for single-threaded programs, while wall time on a shared runner moves by 10-25 % between identical binaries.

![Orin to C wall-time ratio per benchmark over time](charts/ratio_wall.svg)

![Orin to C executed-instruction ratio per benchmark over time](charts/ratio_instructions.svg)

![Self-compile instructions and wall time over time](charts/selfcompile.svg)

![Parallel speedup by worker threads](charts/parallel.svg)

## Latest run


Commit `7635a6de4b` (main), 2026-11-05T12:03:31Z. Machine: AMD EPYC 9V74 80-Core Processor, 4 cores, 15.6 GiB, Linux-7.0.0-1017-azure-x86_64-with-glibc2.43. Runs per cell: 5 (median after one warm-up).

<details><summary>Tool versions</summary>

- cc: `cc (Ubuntu 15.2.0-16ubuntu1) 15.2.0`
- clang: `Ubuntu clang version 21.1.8 (6ubuntu1)`
- go: `go version go1.24.13 linux/amd64`
- java: `openjdk version "21.0.13" 2026-10-20 LTS`
- python: `3.14.4`
- rustc: `rustc 1.99.1 (58cf8f9c3 2026-10-13)`
- valgrind: `valgrind-3.26.0`

</details>

### Wall time, seconds (median; min-max)

| benchmark | Orin (C backend) | Orin (LLVM backend) | C | Go | Java | Rust |
|---|---:|---:|---:|---:|---:|---:|
| appends | 0.007 (0.007-0.007) | 0.006 (0.006-0.006) | 0.004 (0.004-0.004) | 0.010 (0.008-0.011) | 0.054 (0.054-0.068) | 0.003 (0.003-0.005) |
| bintrees | 0.331 (0.329-0.357) | 0.320 (0.317-0.325) | 0.810 (0.807-0.810) | 0.962 (0.956-1.031) | 0.279 (0.271-0.283) | 0.960 (0.956-0.973) |
| bytesstr | 0.031 (0.031-0.032) | 0.028 (0.027-0.028) | 0.018 (0.017-0.018) | 0.008 (0.007-0.017) | 0.077 (0.077-0.101) | 0.033 (0.032-0.033) |
| fib | 0.216 (0.216-0.219) | 0.272 (0.272-0.272) | 0.134 (0.133-0.134) | 0.512 (0.510-0.515) | 0.321 (0.314-0.326) | 0.271 (0.271-0.271) |
| html | 0.126 (0.125-0.128) | 0.104 (0.103-0.108) | 0.114 (0.113-0.115) | 0.181 (0.175-0.193) | n/a | n/a |
| html_hand | 0.104 (0.103-0.107) | 0.081 (0.077-0.082) | n/a | n/a | n/a | n/a |
| http_parse | 0.093 (0.093-0.095) | 0.080 (0.080-0.081) | n/a | n/a | n/a | n/a |
| mapfreq | 0.121 (0.121-0.122) | 0.121 (0.121-0.122) | 0.059 (0.059-0.060) | 0.090 (0.090-0.090) | n/a | n/a |
| mutres | 0.144 (0.144-0.147) | 0.116 (0.116-0.117) | 0.032 (0.032-0.032) | 0.036 (0.036-0.037) | 0.070 (0.067-0.072) | 0.033 (0.032-0.033) |
| nbody | 0.054 (0.054-0.055) | 0.064 (0.064-0.064) | 0.064 (0.064-0.064) | 0.072 (0.071-0.072) | n/a | n/a |
| pqueue | 0.124 (0.124-0.126) | 0.103 (0.103-0.107) | 0.061 (0.060-0.061) | 0.164 (0.163-0.174) | 0.208 (0.203-0.217) | 0.075 (0.074-0.106) |
| qsort_func | 0.178 (0.177-0.184) | 0.182 (0.181-0.186) | 0.164 (0.164-0.165) | 0.320 (0.304-0.335) | n/a | n/a |
| qsort_inplace | 0.100 (0.098-0.102) | 0.107 (0.107-0.110) | 0.076 (0.075-0.076) | 0.104 (0.095-0.112) | n/a | n/a |
| sieve | 0.107 (0.106-0.111) | 0.112 (0.107-0.113) | 0.099 (0.094-0.113) | 0.215 (0.201-0.266) | 0.152 (0.150-0.156) | 0.106 (0.102-0.120) |
| sortedmap | 0.208 (0.204-0.231) | 0.217 (0.216-0.219) | n/a | n/a | n/a | n/a |
| streams | 0.102 (0.101-0.104) | 0.100 (0.098-0.101) | n/a | n/a | n/a | n/a |
| strings | 0.066 (0.065-0.067) | 0.065 (0.065-0.066) | 0.060 (0.057-0.097) | 0.062 (0.053-0.065) | 0.194 (0.188-0.202) | 0.026 (0.025-0.026) |
| tasks | 3.334 (3.326-3.443) | 3.283 (3.211-3.408) | n/a | n/a | n/a | n/a |
| url | 0.293 (0.292-0.297) | 0.260 (0.256-0.306) | n/a | n/a | n/a | n/a |
| wordfreq | 0.096 (0.096-0.096) | 0.094 (0.094-0.095) | 0.080 (0.080-0.081) | 0.094 (0.094-0.095) | n/a | n/a |

### Ratio to C (wall-time median; lower is better, 1.00x = as fast as C)

| benchmark | Orin C/C | Orin LLVM/C | Go/C | Java/C | Rust/C |
|---|---:|---:|---:|---:|---:|
| appends | 1.81x | 1.51x | 2.52x | 13.79x | 0.88x |
| bintrees | 0.41x | 0.39x | 1.19x | 0.35x | 1.19x |
| bytesstr | 1.76x | 1.56x | 0.44x | 4.33x | 1.85x |
| fib | 1.61x | 2.04x | 3.83x | 2.40x | 2.03x |
| html | 1.10x | 0.91x | 1.59x | n/a | n/a |
| html_hand | n/a | n/a | n/a | n/a | n/a |
| http_parse | n/a | n/a | n/a | n/a | n/a |
| mapfreq | 2.05x | 2.04x | 1.52x | n/a | n/a |
| mutres | 4.53x | 3.66x | 1.14x | 2.20x | 1.04x |
| nbody | 0.85x | 1.00x | 1.13x | n/a | n/a |
| pqueue | 2.05x | 1.71x | 2.71x | 3.43x | 1.24x |
| qsort_func | 1.09x | 1.11x | 1.95x | n/a | n/a |
| qsort_inplace | 1.32x | 1.42x | 1.38x | n/a | n/a |
| sieve | 1.08x | 1.13x | 2.17x | 1.53x | 1.07x |
| sortedmap | n/a | n/a | n/a | n/a | n/a |
| streams | n/a | n/a | n/a | n/a | n/a |
| strings | 1.10x | 1.09x | 1.03x | 3.23x | 0.43x |
| tasks | n/a | n/a | n/a | n/a | n/a |
| url | n/a | n/a | n/a | n/a | n/a |
| wordfreq | 1.20x | 1.17x | 1.17x | n/a | n/a |

### CPU time (user + sys, median s) and peak RSS (MiB)

| benchmark | orin CPU | llvm CPU | c CPU | go CPU | java CPU | rust CPU | orin RSS | llvm RSS | c RSS | go RSS | java RSS | rust RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| appends | 0.007 | 0.006 | 0.004 | 0.014 | 0.088 | 0.003 | 4.8 | 5.0 | 4.8 | 8.4 | 47.9 | 5.2 |
| bintrees | 0.331 | 0.318 | 0.810 | 2.038 | 0.324 | 0.958 | 17.6 | 17.8 | 9.6 | 12.7 | 301.3 | 10.0 |
| bytesstr | 0.031 | 0.028 | 0.018 | 0.010 | 0.093 | 0.033 | 11.6 | 11.8 | 11.6 | 6.3 | 104.5 | 5.1 |
| fib | 0.215 | 0.272 | 0.133 | 0.513 | 0.331 | 0.271 | 1.6 | 1.8 | 1.5 | 1.9 | 39.0 | 2.0 |
| html | 0.126 | 0.103 | 0.114 | 0.235 | n/a | n/a | 4.0 | 4.2 | 2.1 | 7.6 | n/a | n/a |
| html_hand | 0.103 | 0.081 | n/a | n/a | n/a | n/a | 2.7 | 2.9 | n/a | n/a | n/a | n/a |
| http_parse | 0.093 | 0.080 | n/a | n/a | n/a | n/a | 1.8 | 1.9 | n/a | n/a | n/a | n/a |
| mapfreq | 0.121 | 0.121 | 0.059 | 0.100 | n/a | n/a | 11.2 | 11.4 | 5.0 | 7.4 | n/a | n/a |
| mutres | 0.144 | 0.116 | 0.032 | 0.037 | 0.092 | 0.033 | 1.7 | 1.8 | 1.5 | 1.8 | 39.1 | 2.1 |
| nbody | 0.054 | 0.064 | 0.064 | 0.073 | n/a | n/a | 1.8 | 1.9 | 1.7 | 1.7 | n/a | n/a |
| pqueue | 0.124 | 0.103 | 0.060 | 0.173 | 0.263 | 0.075 | 6.3 | 6.5 | 4.8 | 14.9 | 62.1 | 5.2 |
| qsort_func | 0.178 | 0.182 | 0.164 | 0.391 | n/a | n/a | 36.4 | 36.6 | 22.0 | 38.9 | n/a | n/a |
| qsort_inplace | 0.100 | 0.107 | 0.075 | 0.129 | n/a | n/a | 16.9 | 17.1 | 16.8 | 31.1 | n/a | n/a |
| sieve | 0.107 | 0.112 | 0.099 | 0.334 | 0.175 | 0.106 | 78.0 | 78.2 | 77.7 | 185.8 | 116.2 | 78.4 |
| sortedmap | 0.207 | 0.217 | n/a | n/a | n/a | n/a | 11.2 | 11.4 | n/a | n/a | n/a | n/a |
| streams | 0.101 | 0.099 | n/a | n/a | n/a | n/a | 39.9 | 40.0 | n/a | n/a | n/a | n/a |
| strings | 0.066 | 0.065 | 0.056 | 0.082 | 0.363 | 0.025 | 46.3 | 46.5 | 34.8 | 23.5 | 139.5 | 20.1 |
| tasks | 3.973 | 3.876 | n/a | n/a | n/a | n/a | 14.2 | 14.4 | n/a | n/a | n/a | n/a |
| url | 0.293 | 0.260 | n/a | n/a | n/a | n/a | 6.6 | 6.7 | n/a | n/a | n/a | n/a |
| wordfreq | 0.096 | 0.094 | 0.080 | 0.096 | n/a | n/a | 2.4 | 2.5 | 1.9 | 6.5 | n/a | n/a |

### Executed instructions (valgrind; the regression metric)

| benchmark | Orin C | Orin LLVM | C | Orin C/C | Orin LLVM/C | note |
|---|---:|---:|---:|---:|---:|---|
| appends | 60,396,423 | 43,975,986 | 18,927,528 | 3.19x | 2.32x |  |
| bintrees | 4,351,239,877 | 4,313,426,384 | 11,630,513,653 | 0.37x | 0.37x |  |
| bytesstr | 349,643,423 | 259,442,744 | 103,926,345 | 3.36x | 2.50x |  |
| fib | 3,200,255,609 | 2,342,472,758 | 2,780,168,191 | 1.15x | 0.84x |  |
| html | 1,578,539,542 | 1,388,947,781 | 1,521,579,763 | 1.04x | 0.91x |  |
| html_hand | 1,201,367,117 | 989,088,618 | n/a | n/a | n/a |  |
| http_parse | 1,507,220,019 | 1,363,868,352 | n/a | n/a | n/a |  |
| mapfreq | 1,014,961,993 | 996,989,683 | 682,002,064 | 1.49x | 1.46x |  |
| mutres | 2,470,218,148 | 2,030,196,750 | 267,649,004 | 9.23x | 7.59x |  |
| nbody | 464,253,292 | 768,199,283 | 386,176,091 | 1.20x | 1.99x |  |
| pqueue | 1,383,384,665 | 1,325,196,257 | 359,470,959 | 3.85x | 3.69x |  |
| qsort_func | 1,317,511,061 | 1,279,283,531 | 1,064,640,757 | 1.24x | 1.20x |  |
| qsort_inplace | 622,537,200 | 521,084,162 | 275,674,911 | 2.26x | 1.89x |  |
| sieve | 390,345,902 | 451,732,640 | 161,705,202 | 2.41x | 2.79x |  |
| sortedmap | 1,335,062,466 | 1,343,622,284 | n/a | n/a | n/a |  |
| streams | 1,173,823,143 | 1,173,803,280 | n/a | n/a | n/a |  |
| strings | 653,658,323 | 580,559,558 | 734,241,667 | 0.89x | 0.79x |  |
| tasks | n/a | n/a | n/a | n/a | n/a | llvm skipped: multi-threaded (20,000 tasks, channels): valgrind serialises threads, so the count would include scheduler waits; orin skipped: multi-threaded (20,000 tasks, channels): valgrind serialises threads, so the count would include scheduler waits |
| url | 4,584,662,960 | 4,368,675,859 | n/a | n/a | n/a |  |
| wordfreq | 755,666,681 | 708,712,510 | 860,830,812 | 0.88x | 0.82x |  |

### Parallel speedup (std:task; worker threads = first argument of the program)

| benchmark | threads | wall s (min-max) | CPU s (user+sys) | speedup | efficiency | CPU vs 1 thread | output |
|---|---:|---:|---:|---:|---:|---:|---|
| parallel_collatz | 1 | 0.421 (0.420-0.421) | 0.421 | 1.00x | 100 % | 1.00x | same |
| parallel_collatz | 2 | 0.249 (0.248-0.263) | 0.449 | 1.69x | 85 % | 1.07x | same |
| parallel_collatz | 4 | 0.163 (0.162-0.164) | 0.544 | 2.59x | 65 % | 1.29x | same |
| streams_parallel | 1 | 0.421 (0.412-0.442) | 0.412 | 1.00x | 100 % | 1.00x | same |
| streams_parallel | 2 | 0.218 (0.217-0.220) | 0.414 | 1.94x | 97 % | 1.01x | same |
| streams_parallel | 4 | 0.137 (0.136-0.137) | 0.483 | 3.08x | 77 % | 1.17x | same |

Speedup = wall(1 thread) / wall(n); efficiency = speedup / n. CPU time that grows with n is overhead or oversubscription (more threads than free cores).

### Self-compile (orin2 compiles compiler/main.or)

| wall s (min-max) | CPU s | peak RSS MiB | instructions | output identical to stage2.c |
|---:|---:|---:|---:|---|
| 2.304 (2.291-2.389) | 3.951 | 395.4 | 28,542,603,064 | yes |


## All runs

| date | commit | ref | self-compile instructions | self-compile wall s | file |
|---|---|---|---:|---:|---|
| 2026-11-05T12:03:31Z | `7635a6de4b` | main | 28,542,603,064 | 2.304 | [json](history/2026-11-05-7635a6de4ba0.json) |
| 2026-11-04T12:01:20Z | `7635a6de4b` | main | 28,542,780,461 | 2.352 | [json](history/2026-11-04-7635a6de4ba0.json) |
| 2026-11-03T11:46:50Z | `7635a6de4b` | main | 28,542,833,519 | 1.976 | [json](history/2026-11-03-7635a6de4ba0.json) |
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
