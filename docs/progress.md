# Progress

_Updated: 2026-10-13_

## Current stage
**M1 reached:** Stage 0 (`orinb`, Rust) compiles Orin-B to C and passes the conformance suite
(75 run + 61 error tests), also under ASan/UBSan. Stage 1 (Orin) components are being written;
the Stage 1 parser already compiles with Stage 0 and runs natively.

## Capability matrix
| Component | Stage 0 (Rust) | Stage 1 (Orin) |
|---|---|---|
| Lexer/parser | done (50 unit tests) | written; compiles & runs; differential test pending |
| Loader/modules (E0301–E0303) | done | in progress |
| Checker → HIR | done (54 unit tests) | in progress |
| C codegen + runtime | done (18 tests, ASan) | not started |
| Driver (`compile`) | done | not started |
| Conformance suite | 136/136 pass | – |

## Next milestones
- M2: Stage 1 compiler complete (`compiler/main.or`), passing the conformance suite when built by Stage 0.
- M3: Stage 2 / Stage 3 bootstrap with byte-identical C output, in CI.
