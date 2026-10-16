- **`u8[]` <-> string conversions 4 elements per iteration; packed arrays (b) and in-place field/element reuse (e) measured first (ADR-0038 addendum 2026-10-16).**
  (e) is worth at most 0.54 % of the self-compile (the field in/out pattern; all COW copies together are 2.25 %, mostly real sharing) and
  nothing on the benchmarks: not built. Full packed storage would give bytesstr -99 % and http_parse at most -9 % and nothing on the
  compiler, for a MIR version, a lowering change and the runtime's array sites: not built. Built instead, runtime only:
  `orin_bytes_to_string` / `orin_string_to_bytes` narrow and widen 4 elements per iteration, same checks and
  traps. Executed instructions: bytesstr -26.9 % (LLVM -35.2 %), http_parse -0.1 % (LLVM -1.5 %), the other benchmarks and the self-compile unchanged.
