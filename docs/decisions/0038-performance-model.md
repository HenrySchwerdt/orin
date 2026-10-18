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
  - *Evidence:* `tools/differential.sh --mode fuse` (fused vs `--no-fuse`, every run test, 0 differences) and `--mode opt`;
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
     **Status (2026-10-16): met.** `tools/llvm_fixpoint.sh` (CI job `llvm`): `orin2` compiles `compiler/main.or` with
     `--backend=llvm`, clang links `orin2-llvm`, and `orin2-llvm` emits C identical to `stage2.c` and LLVM IR identical to the
     first `.ll` (and, with `--deep`, so does a third compiler built from that `.ll`). No difference was found.
  3. **Toolchain:** a pinned LLVM version is used, as described below.
     **Status (2026-10-16): met; LLVM is the release default (owner, 2026-10-16).** LLVM 19.1.7, `dist/llvm.pin`, `orin toolchain install`; see the addendum "the pinned LLVM toolchain".
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
| T5 | unique receivers and results across calls | v2.7 two `MFunction` flags | 0 | -4 | 0 | -2% | 0 |
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

**Status (2026-10-16): implemented on branch `claude/project-thread-niggkx-t2-checks`, gain measured as nil; not recommended for merge as is.**
MIR v2.6 (built as v2.5 before main took v2.5 for the string append primitives, PR #100; renumbered on merge): `IArrayGetU` /
`IArraySetU`, rule U1 (`compiler/verify/unchecked.or`, helpers shared with F1 in `scan.or`), pass `compiler/opt/bounds.or` (last pass),
`--assert-facts` via `orin_assert_array`, mutation classes `bce-*` (0 survivors, positive controls accepted), Lean: outside the model
(array length), documented in docs/tcb.md and docs/formal.md. Deviations from the text below, all conservative: `arraytake` / `arrayput`
on the array end the scan; a source that redefines its own index (or the array) is not a source; an `IForward` from the array does not end it.
Measured (valgrind, executed instructions, main 8587609 against the same plus T2, same benchmark inputs): nbody 1,402,363,100 -> 1,402,363,072,
mutres -28, pqueue -28, sieve -28 (all within noise: 9 / 0 / 0 / 0 static sites), qsort_inplace 583,004,355 -> 584,039,634 (+0.18 %, 4 sites).
`ORIN_STATS` counters identical on all five; the generated C differs only at the converted accesses (compiler/main.or: 44 lines, nbody 9,
qsort_inplace 4). The reason is that `gcc -O2` already removes the second kind and bounds check of the same `(array, index)` inside one C
function, so the estimate of -30 instructions per pair for nbody above does not hold; what remains in nbody's inner loop is not a repeated check.

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
object of an `IForward` must be a reference local (an unboxed aggregate is already in registers); a load that overwrites its own index local
(`i = arrayget o[i]`) is not a source (found in review: the first version accepted it). Lean lemmas: `formal/Orin/Forward.lean`
(`load_load`, `store_load`, `store_frame_other_slot`, `store_frame_other_local`, `makeUnique_frame`).

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

**Status (2026-10-16): implemented** (branch `claude/project-thread-niggkx-t5-unique-calls`, on main with T1, T3, T4; MIR v2.7, rules U2-U5 in
`compiler/verify/{wf,verify,rules}.or` (+76 code lines), pass `compiler/opt/uniqflags.or`, T1 extended in `compiler/opt/unique.or`, mutation classes
`uniq-*`, `docs/mir.md` section "Unique receivers and results").
Measured (valgrind, executed instructions, orin2 of main b5bf508 against the same plus T5): mutres 2,541.6M -> 2,400.3M (**-5.56 %**; `cow_inplace`
60.0M -> 40.0M, the only counter that moves), nbody, sieve, pqueue, qsort_inplace unchanged (+-6 instructions); self-compile 24,643.1M -> 24,846.9M
(**+0.83 %**, gate +1 %; the first version, which analysed every candidate, cost +20 %, see below). Census (`-DORIN_STATS_ENABLED`): allocations, frees, retains,
releases, `cow_copies` identical on the five benchmarks. Generated C of the 407-program corpus, the benchmarks and the compiler: 41 programs
differ, 221 `orin_make_unique` calls removed and 86 added (the ones put before calls), no other line. In the compiler itself: 36 of 284 in/out functions are
`unique-in`, 82 of 3,817 functions `unique-out`. The estimate in the table above (mutres -4 of 55 per call) held; **pqueue's -2 % did not**: the std collection
methods that were meant to benefit have their `makeunique` outside block 0, which the final candidate rule (below) excludes, and with them included the first version saved
2 % of pqueue's `cow_inplace` tests (600,000 of 28.2M), against a +20 % self-compile.
Checked in the code before relying on the soundness argument (details in `docs/mir.md`): (a) an `inout` function can never be a closure target, vtable
entry or indirect callee: `closureMsg` and `vtableMsg` require borrowed parameters and `inout` needs an owned parameter 0; `main` is rejected as `unique-in`.
(b) The receiver is the only reference at an `inout` call: the call consumes argument 0 (`killBorrows`), and a borrowed argument aliasing it is already an
error. **This check found a hole in the pre-existing verifier**: a `Unique` argument in a *borrowed* position stayed `Unique` after an `inout` call with a
scalar or void result, although the callee can `dup` it into the receiver it hands back (`push(items, item)`). Harmless while only a runtime `makeunique`
consumed the fact, wrong once a callee skips the test. Fixed: an `inout` call demotes its borrowed arguments (case in `verify_main.or`, and T1's analysis already did
so). (c) For a non-`inout` `unique-out` result, `KUnique` already implies that nothing the callee keeps can reach the object (no globals; closures consume
their captures; a borrowed parameter cannot be stored through; the receiver is covered by (b)); U3 therefore checks only the kind.
Deviations from the text below, all on the conservative side: a `unique-in` candidate is an `inout` function whose **block 0** starts with the `makeunique` of
its receiver, so a `makeunique` put before a call is exactly the copy the callee would have made (`cow_copies` identical, no pessimisation of a callee that does not
write); a call site outside every loop never costs the flag and gets the `makeunique` (open question 6: accepted in this form, it is cost-neutral by
construction), a site inside a loop with a non-`Unique` receiver does (the flag is not set). Compile-time gate: the verifier's fixpoint is not rerun; the
pass uses T1's local analysis, analyses only functions that can change a verdict (214 of 3,817 in the compiler, 252 analyses in all, so 38 re-analyses for
retractions), runs callees before callers, takes a function without a loop as always satisfiable (it gets the `makeunique` before each call, T1 removes the redundant
ones), makes a `unique-out` a candidate only where a caller can use it, and skips functions over 12,000 blocks times locals. T1 also learned that a
closure and an interface value are `Unique` (the verifier says so) and got a fast path for instructions that name no `Unique` local. Without the budget measures the pass
cost +20 % self-compile, with them +0.83 %. Mutation classes: 1,638 `uniq-flag-flip-out`, 190 `uniq-flag-flip-in`, 94 `uniq-in-shared-caller`, 29 `uniq-out-then-dup` mutants
among 54,672 in all: 0 survivors, 0 wrong-reason (776 benign, each classified with a reason). Lean: outside the model (calls), listed in docs/tcb.md and docs/formal.md.

- *MIR change:* v2.7. Two flags on `MFunction`, printed after the existing ones: `unique-in` (the `inout` receiver, local 0, is
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

#### T6. Range facts for constant-length arrays (implemented on the T2 branch, see "As built")

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

- *As built (2026-10-16, branch `claude/project-thread-niggkx-t2-checks`, on top of T2; MIR v2.6, no new instruction):*
  `compiler/verify/range.or` (811 code lines; the verifier grows from 2591 to 3461 code lines with T6, +870 including `unchecked.or`
  and `verify.or`), rules R1-R5 in docs/mir.md "Range facts". Interval per `int` / `usize` local, array length interval per
  reference local (`arraynew` with n elements -> `[n, n]`, moved by `move`, destroyed by every other mention except plain reads and
  stores, `makeunique`, `forward`, `arr.length` and a borrowed-position argument of a known call), refinement from a same-block
  compare feeding the `TBranch` (`lt le gt ge eq ne`, local against local or constant), transfer through `copy` / `add` / `sub` with the
  traps kept (a `usize` subtraction that always underflows ends the path), hull join, widening to the function's constants after two
  changes of a block, one in-order narrowing round. Acceptance: shape known, `lo(i) >= 0`, `hi(i) < lo(len)`. Deviations from the
  text above: parameters and call results have no shape fact (as planned); a function is analysed only when it accesses a local
  built by a non-empty `arraynew` and its `locals x blocks` product is at most 4000 (the first version had no such gate and cost
  +17 % self-compile instructions, `RangeFx.joinInto` alone 11 %; the gate, a join that writes only on change and the access-based
  filter brought it to +0.37 %); the optimiser pass (`opt/bounds.or`) asks the same `rangeAccepted` table, so it cannot emit
  what the verifier would not re-derive. No assurance report hook exists in the tree yet, so the fact kind is visible only in the
  mutation tool's census (`unchecked accesses by fact: both 9, dominated-by-check 34, interval 141` over the corpus) and
  `verify_text --facts`. `--assert-facts` re-checks every unchecked access (`orin_assert_array`), all suites clean.
- *Measured (valgrind, executed instructions, same inputs; main `a63a1e2`-based baseline against this branch):*

  | benchmark | main | T2 + T6 | change | ceiling (all checks removed) |
  |---|---|---|---|---|
  | nbody | 1,402,357,380 | 658,357,335 | -53.06 % | -53 % |
  | pqueue | 1,404,018,704 | 1,404,018,708 | 0 | -37 % |
  | sieve | 410,380,710 | 410,380,713 | 0 | -18 % |
  | qsort_inplace | 583,001,188 | 584,036,481 | +0.18 % (T2) | -16 % |
  | mutres | 2,541,569,601 | 2,541,569,605 | 0 | -13 % |
  | self-compile (same input) | 24,488,990,415 | 24,578,761,644 | +0.37 % | gate +1 % |

  nbody reaches the ceiling because its `main` builds the arrays by literals and indexes them in counted loops. The others gain
  nothing: their hot arrays are parameters (no shape fact by design), built by `push` in a loop (the length is not known) or
  indexed by values the intervals cannot bound (heap indices, `i * 2 + 1`, a partition cursor against a variable `hi`). Reaching them needs
  a relational domain or contract facts (the "Open" item above), not a better interval implementation.
- *Soundness corner cases handled:* `<=` against the length keeps the check; a push, pop, extend, take, put, dup, borrow,
  release, consuming constructor, owned or in/out call, indirect call or redefinition of the array, or of the index
  after the guard, drops the fact; a borrowed call keeps the length (a borrowed parameter is never mutated, and the caller's live reference
  forces copy-on-write); an unsigned underflow of `n - 1` still traps and nothing after it is claimed; a negative `int` cannot index
  (`toUsize` traps first); an unreached or dead block justifies nothing; a branch condition redefined between compare and branch
  refines nothing; a huge or unknown index keeps the check.
- *Tests:* about 110 cases `rangeCases` in `compiler/tests/verify_main.or`, four optimiser tests in `opt_test.or`, eight `tests/next/run/bce_range_*`
  programs (outputs identical to main), mutation classes `range-*` (see docs/mir.md) with 0 survivors and 0 wrong-reason mutants.
  The T2 optimiser tests now use owned array parameters, because a literal array with constant indices is interval-justified.
- *Lean:* array length is outside the model; nothing is claimed as proved (docs/tcb.md, docs/formal.md).

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
`tools/differential.sh --mode opt` and `--mode llvm` with 0 differences, ASan + UBSan (`--sanitize`) on every suite and TSan on
`tools/test_concurrency.sh`, the census identity stated for the step, callgrind instruction counts of the five benchmarks before and
after (reported in docs/benchmarks.md), and self-compile instructions not worse than +1 % (the fusion step missed "not worse" by 0.84 %, so the verifier cost is a gate here).

1. **T1** (no MIR change). Gate: `cow_inplace` is the only counter that moves; the Python `certainly_unique` finds no remaining redundant `makeunique`.
2. **T3** (emitters). Gate: LeakSanitizer clean; nothing else.
3. **T2** (v2.6, `U1`). Gate: new mutants rejected for the stated reason; `--assert-facts` suite run clean.
4. **T4** (v2.4, `F1`). Gate: as T2; Lean lemmas merged before the PR.
5. **T5** (v2.7, `U2-U5`). Gate: flag-flip mutants; compile-time gate on the optimistic-retract loop.
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


## Addendum (2026-10-16): string intermediates (census row 1)

The allocation census (`docs/perf/alloc-census.md`, ranking of 2026-10-16) ranks "string intermediates" first: the decimal text of
a number built as a string only to be appended to another (`usizeToString`, 6.13M allocations), the `substring` pieces of
`html.escape` (1.83M) and the temporaries of `bench/strings`. This addendum fixes how they are removed. **No language-visible
change**: same text, same traps, same evaluation order. It adds MIR instructions, so it is MIR v2.5 (docs/mir.md, docs/tcb.md).

### Choice

Three candidates were read against the code:

1. *A pure std/lowering change.* Not possible for the digits: `usizeToString` is already one allocation (the result), because
   `"w" + n.toString()` was already lowered to a `strprepend` onto that result (MIR v2.3). What costs is the Orin digit loop
   (a `fromCharCode` and an `orin_str_append` call per digit, plus the power-of-ten loop) and, whenever the destination already
   exists (`s += "item" + i.toString() + ","`, a template, an OX root), the temporary that is built, copied and dropped. Without a
   primitive that writes digits into the destination there is no way to remove either, and no existing builtin consumes and
   returns its destination (a builtin is non-mutating for the verifier).
2. *An append-decimal runtime primitive reached through a new MIR instruction* `IStrAppendNum(x, y, unsigned)`: chosen.
   Its verifier rule is that of `IStrAppend` (the destination must be Owned, borrows of it die, the result stays Owned), and the
   source is a scalar, so there is no aliasing case at all (the `y` not borrowed from `x` rule of `IStrAppend` is vacuous).
3. *`html.escape` appends its pieces.* The pieces are `s.substring(a, b)`; the primitive that removes the object is
   `IStrAppendSub(x, y, a, b)`, again with the `IStrAppend` rule (y live, not `x`, not borrowed from `x`; a, b usize scalars).
   Escaping by single bytes would also avoid the object but costs an append call per byte.

Rejected: a new verifier analysis (none is needed: both instructions are instances of the existing mutate-an-Owned-string rule,
and in-place is decided at run time by `rc == 1`, as for `IStrAppend`); changing `escape` to a different algorithm (the std
source is unchanged except that its `out += s.substring(..)` is now lowered to the primitive).

### Lowering (compiler/lower/lowerer.or)

* `a + n.toString()` with `n` an `int`/`usize` (the checker produces the same HIR for `${n}`): `a` is evaluated, then `n`; the
  digits of `n` are appended onto an owned copy of `a` (`strappendi` / `strappendu`). A borrowed or literal `a` is `dup`ed first, as
  before, so a shared destination is copied by the runtime and never changed.
* `n.toString()` as a value: `str.withCapacity(24)` then `strappendi`: one allocation, no digit loop in Orin. The prelude
  functions `numbers.intToString` / `usizeToString` stay (they are the `--c-builtins` reference semantics and exported), but the
  lowering no longer calls them.
* `s += e` (and `s = s + e`) on a string local: `e` is split into the operands of its left-nested `+` chain. All operands are
  evaluated first, in order, by the existing `args`, and only then appended one by one; an operand that is the destination's own
  value is `dup`ed before the first append (`s += "a" + s` appends the old `s`). `s ++ ((a ++ b) ++ c) == ((s ++ a) ++ b) ++ c`,
  so the value is the same, and since nothing is appended before every operand has been evaluated, the evaluation order and the
  first trap are those of the concatenation. A `.toString()` operand appends its digits.
* The last operand `x.substring(i, j)` of such a chain is appended with `strappendsub`. Only the last: the substring range check
  now happens at the append, after the earlier operands were appended (unobservable: a trap ends the task and `s` is local);
  a middle operand would let a later operand's side effect or trap run before the substring's trap.

### Runtime and verifier

`orin_str_append_int/_usize(a, v)` form the digits in a 24-byte stack buffer and append with the growth rule of
`orin_str_append`; `orin_str_append_sub(a, s, i, j)` traps `substring out of range` first and then appends the bytes. All three:
in place iff `a->rc == 1` (and `a != s` for the substring), otherwise a fresh string and the old one released. They add about
70 lines to the trusted runtime (docs/tcb.md); the Orin digit loop they replace was untrusted code, which is the one cost of this
change. Verifier: `rules.or` (one arm each, `mutateOwned`), `wf.or` (classes), `analysis.or`, printer and text parser;
`compiler/tests/verify_main.or` has positive and negative cases for both, and `tools/mutate_mir.py` gains the classes
`append-after-release`, `append-borrowed` and `append-kills-borrow` for every string append instruction of the corpus
(`strappend`, `strprepend`, `strappendi`, `strappendu`, `strappendsub`).

### Measurement (same inputs, main `e23ff6d` vs this branch; valgrind instructions, census allocations)

| workload | instructions before | after | change | allocations before | after | change |
|---|---:|---:|---:|---:|---:|---:|
| mapfreq | 1,621,489,667 | 1,171,665,517 | -27.7% | 1,050,017 | 1,050,017 | 0 |
| wordfreq | 1,235,942,915 | 878,444,843 | -28.9% | 1,006,028 | 1,006,028 | 0 |
| html | 3,005,772,527 | 1,907,050,854 | -36.6% | 4,338,006 | 1,720,006 | -60.4% |
| html_hand | 4,590,162,194 | 1,608,789,644 | -65.0% | 5,034,406 | 118,806 | -97.6% |
| strings | 1,119,961,484 | 696,111,714 | -37.8% | 1,500,009 | 1,000,008 | -33.3% |
| url | 4,978,414,075 | 4,978,402,795 | 0 | 10,972 | 10,966 | 0 |
| self-compile, same input (this branch's `compiler/main.or`, built by main's vs this branch's compiler) | 24,620,120,259 | 24,488,437,976 | -0.5% | 15,127,543 | 15,087,407 | -0.3% |
| self-compile, each tree's own source (main `e23ff6d` vs this branch) | 24,544,355,195 | 24,488,437,976 | -0.2% | 15,072,609 | 15,087,407 | +0.1% (more source) |

Finding that corrects the census: for mapfreq and wordfreq (95% / 99% of their allocations) the `toString` string *is* the map
key and stays alive, and since MIR v2.3 it was already the only allocation of `"w" + n.toString()`; those allocations are
inherent, and the gain there (-28%) is instructions only (the digit loop). The allocation gain is where the destination already
existed: OX roots and hand-written `out += ...` (html -2.6M, html_hand -4.9M) and `s += "item" + i.toString() + ","` (strings
-0.5M). The census row "up to 6.13M" is therefore an upper bound that is reached only where the number is not kept.

## Addendum (2026-10-16): escape analysis, scalar replacement of temporary array literals (census row 3, class (c))

The census ranks class (c) third: 1.27M allocations (1.9 %), 6.7 % of the self-compile's and 100 % of `appends`' (200,021 `[i]` /
`[i, i]` at bench/appends/main.or:49, :55). **No language-visible change** (same values, same traps, same evaluation order),
**no MIR change, no new verifier rule**, no runtime change. This addendum fixes which part of the class is removed, and why the
rest is not.

### What the class contains (read against the sites)

1. *A temporary array literal that is only appended.* `a = a.concat([e1, .., ek])` lowers to `t = arraynew [..]`, and the
   in-place pass (`inplace.or`, MIR v1.10) turns the concatenation into `arrayextend a, t; release t`. `t` is defined once, read
   by the one extend (which only copies its elements) and released at once: it does not escape in any sense (not stored,
   returned, captured, passed in an owned position, or read twice). It costs an object, a buffer, the extend call and two frees.
2. *Method-local helper objects of the compiler* (`BlockSink`, `State`, `RewritePlan`, `Transfer`, `runBlock`'s `Transfer`,
   `Cx`): classes with mutable fields that are built, mutated through methods and dropped. Their arrays are moved into the result
   (`BlockSink.finish` hands `instrs` / `spans` to the `MBlock`), so only the small header object of each is removable; removing it
   needs the methods inlined (the object is mutated through `this`) and the fields turned into locals (scalar replacement of a
   *mutable* object), which is a new interprocedural analysis plus an inliner, and the verifier would have to accept field
   locals that alias the heap arrays. Measured ceiling: `BlockSink` 111k + `State` 95k + `RewritePlan` 95k + `Transfer` 75k +
   `runBlock` 92k + `Cx` is about 0.5M of the self-compile's 15.8M allocations; at about 120 executed instructions per
   allocate / free pair (24.8G instructions, 15.8M allocations: the whole allocation cost is below 8 %), that is about 0.5 % of
   its instructions. Below the 2 % bar of the task, so **not built**; no stack allocation of objects either (it would need a
   verifier rule for a non-heap object that must not be retained, released or stored: a new TCB rule for ~0.5 %).

### Choice: remove (1) in the optimiser, with the existing verifier rules

`compiler/opt/lits.or` (`pushLiterals`, last step of `optimizeFunction`) rewrites three adjacent instructions

    t = arraynew [e1, .., ek]          arraypush x, e1 ; .. ; arraypush x, ek
    arrayextend x, t              =>
    release t

when `t` is defined once and used exactly twice (the extend and the release), `x != t`, no element is `x`, and `k <= 8`; an empty
literal extends nothing and its three instructions are deleted. Why this is sound without a new rule:

* `arrayextend x, t` and `arraypush x, e` have the same rule on `x` (Owned or Unique, not a parameter or borrow, stays Owned,
  borrows of `x` die: `mutateOwned`). The extend's extra rule (`t` not `x`, not borrowed from `x`) is vacuous for a fresh `t`.
* The elements are consumed by the literal today and by the pushes afterwards (`consume`, each ref element an Owned local or
  `OStr`, becoming Dead); between the literal and the extend there is no instruction, so no local changes state in between.
  The runtime retains the ref elements of `t` and `release t` frees them again; a push moves them: the same reference counts.
* Value semantics are those of the extend: `orin_mir_array_push` makes `x` unique first (a shared `x` is copied, never changed
  behind the other reference), as `orin_array_extend` does.
* The result is verified like any other MIR, so a wrong rewrite would be rejected (or the C differential would see it); the
  contract `passKept` (same signature, locals only appended, same calls and builtins in the same order) is checked on the pass.

Rejected: a general points-to / escape analysis over `IArrayNew` + builtins (the only non-escaping consumer that occurs in the
census is the extend; a general analysis would add a TCB-visible fact language for no further site); a runtime `extend_lit`
primitive (new trusted C for what the verified push already does); a stack-allocated literal object (see above).

Not covered, by design: a literal that is bound to a name and used twice, passed to a call (owned or borrowed), stored, returned
or captured keeps its object; so does a ref array whose destination is `string[]` of more than 8 literal elements. Regression
test: `tests/next/run/escape_array_literal.or` (each escape form, shared destinations, empty literal, literals built from the
destination, ref elements, nested arrays, record / class / element destinations); its output is byte-identical to main's.

### Measurement (same inputs; main `d297509` vs this branch; valgrind instructions, census counters)

| workload | instructions before | after | change | allocations before | after | change |
|---|---:|---:|---:|---:|---:|---:|
| appends | 119,868,365 | 61,568,375 | -48.6% | 200,019 | 19 | -99.99% |
| self-compile, same input | 24,816,681,927 | 24,816,681,927 | 0.00% | 15,764,604 | 15,764,604 | 0 |
| bintrees, bytesstr, fib, html, html_hand, http_parse, mapfreq, mutres, nbody, pqueue, qsort_func, qsort_inplace, sieve, sortedmap, streams, strings, url, wordfreq | | | 0.00% each | | | 0 |

The compiler's own source contains no `concat([..])` of a literal, so the C that the self-compile produces is byte-identical
(`== stage2.c`) and its counts do not move: the self-compile gate (<= +1 %) holds with 0.00 %. The gain is where the idiom
occurs: appends -58.3M instructions for 200,000 literals, about 290 instructions per literal (an object, an item buffer, the extend
call and two frees). The ratio to C falls from 4.7x to 2.4x. Retains / releases of `appends` are unchanged (0 / 200,019 before,
0 / 19 after).

Consequence for the ranking: the remaining class (c) in the compiler is real but worth about 0.5 % of its instructions, and
needs either an inliner with scalar replacement of mutable objects or a verified non-heap object; neither is justified at that size.

## Addendum (2026-10-16): bintrees regions, measured first (class (f)) and a small-block cache

Question: is a region/arena for `bench/bintrees` (33.4M allocations, 49.6 % of the census, 26.7 % of its RC operations) worth
building, or do cheaper runtime-only levers (a size-class free list in front of malloc, an iterative release) get most of it?
Method: callgrind (`--tool=callgrind`, `-O2 -g`, runtime from `main` `d297509`) on the C-backend binaries, same inputs.

### What the runtime already had

Both runtime-only options exist since ADR-0017 stage 0, so there is no malloc to remove on bintrees:
- **(a) size-class free lists:** per-thread lists for struct objects of 0..8 slots and for array headers (`fl_struct`, `fl_array`, cap
  2^18 each; off under ASan or `-DORIN_NO_FREELIST`);
- **(b) iterative release:** `orin_destroy` runs on an explicit work stack and cannot overflow the C stack on deep trees.

### Profile of bintrees (6,198,920,279 instructions, 33.4M objects, 186 instructions per node built, checked and dropped)

| where | instructions | share | per node |
|---|---:|---:|---:|
| `orin_destroy` (release of a whole tree) | 2,075,639,086 | 33.5 % | 62 |
| `orin_struct_new` (free-list pop, header, slots) | 1,403,047,254 | 22.6 % | 42 |
| `check` (generated code, incl. inlined shape checks) | 764,700,380 + 464,327,014 | 19.8 % | 37 |
| `make` (generated code) | 662,525,360 + 115,103,084 | 12.5 % | 23 |
| `orin_nullary` (the shared `Leaf`, acquire load per call) | 640,024,586 | 10.3 % | 19 |
| malloc (`_int_malloc`, start-up only) | 36,446,150 | 0.6 % | 1 |
| free | 0 | 0 % | 0 |

Inside `orin_destroy` the per-child loop (refmask test, `rc > 0` test, decrement, push) is 1.30G of the 2.08G.

### Ceilings

| option | bintrees | other benchmarks and self-compile |
|---|---|---|
| (a) free list for struct objects | already built: malloc+free = 0.6 % left, ceiling 0 | none left for structs |
| (b) iterative release | already built; tuning it is worth little. Two variants measured: bit-scan of `refmask` instead of the slot loop -1.1 % (6,132,108,519); in addition keeping the last dead child out of the work stack +1.1 % (worse, 6,265,732,079). Ceiling of the whole function if it cost nothing: -33 % | not a lever outside trees |
| (c) real regions: bump allocation, no per-object release | upper bound about -50 % instructions (destroy 62 -> about 0, `struct_new` 42 -> about 10 per node; `Leaf`, `make` and `check` unchanged). Needs escape facts or a verifier rule for "nothing outside points in" (docs/tcb.md) and a new copy-out at the boundary | nil by the census: bintrees is 100 % of class (f) and no other workload has a tree built and dropped per scope. mapfreq / wordfreq / html / sortedmap / streams have no big structure graphs: their cost is strings, array buffers and lookups |

So (a) and (b) cannot give the 5 % on bintrees (the best measured runtime-only change is -1.1 %), and (c) would give about half
of bintrees and nothing else, for the largest change to the trusted base. Decision: **regions stay deferred** (as in the census,
rank 6), and the bintrees lever is closed as "no cheap variant".

### What the profile showed instead

Strings and array item buffers were not covered by the free lists: they go straight to glibc, and the profiles of the string and
map workloads carry 15-20 % of their instructions in `malloc`/`free`/`realloc` (wordfreq 18 %, mapfreq 15 %, html 15 %, the
self-compile 9.7 %: `_int_malloc` 3.4 %, `_int_free` 2.1 %, `malloc` 1.4 %, `free` 0.8 %, `realloc` 0.8 %, `malloc_consolidate`
0.7 %, `_int_realloc` 0.5 %; glibc's tcache holds only 7 blocks per size). Extending (a) to these buffers is the cheap,
runtime-only lever that does reach the other benchmarks, so it was built.

### Change: small-block cache for string objects and array item buffers

`runtime/orin_runtime.c`: `sb_alloc` / `sb_free` / `sb_realloc` / `sb_drain`. Blocks of at most 256 bytes are allocated with their
size rounded up to 16-byte classes and cached on a per-thread list per class (cap 2^15 blocks per class, beyond which a block
goes back to the allocator). No header: the size is known at every free (strings `sizeof(OrinString) + cap + 1`, item buffers
`cap * 8`), and a grow within one class does not move the block. Larger buffers keep `realloc`. Per thread like the object lists
(a block is plain malloc memory, so a block freed on another thread just joins that thread's list), drained in
`orin_rt_heap_exit`, compiled out with them under ASan and `-DORIN_NO_FREELIST`. Runtime only: no compiler, MIR or verifier
change, no Lean change, same generated C (self-compile output identical, hash `b01183cb`).

Measurement (valgrind instructions, same inputs, `main` `d297509` against this branch; peak RSS in KiB):

| workload | instructions before | after | change | RSS before | after |
|---|---:|---:|---:|---:|---:|
| bintrees | 6,198,920,233 | 6,198,919,166 | 0 | 17,800 | 17,948 |
| mapfreq | 1,171,658,908 | 1,060,960,418 | -9.4 % | 10,604 | 11,324 |
| wordfreq | 878,433,734 | 764,400,650 | -13.0 % | 2,332 | 2,336 |
| html | 1,900,805,542 | 1,834,311,062 | -3.5 % | 3,888 | 3,932 |
| sortedmap | 1,387,524,604 | 1,361,887,373 | -1.8 % | 9,492 | 11,232 |
| appends | 119,462,891 | 99,563,401 | -16.7 % | 4,616 | 4,620 |
| strings | 694,105,349 | 647,452,075 | -6.7 % | 47,240 | 47,244 |
| bytesstr | 507,095,151 | 507,227,227 | +0.03 % | 11,784 | 11,784 |
| url | 4,977,063,136 | 4,976,046,193 | 0 | 6,612 | 6,612 |
| http_parse | 1,739,673,896 | 1,534,852,483 | -11.8 % | 1,756 | 1,756 |
| pqueue | 1,403,174,728 | 1,403,174,027 | 0 | 6,284 | 6,284 |
| mutres | 2,541,565,008 | 2,541,564,779 | 0 | 1,568 | 1,568 |
| self-compile (`compiler/main.or`) | 23,761,246,629 | 22,590,961,715 | -4.9 % | 225,328 | 229,908 |

Cost: the lists keep up to 2^15 freed blocks per class instead of returning them to glibc, so peak RSS rises where a program
frees many small buffers (sortedmap +1.7 MB, mapfreq +0.7 MB, self-compile +2.0 %).

## Addendum (2026-10-16): the pinned LLVM toolchain (section 8, gate 3)

Gate 3 of section 8 is: a pinned LLVM version is used; the pin is recorded in the repository and checked in CI;
`orin toolchain install` downloads the matching `clang`/`llc` into `~/.orin/toolchains/llvm-<version>`, verified by checksum;
`orin doctor` reports the installed version and whether it matches; without a matching LLVM, `--release` falls back to the C
backend and says so. Gates 1 and 2 were already met. **Status: met.** The release default was a separate decision (below);
the owner took it on 2026-10-16: `orin build|run|test --release` now defaults to LLVM, `--backend=c` is the explicit fallback.

- **The pin** is `dist/llvm.pin` (shipped as `lib/orin/llvm.pin`): `version 19.1.7` and, per platform (`linux-x86_64`,
  `linux-aarch64`, `macos-arm64`), the URL and sha256 of the official, unmodified LLVM release archive. There is no
  `macos-x86_64` archive in that release. `tools/test_llvm_toolchain.sh` (CI job `llvm`) checks the pin's shape.
- **Why 19.1.7, not 18.x.** The 18.1.8 Linux x86_64 archive links `libtinfo.so.5`, which current distributions no longer ship,
  so the downloaded `clang` would not start. 19.1.7 starts without it. The gates were rerun with the pinned clang (not the
  system clang 18): the whole suite with `--backend llvm` (925 passed) and `tools/llvm_fixpoint.sh` (C and IR of the LLVM-built
  compiler identical) both pass, so the textual IR is accepted by LLVM 19 without a backend change.
- **`orin toolchain install [--force]`** downloads the archive for the platform (`curl`, or `wget`), compares its sha256 with the
  pin **before unpacking**, unpacks only `bin/clang`, `bin/llc` and clang's resource directory (the full archive unpacks to
  several GB; the install is about 400 MB), checks that `clang --version` reports the pinned version, and moves the tree into
  `~/.orin/toolchains/llvm-19.1.7` in one step. A checksum mismatch, a missing platform entry, a wrong version or a failed unpack
  installs nothing. `orin toolchain status` reports the pin and the install state. `ORIN_HOME` relocates the directory.
- **Use.** `orin build|run --backend=llvm` uses the pinned clang when it is installed; an explicit `CC` wins; a dev build
  without the pinned toolchain uses the system `clang` as before. A `--release` build that asks for LLVM without the pinned
  toolchain **falls back to the C backend and prints a note** naming `orin toolchain install`. `orin doctor` reports
  "pinned 19.1.7 installed" or "not installed" (informational, never a warning: the C backend needs no LLVM).
- **Open for the owner.** (1) Whether `--release` defaults to LLVM: one variable, `release_backend=c` in `build_command`
  (`dist/orin-cli.sh`); with gates 1-3 met the decision is the owner's. (2) The release packages do not yet bundle the toolchain
  (the ADR says "may"); they ship only the pin. (3) The checksums are those of the archives downloaded while writing this change,
  not compared with a checksum published by LLVM. (4) The real download was exercised only on linux-x86_64; the aarch64 and
  macOS entries are checksummed but not run.

**Decision (2026-10-16, owner): LLVM is the `--release` default.** Without the pinned toolchain the default release build uses a system
`clang` of at least the pin's major version, else falls back to C with one note. Both backends run the same optimiser at `-O2`.

## Addendum (2026-10-16): packed arrays (b) and reuse in place for field / element in-out (e), measured first

Both levers were measured before any code (main `2fc3895`, C backend, `tools/bench.py --instructions` and `valgrind --tool=callgrind`
on the self-compile; the baseline of every benchmark is the "before" column of the table below).

### (e) in-place reuse for `x.f = g(x.f)` / `a[i] = g(a[i])`: ceiling below the gate, not built

The benchmarks cannot gain: their COW counters are 1 (`cow_copies` of all 18 workloads other than the self-compile and html/url).
Only the self-compile copies. Its ceiling for *every* copy, the inclusive cost of `orin_make_unique_slow` (callgrind):
520.5 M of 23,087 M instructions = **2.25 %** (929,236 copies, 166.9 M in-place reuses). Splitting that by caller:

| caller | inclusive | share | is it the field in/out pattern? |
|---|---:|---:|---|
| `mapSet<string,string>` (217,859 copies; `Sources` / `Tab.addUni`: `l16 = struct_get(l1,0); l21 = dup l16; mapSet(l21,..); struct_replace(l1,0,..)`) | 97.0 M + 27.6 M | 0.54 % | **yes**: the field is read (rc 2), the callee copies, the replace releases the old value; `ITakeField` (as used for `push`) would avoid it |
| `Transfer.set` / `Transfer.load` (`this.ls[l] = ..`) | 78.1 M + 65.0 M | 0.62 % | no: `ls` is shared with the in-state on purpose (`state()` hands it out); a genuine COW |
| `UniqueSet.step`, `uniqueIn`, `Fixpoint.joinInto` | 63.2 M + 29.6 M + 34.9 M | 0.55 % | no: a shared in-state array that is then written; a data-structure fix (lever 1 style), not a move-out-and-back |
| `registerLifted`, `instFunc`, `newLocal`, `ancestors`, other | 82 M | 0.35 % | no |

So the pattern named by (e) is worth at most **0.54 % of the self-compile** and nothing on any benchmark, under the gate (1 %). The
rest of the COW cost is real sharing. Not built; the recipe if a program ever needs it: an optimiser rewrite of
`getfield; dup; call g(owned); structreplace` into `takefield; call; structset` with the existing hole rules.

### (b) packed arrays: ceilings

`u8[]` is the only scalar array a benchmark or the compiler exercises through a bulk path. Users of `bytesToString` /
`stringToBytes` (the only operations that read or write a whole `u8[]` as bytes): `bench/bytesstr` and `bench/http_parse`; the
self-compile has none (`orin_bytes_to_string`, `orin_string_to_bytes` do not appear in its profile).

| experiment | bytesstr | http_parse | self-compile |
|---|---:|---:|---:|
| baseline (6 instructions per converted byte) | 507.2 M | 1,537.9 M | 24,274 M |
| ideal packed storage: both conversions free (a memcpy; hack runtime, wrong output) | about 4 M (-99 %) | about -9.0 % (`orin_bytes_to_string` is 9.03 % inclusive) | 0 |

Real packing needs the element width at `IArrayNew` / `IArrayGet` / `IArraySet` and in the `.ll` the LLVM backend inlines, or a
second array kind with a slow path in every runtime array operation (a `slot_ptr` into a packed array does not exist). That is a
MIR version (v2.7), a lowering change outside this branch's directories, a rewrite of the runtime's 40 array sites and of the LLVM
runtime IR, for one micro-benchmark (-99 %) and at most -9 % on http_parse, nothing on the compiler. Not built.

### Built: the conversion loops, 4 elements per iteration (runtime only)

What packing would have saved on those two operations is the per-byte loop, not the storage width. `orin_bytes_to_string` and
`orin_string_to_bytes` now narrow and widen 4 elements per iteration in plain C, with the same checks (`byte out of range` from
the OR of all slots, slice bounds, shape). No MIR, verifier, backend or compiler change, so no new trusted code beyond two
runtime loops.

| executed instructions (valgrind, C backend / LLVM backend) | before | after | change |
|---|---:|---:|---:|
| bytesstr, C | 507,236,033 | 370,922,073 | -26.9 % |
| bytesstr, LLVM | 506,826,797 | 328,569,037 | -35.2 % |
| http_parse, C | 1,537,904,468 | 1,535,635,006 | -0.1 % |
| http_parse, LLVM | 1,489,300,029 | 1,466,340,146 | -1.5 % |

An SSE2 version (16 per iteration) reached bytesstr -58.9 %, but `<emmintrin.h>` is outside the platform boundary
(`tools/check_platform_boundary.sh`, ADR-0030); GCC's generic vector types (`__builtin_convertvector`) stay inside it but GCC 13
compiles them worse than the plain loop (bytesstr 444 M, http_parse +5 %). The plain loop is kept; an intrinsics path would need
its own place in the platform layer. The rest of bytesstr is the 8-byte slot traffic (2 x 8 MB per round trip); only packed
storage removes it. http_parse gains little because its strings are short.

## Addendum (2026-10-17): U6 unchecked struct slots
Every `getfield` / `setfield` of a heap struct executes the check `kind == 3 && nslots > k` in both backends (`slotInline` in the LLVM backend,
`orinc_chk_slot` in C). Removing every one of them by hand from the LLVM IR of `bench/mutres` halved its executed instructions (2.03G to 1.02G) and
cut `pqueue` by 13%. This change removes the ones a verifier can justify: MIR v2.8 adds `IGetFieldU` / `ISetFieldU` (docs/mir.md), accepted by rule
**U6** (`compiler/verify/fieldcheck.or`) when an earlier access (`getfield`, `setfield`, `takefield`, `putfield`, checked or unchecked) of the same struct
local in the same block, within 64 instructions, checked slot `k' >= k` and nothing in between defines the local. Unlike the array rule U1, `makeunique`
and every other use of the local leave the fact intact, because a struct's kind and slot count never change and the copy `makeunique` makes has the
same header. The optimiser pass `compiler/opt/fieldcheck.or` asks the same predicate. `--assert-facts` does not re-check these (it needs a new runtime
symbol; runtime/ and the seed are frozen here).

A second step makes the first access of a block benefit as well. The new instruction `IShapeCheck(o, k)` is exactly the check of a field access,
alone; rule U6 also accepts it, and the `IStructNew` that builds the local (slot count known statically), as sources. The optimiser puts one
`IShapeCheck(o, K)` in front of the first checked access of a struct local in a block when later accesses of the same block (within the window, before the
local is redefined) use higher slots (K the highest), so the whole group executes one check instead of several, and the first access is unchecked too.
Insertion happens only where it removes at least one check. A struct too small for K now traps at the first access instead of the later one, with the same
message (a compiler bug either way).

Measured (executed instructions, cachegrind, LLVM backend / C backend, main vs this change): mutres 2,030M / 2,542M to 1,757M / 2,407M; pqueue 1,344M /
1,411M to 1,350M / 1,384M; bintrees 4,320M / 4,457M to 4,219M / 4,324M; nbody, qsort_inplace, html, mapfreq unchanged within 0.02%. In the self-compile
8,440 of 27,210 field accesses (31%) become unchecked, behind 2,646 shape checks. The remaining distance to the hand-removal (mutres 1.02G) is the
first access of each function on a parameter, which needs a fact across calls (a typed-parameter shape invariant) or a rule across blocks: follow-ups.
Mutation classes `field-*` and `shape-*` in `tools/mutate_mir.py` (2,556 unchecked accesses and 507 shape checks of the corpus) are all rejected, and the
positive control is accepted.
