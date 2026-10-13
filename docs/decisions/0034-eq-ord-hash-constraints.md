# ADR-0034: `Eq`, `Ord` and `Hash` constraints on type parameters

Status: proposed (2026-10-13). Additive to the frozen language core (ADR-0016 rule: additive
features after the freeze need an ADR). Related: ADR-0019 (interfaces), ADR-0026 (generic
classes with `T extends I` bounds), ADR-0030 (std uses the best known algorithm), ADR-0031
(contracts over generic values).

## Context

`==`, `<` and hashing are not available on a type parameter, and `Map` keys must be concrete
`int`/`usize`/`bool`/`string`. As a result the std ships `IntSet`/`StringSet` and int/string-only
`SortedMap`s instead of `Set<T>`/`SortedMap<K, V>`. Generic containers cannot state "the value you
get back equals the value you put in" in their contracts.

## Decision

1. **Three built-in constraint interfaces:**
   - `Eq` gives `==`/`!=`;
   - `Ord extends Eq` gives `<`, `<=`, `>`, `>=` and `compare`;
   - `Hash extends Eq` gives a hash used by `Map`/`Set`.

   They are used like any bound: `class Set<T extends Hash>`, `function max<T extends Ord>(...)`.
2. **Structural instances, derived by the compiler** (value semantics make structural equality
   the natural meaning):
   - `int`, the fixed-width integers, `usize`, `bool` and `string` are `Eq + Ord + Hash`;
   - floats are **not** `Eq`/`Hash` (NaN), and ordering them needs an explicit `totalOrder`
     wrapper;
   - records, enums/tagged unions, `Option`, `Result` and arrays are `Eq`/`Hash` when all their
     components are, and `Ord` lexicographically when all components are `Ord`;
   - classes opt in with `implements Eq` (structural over fields) or by declaring
     `equals`/`compare`/`hash` methods with contracts.
3. **Laws as contracts.** A user-defined instance must satisfy:
   - reflexive, symmetric and transitive `equals`;
   - a total order consistent with `equals`;
   - `a == b ⇒ hash(a) == hash(b)`.

   These are checked as `@Property` tests (ADR-0031 §17). For Z3, `Eq`/`Ord` on `T` are
   uninterpreted relations with exactly these axioms, so generic container contracts become
   verifiable.
4. **`Map<K, V>` accepts `K extends Hash`.** The existing concrete key types keep working
   unchanged.
5. **No implicit instances for function values or resources** (handles). They are neither `Eq`
   nor `Hash`.

## Consequences

- `std:collections` gets `Set<T>`, `SortedMap<K extends Ord, V>` (B-tree) and
  `PriorityQueue<T extends Ord>`. The int/string versions become aliases or are removed before the
  std I/O freeze.
- Generic container contracts can state value equality ("get after put returns the value").
- This needs checker, lowering (instance dictionaries or monomorphised `==`/`hash`), VC and docs
  work. It comes after rewrite step 2b, because it touches the checker's body rules, and before the
  std I/O freeze, because it changes the collection APIs. `std:net`/`std:http` do not depend on
  it: header maps use string keys.
