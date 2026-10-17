# Frozen runtime snapshot (the "legacy world")

A byte copy of `runtime/core/orin_runtime.{c,h}`, `orin_runtime_io.h`, `orin_runtime_mir.h` and `orin_runtime_llvm.c` as they were
at the start of ADR-0052 step R3d (commit 4d5eeee), with the C object model (`orin_struct_new`, `orin_destroy`, the free lists, ...)
and the C copies of the R1/R3b string functions. **Do not edit its object model.**

It is linked by

- `tools/bootstrap.sh` for stage 0 and stage 1: `seed.c` and `stage1.c` are emitted by compilers whose logic predates R3d, and the
  live runtime is free to lose the definitions they reference (R3d.1 and later) before the seed is regenerated (R3d.7);
- the `--c-builtins` side of `tools/differential.sh --mode builtins` (the legacy world: the C runtime path, no `$std` / `$rt`).

The files that link it read the list in `tools/runtime-sources.txt` (world `legacy`). The platform layer (`runtime/platform/`) is
shared with the live runtime. Deletion order: ADR-0052 Addendum A section 4 (R3d.7 refreshes the seed, R3f removes this directory).

**Exception: interfaces outside the object model.** The task, monitor, capability and network C interface is not moved by R3d
(R3e moves it), and the legacy world must keep linking programs that use it. A PR that adds such a function to `runtime/core/`
copies it, and every change to the snapshot's existing code that it needs, verbatim into this directory in the same PR.
`tools/check_seed_runtime.sh` (CI) fails when the live runtime defines an external symbol this snapshot lacks; symbols that
only R3d code in `$rt` uses are listed in `core-only-symbols.txt` instead.
