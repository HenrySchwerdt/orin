# Orin benchmark history

Written by `.github/workflows/bench.yml` (nightly and manual runs on `main`); one JSON file per run in [`history/`](history/), charts rendered by `tooling/benchmarks` (`bench-report render`, no external services). The same data as a stand-alone page: [`report.html`](report.html). Metrics and methodology: `docs/benchmarks.md` on `main`. Do not edit this branch by hand.

37 runs, 2026-10-14 to 2026-11-21. Latest: [`7635a6de4b`](https://github.com/HenrySchwerdt/orin/commit/7635a6de4ba00d5f68f1c6355860428eaad22201).

Instruction counts are the regression metric: they are deterministic for single-threaded programs, while wall time on a shared runner moves by 10-25 % between identical binaries.

![Orin to C wall-time ratio per benchmark over time](charts/ratio_wall.svg)

![Orin to C executed-instruction ratio per benchmark over time](charts/ratio_instructions.svg)

![Self-compile instructions and wall time over time](charts/selfcompile.svg)

![Parallel speedup by worker threads](charts/parallel.svg)

## Latest run


Commit `7635a6de4b` (main), 2026-11-21T12:19:24Z. Machine: AMD EPYC 7763 64-Core Processor, 4 cores, 15.6 GiB, Linux-7.0.0-1020-azure-x86_64-with-glibc2.43. Runs per cell: 5 (median after one warm-up).

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
| appends | 0.009 (0.009-0.009) | 0.008 (0.008-0.008) | 0.005 (0.005-0.005) | 0.011 (0.009-0.016) | 0.076 (0.068-0.083) | 0.004 (0.004-0.005) |
| bintrees | 0.408 (0.401-0.414) | 0.390 (0.389-0.391) | 1.017 (1.012-1.024) | 1.282 (1.279-1.288) | 0.330 (0.319-0.335) | 1.163 (1.161-1.169) |
| bytesstr | 0.037 (0.037-0.037) | 0.033 (0.032-0.033) | 0.027 (0.027-0.027) | 0.009 (0.008-0.010) | 0.101 (0.096-0.111) | 0.037 (0.036-0.041) |
| fib | 0.261 (0.259-0.263) | 0.314 (0.310-0.315) | 0.177 (0.176-0.195) | 0.598 (0.596-0.600) | 0.433 (0.425-0.438) | 0.313 (0.312-0.315) |
| html | 0.161 (0.160-0.163) | 0.138 (0.137-0.139) | 0.150 (0.148-0.151) | 0.234 (0.222-0.240) | n/a | n/a |
| html_hand | 0.128 (0.127-0.131) | 0.100 (0.100-0.102) | n/a | n/a | n/a | n/a |
| http_parse | 0.125 (0.125-0.126) | 0.111 (0.111-0.112) | n/a | n/a | n/a | n/a |
| mapfreq | 0.154 (0.153-0.155) | 0.155 (0.154-0.155) | 0.074 (0.072-0.076) | 0.114 (0.113-0.114) | n/a | n/a |
| mutres | 0.170 (0.170-0.171) | 0.134 (0.133-0.134) | 0.037 (0.037-0.038) | 0.045 (0.044-0.045) | 0.084 (0.080-0.087) | 0.038 (0.036-0.038) |
| nbody | 0.063 (0.063-0.063) | 0.078 (0.078-0.081) | 0.073 (0.073-0.074) | 0.087 (0.087-0.088) | n/a | n/a |
| pqueue | 0.144 (0.143-0.147) | 0.124 (0.124-0.129) | 0.072 (0.071-0.072) | 0.195 (0.194-0.201) | 0.237 (0.222-0.239) | 0.089 (0.089-0.091) |
| qsort_func | 0.212 (0.210-0.214) | 0.215 (0.214-0.217) | 0.183 (0.182-0.184) | 0.375 (0.359-0.383) | n/a | n/a |
| qsort_inplace | 0.108 (0.107-0.108) | 0.110 (0.108-0.110) | 0.086 (0.085-0.087) | 0.127 (0.104-0.132) | n/a | n/a |
| sieve | 0.110 (0.107-0.112) | 0.118 (0.117-0.119) | 0.098 (0.097-0.099) | 0.278 (0.271-0.361) | 0.161 (0.159-0.162) | 0.102 (0.100-0.103) |
| sortedmap | 0.245 (0.240-0.245) | 0.254 (0.253-0.254) | n/a | n/a | n/a | n/a |
| streams | 0.123 (0.122-0.123) | 0.106 (0.105-0.107) | n/a | n/a | n/a | n/a |
| strings | 0.076 (0.075-0.076) | 0.073 (0.073-0.075) | 0.068 (0.068-0.070) | 0.073 (0.067-0.074) | 0.234 (0.231-0.235) | 0.031 (0.029-0.041) |
| tasks | 3.779 (3.732-3.906) | 3.805 (3.721-4.126) | n/a | n/a | n/a | n/a |
| url | 0.350 (0.349-0.351) | 0.322 (0.321-0.332) | n/a | n/a | n/a | n/a |
| wordfreq | 0.126 (0.125-0.126) | 0.124 (0.123-0.125) | 0.107 (0.105-0.108) | 0.116 (0.115-0.117) | n/a | n/a |

### Ratio to C (wall-time median; lower is better, 1.00x = as fast as C)

| benchmark | Orin C/C | Orin LLVM/C | Go/C | Java/C | Rust/C |
|---|---:|---:|---:|---:|---:|
| appends | 1.92x | 1.59x | 2.27x | 16.00x | 0.95x |
| bintrees | 0.40x | 0.38x | 1.26x | 0.32x | 1.14x |
| bytesstr | 1.37x | 1.20x | 0.34x | 3.72x | 1.35x |
| fib | 1.47x | 1.77x | 3.38x | 2.45x | 1.77x |
| html | 1.07x | 0.92x | 1.56x | n/a | n/a |
| html_hand | n/a | n/a | n/a | n/a | n/a |
| http_parse | n/a | n/a | n/a | n/a | n/a |
| mapfreq | 2.07x | 2.09x | 1.53x | n/a | n/a |
| mutres | 4.55x | 3.57x | 1.19x | 2.24x | 1.00x |
| nbody | 0.86x | 1.07x | 1.20x | n/a | n/a |
| pqueue | 2.00x | 1.73x | 2.71x | 3.30x | 1.25x |
| qsort_func | 1.16x | 1.18x | 2.05x | n/a | n/a |
| qsort_inplace | 1.26x | 1.28x | 1.48x | n/a | n/a |
| sieve | 1.12x | 1.21x | 2.84x | 1.64x | 1.04x |
| sortedmap | n/a | n/a | n/a | n/a | n/a |
| streams | n/a | n/a | n/a | n/a | n/a |
| strings | 1.10x | 1.07x | 1.07x | 3.42x | 0.45x |
| tasks | n/a | n/a | n/a | n/a | n/a |
| url | n/a | n/a | n/a | n/a | n/a |
| wordfreq | 1.18x | 1.16x | 1.09x | n/a | n/a |

### CPU time (user + sys, median s) and peak RSS (MiB)

| benchmark | orin CPU | llvm CPU | c CPU | go CPU | java CPU | rust CPU | orin RSS | llvm RSS | c RSS | go RSS | java RSS | rust RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| appends | 0.009 | 0.007 | 0.005 | 0.015 | 0.096 | 0.004 | 4.8 | 5.0 | 4.8 | 8.5 | 47.8 | 5.2 |
| bintrees | 0.408 | 0.390 | 1.016 | 2.788 | 0.383 | 1.163 | 17.6 | 17.8 | 9.6 | 12.5 | 301.2 | 10.1 |
| bytesstr | 0.037 | 0.032 | 0.027 | 0.014 | 0.115 | 0.036 | 11.7 | 11.9 | 11.6 | 6.3 | 104.6 | 5.1 |
| fib | 0.260 | 0.313 | 0.177 | 0.599 | 0.446 | 0.313 | 1.6 | 1.8 | 1.5 | 1.8 | 38.9 | 2.0 |
| html | 0.160 | 0.138 | 0.149 | 0.312 | n/a | n/a | 4.0 | 4.1 | 2.1 | 7.6 | n/a | n/a |
| html_hand | 0.128 | 0.100 | n/a | n/a | n/a | n/a | 2.6 | 2.9 | n/a | n/a | n/a | n/a |
| http_parse | 0.125 | 0.111 | n/a | n/a | n/a | n/a | 1.8 | 1.9 | n/a | n/a | n/a | n/a |
| mapfreq | 0.154 | 0.155 | 0.074 | 0.128 | n/a | n/a | 11.2 | 11.4 | 5.0 | 7.3 | n/a | n/a |
| mutres | 0.170 | 0.133 | 0.037 | 0.045 | 0.110 | 0.037 | 1.7 | 1.8 | 1.5 | 1.8 | 39.1 | 2.0 |
| nbody | 0.063 | 0.078 | 0.073 | 0.088 | n/a | n/a | 1.9 | 1.9 | 1.8 | 1.8 | n/a | n/a |
| pqueue | 0.144 | 0.124 | 0.072 | 0.205 | 0.310 | 0.089 | 6.3 | 6.4 | 4.8 | 14.8 | 62.2 | 5.2 |
| qsort_func | 0.212 | 0.215 | 0.182 | 0.465 | n/a | n/a | 36.4 | 36.6 | 22.0 | 38.2 | n/a | n/a |
| qsort_inplace | 0.108 | 0.109 | 0.085 | 0.162 | n/a | n/a | 16.9 | 17.1 | 16.8 | 28.7 | n/a | n/a |
| sieve | 0.110 | 0.118 | 0.098 | 0.451 | 0.186 | 0.101 | 77.9 | 78.2 | 77.7 | 231.9 | 116.0 | 78.4 |
| sortedmap | 0.244 | 0.254 | n/a | n/a | n/a | n/a | 11.2 | 11.4 | n/a | n/a | n/a | n/a |
| streams | 0.122 | 0.105 | n/a | n/a | n/a | n/a | 39.8 | 40.0 | n/a | n/a | n/a | n/a |
| strings | 0.075 | 0.073 | 0.068 | 0.095 | 0.455 | 0.030 | 46.3 | 46.5 | 34.8 | 23.4 | 139.5 | 20.0 |
| tasks | 4.485 | 4.514 | n/a | n/a | n/a | n/a | 14.1 | 14.3 | n/a | n/a | n/a | n/a |
| url | 0.350 | 0.322 | n/a | n/a | n/a | n/a | 6.5 | 6.7 | n/a | n/a | n/a | n/a |
| wordfreq | 0.125 | 0.124 | 0.107 | 0.119 | n/a | n/a | 2.3 | 2.6 | 1.9 | 6.5 | n/a | n/a |

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
| parallel_collatz | 1 | 0.493 (0.491-0.494) | 0.493 | 1.00x | 100 % | 1.00x | same |
| parallel_collatz | 2 | 0.290 (0.289-0.291) | 0.525 | 1.70x | 85 % | 1.06x | same |
| parallel_collatz | 4 | 0.191 (0.190-0.194) | 0.641 | 2.59x | 65 % | 1.30x | same |
| streams_parallel | 1 | 0.488 (0.485-0.489) | 0.488 | 1.00x | 100 % | 1.00x | same |
| streams_parallel | 2 | 0.256 (0.255-0.257) | 0.489 | 1.91x | 95 % | 1.00x | same |
| streams_parallel | 4 | 0.162 (0.162-0.164) | 0.580 | 3.00x | 75 % | 1.19x | same |

Speedup = wall(1 thread) / wall(n); efficiency = speedup / n. CPU time that grows with n is overhead or oversubscription (more threads than free cores).

### Self-compile (orin2 compiles compiler/main.or)

| wall s (min-max) | CPU s | peak RSS MiB | instructions | output identical to stage2.c |
|---:|---:|---:|---:|---|
| 2.450 (2.443-2.456) | 4.534 | 395.4 | 28,542,569,621 | yes |


## All runs

| date | commit | ref | self-compile instructions | self-compile wall s | file |
|---|---|---|---:|---:|---|
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
