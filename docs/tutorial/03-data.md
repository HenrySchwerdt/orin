# 3. Records, unions, Option and Result

Orin has no `null` and no exceptions. Absence and failure are ordinary values, and `match` takes them apart.

## The program

<!-- file: examples/tutorial/03-data.or -->
```ts
// Records, unions, match, Option and Result.
type Point = { x: int; y: int; };

type Shape = Circle(int) | Rect(int, int) | Empty;

function area(s: Shape): int {
  return match (s) {
    Circle(r) => 3 * r * r,
    Rect(w, h) => w * h,
    Empty => 0,
  };
}

function firstEven(xs: int[]): Option<int> {
  for (const x of xs) {
    if (x % 2 == 0) {
      return Some(x);
    }
  }
  return None;
}

function parseSide(text: string): Result<int, string> {
  return match (parseInt(text)) {
    Some(n) => n >= 0 ? Ok(n) : Err("negative side: " + text),
    None => Err("not a number: " + text),
  };
}

function squareArea(text: string): Result<int, string> {
  const side = parseSide(text)?;   // on Err, return that Err from squareArea
  return Ok(side * side);
}

function main(): void {
  const p = Point { x: 1, y: 2 };
  const q = Point { ...p, y: 5 };   // copy with one field changed
  console.log("p = " + p.x.toString() + "," + p.y.toString());
  console.log("q = " + q.x.toString() + "," + q.y.toString());
  console.log("p == q: " + (p == q).toString());

  const shapes = [Circle(2), Rect(3, 4), Empty];
  for (const s of shapes) {
    console.log("area " + area(s).toString());
  }

  match (firstEven([3, 5, 8, 9])) {
    Some(n) => { console.log("first even: " + n.toString()); },
    None => { console.log("no even number"); },
  }
  console.log("fallback: " + firstEven([1, 3]).unwrapOr(-1).toString());

  for (const input of ["7", "-1", "abc"]) {
    match (squareArea(input)) {
      Ok(a) => { console.log(input + " -> " + a.toString()); },
      Err(e) => { console.log(input + " -> error: " + e); },
    }
  }
}
```

Output:

<!-- file: examples/tutorial/03-data.out -->
```text
p = 1,2
q = 1,5
p == q: false
area 12
area 12
area 0
first even: 8
fallback: -1
7 -> 49
-1 -> error: negative side: -1
abc -> error: not a number: abc
```

## What is in it

**Records** are named bundles of fields: `type Point = { x: int; y: int; };`. You build one with
`Point { x: 1, y: 2 }`; `{ ...p, y: 5 }` copies `p` and changes one field. Records are values: `q` is a new value, `p`
is untouched. `==` compares records field by field (it works for records of integers, strings, booleans and similar; a record
with a `float` field has no `==`).

**Tagged unions** list their variants: `type Shape = Circle(int) | Rect(int, int) | Empty;`. A variant may carry values.
`match` takes a union apart and must cover every variant (or end with `_`); a missing case is a compile error. `match` is an
expression, so `area` returns it directly. Note that `type Id = int | string` is *not* a union of two types; variants
have names.

**Option** is the type of "maybe a value": `Some(x)` or `None`. `firstEven` returns `Option<int>` so the caller must deal with
the empty case; `match` does it, or `unwrapOr(-1)` supplies a default. `unwrap()` on `None` traps.

**Result** is the type of "a value or an error": `Ok(x)` or `Err(e)`. `parseInt` returns an `Option`, `parseSide` turns it
into a `Result<int, string>` with a message. Postfix `?` means "if this is an `Err`, return it from the current
function right here": `squareArea` reads the side with `parseSide(text)?` and continues only on success. `?` works on
`Result` in a function that returns a `Result` with the same error type. A function that returns `Result<void, E>` returns
`Ok()` on success.

A **trap** is different from an error: it is a bug (overflow, index out of range, `unwrap` of `None`), it stops the program
with status 101 and cannot be caught.

## Try it

Add a variant `Triangle(int, int)` to `Shape` and compile: the compiler points at the `match` that no longer covers
every case. Add the missing arm.

Reference: [types](../reference/03-types.md) (records, unions, `Option`, `Result`),
[patterns and `match`](../reference/04-expressions-statements.md).

Next: [4. Classes, interfaces and generics](04-classes.md).
