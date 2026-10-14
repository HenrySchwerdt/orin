# ADR-0038: Performance model — inferred allocation and invariant-driven optimisation

Status: accepted (2026-10-14, project owner). Related: ADR-0017 (concurrency, isolated tasks),
ADR-0030 (R3 object model in Orin), ADR-0031 §E (contract-driven optimisation), ADR-0032
(translation validation), ADR-0035 D4 (check elimination needs a matching proof), ADR-0036
(verifier fragment), spec 19, `docs/benchmarks.md`.

## Context

Orin compiles value semantics to reference counting (RC) with copy-on-write (COW). Measured
before this ADR, it is 1.4–2.7x slower than C and between 0.27x and 1.65x of Go on the seven
kernels in `docs/benchmarks.md`. The overhead comes from:
- RC traffic when values are passed around;
- COW uniqueness checks;
- per-object headers;
- boxed fields (a `u8` array element takes 8 bytes);
- checked arithmetic and bounds checks;
- one heap allocation per object.

The compiler knows facts a C compiler does not:
- no aliasing (value semantics plus the ownership verifier);
- no null and no exceptions;
- purity and effects;
- proved contracts.

**Principle (project owner):** developers write ordinary TS-like code with classes, arrays and
maps. There is **no user-facing `Arena<T>`, `SlotMap<T>` or lifetime concept**. The compiler
chooses the representation, and invariants — which people write for correctness anyway — are
the lever that unlocks the fastest one.

## Decision

### 1. Allocation is chosen per allocation site by the compiler

| The value… | Allocation |
|---|---|
| does not escape the function | stack |
| lives until the end of a known scope (function call, request handler, compiler phase, task) | that scope's **region**: bump allocation, no per-object free, freed in one step at scope end |
| lives until program end and is never mutated after construction | **immortal**: RC operations become no-ops |
| anything else, or not provable | **RC heap**, as today (the safe fallback; a region never grows unbounded) |

- **Regions need no annotations.** A value that leaves a region is copied out at the boundary,
  or moved if unique. Value semantics makes this always safe, so Orin needs no lifetimes,
  unlike Rust or Cyclone.
- **Per-task heaps** (ADR-0017): each task allocates in its own region and frees it as a whole
  at the end of the task.
- **Allocator:** first a fast size-class allocator per thread (mimalloc-style) for the RC heap.

### 2. RC and copy elimination

- **Borrow inference:** a function or method that only reads a value borrows it, so there is no
  retain or release. This removes most RC traffic on long-lived data.
- **Reuse in place** (Perceus-style): when a value is unique and dead after an operation, its
  memory is reused for the result. There is no allocation and no copy.
- **Freeze after construction:** a value that is built once and then only read becomes one
  immutable shared region. Reads need no COW check, and RC applies to the whole region, not to
  each object. This is also the basis for `Shared<T>` between tasks.
- **Uniqueness:** a COW check is hoisted out of loops, or removed where uniqueness is proved.
- Value semantics cannot create cycles, so there is no cycle collector and no `weak`.
- **Closure inlining and fusion** (project owner, 2026-10-14): an arrow function passed directly to an array API
  method is inlined at that call, so there is no closure object and no indirect call per element. A chain of
  `filter`/`map`/`find`/`some`/`every`/`reduce` with pure closures is fused into one loop with no intermediate
  arrays. This is what Java streams give, without a `Stream<T>` type. Purity is a guaranteed fact, so fusion is
  sound; the differential tests and translation validation (ADR-0032) cover it. Baseline before this step:
  `filter → map → reduce` over 5 M ints is about 4x slower than the equivalent loop.

### 3. Layout

- **Unboxing:** scalars and records are stored inline, a `u8` takes 1 byte, and a field is
  narrowed when a proved range allows it.
- **Small strings** are stored inline.
- **Header compaction:** count and type share 8 bytes, and region objects have no header.
- A size-bounded array is stored inline; an `Option` field is stored without a tag when an
  invariant proves it is `Some`.

### 4. The arena pattern without an arena type

A class that owns arrays of records and refers between them by index *is* an arena:
```ts
class Network {
  nodes: Node[] = [];
  edges: Edge[] = [];   // Edge { from: usize, to: usize }
  @Invariant(this.edges.every(e => e.from < this.nodes.length && e.to < this.nodes.length))
}
```
- **Storage and updates:** the records are stored contiguously, and updates happen in place
  because the class has one owner.
- **Checks:** the invariant proves that every index is valid, so the bounds checks disappear.
- **Deleted entries:** when entries can be deleted and stale indices are possible, a lookup
  yields an `Option`, as `Map.get` does. An invariant "all stored ids are live" removes that
  check too.
- **Graphs:** `Graph<T>` stays an ordinary collection.

### 5. Fact-driven code generation (ADR-0035 D4)

Only **guaranteed** facts are passed to the backend. That means language guarantees and
`VERIFIED` proofs, never `TESTED_ONLY` or `ASSUMED`, because a wrong backend fact is undefined
behaviour.

| Fact | LLVM (C backend) |
|---|---|
| unique value, no aliasing (after R3/R4) | `noalias` (`restrict`) |
| pure function (purity analysis) | `memory(none)`/`readonly`, `willreturn` (`pure`/`const`) |
| no exceptions | `nounwind` |
| no null, values always initialised | `nonnull`, `dereferenceable`, `noundef` |
| proved integer range | `range` metadata, `nsw`/`nuw` |
| proved index bound | `inbounds`, no check |
| proved precondition | `llvm.assume` (`__builtin_assume`) |
| immutable data | `!invariant.load` |
| proved `@Decreases` | `mustprogress` |
| distinct types | TBAA metadata |

Every emitted fact, and every removed check, names the proof obligation that justifies it in
the assurance report. Each optimisation is covered by translation validation (ADR-0032) or by a
proof.

### 6. Developer experience: visible, not required

- **No new syntax:** the language core is frozen.
- **LSP hover** shows how a value is treated: "stack", "region: request", "immortal",
  "borrowed", "frozen" or "heap".
- **Performance lint:** for hot loops it shows the remaining RC traffic, copies and checks, and
  the invariant that would remove them. Example: *"3 bounds checks remain in `route()`; adding
  `@Invariant(...)` lets the compiler prove and remove them."*
- When the compiler cannot prove something, it falls back to the safe representation. That is
  correct, only slower, and the lint says where and why.

### 7. Measurement

- `docs/benchmarks.md` adds **Java** and **Rust** next to Go and C, plus a server workload
  (HTTP + JSON) and an allocation-heavy workload.
- Each step is measured before and after. Expectations stay estimates until measured.

### 8. Backends: C as the base, LLVM for release (project owner, 2026-10-14)

- **The C backend stays the base:**
  - it is the seed bootstrap and the fixed point `stage2.c == stage3.c`;
  - it is the trust chain of ADR-0032: CompCert and diverse double compiling need C;
  - it is what the sanitizers, CBMC and valgrind work with;
  - it is the fallback on any machine without LLVM.
- **LLVM becomes the default for `orin build --release`** once all three gates hold:
  1. **Performance:** the benchmark action (`.github/workflows/bench.yml`) shows the LLVM backend at least on
     par with the C backend on every benchmark, judged by instruction counts. Known outliers such as `fib`
     (about 0.89 s LLVM against 0.54 s C, measured under load) are root-caused and fixed first. The
     suspect is how checked arithmetic is lowered.
  2. **Fixed point:** the LLVM backend also reproduces itself, `stage2.ll == stage3.ll`, in CI.
  3. **Toolchain:** a pinned LLVM version is used, as described below.
- **Toolchain: pinned, not bundled into the compiler.**
  - Orin keeps emitting textual LLVM IR, but only for **one pinned LLVM version**. The pin is recorded in the
    repository and checked in CI.
  - `orin toolchain install` downloads the matching `clang`/`llc` into `~/.orin/toolchains/llvm-<version>`,
    verified by checksum. The release packages may also include it.
  - `orin doctor` reports the installed version and whether it matches.
  - Without a matching LLVM, `--release` falls back to the C backend and says so.
  - Rust links LLVM in-process through its C++ API. Orin does not, because that would need an FFI from
    Orin to the LLVM C API, add more than 100 MB to the package, and put all of LLVM into the trusted
    base of the self-hosted compiler. It is reconsidered only if parsing the textual IR becomes a measured
    bottleneck of build time.
- **Why LLVM for release:** the fact-driven code generation of §5 (`noalias`, `nonnull`, `range`,
  `llvm.assume`, `!invariant.load`, TBAA) is expressed directly in LLVM IR. In C it is only approximated by
  `restrict` and `__builtin_assume`. Most gains from proved invariants therefore land in the LLVM backend.
- **Later, after 1.0:** a fast non-optimising backend for debug builds, in the spirit of Cranelift or Go's
  compiler, if build times call for it.

## Order

1. **Now:**
   - the fast allocator;
   - `nounwind`, `nonnull`/`noundef`, TBAA and purity attributes;
   - the defects being fixed now (`s = s + t`, result pairs, bulk byte conversion);
   - closure inlining and fusion of array API chains (§2);
   - Java and Rust in the benchmarks;
   - the LLVM backend: root-cause the outliers against the C backend (§8, gate 1), the LLVM
     fixed point (gate 2), and the pinned toolchain with `orin toolchain install` (gate 3).
     Then LLVM becomes the release default.
2. **With the verifier results (ADR-0036):** `nsw`/`nuw`, `range` and `llvm.assume` from
   `VERIFIED` facts; check removal and hoisting; the performance lint.
3. **With the lowering rewrite and R3:** borrow inference, immortals, stack allocation,
   unboxing, reuse in place, header compaction.
4. **With concurrency (ADR-0017):** per-task and per-scope regions, freeze/`Shared<T>`, and
   `noalias` (with R4 proofs).

## Proof obligations

Every technique changes the memory model, so each is checked by the independent MIR ownership
verifier and added to the Lean model (ADR-0032):
- borrows and immortals are small extensions of the RC machine;
- regions are a heap partition, where freeing is valid because nothing outside points in, which
  copy-out at the boundary guarantees and the verifier checks;
- reuse in place is a refinement of release-then-allocate.

## Honest limits

- RC remains for genuinely shared, long-lived, mutated data without a provable owner.
- Allocation-heavy code with many short-lived small objects is where a generational GC (Java)
  is strongest. Regions and reuse are how Orin competes there.
- Inference can be imprecise. The fallback is always the RC heap, never unsafety.
- Expected ratios, to be verified by measurement:
  - array and numeric code 1.0–1.2x of C;
  - strings and maps 1.1–1.3x;
  - object-heavy code 1.2–1.5x.

<!-- Future performance addendum: proof-guided memory representations, alias/escape analysis, stack/region/unboxing, safe RC/COW fallback, packed buffers, and benchmark gates. -->
