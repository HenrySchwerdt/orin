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
  - *Not done:* reuse in place, freeze after construction (the rest of this section); fusion of a chain
    through a variable that is used once; translation validation of the pass (ADR-0032).
- **Borrow inference (class (d)), 2026-10-14: read-only copies of parameters** (`compiler/opt/borrow.or`). The lowering copies a
  reference parameter into a local (`d = dup p`, `this` of every method); that retain made the parameter *owned* (callers
  retained, the callee released). Now a copy that is only read (single definition; used only by `release`, `getfield`, `arrayget`,
  `tag`, builtins, binary operations, indirect and virtual calls and borrowed positions of direct calls) does not consume the
  parameter: the mode inference leaves it borrowed, and once the modes are final the copy becomes `d = borrow p` and its releases
  go. Default deny: any other use of the copy (move, store, return, second `dup`, mutation) keeps the old behaviour; function
  values and vtable targets keep borrowed parameters as before. No new MIR rule: a borrow of a `Param` is valid for the whole
  call (docs/mir.md). Measured in docs/perf/alloc-census.md ("After borrow inference").

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


## Addendum (2026-10-14): unboxing, step 1 (eligibility rule)

The first transformation of the performance wave, chosen by the allocation census (`docs/perf/alloc-census.md`, class (a)). The
ADR names unboxing but not its eligibility rule; this addendum fixes it. **No language-visible change**: no syntax, no new type, no
change in behaviour; the representation is the compiler's choice (§6), and the safe RC fallback stays for everything else.

**Representation.** An *unboxed aggregate* `MAgg(n)` (MIR v2.2, `docs/mir.md` "Unboxed aggregates") is n + 1 64-bit words held by
value: the tag, then the payload; a scalar slot is one word, a nested aggregate its words (flattened). No heap object, header or
reference count; passed and returned by value (`OrinV<n>` structs in C, `[n+1 x i64]` in LLVM; whether that ends in registers is
the C / LLVM ABI's decision, see the addendum above). For the ownership verifier it is a scalar: copying it is free.

**Eligibility rule** (conservative; implemented by `compiler/opt/unbox.or`, default deny). A value is unboxed when every place it
flows to — locals connected by moves, dups, borrows, call arguments and parameters, call results and returns, *one web* — satisfies:
1. **Small and scalar.** All slots are scalars (int, usize, bool, float and the fixed-width integers) or themselves unboxed; the
   whole value fits in four words (tag + three payload words). Not recursive. A slot index is a scalar in every variant or a nested
   value in every variant.
2. **Immutable, no identity.** It is only built (`IStructNew`, `INullary`, `pop` into an Option of a scalar) and read (tag, field,
   the Option / Result builtins). Any mutation of it (`this` mutation after construction: set / take / put / make-unique), any
   comparison, and any instruction the pass does not know keep the whole web boxed.
3. **Never on the heap.** It is not an array element, a slot of a boxed value, a closure capture or an interface value.
4. **Known boundaries.** Parameters and results of `main`, of closure targets and vtable entries (called through a function value,
   whose signature both sides cannot agree on) and the in/out receiver stay references.

So in scope today: `Option<T>` / `Result<T, E>` of scalars or of small scalar records, tuples / pairs and small records of scalars
(`Span`, `P { x, y }`, `PQEntry<int>`), across direct calls in both directions. Out of scope (still boxed), each a later step:
values with reference fields (`Bytes {data, start, len}`: unboxing would move the RC to the field), records stored inline in arrays
(the verifier's `LState[]`: an array layout change, ADR-0038 §3), values that reach a function value or the heap.

**The pair gap** (`opt/pairs.or`, census): the `{receiver, result}` record of an in/out call was rebuilt when its release was in
another block (`if (m.put(..))`, `Lowerer` helpers whose result is released at the function's end). The release is now rewritten
in place (to nothing, or a release of the result) when the receiver was moved out of the record.


## Addendum (2026-10-15): lever 2, field and element access code

**Status: accepted by the owner 2026-10-15 for T1-T5 and rules U1, F1, U2-U5 (T6's interval domain needs its own decision);
the `orin_stats` counters become a build-time option.** Originally a design only; no compiler code was written before approval, because the
change touches the trusted base: the MIR ownership verifier (`compiler/verify`), `docs/mir.md`, `docs/tcb.md`, the ADR-0032
translation-validation story and Lean model, and `tools/mutate_mir.py`. Same rule as the rest of this ADR: an optimisation acts
only on a fact the independent verifier re-checks (or that the language guarantees), and the RC/COW path stays the fallback. A
step whose fact cannot be established leaves the code as it is today.

### Evidence

Executed instructions against a C version of the same program (valgrind): `mutres` 10.6x, `appends` 5.0x, `pqueue` 4.8x,
`nbody` 3.7x, `sieve` 3.4x. Allocation is not the cause there (the census, `docs/perf/alloc-census.md`, class (a)/(d) work is
done). Reading the generated C and `gcc -O2 -S` of it (static counts, to be replaced by callgrind numbers in each PR):
- **`mutres` `Reader.next`** (MIR: `orin2 mir bench/mutres/main.or`, fn33) executes about 40 instructions on the fast path,
  where C needs about 5. The MIR has `makeunique l1` twice, `getfield l1.1` three times (once before the write, once after
  it, once to read back what was just stored: `l9 = getfield l1.1` follows `setfield l1.1 = l8`) and `getfield l1.0` twice.
- **`nbody` inner loop** (`main`, block `B9` of the C) executes about 200 instructions per pair, C about 55. Per pair there
  are 24 element accesses, each with its own kind check and bounds check, of which only 14 are distinct (array, index) pairs:
  `m[j]` and `m[i]` are read three times each, and each of the six `v?[k] -= e` is an `arrayget` followed by an `arrayset`
  (`orin_array_at`, then `orin_array_slot_ptr`) on the same index. Six `makeunique` precede the six stores, on arrays that are
  `Unique` since `IArrayNew`.
- **`sieve`** marking loop: `makeunique l1; arrayset l1[l3] = 0` every iteration, on an array that is `Unique` from the
  first `makeunique` before the loop.
- **`pqueue`** `push` (fn84): `makeunique l3` six times in the entry block and three times per sift step, after `takefield` /
  `putfield` which keep `l3` `Unique`. `makeunique l26` on the *taken* array is a different case and stays (below).
- **`appends`** is dominated by `orin_str_append` and the array extend in the runtime; the access code is a small part.

What the runtime does for each of these (`runtime/orin_runtime.h`):
- `orin_make_unique` (:260) tests `rc == 1`, and bumps `orin_stats.cow_inplace` (a thread-local add; the counters are always
  compiled in, :183-208).
- `orin_chk_slot` (:371) and `orin_array_at` / `orin_array_slot_ptr` (:471, :478) check the object kind and the bound on every
  access, because MIR has no types (docs/mir.md "Not checked": slot index bounds, tags).
- `orin_mir_struct_replace` / `orin_mir_array_replace` (`runtime/orin_runtime_mir.h:27`, `:46`) test `refmask` / `is_ref` at run
  time to decide whether to release the old value, though the stored operand's type is known statically. The store goes
  through a `uint64_t *`, so the C compiler must assume it may alias `len` / `nslots` and reloads and re-checks afterwards.

What already exists to build on:
- `KUnique` after `IMakeUnique`, `IStructNew`, `IArrayNew` (`verify/rules.or:862, 889-899, 927`); `needUnique` (:366) guards
  every store, take and put; `demote` (:466) and docs/mir.md:342 demote a `Unique` argument of a call with a reference result.
- Borrows die on a store or `IMakeUnique` of their root (`store` :581, `IMakeUnique` :889). So a `Borrowed` local that is
  still live proves its slot did not change, with no new rule.
- After a call of an `inout` function the receiver is redefined `Owned`, never `Unique` (`rules.or:802-812`, docs/mir.md:168).
  That is why every mutating method starts with its own check.
- The optimiser already replays the verifier's states (`opt/calls.or:22` imports `Transfer`, `blockInStates`, `KUnique`),
  and `passKept` (`opt/wellformed.or:122`) pins the order of calls and builtins.
- `tools/mutate_mir.py` already has `drop-makeunique` and an independent Python uniqueness dataflow (`certainly_unique`, :324)
  that classifies a dropped redundant `makeunique` as BENIGN (:391).

### Guardrails for every step

1. **Same checks, same order, same messages.** A check is removed only when an identical check on the same operands has
   already passed on every path to this point, so the removed check cannot fire. No check moves, so no trap fires earlier or
   later, and no output printed before a trap is lost. Exit status 101 and `trap: <msg>` are unchanged for every remaining trap.
2. **Hoisting is out of scope.** Moving a bounds check out of a loop could change which trap fires and what was printed before
   it. If it is ever wanted it needs its own addendum (restriction: no observable effect between the hoisted check and the
   original place, and an equal message).
3. **Facts are re-checked by the verifier on the output**, like every pass today (ICE exit 70 if it fails). The optimiser may use
   the verifier's own transfer functions as an oracle to *find* candidates; acceptance is the verifier run on the result.
4. **Fail closed.** A fact that is missing, stale or from an unvisited path means an error, never a silent pass. The
   state added to the verifier only ever loses facts at joins (intersection), so the fixpoint still terminates.
5. **Safety-relevant versus behaviour-only.** Dropping a `makeunique` or a bounds check is a *safety* matter (in-place write on
   a shared object; out-of-bounds read), so the verifier must reject a wrong one. Forwarding a load is *behaviour-only*
   (docs/tcb.md: the optimiser's output is re-checked for ownership, not for meaning); it is still re-checked here, to
   the standard of ADR-0032, and see open question 2.

### Transformations, ranked by expected savings

Estimates are executed instructions, static (`gcc -O2 -S`), per iteration of the hot loop; they are hypotheses until
measured. Overlaps are removed from the totals.

| # | Transformation | MIR change | nbody (200/pair) | mutres (55/call) | sieve (20/iter) | pqueue | appends |
|---|---|---|---|---|---|---|---|
| T6 | bounds + kind check from range / constant-length facts | v2.6 `IArrayGetU`/`IArraySetU` | -56 | 0 | 0 | 0 | 0 |
| T2 | repeated checks dominated by an identical check | v2.6 (same instructions) | -30 | 0 | 0 | -2% | 0 |
| T4 | load forwarding (`getfield` / `arrayget` of a known value) | v2.4 `IForward` | -20 | -3 | 0 | 0 | 0 |
| T1 | drop `makeunique` of a local the verifier proves `Unique` | none | -18 | -0.2 | -3 | -8% | -2% |
| T5 | unique receivers and results across calls | v2.5 two `MFunction` flags | 0 | -4 | 0 | -2% | 0 |
| T3 | scalar stores without the `is_ref` / `refmask` test | none (emitters) | -12 | -2 | -2 | -2% | 0 |
| | **Total, T1-T5** (T6 on top for nbody) | | **-40 % (-60 %)** | **-18 %** | **-25 %** (loop) | **-10 %** | **-2 %** |

Honest limits: `mutres` stays near 8x. What remains is the kind and slot-count checks that MIR types would remove (open
question 4), the `orin_out` protocol and the prologue; `appends` is a runtime cost; `pqueue` also pays for the un-inlined
`less` call (fn65) and the take/put dance, which this lever does not touch; `sieve`'s `flags[j]` needs `len == n + 1`, a
relational fact the interval domain of T6 cannot prove, so its bounds check stays.

#### T1. Drop `makeunique x` when the verifier already proves `x` is `Unique`

- *MIR change:* none (version unchanged). The pass deletes `IMakeUnique(x)` where the verifier state before it is `KUnique`.
  At runtime such a call always takes the `rc == 1` path and returns its argument, so deleting it is meaning-preserving.
- *Legality, re-checked:* no new rule. The existing `needUnique` (rules.or:366) rejects any later `ISetField` / `IArraySet` /
  take / put on a local that is not `Unique`, so a *needed* `makeunique` that was dropped is an error today. The deleted
  instruction's other effect, `killBorrows(x)`, only matters when a store follows, and a store does it itself (:589). Facts used:
  `KUnique` flows across loops and joins by the existing join (Owned+Unique = Owned, so a loop keeps `Unique` only if every path does).
- *Cases it covers:* `sieve` b8 (the inner marking loop, after b3), `nbody` main loop, `Reader.next` b1, `Reader.skip` b1,
  `pqueue` `push` b0 and b4 (`makeunique l3`). It does **not** cover `makeunique l26` after `l26 = takefield l3.0`: a taken
  element is `Owned`, and the verifier has no per-slot uniqueness (a struct can share its child arrays with another struct).
- *Trap semantics:* none involved. `orin_make_unique_slow` (the copy, and OOM) is never reached by a `Unique` local.
- *Mutation tests* (`tools/mutate_mir.py`): existing `drop-makeunique` and `store-shared-dup` / `store-shared-alias` keep
  their meaning. Add `redundant-makeunique-census`: after the pass, no remaining `makeunique x` satisfies the Python
  `certainly_unique` (an independent dataflow, so a mismatch is a finding either way). Add `dup-before-store-after-drop`: take a
  program after the pass, insert `t = dup x` before a store that used to follow a deleted `makeunique`; the verifier must say
  "requires ... to be Unique". The BENIGN classification of `drop-makeunique` (:391) shrinks to zero for pass output.
- *Census:* allocations, frees, retains, releases and `cow_copies` identical; only `cow_inplace` decreases, by exactly the number
  of deleted executions. Code changes only where a `makeunique` was deleted.
- *As built (2026-10-15, `compiler/opt/unique.or`):* a second run of the verifier's fixpoint per function cost +19% self-compile
  instructions (the verifier is two thirds of compile time), far over the +1% gate. The pass instead runs a local forward must-analysis
  of the set of certainly-`Unique` locals (created by `structnew`, `arraynew`, `makeunique`, a move of a `Unique` local; any other
  mention removes a local, except stores / takes / puts on it, field and element reads, a borrowed argument of a call without a
  reference result, and a scalar `length`; join is intersection). It admits at most what the verifier admits, and its output is
  verified as usual. Self-compile -0.016%; 1037 `orin_make_unique` calls removed across the corpus, no other code change; only
  `cow_inplace` moves (nbody 75.0M -> 0).

#### T2. Repeated bounds / kind checks on the same (array, index)

- *MIR change:* v2.6. Two instructions, `IArrayGetU(d, a, i)` and `IArraySetU(x, i, v)`: same meaning as `IArrayGet` / `IArraySet`
  with the kind check and the bounds check omitted. (Take / put variants later if `pqueue` shows they matter.) Emitters: C
  `items[i]` directly; LLVM `getelementptr inbounds` and no compare.
- *Legality, re-checked:* a new verifier rule `U1`. The unchecked instruction is accepted only if, scanning backwards in the
  same block (window of at most 64 instructions, so the cost is bounded and the check is local), the first instruction that
  touches `(a, i)` is a *checked or unchecked* `IArrayGet` / `IArraySet` / `IArrayTake` / `IArrayPut` of the same array local and the same
  index operand (the same constant, or the same local), and before reaching it there is no instruction that
  (a) defines `a` or the index local (this includes `IMove`, a call result, and the `inout` redefinition of `a`), or
  (b) can change the length or the shape of the object `a` holds: `IArrayPush`, `IArrayPop`, `IArrayExtend` on `a`, a whole-object
  consume of `a` (the local is then dead anyway). `IMakeUnique(a)` does **not** end the window: the copy has the same length.
  Stores to elements do not end it either (length is unchanged). Calls do not end it: under value semantics a callee cannot change
  an object reachable through a live local (a mutation needs `rc == 1`, which a live local excludes; a consumed or `inout`
  argument is case (a)). Not found within the window: error `unchecked array access without a dominating check`.
- *State needed:* none beyond the instruction stream (a backward scan), which is why this is the first rule to add.
  A cross-block version (a set of `(array, index)` pairs per program point, joined by intersection) would also catch repeated
  accesses across loop iterations; it is deferred.
- *Trap semantics:* the removed check is an exact duplicate of one that already passed with no length change in between, so it
  cannot fire. The first access keeps its check, in its place, with its message `index out of bounds` / the shape trap.
- *Mutation tests:* `bce-no-fact` (turn a checked `arrayget` into `IArrayGetU` with no earlier access: must be rejected, reason
  `without a dominating check`); `bce-across-push` (insert `arraypush a, v` between the checked access and the unchecked one);
  `bce-across-redef` (insert `a = move b` or an `inout` call on `a`); `bce-other-index` (different constant or local index);
  `bce-across-block` (access in the predecessor block).
- *Census:* identical in every counter. Code changes only at `arrayget` / `arrayset` sites turned into the unchecked form.

#### T4. Load forwarding

**Status (2026-10-15): implemented** (branch `claude/project-thread-niggkx-t4-forward`; MIR v2.4, rule F1 in `compiler/verify/forward.or`,
pass `compiler/opt/forward.or`, `orin2 compile --assert-facts`, mutation classes `fwd-*`; measurements below)
Measured (valgrind, executed instructions, orin2 of main c544cfa against the same plus T4): nbody 1,491.4M -> 1,402.4M (-5.97 %, 9 forwarded loads),
mutres 2,540.3M -> 2,541.6M (+0.05 %, 3 forwards: the saved loads are not on the hot path and the extra copy costs a little), pqueue (1 forward), qsort_inplace
and sieve (0): unchanged; self-compile 24,080.36M -> 24,080.23M (-0.001 %; the gate is +1 %). The estimate in the table above (-20 on nbody per pair, -3 on mutres) was
optimistic for mutres. Census: allocs, retains, releases, cow_* identical on all five benchmarks (built with `-DORIN_STATS_ENABLED`); the generated C differs
only at the forwarded loads (77 in `compiler/main.or`). Deviations from the
text below, all on the conservative side: an `IForward` is also a source for the forwards after it (otherwise the third load of a slot could never be
forwarded); the scan is an allow-list (an instruction that mentions `o` and is not one of the listed harmless reads ends it); reference slots
(`IBorrow(d, earlier)`) are not forwarded: accepting that needs the verifier's state at every position, so the pass leaves them as they are; the
object of an `IForward` must be a reference local (an unboxed aggregate is already in registers).

- *MIR change:* v2.4. `IForward(d, s, o, key)`: `d = s` (a scalar copy), claiming that `s` holds the current value of slot
  `key` of `o` (a field index, or an array index operand). It is emitted in place of the second `getfield` / `arrayget` of a
  scalar slot. Emitters: `d = s`.
- *Legality, re-checked:* rule `F1`, the same backward scan (window 64, block-local): the first instruction that touches
  `(o, key)` is `IGetField(s, o, key)`, `IArrayGet(s, o, key)`, `ISetField(o, key, OLocal s)` or `IArraySet(o, key, OLocal s)`, and
  before it there is no (a) definition of `s`, `o` or the key local, no (b) write that may hit the slot: `ISetField` / `ITakeField` /
  `IPutField` of the same index on `o`, `IArraySet` / `IArrayTake` / `IArrayPut` on `o` with an index that is not provably
  different (two different constants are different), `IArrayPush` / `Pop` / `Extend` on `o`. `IMakeUnique(o)` does not end it (a shallow copy
  keeps every slot). Calls do not end it, by the argument of T2; step 1 is more conservative and ends the window at any call or
  builtin that receives `o` as an argument. `o` and `s` must be live and `d` a scalar local, or the ordinary rules reject it.
  Not found: error `unjustified forward`.
- *Reference slots need nothing new:* replace the second `getfield` by `IBorrow(d, earlier)`. A live borrow proves the slot has
  not changed (borrows die on store and on `makeunique`, see above), so the existing rule is the check. In `Reader.next`
  the `makeunique` between the reads kills `l4`, so that read is simply not forwarded.
- *Trap semantics:* the forwarded access had already succeeded on the same `(o, key)` in the same block, so its trap cannot fire.
  A forward from a store (`setfield x.1 = v` then `getfield x.1`) is validated by the store's own check.
- *Mutation tests:* `fwd-across-write` (insert `setfield o.i = w` between the load and the forward: rejected); `fwd-other-slot-ok`
  (a write to a different slot must be accepted: a positive control that the rule is not vacuous); `fwd-after-redef-obj`;
  `fwd-after-redef-src`; `fwd-across-push`; `fwd-wrong-slot` (key differs); `fwd-across-block`.
- *Dynamic check:* `orin2 compile --assert-facts` (new flag, never on by default) emits the original checked access next to every
  `IForward` / `...U` and aborts with exit 70 and a distinct message if the fact is false. The test suites run under it in CI. This is a
  second, independent validation of the facts on every test program, and is the cheap form of ADR-0032 translation validation for these passes.
- *Census:* identical in every counter; code changes only at forwarded loads.

#### T5. Unique receivers and results across calls

- *MIR change:* v2.5. Two flags on `MFunction`, printed after the existing ones: `unique-in` (the `inout` receiver, local 0, is
  `Unique` on entry) and `unique-out` (the value handed back is `Unique`: local 0 at each return for an `inout` function, the
  returned local for any other function with a reference result). Parser, printer, `wf`, `tools/mutate_mir.py` (`Func` header regex, :62) updated.
  Emitters ignore them.
- *Legality, re-checked:* four rules, all local to one function or one call, no whole-program fixpoint in the verifier:
  `U2` callee entry: if `unique-in`, local 0 starts `KUnique` instead of `KOwned`.
  `U3` return: if `unique-out`, the returned local (local 0 for `inout`) must be `KUnique` at every `TReturn`, else error.
  `U4` call site: `ICall` of a `unique-in` function needs argument 0 `KUnique` (`needUnique`), else error.
  `U5` call result: after `ICall` of a `unique-out` function the destination (for `inout`, the receiver local, today redefined `Owned`) is `KUnique`.
  Soundness: `U3` makes the declaration true of the callee, `U4` makes `U2`'s assumption true at every call (an `inout` function is never a
  closure target or a vtable entry, so every call is a direct `ICall` in the program), `U5` uses only what `U3` established. Existing demotion
  at calls is unchanged.
- *The optimiser* sets the flags by optimistic assumption and retraction: assume all candidates, replay the verifier, drop the
  flag of every function whose body or call site fails, repeat until stable. A call site that would need `unique-in` but is not
  `Unique` gets `makeunique x` inserted before the call only when that site is outside a loop; otherwise the flag is not set (no
  pessimisation of a hot path). The result is verified as usual.
- *Effect:* `r.next()` in a loop: before the loop the receiver is `Unique` (T1 or `makeunique` once), after each call `U5` keeps it
  `Unique`, so neither the call site nor the callee tests `rc` again. A constructor with `unique-out` gives `Unique` to `new Reader(d)` and the first `makeunique` goes too.
- *Trap semantics:* none involved.
- *Mutation tests:* `uniq-flag-flip-in` (set `unique-in` on a function whose body or a caller is not unique: must fail `U4`/`U2`);
  `uniq-flag-flip-out` (callee returns a `dup`'d or `Owned` local: fails `U3`); `uniq-in-shared-caller` (caller does
  `t = dup x` before the call: fails `U4`); `uniq-out-then-dup` (caller dups the result and stores through the original:
  fails `needUnique` after `U5`, as today); `inout-drop-receiver` and `inout-release-receiver` stay.
- *Census:* retains / releases / allocations / `cow_copies` identical; `cow_inplace` decreases by the removed tests.

#### T3. Scalar stores without the `is_ref` / `refmask` test (emitters only)

- *Change:* `ISetField`, `IArraySet` whose value operand is a scalar local or constant (statically known from `MLocal.ty`) emit a
  plain store; only a reference value keeps `orin_mir_*_replace`.
- *Legality:* no MIR change, no verifier rule. Failure mode if the (unchecked) type assumption were wrong: a reference
  overwritten by a scalar is not released, a leak, never a use-after-free. That is the reason it needs no fact. State this in docs/tcb.md under "C backend, LLVM backend".
- *Tests:* backend differential (C against LLVM, `--mode opt`) and sanitizers (LeakSanitizer runs of the suites stay clean).
  `ORIN_STATS` counters identical.

#### T6. Range facts for constant-length arrays (separate approval)

- *MIR change:* none beyond T2's `...U` instructions; the verifier gains a fact source for them.
- *Legality, re-checked:* a new abstract state, the largest addition to the TCB in this addendum: for each `usize` / `int` local an
  interval `[lo, hi]`; for each array local a length interval, defined by `IArrayNew` with `n` elements as `[n, n]` and
  destroyed by `IArrayPush` / `Pop` / `Extend` and by redefinition; refined by `TBranch` on `lt` / `le` / `eq` of two locals or a local and a
  constant, transferred through `add` / `sub` / `copy` with the existing overflow traps (a trap path leaves no state), joined by interval hull
  with widening at loop heads and one narrowing round. `IArrayGetU` / `IArraySetU` is accepted when `hi(i) < lo(len(a))` **and** the
  shape is known (`a` defined by `IArrayNew` in this function, or T2's dominating access). Parameters have no shape fact, so `energy()` keeps
  its kind checks; only `main` of `nbody` benefits fully.
- *Trap semantics:* only checks proved unable to fire are removed; nothing is hoisted (guardrail 2). Index arithmetic overflow traps stay.
- *Mutation tests:* `range-widen-off-by-one` (loop bound `<=` instead of `<`: rejected); `range-after-push`; `range-after-redef-index`;
  `range-no-branch-refinement` (delete the guard); `range-param-array` (parameter array, no length: rejected).
- *Open:* whether this domain belongs here or waits for the ADR-0036 verifier fragment, which will also give `@Invariant`-based
  facts (§4) through the same `...U` instructions. The assurance report names the fact kind for every removed check:
  `dominated-by-check`, `interval`, or (later) `contract`.

### Lean model, ADR-0032, docs/tcb.md

- *Lean* (`formal/Orin/Machine.lean`: `load`, `store`, `makeUnique`; no calls, no arrays with length): T1 needs nothing (the model's
  `store` already requires `rc = 1`; add one example in `Examples.lean` of a program with a dropped redundant `makeUnique` that `check_sound` accepts). T4
  needs two lemmas: a load after a load or store of the same slot, with no write and no redefinition in between, returns the same value; `makeUnique`
  preserves every slot value. T2, T5, T6 (length, calls, intervals) are outside the model; they are listed with the other
  "rules not yet in the model" in docs/tcb.md and docs/formal.md, not claimed as proved.
- *ADR-0032:* T4 and T2 are the first passes whose certificate is a *local* check (the backward scan), which is what "small independent
  validator" means for them; the verifier rules `F1`/`U1` are that validator. The `--assert-facts` run is evidence, not proof (the Addendum of ADR-0032 says a
  sanitizer test is not implementation verification, and this follows it).
- *docs/tcb.md:* the verifier row grows by the rules `U1`, `F1`, `U2-U5` (and `R1-R3` if T6 is approved), with the line count of the added
  Orin code; the "C backend, LLVM backend" row gains T3's untyped-store assumption and the two new unchecked access helpers
  (`orin_array_at_u`, LLVM `inbounds` GEP) as the only places where the emitters rely on a verified fact for memory safety.
- *docs/mir.md:* changelog v2.4-v2.6, a section per rule, the new text forms in the grammar, the mutation corpus list.

### Rollout: one PR per step, each with its own measurement

Order is by risk, not by size of the win. Gates common to every PR: `stage2.c == stage3.c` (the compiler's own code changes), the full test
suite, `compiler/tests/verify_main.or` and `verify_text.or` cases for the new rules, `tools/mutate_mir.py` with zero survivors and zero wrong-reason,
`tools/diff_backends.py --mode opt` and `--mode llvm` with 0 differences, ASan + UBSan (`--sanitize`) on every suite and TSan on
`tools/test_concurrency.sh`, the census identity stated for the step, callgrind instruction counts of the five benchmarks before and
after (reported in docs/benchmarks.md), and self-compile instructions not worse than +1 % (the fusion step missed "not worse" by 0.84 %, so the verifier cost is a gate here).

1. **T1** (no MIR change). Gate: `cow_inplace` is the only counter that moves; the Python `certainly_unique` finds no remaining redundant `makeunique`.
2. **T3** (emitters). Gate: LeakSanitizer clean; nothing else.
3. **T2** (v2.6, `U1`). Gate: new mutants rejected for the stated reason; `--assert-facts` suite run clean.
4. **T4** (v2.4, `F1`). Gate: as T2; Lean lemmas merged before the PR.
5. **T5** (v2.5, `U2-U5`). Gate: flag-flip mutants; compile-time gate on the optimistic-retract loop.
6. **T6** (separate owner decision after T2 is measured). Gate: its own review of the interval domain; Lean or documented "outside the model" decision.

### Not in this lever (found while reading)

- The `orin_stats` counters are compiled in unconditionally (`orin_runtime.h:183-208`): one thread-local add per `make_unique`, retain and release. Making
  them opt-in at build time is a runtime decision with its own measurement (open question 3).
- Kind and slot-count checks (`orin_chk_slot`) need types in MIR; that is a larger verifier change (the verifier would check slot indices and
  tags), and is the next lever for `mutres`.
- Inlining small pure functions such as `less` in `pqueue` (fn65), the take/put dance of `makeunique l26`, and the string-append and
  array-extend runtime paths of `appends` are separate items.
- Uniform 8-byte slots (§3, `u8[]` packing) are unchanged.

### Open questions for the owner

1. Approve growing the verifier by `U1`, `F1` and `U2-U5` (about 250 lines of Orin by estimate), with T6's numeric domain decided separately?
2. Forwarding is behaviour-only, not safety. Keep the verifier check `F1` (recommended: it is cheap, local and makes the claim reviewable), or drop `IForward` and rely on differential testing and `--assert-facts`?
3. Should `ORIN_STATS` counters become a build-time option (`-DORIN_STATS`) so release builds do not pay for them? (Not part of this lever; affects every benchmark.)
4. MIR types for slots and elements: take this as the next lever, which would remove the remaining kind checks and make T3 a verified fact?
5. May calls stop ending the forwarding window (T4 step 2) once the Lean lemma for "a live reference excludes in-place mutation" is merged?
6. T5 inserts a `makeunique` at call sites outside loops. Acceptable, or only set the flags when no site needs an insertion?
