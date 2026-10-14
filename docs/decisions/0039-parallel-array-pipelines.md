# ADR-0039: Parallel array pipelines (`.parallel()`)

Status: accepted (2026-10-14, project owner). Related: ADR-0017 (isolated tasks, structured scopes), ADR-0038 §2
(closure inlining, fusion, borrow inference), ADR-0034 (proved laws for user implementations), ADR-0035 (proof
obligations), ADR-0036 (verifier fragment).

## Context

ADR-0038 §2 fuses a chain of pure `filter`/`map`/`reduce` closures into one loop. Java 8 adds `.parallel()` on top
of the same idea: a fork/join pool splits the input into chunks. In Java the rules that make this correct are only
documented, and a violation silently gives a wrong result. The rules are: no side effects, no interference, and an
associative reducer. Orin can check each of them at compile time:
- purity is inferred;
- value semantics rules out shared mutable memory;
- the verifier can prove laws.

## Decision

### 1. Surface

`xs.parallel()` returns a view on which the array API runs in parallel. It is an ordinary array API method, so there
is no new syntax and the frozen core is unchanged. Parallelism is **explicit**: the compiler never parallelises on
its own, because the cost model of an implicit choice is not predictable for the developer. The performance lint
(ADR-0038 §6) may *suggest* `.parallel()` for a large, pure chain.

### 2. Semantics: the same result as the sequential chain

| Operation | Parallel form |
|---|---|
| `map` | chunk by chunk, order preserved |
| `filter` | per-chunk filter, then an order-preserving concatenation (prefix sum of the per-chunk counts) |
| `reduce` | tree reduction over chunks of a **fixed size**; requires associativity (§3) |
| `some` / `every` | a hit cancels the remaining chunks |
| `find` / `findIndex` / `indexOf` / `includes` | the result is the *first* hit: chunks to its right are cancelled, chunks to its left run to completion |
| `sort` | parallel stable merge sort; a **barrier**: the chain is split into two parallel phases there |
| `forEach` | only with a pure closure; an effectful closure is a compile error with the hint to drop `.parallel()` |

**Within a chunk:**
- each chunk runs as one fused loop (ADR-0038 §2);
- a chunk is the unit of a fork/join task in a work-stealing pool built on ADR-0017 stage 0;
- below a size threshold the runtime runs the chain sequentially;
- the result is the same either way.

### 3. What the compiler requires

1. **Every closure in a parallel chain is pure.** Otherwise the compiler reports an error that names the effect,
   with the same reasons as the purity analysis for contracts.
2. **The `reduce` function is associative.**
   - **Built-in operators** are known to be associative: integer `+` and `*`, `min`, `max`, `&&`, `||`, `&`, `|`, `^`,
     and string concatenation, which is associative but not commutative. Associativity is enough, because chunk
     order is kept.
   - **Any other function** carries the proof obligation `f(f(a, b), c) == f(a, f(b, c))`, discharged by the verifier
     (ADR-0036). This works like the user-implementation laws of ADR-0034. When the obligation is `REFUTED`, the
     error shows the counterexample. When it is `UNKNOWN`, the build fails in strict mode and warns in runtime mode.
3. **Checked integer overflow.** Partial results are summed in a different order than in the sequential chain, so a
   partial sum may overflow where the sequential one does not, or the reverse. A parallel integer `reduce` therefore
   needs a proved range that excludes overflow for every grouping, or a wider accumulator. Without either, the
   verifier reports an `UNKNOWN` obligation.
4. **Floating-point `reduce`** is not exactly associative.
   - The **fixed chunk size**, which does not depend on the number of cores, makes the result bit-identical on every
     machine and every run.
   - That result may still differ from the sequential one. The compiler reports this as a warning, not as an error.

### 4. Memory

- Workers **borrow** the input. The structured scope guarantees that the input outlives all chunk tasks, so it is
  neither copied nor sent.
- Reference counts stay non-atomic (ADR-0017). This needs borrow inference (ADR-0038 §2), because reading a
  heap element must not touch its count.
- Until borrow inference lands, `.parallel()` is accepted only for element types without heap references:
  - scalars;
  - flat records and tuples of scalars.
  Other element types get a compile error that explains this.
- Results are built per chunk in the task's own region and moved to the caller (a unique value, so no copy).

### 5. Proof obligations and assurance

- Equivalence of the parallel and the sequential chain follows from purity, associativity and order preservation.
  It is stated once in the Lean model (ADR-0032), next to fusion.
- Differential tests compare `.parallel()` with the sequential result for every operation. The thread count varies
  between 1 and the core count, and the input size varies around the threshold and the chunk boundaries.

### 6. The parallel compiler (project owner, 2026-10-14)

The compiler uses `.parallel()` in every phase where the work splits per file, per function or per proof
obligation. It does not get a separate thread framework.

| Phase | Parallel unit |
|---|---|
| parsing | file |
| loading, resolving, collecting signatures | sequential (short) |
| checking bodies | function, against the frozen `Env` |
| lowering, MIR ownership verifier | function |
| optimiser | interprocedural summaries sequential, then per function |
| code generation | function (the text pieces are joined in a fixed order) |
| `orin verify --contracts` | proof obligation (independent Z3 runs) |
| `orin test` | `@Test` function, results reported in declaration order |

**Hard gates:**
- **Bit-identical output:** the bootstrap fixed point must keep holding, and the output must be identical to
  the sequential run for every thread count.
- **No global counters in a per-function phase:** string literal ids, fresh names and similar numbering are
  local to the function and renumbered in a fixed order after the parallel step. The compiler rewrite already
  follows this rule (docs/rewrite.md), so switching a phase to `.parallel()` stays a one-line change.
- **Shared input without copies:** `Env` and the program are frozen and borrowed by the tasks (§4). That
  needs borrow inference or `Shared<T>` (ADR-0038 §2), and it is the real prerequisite, not the threads.

**Expected gain:** about 2.5–3x on 4 cores for the self-compile. This is an estimate to be measured; Amdahl's
law applies because of the sequential load and collect phases and the final join.

**Test harness:** independently of this, the test tools (the std mutants, std and tooling test files, Z3 cases)
run their independent cases in a process pool now. That needs no Orin threads.

## Implementation status (2026-10-14)

Steps 1 to 3 of the order below are done; 4 and 5 are not. User documentation: docs/std.md "Parallel pipelines"; runtime:
docs/concurrency.md "Fork/join pool and lending".

- **Surface (§1).** The array method `parallel()` returns a view `Parallel<T>` (prelude `array/parallel.or`, loaded only for a
  file that calls it, so other programs compile to the same code as before). Methods: `map`, `filter` (views), `reduce`, `some`,
  `every`, `find`, `findIndex`, and `toArray()` to get the elements (a view is not an array; `toArray` is the one addition to the
  sketch). Not yet: `sort`, `forEach`, `indexOf`, `includes`.
- **Semantics (§2).** Fixed chunks of 4,096 elements, kept by every operation (a filtered chunk may become empty); results in
  chunk order; `reduce` folds each chunk, then `init` with the chunk results, left to right; early-exit operations cancel the
  chunks after the first hit and run every chunk before it. Below 8,192 elements, or with one thread, the chunks run in order
  on the calling task: the same result. Without the optimiser every operation runs on its own (the prelude functions); with it,
  a chain becomes one fused loop per chunk (`compiler/fuse`), with the same result: grouping by chunks of the SOURCE array
  makes fused and unfused bit-identical, also for floats.
- **Requirements (§3).** E0484: every function is a pure arrow function or named function (the message names the effect and
  where it happens). E0485: the reducer is a built-in associative operator (`+` on integers, floats and strings, `*`, `&&`,
  `||`, min and max as `?:` of a comparison or `Math.min` / `Math.max`), a user function needs the proof obligation of §3.2,
  which is step 4. §3.3, the simplest sound rule: unsigned `+` is accepted silently (a partial sum is at most the total, so it
  overflows only when the total does); signed `+` and any `*` warn (W0481), because a chunk's partial result can overflow where
  the sequential fold does not, or the reverse. §3.4: a float `reduce` warns (W0480).
- **Memory (§4).** Element types of the input: scalars and records of scalars (E0486); stages may produce any type. The input is
  LENT, not copied: the runtime pins its graph (counts frozen, so inline retain / release do not write them) while the workers
  run; a transfer by the owner shares pinned objects, a transfer by anybody else copies them, so no result refers into the lent
  graph after the lend ends. Results are built per chunk and moved to the caller. Lending is the temporary runtime C of
  ADR-0017 (TESTED_ONLY), to move to Orin with R3.
- **Pool.** `std:task` `forkJoin` / `forkJoinUntil`: a pool per call, `ORIN_THREADS` (or the processors online) worker tasks,
  work stealing over chunk ranges (`std:taskcore` `Ranges`, invariants checked by `orin test`); a panic in a chunk cancels the
  rest, joins every worker and traps the caller with the chunk's own message.
- **Tests (§5).** `tests/next/run/par_ops.or` (every operation against the sequential chain at sizes 0, 1, 2, 4095 to 4097,
  8191 to 8193, 12287 to 12289, 40000), `par_float_reduce.or`, `par_trap.or`, `tests/concurrency/par_pipelines.or`, seven error
  tests; `tools/test_parallel.sh` runs them fused, `--no-fuse` and `--no-opt` with ORIN_THREADS = 1 .. 8 and the default, then
  under ThreadSanitizer (2, 4, 8 threads) and ASan + UBSan; it is part of `tools/test_concurrency.sh`.
- **Measured** (`bench/streams_parallel`, docs/benchmarks.md): no speedup could be measured on the shared 4-core machine (load
  average 15 to 22 while measuring: a process got about half of one core); the CPU time of the parallel runs equals the
  sequential one within noise (no measurable overhead of chunking, lending or the pool). The speedup claim waits for an idle
  machine.
- **Not done:** parallel `sort` and user reducers with the associativity obligation (step 4), all element types (step 5), a
  persistent pool (needs process-wide state), the Lean statement of §5, the parallel compiler of §6. A parallel `some` /
  `every` / `find` / `findIndex` whose predicate can trap may trap on an element after the first match (a chunk to the right
  may run before the hit is known); documented, not prevented.

## Order

1. Concurrency stage 0 (ADR-0017): pool, tasks, per-thread heaps.
2. Fusion (ADR-0038 §2).
3. `.parallel()` for scalar and flat element types: `map`, `filter`, `reduce` with built-in operators, `some`,
   `every`, `find`.
4. Parallel `sort`, and `reduce` with user functions (the associativity obligation).
5. After borrow inference: all element types.
