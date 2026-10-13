# Orin — Language Specification

**Status:** Design RFC / pre-implementation specification (v0.1)  
**Source extension:** `.or` · **CLI:** `orin` · **Package/spec folder:** `spec/`  
**Motto:** Native. Safe. Simple.

Orin is an AI-first, human-readable, statically typed, ahead-of-time compiled language. It takes its surface syntax and everyday APIs from TypeScript/JavaScript but deliberately avoids JavaScript semantics and TypeScript's Turing-complete type-level programming. The compiler is intended to be self-hosted in Orin.

## Normative language

- **MUST**: required design invariant.
- **SHOULD**: strongly preferred unless justified by benchmark or proof.
- **MAY**: optional or future addition.
- **OPEN**: not yet decided; implementations must not silently invent a public guarantee.
- **PHASE**: implementation milestone, not a weakening of the eventual semantics.

The files in this folder collectively form the design contract:

| File | Subject |
|---|---|
| `01-syntax-and-grammar.md` | Lexical rules, expressions, declarations and EBNF subset |
| `02-types-and-errors.md` | Types, integers, floats, generics, `Option`/`Result` |
| `03-values-classes-interfaces.md` | Value semantics, classes, methods, interfaces, mutability |
| `04-modules-and-packages.md` | Mandatory module boundaries, imports, architecture rules |
| `05-annotations-and-metaprogramming.md` | Java-style annotations without runtime reflection |
| `06-memory-model-oim.md` | Ownership inference, optimized RC, regions, reuse, resource lifetime |
| `07-formal-safety.md` | Memory-safety theorem goals, verifier, trusted computing base |
| `08-standard-library.md` | JavaScript-familiar APIs with strict Result/Option contracts |
| `09-compiler-self-hosting.md` | Compiler pipeline, bootstrap stages, conformance tests |
| `10-mcp-and-agent-tooling.md` | Compiler-integrated MCP, diagnostics and token efficiency |
| `11-performance-and-benchmarks.md` | Rust/Go performance objective and measurement protocol |
| `12-open-questions-and-roadmap.md` | Unresolved tradeoffs, implementation phases, release gates |
| `13-research-references.md` | Primary research and links; scope of evidence |

## Decided principles

1. **Human-readable, agent-efficient:** TypeScript-like syntax, a canonical way to express common operations, no artificial code-golf syntax. Measure *total tokens until a tested correct solution*, not source tokens alone.
2. **Native AOT:** Produce native executables without a JavaScript VM or mandatory tracing GC. A small runtime is allowed.
3. **Self-hosted:** The production compiler MUST be written in Orin and able to compile its own source. Bootstrap tooling may temporarily be written in another language.
4. **Mathematically grounded safety:** Safe Orin MUST have a formally specified memory model with mechanically checked proofs as a long-term release requirement. A proof of an IR is not automatically proof of machine-code correctness.
5. **No visible borrow checker:** Normal code has no lifetime/borrow/move/free annotations. The compiler internally manages ownership and memory.
6. **Simple declarations:** Only `const` and `let`. `var` is illegal. Declarations require an initializer. Variables are block-scoped, with no hoisting.
7. **Constrained static types:** Records, classes, enums/tagged unions, arrays, simple parametric generics, interfaces and local inference; no `any`, `null`, `undefined`, conditional/mapped/template-literal type programming.
8. **One error convention:** `Option<T>` for absence and `Result<T,E>` for fallible operations. Propagation uses postfix `?`; no unchecked exceptions as a standard-language feature.
9. **Classes are sugar over data + methods:** Class methods lower to explicit functions and data; default semantics are values, not shared mutable Java-style reference identity. No class inheritance in the initial language.
10. **Annotations work at compile time:** Java-style `@Annotation(...)` syntax; generated code is checked and analyzed like handwritten code. No required runtime reflection/proxy framework.
11. **Modular by construction:** Explicit module API boundaries, private-by-default internal declarations, no cross-module imports of private implementation files; module dependencies form a DAG.
12. **Familiar standard APIs:** Prefer JS/TS-familiar names (`map`, `filter`, `find`, `split`, etc.) with Orin's strict semantics.
13. **Built-in MCP integration:** `orin mcp` exposes compact diagnostics, symbol inspection, refactoring, tests and builds; the MCP and LSP integrations share compiler services.
14. **Performance target:** Strive for application performance broadly between optimized Go and Rust on *defined comparable workloads*. No unconditional guarantee or published measurement exists yet.

## Explicit boundaries

- **Not all allocation is compile-time:** Runtime-size data allocates at runtime; the compiler can plan ownership/lifetime and optimize allocation and release.
- **Reference counting alone does not collect cycles:** Ordinary owning values MUST not form cycles; safe graph/arena abstractions MAY use checked generational handles.
- **Compile-time annotations are not automatically free:** Generated handlers, validators and codecs do work at runtime, although dynamic reflection overhead can be avoided.
- **`const`/`let` control bindings and visible mutation, not heap placement.**
- **Unsafe/FFI is a separate, minimal trusted boundary**, not part of ordinary safe code.

## Initial compilation strategy

Freeze a small bootstrap subset first: functions, primitives, strings, arrays, records, basic control flow, modules, and `Result`/`Option` handling. Generate portable C in Stage 0; implement Stage 1 in Orin; obtain Stage 2 and Stage 3 by compiling the compiler with itself; verify determinism and conformance. Build a proof-oriented memory IR and verifier independently of codegen. Classes and annotations should lower to this kernel, not enlarge its proof obligations unnecessarily.

## Definition of maturity

- **Prototype:** Can compile samples; not formally proven memory-safe.
- **Self-hosting alpha:** Can compile itself and passes differential/bootstrap tests; still not formally verified end-to-end.
- **Verified-core beta:** Core semantics and memory IR checker have mechanized safety proofs; codegen/runtime remain identified trust assumptions.
- **Verified release (aspirational):** Specified trust boundary and end-to-end safety argument, including backend/runtime validation, have been established.

Read `12-open-questions-and-roadmap.md` before treating any illustrative code in this spec as accepted syntax.
