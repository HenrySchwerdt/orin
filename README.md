# Orin benchmark history

Written by `.github/workflows/bench.yml` (nightly and manual runs on `main`); one JSON file per run in [`history/`](history/), charts rendered by `tooling/benchmarks` (`bench-report render`, no external services). The same data as a stand-alone page: [`report.html`](report.html). Metrics and methodology: `docs/benchmarks.md` on `main`. Do not edit this branch by hand.

41 runs, 2026-10-14 to 2026-11-25. Latest: [`7635a6de4b`](https://github.com/HenrySchwerdt/orin/commit/7635a6de4ba00d5f68f1c6355860428eaad22201).

Instruction counts are the regression metric: they are deterministic for single-threaded programs, while wall time on a shared runner moves by 10-25 % between identical binaries.

![Orin to C wall-time ratio per benchmark over time](charts/ratio_wall.svg)

![Orin to C executed-instruction ratio per benchmark over time](charts/ratio_instructions.svg)

![Self-compile instructions and wall time over time](charts/selfcompile.svg)

![Parallel speedup by worker threads](charts/parallel.svg)

## Latest run


Commit `7635a6de4b` (main), 2026-11-25T14:07:56Z. Machine: AMD EPYC 7763 64-Core Processor, 4 cores, 15.6 GiB, Linux-7.0.0-1020-azure-x86_64-with-glibc2.43. Runs per cell: 5 (median after one warm-up).

<details><summary>Tool versions</summary>

- cc: `cc (Ubuntu 15.2.0-16ubuntu1) 15.2.0`
- clang: `Ubuntu clang version 21.1.8 (6ubuntu1)`
- go: `go version go1.24.13 linux/amd64`
- java: `openjdk version "21.0.13" 2026-10-20 LTS`
- python: `3.14.4`
- rustc: `rustc 1.100.0 (0ef1bc386 2026-11-09)`
- valgrind: `valgrind-3.26.0`

</details>

### Wall time, seconds (median; min-max)

| benchmark | Orin (C backend) | Orin (LLVM backend) | C | Go | Java | Rust |
|---|---:|---:|---:|---:|---:|---:|
| appends | 0.009 (0.009-0.009) | 0.008 (0.008-0.008) | 0.005 (0.005-0.005) | 0.012 (0.012-0.013) | 0.069 (0.067-0.083) | 0.005 (0.005-0.005) |
| bintrees | 0.415 (0.409-0.420) | 0.403 (0.396-0.432) | 1.034 (1.025-1.042) | 1.306 (1.287-1.329) | 0.336 (0.327-0.339) | 1.217 (1.205-1.224) |
| bytesstr | 0.040 (0.039-0.040) | 0.036 (0.035-0.038) | 0.029 (0.028-0.030) | 0.010 (0.010-0.013) | 0.099 (0.098-0.111) | 0.039 (0.038-0.040) |
| fib | 0.263 (0.263-0.264) | 0.314 (0.314-0.315) | 0.177 (0.177-0.186) | 0.598 (0.594-0.638) | 0.430 (0.417-0.434) | 0.314 (0.313-0.314) |
| html | 0.164 (0.162-0.178) | 0.139 (0.137-0.141) | 0.150 (0.150-0.151) | 0.240 (0.234-0.260) | n/a | n/a |
| html_hand | 0.128 (0.128-0.130) | 0.104 (0.099-0.104) | n/a | n/a | n/a | n/a |
| http_parse | 0.126 (0.126-0.128) | 0.113 (0.112-0.113) | n/a | n/a | n/a | n/a |
| mapfreq | 0.157 (0.156-0.160) | 0.158 (0.156-0.159) | 0.078 (0.076-0.078) | 0.117 (0.117-0.119) | n/a | n/a |
| mutres | 0.171 (0.170-0.173) | 0.134 (0.134-0.138) | 0.038 (0.038-0.038) | 0.046 (0.045-0.046) | 0.084 (0.081-0.087) | 0.038 (0.037-0.038) |
| nbody | 0.063 (0.063-0.063) | 0.079 (0.079-0.079) | 0.074 (0.074-0.074) | 0.089 (0.087-0.095) | n/a | n/a |
| pqueue | 0.149 (0.146-0.150) | 0.126 (0.126-0.130) | 0.074 (0.073-0.074) | 0.202 (0.198-0.206) | 0.242 (0.234-0.262) | 0.093 (0.092-0.093) |
| qsort_func | 0.220 (0.217-0.222) | 0.219 (0.218-0.219) | 0.189 (0.187-0.190) | 0.406 (0.388-0.434) | n/a | n/a |
| qsort_inplace | 0.110 (0.109-0.110) | 0.109 (0.109-0.110) | 0.087 (0.086-0.087) | 0.120 (0.114-0.123) | n/a | n/a |
| sieve | 0.117 (0.117-0.122) | 0.130 (0.123-0.142) | 0.111 (0.108-0.114) | 0.340 (0.320-0.390) | 0.180 (0.174-0.185) | 0.118 (0.114-0.120) |
| sortedmap | 0.255 (0.251-0.258) | 0.271 (0.264-0.278) | n/a | n/a | n/a | n/a |
| streams | 0.124 (0.124-0.125) | 0.110 (0.109-0.110) | n/a | n/a | n/a | n/a |
| strings | 0.078 (0.078-0.079) | 0.076 (0.075-0.079) | 0.071 (0.070-0.071) | 0.071 (0.070-0.078) | 0.237 (0.229-0.242) | 0.032 (0.031-0.033) |
| tasks | 4.007 (3.919-4.183) | 3.990 (3.877-4.381) | n/a | n/a | n/a | n/a |
| url | 0.356 (0.354-0.362) | 0.327 (0.324-0.333) | n/a | n/a | n/a | n/a |
| wordfreq | 0.127 (0.126-0.127) | 0.126 (0.125-0.129) | 0.109 (0.107-0.110) | 0.118 (0.116-0.120) | n/a | n/a |

### Ratio to C (wall-time median; lower is better, 1.00x = as fast as C)

| benchmark | Orin C/C | Orin LLVM/C | Go/C | Java/C | Rust/C |
|---|---:|---:|---:|---:|---:|
| appends | 1.91x | 1.59x | 2.43x | 14.04x | 0.94x |
| bintrees | 0.40x | 0.39x | 1.26x | 0.32x | 1.18x |
| bytesstr | 1.39x | 1.25x | 0.36x | 3.46x | 1.34x |
| fib | 1.49x | 1.77x | 3.37x | 2.42x | 1.77x |
| html | 1.10x | 0.93x | 1.60x | n/a | n/a |
| html_hand | n/a | n/a | n/a | n/a | n/a |
| http_parse | n/a | n/a | n/a | n/a | n/a |
| mapfreq | 2.02x | 2.03x | 1.51x | n/a | n/a |
| mutres | 4.51x | 3.55x | 1.20x | 2.21x | 1.00x |
| nbody | 0.86x | 1.07x | 1.21x | n/a | n/a |
| pqueue | 2.02x | 1.72x | 2.75x | 3.29x | 1.26x |
| qsort_func | 1.17x | 1.16x | 2.15x | n/a | n/a |
| qsort_inplace | 1.27x | 1.26x | 1.38x | n/a | n/a |
| sieve | 1.06x | 1.17x | 3.07x | 1.62x | 1.07x |
| sortedmap | n/a | n/a | n/a | n/a | n/a |
| streams | n/a | n/a | n/a | n/a | n/a |
| strings | 1.11x | 1.07x | 1.00x | 3.36x | 0.46x |
| tasks | n/a | n/a | n/a | n/a | n/a |
| url | n/a | n/a | n/a | n/a | n/a |
| wordfreq | 1.16x | 1.16x | 1.08x | n/a | n/a |

### CPU time (user + sys, median s) and peak RSS (MiB)

| benchmark | orin CPU | llvm CPU | c CPU | go CPU | java CPU | rust CPU | orin RSS | llvm RSS | c RSS | go RSS | java RSS | rust RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| appends | 0.009 | 0.008 | 0.005 | 0.016 | 0.105 | 0.004 | 4.8 | 5.0 | 4.8 | 9.8 | 47.9 | 5.2 |
| bintrees | 0.412 | 0.402 | 1.034 | 2.806 | 0.394 | 1.217 | 17.6 | 17.8 | 9.6 | 11.9 | 301.1 | 10.0 |
| bytesstr | 0.040 | 0.035 | 0.028 | 0.015 | 0.122 | 0.038 | 11.6 | 11.8 | 11.6 | 6.5 | 103.3 | 5.1 |
| fib | 0.263 | 0.314 | 0.177 | 0.600 | 0.441 | 0.313 | 1.6 | 1.8 | 1.5 | 1.6 | 38.8 | 2.1 |
| html | 0.164 | 0.139 | 0.150 | 0.320 | n/a | n/a | 4.0 | 4.1 | 2.1 | 7.6 | n/a | n/a |
| html_hand | 0.128 | 0.103 | n/a | n/a | n/a | n/a | 2.7 | 2.9 | n/a | n/a | n/a | n/a |
| http_parse | 0.126 | 0.112 | n/a | n/a | n/a | n/a | 1.8 | 1.9 | n/a | n/a | n/a | n/a |
| mapfreq | 0.156 | 0.157 | 0.076 | 0.133 | n/a | n/a | 11.2 | 11.4 | 5.0 | 7.7 | n/a | n/a |
| mutres | 0.171 | 0.134 | 0.038 | 0.046 | 0.120 | 0.038 | 1.6 | 1.8 | 1.5 | 1.7 | 39.1 | 2.1 |
| nbody | 0.063 | 0.078 | 0.073 | 0.090 | n/a | n/a | 1.8 | 1.9 | 1.8 | 1.8 | n/a | n/a |
| pqueue | 0.148 | 0.126 | 0.073 | 0.216 | 0.320 | 0.092 | 6.3 | 6.5 | 4.8 | 14.6 | 62.2 | 5.2 |
| qsort_func | 0.220 | 0.219 | 0.189 | 0.515 | n/a | n/a | 36.4 | 36.6 | 22.0 | 39.1 | n/a | n/a |
| qsort_inplace | 0.110 | 0.109 | 0.086 | 0.153 | n/a | n/a | 16.9 | 17.1 | 16.8 | 31.1 | n/a | n/a |
| sieve | 0.117 | 0.129 | 0.108 | 0.549 | 0.204 | 0.118 | 77.9 | 78.2 | 77.7 | 255.2 | 116.0 | 78.4 |
| sortedmap | 0.254 | 0.271 | n/a | n/a | n/a | n/a | 11.2 | 11.4 | n/a | n/a | n/a | n/a |
| streams | 0.124 | 0.110 | n/a | n/a | n/a | n/a | 39.9 | 40.1 | n/a | n/a | n/a | n/a |
| strings | 0.078 | 0.075 | 0.070 | 0.089 | 0.454 | 0.032 | 46.3 | 46.4 | 34.8 | 21.7 | 139.5 | 20.1 |
| tasks | 4.747 | 4.707 | n/a | n/a | n/a | n/a | 14.1 | 14.3 | n/a | n/a | n/a | n/a |
| url | 0.355 | 0.326 | n/a | n/a | n/a | n/a | 6.5 | 6.8 | n/a | n/a | n/a | n/a |
| wordfreq | 0.126 | 0.126 | 0.109 | 0.121 | n/a | n/a | 2.3 | 2.5 | 1.9 | 6.6 | n/a | n/a |

### Executed instructions (valgrind; the regression metric)

| benchmark | Orin C | Orin LLVM | C | Orin C/C | Orin LLVM/C | note |
|---|---:|---:|---:|---:|---:|---|
| appends | 60,396,257 | 43,975,557 | 18,927,373 | 3.19x | 2.32x |  |
| bintrees | 4,351,239,711 | 4,313,425,955 | 11,630,513,487 | 0.37x | 0.37x |  |
| bytesstr | 349,643,257 | 259,442,315 | 103,926,179 | 3.36x | 2.50x |  |
| fib | 3,200,255,443 | 2,342,472,329 | 2,780,168,025 | 1.15x | 0.84x |  |
| html | 1,578,539,387 | 1,388,947,363 | 1,521,579,597 | 1.04x | 0.91x |  |
| html_hand | 1,201,366,940 | 989,088,178 | n/a | n/a | n/a |  |
| http_parse | 1,507,219,853 | 1,363,867,923 | n/a | n/a | n/a |  |
| mapfreq | 1,014,961,827 | 996,989,254 | 682,001,909 | 1.49x | 1.46x |  |
| mutres | 2,470,217,982 | 2,030,196,321 | 267,648,838 | 9.23x | 7.59x |  |
| nbody | 464,252,863 | 768,198,854 | 386,175,662 | 1.20x | 1.99x |  |
| pqueue | 1,383,384,499 | 1,325,195,828 | 359,470,793 | 3.85x | 3.69x |  |
| qsort_func | 1,317,510,895 | 1,279,283,102 | 1,064,640,591 | 1.24x | 1.20x |  |
| qsort_inplace | 622,537,034 | 521,083,733 | 275,674,745 | 2.26x | 1.89x |  |
| sieve | 390,345,736 | 451,732,211 | 161,705,036 | 2.41x | 2.79x |  |
| sortedmap | 1,335,062,289 | 1,343,621,844 | n/a | n/a | n/a |  |
| streams | 1,173,822,977 | 1,173,802,851 | n/a | n/a | n/a |  |
| strings | 653,658,157 | 580,559,129 | 734,241,512 | 0.89x | 0.79x |  |
| tasks | n/a | n/a | n/a | n/a | n/a | llvm skipped: multi-threaded (20,000 tasks, channels): valgrind serialises threads, so the count would include scheduler waits; orin skipped: multi-threaded (20,000 tasks, channels): valgrind serialises threads, so the count would include scheduler waits |
| url | 4,584,662,794 | 4,368,675,430 | n/a | n/a | n/a |  |
| wordfreq | 755,666,515 | 708,712,081 | 860,830,646 | 0.88x | 0.82x |  |

### Parallel speedup (std:task; worker threads = first argument of the program)

| benchmark | threads | wall s (min-max) | CPU s (user+sys) | speedup | efficiency | CPU vs 1 thread | output |
|---|---:|---:|---:|---:|---:|---:|---|
| parallel_collatz | 1 | 0.495 (0.495-0.496) | 0.495 | 1.00x | 100 % | 1.00x | same |
| parallel_collatz | 2 | 0.293 (0.292-0.294) | 0.528 | 1.69x | 85 % | 1.07x | same |
| parallel_collatz | 4 | 0.192 (0.192-0.193) | 0.644 | 2.58x | 64 % | 1.30x | same |
| streams_parallel | 1 | 0.490 (0.487-0.491) | 0.490 | 1.00x | 100 % | 1.00x | same |
| streams_parallel | 2 | 0.259 (0.258-0.270) | 0.492 | 1.89x | 95 % | 1.01x | same |
| streams_parallel | 4 | 0.164 (0.164-0.169) | 0.582 | 2.98x | 75 % | 1.19x | same |

Speedup = wall(1 thread) / wall(n); efficiency = speedup / n. CPU time that grows with n is overhead or oversubscription (more threads than free cores).

### Self-compile (orin2 compiles compiler/main.or)

| wall s (min-max) | CPU s | peak RSS MiB | instructions | output identical to stage2.c |
|---:|---:|---:|---:|---|
| 2.634 (2.619-2.714) | 4.751 | 395.3 | 28,542,896,819 | yes |


## All runs

| date | commit | ref | self-compile instructions | self-compile wall s | file |
|---|---|---|---:|---:|---|
| 2026-11-25T14:07:56Z | `7635a6de4b` | main | 28,542,896,819 | 2.634 | [json](history/2026-11-25-7635a6de4ba0.json) |
| 2026-11-24T14:46:25Z | `7635a6de4b` | main | 28,543,458,173 | 2.596 | [json](history/2026-11-24-7635a6de4ba0.json) |
| 2026-11-23T14:16:00Z | `7635a6de4b` | main | 28,541,497,326 | 2.347 | [json](history/2026-11-23-7635a6de4ba0.json) |
| 2026-11-22T12:32:41Z | `7635a6de4b` | main | 28,542,696,623 | 2.347 | [json](history/2026-11-22-7635a6de4ba0.json) |
| 2026-11-21T12:19:24Z | `7635a6de4b` | main | 28,542,569,621 | 2.450 | [json](history/2026-11-21-7635a6de4ba0.json) |
| 2026-11-20T12:44:53Z | `7635a6de4b` | main | 28,541,523,709 | 2.611 | [json](history/2026-11-20-7635a6de4ba0.json) |
| 2026-11-18T12:53:40Z | `7635a6de4b` | main | 28,542,480,299 | 2.742 | [json](history/2026-11-18-7635a6de4ba0.json) |
| 2026-11-17T12:57:26Z | `7635a6de4b` | main | 28,543,095,342 | 2.282 | [json](history/2026-11-17-7635a6de4ba0.json) |
| 2026-11-16T12:34:51Z | `7635a6de4b` | main | 28,541,439,702 | 1.930 | [json](history/2026-11-16-7635a6de4ba0.json) |
| 2026-11-15T11:54:27Z | `7635a6de4b` | main | 28,542,663,271 | 1.858 | [json](history/2026-11-15-7635a6de4ba0.json) |
| 2026-11-14T11:29:07Z | `7635a6de4b` | main | 28,541,943,893 | 2.378 | [json](history/2026-11-14-7635a6de4ba0.json) |
| 2026-11-13T12:02:42Z | `7635a6de4b` | main | 28,542,382,986 | 2.218 | [json](history/2026-11-13-7635a6de4ba0.json) |
| 2026-11-12T12:22:16Z | `7635a6de4b` | main | 28,542,960,948 | 2.473 | [json](history/2026-11-12-7635a6de4ba0.json) |
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
