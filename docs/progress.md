# Progress

_Updated: 2026-10-13_

## Current stage
Stage 0 (Rust bootstrap `orinb`) under construction. No Orin program compiles yet.

## Capability matrix
| Component | Stage 0 (Rust) | Stage 1 (Orin) |
|---|---|---|
| Lexer/parser | in progress | – |
| Loader/modules | in progress | – |
| Checker → HIR | in progress | – |
| C codegen + runtime | in progress | – |
| Conformance suite | in progress | – |

## Next milestones
- M1: Stage 0 compiles and passes `tests/run` + `tests/errors`.
- M2: Stage 1 compiler sources in Orin-B (`compiler/`).
- M3: Stage 2 / Stage 3 bootstrap with byte-identical C output, in CI.
