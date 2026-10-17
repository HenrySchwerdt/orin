# 5. Collections and strings

## The program

<!-- file: examples/tutorial/05-collections.or -->
```ts
// Arrays, Map and strings: a word-frequency counter.
function countWords(text: string): Map<string, int> {
  let counts = new Map<string, int>();
  for (const raw of text.split(" ")) {
    const word = raw.trim();
    if (word.length == 0) {
      continue;
    }
    counts.set(word, counts.get(word).unwrapOr(0) + 1);
  }
  return counts;
}

function main(): void {
  // Arrays
  let xs = [5, 3, 8, 1];
  xs.push(7);
  console.log("length " + xs.length.toString() + ", first " + xs[0].toString());
  const evens = xs.filter(x => x % 2 == 0);
  const doubled = xs.map(x => x * 2);
  const sum = xs.reduce((acc: int, x: int): int => acc + x, 0);
  console.log("evens " + evens.length.toString() + ", sum " + sum.toString());
  console.log("doubled: " + doubled.map(x => x.toString()).join(", "));
  console.log("xs.get(10) is none: " + xs.get(10).isNone().toString());

  // Strings
  const text = "the quick brown fox jumps over the lazy dog the end";
  console.log("has fox: " + text.includes("fox").toString());
  console.log("starts with the: " + text.startsWith("the").toString());
  console.log("first 9: " + text.substring(0, 9));
  console.log("greeting: " + "Hello, " + "world".trim());

  // Map: insertion-ordered
  const counts = countWords(text);
  console.log("distinct words: " + counts.size.toString());
  console.log("the = " + counts.get("the").unwrapOr(0).toString());
  console.log("cat = " + counts.get("cat").unwrapOr(0).toString());
  for (const e of counts.entries()) {
    if (e.value > 1) {
      console.log(e.key + " appears " + e.value.toString() + " times");
    }
  }
}
```

Output:

<!-- file: examples/tutorial/05-collections.out -->
```text
length 5, first 5
evens 1, sum 24
doubled: 10, 6, 16, 2, 14
xs.get(10) is none: true
has fox: true
starts with the: true
first 9: the quick
greeting: Hello, world
distinct words: 9
the = 3
cat = 0
the appears 3 times
```

## What is in it

**Arrays** are written `int[]` and `[5, 3, 8]`. They are values like everything else, and a `let` array can grow:
`xs.push(7)`. `xs.length` is a `usize`. Indexing `xs[0]` traps when out of range, so when an index can be wrong use
`xs.get(10)`, which returns an `Option`. The methods `map`, `filter`, `reduce`, `find`, `some`, `every`, `sort` and
`forEach` take closures (`sort` takes a comparison returning a negative, zero or positive `int`, and returns a sorted copy). An empty array needs a type (`const none: int[] = [];`). `for (const x of xs)` visits each
element.

**Strings** are immutable byte strings with UTF-8 passing through unchanged. `length` is the byte count. Methods:
`split`, `trim`, `substring(a, b)`, `includes`, `startsWith`, `endsWith`, `indexOf` (an `Option`), `charAt`, and
`parts.join(", ")` on an array of strings. `s[i]` is not allowed; use `charAt` or `substring`. For richer text work there
are `std:text` and `std:utf8` ([std.md](../std.md)).

**Map** is a generic dictionary: `new Map<string, int>()`, `set(k, v)`, `get(k)` (an `Option`), `has`, `delete`, `size`,
and `keys()`, `values()` and `entries()`, which return arrays. Iteration order is insertion order, so the output above
is deterministic. Keys may be integers, `bool`, strings, or records, unions and arrays of those. `counts.set(...)` changes
the map, so `counts` is a `let`.

The `std:collections` module adds `Set`, `OrderedMap`, `Deque`, `MinHeap` and more.

## Try it

Sort the distinct words: take `counts.keys()` and call `.sort((a: string, b: string): int => a < b ? -1 : a > b ? 1 : 0)` on it, then print the words with `join`.

Reference: [strings, arrays and Map](../reference/03-types.md), [the standard library](../std.md).

Next: [6. A command-line tool](06-cli.md).
