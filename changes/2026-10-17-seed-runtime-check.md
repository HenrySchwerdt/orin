- **Seed runtime snapshot check (ADR-0052).** `tools/check_seed_runtime.sh` (CI) fails when the live runtime defines a C
  symbol the frozen snapshot `bootstrap/seed/runtime/` lacks; new task, monitor, capability or network functions are copied
  into the snapshot verbatim in the same PR (README of the snapshot).
