## Orin benchmarks

Commit `a1b5f4708f` (main), 2026-12-30T00:00:00Z. Machine: AMD EPYC 9V74 80-Core Processor, 8 cores, 15.6 GiB, Linux-6.17.0-1022-azure-x86_64-with-glibc2.39. Runs per cell: 10 (median after one warm-up).

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
| appends | 0.013 (0.011-0.000) | 0.013 (0.008-0.014) MISMATCH | 0.005 (0.004-0.049) MISMATCH | 0.009 (0.006-0.071) | 0.059 (0.060-0.000) | 0.004 (0.002-0.004) |
| bintrees | 0.000 (0.373-0.270) | 0.619 (0.000-0.416) | 0.593 (0.000-0.503) | 9.533 (9.515-0.670) | 0.179 (0.177-1.735) | 0.001 (0.851-0.582) MISMATCH |
| bytesstr | 0.030 (0.029-0.055) | 0.034 (0.028-0.000) | 0.023 (0.015-0.160) | 0.007 (0.000-0.008) | 0.061 (0.470-0.000) | 0.048 (0.029-0.038) |
| fib | 0.244 (2.435-2.438) | 0.219 (0.218-2.276) | 1.510 (0.226-1.514) MISMATCH | 5.138 (0.507-0.516) | 0.000 (0.000-0.224) | 0.271 (0.285-0.000) MISMATCH |
| html | 0.092 (0.130-0.198) | 0.196 (0.127-0.174) | 0.087 (0.087-1.243) MISMATCH | 0.277 (0.179-n/a) | n/a | n/a |
| html_hand | 0.139 (1.157-0.141) | 0.114 (0.162-0.168) | n/a | n/a | n/a | n/a |
| http_parse | 0.075 (0.159-0.107) | 0.102 (0.968-0.974) | n/a | n/a | n/a | n/a |
| mapfreq | 0.189 (0.000-0.127) | 0.192 (0.089-0.000) | 0.000 (0.059-0.042) | 0.059 (0.000-0.060) | n/a | n/a |
| mutres | 0.220 (0.154-0.147) | 0.122 (0.000-0.000) | MISMATCH | MISMATCH | 0.071 (0.068-0.071) | 0.023 (0.038-0.040) |
| nbody | 0.125 (n/a-0.084) | 0.118 (0.000-0.097) | 0.000 (0.061-0.091) | 0.108 (0.071-0.000) | n/a | n/a |
| pqueue | 1.241 (0.124-0.088) | 0.101 (0.153-0.103) | 0.040 (0.060-0.069) | 0.155 (0.153-0.156) | MISMATCH | 0.090 (0.074-0.074) MISMATCH |
| qsort_func | 0.272 (0.338-0.239) | 0.235 (0.237-0.168) | 0.180 (0.000-1.835) | 0.284 (0.275-0.210) | n/a | n/a |
| qsort_inplace | MISMATCH | 0.101 (0.120-0.108) | MISMATCH | 0.000 (0.000-0.121) | n/a | n/a |
| sieve | 0.085 (0.102-0.130) | 0.104 (0.060-0.061) | 0.000 (0.000-0.082) | 0.124 (0.166-0.123) MISMATCH | 0.151 (0.086-0.000) | 0.056 (0.118-0.912) MISMATCH |
| sortedmap | 0.209 (0.219-0.211) | 0.221 (0.264-0.222) | n/a | n/a | n/a | n/a |
| streams | 0.087 (0.087-0.882) | 0.056 (n/a-0.080) | n/a | n/a | n/a | n/a |
| strings | 0.067 (0.098-0.068) | 0.647 (0.045-0.098) | 0.056 (0.063-0.535) | 0.041 (0.061-0.030) | 0.158 (0.150-1.642) | 0.025 (0.023-0.035) |
| tasks | 3.925 (5.599-3.931) | 38.450 (5.634-5.875) | n/a | n/a | n/a | n/a |
| url | 0.209 (0.294-0.476) | 0.178 (0.302-2.570) | n/a | n/a | n/a | n/a |
| wordfreq | 0.105 (0.106-0.075) | 0.127 (0.074-0.000) | 0.124 (0.081-0.832) | MISMATCH | n/a | n/a |

### Ratio to C (wall-time median; lower is better, 1.00x = as fast as C)

| benchmark | Orin C/C | Orin LLVM/C | Go/C | Java/C | Rust/C |
|---|---:|---:|---:|---:|---:|
| appends | 2.92x | 2.90x | 1.88x | 13.06x | 0.80x |
| bintrees | 0.00x | 1.04x | 16.07x | 0.30x | 0.00x |
| bytesstr | 1.31x | 1.49x | 0.32x | 2.66x | 2.08x |
| fib | 0.16x | 0.15x | 3.40x | 0.00x | 0.18x |
| html | 1.05x | 2.26x | 3.18x | n/a | n/a |
| html_hand | n/a | n/a | n/a | n/a | n/a |
| http_parse | n/a | n/a | n/a | n/a | n/a |
| mapfreq | 3152.16x | 3207.61x | 985.94x | n/a | n/a |
| mutres | n/a | n/a | n/a | n/a | n/a |
| nbody | 2055.45x | 1936.05x | 1780.02x | n/a | n/a |
| pqueue | 30.78x | 2.52x | 3.85x | n/a | 2.22x |
| qsort_func | 1.51x | 1.31x | 1.58x | n/a | n/a |
| qsort_inplace | n/a | n/a | n/a | n/a | n/a |
| sieve | 1087.11x | 1323.79x | 1576.34x | 1927.61x | 712.21x |
| sortedmap | n/a | n/a | n/a | n/a | n/a |
| streams | n/a | n/a | n/a | n/a | n/a |
| strings | 1.19x | 11.58x | 0.73x | 2.83x | 0.44x |
| tasks | n/a | n/a | n/a | n/a | n/a |
| url | n/a | n/a | n/a | n/a | n/a |
| wordfreq | 0.85x | 1.03x | n/a | n/a | n/a |

### CPU time (user + sys, median s) and peak RSS (MiB)

| benchmark | orin CPU | llvm CPU | c CPU | go CPU | java CPU | rust CPU | orin RSS | llvm RSS | c RSS | go RSS | java RSS | rust RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| appends | 0.016 | 0.000 | 0.000 | 0.072 | 0.080 | 0.003 | 2.3 | 2.5 | 4.9 | 41.1 | 58.9 | 5.2 |
| bintrees | 0.399 | 0.288 | 0.593 | 3.028 | 0.315 | 0.401 | 8.8 | 66.5 | 9.7 | 14.4 | 1139.0 | 5.1 |
| bytesstr | 0.045 | 0.034 | 0.000 | 0.016 | n/a | 0.000 | 23.2 | 44.0 | 23.2 | 36.8 | 107.9 | 9.9 |
| fib | 0.255 | 2.182 | 0.151 | 0.001 | 0.390 | 0.268 | 1.6 | 1.0 | 1.6 | 3.4 | 47.5 | 2.0 |
| html | 0.129 | 0.194 | 0.186 | 0.256 | n/a | n/a | 3.9 | 2.1 | 4.5 | 4.2 | n/a | n/a |
| html_hand | 0.081 | 0.162 | n/a | n/a | n/a | n/a | 3.2 | 12.9 | n/a | n/a | n/a | n/a |
| http_parse | 0.105 | 0.145 | n/a | n/a | n/a | n/a | 1.7 | 1.0 | n/a | n/a | n/a | n/a |
| mapfreq | 0.000 | 0.153 | 0.062 | 0.066 | n/a | n/a | 21.1 | 5.4 | 5.2 | 4.0 | n/a | n/a |
| mutres | 0.146 | 0.116 | 0.271 | 0.025 | 0.140 | 0.033 | 0.8 | 2.0 | 1.6 | n/a | 23.9 | 1.1 |
| nbody | 0.082 | 0.097 | 0.604 | 0.051 | n/a | n/a | 0.9 | 6.9 | 7.5 | 12.6 | n/a | n/a |
| pqueue | 0.148 | 0.102 | 0.086 | 1.596 | 0.159 | 0.078 | 3.1 | 13.0 | 9.7 | 16.1 | 70.3 | 10.2 |
| qsort_func | n/a | 0.356 | 0.180 | 0.342 | n/a | n/a | 65.8 | 33.2 | 92.7 | 22.3 | n/a | n/a |
| qsort_inplace | 0.114 | 0.101 | 0.105 | 0.086 | n/a | n/a | 8.4 | 17.1 | 16.9 | 102.7 | n/a | n/a |
| sieve | 0.127 | 0.085 | 0.094 | 0.241 | 0.182 | 0.119 | 78.6 | 79.7 | 39.5 | 563.6 | 62.3 | 158.3 |
| sortedmap | 0.313 | 0.220 | n/a | n/a | n/a | n/a | 9.4 | 4.8 | n/a | n/a | n/a | n/a |
| streams | 0.870 | 0.119 | n/a | n/a | n/a | n/a | 150.4 | 151.6 | n/a | n/a | n/a | n/a |
| strings | 0.066 | 0.064 | 0.063 | 0.045 | 3.159 | 0.016 | 48.4 | 47.9 | 73.0 | 22.7 | 72.9 | 10.1 |
| tasks | 43.611 | 4.245 | n/a | n/a | n/a | n/a | 32.3 | 16.5 | n/a | n/a | n/a | n/a |
| url | 0.294 | 0.380 | n/a | n/a | n/a | n/a | 3.3 | 25.2 | n/a | n/a | n/a | n/a |
| wordfreq | 0.127 | n/a | 0.082 | 0.091 | n/a | n/a | 2.4 | 1.3 | 2.0 | 7.9 | n/a | n/a |

### Executed instructions (valgrind; the regression metric)

| benchmark | Orin C | Orin LLVM | C | Orin C/C | Orin LLVM/C | note |
|---|---:|---:|---:|---:|---:|---|
| appends | 119,819,277 | 141,846,196 | 24,619,720 | 4.87x | 5.76x |  |
| bintrees | 6,198,876,529 | n/a | 7,314,716,367 | 0.85x | n/a |  |
| bytesstr | 456,346,347 | 423,152,018 | 178,695,497 | 2.55x | 2.37x |  |
| fib | 3,840,369,600 | 2,980,746,037 | 3,170,983,196 | 1.21x | 0.94x |  |
| html | 1,849,791,107 | 2,187,072,181 | 1,597,477,105 | 1.16x | 1.37x |  |
| html_hand | 1,608,739,875 | 1,553,195,865 | n/a | n/a | n/a |  |
| http_parse | 2,092,885,316 | 1,668,864,217 | n/a | n/a | n/a |  |
| mapfreq | 1,054,454,160 | 1,128,831,835 | 717,968,445 | 1.47x | 1.57x |  |
| mutres | 2,617,766,796 | 1,827,231,592 | 291,450,124 | 8.98x | 6.27x |  |
| nbody | 1,402,308,868 | 1,405,782,606 | 586,107,626 | 2.39x | 2.40x |  |
| pqueue | 1,446,089,372 | 1,384,746,525 | 358,765,701 | 4.03x | 3.86x |  |
| qsort_func | 1,996,458,292 | 1,807,721,285 | 1,543,964,510 | 1.29x | 1.17x |  |
| qsort_inplace | 524,657,475 | 633,821,189 | 273,751,959 | 1.92x | 2.32x |  |
| sieve | 369,299,050 | 456,725,332 | 193,674,107 | 1.91x | 2.36x |  |
| sortedmap | 1,388,053,690 | 1,353,159,400 | n/a | n/a | n/a |  |
| streams | 1,173,744,689 | 1,408,477,525 | n/a | n/a | n/a |  |
| strings | 716,943,788 | 579,592,058 | 617,304,186 | 1.16x | 0.94x |  |
| tasks | n/a | n/a | n/a | n/a | n/a | llvm skipped: multi-threaded (20,000 tasks, channels): valgrind serialises threads, so the count would include scheduler waits; orin skipped: multi-threaded (20,000 tasks, channels): valgrind serialises threads, so the count would include scheduler waits |
| url | 4,983,991,535 | 4,050,594,159 | n/a | n/a | n/a |  |
| wordfreq | 790,555,566 | 813,230,838 | 792,439,922 | 1.00x | 1.03x |  |

### Parallel speedup (std:task; worker threads = first argument of the program)

| benchmark | threads | wall s (min-max) | CPU s (user+sys) | speedup | efficiency | CPU vs 1 thread | output |
|---|---:|---:|---:|---:|---:|---:|---|
| parallel_collatz | 1 | 0.290 (0.413-0.411) | 0.413 | 1.50x | 1000 % | 10.00x | same |
| parallel_collatz | 2 | 0.161 (0.240-0.000) | 0.511 | 18.01x | 108 % | 10.31x | same |
| parallel_collatz | 4 | 0.107 (0.000-0.162) | 0.792 | 0.00x | 68 % | 1.28x | same |
| streams_parallel | 1 | 0.422 (0.398-0.482) | 0.397 | 10.00x | n/a | 0.70x | same |
| streams_parallel | 2 | 0.205 (0.000-0.249) | 4.028 | 2.33x | 970 % | 10.04x | same |
| streams_parallel | 4 | 0.000 (0.190-0.089) | 0.496 | 3.80x | 793 % | 0.82x | same |

Speedup = wall(1 thread) / wall(n); efficiency = speedup / n. CPU time that grows with n is overhead or oversubscription (more threads than free cores).

### Self-compile (orin2 compiles compiler/main.or)

| wall s (min-max) | CPU s | peak RSS MiB | instructions | output identical to stage2.c |
|---:|---:|---:|---:|---|
| 3.657 (2.896-0.002) | 1.677 | 435.7 | 25,230,938,665 | yes |

