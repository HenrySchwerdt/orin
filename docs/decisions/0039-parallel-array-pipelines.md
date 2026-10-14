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

## Order

1. Concurrency stage 0 (ADR-0017): pool, tasks, per-thread heaps.
2. Fusion (ADR-0038 §2).
3. `.parallel()` for scalar and flat element types: `map`, `filter`, `reduce` with built-in operators, `some`,
   `every`, `find`.
4. Parallel `sort`, and `reduce` with user functions (the associativity obligation).
5. After borrow inference: all element types.
