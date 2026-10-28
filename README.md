# Orin benchmark history

Written by `.github/workflows/bench.yml` (nightly and manual runs on `main`); one JSON file per run in [`history/`](history/), charts rendered by `tooling/benchmarks` (`bench-report render`, no external services). The same data as a stand-alone page: [`report.html`](report.html). Metrics and methodology: `docs/benchmarks.md` on `main`. Do not edit this branch by hand.

14 runs, 2026-10-14 to 2026-10-28. Latest: [`7635a6de4b`](https://github.com/HenrySchwerdt/orin/commit/7635a6de4ba00d5f68f1c6355860428eaad22201).

Instruction counts are the regression metric: they are deterministic for single-threaded programs, while wall time on a shared runner moves by 10-25 % between identical binaries.

![Orin to C wall-time ratio per benchmark over time](charts/ratio_wall.svg)

![Orin to C executed-instruction ratio per benchmark over time](charts/ratio_instructions.svg)

![Self-compile instructions and wall time over time](charts/selfcompile.svg)

![Parallel speedup by worker threads](charts/parallel.svg)

## Latest run


Commit `7635a6de4b` (main), 2026-10-28T10:34:30Z. Machine: AMD EPYC 9V74 80-Core Processor, 4 cores, 15.6 GiB, Linux-6.17.0-1022-azure-x86_64-with-glibc2.39. Runs per cell: 5 (median after one warm-up).

<details><summary>Tool versions</summary>

- cc: `cc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0`
- clang: `Ubuntu clang version 18.1.3 (1ubuntu1)`
- go: `go version go1.24.13 linux/amd64`
- java: `openjdk version "21.0.12.1" 2026-08-18 LTS`
- python: `3.12.3`
- rustc: `rustc 1.99.1 (58cf8f9c3 2026-10-13)`
- valgrind: `valgrind-3.22.0`

</details>

### Wall time, seconds (median; min-max)

| benchmark | Orin (C backend) | Orin (LLVM backend) | C | Go | Java | Rust |
|---|---:|---:|---:|---:|---:|---:|
| appends | 0.009 (0.009-0.011) | 0.007 (0.007-0.008) | 0.005 (0.005-0.006) | 0.006 (0.006-0.007) | 0.064 (0.060-0.087) | 0.004 (0.004-0.004) |
| bintrees | 0.412 (0.409-0.415) | 0.415 (0.411-0.417) | 0.588 (0.586-0.592) | 1.235 (1.227-1.244) | 0.206 (0.204-0.213) | 0.729 (0.728-0.743) |
| bytesstr | 0.035 (0.035-0.035) | 0.029 (0.029-0.030) | 0.019 (0.018-0.019) | 0.006 (0.006-0.009) | 0.063 (0.060-0.069) | 0.040 (0.036-0.040) |
| fib | 0.328 (0.327-0.330) | 0.362 (0.362-0.362) | 0.194 (0.194-0.195) | 0.663 (0.661-0.673) | 0.404 (0.402-0.406) | 0.349 (0.349-0.349) |
| html | 0.155 (0.155-0.160) | 0.124 (0.123-0.126) | 0.157 (0.151-0.158) | 0.227 (0.223-0.234) | n/a | n/a |
| html_hand | 0.125 (0.123-0.125) | 0.096 (0.092-0.097) | n/a | n/a | n/a | n/a |
| http_parse | 0.121 (0.120-0.121) | 0.105 (0.105-0.106) | n/a | n/a | n/a | n/a |
| mapfreq | 0.156 (0.156-0.159) | 0.158 (0.158-0.158) | 0.075 (0.072-0.077) | 0.108 (0.107-0.110) | n/a | n/a |
| mutres | 0.192 (0.192-0.192) | 0.150 (0.149-0.152) | 0.035 (0.035-0.035) | 0.046 (0.046-0.047) | 0.088 (0.086-0.092) | 0.042 (0.041-0.043) |
| nbody | 0.078 (0.078-0.078) | 0.084 (0.084-0.084) | 0.078 (0.078-0.079) | 0.092 (0.091-0.093) | n/a | n/a |
| pqueue | 0.164 (0.164-0.165) | 0.136 (0.135-0.137) | 0.075 (0.074-0.075) | 0.202 (0.199-0.207) | 0.220 (0.211-0.225) | 0.096 (0.096-0.096) |
| qsort_func | 0.217 (0.216-0.218) | 0.221 (0.221-0.223) | 0.235 (0.232-0.235) | 0.346 (0.340-0.360) | n/a | n/a |
| qsort_inplace | 0.118 (0.118-0.118) | 0.126 (0.121-0.130) | 0.090 (0.090-0.090) | 0.100 (0.100-0.101) | n/a | n/a |
| sieve | 0.097 (0.096-0.098) | 0.095 (0.094-0.097) | 0.085 (0.084-0.089) | 0.133 (0.129-0.137) | 0.138 (0.134-0.140) | 0.087 (0.085-0.087) |
| sortedmap | 0.261 (0.260-0.262) | 0.275 (0.275-0.276) | n/a | n/a | n/a | n/a |
| streams | 0.112 (0.111-0.112) | 0.099 (0.096-0.101) | n/a | n/a | n/a | n/a |
| strings | 0.077 (0.077-0.077) | 0.074 (0.073-0.075) | 0.067 (0.067-0.068) | 0.053 (0.050-0.059) | 0.191 (0.186-0.210) | 0.029 (0.029-0.030) |
| tasks | 4.731 (4.674-4.803) | 4.582 (4.553-4.592) | n/a | n/a | n/a | n/a |
| url | 0.382 (0.381-0.407) | 0.341 (0.337-0.348) | n/a | n/a | n/a | n/a |
| wordfreq | 0.126 (0.126-0.128) | 0.124 (0.124-0.125) | 0.109 (0.108-0.122) | 0.114 (0.113-0.115) | n/a | n/a |

### Ratio to C (wall-time median; lower is better, 1.00x = as fast as C)

| benchmark | Orin C/C | Orin LLVM/C | Go/C | Java/C | Rust/C |
|---|---:|---:|---:|---:|---:|
| appends | 1.58x | 1.33x | 1.13x | 11.66x | 0.75x |
| bintrees | 0.70x | 0.70x | 2.10x | 0.35x | 1.24x |
| bytesstr | 1.88x | 1.58x | 0.33x | 3.37x | 2.13x |
| fib | 1.69x | 1.86x | 3.41x | 2.08x | 1.80x |
| html | 0.98x | 0.79x | 1.44x | n/a | n/a |
| html_hand | n/a | n/a | n/a | n/a | n/a |
| http_parse | n/a | n/a | n/a | n/a | n/a |
| mapfreq | 2.10x | 2.12x | 1.45x | n/a | n/a |
| mutres | 5.50x | 4.31x | 1.33x | 2.51x | 1.21x |
| nbody | 1.00x | 1.08x | 1.18x | n/a | n/a |
| pqueue | 2.20x | 1.82x | 2.70x | 2.94x | 1.28x |
| qsort_func | 0.92x | 0.94x | 1.47x | n/a | n/a |
| qsort_inplace | 1.31x | 1.40x | 1.12x | n/a | n/a |
| sieve | 1.15x | 1.12x | 1.57x | 1.63x | 1.02x |
| sortedmap | n/a | n/a | n/a | n/a | n/a |
| streams | n/a | n/a | n/a | n/a | n/a |
| strings | 1.14x | 1.10x | 0.78x | 2.83x | 0.44x |
| tasks | n/a | n/a | n/a | n/a | n/a |
| url | n/a | n/a | n/a | n/a | n/a |
| wordfreq | 1.16x | 1.14x | 1.04x | n/a | n/a |

### CPU time (user + sys, median s) and peak RSS (MiB)

| benchmark | orin CPU | llvm CPU | c CPU | go CPU | java CPU | rust CPU | orin RSS | llvm RSS | c RSS | go RSS | java RSS | rust RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| appends | 0.008 | 0.007 | 0.005 | 0.008 | 0.095 | 0.004 | 4.5 | 4.7 | 4.7 | 10.4 | 58.4 | 5.0 |
| bintrees | 0.412 | 0.414 | 0.588 | 2.618 | 0.257 | 0.728 | 17.5 | 17.8 | 9.5 | 14.2 | 307.8 | 10.1 |
| bytesstr | 0.035 | 0.029 | 0.018 | 0.009 | 0.082 | 0.039 | 11.5 | 11.7 | 11.5 | 9.9 | 108.0 | 4.9 |
| fib | 0.327 | 0.361 | 0.194 | 0.666 | 0.418 | 0.349 | 1.5 | 1.8 | 1.5 | 3.4 | 47.5 | 1.9 |
| html | 0.155 | 0.124 | 0.157 | 0.301 | n/a | n/a | 3.7 | 4.1 | 2.1 | 8.4 | n/a | n/a |
| html_hand | 0.125 | 0.095 | n/a | n/a | n/a | n/a | 2.4 | 2.7 | n/a | n/a | n/a | n/a |
| http_parse | 0.120 | 0.105 | n/a | n/a | n/a | n/a | 1.6 | 1.9 | n/a | n/a | n/a | n/a |
| mapfreq | 0.156 | 0.157 | 0.074 | 0.122 | n/a | n/a | 11.3 | 11.5 | 5.0 | 9.9 | n/a | n/a |
| mutres | 0.192 | 0.150 | 0.035 | 0.047 | 0.114 | 0.042 | 1.5 | 1.8 | 1.5 | 3.4 | 47.8 | 2.0 |
| nbody | 0.078 | 0.084 | 0.078 | 0.093 | n/a | n/a | 1.8 | 1.8 | 1.8 | 3.4 | n/a | n/a |
| pqueue | 0.164 | 0.136 | 0.075 | 0.208 | 0.289 | 0.096 | 6.1 | 6.3 | 4.7 | 16.1 | 70.3 | 5.0 |
| qsort_func | 0.216 | 0.221 | 0.234 | 0.408 | n/a | n/a | 36.3 | 36.7 | 24.7 | 40.9 | n/a | n/a |
| qsort_inplace | 0.118 | 0.126 | 0.090 | 0.106 | n/a | n/a | 16.7 | 17.0 | 16.8 | 29.8 | n/a | n/a |
| sieve | 0.097 | 0.095 | 0.084 | 0.181 | 0.163 | 0.086 | 79.0 | 78.8 | 78.9 | 308.2 | 124.5 | 79.5 |
| sortedmap | 0.261 | 0.275 | n/a | n/a | n/a | n/a | 11.1 | 11.4 | n/a | n/a | n/a | n/a |
| streams | 0.112 | 0.098 | n/a | n/a | n/a | n/a | 43.3 | 40.9 | n/a | n/a | n/a | n/a |
| strings | 0.077 | 0.074 | 0.067 | 0.060 | 0.393 | 0.029 | 47.4 | 48.6 | 36.4 | 23.7 | 145.8 | 21.8 |
| tasks | 5.580 | 5.255 | n/a | n/a | n/a | n/a | 18.0 | 18.3 | n/a | n/a | n/a | n/a |
| url | 0.382 | 0.341 | n/a | n/a | n/a | n/a | 6.4 | 6.7 | n/a | n/a | n/a | n/a |
| wordfreq | 0.126 | 0.124 | 0.109 | 0.116 | n/a | n/a | 2.2 | 2.5 | 1.9 | 7.9 | n/a | n/a |

### Executed instructions (valgrind; the regression metric)

| benchmark | Orin C | Orin LLVM | C | Orin C/C | Orin LLVM/C | note |
|---|---:|---:|---:|---:|---:|---|
| appends | 63,530,238 | 44,305,230 | 25,381,155 | 2.50x | 1.75x |  |
| bintrees | 4,457,305,570 | 4,319,515,260 | 7,242,293,433 | 0.62x | 0.60x |  |
| bytesstr | 349,907,901 | 259,441,192 | 178,695,497 | 1.96x | 1.45x |  |
| fib | 3,200,318,149 | 2,483,953,789 | 3,170,983,196 | 1.01x | 0.78x |  |
| html | 1,784,203,908 | 1,471,870,971 | 1,581,660,500 | 1.13x | 0.93x |  |
| html_hand | 1,332,890,919 | 987,886,037 | n/a | n/a | n/a |  |
| http_parse | 1,539,178,532 | 1,358,991,073 | n/a | n/a | n/a |  |
| mapfreq | 1,050,624,793 | 995,125,501 | 717,968,445 | 1.46x | 1.39x |  |
| mutres | 2,541,530,939 | 2,030,255,608 | 291,450,138 | 8.72x | 6.97x |  |
| nbody | 658,315,521 | 772,258,305 | 651,230,682 | 1.01x | 1.19x |  |
| pqueue | 1,411,252,294 | 1,344,413,165 | 355,213,580 | 3.97x | 3.78x |  |
| qsort_func | 1,329,379,223 | 1,269,367,671 | 1,528,677,747 | 0.87x | 0.83x |  |
| qsort_inplace | 576,878,278 | 521,077,518 | 273,751,945 | 2.11x | 1.90x |  |
| sieve | 410,343,299 | 456,726,111 | 191,756,528 | 2.14x | 2.38x |  |
| sortedmap | 1,356,615,067 | 1,358,427,082 | n/a | n/a | n/a |  |
| streams | 1,173,755,264 | 1,173,731,319 | n/a | n/a | n/a |  |
| strings | 647,532,817 | 559,940,890 | 685,893,540 | 0.94x | 0.82x |  |
| tasks | n/a | n/a | n/a | n/a | n/a | llvm skipped: multi-threaded (20,000 tasks, channels): valgrind serialises threads, so the count would include scheduler waits; orin skipped: multi-threaded (20,000 tasks, channels): valgrind serialises threads, so the count would include scheduler waits |
| url | 4,852,179,714 | 4,363,458,753 | n/a | n/a | n/a |  |
| wordfreq | 760,378,206 | 707,684,209 | 880,488,803 | 0.86x | 0.80x |  |

### Parallel speedup (std:task; worker threads = first argument of the program)

| benchmark | threads | wall s (min-max) | CPU s (user+sys) | speedup | efficiency | CPU vs 1 thread | output |
|---|---:|---:|---:|---:|---:|---:|---|
| parallel_collatz | 1 | 0.536 (0.535-0.540) | 0.536 | 1.00x | 100 % | 1.00x | same |
| parallel_collatz | 2 | 0.296 (0.293-0.297) | 0.551 | 1.81x | 91 % | 1.03x | same |
| parallel_collatz | 4 | 0.188 (0.188-0.189) | 0.660 | 2.85x | 71 % | 1.23x | same |
| streams_parallel | 1 | 0.531 (0.530-0.536) | 0.531 | 1.00x | 100 % | 1.00x | same |
| streams_parallel | 2 | 0.273 (0.272-0.273) | 0.531 | 1.95x | 97 % | 1.00x | same |
| streams_parallel | 4 | 0.183 (0.183-0.183) | 0.689 | 2.90x | 73 % | 1.30x | same |

Speedup = wall(1 thread) / wall(n); efficiency = speedup / n. CPU time that grows with n is overhead or oversubscription (more threads than free cores).

### Self-compile (orin2 compiles compiler/main.or)

| wall s (min-max) | CPU s | peak RSS MiB | instructions | output identical to stage2.c |
|---:|---:|---:|---:|---|
| 2.775 (2.758-2.822) | 4.907 | 400.1 | 28,927,700,571 | yes |


## All runs

| date | commit | ref | self-compile instructions | self-compile wall s | file |
|---|---|---|---:|---:|---|
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
