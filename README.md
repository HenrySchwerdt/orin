# Orin benchmark history

Written by `.github/workflows/bench.yml` (nightly and manual runs on `main`); one JSON file per run in [`history/`](history/), charts rendered by `tooling/benchmarks` (`bench-report render`, no external services). The same data as a stand-alone page: [`report.html`](report.html). Metrics and methodology: `docs/benchmarks.md` on `main`. Do not edit this branch by hand.

21 runs, 2026-10-14 to 2026-11-04. Latest: [`7635a6de4b`](https://github.com/HenrySchwerdt/orin/commit/7635a6de4ba00d5f68f1c6355860428eaad22201).

Instruction counts are the regression metric: they are deterministic for single-threaded programs, while wall time on a shared runner moves by 10-25 % between identical binaries.

![Orin to C wall-time ratio per benchmark over time](charts/ratio_wall.svg)

![Orin to C executed-instruction ratio per benchmark over time](charts/ratio_instructions.svg)

![Self-compile instructions and wall time over time](charts/selfcompile.svg)

![Parallel speedup by worker threads](charts/parallel.svg)

## Latest run


Commit `7635a6de4b` (main), 2026-11-04T12:01:20Z. Machine: AMD EPYC 9V45 96-Core Processor, 4 cores, 15.6 GiB, Linux-7.0.0-1017-azure-x86_64-with-glibc2.43. Runs per cell: 5 (median after one warm-up).

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
| appends | 0.006 (0.005-0.006) | 0.004 (0.004-0.004) | 0.004 (0.004-0.019) | 0.008 (0.007-0.010) | 0.061 (0.053-0.061) | 0.003 (0.003-0.005) |
| bintrees | 0.245 (0.242-0.246) | 0.243 (0.240-0.246) | 0.586 (0.582-0.637) | 0.756 (0.742-0.762) | 0.226 (0.218-0.231) | 0.717 (0.693-0.724) |
| bytesstr | 0.025 (0.025-0.026) | 0.022 (0.022-0.023) | 0.017 (0.017-0.018) | 0.006 (0.006-0.010) | 0.081 (0.074-0.089) | 0.031 (0.030-0.031) |
| fib | 0.191 (0.185-0.192) | 0.192 (0.189-0.193) | 0.095 (0.094-0.096) | 0.373 (0.371-0.378) | 0.274 (0.271-0.277) | 0.201 (0.199-0.203) |
| html | 0.109 (0.096-0.112) | 0.075 (0.073-0.076) | 0.089 (0.088-0.090) | 0.142 (0.138-0.156) | n/a | n/a |
| html_hand | 0.090 (0.079-0.113) | 0.056 (0.055-0.056) | n/a | n/a | n/a | n/a |
| http_parse | 0.074 (0.073-0.077) | 0.063 (0.062-0.065) | n/a | n/a | n/a | n/a |
| mapfreq | 0.096 (0.095-0.097) | 0.095 (0.093-0.096) | 0.050 (0.048-0.050) | 0.068 (0.067-0.069) | n/a | n/a |
| mutres | 0.095 (0.094-0.096) | 0.078 (0.077-0.078) | 0.023 (0.022-0.023) | 0.024 (0.023-0.024) | 0.062 (0.058-0.066) | 0.027 (0.027-0.027) |
| nbody | 0.047 (0.043-0.068) | 0.046 (0.045-0.046) | 0.048 (0.048-0.049) | 0.058 (0.058-0.059) | n/a | n/a |
| pqueue | 0.111 (0.103-0.116) | 0.094 (0.085-0.099) | 0.053 (0.052-0.054) | 0.146 (0.138-0.150) | 0.181 (0.174-0.189) | 0.061 (0.059-0.061) |
| qsort_func | 0.154 (0.152-0.155) | 0.152 (0.150-0.155) | 0.141 (0.139-0.163) | 0.261 (0.256-0.276) | n/a | n/a |
| qsort_inplace | 0.087 (0.086-0.088) | 0.085 (0.085-0.085) | 0.075 (0.073-0.078) | 0.088 (0.085-0.090) | n/a | n/a |
| sieve | 0.078 (0.076-0.080) | 0.074 (0.074-0.079) | 0.070 (0.069-0.070) | 0.164 (0.145-0.168) | 0.121 (0.118-0.125) | 0.072 (0.071-0.073) |
| sortedmap | 0.168 (0.166-0.202) | 0.173 (0.170-0.176) | n/a | n/a | n/a | n/a |
| streams | 0.085 (0.083-0.121) | 0.075 (0.075-0.077) | n/a | n/a | n/a | n/a |
| strings | 0.051 (0.051-0.052) | 0.049 (0.048-0.049) | 0.046 (0.045-0.047) | 0.042 (0.041-0.048) | 0.180 (0.179-0.188) | 0.020 (0.020-0.024) |
| tasks | 3.175 (3.074-3.334) | 3.158 (3.088-3.255) | n/a | n/a | n/a | n/a |
| url | 0.210 (0.203-0.215) | 0.182 (0.179-0.194) | n/a | n/a | n/a | n/a |
| wordfreq | 0.078 (0.077-0.079) | 0.075 (0.074-0.076) | 0.064 (0.064-0.064) | 0.080 (0.080-0.081) | n/a | n/a |

### Ratio to C (wall-time median; lower is better, 1.00x = as fast as C)

| benchmark | Orin C/C | Orin LLVM/C | Go/C | Java/C | Rust/C |
|---|---:|---:|---:|---:|---:|
| appends | 1.42x | 1.12x | 1.93x | 15.45x | 0.76x |
| bintrees | 0.42x | 0.42x | 1.29x | 0.39x | 1.22x |
| bytesstr | 1.46x | 1.28x | 0.36x | 4.64x | 1.78x |
| fib | 2.00x | 2.01x | 3.91x | 2.87x | 2.11x |
| html | 1.22x | 0.84x | 1.60x | n/a | n/a |
| html_hand | n/a | n/a | n/a | n/a | n/a |
| http_parse | n/a | n/a | n/a | n/a | n/a |
| mapfreq | 1.94x | 1.92x | 1.36x | n/a | n/a |
| mutres | 4.20x | 3.42x | 1.04x | 2.73x | 1.18x |
| nbody | 0.98x | 0.94x | 1.21x | n/a | n/a |
| pqueue | 2.09x | 1.78x | 2.76x | 3.41x | 1.15x |
| qsort_func | 1.09x | 1.08x | 1.85x | n/a | n/a |
| qsort_inplace | 1.16x | 1.13x | 1.17x | n/a | n/a |
| sieve | 1.13x | 1.07x | 2.36x | 1.74x | 1.03x |
| sortedmap | n/a | n/a | n/a | n/a | n/a |
| streams | n/a | n/a | n/a | n/a | n/a |
| strings | 1.11x | 1.06x | 0.91x | 3.90x | 0.45x |
| tasks | n/a | n/a | n/a | n/a | n/a |
| url | n/a | n/a | n/a | n/a | n/a |
| wordfreq | 1.21x | 1.17x | 1.26x | n/a | n/a |

### CPU time (user + sys, median s) and peak RSS (MiB)

| benchmark | orin CPU | llvm CPU | c CPU | go CPU | java CPU | rust CPU | orin RSS | llvm RSS | c RSS | go RSS | java RSS | rust RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| appends | 0.005 | 0.004 | 0.004 | 0.009 | 0.077 | 0.003 | 4.8 | 5.0 | 4.8 | 8.0 | 48.0 | 5.2 |
| bintrees | 0.245 | 0.243 | 0.586 | 1.613 | 0.267 | 0.716 | 17.7 | 17.8 | 9.6 | 13.2 | 301.3 | 10.1 |
| bytesstr | 0.025 | 0.022 | 0.017 | 0.008 | 0.092 | 0.031 | 11.6 | 11.8 | 11.6 | 6.1 | 104.7 | 5.0 |
| fib | 0.191 | 0.192 | 0.095 | 0.374 | 0.284 | 0.201 | 1.6 | 1.8 | 1.5 | 1.6 | 38.9 | 2.2 |
| html | 0.108 | 0.074 | 0.089 | 0.193 | n/a | n/a | 4.0 | 4.1 | 2.1 | 7.5 | n/a | n/a |
| html_hand | 0.090 | 0.055 | n/a | n/a | n/a | n/a | 2.7 | 2.9 | n/a | n/a | n/a | n/a |
| http_parse | 0.074 | 0.063 | n/a | n/a | n/a | n/a | 1.8 | 1.9 | n/a | n/a | n/a | n/a |
| mapfreq | 0.096 | 0.095 | 0.049 | 0.076 | n/a | n/a | 11.2 | 11.4 | 5.0 | 7.1 | n/a | n/a |
| mutres | 0.095 | 0.077 | 0.022 | 0.024 | 0.080 | 0.026 | 1.6 | 1.8 | 1.5 | 1.8 | 39.1 | 2.1 |
| nbody | 0.044 | 0.045 | 0.048 | 0.059 | n/a | n/a | 1.9 | 1.9 | 1.7 | 1.6 | n/a | n/a |
| pqueue | 0.110 | 0.094 | 0.053 | 0.153 | 0.235 | 0.061 | 6.3 | 6.5 | 4.8 | 15.2 | 62.2 | 5.2 |
| qsort_func | 0.154 | 0.152 | 0.141 | 0.317 | n/a | n/a | 36.3 | 36.5 | 22.0 | 36.9 | n/a | n/a |
| qsort_inplace | 0.086 | 0.085 | 0.075 | 0.099 | n/a | n/a | 17.0 | 17.1 | 16.8 | 26.1 | n/a | n/a |
| sieve | 0.078 | 0.074 | 0.069 | 0.270 | 0.143 | 0.071 | 78.0 | 78.1 | 77.7 | 231.7 | 116.1 | 78.4 |
| sortedmap | 0.168 | 0.173 | n/a | n/a | n/a | n/a | 11.2 | 11.4 | n/a | n/a | n/a | n/a |
| streams | 0.085 | 0.075 | n/a | n/a | n/a | n/a | 39.9 | 40.0 | n/a | n/a | n/a | n/a |
| strings | 0.051 | 0.049 | 0.046 | 0.048 | 0.347 | 0.020 | 46.3 | 46.5 | 34.8 | 21.6 | 139.4 | 20.1 |
| tasks | 3.673 | 3.553 | n/a | n/a | n/a | n/a | 14.1 | 14.4 | n/a | n/a | n/a | n/a |
| url | 0.209 | 0.182 | n/a | n/a | n/a | n/a | 6.6 | 6.8 | n/a | n/a | n/a | n/a |
| wordfreq | 0.077 | 0.075 | 0.064 | 0.082 | n/a | n/a | 2.4 | 2.5 | 1.9 | 6.5 | n/a | n/a |

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
| parallel_collatz | 1 | 0.473 (0.463-0.501) | 0.472 | 1.00x | 100 % | 1.00x | same |
| parallel_collatz | 2 | 0.270 (0.269-0.279) | 0.491 | 1.75x | 87 % | 1.04x | same |
| parallel_collatz | 4 | 0.167 (0.165-0.170) | 0.568 | 2.83x | 71 % | 1.20x | same |
| streams_parallel | 1 | 0.446 (0.422-0.461) | 0.446 | 1.00x | 100 % | 1.00x | same |
| streams_parallel | 2 | 0.236 (0.229-0.238) | 0.452 | 1.89x | 95 % | 1.01x | same |
| streams_parallel | 4 | 0.148 (0.147-0.151) | 0.535 | 3.01x | 75 % | 1.20x | same |

Speedup = wall(1 thread) / wall(n); efficiency = speedup / n. CPU time that grows with n is overhead or oversubscription (more threads than free cores).

### Self-compile (orin2 compiles compiler/main.or)

| wall s (min-max) | CPU s | peak RSS MiB | instructions | output identical to stage2.c |
|---:|---:|---:|---:|---|
| 2.352 (2.310-2.400) | 3.655 | 394.7 | 28,542,780,461 | yes |


## All runs

| date | commit | ref | self-compile instructions | self-compile wall s | file |
|---|---|---|---:|---:|---|
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
