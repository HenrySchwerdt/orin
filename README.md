# Orin benchmark history

Written by `.github/workflows/bench.yml` (nightly and manual runs on `main`); one JSON file per run in [`history/`](history/), charts rendered by `tooling/benchmarks` (`bench-report render`, no external services). The same data as a stand-alone page: [`report.html`](report.html). Metrics and methodology: `docs/benchmarks.md` on `main`. Do not edit this branch by hand.

28 runs, 2026-10-14 to 2026-11-11. Latest: [`7635a6de4b`](https://github.com/HenrySchwerdt/orin/commit/7635a6de4ba00d5f68f1c6355860428eaad22201).

Instruction counts are the regression metric: they are deterministic for single-threaded programs, while wall time on a shared runner moves by 10-25 % between identical binaries.

![Orin to C wall-time ratio per benchmark over time](charts/ratio_wall.svg)

![Orin to C executed-instruction ratio per benchmark over time](charts/ratio_instructions.svg)

![Self-compile instructions and wall time over time](charts/selfcompile.svg)

![Parallel speedup by worker threads](charts/parallel.svg)

## Latest run


Commit `7635a6de4b` (main), 2026-11-11T11:53:47Z. Machine: AMD EPYC 9V74 80-Core Processor, 4 cores, 15.6 GiB, Linux-7.0.0-1019-azure-x86_64-with-glibc2.43. Runs per cell: 5 (median after one warm-up).

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
| appends | 0.008 (0.008-0.116) | 0.006 (0.006-0.007) | 0.004 (0.004-0.004) | 0.010 (0.008-0.012) | 0.060 (0.055-0.176) | 0.003 (0.003-0.004) |
| bintrees | 0.337 (0.333-0.338) | 0.323 (0.321-0.326) | 0.807 (0.806-0.831) | 0.967 (0.961-0.970) | 0.276 (0.273-0.283) | 0.964 (0.958-0.972) |
| bytesstr | 0.033 (0.033-0.037) | 0.029 (0.028-0.029) | 0.019 (0.019-0.019) | 0.009 (0.007-0.010) | 0.079 (0.079-0.091) | 0.033 (0.033-0.223) |
| fib | 0.216 (0.216-0.216) | 0.290 (0.273-0.304) | 0.136 (0.134-0.136) | 0.517 (0.508-0.522) | 0.321 (0.314-0.324) | 0.271 (0.271-0.273) |
| html | 0.126 (0.125-0.127) | 0.106 (0.103-0.112) | 0.113 (0.113-0.113) | 0.182 (0.172-0.190) | n/a | n/a |
| html_hand | 0.104 (0.104-0.105) | 0.082 (0.081-0.082) | n/a | n/a | n/a | n/a |
| http_parse | 0.094 (0.093-0.094) | 0.081 (0.081-0.081) | n/a | n/a | n/a | n/a |
| mapfreq | 0.121 (0.121-0.123) | 0.121 (0.121-0.128) | 0.061 (0.059-0.062) | 0.089 (0.088-0.089) | n/a | n/a |
| mutres | 0.144 (0.144-0.146) | 0.116 (0.116-0.118) | 0.032 (0.032-0.032) | 0.036 (0.036-0.036) | 0.068 (0.068-0.072) | 0.033 (0.032-0.034) |
| nbody | 0.055 (0.054-0.055) | 0.064 (0.064-0.064) | 0.064 (0.064-0.064) | 0.072 (0.071-0.072) | n/a | n/a |
| pqueue | 0.127 (0.125-0.128) | 0.105 (0.104-0.133) | 0.061 (0.061-0.239) | 0.162 (0.161-0.167) | 0.206 (0.198-0.216) | 0.075 (0.075-0.077) |
| qsort_func | 0.178 (0.176-0.202) | 0.182 (0.181-0.183) | 0.162 (0.161-0.162) | 0.324 (0.310-0.330) | n/a | n/a |
| qsort_inplace | 0.100 (0.098-0.103) | 0.105 (0.104-0.108) | 0.076 (0.075-0.076) | 0.091 (0.090-0.100) | n/a | n/a |
| sieve | 0.114 (0.108-0.124) | 0.109 (0.106-0.111) | 0.099 (0.094-0.100) | 0.248 (0.190-0.260) | 0.151 (0.148-0.151) | 0.106 (0.100-0.109) |
| sortedmap | 0.208 (0.207-0.217) | 0.217 (0.214-0.228) | n/a | n/a | n/a | n/a |
| streams | 0.100 (0.099-0.101) | 0.098 (0.097-0.098) | n/a | n/a | n/a | n/a |
| strings | 0.064 (0.064-0.065) | 0.064 (0.063-0.065) | 0.055 (0.055-0.056) | 0.057 (0.050-0.063) | 0.191 (0.188-0.201) | 0.025 (0.025-0.025) |
| tasks | 3.334 (3.308-3.347) | 3.253 (3.171-3.359) | n/a | n/a | n/a | n/a |
| url | 0.299 (0.290-0.302) | 0.260 (0.257-0.265) | n/a | n/a | n/a | n/a |
| wordfreq | 0.098 (0.097-0.099) | 0.095 (0.095-0.097) | 0.091 (0.081-0.099) | 0.095 (0.094-0.163) | n/a | n/a |

### Ratio to C (wall-time median; lower is better, 1.00x = as fast as C)

| benchmark | Orin C/C | Orin LLVM/C | Go/C | Java/C | Rust/C |
|---|---:|---:|---:|---:|---:|
| appends | 1.84x | 1.49x | 2.51x | 14.44x | 0.83x |
| bintrees | 0.42x | 0.40x | 1.20x | 0.34x | 1.19x |
| bytesstr | 1.77x | 1.55x | 0.50x | 4.28x | 1.80x |
| fib | 1.59x | 2.14x | 3.82x | 2.37x | 2.00x |
| html | 1.11x | 0.94x | 1.61x | n/a | n/a |
| html_hand | n/a | n/a | n/a | n/a | n/a |
| http_parse | n/a | n/a | n/a | n/a | n/a |
| mapfreq | 2.01x | 2.00x | 1.46x | n/a | n/a |
| mutres | 4.53x | 3.66x | 1.15x | 2.15x | 1.05x |
| nbody | 0.85x | 1.00x | 1.12x | n/a | n/a |
| pqueue | 2.08x | 1.72x | 2.66x | 3.37x | 1.23x |
| qsort_func | 1.10x | 1.13x | 2.01x | n/a | n/a |
| qsort_inplace | 1.32x | 1.39x | 1.20x | n/a | n/a |
| sieve | 1.15x | 1.10x | 2.51x | 1.52x | 1.07x |
| sortedmap | n/a | n/a | n/a | n/a | n/a |
| streams | n/a | n/a | n/a | n/a | n/a |
| strings | 1.16x | 1.16x | 1.03x | 3.46x | 0.45x |
| tasks | n/a | n/a | n/a | n/a | n/a |
| url | n/a | n/a | n/a | n/a | n/a |
| wordfreq | 1.08x | 1.05x | 1.05x | n/a | n/a |

### CPU time (user + sys, median s) and peak RSS (MiB)

| benchmark | orin CPU | llvm CPU | c CPU | go CPU | java CPU | rust CPU | orin RSS | llvm RSS | c RSS | go RSS | java RSS | rust RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| appends | 0.007 | 0.006 | 0.004 | 0.014 | 0.089 | 0.003 | 4.8 | 5.0 | 4.8 | 9.7 | 47.9 | 5.2 |
| bintrees | 0.336 | 0.322 | 0.807 | 2.045 | 0.319 | 0.964 | 17.6 | 17.7 | 9.6 | 12.1 | 301.3 | 10.1 |
| bytesstr | 0.033 | 0.028 | 0.018 | 0.014 | 0.094 | 0.033 | 11.7 | 11.9 | 11.6 | 7.0 | 103.3 | 5.1 |
| fib | 0.215 | 0.274 | 0.133 | 0.519 | 0.332 | 0.271 | 1.6 | 1.8 | 1.5 | 1.7 | 38.8 | 2.1 |
| html | 0.125 | 0.103 | 0.113 | 0.234 | n/a | n/a | 3.9 | 4.1 | 2.1 | 8.0 | n/a | n/a |
| html_hand | 0.104 | 0.081 | n/a | n/a | n/a | n/a | 2.7 | 2.9 | n/a | n/a | n/a | n/a |
| http_parse | 0.093 | 0.080 | n/a | n/a | n/a | n/a | 1.8 | 2.0 | n/a | n/a | n/a | n/a |
| mapfreq | 0.121 | 0.121 | 0.060 | 0.098 | n/a | n/a | 11.2 | 11.3 | 5.0 | 7.7 | n/a | n/a |
| mutres | 0.144 | 0.116 | 0.031 | 0.037 | 0.093 | 0.033 | 1.6 | 1.8 | 1.5 | 1.7 | 39.0 | 2.2 |
| nbody | 0.054 | 0.064 | 0.064 | 0.073 | n/a | n/a | 1.9 | 1.8 | 1.8 | 1.7 | n/a | n/a |
| pqueue | 0.127 | 0.105 | 0.061 | 0.170 | 0.259 | 0.075 | 6.3 | 6.5 | 4.8 | 14.6 | 62.1 | 5.2 |
| qsort_func | 0.177 | 0.182 | 0.161 | 0.405 | n/a | n/a | 36.4 | 36.6 | 22.0 | 38.6 | n/a | n/a |
| qsort_inplace | 0.100 | 0.105 | 0.075 | 0.105 | n/a | n/a | 16.9 | 17.1 | 16.8 | 26.0 | n/a | n/a |
| sieve | 0.111 | 0.108 | 0.098 | 0.368 | 0.169 | 0.105 | 77.9 | 78.1 | 77.7 | 243.2 | 116.2 | 78.5 |
| sortedmap | 0.207 | 0.216 | n/a | n/a | n/a | n/a | 11.2 | 11.4 | n/a | n/a | n/a | n/a |
| streams | 0.099 | 0.097 | n/a | n/a | n/a | n/a | 39.9 | 40.1 | n/a | n/a | n/a | n/a |
| strings | 0.064 | 0.064 | 0.055 | 0.072 | 0.364 | 0.025 | 46.3 | 46.5 | 34.8 | 23.2 | 139.4 | 20.1 |
| tasks | 4.037 | 3.904 | n/a | n/a | n/a | n/a | 14.2 | 14.4 | n/a | n/a | n/a | n/a |
| url | 0.298 | 0.260 | n/a | n/a | n/a | n/a | 6.5 | 6.7 | n/a | n/a | n/a | n/a |
| wordfreq | 0.097 | 0.095 | 0.081 | 0.096 | n/a | n/a | 2.3 | 2.6 | 1.9 | 6.5 | n/a | n/a |

### Executed instructions (valgrind; the regression metric)

| benchmark | Orin C | Orin LLVM | C | Orin C/C | Orin LLVM/C | note |
|---|---:|---:|---:|---:|---:|---|
| appends | 60,396,257 | 43,975,557 | 18,927,362 | 3.19x | 2.32x |  |
| bintrees | 4,351,239,711 | 4,313,425,955 | 11,630,513,487 | 0.37x | 0.37x |  |
| bytesstr | 349,643,257 | 259,442,315 | 103,926,179 | 3.36x | 2.50x |  |
| fib | 3,200,255,443 | 2,342,472,329 | 2,780,168,025 | 1.15x | 0.84x |  |
| html | 1,578,539,376 | 1,388,947,352 | 1,521,579,597 | 1.04x | 0.91x |  |
| html_hand | 1,201,366,951 | 989,088,189 | n/a | n/a | n/a |  |
| http_parse | 1,507,219,853 | 1,363,867,923 | n/a | n/a | n/a |  |
| mapfreq | 1,014,961,827 | 996,989,254 | 682,001,898 | 1.49x | 1.46x |  |
| mutres | 2,470,217,982 | 2,030,196,321 | 267,648,838 | 9.23x | 7.59x |  |
| nbody | 464,252,863 | 768,198,854 | 386,175,662 | 1.20x | 1.99x |  |
| pqueue | 1,383,384,499 | 1,325,195,828 | 359,470,793 | 3.85x | 3.69x |  |
| qsort_func | 1,317,510,895 | 1,279,283,102 | 1,064,640,591 | 1.24x | 1.20x |  |
| qsort_inplace | 622,537,034 | 521,083,733 | 275,674,745 | 2.26x | 1.89x |  |
| sieve | 390,345,736 | 451,732,211 | 161,705,036 | 2.41x | 2.79x |  |
| sortedmap | 1,335,062,300 | 1,343,621,855 | n/a | n/a | n/a |  |
| streams | 1,173,822,977 | 1,173,802,851 | n/a | n/a | n/a |  |
| strings | 653,658,157 | 580,559,129 | 734,241,501 | 0.89x | 0.79x |  |
| tasks | n/a | n/a | n/a | n/a | n/a | llvm skipped: multi-threaded (20,000 tasks, channels): valgrind serialises threads, so the count would include scheduler waits; orin skipped: multi-threaded (20,000 tasks, channels): valgrind serialises threads, so the count would include scheduler waits |
| url | 4,584,662,794 | 4,368,675,430 | n/a | n/a | n/a |  |
| wordfreq | 755,666,515 | 708,712,081 | 860,830,646 | 0.88x | 0.82x |  |

### Parallel speedup (std:task; worker threads = first argument of the program)

| benchmark | threads | wall s (min-max) | CPU s (user+sys) | speedup | efficiency | CPU vs 1 thread | output |
|---|---:|---:|---:|---:|---:|---:|---|
| parallel_collatz | 1 | 0.422 (0.419-0.422) | 0.421 | 1.00x | 100 % | 1.00x | same |
| parallel_collatz | 2 | 0.250 (0.249-0.250) | 0.449 | 1.69x | 84 % | 1.07x | same |
| parallel_collatz | 4 | 0.162 (0.162-0.165) | 0.543 | 2.60x | 65 % | 1.29x | same |
| streams_parallel | 1 | 0.413 (0.411-0.413) | 0.412 | 1.00x | 100 % | 1.00x | same |
| streams_parallel | 2 | 0.217 (0.216-0.217) | 0.413 | 1.90x | 95 % | 1.00x | same |
| streams_parallel | 4 | 0.136 (0.136-0.136) | 0.482 | 3.03x | 76 % | 1.17x | same |

Speedup = wall(1 thread) / wall(n); efficiency = speedup / n. CPU time that grows with n is overhead or oversubscription (more threads than free cores).

### Self-compile (orin2 compiles compiler/main.or)

| wall s (min-max) | CPU s | peak RSS MiB | instructions | output identical to stage2.c |
|---:|---:|---:|---:|---|
| 2.327 (2.279-2.387) | 3.943 | 394.8 | 28,542,808,219 | yes |


## All runs

| date | commit | ref | self-compile instructions | self-compile wall s | file |
|---|---|---|---:|---:|---|
| 2026-11-11T11:53:47Z | `7635a6de4b` | main | 28,542,808,219 | 2.327 | [json](history/2026-11-11-7635a6de4ba0.json) |
| 2026-11-10T12:19:35Z | `7635a6de4b` | main | 28,542,948,040 | 2.345 | [json](history/2026-11-10-7635a6de4ba0.json) |
| 2026-11-09T12:46:20Z | `7635a6de4b` | main | 28,542,360,770 | 2.228 | [json](history/2026-11-09-7635a6de4ba0.json) |
| 2026-11-08T11:13:42Z | `7635a6de4b` | main | 28,542,100,863 | 2.306 | [json](history/2026-11-08-7635a6de4ba0.json) |
| 2026-11-07T11:05:37Z | `7635a6de4b` | main | 28,542,838,708 | 2.349 | [json](history/2026-11-07-7635a6de4ba0.json) |
| 2026-11-06T12:14:12Z | `7635a6de4b` | main | 28,542,494,981 | 2.629 | [json](history/2026-11-06-7635a6de4ba0.json) |
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
