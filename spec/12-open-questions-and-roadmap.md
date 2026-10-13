# 12 — Open Questions and Decisions Log

## Resolved (do not revisit without an RFC)

- Language name **Orin**, extension `.or`, CLI `orin`; prior working title Nivra is obsolete.
- Only `const` and `let`; no `var`.
- Human-readable TS-like syntax, no full JS semantics; classes allowed, lowered to functions + data.
- Java-like compile-time annotations; no default runtime reflection/proxies.
- Module boundaries enforced via `module.or` and DAG dependencies.
- Standard `Result`/`Option`, no `null`/`undefined`, canonical `?` error propagation.
- `int=i64`; `float=f64`; signed/unsigned widths and native-size `isize`/`usize`.
- Conservative, compiler-managed OIM memory model without source borrow syntax or mandatory tracing GC.
- Mathematically founded memory safety is a formal goal; native artifacts require a larger trust argument.
- Target: self-hosting and native performance competitive with Go/Rust.
- Built-in MCP-based compiler introspection and targeted verification.

## Resolved 2026-10-13 (implementation ADRs)

- Interfaces: nominal, `implements`; bounds (static) and interface-typed values (explicit dynamic dispatch) — ADR-0016.
- String interpolation: TypeScript template literals, primitives only — ADR-0016.
- Class mutability: mutating methods inferred; mutability part of the public API snapshot — ADR-0009.
- Closures: capture by value, immutable captures — ADR-0011.
- Concurrency: isolated tasks, send = move-or-copy, structured `scope`, no shared mutable memory — ADR-0017.
- Language 1.0 core scope and freeze — ADR-0016.

## Priority OPEN decisions

1. **Precisely define observable value identity.** Are ordinary classes exclusively values, and how do resources/actors expose identity? No hidden Java reference semantics.
2. **Function parameter and closure semantics.** Copy/retain/consume internal semantics, captures, equality, deterministic destruction and effects.
3. **Class mutability syntax.** Define whether `this` mutation requires `let` receiver only and how it lowers to value replacement.
4. **Interfaces.** Nominal vs structural conformance and explicit dynamic dispatch; avoid trait-style complexity.
5. **Async concurrency.** Structured tasks, message passing, failure/cleanup and predictable `Result` behavior.
6. **Resource types.** Scope APIs, non-copyable handles, FFI and opaque identity; prove escape restrictions.
7. **Cycle control.** Formal DAG invariant for owning object references, Graph ID semantics, behavior under graph cloning.
8. **Type errors and numeric literals.** Overflow trapping, float-rounding and `Result` error upcasting.
9. **Annotation language.** Typed AST APIs, expansion termination, hygiene and source maps.
10. **Grammar finalization.** Lambda, constructor, enum, generic syntax and precedence ambiguity; semicolon policy.
11. **Compiler proof boundary.** Which OIM instructions can be checked independently, and how much codegen is in the TCB?
12. **Platform/ABI model.** ARM64/x86-64, Windows/macOS/Linux, `usize` layouts, native interop.
13. **Packages.** Dependency resolution, lockfile, reproducibility and security review.
14. **Trademark/extensions.** Check name `Orin`, CLI collisions, `.or` file associations before external launch.

## Roadmap / proposed release gates

- **0.0 bootstrap:** frozen syntax subset; host-compiler -> C; basic examples.
- **0.1 self-host:** compiler written in Orin; reproducible Stage 2/3 tests, minimal std/core.
- **0.2 type/memory:** conservative RC, OIM IR, verifier prototype, independent differential testing.
- **0.3 modules/classes:** enforce module APIs, lower simple classes, preserve value semantics.
- **0.4 annotations:** built-ins + bounded typed code generation, safe static DI.
- **0.5 agent tooling:** `orin mcp`, incremental checks, symbol inspection, compact diagnostics.
- **0.6 optimized memory:** verified reuse, selective region inference, improved native codegen.
- **1.0 candidate:** comprehensive conformance, clear memory-safety proof status and TCB disclosure, measured competitive performance. Do not advertise formal end-to-end safety until established.

## Acceptance tests (minimum examples)

- Every safe array access is guarded or proven in range.
- `const b = a; a.update()` (where `a` is `let`) leaves `b` unchanged.
- Mutation through `const` receiver fails type checking.
- Compile-time annotation expansion cannot create unchecked memory operations.
- External imports into a private module implementation are rejected.
- Module cycle is rejected.
- Type errors from `Result` propagation are correctly reported.
- A graph stale ID fails safely, never dereferences freed memory.
- Self-hosting Stage 2/3 is repeatable, under a deterministic build contract.
