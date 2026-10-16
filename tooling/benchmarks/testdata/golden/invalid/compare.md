<!-- orin-bench-comment -->
## Benchmark comparison

Head `9f83f16af4` against `main` `f837889af7` (2026-10-14). Regression thresholds: executed instructions **> +2 %** (the reliable metric), wall-time median **> +15 %** (noisy on shared runners). This comment reports only; it does not fail the job.

No regression above the thresholds.

| benchmark | binary | instructions main | instructions PR | change | wall main s | wall PR s | change | verdict |
|---|---|---:|---:|---:|---:|---:|---:|---|
| appends | Orin (C backend) | 126,318,041 | 119,819,277 | -5.1 % | 0.011 | 0.011 | +4.4 % | improvement |
| appends | Orin (LLVM backend) | 127,513,214 | 118,205,164 | -7.3 % | 0.011 | 0.011 | -2.0 % | improvement |
| bintrees | Orin (C backend) | 7,135,047,035 | 6,198,876,529 | -13.1 % | 0.527 | 0.381 | -27.8 % | improvement |
| bintrees | Orin (LLVM backend) | 7,437,460,288 | 6,099,850,689 | -18.0 % | 0.479 | 0.412 | -13.9 % | improvement |
| bytesstr | Orin (C backend) | 507,049,236 | 507,051,497 | +0.0 % | 0.041 | 0.030 | -26.2 % | ok |
| bytesstr | Orin (LLVM backend) | 423,225,141 | 423,152,018 | -0.0 % | 0.028 | 0.028 | +0.9 % | ok |
| fib | Orin (C backend) | 3,200,300,984 | 3,200,308,000 | +0.0 % | 0.256 | 0.244 | -4.9 % | ok |
| fib | Orin (LLVM backend) | 4,802,078,512 | 2,483,955,031 | -48.3 % | 0.462 | 0.219 | -52.6 % | improvement |
| html | Orin (C backend) | n/a | 1,907,001,142 | n/a | n/a | 0.131 | n/a | ok |
| html | Orin (LLVM backend) | n/a | 1,822,560,151 | n/a | n/a | 0.131 | n/a | ok |
| html_hand | Orin (C backend) | n/a | 1,608,739,875 | n/a | n/a | 0.116 | n/a | ok |
| html_hand | Orin (LLVM backend) | n/a | 1,537,817,689 | n/a | n/a | 0.108 | n/a | ok |
| http_parse | Orin (C backend) | 2,961,801,240 | 1,744,071,097 | -41.1 % | 0.191 | 0.107 | -44.1 % | improvement |
| http_parse | Orin (LLVM backend) | 3,021,310,497 | 1,652,340,809 | -45.3 % | 0.210 | 0.097 | -54.0 % | improvement |
| mapfreq | Orin (C backend) | 2,031,810,766 | 1,171,615,734 | -42.3 % | 0.182 | 0.126 | -31.1 % | improvement |
| mapfreq | Orin (LLVM backend) | 2,123,612,253 | 1,117,655,283 | -47.4 % | 0.185 | 0.128 | -31.0 % | improvement |
| mutres | Orin (C backend) | 3,390,268,479 | 2,541,521,162 | -25.0 % | 0.185 | 0.147 | -20.9 % | improvement |
| mutres | Orin (LLVM backend) | 2,632,763,913 | 2,030,257,325 | -22.9 % | 0.143 | 0.116 | -19.0 % | improvement |
| nbody | Orin (C backend) | 2,397,304,014 | 1,402,308,868 | -41.5 % | 0.132 | 0.083 | -37.0 % | improvement |
| nbody | Orin (LLVM backend) | 1,997,264,018 | 1,449,260,419 | -27.4 % | 0.118 | 0.098 | -16.8 % | improvement |
| pqueue | Orin (C backend) | 2,263,872,264 | 1,403,970,265 | -38.0 % | 0.212 | 0.124 | -41.4 % | improvement |
| pqueue | Orin (LLVM backend) | 2,025,241,573 | 1,344,414,102 | -33.6 % | 0.160 | 0.103 | -35.7 % | improvement |
| qsort_func | Orin (C backend) | 2,381,898,999 | 1,996,458,292 | -16.2 % | 0.258 | 0.227 | -12.1 % | improvement |
| qsort_func | Orin (LLVM backend) | 2,377,522,586 | 2,008,579,206 | -15.5 % | 0.258 | 0.238 | -7.7 % | improvement |
| qsort_inplace | Orin (C backend) | 980,428,383 | 582,952,750 | -40.5 % | 0.126 | 0.096 | -23.9 % | improvement |
| qsort_inplace | Orin (LLVM backend) | 817,415,460 | 615,360,378 | -24.7 % | 0.117 | 0.102 | -13.3 % | improvement |
| sieve | Orin (C backend) | 658,840,889 | 410,332,278 | -37.7 % | 0.128 | 0.085 | -33.2 % | improvement |
| sieve | Orin (LLVM backend) | 492,430,342 | 456,725,332 | -7.3 % | 0.087 | 0.087 | -0.5 % | improvement |
| sortedmap | Orin (C backend) | 1,871,625,616 | 1,388,053,690 | -25.8 % | 0.270 | 0.209 | -22.5 % | improvement |
| sortedmap | Orin (LLVM backend) | 1,729,193,460 | 1,395,009,691 | -19.3 % | 0.240 | 0.221 | -8.2 % | improvement |
| streams | Orin (C backend) | n/a | 1,173,744,689 | n/a | n/a | 0.087 | n/a | ok |
| streams | Orin (LLVM backend) | n/a | 1,173,731,271 | n/a | n/a | 0.079 | n/a | ok |
| strings | Orin (C backend) | 1,310,179,004 | 696,061,931 | -46.9 % | 0.108 | 0.067 | -38.4 % | improvement |
| strings | Orin (LLVM backend) | 1,350,441,664 | 643,991,176 | -52.3 % | 0.113 | 0.065 | -42.5 % | improvement |
| tasks | Orin (C backend) | n/a | n/a | n/a | 3.829 | 3.925 | +2.5 % | ok |
| tasks | Orin (LLVM backend) | n/a | n/a | n/a | 3.826 | 3.845 | +0.5 % | ok |
| url | Orin (C backend) | n/a | 4,983,991,535 | n/a | n/a | 0.298 | n/a | ok |
| url | Orin (LLVM backend) | n/a | 4,500,660,177 | n/a | n/a | 0.254 | n/a | ok |
| wordfreq | Orin (C backend) | 1,500,053,613 | 878,395,074 | -41.4 % | 0.146 | 0.106 | -27.5 % | improvement |
| wordfreq | Orin (LLVM backend) | 1,488,479,223 | 838,382,308 | -43.7 % | 0.148 | 0.106 | -28.5 % | improvement |
| selfcompile | orin2 | 35,729,157,194 | 24,496,056,957 | -31.4 % | 3.937 | 2.438 | -38.1 % | improvement |

Parallel speedup of this run (informational): parallel_collatz 1 thr 1.00x, 2 thr 1.80x, 4 thr 2.71x; streams_parallel 1 thr 1.00x, 2 thr 1.94x, 4 thr 3.17x.

