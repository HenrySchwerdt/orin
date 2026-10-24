# Orin benchmark history

Written by `.github/workflows/bench.yml` (nightly and manual runs on `main`); one JSON file per run in [`history/`](history/), charts rendered by `tooling/benchmarks` (`bench-report render`, no external services). The same data as a stand-alone page: [`report.html`](report.html). Metrics and methodology: `docs/benchmarks.md` on `main`. Do not edit this branch by hand.

10 runs, 2026-10-14 to 2026-10-24. Latest: [`7635a6de4b`](https://github.com/HenrySchwerdt/orin/commit/7635a6de4ba00d5f68f1c6355860428eaad22201).

Instruction counts are the regression metric: they are deterministic for single-threaded programs, while wall time on a shared runner moves by 10-25 % between identical binaries.

![Orin to C wall-time ratio per benchmark over time](charts/ratio_wall.svg)

![Orin to C executed-instruction ratio per benchmark over time](charts/ratio_instructions.svg)

![Self-compile instructions and wall time over time](charts/selfcompile.svg)

![Parallel speedup by worker threads](charts/parallel.svg)

## Latest run


Commit `7635a6de4b` (main), 2026-10-24T08:51:56Z. Machine: AMD EPYC 7763 64-Core Processor, 4 cores, 15.6 GiB, Linux-6.17.0-1022-azure-x86_64-with-glibc2.39. Runs per cell: 5 (median after one warm-up).

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
| appends | 0.008 (0.008-0.009) | 0.008 (0.007-0.009) | 0.005 (0.005-0.005) | 0.007 (0.006-0.007) | 0.070 (0.068-0.071) | 0.004 (0.004-0.005) |
| bintrees | 0.407 (0.405-0.414) | 0.397 (0.392-0.411) | 0.691 (0.676-0.714) | 1.296 (1.290-1.303) | 0.220 (0.214-0.223) | 0.708 (0.705-0.716) |
| bytesstr | 0.033 (0.033-0.034) | 0.028 (0.028-0.028) | 0.018 (0.016-0.019) | 0.007 (0.007-0.009) | 0.066 (0.064-0.068) | 0.035 (0.035-0.035) |
| fib | 0.295 (0.295-0.296) | 0.326 (0.326-0.329) | 0.198 (0.198-0.199) | 0.598 (0.597-0.599) | 0.420 (0.419-0.425) | 0.313 (0.313-0.314) |
| html | 0.164 (0.163-0.165) | 0.136 (0.134-0.137) | 0.168 (0.167-0.169) | 0.230 (0.225-0.236) | n/a | n/a |
| html_hand | 0.128 (0.128-0.134) | 0.102 (0.099-0.103) | n/a | n/a | n/a | n/a |
| http_parse | 0.129 (0.128-0.129) | 0.115 (0.114-0.117) | n/a | n/a | n/a | n/a |
| mapfreq | 0.154 (0.153-0.157) | 0.157 (0.155-0.160) | 0.075 (0.072-0.076) | 0.111 (0.110-0.111) | n/a | n/a |
| mutres | 0.174 (0.173-0.174) | 0.134 (0.134-0.135) | 0.032 (0.032-0.034) | 0.045 (0.044-0.046) | 0.083 (0.080-0.087) | 0.038 (0.038-0.038) |
| nbody | 0.070 (0.070-0.076) | 0.078 (0.078-0.079) | 0.070 (0.070-0.070) | 0.088 (0.088-0.088) | n/a | n/a |
| pqueue | 0.150 (0.149-0.152) | 0.128 (0.126-0.134) | 0.064 (0.063-0.064) | 0.189 (0.185-0.193) | 0.206 (0.198-0.214) | 0.092 (0.090-0.094) |
| qsort_func | 0.208 (0.208-0.214) | 0.206 (0.204-0.208) | 0.229 (0.228-0.230) | 0.332 (0.325-0.339) | n/a | n/a |
| qsort_inplace | 0.105 (0.105-0.105) | 0.106 (0.106-0.107) | 0.081 (0.081-0.081) | 0.092 (0.089-0.093) | n/a | n/a |
| sieve | 0.094 (0.093-0.099) | 0.096 (0.093-0.104) | 0.083 (0.081-0.088) | 0.136 (0.125-0.141) | 0.137 (0.136-0.139) | 0.086 (0.085-0.088) |
| sortedmap | 0.254 (0.247-0.259) | 0.261 (0.258-0.267) | n/a | n/a | n/a | n/a |
| streams | 0.110 (0.108-0.111) | 0.090 (0.086-0.091) | n/a | n/a | n/a | n/a |
| strings | 0.073 (0.072-0.075) | 0.069 (0.068-0.070) | 0.073 (0.072-0.074) | 0.055 (0.053-0.057) | 0.198 (0.188-0.203) | 0.028 (0.027-0.029) |
| tasks | 4.860 (4.757-4.879) | 4.779 (4.698-4.891) | n/a | n/a | n/a | n/a |
| url | 0.374 (0.372-0.377) | 0.341 (0.340-0.342) | n/a | n/a | n/a | n/a |
| wordfreq | 0.126 (0.125-0.128) | 0.125 (0.124-0.126) | 0.113 (0.111-0.116) | 0.111 (0.109-0.112) | n/a | n/a |

### Ratio to C (wall-time median; lower is better, 1.00x = as fast as C)

| benchmark | Orin C/C | Orin LLVM/C | Go/C | Java/C | Rust/C |
|---|---:|---:|---:|---:|---:|
| appends | 1.65x | 1.50x | 1.30x | 13.84x | 0.88x |
| bintrees | 0.59x | 0.58x | 1.88x | 0.32x | 1.02x |
| bytesstr | 1.82x | 1.52x | 0.40x | 3.63x | 1.90x |
| fib | 1.49x | 1.65x | 3.02x | 2.12x | 1.58x |
| html | 0.98x | 0.81x | 1.36x | n/a | n/a |
| html_hand | n/a | n/a | n/a | n/a | n/a |
| http_parse | n/a | n/a | n/a | n/a | n/a |
| mapfreq | 2.07x | 2.10x | 1.49x | n/a | n/a |
| mutres | 5.45x | 4.22x | 1.41x | 2.60x | 1.19x |
| nbody | 1.00x | 1.12x | 1.26x | n/a | n/a |
| pqueue | 2.34x | 2.00x | 2.95x | 3.22x | 1.44x |
| qsort_func | 0.91x | 0.90x | 1.45x | n/a | n/a |
| qsort_inplace | 1.29x | 1.31x | 1.13x | n/a | n/a |
| sieve | 1.13x | 1.16x | 1.64x | 1.65x | 1.03x |
| sortedmap | n/a | n/a | n/a | n/a | n/a |
| streams | n/a | n/a | n/a | n/a | n/a |
| strings | 0.99x | 0.94x | 0.75x | 2.71x | 0.38x |
| tasks | n/a | n/a | n/a | n/a | n/a |
| url | n/a | n/a | n/a | n/a | n/a |
| wordfreq | 1.11x | 1.11x | 0.98x | n/a | n/a |

### CPU time (user + sys, median s) and peak RSS (MiB)

| benchmark | orin CPU | llvm CPU | c CPU | go CPU | java CPU | rust CPU | orin RSS | llvm RSS | c RSS | go RSS | java RSS | rust RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| appends | 0.008 | 0.007 | 0.005 | 0.009 | 0.095 | 0.004 | 4.5 | 4.7 | 4.7 | 9.9 | 59.2 | 5.0 |
| bintrees | 0.406 | 0.397 | 0.690 | 2.820 | 0.269 | 0.708 | 17.5 | 17.9 | 9.5 | 14.1 | 308.3 | 10.1 |
| bytesstr | 0.033 | 0.027 | 0.018 | 0.010 | 0.087 | 0.034 | 11.5 | 11.8 | 11.6 | 9.8 | 108.6 | 4.8 |
| fib | 0.295 | 0.326 | 0.198 | 0.600 | 0.435 | 0.313 | 1.5 | 1.7 | 1.5 | 3.4 | 47.4 | 1.9 |
| html | 0.164 | 0.136 | 0.168 | 0.303 | n/a | n/a | 3.7 | 4.1 | 2.1 | 8.4 | n/a | n/a |
| html_hand | 0.128 | 0.102 | n/a | n/a | n/a | n/a | 2.4 | 2.8 | n/a | n/a | n/a | n/a |
| http_parse | 0.128 | 0.114 | n/a | n/a | n/a | n/a | 1.6 | 2.0 | n/a | n/a | n/a | n/a |
| mapfreq | 0.154 | 0.155 | 0.074 | 0.126 | n/a | n/a | 11.3 | 11.6 | 5.1 | 7.9 | n/a | n/a |
| mutres | 0.173 | 0.134 | 0.031 | 0.045 | 0.113 | 0.038 | 1.5 | 1.8 | 1.5 | 3.4 | 47.7 | 2.1 |
| nbody | 0.070 | 0.078 | 0.070 | 0.088 | n/a | n/a | 1.7 | 1.8 | 1.9 | 3.4 | n/a | n/a |
| pqueue | 0.149 | 0.127 | 0.063 | 0.195 | 0.277 | 0.090 | 6.1 | 6.4 | 4.7 | 16.0 | 70.8 | 5.0 |
| qsort_func | 0.208 | 0.206 | 0.229 | 0.396 | n/a | n/a | 36.4 | 36.7 | 23.6 | 40.9 | n/a | n/a |
| qsort_inplace | 0.104 | 0.106 | 0.081 | 0.101 | n/a | n/a | 16.7 | 17.0 | 16.8 | 25.6 | n/a | n/a |
| sieve | 0.093 | 0.096 | 0.082 | 0.183 | 0.163 | 0.085 | 78.5 | 78.8 | 78.4 | 279.5 | 124.5 | 79.8 |
| sortedmap | 0.254 | 0.261 | n/a | n/a | n/a | n/a | 11.1 | 11.4 | n/a | n/a | n/a | n/a |
| streams | 0.110 | 0.090 | n/a | n/a | n/a | n/a | 43.3 | 40.9 | n/a | n/a | n/a | n/a |
| strings | 0.072 | 0.069 | 0.073 | 0.064 | 0.409 | 0.028 | 48.3 | 48.1 | 34.6 | 25.6 | 143.9 | 20.8 |
| tasks | 5.347 | 5.177 | n/a | n/a | n/a | n/a | 18.0 | 18.4 | n/a | n/a | n/a | n/a |
| url | 0.374 | 0.340 | n/a | n/a | n/a | n/a | 6.4 | 6.7 | n/a | n/a | n/a | n/a |
| wordfreq | 0.125 | 0.125 | 0.112 | 0.113 | n/a | n/a | 2.2 | 2.5 | 1.9 | 7.9 | n/a | n/a |

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
| parallel_collatz | 1 | 0.493 (0.492-0.499) | 0.492 | 1.00x | 100 % | 1.00x | same |
| parallel_collatz | 2 | 0.271 (0.271-0.272) | 0.505 | 1.82x | 91 % | 1.03x | same |
| parallel_collatz | 4 | 0.178 (0.177-0.180) | 0.623 | 2.77x | 69 % | 1.27x | same |
| streams_parallel | 1 | 0.480 (0.479-0.484) | 0.479 | 1.00x | 100 % | 1.00x | same |
| streams_parallel | 2 | 0.248 (0.247-0.250) | 0.482 | 1.93x | 97 % | 1.01x | same |
| streams_parallel | 4 | 0.172 (0.171-0.175) | 0.645 | 2.79x | 70 % | 1.35x | same |

Speedup = wall(1 thread) / wall(n); efficiency = speedup / n. CPU time that grows with n is overhead or oversubscription (more threads than free cores).

### Self-compile (orin2 compiles compiler/main.or)

| wall s (min-max) | CPU s | peak RSS MiB | instructions | output identical to stage2.c |
|---:|---:|---:|---:|---|
| 2.708 (2.691-2.747) | 4.807 | 400.4 | 28,924,241,295 | yes |


## All runs

| date | commit | ref | self-compile instructions | self-compile wall s | file |
|---|---|---|---:|---:|---|
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
