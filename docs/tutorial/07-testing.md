# 7. Testing

Tests live next to the code, as functions marked `@Test`.

## The program

<!-- file: examples/tutorial/07-testing.or -->
```ts
// Unit tests with @Test: `orin test 07-testing.or` runs the tests, `orin run` the program.
import { assert, assertEq, assertEqString, assertEqual } from "std:test";

function clamp(x: int, lo: int, hi: int): int {
  if (x < lo) {
    return lo;
  }
  if (x > hi) {
    return hi;
  }
  return x;
}

function shout(s: string): string {
  return s.trim() + "!";
}

type Point = { x: int; y: int; };

function origin(): Point {
  return Point { x: 0, y: 0 };
}

@Test
function clampKeepsValuesInRange(): void {
  assertEq(clamp(5, 0, 10), 5, "inside");
  assertEq(clamp(-3, 0, 10), 0, "below");
  assertEq(clamp(42, 0, 10), 10, "above");
}

@Test
function shoutTrimsAndAddsBang(): void {
  assertEqString(shout("  hi "), "hi!", "trim");
  assert(shout("").length == 1, "empty input");
}

@Test
function originIsZero(): void {
  assertEqual(origin(), Point { x: 0, y: 0 }, "origin");
}

function main(): void {
  console.log(clamp(15, 0, 10).toString());
  console.log(shout("done "));
}
```

`orin run` runs the normal program; the tests are removed from it:

<!-- file: examples/tutorial/07-testing.out -->
```text
10
done!
```

`orin test` builds the tests and runs each one in its own process:

```sh
orin test examples/tutorial/07-testing.or
```

<!-- file: examples/tutorial/07-testing.test.out -->
```text
PASS 07-testing.clampKeepsValuesInRange
PASS 07-testing.shoutTrimsAndAddsBang
PASS 07-testing.originIsZero
3 passed, 0 failed
```

## What is in it

- A test is a top-level function with the `@Test` annotation, no parameters (a test that needs I/O takes
  `host: Host`) and no result. It passes if it returns and fails if it traps.
- `std:test` provides the assertions: `assert(cond, msg)`, `assertEq(actual, expected, msg)` for `int`,
  `assertEqString`, `assertEqUsize`, `assertEqBool`, `assertNear` for floats, and `assertEqual` for any type with
  `==` (records, unions, `Option`, arrays), which is what `originIsZero` uses. A failed assertion prints
  `trap: assertEq failed: below: expected 0, got 10` on standard error and the test fails with status 101.
- The file needs no `main` to be tested. If it has one, `orin test` does not run it.
- Because each test is its own process, a test that crashes, loops or exits cannot affect the others. The default time limit
  is 10 seconds per test.
- `--filter clamp` runs only tests whose name contains `clamp`; `--format=json` gives a report for tools.

In a project, `orin test` (no file) runs every `@Test` function of the package and every file named
`tests/**/*_test.or`. Chapter 9 does this. Tests run with contracts checked, which chapter 8 uses.

## Try it

Break `clamp` (return `lo` where it returns `hi`), run `orin test` and read the failure. Then restore it and use
`--filter shout` to run one test.

Reference: [testing guide](../testing.md), [annotations](../reference/07-annotations-contracts.md).

Next: [8. Contracts](08-contracts.md).
