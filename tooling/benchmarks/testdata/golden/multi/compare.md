<!-- orin-bench-comment -->
## Benchmark comparison

Head `a1b5f4708f` against `main` `0b7cafb7b7` (2026-10-19), `4daf30e6a3` (2026-10-16). Regression thresholds: executed instructions **> +2 %** (the reliable metric), wall-time median **> +15 %** (noisy on shared runners). This comment reports only; it does not fail the job.

**29 regression(s) flagged:** appends / Orin (C backend), appends / Orin (LLVM backend), bintrees / Orin (LLVM backend), bytesstr / Orin (LLVM backend), fib / Orin (C backend), fib / Orin (LLVM backend), html / Orin (LLVM backend), html_hand / Orin (LLVM backend), http_parse / Orin (C backend), http_parse / Orin (LLVM backend), mapfreq / Orin (C backend), mapfreq / Orin (LLVM backend), mutres / Orin (C backend), mutres / Orin (LLVM backend), nbody / Orin (C backend), nbody / Orin (LLVM backend), pqueue / Orin (C backend), qsort_func / Orin (C backend), qsort_func / Orin (LLVM backend), qsort_inplace / Orin (LLVM backend), sieve / Orin (C backend), sieve / Orin (LLVM backend), streams / Orin (LLVM backend), strings / Orin (C backend), strings / Orin (LLVM backend), tasks / Orin (LLVM backend), wordfreq / Orin (C backend), wordfreq / Orin (LLVM backend), selfcompile / orin2.

| benchmark | binary | instructions main | instructions PR | change | wall main s | wall PR s | change | verdict |
|---|---|---:|---:|---:|---:|---:|---:|---|
| appends | Orin (C backend) | 119,819,277 | 119,819,277 | +0.0 % | 0.000 | 0.013 | +119900.0 % | **regression (wall time)** |
| appends | Orin (LLVM backend) | 119,387,215 | 141,846,196 | +18.8 % | 0.008 | 0.013 | +71.4 % | **regression (instructions)**, **regression (wall time)** |
| bintrees | Orin (C backend) | 6,198,876,529 | 6,198,876,529 | +0.0 % | 0.381 | 0.000 | -99.9 % | ok |
| bintrees | Orin (LLVM backend) | 5,916,855,168 | n/a | n/a | 0.412 | 0.619 | +50.0 % | **regression (wall time)** |
| bytesstr | Orin (C backend) | 456,346,347 | 456,346,347 | +0.0 % | 0.045 | 0.030 | -34.0 % | ok |
| bytesstr | Orin (LLVM backend) | 380,836,816 | 423,152,018 | +11.1 % | 0.034 | 0.034 | +0.0 % | **regression (instructions)** |
| fib | Orin (C backend) | 3,296,317,240 | 3,840,369,600 | +16.5 % | 0.256 | 0.244 | -4.8 % | **regression (instructions)** |
| fib | Orin (LLVM backend) | 2,483,955,031 | 2,980,746,037 | +20.0 % | 0.153 | 0.219 | +42.9 % | **regression (instructions)**, **regression (wall time)** |
| html | Orin (C backend) | 1,907,001,142 | 1,849,791,107 | -3.0 % | 1.308 | 0.092 | -93.0 % | improvement |
| html | Orin (LLVM backend) | 1,840,785,752 | 2,187,072,181 | +18.8 % | 0.196 | 0.196 | +0.0 % | **regression (instructions)** |
| html_hand | Orin (C backend) | 1,624,827,273 | 1,608,739,875 | -1.0 % | 0.122 | 0.139 | +14.3 % | ok |
| html_hand | Orin (LLVM backend) | 1,491,683,158 | 1,553,195,865 | +4.1 % | 0.107 | 0.114 | +6.1 % | **regression (instructions)** |
| http_parse | Orin (C backend) | 1,569,663,987 | 2,092,885,316 | +33.3 % | 0.128 | 0.075 | -41.7 % | **regression (instructions)** |
| http_parse | Orin (LLVM backend) | 1,487,106,728 | 1,668,864,217 | +12.2 % | 0.969 | 0.102 | -89.5 % | **regression (instructions)** |
| mapfreq | Orin (C backend) | 1,206,764,206 | 1,054,454,160 | -12.6 % | 0.088 | 0.189 | +114.3 % | **regression (wall time)**, improvement |
| mapfreq | Orin (LLVM backend) | 1,005,889,754 | 1,128,831,835 | +12.2 % | 0.127 | 0.192 | +51.5 % | **regression (instructions)**, **regression (wall time)** |
| mutres | Orin (C backend) | 2,465,275,527 | 2,617,766,796 | +6.2 % | 0.000 | 0.220 | +149900.0 % | **regression (instructions)**, **regression (wall time)** |
| mutres | Orin (LLVM backend) | 2,050,559,898 | 1,827,231,592 | -10.9 % | 0.081 | 0.122 | +50.0 % | **regression (wall time)**, improvement |
| nbody | Orin (C backend) | 1,402,308,868 | 1,402,308,868 | +0.0 % | 0.000 | 0.125 | +149900.0 % | **regression (wall time)** |
| nbody | Orin (LLVM backend) | 1,739,112,502 | 1,405,782,606 | -19.2 % | 0.097 | 0.118 | +21.2 % | **regression (wall time)**, improvement |
| pqueue | Orin (C backend) | 1,418,009,967 | 1,446,089,372 | +2.0 % | 0.124 | 1.241 | +900.0 % | **regression (wall time)** |
| pqueue | Orin (LLVM backend) | 1,613,296,922 | 1,384,746,525 | -14.2 % | 0.103 | 0.101 | -1.0 % | improvement |
| qsort_func | Orin (C backend) | 1,936,564,543 | 1,996,458,292 | +3.1 % | 0.341 | 0.272 | -20.0 % | **regression (instructions)** |
| qsort_func | Orin (LLVM backend) | 2,068,836,582 | 1,807,721,285 | -12.6 % | 0.000 | 0.235 | +98900.0 % | **regression (wall time)**, improvement |
| qsort_inplace | Orin (C backend) | 524,657,475 | 524,657,475 | +0.0 % | 0.143 | n/a | n/a | ok |
| qsort_inplace | Orin (LLVM backend) | 553,824,340 | 633,821,189 | +14.4 % | 0.107 | 0.101 | -5.7 % | **regression (instructions)** |
| sieve | Orin (C backend) | 414,435,600 | 369,299,050 | -10.9 % | 0.000 | 0.085 | +99900.0 % | **regression (wall time)**, improvement |
| sieve | Orin (LLVM backend) | 411,052,798 | 456,725,332 | +11.1 % | 0.104 | 0.104 | +0.0 % | **regression (instructions)** |
| sortedmap | Orin (C backend) | 1,665,664,428 | 1,388,053,690 | -16.7 % | 0.314 | 0.209 | -33.3 % | improvement |
| sortedmap | Orin (LLVM backend) | 1,436,859,981 | 1,353,159,400 | -5.8 % | 0.232 | 0.221 | -4.8 % | improvement |
| streams | Orin (C backend) | 1,185,482,135 | 1,173,744,689 | -1.0 % | 0.131 | 0.087 | -34.0 % | ok |
| streams | Orin (LLVM backend) | 1,138,519,332 | 1,408,477,525 | +23.7 % | 0.056 | 0.056 | +0.0 % | **regression (instructions)** |
| strings | Orin (C backend) | 716,943,788 | 716,943,788 | +0.0 % | 0.047 | 0.067 | +42.9 % | **regression (wall time)** |
| strings | Orin (LLVM backend) | 650,431,087 | 579,592,058 | -10.9 % | 0.068 | 0.647 | +852.4 % | **regression (wall time)**, improvement |
| tasks | Orin (C backend) | n/a | n/a | n/a | 39.246 | 3.925 | -90.0 % | ok |
| tasks | Orin (LLVM backend) | n/a | n/a | n/a | 3.845 | 38.450 | +900.0 % | **regression (wall time)** |
| url | Orin (C backend) | 5,980,789,842 | 4,983,991,535 | -16.7 % | 0.447 | 0.209 | -53.3 % | improvement |
| url | Orin (LLVM backend) | 4,500,660,177 | 4,050,594,159 | -10.0 % | 2.538 | 0.178 | -93.0 % | improvement |
| wordfreq | Orin (C backend) | 904,746,926 | 790,555,566 | -12.6 % | 0.074 | 0.105 | +41.4 % | **regression (wall time)**, improvement |
| wordfreq | Orin (LLVM backend) | 846,766,131 | 813,230,838 | -4.0 % | 0.074 | 0.127 | +71.4 % | **regression (wall time)**, improvement |
| selfcompile | orin2 | 23,761,175,248 | 25,230,938,665 | +6.2 % | 2.926 | 3.657 | +25.0 % | **regression (instructions)**, **regression (wall time)** |

Parallel speedup of this run (informational): parallel_collatz 1 thr 1.50x, 2 thr 18.01x, 4 thr 0.00x; streams_parallel 1 thr 10.00x, 2 thr 2.33x, 4 thr 3.80x.

