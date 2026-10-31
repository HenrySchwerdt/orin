# Orin benchmark history

Written by `.github/workflows/bench.yml` (nightly and manual runs on `main`); one JSON file per run in [`history/`](history/), charts rendered by `tooling/benchmarks` (`bench-report render`, no external services). The same data as a stand-alone page: [`report.html`](report.html). Metrics and methodology: `docs/benchmarks.md` on `main`. Do not edit this branch by hand.

17 runs, 2026-10-14 to 2026-10-31. Latest: [`7635a6de4b`](https://github.com/HenrySchwerdt/orin/commit/7635a6de4ba00d5f68f1c6355860428eaad22201).

Instruction counts are the regression metric: they are deterministic for single-threaded programs, while wall time on a shared runner moves by 10-25 % between identical binaries.

![Orin to C wall-time ratio per benchmark over time](charts/ratio_wall.svg)

![Orin to C executed-instruction ratio per benchmark over time](charts/ratio_instructions.svg)

![Self-compile instructions and wall time over time](charts/selfcompile.svg)

![Parallel speedup by worker threads](charts/parallel.svg)

## Latest run


Commit `7635a6de4b` (main), 2026-10-31T10:26:16Z. Machine: AMD EPYC 9V74 80-Core Processor, 4 cores, 15.6 GiB, Linux-7.0.0-1017-azure-x86_64-with-glibc2.39. Runs per cell: 5 (median after one warm-up).

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
| appends | 0.009 (0.009-0.009) | 0.008 (0.007-0.008) | 0.006 (0.006-0.006) | 0.014 (0.011-0.017) | 0.072 (0.067-0.085) | 0.004 (0.004-0.004) |
| bintrees | 0.416 (0.408-0.429) | 0.415 (0.410-0.419) | 0.585 (0.584-0.591) | 1.238 (1.236-1.250) | 0.353 (0.346-0.357) | 0.733 (0.728-0.737) |
| bytesstr | 0.042 (0.042-0.042) | 0.036 (0.036-0.036) | 0.025 (0.024-0.025) | 0.012 (0.009-0.015) | 0.103 (0.101-0.109) | 0.041 (0.040-0.044) |
| fib | 0.328 (0.328-0.328) | 0.362 (0.362-0.365) | 0.195 (0.194-0.195) | 0.664 (0.660-0.670) | 0.401 (0.401-0.413) | 0.350 (0.349-0.359) |
| html | 0.156 (0.155-0.157) | 0.127 (0.124-0.130) | 0.158 (0.158-0.158) | 0.235 (0.228-0.259) | n/a | n/a |
| html_hand | 0.125 (0.125-0.130) | 0.095 (0.092-0.096) | n/a | n/a | n/a | n/a |
| http_parse | 0.121 (0.121-0.122) | 0.106 (0.106-0.107) | n/a | n/a | n/a | n/a |
| mapfreq | 0.163 (0.159-0.166) | 0.158 (0.158-0.161) | 0.078 (0.075-0.078) | 0.113 (0.113-0.115) | n/a | n/a |
| mutres | 0.192 (0.192-0.193) | 0.150 (0.149-0.151) | 0.035 (0.035-0.035) | 0.047 (0.047-0.047) | 0.090 (0.086-0.091) | 0.041 (0.041-0.043) |
| nbody | 0.078 (0.078-0.079) | 0.084 (0.084-0.084) | 0.078 (0.078-0.078) | 0.093 (0.092-0.094) | n/a | n/a |
| pqueue | 0.163 (0.163-0.163) | 0.139 (0.135-0.148) | 0.076 (0.076-0.076) | 0.214 (0.210-0.226) | 0.272 (0.265-0.276) | 0.097 (0.097-0.098) |
| qsort_func | 0.227 (0.227-0.229) | 0.232 (0.230-0.233) | 0.244 (0.243-0.246) | 0.431 (0.414-0.436) | n/a | n/a |
| qsort_inplace | 0.123 (0.122-0.123) | 0.127 (0.127-0.131) | 0.097 (0.096-0.098) | 0.141 (0.139-0.149) | n/a | n/a |
| sieve | 0.131 (0.129-0.133) | 0.134 (0.126-0.137) | 0.122 (0.111-0.125) | 0.445 (0.429-0.486) | 0.179 (0.176-0.180) | 0.113 (0.111-0.114) |
| sortedmap | 0.262 (0.261-0.263) | 0.276 (0.275-0.278) | n/a | n/a | n/a | n/a |
| streams | 0.138 (0.138-0.139) | 0.126 (0.126-0.127) | n/a | n/a | n/a | n/a |
| strings | 0.082 (0.080-0.082) | 0.080 (0.078-0.080) | 0.071 (0.071-0.072) | 0.078 (0.073-0.088) | 0.243 (0.242-0.246) | 0.033 (0.033-0.034) |
| tasks | 4.354 (4.346-4.406) | 4.347 (4.279-4.369) | n/a | n/a | n/a | n/a |
| url | 0.389 (0.386-0.400) | 0.354 (0.342-0.358) | n/a | n/a | n/a | n/a |
| wordfreq | 0.125 (0.124-0.125) | 0.125 (0.123-0.125) | 0.112 (0.109-0.114) | 0.122 (0.121-0.123) | n/a | n/a |

### Ratio to C (wall-time median; lower is better, 1.00x = as fast as C)

| benchmark | Orin C/C | Orin LLVM/C | Go/C | Java/C | Rust/C |
|---|---:|---:|---:|---:|---:|
| appends | 1.57x | 1.35x | 2.45x | 12.73x | 0.77x |
| bintrees | 0.71x | 0.71x | 2.12x | 0.60x | 1.25x |
| bytesstr | 1.69x | 1.46x | 0.47x | 4.19x | 1.65x |
| fib | 1.68x | 1.86x | 3.41x | 2.06x | 1.80x |
| html | 0.99x | 0.81x | 1.49x | n/a | n/a |
| html_hand | n/a | n/a | n/a | n/a | n/a |
| http_parse | n/a | n/a | n/a | n/a | n/a |
| mapfreq | 2.09x | 2.03x | 1.45x | n/a | n/a |
| mutres | 5.47x | 4.26x | 1.34x | 2.55x | 1.18x |
| nbody | 1.00x | 1.07x | 1.19x | n/a | n/a |
| pqueue | 2.16x | 1.83x | 2.83x | 3.60x | 1.29x |
| qsort_func | 0.93x | 0.95x | 1.77x | n/a | n/a |
| qsort_inplace | 1.27x | 1.31x | 1.46x | n/a | n/a |
| sieve | 1.07x | 1.10x | 3.65x | 1.47x | 0.92x |
| sortedmap | n/a | n/a | n/a | n/a | n/a |
| streams | n/a | n/a | n/a | n/a | n/a |
| strings | 1.15x | 1.12x | 1.09x | 3.41x | 0.46x |
| tasks | n/a | n/a | n/a | n/a | n/a |
| url | n/a | n/a | n/a | n/a | n/a |
| wordfreq | 1.11x | 1.11x | 1.09x | n/a | n/a |

### CPU time (user + sys, median s) and peak RSS (MiB)

| benchmark | orin CPU | llvm CPU | c CPU | go CPU | java CPU | rust CPU | orin RSS | llvm RSS | c RSS | go RSS | java RSS | rust RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| appends | 0.009 | 0.007 | 0.005 | 0.020 | 0.110 | 0.004 | 4.5 | 4.7 | 4.7 | 9.8 | 47.6 | 5.0 |
| bintrees | 0.416 | 0.414 | 0.585 | 2.640 | 0.403 | 0.733 | 17.5 | 17.7 | 9.5 | 12.7 | 301.0 | 10.0 |
| bytesstr | 0.041 | 0.036 | 0.024 | 0.018 | 0.125 | 0.040 | 11.5 | 11.8 | 11.6 | 7.3 | 102.9 | 4.8 |
| fib | 0.327 | 0.362 | 0.194 | 0.666 | 0.415 | 0.349 | 1.5 | 1.9 | 1.5 | 1.7 | 38.5 | 2.0 |
| html | 0.156 | 0.127 | 0.158 | 0.314 | n/a | n/a | 3.7 | 4.1 | 2.1 | 7.8 | n/a | n/a |
| html_hand | 0.125 | 0.095 | n/a | n/a | n/a | n/a | 2.4 | 2.7 | n/a | n/a | n/a | n/a |
| http_parse | 0.121 | 0.106 | n/a | n/a | n/a | n/a | 1.6 | 1.9 | n/a | n/a | n/a | n/a |
| mapfreq | 0.163 | 0.158 | 0.078 | 0.126 | n/a | n/a | 11.3 | 11.5 | 5.0 | 7.1 | n/a | n/a |
| mutres | 0.192 | 0.150 | 0.035 | 0.048 | 0.118 | 0.041 | 1.5 | 1.8 | 1.5 | 1.7 | 38.9 | 2.0 |
| nbody | 0.078 | 0.084 | 0.078 | 0.093 | n/a | n/a | 1.8 | 1.8 | 1.8 | 1.8 | n/a | n/a |
| pqueue | 0.163 | 0.138 | 0.075 | 0.227 | 0.337 | 0.097 | 6.1 | 6.3 | 4.7 | 15.3 | 62.0 | 5.0 |
| qsort_func | 0.227 | 0.231 | 0.244 | 0.551 | n/a | n/a | 36.4 | 36.6 | 23.7 | 41.2 | n/a | n/a |
| qsort_inplace | 0.122 | 0.127 | 0.096 | 0.181 | n/a | n/a | 16.7 | 17.1 | 16.7 | 28.8 | n/a | n/a |
| sieve | 0.130 | 0.133 | 0.121 | 0.749 | 0.206 | 0.112 | 77.7 | 78.0 | 77.6 | 280.3 | 115.9 | 78.2 |
| sortedmap | 0.262 | 0.276 | n/a | n/a | n/a | n/a | 11.1 | 11.4 | n/a | n/a | n/a | n/a |
| streams | 0.138 | 0.126 | n/a | n/a | n/a | n/a | 39.6 | 39.9 | n/a | n/a | n/a | n/a |
| strings | 0.081 | 0.079 | 0.071 | 0.101 | 0.467 | 0.032 | 46.1 | 46.4 | 34.6 | 21.6 | 139.2 | 19.8 |
| tasks | 5.182 | 5.115 | n/a | n/a | n/a | n/a | 14.0 | 14.4 | n/a | n/a | n/a | n/a |
| url | 0.388 | 0.353 | n/a | n/a | n/a | n/a | 6.4 | 6.7 | n/a | n/a | n/a | n/a |
| wordfreq | 0.125 | 0.124 | 0.112 | 0.124 | n/a | n/a | 2.2 | 2.5 | 1.9 | 6.9 | n/a | n/a |

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
| parallel_collatz | 1 | 0.544 (0.544-0.547) | 0.544 | 1.00x | 100 % | 1.00x | same |
| parallel_collatz | 2 | 0.322 (0.319-0.347) | 0.582 | 1.69x | 85 % | 1.07x | same |
| parallel_collatz | 4 | 0.202 (0.202-0.203) | 0.682 | 2.69x | 67 % | 1.25x | same |
| streams_parallel | 1 | 0.541 (0.541-0.542) | 0.541 | 1.00x | 100 % | 1.00x | same |
| streams_parallel | 2 | 0.284 (0.284-0.285) | 0.543 | 1.90x | 95 % | 1.00x | same |
| streams_parallel | 4 | 0.195 (0.194-0.195) | 0.700 | 2.78x | 69 % | 1.29x | same |

Speedup = wall(1 thread) / wall(n); efficiency = speedup / n. CPU time that grows with n is overhead or oversubscription (more threads than free cores).

### Self-compile (orin2 compiles compiler/main.or)

| wall s (min-max) | CPU s | peak RSS MiB | instructions | output identical to stage2.c |
|---:|---:|---:|---:|---|
| 2.912 (2.876-2.926) | 5.067 | 394.0 | 28,907,840,339 | yes |


## All runs

| date | commit | ref | self-compile instructions | self-compile wall s | file |
|---|---|---|---:|---:|---|
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
