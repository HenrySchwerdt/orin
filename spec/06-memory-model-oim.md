# 06 — OIM: Orin Inferred Memory

## Goals and non-goals

OIM is compiler-managed memory **without source-level borrow/lifetime annotations, mandatory tracing GC, or manual `free` in normal code**. Memory allocation itself still happens at runtime when data sizes/paths depend on input. Target optimized native speed, while retaining mathematical memory-safety invariants.

OIM combines: (1) value semantics, (2) ownership/liveness and escape inference, (3) stack/region placement where proved valid, (4) precise optimized reference counting for dynamically shared values, (5) uniqueness tests and allocation reuse / copy-on-write, and (6) a small trusted runtime for resources and concurrency.

## Canonical source semantics

Ordinary records, arrays and classes are logical values. `const b = a` creates a logical snapshot. The compiler may share immutable data. `a` can be locally mutated only through `let`; if aliases to the old value exist, they MUST keep observing the old value. An optimized in-place update is legal only when the target is uniquely owned or the optimizer proves all other references unobservable.

```typescript
let a = new Counter(0);
const b = a;
a.increment();
// a.value == 1; b.value == 0
```

## Compiler-side memory operations

Illustrative core operations:

```text
allocate(type, fields) -> owner
retain(owner) -> shared_owner
release(owner) -> ()
reuse_unique(owner, replacement_fields) -> owner
enter_region() -> region
region_alloc(region, value) -> handle
leave_region(region)
```

These are NOT available as safe-source operations. An independently verified IR checker checks correct use. RC correctness must account for locals, fields, temporaries, parameter passing, exceptional/early returns and concurrent transfer.

## Placement strategy

| Proof/usage property | Candidate allocation strategy |
|---|---|
| Non-escaping scalar/value | Register or stack |
| Many objects with common bounded lifetime | Region/arena |
| Escape with unique owner | Unique heap, deterministic release/reuse |
| Dynamically shared immutable value | Optimized RC |
| Logically mutated shared value | Copy-on-write or new allocation |
| Cyclic graph | Dedicated graph owner with safe generational IDs |

**Important:** Region inference must not permit references to outlive their region. Region optimization must not create unbounded retention. RC counts and runtime uniqueness checks can carry overhead; this is a performance research problem, not a proved universal win.

## Cycles

No owning cycles in ordinary values. Cyclic graph structures use `Graph<T>` / `GraphId<T>`-style APIs where a graph owner holds the nodes, and edges are checked non-owning IDs. Node IDs require generation + graph identity checks so stale or cross-graph handles fail safely. Releasing the last graph owner can free all nodes regardless of edges. `Graph` operations use `Result` for invalid IDs.

## Concurrency

No unrestricted mutable aliasing across tasks. Prefer isolated tasks, actors and message passing. Immutable sharing may use atomic RC, ownership transfer, or copying as proven safe. Actors/resources are distinguished from duplicable plain values. Race freedom requires a formal concurrency model and a verified or trusted runtime scheduler/atomics layer.

## External resources

Files, sockets, locks and DB connections are *resource handles*, not duplicable value classes. Scope-based APIs such as `File.use(path, callback)` ensure deterministic cleanup even upon `Err`. Resource escape is statically rejected or guarded by opaque trusted handles; finalizers are not a substitute for deterministic release.

*Realisation (ADR-0025):* `File` is a resource type that exists only as a function parameter; the scope API is
`withFile(fs, path, mode, f => ...)` of `std:fs` (callback receives the handle as its parameter, release on every path);
escape is rejected by the checker (E0450/E0451/E0452) and, independently, by the MIR verifier (`MHandle`).
*Capabilities (ADR-0021 Stage A, ADR-0027):* the grants that authorise I/O (`Host`, `FsGrant`, ...) are resource handles with
exactly these rules; the `fs` argument above is one.

## Safety invariants (proof targets)

1. Every accessed object is allocated, live and properly typed.
2. Each owning reference is counted exactly (or accounted for by an equivalent proven unique/region invariant).
3. No object is released while any valid owning reference requires it.
4. A release cannot run twice on the same ownership unit.
5. Region references cannot escape region lifetime, except through safe copying/promotion.
6. Reuse only occurs where there are no observable aliases to the old value.
7. Safe concurrency cannot read/write unsynchronized shared mutable memory.
8. Any bounds failure/overflow/OOM yields specified safe failure, never UB.

## Implementation sequence

Start with a conservative RC scheme, then add verified optimizations: retain-release cancellation, borrow-like internal transfer (not source syntax), uniqueness reuse, escape analysis, and selective regions. Each optimization MUST pass IR verification and differential semantic testing. For native backends, preserve invariants through codegen or clearly enumerate backend assumptions.

## Background

Perceus (Reinking et al., PLDI 2021), region inference (Tofte & Talpin), and Lean 4/Koka implementation techniques motivate this architecture. They do **not** constitute a proof of the Orin hybrid model; that proof must be developed.
