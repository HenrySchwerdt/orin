# 2. Values, types and functions

## The program

<!-- file: examples/tutorial/02-values.or -->
```ts
// Values, types and functions.
const LANGUAGE = "Orin"; // a top-level const must be a literal

function square(x: int): int {
  return x * x;
}

function describe(n: int): string {
  if (n < 0) {
    return "negative";
  } else if (n == 0) {
    return "zero";
  }
  return "positive";
}

function sumTo(n: int): int {
  let total = 0;
  let i = 1;
  while (i <= n) {
    total += i;
    i += 1;
  }
  return total;
}

function main(): void {
  let count = 0; // let: can be reassigned
  count += 1;
  count = count * 10;
  const flag: bool = count > 5;
  const ratio: float = 7.0 / 2.0;
  const small: u8 = 200;
  console.log("hello, " + LANGUAGE);
  console.log("count = " + count.toString());
  console.log("flag = " + flag.toString());
  console.log("ratio = " + ratio.toString());
  console.log("7 / 2 = " + (7 / 2).toString());
  console.log("small widened: " + (small.toInt() + 100).toString());
  console.log("square(12) = " + square(12).toString());
  console.log(describe(-4) + " " + describe(0) + " " + describe(9));
  console.log("sumTo(100) = " + sumTo(100).toString());
  const double = (x: int): int => x * 2;
  console.log("double(21) = " + double(21).toString());
}
```

Run it with `orin run examples/tutorial/02-values.or`:

<!-- file: examples/tutorial/02-values.out -->
```text
hello, Orin
count = 10
flag = true
ratio = 3.5
7 / 2 = 3
small widened: 300
square(12) = 144
negative zero positive
sumTo(100) = 5050
double(21) = 42
```

## What is in it

**`const` and `let`.** `const` binds a name once; `let` allows reassignment (`count += 1`). There is no `var`. Types are
inferred from the initialiser, or written: `const ratio: float = 7.0 / 2.0;`. At the top level only `const` with a literal
value is allowed (`const LANGUAGE = "Orin";`).

**Numbers.** `int` is a 64-bit signed integer, `float` a 64-bit float. There are also `i8 i16 i32`, `u8 u16 u32 u64`,
`usize` (the type of lengths and indexes) and `f32`. Types never mix implicitly: `int + float` is an error, and
`const a: float = 1;` is an error too. You convert with methods such as `small.toInt()`. Integer division truncates
(`7 / 2` is `3`); overflow and division by zero **trap** (the program stops with exit status 101) instead of wrapping.

**Text and booleans.** `string` is an immutable UTF-8 string, joined with `+`. Numbers and booleans become strings with
`.toString()`; there is no implicit conversion. `bool` is `true` or `false`, and conditions must be `bool` (`if (n)` with an
`int` is an error).

**Control flow.** `if`/`else if`/`else` and `while` need parentheses around the condition. `for (const x of xs)` loops over
an array (chapter 5). There is no C-style `for (;;)`; use `while`, as `sumTo` does.

**Functions.** Parameter and return types are written out. A function that returns a value must return on every path;
`void` functions return nothing. A function can be an expression: `(x: int): int => x * 2` is a closure. A closure takes a
snapshot of the variables it uses when it is created.

## Try it

Change `describe` so that numbers above 100 are `"big"`. Then add `const bad: int = 1.5;` to `main` and read the error;
the message tells you which type was expected.

Reference: [types](../reference/03-types.md), [expressions and statements](../reference/04-expressions-statements.md).

Next: [3. Records, unions, Option and Result](03-data.md).
