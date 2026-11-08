# Orin benchmark history

Written by `.github/workflows/bench.yml` (nightly and manual runs on `main`); one JSON file per run in [`history/`](history/), charts rendered by `tooling/benchmarks` (`bench-report render`, no external services). The same data as a stand-alone page: [`report.html`](report.html). Metrics and methodology: `docs/benchmarks.md` on `main`. Do not edit this branch by hand.

25 runs, 2026-10-14 to 2026-11-08. Latest: [`7635a6de4b`](https://github.com/HenrySchwerdt/orin/commit/7635a6de4ba00d5f68f1c6355860428eaad22201).

Instruction counts are the regression metric: they are deterministic for single-threaded programs, while wall time on a shared runner moves by 10-25 % between identical binaries.

![Orin to C wall-time ratio per benchmark over time](charts/ratio_wall.svg)

![Orin to C executed-instruction ratio per benchmark over time](charts/ratio_instructions.svg)

![Self-compile instructions and wall time over time](charts/selfcompile.svg)

![Parallel speedup by worker threads](charts/parallel.svg)

## Latest run


Commit `7635a6de4b` (main), 2026-11-08T11:13:42Z. Machine: AMD EPYC 9V74 80-Core Processor, 4 cores, 15.6 GiB, Linux-7.0.0-1019-azure-x86_64-with-glibc2.43. Runs per cell: 5 (median after one warm-up).

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
| appends | 0.008 (0.008-0.008) | 0.006 (0.006-0.007) | 0.004 (0.004-0.004) | 0.010 (0.009-0.011) | 0.066 (0.055-0.077) | 0.003 (0.003-0.005) |
| bintrees | 0.335 (0.335-0.340) | 0.323 (0.322-0.326) | 0.810 (0.803-0.834) | 0.969 (0.967-0.980) | 0.289 (0.276-0.296) | 0.965 (0.955-0.974) |
| bytesstr | 0.032 (0.032-0.074) | 0.027 (0.027-0.028) | 0.017 (0.017-0.018) | 0.009 (0.007-0.010) | 0.083 (0.078-0.094) | 0.033 (0.031-0.033) |
| fib | 0.216 (0.216-0.217) | 0.272 (0.272-0.272) | 0.134 (0.134-0.134) | 0.513 (0.512-0.515) | 0.319 (0.313-0.321) | 0.272 (0.271-0.272) |
| html | 0.125 (0.125-0.128) | 0.102 (0.102-0.104) | 0.113 (0.113-0.113) | 0.180 (0.177-0.206) | n/a | n/a |
| html_hand | 0.104 (0.104-0.104) | 0.081 (0.078-0.082) | n/a | n/a | n/a | n/a |
| http_parse | 0.095 (0.094-0.095) | 0.081 (0.080-0.082) | n/a | n/a | n/a | n/a |
| mapfreq | 0.121 (0.120-0.122) | 0.121 (0.121-0.122) | 0.059 (0.059-0.060) | 0.089 (0.088-0.090) | n/a | n/a |
| mutres | 0.144 (0.144-0.156) | 0.116 (0.116-0.117) | 0.032 (0.032-0.032) | 0.036 (0.036-0.036) | 0.067 (0.066-0.070) | 0.033 (0.032-0.208) |
| nbody | 0.054 (0.054-0.055) | 0.064 (0.064-0.064) | 0.064 (0.064-0.066) | 0.072 (0.069-0.073) | n/a | n/a |
| pqueue | 0.127 (0.124-0.140) | 0.102 (0.102-0.105) | 0.061 (0.061-0.063) | 0.164 (0.160-0.165) | 0.198 (0.196-0.213) | 0.076 (0.076-0.076) |
| qsort_func | 0.177 (0.176-0.179) | 0.181 (0.179-0.182) | 0.162 (0.162-0.164) | 0.323 (0.308-0.342) | n/a | n/a |
| qsort_inplace | 0.099 (0.097-0.201) | 0.107 (0.106-0.108) | 0.075 (0.075-0.075) | 0.098 (0.089-0.111) | n/a | n/a |
| sieve | 0.103 (0.100-0.106) | 0.105 (0.104-0.107) | 0.094 (0.092-0.149) | 0.209 (0.202-0.231) | 0.144 (0.142-0.157) | 0.096 (0.095-0.096) |
| sortedmap | 0.205 (0.204-0.206) | 0.214 (0.212-0.214) | n/a | n/a | n/a | n/a |
| streams | 0.098 (0.097-0.099) | 0.096 (0.096-0.097) | n/a | n/a | n/a | n/a |
| strings | 0.065 (0.064-0.065) | 0.064 (0.064-0.066) | 0.056 (0.055-0.056) | 0.057 (0.051-0.065) | 0.192 (0.186-0.203) | 0.025 (0.024-0.025) |
| tasks | 3.335 (3.280-3.399) | 3.314 (3.305-3.356) | n/a | n/a | n/a | n/a |
| url | 0.291 (0.289-0.296) | 0.260 (0.253-0.265) | n/a | n/a | n/a | n/a |
| wordfreq | 0.097 (0.097-0.097) | 0.095 (0.095-0.095) | 0.080 (0.080-0.081) | 0.094 (0.094-0.094) | n/a | n/a |

### Ratio to C (wall-time median; lower is better, 1.00x = as fast as C)

| benchmark | Orin C/C | Orin LLVM/C | Go/C | Java/C | Rust/C |
|---|---:|---:|---:|---:|---:|
| appends | 1.79x | 1.53x | 2.29x | 15.54x | 0.82x |
| bintrees | 0.41x | 0.40x | 1.20x | 0.36x | 1.19x |
| bytesstr | 1.85x | 1.58x | 0.51x | 4.78x | 1.90x |
| fib | 1.62x | 2.04x | 3.84x | 2.39x | 2.03x |
| html | 1.11x | 0.90x | 1.60x | n/a | n/a |
| html_hand | n/a | n/a | n/a | n/a | n/a |
| http_parse | n/a | n/a | n/a | n/a | n/a |
| mapfreq | 2.05x | 2.05x | 1.52x | n/a | n/a |
| mutres | 4.54x | 3.67x | 1.14x | 2.11x | 1.05x |
| nbody | 0.85x | 1.00x | 1.12x | n/a | n/a |
| pqueue | 2.07x | 1.67x | 2.68x | 3.24x | 1.24x |
| qsort_func | 1.09x | 1.12x | 2.00x | n/a | n/a |
| qsort_inplace | 1.31x | 1.43x | 1.30x | n/a | n/a |
| sieve | 1.10x | 1.12x | 2.23x | 1.53x | 1.02x |
| sortedmap | n/a | n/a | n/a | n/a | n/a |
| streams | n/a | n/a | n/a | n/a | n/a |
| strings | 1.16x | 1.16x | 1.03x | 3.46x | 0.44x |
| tasks | n/a | n/a | n/a | n/a | n/a |
| url | n/a | n/a | n/a | n/a | n/a |
| wordfreq | 1.20x | 1.18x | 1.17x | n/a | n/a |

### CPU time (user + sys, median s) and peak RSS (MiB)

| benchmark | orin CPU | llvm CPU | c CPU | go CPU | java CPU | rust CPU | orin RSS | llvm RSS | c RSS | go RSS | java RSS | rust RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| appends | 0.007 | 0.006 | 0.004 | 0.013 | 0.089 | 0.003 | 4.8 | 5.0 | 4.8 | 8.4 | 48.1 | 5.2 |
| bintrees | 0.335 | 0.323 | 0.809 | 2.060 | 0.321 | 0.965 | 17.6 | 17.8 | 9.6 | 12.2 | 301.3 | 10.1 |
| bytesstr | 0.032 | 0.027 | 0.017 | 0.013 | 0.096 | 0.033 | 11.6 | 11.9 | 11.6 | 7.2 | 103.2 | 5.1 |
| fib | 0.216 | 0.272 | 0.133 | 0.515 | 0.330 | 0.271 | 1.6 | 1.9 | 1.5 | 1.8 | 38.8 | 2.1 |
| html | 0.125 | 0.102 | 0.113 | 0.237 | n/a | n/a | 4.0 | 4.2 | 2.1 | 7.5 | n/a | n/a |
| html_hand | 0.104 | 0.081 | n/a | n/a | n/a | n/a | 2.7 | 2.9 | n/a | n/a | n/a | n/a |
| http_parse | 0.094 | 0.081 | n/a | n/a | n/a | n/a | 1.8 | 1.9 | n/a | n/a | n/a | n/a |
| mapfreq | 0.120 | 0.121 | 0.059 | 0.099 | n/a | n/a | 11.2 | 11.3 | 5.0 | 7.5 | n/a | n/a |
| mutres | 0.144 | 0.116 | 0.031 | 0.037 | 0.091 | 0.033 | 1.6 | 1.8 | 1.5 | 1.8 | 39.0 | 2.1 |
| nbody | 0.054 | 0.064 | 0.064 | 0.072 | n/a | n/a | 1.9 | 1.9 | 1.8 | 1.9 | n/a | n/a |
| pqueue | 0.126 | 0.102 | 0.061 | 0.170 | 0.255 | 0.075 | 6.3 | 6.4 | 4.8 | 15.0 | 62.2 | 5.2 |
| qsort_func | 0.176 | 0.180 | 0.162 | 0.400 | n/a | n/a | 36.4 | 36.6 | 22.0 | 46.0 | n/a | n/a |
| qsort_inplace | 0.097 | 0.107 | 0.075 | 0.120 | n/a | n/a | 17.0 | 17.1 | 16.8 | 31.3 | n/a | n/a |
| sieve | 0.102 | 0.105 | 0.092 | 0.319 | 0.166 | 0.095 | 78.0 | 78.2 | 77.7 | 231.6 | 116.2 | 78.5 |
| sortedmap | 0.205 | 0.214 | n/a | n/a | n/a | n/a | 11.2 | 11.4 | n/a | n/a | n/a | n/a |
| streams | 0.097 | 0.096 | n/a | n/a | n/a | n/a | 39.8 | 40.1 | n/a | n/a | n/a | n/a |
| strings | 0.064 | 0.064 | 0.055 | 0.073 | 0.368 | 0.024 | 46.3 | 46.5 | 34.8 | 23.5 | 139.4 | 20.1 |
| tasks | 4.044 | 3.927 | n/a | n/a | n/a | n/a | 14.1 | 14.2 | n/a | n/a | n/a | n/a |
| url | 0.291 | 0.260 | n/a | n/a | n/a | n/a | 6.5 | 6.7 | n/a | n/a | n/a | n/a |
| wordfreq | 0.096 | 0.095 | 0.080 | 0.095 | n/a | n/a | 2.3 | 2.6 | 1.9 | 6.5 | n/a | n/a |

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
| parallel_collatz | 1 | 0.421 (0.420-0.421) | 0.421 | 1.00x | 100 % | 1.00x | same |
| parallel_collatz | 2 | 0.248 (0.246-0.252) | 0.447 | 1.70x | 85 % | 1.06x | same |
| parallel_collatz | 4 | 0.162 (0.161-0.163) | 0.543 | 2.60x | 65 % | 1.29x | same |
| streams_parallel | 1 | 0.413 (0.412-0.414) | 0.413 | 1.00x | 100 % | 1.00x | same |
| streams_parallel | 2 | 0.216 (0.216-0.217) | 0.413 | 1.91x | 95 % | 1.00x | same |
| streams_parallel | 4 | 0.136 (0.135-0.154) | 0.482 | 3.04x | 76 % | 1.17x | same |

Speedup = wall(1 thread) / wall(n); efficiency = speedup / n. CPU time that grows with n is overhead or oversubscription (more threads than free cores).

### Self-compile (orin2 compiles compiler/main.or)

| wall s (min-max) | CPU s | peak RSS MiB | instructions | output identical to stage2.c |
|---:|---:|---:|---:|---|
| 2.306 (2.285-2.392) | 3.921 | 395.1 | 28,542,100,863 | yes |


## All runs

| date | commit | ref | self-compile instructions | self-compile wall s | file |
|---|---|---|---:|---:|---|
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
