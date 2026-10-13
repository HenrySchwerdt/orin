# Progress

_Updated: 2026-10-13_

## Current stage: self-hosting alpha (M3 reached)
- The compiler in `compiler/` (~6,000 lines of Orin-B) is compiled by Stage 0 (`orin1`), compiles
  itself (`orin2`), and `orin2` compiles it again: `stage2.c` and `stage3.c` are byte-identical
  (`tools/bootstrap.sh`, run in CI).
- `orin2` passes the full conformance suite (76 run + 61 error tests), also with ASan/UBSan.
- `orin2` built with ASan/UBSan compiles itself without memory errors.
- Self-compile time: ~0.1 s (plus the C compiler).
- Stage 0 and Stage 1 parsers agree on 753 files (`tools/diff_parsers.py`, in CI).

This is "self-hosting alpha" in the sense of spec.md "Definition of maturity": **not** formally
verified; memory safety is supported by tests and sanitizers only.

## Capability matrix
| Component | Stage 0 (Rust, frozen) | Self-hosted (Orin) |
|---|---|---|
| Lexer/parser | done | done; differential-tested vs Stage 0 |
| Loader/modules (E0301–E0303) | done | done |
| Checker → HIR | done | done (same diagnostics on the error suite) |
| C codegen + runtime | done | done (ASan-clean) |
| Driver `check`/`compile` | done | done |

## Next milestones
1. Freeze Stage 0 (bug fixes only); all new language work goes into `compiler/`.
2. MIR + OIM memory IR and independent verifier (spec 07, ADR-0006), C backend on MIR.
3. Language growth in the self-hosted compiler: generics (done: simple parametric generics,
   ADR-0007, `tests/next/`), closures, classes (lowering),
   floats, maps, interfaces, annotations — each with an ADR and conformance tests.
4. LLVM IR backend (ADR-0006); benchmarks (spec 11); formal core calculus (spec 07); `orin mcp`.
