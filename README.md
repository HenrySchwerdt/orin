# Orin benchmark history

Written by `.github/workflows/bench.yml` (nightly and manual runs on `main`); one JSON file per run in [`history/`](history/), charts rendered by `tooling/benchmarks` (`bench-report render`, no external services). The same data as a stand-alone page: [`report.html`](report.html). Metrics and methodology: `docs/benchmarks.md` on `main`. Do not edit this branch by hand.

27 runs, 2026-10-14 to 2026-11-10. Latest: [`7635a6de4b`](https://github.com/HenrySchwerdt/orin/commit/7635a6de4ba00d5f68f1c6355860428eaad22201).

Instruction counts are the regression metric: they are deterministic for single-threaded programs, while wall time on a shared runner moves by 10-25 % between identical binaries.

![Orin to C wall-time ratio per benchmark over time](charts/ratio_wall.svg)

![Orin to C executed-instruction ratio per benchmark over time](charts/ratio_instructions.svg)

![Self-compile instructions and wall time over time](charts/selfcompile.svg)

![Parallel speedup by worker threads](charts/parallel.svg)

## Latest run


Commit `7635a6de4b` (main), 2026-11-10T12:19:35Z. Machine: AMD EPYC 9V74 80-Core Processor, 4 cores, 15.6 GiB, Linux-7.0.0-1019-azure-x86_64-with-glibc2.43. Runs per cell: 5 (median after one warm-up).

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
| appends | 0.008 (0.007-0.008) | 0.006 (0.006-0.007) | 0.004 (0.004-0.005) | 0.010 (0.007-0.011) | 0.072 (0.059-0.109) | 0.003 (0.003-0.004) |
| bintrees | 0.333 (0.332-0.334) | 0.319 (0.316-0.334) | 0.804 (0.799-0.808) | 0.957 (0.954-0.963) | 0.275 (0.271-0.278) | 0.959 (0.954-0.975) |
| bytesstr | 0.032 (0.032-0.033) | 0.028 (0.028-0.028) | 0.018 (0.018-0.018) | 0.009 (0.007-0.011) | 0.080 (0.076-0.084) | 0.032 (0.031-0.033) |
| fib | 0.216 (0.216-0.216) | 0.272 (0.272-0.272) | 0.134 (0.134-0.134) | 0.515 (0.512-0.521) | 0.320 (0.312-0.323) | 0.272 (0.271-0.272) |
| html | 0.125 (0.125-0.127) | 0.103 (0.102-0.104) | 0.113 (0.113-0.116) | 0.183 (0.175-0.191) | n/a | n/a |
| html_hand | 0.104 (0.103-0.104) | 0.081 (0.078-0.082) | n/a | n/a | n/a | n/a |
| http_parse | 0.093 (0.093-0.094) | 0.081 (0.081-0.083) | n/a | n/a | n/a | n/a |
| mapfreq | 0.121 (0.120-0.366) | 0.120 (0.119-0.123) | 0.059 (0.059-0.060) | 0.088 (0.088-0.090) | n/a | n/a |
| mutres | 0.155 (0.144-0.166) | 0.117 (0.116-0.117) | 0.032 (0.032-0.032) | 0.036 (0.036-0.037) | 0.074 (0.068-0.076) | 0.032 (0.032-0.034) |
| nbody | 0.055 (0.055-0.055) | 0.064 (0.064-0.064) | 0.064 (0.064-0.064) | 0.072 (0.070-0.073) | n/a | n/a |
| pqueue | 0.127 (0.125-0.130) | 0.106 (0.104-0.110) | 0.061 (0.061-0.061) | 0.164 (0.162-0.166) | 0.218 (0.211-0.220) | 0.077 (0.076-0.099) |
| qsort_func | 0.178 (0.177-0.178) | 0.183 (0.182-0.183) | 0.162 (0.162-0.163) | 0.319 (0.312-0.322) | n/a | n/a |
| qsort_inplace | 0.105 (0.097-0.110) | 0.107 (0.103-0.108) | 0.075 (0.075-0.076) | 0.104 (0.101-0.107) | n/a | n/a |
| sieve | 0.108 (0.106-0.108) | 0.109 (0.106-0.111) | 0.095 (0.094-0.098) | 0.224 (0.209-0.234) | 0.152 (0.148-0.157) | 0.102 (0.101-0.105) |
| sortedmap | 0.205 (0.203-0.206) | 0.213 (0.212-0.214) | n/a | n/a | n/a | n/a |
| streams | 0.100 (0.100-0.100) | 0.099 (0.098-0.099) | n/a | n/a | n/a | n/a |
| strings | 0.065 (0.064-0.065) | 0.065 (0.064-0.065) | 0.056 (0.055-0.056) | 0.063 (0.053-0.069) | 0.193 (0.189-0.200) | 0.025 (0.025-0.026) |
| tasks | 3.344 (3.260-3.359) | 3.238 (3.211-3.264) | n/a | n/a | n/a | n/a |
| url | 0.296 (0.294-0.306) | 0.257 (0.255-0.265) | n/a | n/a | n/a | n/a |
| wordfreq | 0.097 (0.097-0.098) | 0.095 (0.094-0.095) | 0.081 (0.080-0.081) | 0.094 (0.094-0.095) | n/a | n/a |

### Ratio to C (wall-time median; lower is better, 1.00x = as fast as C)

| benchmark | Orin C/C | Orin LLVM/C | Go/C | Java/C | Rust/C |
|---|---:|---:|---:|---:|---:|
| appends | 1.80x | 1.49x | 2.39x | 17.22x | 0.82x |
| bintrees | 0.41x | 0.40x | 1.19x | 0.34x | 1.19x |
| bytesstr | 1.78x | 1.56x | 0.49x | 4.41x | 1.76x |
| fib | 1.61x | 2.04x | 3.85x | 2.39x | 2.03x |
| html | 1.11x | 0.91x | 1.62x | n/a | n/a |
| html_hand | n/a | n/a | n/a | n/a | n/a |
| http_parse | n/a | n/a | n/a | n/a | n/a |
| mapfreq | 2.03x | 2.02x | 1.49x | n/a | n/a |
| mutres | 4.86x | 3.66x | 1.15x | 2.32x | 1.01x |
| nbody | 0.85x | 1.00x | 1.12x | n/a | n/a |
| pqueue | 2.09x | 1.74x | 2.69x | 3.59x | 1.26x |
| qsort_func | 1.09x | 1.13x | 1.97x | n/a | n/a |
| qsort_inplace | 1.40x | 1.43x | 1.38x | n/a | n/a |
| sieve | 1.14x | 1.15x | 2.37x | 1.60x | 1.08x |
| sortedmap | n/a | n/a | n/a | n/a | n/a |
| streams | n/a | n/a | n/a | n/a | n/a |
| strings | 1.16x | 1.16x | 1.13x | 3.47x | 0.46x |
| tasks | n/a | n/a | n/a | n/a | n/a |
| url | n/a | n/a | n/a | n/a | n/a |
| wordfreq | 1.20x | 1.18x | 1.17x | n/a | n/a |

### CPU time (user + sys, median s) and peak RSS (MiB)

| benchmark | orin CPU | llvm CPU | c CPU | go CPU | java CPU | rust CPU | orin RSS | llvm RSS | c RSS | go RSS | java RSS | rust RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| appends | 0.007 | 0.006 | 0.004 | 0.014 | 0.087 | 0.003 | 4.8 | 5.0 | 4.8 | 7.7 | 48.2 | 5.2 |
| bintrees | 0.332 | 0.319 | 0.804 | 2.034 | 0.320 | 0.958 | 17.6 | 17.8 | 9.6 | 12.2 | 301.2 | 10.0 |
| bytesstr | 0.032 | 0.028 | 0.018 | 0.014 | 0.092 | 0.032 | 11.7 | 11.9 | 11.6 | 7.3 | 103.2 | 5.0 |
| fib | 0.215 | 0.272 | 0.133 | 0.516 | 0.332 | 0.271 | 1.6 | 1.8 | 1.5 | 1.6 | 38.8 | 2.0 |
| html | 0.125 | 0.102 | 0.113 | 0.243 | n/a | n/a | 4.0 | 4.1 | 2.1 | 7.9 | n/a | n/a |
| html_hand | 0.103 | 0.081 | n/a | n/a | n/a | n/a | 2.6 | 2.9 | n/a | n/a | n/a | n/a |
| http_parse | 0.093 | 0.081 | n/a | n/a | n/a | n/a | 1.8 | 1.9 | n/a | n/a | n/a | n/a |
| mapfreq | 0.120 | 0.119 | 0.059 | 0.098 | n/a | n/a | 11.2 | 11.4 | 5.0 | 7.3 | n/a | n/a |
| mutres | 0.146 | 0.116 | 0.032 | 0.037 | 0.095 | 0.032 | 1.6 | 1.8 | 1.5 | 1.6 | 39.3 | 2.2 |
| nbody | 0.054 | 0.064 | 0.064 | 0.072 | n/a | n/a | 1.9 | 1.9 | 1.8 | 1.6 | n/a | n/a |
| pqueue | 0.127 | 0.105 | 0.060 | 0.174 | 0.270 | 0.076 | 6.3 | 6.5 | 4.8 | 14.7 | 62.2 | 5.1 |
| qsort_func | 0.177 | 0.182 | 0.162 | 0.390 | n/a | n/a | 36.3 | 36.6 | 22.0 | 39.2 | n/a | n/a |
| qsort_inplace | 0.105 | 0.107 | 0.075 | 0.126 | n/a | n/a | 16.9 | 17.1 | 16.8 | 31.5 | n/a | n/a |
| sieve | 0.107 | 0.109 | 0.094 | 0.337 | 0.171 | 0.102 | 78.0 | 78.2 | 77.7 | 212.7 | 116.2 | 78.4 |
| sortedmap | 0.205 | 0.213 | n/a | n/a | n/a | n/a | 11.2 | 11.4 | n/a | n/a | n/a | n/a |
| streams | 0.099 | 0.098 | n/a | n/a | n/a | n/a | 39.9 | 40.1 | n/a | n/a | n/a | n/a |
| strings | 0.064 | 0.064 | 0.055 | 0.084 | 0.368 | 0.025 | 46.3 | 46.5 | 34.8 | 23.4 | 139.6 | 20.1 |
| tasks | 3.905 | 3.804 | n/a | n/a | n/a | n/a | 14.1 | 14.2 | n/a | n/a | n/a | n/a |
| url | 0.296 | 0.257 | n/a | n/a | n/a | n/a | 6.5 | 6.7 | n/a | n/a | n/a | n/a |
| wordfreq | 0.096 | 0.095 | 0.080 | 0.096 | n/a | n/a | 2.3 | 2.6 | 1.9 | 6.5 | n/a | n/a |

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
| parallel_collatz | 1 | 0.420 (0.420-0.422) | 0.420 | 1.00x | 100 % | 1.00x | same |
| parallel_collatz | 2 | 0.248 (0.248-0.249) | 0.448 | 1.69x | 85 % | 1.07x | same |
| parallel_collatz | 4 | 0.161 (0.161-0.162) | 0.543 | 2.61x | 65 % | 1.29x | same |
| streams_parallel | 1 | 0.412 (0.411-0.413) | 0.412 | 1.00x | 100 % | 1.00x | same |
| streams_parallel | 2 | 0.226 (0.217-0.250) | 0.413 | 1.83x | 91 % | 1.00x | same |
| streams_parallel | 4 | 0.136 (0.136-0.137) | 0.482 | 3.03x | 76 % | 1.17x | same |

Speedup = wall(1 thread) / wall(n); efficiency = speedup / n. CPU time that grows with n is overhead or oversubscription (more threads than free cores).

### Self-compile (orin2 compiles compiler/main.or)

| wall s (min-max) | CPU s | peak RSS MiB | instructions | output identical to stage2.c |
|---:|---:|---:|---:|---|
| 2.345 (2.329-2.394) | 3.956 | 395.4 | 28,542,948,040 | yes |


## All runs

| date | commit | ref | self-compile instructions | self-compile wall s | file |
|---|---|---|---:|---:|---|
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
