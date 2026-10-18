# ADR-0016: Language 1.0 core scope ("feature complete") and open-point decisions

Status: accepted (2026-10-13). After the core is complete the language surface is **frozen**
(only bug fixes and ADR-approved additions) and work shifts to optimisation and provability.

**Amendment (2026-10-13): two-stage freeze** (decided with the project owner).
1. **Language freeze:** taken as soon as integers, interpolation, `@Test`/`@Deprecated`/`@Inline`,
   resources and generic classes are in. From then on, syntax and semantics change only through
   an ADR, and the compiler rewrite (ADR-0015) starts.
2. **std I/O freeze:** taken after capabilities (ADR-0021). Until then `std:fs`, `std:process`,
   `std:io` and `std:time` are marked *unstable*. Capabilities may change their signatures; that is
   library API, not syntax. Any syntax capabilities need goes through an ADR, like every
   post-freeze change.

**Amendment (2026-10-18): the 1.0 scope as of the syntax and std freeze** (decided with the project owner, roadmap D2 and D5; one amendment
for everything below, and the rows of the tables that it changes point back here).
1. **Collections (ADR-0034):** `Eq`/`Ord`/`Hash` constraints are in the 1.0 core, with the frozen std collections `Set<T extends Hash>`,
   `OrderedMap<K extends Ord, V>`, `MinHeap<T extends Ord>` plus `IntSet`, `StringSet`, `SortedMap<V>`, `SortedStringMap<V>` and
   `PriorityQueue<T>` under their current names (ADR-0034, Decision 2026-10-18).
2. **Generic methods and `void` as a type argument (ADR-0040) are in the 1.0 core and implemented**, not post-1.0. The only generic-method
   restriction left is that an *interface* method cannot be generic (E0460). Multiple bounds `T extends A & B` are accepted.
3. **User annotations and pure processors** (ADR-0046) are in scope and implemented (see the Annotations row).
4. **`std:task` is in the core at the Gate 1 surface** (roadmap D1): `scope`, `s.spawn`, `join`, channels, timed waits, `select`,
   `sleep`, cancellation and `spawnNet`. Additions beyond it are experimental ([stability](../stability.md)).
5. **HTTP is not post-1.0:** `std:http` (the pure HTTP/1.1 message layer, ADR-0030) is in the std and frozen; the sockets are `std:net`
   (ADR-0033). What stays post-1.0 is TLS/HTTPS and an HTTP client or server framework.
6. **"Core complete" is relaxed (roadmap D5):** 1.0 requires a self-hosted, reproducible, behaviour-stable compiler with the rows above
   implemented and tested; finishing the compiler rewrite of ADR-0015 (`compiler/vc/` and the remaining `check/` files) is **not** a 1.0
   condition. The "Definition of core complete" below is read with this clause.

## In the 1.0 core
| Area | Decision |
|---|---|
| Done | Orin-B core, modules, generics, classes (value semantics, inferred mutation), closures (by-value capture), array API, Option/Result/`?`, match |
| In progress | `float`/`f32`, `Map<K,V>`, contract clauses (parse/check/erase/runtime check) |
| **Integers** | full spec-02 set: `i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 isize usize`, `int = i64`; literals adopt expected type; explicit conversions only (`x.toI32()` … trapping, `wrapping*`/`checked*`/`saturating*` methods); overflow traps by default. **Implemented (ADR-0022)** except `i128`/`u128`, which are rejected with E0431 (64-bit slots). **Decided with the project owner (2026-10-13): 128-bit integers are post-1.0** — an additive extension, the language freeze does not wait for them. |
| **Interfaces** (OPEN #4) | **nominal**: `interface Shape { area(): float; }`, conformance declared with `class Circle implements Shape`. Two uses: (1) generic bounds `function total<T extends Shape>(xs: T[])` — static dispatch, monomorphised; (2) interface-typed values `const s: Shape = circle` — **explicit dynamic dispatch** via a vtable object; cost documented (one indirect call, one box). No default methods, no interface inheritance, no generic interfaces in 1.0 core (post-1.0). |
| **String interpolation** (OPEN) | TypeScript template literals `` `Hello ${name}, you are ${age}` ``; interpolated expressions must be `string`, integer, float or `bool` (implicit `toString` only for these); other types → error (call `.toString()` explicitly). One canonical form; `+` concatenation stays valid. **Implemented (ADR-0022)** |
| **Annotations** (spec 05) | 1.0 core ships compiler built-ins only: `@Test` (with `orin test` runner), `@Deprecated("msg")`, `@Inline`. User-defined annotation processors were post-1.0; **amended 2026-10-16 (owner decision): user-defined annotations and pure processors are in 1.0 scope, [ADR-0046](0046-typed-annotation-processors.md)**. Contract clauses are separate constructs (ADR-0012). **Done (ADR-0024, 2026-10-13):** `@Test` + `orin test` + `std:test`, `@Deprecated` (warning W0440, LSP tag, API snapshot), `@Inline` (both backends). |
| **Resources** (spec 06) — **done, ADR-0025** | resource types are non-copyable handles: may be passed to functions (borrowed) but not stored in values, returned, captured by closures or put in collections; scope API `File.open(path, f => ...)` releases deterministically, also on `Err`/trap paths. `std:fs` streaming file API built on it (spelled `withFile(path, mode, f => ...)`, ADR-0025; since ADR-0027 `withFile(fs, path, mode, f => ...)` takes the file grant; `std:fs` is unstable until the owner confirms the I/O freeze). |
| **Graph<T>/GraphId<T>** | std library type (Orin) with generational, graph-tagged IDs; stale/foreign IDs → `Err` (spec 06 cycle rule). |
| **Packages** (spec 04) | `orin.toml` manifest: package name, module architecture rules (`allowed_dependencies`), entry point; `orin build`/`check` from a package root. No registry/versions in 1.0 core (post-1.0). |
| **std** | `std:fs`, `std:process`, `std:io`, `std:math`, `std:path`, `std:time`, `std:json` (`parse` into a `Json` union + typed helpers; codegen-based `parse<T>` needs annotations → post-1.0), `std:map`. HTTP: `std:http` exists and is frozen, TLS is post-1.0 (amendment 2026-10-18). |
| **Capabilities** (ADR-0020 D4) | language part only: unforgeable capability handles granted at the program root, boundary declarations in `orin.toml`, enforcement in the L0 platform layer; std I/O APIs take handles. Designed in ADR-0021 (pending) — the **std I/O freeze** (stage 2) waits for it, the language freeze does not. Effect inference/policy checking come after the freeze. |
| **Generic classes** | `class Box<T> { ... }`, monomorphised like generic functions (ADR-0007), with bounds `T extends I` (ADR-0019). Needed for `Graph<T>`/`GraphId<T>`. **Implemented (ADR-0026)**: bounds, `implements`, nesting, contracts, cross-module; generic methods were E0460 at the time and are in the core since ADR-0040 (amendment 2026-10-18; only interface methods stay E0460); `std:graph` is rewritten on `class Graph<T>`. |
| **Concurrency** | **designed now** (ADR-0017), implemented after the core freeze but before 1.0 final. |

## Explicitly post-1.0
~~User annotation processors/codegen~~ (moved into 1.0 scope by ADR-0046), generic interfaces, default
methods, `Shared<T>` (atomic RC) values, async/await syntax, package registry/versioning, TLS/HTTPS,
incremental analysis engine, `i128`/`u128` (additive; E0431 until then), inheritance (never planned).

**Bit operators — post-1.0, reserved now** (decided with the project owner, 2026-10-13). `&`, `|`,
`^`, `~`, `<<`, `>>` on integers are an additive extension (today they are errors on numbers, so no
program can change meaning). Reserved semantics so nothing else claims these tokens:
- integer operands only, same type on both sides (no implicit width mixing, like `+`);
- shifts by a negative amount or by >= the bit width **trap** (no C-style undefined behaviour);
  `>>` is arithmetic on signed, logical on unsigned types;
- `|` keeps its meaning in type position (unions), `&` stays reserved in type position for
  the bound separator of `T extends A & B` (accepted since ADR-0040's multiple-bounds addendum);
- the lexer never produces a `>>` token in type context (`Box<Box<int>>`, ADR-0026); a shift
  operator, when added, is recognised in expression context only.

## Definition of "core complete"
All rows above implemented with conformance tests (default + `tests/next`), formatter/LSP/MCP
support, both backends, verifier-clean, documented in `docs/` and reflected in the spec files;
and the compiler itself rewritten per ADR-0015 (relaxed by the amendment of 2026-10-18: the rewrite is not a 1.0 condition).
