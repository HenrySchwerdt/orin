# Orin benchmark history

Written by `.github/workflows/bench.yml` (nightly and manual runs on `main`); one JSON file per run in [`history/`](history/), charts rendered by `tooling/benchmarks` (`bench-report render`, no external services). The same data as a stand-alone page: [`report.html`](report.html). Metrics and methodology: `docs/benchmarks.md` on `main`. Do not edit this branch by hand.

26 runs, 2026-10-14 to 2026-11-09. Latest: [`7635a6de4b`](https://github.com/HenrySchwerdt/orin/commit/7635a6de4ba00d5f68f1c6355860428eaad22201).

Instruction counts are the regression metric: they are deterministic for single-threaded programs, while wall time on a shared runner moves by 10-25 % between identical binaries.

![Orin to C wall-time ratio per benchmark over time](charts/ratio_wall.svg)

![Orin to C executed-instruction ratio per benchmark over time](charts/ratio_instructions.svg)

![Self-compile instructions and wall time over time](charts/selfcompile.svg)

![Parallel speedup by worker threads](charts/parallel.svg)

## Latest run


Commit `7635a6de4b` (main), 2026-11-09T12:46:20Z. Machine: INTEL(R) XEON(R) PLATINUM 8573C, 4 cores, 15.6 GiB, Linux-7.0.0-1019-azure-x86_64-with-glibc2.43. Runs per cell: 5 (median after one warm-up).

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
| appends | 0.007 (0.007-0.008) | 0.006 (0.006-0.006) | 0.004 (0.003-0.004) | 0.010 (0.009-0.010) | 0.067 (0.063-0.072) | 0.003 (0.003-0.003) |
| bintrees | 0.482 (0.478-0.490) | 0.462 (0.461-0.473) | 0.879 (0.869-0.881) | 1.142 (1.139-1.149) | 0.336 (0.333-0.349) | 1.018 (1.016-1.027) |
| bytesstr | 0.039 (0.038-0.039) | 0.035 (0.035-0.036) | 0.035 (0.034-0.037) | 0.009 (0.008-0.012) | 0.101 (0.099-0.105) | 0.031 (0.030-0.031) |
| fib | 0.296 (0.295-0.299) | 0.360 (0.356-0.361) | 0.161 (0.160-0.161) | 0.581 (0.578-0.589) | 0.523 (0.519-0.530) | 0.305 (0.303-0.306) |
| html | 0.154 (0.151-0.155) | 0.123 (0.123-0.125) | 0.145 (0.144-0.146) | 0.256 (0.242-0.285) | n/a | n/a |
| html_hand | 0.132 (0.131-0.133) | 0.096 (0.093-0.097) | n/a | n/a | n/a | n/a |
| http_parse | 0.112 (0.111-0.113) | 0.096 (0.094-0.097) | n/a | n/a | n/a | n/a |
| mapfreq | 0.135 (0.134-0.137) | 0.139 (0.138-0.139) | 0.065 (0.064-0.066) | 0.104 (0.100-0.110) | n/a | n/a |
| mutres | 0.134 (0.133-0.136) | 0.113 (0.111-0.114) | 0.031 (0.029-0.032) | 0.076 (0.075-0.077) | 0.083 (0.079-0.085) | 0.029 (0.028-0.031) |
| nbody | 0.050 (0.049-0.051) | 0.059 (0.058-0.061) | 0.060 (0.060-0.061) | 0.089 (0.089-0.090) | n/a | n/a |
| pqueue | 0.148 (0.147-0.150) | 0.108 (0.105-0.113) | 0.077 (0.076-0.077) | 0.186 (0.185-0.186) | 0.248 (0.243-0.251) | 0.086 (0.085-0.087) |
| qsort_func | 0.222 (0.220-0.224) | 0.227 (0.224-0.229) | 0.194 (0.191-0.195) | 0.373 (0.372-0.379) | n/a | n/a |
| qsort_inplace | 0.124 (0.122-0.125) | 0.119 (0.118-0.120) | 0.096 (0.095-0.098) | 0.110 (0.108-0.118) | n/a | n/a |
| sieve | 0.112 (0.100-0.115) | 0.117 (0.107-0.120) | 0.094 (0.090-0.108) | 0.211 (0.207-0.252) | 0.171 (0.163-0.176) | 0.101 (0.100-0.115) |
| sortedmap | 0.235 (0.235-0.237) | 0.248 (0.248-0.249) | n/a | n/a | n/a | n/a |
| streams | 0.128 (0.124-0.133) | 0.107 (0.096-0.109) | n/a | n/a | n/a | n/a |
| strings | 0.061 (0.061-0.065) | 0.058 (0.057-0.059) | 0.060 (0.058-0.063) | 0.053 (0.051-0.060) | 0.222 (0.217-0.232) | 0.026 (0.025-0.027) |
| tasks | 4.469 (4.429-4.550) | 4.169 (4.102-4.451) | n/a | n/a | n/a | n/a |
| url | 0.347 (0.346-0.349) | 0.351 (0.349-0.353) | n/a | n/a | n/a | n/a |
| wordfreq | 0.107 (0.107-0.107) | 0.105 (0.104-0.106) | 0.097 (0.096-0.098) | 0.111 (0.109-0.112) | n/a | n/a |

### Ratio to C (wall-time median; lower is better, 1.00x = as fast as C)

| benchmark | Orin C/C | Orin LLVM/C | Go/C | Java/C | Rust/C |
|---|---:|---:|---:|---:|---:|
| appends | 1.86x | 1.44x | 2.42x | 16.65x | 0.82x |
| bintrees | 0.55x | 0.53x | 1.30x | 0.38x | 1.16x |
| bytesstr | 1.11x | 1.01x | 0.25x | 2.90x | 0.88x |
| fib | 1.84x | 2.24x | 3.61x | 3.26x | 1.90x |
| html | 1.06x | 0.85x | 1.77x | n/a | n/a |
| html_hand | n/a | n/a | n/a | n/a | n/a |
| http_parse | n/a | n/a | n/a | n/a | n/a |
| mapfreq | 2.07x | 2.12x | 1.58x | n/a | n/a |
| mutres | 4.32x | 3.62x | 2.45x | 2.67x | 0.94x |
| nbody | 0.83x | 0.97x | 1.48x | n/a | n/a |
| pqueue | 1.92x | 1.40x | 2.42x | 3.22x | 1.12x |
| qsort_func | 1.14x | 1.17x | 1.92x | n/a | n/a |
| qsort_inplace | 1.29x | 1.25x | 1.15x | n/a | n/a |
| sieve | 1.19x | 1.24x | 2.23x | 1.81x | 1.07x |
| sortedmap | n/a | n/a | n/a | n/a | n/a |
| streams | n/a | n/a | n/a | n/a | n/a |
| strings | 1.03x | 0.98x | 0.90x | 3.73x | 0.43x |
| tasks | n/a | n/a | n/a | n/a | n/a |
| url | n/a | n/a | n/a | n/a | n/a |
| wordfreq | 1.11x | 1.08x | 1.15x | n/a | n/a |

### CPU time (user + sys, median s) and peak RSS (MiB)

| benchmark | orin CPU | llvm CPU | c CPU | go CPU | java CPU | rust CPU | orin RSS | llvm RSS | c RSS | go RSS | java RSS | rust RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| appends | 0.007 | 0.006 | 0.004 | 0.013 | 0.102 | 0.003 | 4.8 | 5.0 | 4.8 | 9.9 | 48.1 | 5.2 |
| bintrees | 0.482 | 0.462 | 0.879 | 2.511 | 0.391 | 1.017 | 17.6 | 17.8 | 9.6 | 13.3 | 301.2 | 10.1 |
| bytesstr | 0.038 | 0.035 | 0.034 | 0.012 | 0.122 | 0.030 | 11.7 | 11.8 | 11.6 | 6.4 | 104.5 | 5.1 |
| fib | 0.295 | 0.360 | 0.160 | 0.582 | 0.541 | 0.305 | 1.6 | 1.8 | 1.5 | 1.7 | 38.8 | 2.1 |
| html | 0.153 | 0.123 | 0.144 | 0.335 | n/a | n/a | 3.9 | 4.2 | 2.1 | 7.8 | n/a | n/a |
| html_hand | 0.132 | 0.096 | n/a | n/a | n/a | n/a | 2.6 | 2.8 | n/a | n/a | n/a | n/a |
| http_parse | 0.112 | 0.095 | n/a | n/a | n/a | n/a | 1.8 | 2.0 | n/a | n/a | n/a | n/a |
| mapfreq | 0.135 | 0.139 | 0.065 | 0.123 | n/a | n/a | 11.2 | 11.4 | 5.0 | 7.5 | n/a | n/a |
| mutres | 0.134 | 0.112 | 0.031 | 0.076 | 0.114 | 0.028 | 1.6 | 1.8 | 1.5 | 1.8 | 39.2 | 2.1 |
| nbody | 0.050 | 0.058 | 0.060 | 0.089 | n/a | n/a | 1.9 | 1.9 | 1.8 | 1.8 | n/a | n/a |
| pqueue | 0.147 | 0.107 | 0.077 | 0.194 | 0.320 | 0.085 | 6.3 | 6.5 | 4.8 | 14.6 | 62.1 | 5.2 |
| qsort_func | 0.222 | 0.227 | 0.194 | 0.450 | n/a | n/a | 36.4 | 36.6 | 22.0 | 36.4 | n/a | n/a |
| qsort_inplace | 0.123 | 0.119 | 0.095 | 0.124 | n/a | n/a | 17.0 | 17.1 | 16.8 | 24.8 | n/a | n/a |
| sieve | 0.112 | 0.116 | 0.094 | 0.344 | 0.202 | 0.101 | 77.9 | 78.2 | 77.7 | 185.9 | 116.3 | 78.4 |
| sortedmap | 0.235 | 0.248 | n/a | n/a | n/a | n/a | 11.3 | 11.4 | n/a | n/a | n/a | n/a |
| streams | 0.127 | 0.107 | n/a | n/a | n/a | n/a | 39.9 | 40.0 | n/a | n/a | n/a | n/a |
| strings | 0.061 | 0.057 | 0.059 | 0.062 | 0.474 | 0.025 | 46.3 | 46.5 | 34.8 | 21.8 | 139.1 | 20.1 |
| tasks | 4.445 | 4.205 | n/a | n/a | n/a | n/a | 14.1 | 14.4 | n/a | n/a | n/a | n/a |
| url | 0.347 | 0.349 | n/a | n/a | n/a | n/a | 6.6 | 6.7 | n/a | n/a | n/a | n/a |
| wordfreq | 0.106 | 0.104 | 0.096 | 0.113 | n/a | n/a | 2.3 | 2.5 | 1.9 | 6.7 | n/a | n/a |

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
| parallel_collatz | 1 | 0.688 (0.685-0.694) | 0.687 | 1.00x | 100 % | 1.00x | same |
| parallel_collatz | 2 | 0.390 (0.387-0.393) | 0.718 | 1.76x | 88 % | 1.05x | same |
| parallel_collatz | 4 | 0.272 (0.268-0.321) | 0.948 | 2.53x | 63 % | 1.38x | same |
| streams_parallel | 1 | 0.739 (0.735-0.739) | 0.738 | 1.00x | 100 % | 1.00x | same |
| streams_parallel | 2 | 0.386 (0.385-0.387) | 0.749 | 1.91x | 96 % | 1.01x | same |
| streams_parallel | 4 | 0.279 (0.278-0.283) | 1.049 | 2.64x | 66 % | 1.42x | same |

Speedup = wall(1 thread) / wall(n); efficiency = speedup / n. CPU time that grows with n is overhead or oversubscription (more threads than free cores).

### Self-compile (orin2 compiles compiler/main.or)

| wall s (min-max) | CPU s | peak RSS MiB | instructions | output identical to stage2.c |
|---:|---:|---:|---:|---|
| 2.228 (2.213-2.315) | 3.872 | 394.7 | 28,542,360,770 | yes |


## All runs

| date | commit | ref | self-compile instructions | self-compile wall s | file |
|---|---|---|---:|---:|---|
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
