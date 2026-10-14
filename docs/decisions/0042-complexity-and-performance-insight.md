# ADR-0042: Complexity and performance insight (Big-O, cost, gain)

Status: accepted (2026-10-14, project owner). Related: ADR-0038 §6 (performance lint, visible
representation), ADR-0037 D2 (effect summaries, the model for modular summaries), ADR-0039
(`.parallel()`), ADR-0035 (evidence classes), ADR-0029 (actions for agents), ADR-0032 §4 (`@Decreases`).

## Context

The compiler already knows a lot about cost:
- loop structure and `@Decreases` measures;
- which calls are pure;
- where RC traffic, copies, bounds and overflow checks remain;
- which representation a value got (ADR-0038).

None of this is visible today. Developers and agents find an O(n²) algorithm or a hot loop full of checks
only by profiling. The project owner wants the compiler to **show** cost: the complexity in Big-O, and
the expected gain of a suggested change.

## Decision

### 1. Complexity summaries per function

- **Modular:** every function, method and constructor gets a complexity summary, computed like the effect
  summaries of Stage B. The summaries are composed over the call graph, and recursion is resolved as a
  fixed point with `@Decreases` measures.
- **Form:** a Big-O term over named size variables taken from the code:
  - parameters such as `xs.length`, `s.length` or `n`;
  - fields such as `this.routes.length`;
  - the measure of a `@Decreases` clause.

  Example: `route()  O(n·m)  n = this.routes.length, m = path.length`.
- **Sources:**
  - **Loop nesting and bounds:** `for of` over a collection; a `while` with a recognised counter and bound;
    loops with a `@Decreases` measure.
  - **Calls:** the callee's summary, instantiated with the argument sizes. `f` in a loop over `xs` is
    O(|xs| · cost(f)).
  - **std functions:** they carry their complexity as a built-in annotation, for example
    `@Complexity("O(log n)", n = "this.size")` on `SortedMap.get`, and `O(n log n)` on `sort`.
    - Amortised costs are marked `amortised`, for example `push`; expected costs are marked `expected`, for
      example hash lookups.
    - `@Complexity` is a closed built-in annotation, like `@Inline` (ADR-0024). User code may use it too; then
      it is a *claim* checked as below.
  - **Fusion and `.parallel()`:** ADR-0038 §2 and ADR-0039 are applied before the summary. A fused chain is
    one loop, and a parallel chain reports work and span separately: `work O(n), span O(n/p + log p)`.
- **Honesty:**
  - Where no bound is found, for example a `while` over an opaque condition, a callback of unknown origin
    or unbounded recursion, the result is **`O(?)` with the reason**, never a guess.
  - Data-dependent costs are stated as such: the term is the worst case unless marked `expected` or
    `amortised`.

### 2. Evidence classes for complexity

Complexity uses the evidence classes of ADR-0035:

| Status | Meaning |
|---|---|
| `DERIVED` | Computed from the code and summaries. Sound for the modelled constructs; the assumptions are listed (std annotations, `expected`/`amortised`). |
| `CLAIMED` | A user-written `@Complexity` the compiler could not derive. Shown as a claim, never as fact. |
| `TESTED` | A `@Complexity` claim backed by a **scaling test**. The benchmark harness runs the function at several sizes and checks the growth of the instruction count against the claim within a tolerance. |
| `CONTRADICTED` | The derived bound is strictly worse than the claim, for example a claimed `O(n)` that derives `O(n²)`. This is a warning, or an error under a policy. |

A Big-O term is never `VERIFIED` unless a later ADR adds a cost semantics to the Lean model.

### 3. Cost and gain (performance lint, ADR-0038 §6)

For hot code (loops, and functions called in loops), the compiler reports what remains:
- RC operations;
- COW copies;
- bounds and overflow checks;
- allocations, closures and indirect calls.

With each finding it names the **change that removes it** and an **estimated gain**:

```
route()  O(n·m)   n = this.routes.length, m = path.length          [DERIVED]
  ⚠ 3 bounds checks per iteration remain (UNKNOWN)
    → @Invariant(this.routes.every(r => r.handler < this.handlers.length)) lets the compiler remove them
      estimated −12 % in this loop (cost model v1)
  ⚠ filter → map not fused: the closure in line 41 calls console.log (effect)
  ✓ handlers borrowed (no RC), routes frozen
  ℹ lookup by name is O(n) per request: a Map<string, Route> makes it O(1) expected
```

- **Cost model:** the gain is computed from a cost model in which each RC operation, check, allocation and
  indirect call has a weight.
  - The weights are calibrated on the benchmark suite: the benchmark action fits them to instruction
    counts.
  - The model is versioned.
- **Estimates stay estimates:** every gain is labelled "estimated" and names the model version. `orin bench`
  measures the real effect.
- **Algorithmic advice:** the compiler suggests a better data structure (`ℹ`) only for patterns it
  recognises with certainty, for example a linear search inside a loop over the same collection. It never
  rewrites code itself.

### 4. Surfaces

The same analysis feeds every surface, as with effects.
- **CLI:** `orin perf <entry|package> [--format=json] [--function F] [--hot]`.
- **LSP:** the hover shows the complexity line and the representation; inline hints mark hot loops; code
  actions insert a suggested `@Invariant` or `Map`.
- **MCP:** `inspect` includes the summary. The JSON uses ADR-0029 actions (`FIX_CODE`, `STRENGTHEN_SPEC`)
  with the estimated gain, so agents can pick the change that pays most.
- **OSIG:** an optional `COMPLEXITY` attribute on function nodes. `orin diff` reports complexity changes in
  a PR, for example "`route()` went from O(n) to O(n²)".

### 5. Policy

`orin.toml` gets a `[complexity]` table, in the style of `[effects]` (Stage B):

```toml
[complexity."api"]
max = "O(n log n)"      # over request-derived sizes
unknown = "warn"        # O(?) in this module: warn | error | allow
```

- A function whose derived bound exceeds `max` is reported with the explaining call chain.
- An O(n²) path over request data is also a denial-of-service risk, so this policy is a security
  instrument as much as a performance one.
- Absent configuration means no restriction.

## Order

1. **With the fusion and `.parallel()` work:** loop and call summaries, `O(?)` with reasons,
   `@Complexity` on the std collections, CLI and hover. Fusion needs the same analysis of chains.
2. **With the performance push (ADR-0038):** the RC, copy and check findings, the cost model calibrated by
   the benchmark action, and the gain estimates.
3. **Afterwards:**
   - scaling tests for `TESTED`;
   - the `[complexity]` policy;
   - OSIG and `orin diff` complexity changes;
   - code actions.

## Not decided here

- A formal cost semantics, and therefore `VERIFIED` complexity bounds.
- Space complexity: memory is reported as allocations per call, not as a Big-O term.
- Cache effects and constant factors beyond the calibrated cost model.
