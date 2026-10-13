# 09 — Compiler, Bootstrap and Self-Hosting

## Non-negotiable goal

The **production compiler is written in Orin and compiles its own Orin sources**. Using Rust, TypeScript or C in a temporary Stage 0 bootstrap is permitted. A C compiler/linker can remain a platform tool; self-hosting does not imply eliminating all external toolchain components.

## Pipeline

Orin Source -> Lexer/Parser with spans -> AST -> Name/Module Resolution -> Annotation Expansion -> Type-checked HIR -> Class/Method Lowering -> Core Calculus -> MIR/SSA -> OIM analysis + memory IR verifier -> Codegen (initial C, future Cranelift/LLVM) -> Native binary.

Preserve exact source spans and original/exported symbol names for diagnostics and MCP. The parser/type checker MUST remain deterministic under fixed inputs. Compiler and LSP/MCP use one semantic service library.

## Stage strategy

- **Stage 0:** smallest compiler in a host language, targeting C and covering a frozen bootstrap subset.
- **Stage 1:** compiler frontend/backend implemented in Orin, compiled with Stage 0.
- **Stage 2:** Stage 1 compiles its own sources.
- **Stage 3:** Stage 2 compiles them again. Compare deterministic outputs and run conformance suites; differences require investigation.

Illustrative workflow:

```bash
orin-bootstrap compiler/main.or -o stage1.c
cc stage1.c orin_runtime.c -o orin1
./orin1 compiler/main.or -o stage2.c
cc stage2.c orin_runtime.c -o orin2
./orin2 compiler/main.or -o stage3.c
cmp stage2.c stage3.c
```

Actual commands, paths and compiler ABI will depend on implementation. Stage equality is a bootstrap consistency test, **not** a formal correctness or trust-chain proof (see also trusting-trust attacks).

## Minimal self-hosting subset

Functions/recursion, simple types `int/bool/string`, arrays, records, declarations `const/let`, control flow (`if`, `while`, `for`), simple module resolution, enum/Result/Option lowering and conservative runtime memory management. Compile-time annotations, dynamic interfaces, rich generics, MCP server and aggressive OIM optimizations are NOT necessary for the earliest self-host.

`Result` and `Option` may be intrinsically supported while generics are still incomplete; their final public semantics must remain consistent.

## Milestones

M0 language sketch and shared AST contracts; M1 Stage 0 compiles golden tests; M2 self-hosted Orin compiler source; M3 Stage 2+3 bootstrap; M4 typed memory IR + independent verifier; M5 classes/annotations/modules hardening; M6 stdlib/MCP; M7 backend optimization; M8 verified-core milestones.

## Practical parallel-agent coordination

One lead architect owns grammar, IR, runtime API and integration gate. Independent agents own parser, checker, codegen, runtime, self-hosted frontend and tests. Merge behind shared interfaces and continuous goldens; don't let agents silently broaden syntax or invent noncanonical alternatives. Proof development proceeds in parallel and may take substantially longer than the bootstrap.
