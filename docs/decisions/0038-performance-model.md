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

  **Implementation status (closure inlining and fusion, 2026-10-14): done** in `compiler/fuse`, a HIR → HIR pass between
  the checker and the lowering, run by the optimising pipeline of both backends (`--no-opt` and `--no-fuse` skip it).
  - *Fused:* any number of `map` / `filter` stages ended by `map`, `filter`, `reduce`, `some`, `every`, `find`,
    `findIndex`, `forEach`, `includes` or `indexOf`, when every function is an arrow function or a named function at the
    call and pure (`check/purity.or`). One loop, no intermediate arrays, no closure objects: a body of `let`s and one
    `return` is inlined with its parameters bound to the element, any other body is called directly with its environment
    record built once. Early exit for `some` / `every` / `find` / `findIndex` / `includes` / `indexOf`; a `map` that ends a
    chain without a `filter` allocates its result with the exact capacity (task primitive 24, `orin_array_new`).
  - *Not fused (the prelude call stays, the rest of the chain is fused around it):* a function value that is not a
    literal, an impure closure, a value argument (`reduce`'s initial value, the needle of `includes` / `indexOf`) that is
    not a simple expression, a result bound to a variable (used twice or not), `sort` (a barrier).
  - *Traps (decision):* fusion evaluates exactly the (stage, element) pairs of the unfused chain, element by element
    instead of stage by stage, so a fused chain traps if and only if the unfused one does, with the same exit status; when
    two stages would both trap, which one fires first can differ, and so can the message. Accepted, because a trap ends the
    program either way; no existing test changed. Early exit never hides a trap: when a stage before an early-exit terminal
    may trap (conservative analysis: checked integer arithmetic, an index, an unwrap, a call), the loop keeps running the
    stages after the hit without evaluating the terminal (`tests/next/run/fuse_trap_early_exit.or`).
  - *Evidence:* `tools/diff_backends.py --mode fuse` (fused vs `--no-fuse`, every run test, 0 differences) and `--mode opt`;
    `tests/next/run/fuse_shapes.or` (every shape, output equal to the unfused compiler's), `fuse_not_fused.or` (every case
    that must not be fused, with effects whose order would show a wrong fusion), `fuse_trap_early_exit.or`; the MIR ownership
    verifier runs on every fused program; `compiler/tests/fuse_test.or`. Programs without an array-API call compile to
    byte-identical code (the pass returns the program unchanged).
  - *Measured* (`bench/streams`, docs/benchmarks.md "Streams"): `filter → map → reduce` over 5 M ints, 10 times, C backend
    `-O2`: before 0.95 s wall / 0.46 s CPU against 0.27 s / 0.12 s for the loop; after 0.25 s / 0.11 s against 0.22 s /
    0.11 s: parity in CPU time.
  - *Self-compile* (callgrind, `compile compiler/main.or`, all on the same source tree): baseline compiler 41.49 G
    instructions; the new compiler with `--no-fuse` 41.52 G (+0.07 %); with fusion 41.84 G (+0.84 %). The pass itself costs
    about 20 M; the rest is the MIR ownership verifier and the optimiser working on the larger fused functions (the
    verifier's fixpoint +0.26 G). The fused chains in the compiler's own code do not pay that back yet. A follow-up is to make
    the verifier cheaper on long straight-line loops; the gate "not worse" is missed by 0.84 %.
  - *Kept for ADR-0042:* the pass returns, for every chain it saw, a `ChainInfo` (function, span, stages, parallel or not,
    fused or not and why, loops left over the data, early exit, exact capacity); `orin compile --fuse-report` prints it.
  - *Not done:* borrow inference, reuse in place, freeze after construction (the rest of this section); fusion of a chain
    through a variable that is used once; translation validation of the pass (ADR-0032).

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
     **Status (2026-10-14):** the lowering was not the cause; a trap call blocking shrink-wrapping and gcc's
     partial inlining of the recursion guard were (`fib` 1.50x C instructions, now 0.78x). 14 of 16 benchmarks are
     at or below the C backend; `appends` (+0.9 %) and `bintrees` (+0.5 %) are still above, caused by the C
     runtime being compiled by clang instead of gcc. Table and causes: docs/benchmarks.md, "Backends: ADR-0038 §8 gate 1".
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

## Addendum (2026-10-14): proof-guided memory strategy

RC/COW is Orin's **fallback representation**, not a mandate that every non-scalar remain boxed. Today most objects have a reference-counted heap header; sharing a pointer is not an immediate deep copy. Track allocations, retains/releases, uniqueness checks and actual COW copies separately.

The MIR optimizer should combine **interprocedural escape analysis, points-to/alias analysis, capture and last-use inference, mutability/effects, shape/range proofs and task reachability**. Unknown dispatch or unproved lifetimes use the safe RC/COW fallback. Facts determine which transformations are legal; a calibrated cost model selects among legal choices. Escape analysis alone is not a universal heap-versus-stack algorithm: inlining and scalar replacement may eliminate an escaping object; unbounded locals may still require heap storage.

Candidate order (not a universal cost ranking): eliminate/scalar-replace values; unbox small aggregates; stack-allocate proven non-escaping bounded objects; place scope-bound graphs into verified regions; reuse unique mutable objects in place; freeze transitively immutable long-lived graphs; otherwise use RC/COW. LLVM SROA and mem2reg may produce SSA values and registers but can spill; neither a source annotation nor a proof guarantees physical register residency.

A `u8[]` should eventually occupy one payload byte per element, rather than today's eight-byte slots; verify alignment, bounds, integer overflow, layouts and cross-task transfer. Build a direct JSON-to-packed-byte writer and bulk socket I/O, eliminating temporary number strings and byte-wise conversion, while preserving partial-write and error behavior. This is a library algorithm change, not something escape analysis invents.

Read-only globals may become frozen shared graphs **only after** safe publication, lifetime and reclamation proofs. Mutable globals require explicit synchronization, owner tasks or semantics-preserving sharding. An observable exact counter must not silently become eventually-consistent worker-local counts. Stage-0 task heaps still move or copy objects.

A future separate language/CLI decision may allow ignorable optimization hints versus **provable performance requirements** (hypothetical `@Prefer("stack")`, `@NoHeap`, `@NoCopy`); none of this syntax is implemented or approved by this addendum. Strict requirements must define transitive accounting and reject unknown proofs. No unsafe escape hatch.

Measure every pass on matched HTTP+JSON, allocation-heavy and compiler workloads: `ORIN_STATS` allocations/retains/releases/COW, RSS, instruction counts, throughput, p50/p99 latency, compilation and verification time, with Go/C/Rust comparators. Roll out packed bytes, the direct writer **and unboxing of small aggregates** (`Result`, `Option`, pairs and small records, which are 1.7M of the 3.9M allocations measured in `http_parse`); then escape/alias and stack/SROA; then R3 regions/frozen sharing; finally proof-backed LLVM metadata and check removal, which lands mainly in the LLVM backend (§8, the release default once its gates hold). C/LLVM differential, sanitizer, alias/closure/recursion, panic and self-hosting tests are required. Speedup ratios remain hypotheses until measured.

