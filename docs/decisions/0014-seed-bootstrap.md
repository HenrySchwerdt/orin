# ADR-0014: Seed-based bootstrap; compiler source may use the full language

Status: accepted (2026-10-13). Refines ADR-0001 / docs/bootstrap.md.

## Problem
The compiler source (`compiler/`) is restricted to Orin-B because CI bootstraps it from the
frozen Rust Stage 0. The compiler would benefit from generics, closures, classes and the array
API — but Stage 0 cannot compile them, and extending Stage 0 is explicitly not wanted.

## Decision
- A **seed** is the generated C of a self-hosted compiler built from a known commit
  (`bootstrap/seed/orin-seed.c.gz` + `bootstrap/seed/SEED_INFO` with source commit, sha256 of the
  uncompressed C, and how it was produced). Every release already ships the same artefact
  (`share/orin/orin-seed.c`).
- New bootstrap chain: `cc seed → orin0`; `orin0 compile compiler/ → stage1.c → orin1`;
  `orin1 → stage2.c → orin2`; `orin2 → stage3.c`; require `stage2.c == stage3.c` (unchanged).
- The seed is **updated deliberately** (a PR that regenerates it with `tools/update_seed.sh`),
  only when the compiler starts using a feature the current seed cannot compile; the PR must show
  the full bootstrap from the *old* seed to the new compiler.
- **Stage 0 (Rust) remains** as an independent second root during the transition: CI keeps a job
  that bootstraps from Stage 0 as long as `compiler/` is still Orin-B. The first PR that uses a
  non-Orin-B feature inside `compiler/` removes that job and retires Stage 0 to `bootstrap/`
  (kept for history and the Rust unit tests). Before that, at least one seed is produced by the
  Stage 0 chain, so the trust chain is: Rust Stage 0 → seed₁ → … (documented in SEED_INFO).
- Trusting-trust note (spec 09): seeds are reproducible from the previous seed and the tagged
  source; anyone can verify a seed by re-running the chain. Diverse double-compilation (C backend
  vs LLVM backend producing the same stage3.c — already true today) is kept in CI.
