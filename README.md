# Orin benchmark history

Written by `.github/workflows/bench.yml` (nightly and manual runs on `main`); one JSON file per run in [`history/`](history/), charts rendered by `tooling/benchmarks` (`bench-report render`, no external services). The same data as a stand-alone page: [`report.html`](report.html). Metrics and methodology: `docs/benchmarks.md` on `main`. Do not edit this branch by hand.

32 runs, 2026-10-14 to 2026-11-15. Latest: [`7635a6de4b`](https://github.com/HenrySchwerdt/orin/commit/7635a6de4ba00d5f68f1c6355860428eaad22201).

Instruction counts are the regression metric: they are deterministic for single-threaded programs, while wall time on a shared runner moves by 10-25 % between identical binaries.

![Orin to C wall-time ratio per benchmark over time](charts/ratio_wall.svg)

![Orin to C executed-instruction ratio per benchmark over time](charts/ratio_instructions.svg)

![Self-compile instructions and wall time over time](charts/selfcompile.svg)

![Parallel speedup by worker threads](charts/parallel.svg)

## Latest run


Commit `7635a6de4b` (main), 2026-11-15T11:54:27Z. Machine: AMD EPYC 9V45 96-Core Processor, 4 cores, 15.6 GiB, Linux-7.0.0-1019-azure-x86_64-with-glibc2.43. Runs per cell: 5 (median after one warm-up).

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
| appends | 0.005 (0.005-0.005) | 0.004 (0.004-0.004) | 0.003 (0.003-0.003) | 0.006 (0.006-0.006) | 0.055 (0.053-0.058) | 0.003 (0.003-0.006) |
| bintrees | 0.231 (0.229-0.234) | 0.229 (0.226-0.231) | 0.560 (0.547-0.696) | 0.693 (0.685-0.700) | 0.204 (0.202-0.205) | 0.657 (0.647-0.674) |
| bytesstr | 0.023 (0.023-0.023) | 0.019 (0.019-0.020) | 0.014 (0.013-0.014) | 0.006 (0.005-0.007) | 0.068 (0.066-0.073) | 0.027 (0.027-0.027) |
| fib | 0.178 (0.173-0.181) | 0.181 (0.179-0.188) | 0.089 (0.088-0.092) | 0.357 (0.353-0.364) | 0.253 (0.252-0.257) | 0.193 (0.191-0.194) |
| html | 0.087 (0.087-0.088) | 0.070 (0.069-0.070) | 0.081 (0.080-0.081) | 0.127 (0.125-0.139) | n/a | n/a |
| html_hand | 0.074 (0.073-0.074) | 0.051 (0.051-0.051) | n/a | n/a | n/a | n/a |
| http_parse | 0.065 (0.065-0.066) | 0.055 (0.055-0.057) | n/a | n/a | n/a | n/a |
| mapfreq | 0.090 (0.089-0.090) | 0.090 (0.088-0.090) | 0.044 (0.043-0.046) | 0.063 (0.062-0.063) | n/a | n/a |
| mutres | 0.089 (0.088-0.090) | 0.072 (0.072-0.073) | 0.021 (0.021-0.022) | 0.022 (0.022-0.022) | 0.056 (0.054-0.057) | 0.025 (0.025-0.025) |
| nbody | 0.040 (0.040-0.041) | 0.042 (0.042-0.042) | 0.045 (0.045-0.046) | 0.055 (0.054-0.060) | n/a | n/a |
| pqueue | 0.086 (0.086-0.086) | 0.071 (0.070-0.071) | 0.046 (0.046-0.073) | 0.123 (0.119-0.124) | 0.147 (0.145-0.151) | 0.053 (0.053-0.053) |
| qsort_func | 0.141 (0.139-0.142) | 0.141 (0.138-0.142) | 0.133 (0.130-0.134) | 0.234 (0.229-0.242) | n/a | n/a |
| qsort_inplace | 0.081 (0.080-0.083) | 0.079 (0.078-0.080) | 0.069 (0.067-0.069) | 0.078 (0.077-0.080) | n/a | n/a |
| sieve | 0.073 (0.071-0.073) | 0.069 (0.068-0.148) | 0.067 (0.065-0.067) | 0.139 (0.136-0.159) | 0.112 (0.111-0.113) | 0.067 (0.066-0.068) |
| sortedmap | 0.145 (0.145-0.146) | 0.151 (0.150-0.154) | n/a | n/a | n/a | n/a |
| streams | 0.075 (0.074-0.075) | 0.066 (0.066-0.067) | n/a | n/a | n/a | n/a |
| strings | 0.046 (0.045-0.047) | 0.044 (0.044-0.046) | 0.042 (0.042-0.043) | 0.041 (0.037-0.042) | 0.159 (0.156-0.170) | 0.019 (0.019-0.020) |
| tasks | 2.766 (2.730-2.814) | 2.679 (2.621-2.728) | n/a | n/a | n/a | n/a |
| url | 0.195 (0.192-0.197) | 0.168 (0.167-0.173) | n/a | n/a | n/a | n/a |
| wordfreq | 0.073 (0.072-0.075) | 0.069 (0.069-0.070) | 0.059 (0.059-0.060) | 0.075 (0.074-0.076) | n/a | n/a |

### Ratio to C (wall-time median; lower is better, 1.00x = as fast as C)

| benchmark | Orin C/C | Orin LLVM/C | Go/C | Java/C | Rust/C |
|---|---:|---:|---:|---:|---:|
| appends | 1.43x | 1.17x | 1.72x | 15.92x | 0.76x |
| bintrees | 0.41x | 0.41x | 1.24x | 0.36x | 1.17x |
| bytesstr | 1.66x | 1.40x | 0.42x | 5.00x | 1.99x |
| fib | 2.00x | 2.03x | 3.99x | 2.83x | 2.16x |
| html | 1.08x | 0.86x | 1.57x | n/a | n/a |
| html_hand | n/a | n/a | n/a | n/a | n/a |
| http_parse | n/a | n/a | n/a | n/a | n/a |
| mapfreq | 2.04x | 2.04x | 1.43x | n/a | n/a |
| mutres | 4.18x | 3.38x | 1.02x | 2.61x | 1.15x |
| nbody | 0.89x | 0.93x | 1.20x | n/a | n/a |
| pqueue | 1.87x | 1.53x | 2.66x | 3.18x | 1.15x |
| qsort_func | 1.06x | 1.06x | 1.76x | n/a | n/a |
| qsort_inplace | 1.18x | 1.14x | 1.13x | n/a | n/a |
| sieve | 1.09x | 1.03x | 2.08x | 1.67x | 1.00x |
| sortedmap | n/a | n/a | n/a | n/a | n/a |
| streams | n/a | n/a | n/a | n/a | n/a |
| strings | 1.09x | 1.05x | 0.97x | 3.77x | 0.44x |
| tasks | n/a | n/a | n/a | n/a | n/a |
| url | n/a | n/a | n/a | n/a | n/a |
| wordfreq | 1.23x | 1.17x | 1.26x | n/a | n/a |

### CPU time (user + sys, median s) and peak RSS (MiB)

| benchmark | orin CPU | llvm CPU | c CPU | go CPU | java CPU | rust CPU | orin RSS | llvm RSS | c RSS | go RSS | java RSS | rust RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| appends | 0.005 | 0.004 | 0.003 | 0.008 | 0.070 | 0.002 | 4.8 | 5.0 | 4.8 | 7.3 | 48.2 | 5.2 |
| bintrees | 0.231 | 0.228 | 0.556 | 1.478 | 0.238 | 0.657 | 17.6 | 17.9 | 9.6 | 13.1 | 301.4 | 10.0 |
| bytesstr | 0.022 | 0.019 | 0.013 | 0.007 | 0.079 | 0.027 | 11.6 | 11.9 | 11.6 | 6.2 | 104.7 | 5.0 |
| fib | 0.176 | 0.181 | 0.089 | 0.357 | 0.262 | 0.192 | 1.6 | 1.9 | 1.5 | 1.7 | 39.0 | 2.0 |
| html | 0.087 | 0.069 | 0.081 | 0.170 | n/a | n/a | 3.9 | 4.2 | 2.1 | 7.6 | n/a | n/a |
| html_hand | 0.073 | 0.051 | n/a | n/a | n/a | n/a | 2.7 | 2.9 | n/a | n/a | n/a | n/a |
| http_parse | 0.065 | 0.055 | n/a | n/a | n/a | n/a | 1.8 | 2.0 | n/a | n/a | n/a | n/a |
| mapfreq | 0.090 | 0.089 | 0.044 | 0.070 | n/a | n/a | 11.2 | 11.4 | 5.0 | 7.2 | n/a | n/a |
| mutres | 0.089 | 0.072 | 0.021 | 0.022 | 0.078 | 0.024 | 1.6 | 1.8 | 1.5 | 1.7 | 39.3 | 2.1 |
| nbody | 0.040 | 0.042 | 0.045 | 0.055 | n/a | n/a | 1.9 | 1.9 | 2.0 | 1.6 | n/a | n/a |
| pqueue | 0.086 | 0.070 | 0.046 | 0.126 | 0.194 | 0.053 | 6.3 | 6.5 | 4.8 | 15.1 | 62.3 | 5.2 |
| qsort_func | 0.141 | 0.141 | 0.133 | 0.287 | n/a | n/a | 36.4 | 36.6 | 22.0 | 36.3 | n/a | n/a |
| qsort_inplace | 0.081 | 0.078 | 0.069 | 0.089 | n/a | n/a | 16.9 | 17.2 | 16.8 | 24.6 | n/a | n/a |
| sieve | 0.073 | 0.068 | 0.067 | 0.234 | 0.130 | 0.066 | 77.9 | 78.3 | 77.7 | 186.0 | 116.2 | 78.5 |
| sortedmap | 0.145 | 0.151 | n/a | n/a | n/a | n/a | 11.3 | 11.5 | n/a | n/a | n/a | n/a |
| streams | 0.074 | 0.066 | n/a | n/a | n/a | n/a | 39.9 | 40.1 | n/a | n/a | n/a | n/a |
| strings | 0.046 | 0.044 | 0.042 | 0.051 | 0.303 | 0.019 | 46.3 | 46.6 | 34.8 | 23.5 | 139.4 | 20.0 |
| tasks | 3.317 | 3.072 | n/a | n/a | n/a | n/a | 14.1 | 14.5 | n/a | n/a | n/a | n/a |
| url | 0.195 | 0.167 | n/a | n/a | n/a | n/a | 6.5 | 6.9 | n/a | n/a | n/a | n/a |
| wordfreq | 0.073 | 0.069 | 0.059 | 0.077 | n/a | n/a | 2.3 | 2.6 | 1.9 | 6.5 | n/a | n/a |

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
| parallel_collatz | 1 | 0.436 (0.431-0.447) | 0.435 | 1.00x | 100 % | 1.00x | same |
| parallel_collatz | 2 | 0.252 (0.249-0.252) | 0.457 | 1.73x | 87 % | 1.05x | same |
| parallel_collatz | 4 | 0.156 (0.154-0.157) | 0.532 | 2.80x | 70 % | 1.22x | same |
| streams_parallel | 1 | 0.420 (0.411-0.424) | 0.419 | 1.00x | 100 % | 1.00x | same |
| streams_parallel | 2 | 0.222 (0.219-0.223) | 0.426 | 1.89x | 95 % | 1.02x | same |
| streams_parallel | 4 | 0.140 (0.139-0.147) | 0.504 | 2.99x | 75 % | 1.20x | same |

Speedup = wall(1 thread) / wall(n); efficiency = speedup / n. CPU time that grows with n is overhead or oversubscription (more threads than free cores).

### Self-compile (orin2 compiles compiler/main.or)

| wall s (min-max) | CPU s | peak RSS MiB | instructions | output identical to stage2.c |
|---:|---:|---:|---:|---|
| 1.858 (1.820-1.988) | 2.999 | 394.6 | 28,542,663,271 | yes |


## All runs

| date | commit | ref | self-compile instructions | self-compile wall s | file |
|---|---|---|---:|---:|---|
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
