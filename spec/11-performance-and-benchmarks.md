# 11 — Performance and Evaluation

## Target, not a guarantee

Orin aspires to **performance often between optimized Go and Rust** for specified CPU-/memory-/server workloads; this is not an ordering that always holds. Compilation AOT, static routing, no mandatory tracing GC, and lowered classes/annotations are strategies, NOT proof of speed. Dynamic RC, copy-on-write, bounds checks, region retention and runtime allocations may be costly in some workloads.

## Benchmark groups

1. CPU: integer/numeric kernels, compression, parsers, serialization.
2. Memory: alloc-heavy trees, immutable updates, maps, arrays, variable aliasing, graph workloads.
3. Services: HTTP routing, JSON decode/encode, simple database-adjacent request handlers.
4. Concurrency: actor/message transfer, immutable sharing, task throughput.
5. Compiler UX: build time, incremental check, binary size and startup.
6. AI coding: total tokens to successful tests, independent human review, build/repair cycles.

Use comparable semantics and algorithms, identical datasets/hardware/compiler flags, warm-up policy, confidence intervals and full source publication. Report throughput, latency distributions, CPU, RSS/peak heap, allocations, retain/release operations, reuse rate and binary size. Compare Rust, Go, Orin and relevant Koka/Lean techniques where possible; do not cherry-pick only winning cases.

## Optimization order

Correct semantics and memory safety -> conservative RC -> verified retain/release removal -> uniqueness/COW reuse -> escape/region placement -> codegen optimization -> more advanced whole-program transformations. Never weaken safety to reach a benchmark.

## Proposed design hypothesis

The reduction in source-level ownership choices and JS/TS-familiar stdlib APIs should reduce agents' overall coding tokens and correction attempts. Validate this empirically against TS, Go and Rust; token count depends on tokenizer and surrounding prompts, not just character count or keyword spelling.
