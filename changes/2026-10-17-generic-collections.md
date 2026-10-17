- **Generic std collections (ADR-0034).** `std:collections` has `Set<T extends Hash>`, `OrderedMap<K extends Ord, V>` (B-tree) and
  `MinHeap<T extends Ord>` (4-ary heap), with contracts that state equality of keys and elements; `std:test` has
  `assertEqual<T extends Eq>`. The specialised `IntSet`, `StringSet`, `SortedMap`, `SortedStringMap` and `PriorityQueue` are unchanged.
