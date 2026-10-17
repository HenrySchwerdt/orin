- **`Eq`, `Ord` and `Hash` constraints (ADR-0034, slice 1).** `function max<T extends Ord>(a: T, b: T): T`, `class Counter<K extends Hash>`:
  the built-in constraint interfaces give `==`/`!=` (`Eq`), `<`/`<=`/`>`/`>=` and `compare` (`Ord`) and `hash` (`Hash`) on a type
  parameter. Integers, `bool` and `string` have all three; records, tagged unions, `Option`, `Result` and arrays are derived
  structurally by the compiler (fields in order, variants by position), so `==` and `<` now work on them directly; a type with a
  `float` component, a function value or a resource has no instance (E0475, `==` on it stays E0410). A class declares `equals`,
  `compare` and/or `hash` itself (E0476 when unusable) or writes `implements Eq` for the structural instance. `Map<K, V>` accepts any
  `Hash` key (records, unions, arrays, `Option`, classes with `hash`) and `K extends Hash` in generic classes; the existing key types
  are unchanged. New codes E0475 and E0476. Strings are now ordered (`"a" < "b"`). The std collections (`Set<T>`, generic `SortedMap`)
  and the tier-3 law proofs are the next slice.
