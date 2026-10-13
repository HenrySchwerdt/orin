# ADR-0016: Language 1.0 core scope ("feature complete") and open-point decisions

Status: accepted (2026-10-13). After the core is complete the language surface is **frozen**
(only bug fixes and ADR-approved additions) and work shifts to optimisation and provability.

## In the 1.0 core
| Area | Decision |
|---|---|
| Done | Orin-B core, modules, generics, classes (value semantics, inferred mutation), closures (by-value capture), array API, Option/Result/`?`, match |
| In progress | `float`/`f32`, `Map<K,V>`, contract clauses (parse/check/erase/runtime check) |
| **Integers** | full spec-02 set: `i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 isize usize`, `int = i64`; literals adopt expected type; explicit conversions only (`x.toI32()` … trapping, `wrapping*`/`checked*`/`saturating*` methods); overflow traps by default |
| **Interfaces** (OPEN #4) | **nominal**: `interface Shape { area(): float; }`, conformance declared with `class Circle implements Shape`. Two uses: (1) generic bounds `function total<T extends Shape>(xs: T[])` — static dispatch, monomorphised; (2) interface-typed values `const s: Shape = circle` — **explicit dynamic dispatch** via a vtable object; cost documented (one indirect call, one box). No default methods, no interface inheritance, no generic interfaces in 1.0 core (post-1.0). |
| **String interpolation** (OPEN) | TypeScript template literals `` `Hello ${name}, you are ${age}` ``; interpolated expressions must be `string`, integer, float or `bool` (implicit `toString` only for these); other types → error (call `.toString()` explicitly). One canonical form; `+` concatenation stays valid. |
| **Annotations** (spec 05) | 1.0 core ships compiler built-ins only: `@Test` (with `orin test` runner), `@Deprecated("msg")`, `@Inline`. User-defined annotation processors are **post-1.0**. Contract clauses are separate constructs (ADR-0012). |
| **Resources** (spec 06) | resource types are non-copyable handles: may be passed to functions (borrowed) but not stored in values, returned, captured by closures or put in collections; scope API `File.open(path, f => ...)` releases deterministically, also on `Err`/trap paths. `std:fs` streaming file API built on it. |
| **Graph<T>/GraphId<T>** | std library type (Orin) with generational, graph-tagged IDs; stale/foreign IDs → `Err` (spec 06 cycle rule). |
| **Packages** (spec 04) | `orin.toml` manifest: package name, module architecture rules (`allowed_dependencies`), entry point; `orin build`/`check` from a package root. No registry/versions in 1.0 core (post-1.0). |
| **std** | `std:fs`, `std:process`, `std:io`, `std:math`, `std:path`, `std:time`, `std:json` (`parse` into a `Json` union + typed helpers; codegen-based `parse<T>` needs annotations → post-1.0), `std:map`. HTTP is post-1.0. |
| **Concurrency** | **designed now** (ADR-0017), implemented after the core freeze but before 1.0 final. |

## Explicitly post-1.0
User annotation processors/codegen, generic interfaces & bounds beyond single interfaces, default
methods, `Shared<T>` (atomic RC) values, async/await syntax, package registry/versioning, HTTP,
incremental analysis engine, inheritance (never planned).

## Definition of "core complete"
All rows above implemented with conformance tests (default + `tests/next`), formatter/LSP/MCP
support, both backends, verifier-clean, documented in `docs/` and reflected in the spec files;
and the compiler itself rewritten per ADR-0015.
