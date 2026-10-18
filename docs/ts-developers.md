# Orin for TypeScript developers

Orin looks like TypeScript on purpose, so that the largest group of developers can **read** code an
agent wrote. The risk is *false familiarity*: code that reads like TypeScript and means something
else. This page lists those places. It is short and not a tutorial.

**Same:** the syntax family. `const`/`let`, `function`, `class`, `interface`, arrow functions,
`for (const x of xs)`, template literals, `map`/`filter`, `import`/`export`, `: Type` annotations.
**Different:** the semantics. Values are copied, not shared. There is no `null`, no exceptions, no
`any`, no implicit conversion, no inheritance, and the integer type is not a double. The compiler
rejects most TypeScript habits with an error, but a few things compile and behave differently, and
those are the dangerous ones (items 1, 4, 5, 6 below). Orin is **not** TypeScript with a different
backend, it does not run JavaScript, and there is no npm.

Every Orin snippet below was compiled with the self-hosted compiler. Complete programs are in
`tests/next/run/ts_dev_*.or` (with expected output); every error example is a test in
`tests/next/errors/ts_dev_*.or` and the error text is what the compiler prints.

## 1. The differences that change meaning when you read code

### 1.1 Assignment copies. There are no shared mutable objects.

Records, classes, arrays and `Map` are values (spec 03, ADR-0002, ADR-0009).

```ts
// TypeScript: both names point at the same object
let a = new Counter(0);
const b = a;
a.increment();
console.log(a.value, b.value);   // 1 1
```
```ts
// Orin: b is an independent snapshot
let a = new Counter(0);
const b = a;
a.increment();
console.log(`${a.value} ${b.value}`);   // 1 0
```

The same holds for records (`const q = p; p.x = 5;` leaves `q.x` alone), arrays (`ys = xs; xs.push(3)`
leaves `ys` alone), function arguments and captured variables. Nothing is observably shared, so
"who else holds a reference to this?" is never a question when reading. (Under the hood the
compiler shares storage and copies lazily, so this is not an eager deep copy; `docs/architecture.md`.)
Test: `ts_dev_values.or`.

### 1.2 Mutation needs `let`, and a method call can be a mutation

A method that assigns to `this` is *mutating*. The compiler infers this; there is no `mut` keyword
(ADR-0009). A mutating method can only be called on a `let` variable. A `const` holder is frozen
all the way down, including calls, unlike TypeScript where `const` only fixes the binding:

```ts
class Counter {
  constructor(public value: int) {}
  increment(): void { this.value += 1; }   // inferred: mutating
}
const c = new Counter(3);
c.increment();   // error[E0401]: cannot call mutating method `increment` on `c`: it is not declared with `let`
```

Parameters are never mutable either. A function cannot change its argument; it returns a new value
(``error[E0401]: cannot call `push` on `xs`: it is not declared with `let` ``). To "modify" a value
inside a helper, copy it into a `let` and return it (`bumped` in `ts_dev_values.or`). Whether a
method mutates is part of the module's public API snapshot (`orin api`), so a change is visible
in review. A mutating call in a conditionally evaluated spot (`a.bump() && a.bump()`, a `?:` branch,
a `while` condition) is `error[E0408]`; put it in its own statement.

### 1.3 No `null`, no `undefined`: `Option<T>`

Absence is a value of type `Option<T>`, built with `Some(x)` and `None`, taken apart with `match`
(or `isSome()`, `unwrapOr(d)`, `unwrap()` which traps on `None`). There is no `?.` or `??`.

```ts
// TypeScript
function find(xs: number[], k: number): number | undefined { /* ... */ }
const v = find(xs, 2) ?? -1;
```
```ts
// Orin
function find(xs: int[], k: int): Option<int> { /* ... */ return None; }
const v = find(xs, 2).unwrapOr(-1);
match (find(xs, 2)) { Some(v) => { /* ... */ }, None => { /* ... */ } }
```

`null` and `undefined` are not keywords: `const a: int = null;` is ``error[E0200]: expected expression, found `null` ``. `Option<int>` is a different type from `int`; `a + 1` on an Option is a
type error. `?` is not optional chaining (see 1.4).

### 1.4 No exceptions: `Result<T, E>` and postfix `?`

There is no `throw`, `try` or `catch`. A function that can fail returns `Result<T, E>`. Postfix `?`
means *return early with the error*, not "optional":

```ts
function parse(s: string): Result<int, string> {
  return match (parseInt(s)) { Some(v) => Ok(v), None => Err("not a number: " + s) };
}
function twice(s: string): Result<int, string> {
  const v = parse(s)?;          // on Err: `twice` returns that Err right here
  return Ok(v * 2);
}
```

`?` works only on `Result`, only inside a function that itself returns a `Result`, and the error
types must be identical; there is no conversion:
``error[E0406]: error type `string` does not match the function's error type `int` ``, and on an
Option, ``error[E0406]: `?` requires a `Result`, found `Option<int>` ``. A **trap** is different from an
error: it is a defined, non-recoverable stop (exit status 101, message `trap: ...`) for bugs such as
overflow, division by zero, an out-of-range index or `unwrap()` on `None`. It cannot be caught.
Test: `ts_dev_option_result.or`.

### 1.5 `int` is a 64-bit integer, and it traps

There is no `number`. `int` is `i64`; `float` is `f64`; there are also `i8..i64`, `u8..u64`, `isize`,
`usize` and `f32`. Differences that matter:

- **Overflow traps** (`trap: integer overflow`), it does not wrap and does not turn into a float.
  Use `checkedAdd` (returns `Option`), `wrappingAdd` or `saturatingAdd` when you want another rule.
- **Integer division truncates and division by zero traps**: `7 / 2` is `3`, `-7 / 2` is `-3`, `-7 % 3`
  is `-1`, `10 / 0` traps (`trap: division by zero`). Float division follows IEEE (`1.0 / 0.0` is
  `Infinity`, `NaN != NaN`, no `%` on floats).
- **Types never mix implicitly.** `int + i32` is ``error[E0400]: cannot mix `i32` and `int`; convert explicitly``; `const a: float = 1;` is
  ``error[E0400]: expected `float`, found `int` ``. Convert with
  methods, and a conversion that does not fit **traps**:

```ts
const n: int = 200;
const b: u8 = n.toU8();          // ok
const f: float = n.toFloat() / 3.0;
const big: int = 300;
big.toU8();                      // trap: integer conversion out of range
```

- A literal that does not fit is a compile error, not a truncation:
  `const a: u8 = 300;` is ``error[E0430]: integer literal `300` does not fit in `u8` (0 to 255)``.
- Array indexes are `usize`. `a[i]` with an `int` variable is
  ``error[E0400]: expected `usize`, found `int` ``; write `i.toUsize()` (literals adapt). `a[i]` out of range **traps**; `a.get(i)` returns
  `Option<T>`. `a.length` is a `usize`.
- 128-bit integers do not exist yet (`i128`: `error[E0431]`).

Tests: `ts_dev_ints.or`, `ts_dev_trap_overflow.or`, `ts_dev_trap_divzero.or`,
`ts_dev_trap_convert.or`, `ts_dev_trap_index.or`.

### 1.6 `==` is structural, never reference equality (ADR-0034)

`==` / `!=` and `<`, `<=`, `>`, `>=` compare **values**. Integers, `bool` and `string` have all of them; `float` / `f32`
have them too, as in every language (NaN is not equal to itself). Records, tagged unions (even unit-like ones such as `Red`),
`Option`, `Result` and arrays compare structurally, field by field, variant by variant, element by element: `==` when all
their components have `==`, and the orderings lexicographically (a union orders by the position of its variant, `None`
before `Some`, `Ok` before `Err`).

```ts
type Point = { x: int; y: int; };
const p = Point { x: 1, y: 2 };
const q = Point { x: 1, y: 3 };
p == q;   // false
p < q;    // true (x equal, then y)
```

What has no `==` is a type that contains a `float` (a record with a `float` field, `Option<float>`, `float[]`), a function
value, an interface value, a resource handle and `Map`: `error[E0410]: operator is not defined for type ...` with the
reason. A class is not compared by reference either; it has no `==` unless it declares `equals` (and `compare` / `hash` for
the orderings and `Map` keys), or asks for the structural instance with `implements Eq` (`Ord`, `Hash`). The same
operations on a type parameter need a bound: `function max<T extends Ord>(a: T, b: T): T`. Tests: `ts_dev_match_union.or`,
`ts_dev_e0410_record_eq.or`, `eqord_*.or`.

### 1.7 Closures capture values, not variables

An arrow function takes a **snapshot** of the outer variables it mentions when it is created
(ADR-0011). Later changes outside are not seen, and the closure cannot assign to a captured variable.

```ts
// TypeScript prints 11            // Orin prints 2
let n = 1;                          let n = 1;
const addN = (x) => x + n;          const addN = (x: int): int => x + n;
n = 10;                             n = 10;
console.log(addN(1));               console.log(`${addN(1)}`);
```

`const inc = (): void => { n += 1; };` is ``error[E0401]: cannot modify `n`: it is captured by a closure, and closures capture variables by value (a snapshot taken when the closure is created)``. So the
usual "counter in a closure" idiom does not exist: use a class, or fold with `reduce`. Also: a
closure cannot call itself (use a top-level function), parameter types may be omitted only where
the expected function type is known (E0407), and there are no `function` expressions. Test:
`ts_dev_closure.or`.

### 1.8 No inheritance; interfaces are declared and nominal

`class B extends A` is ``error[E0408]: class inheritance (`extends`) is not supported; use composition (ADR-0009)``. There is no `protected`, `abstract`, getter/setter or static field. Shared
behaviour goes through interfaces, and conformance is **declared, never inferred** (ADR-0019):

```ts
interface Shape { area(): int; }                 // methods only: no fields, no default methods
class Square implements Shape { /* ... area() ... */ }
class Tri { constructor(public s: int) {} area(): int { return this.s; } }
show(new Tri(2));   // error[E0417]: class `Tri` does not implement interface `Shape`;
                    //   declare `class Tri implements Shape` (conformance is nominal)
```

The same is true of records: `type A = { x: int }` and `type B = { x: int }` are different types
(``error[E0400]: expected `A`, found `B` ``), unlike TypeScript's structural typing. Further:

- An interface method cannot mutate its receiver (`error[E0418]`), and a `Square[]` is not accepted
  where a `Shape[]` is expected (the one implicit conversion, class to its interface, is not lifted over
  arrays: E0400).
- No `instanceof`, no downcasts. Dispatch is a vtable call, and an interface value holds a
  *snapshot* of the class value.
- Generic bound: `function total<T extends Shape>(xs: T[]): int` is monomorphised (zero cost);
  a parameter may have several bounds (`T extends Ord & Hash`).

Tests: `ts_dev_interface.or`, `ts_dev_e0417_structural.or`.

### 1.9 `match` is exhaustive, and unions are tagged

TypeScript's `int | string` has no Orin counterpart. A union is a closed set of **named variants**,
each with optional payload; `match` must cover all of them (or use `_`):

```ts
type Id = Num(int) | Name(string);
function show(id: Id): string {
  return match (id) { Num(n) => `n${n}`, Name(s) => s };
}
```

A missing case is ``error[E0402]: non-exhaustive match: missing Square``. Beware: `type Id = int | string;`
is accepted by the compiler but is **not** a union of `int` and `string`; `const a: Id = 1;` is
``error[E0400]: expected `Id`, found `int` ``. `match` is an expression, patterns are variants,
literals and `_`; there is no `switch`. Test: `ts_dev_match_union.or`.

### 1.10 Modules have real boundaries

A directory with a `module.or` is a module; only what it `export`s (re-exported from `module.or`)
is visible, and files inside it cannot be imported from outside:
``error[E0302]: cannot import private file `pkg/internal` of module `pkg`; import the module itself``.
A name that is not exported is ``error[E0300]: `hidden` is not exported by `./lib` ``. Module imports
must form a DAG (cycles are `E0303`), and `orin.toml` can restrict which modules may import which
(`allowed_dependencies`, `E0501`). Standard library modules use `std:` (`import { withFile } from "std:fs"`).
See spec 04 and `README.md` (Packages).

### 1.11 Resources can't be stored (`File`)

A `File` is a handle, not a value. You get one as the parameter of the callback of `withFile`/
`useFile`, which opens and closes it for you on every path. It cannot be stored in a variable,
record, array or `Option`, returned, or captured by a closure (E0450, E0451, E0452):

```ts
import { File } from "std:fs";
type Log = { out: File; };
// error[E0450]: a resource type cannot be a record or class field; a resource handle can only be a parameter (borrowed)
```

So there is no `const f = openFile(...)` that you must remember to close. See ADR-0025, `docs/std.md`.

### 1.12 Template literals: same syntax, primitives only

`` `a=${a + 1}` `` works as in TypeScript for `string`, integers, `float`, `f32` and `bool`. Nothing else
interpolates, and there is no implicit `toString()` on objects:
`` `${p}` `` with a record is ``error[E0432]: cannot interpolate a value of type `P` in a template literal; only `string`, integers, `float`, `f32` and `bool` convert implicitly, convert it explicitly (call `.toString()`)``. No tagged templates, no `\u` escapes. `+` with a string and a number is also an
error (``error[E0410]: operands have different types `string` and `int` ``), and `console.log` takes a
`string`: `console.log(1)` is E0400. (ADR-0022.)

## 2. Things that are simply missing

| TypeScript feature | In Orin |
|---|---|
| npm, `require`, JS/Node interop | None. `import ... from "lodash"` is `error[E0301]: cannot find module`. Only your own modules and `std:*` (`fs`, `path`, `json`, `time`, `math`, `process`, `io`, `test`, `graph`). |
| `async`/`await`, `Promise` | Not implemented. `async function` is ``error[E0200]: expected declaration, found `async` ``; `Promise` is an unknown type. Concurrency is designed as isolated tasks with `scope`/`spawn`/channels and no function colouring (ADR-0017), after the 1.0 core. |
| Decorators, user annotations | The built-ins `@Test`, `@Deprecated`, `@Inline`, `@Sealed` and the contract clauses (`@Requires`, `@Ensures`, `@Invariant`, `@Decreases`, `@Rule`) exist. You can define your own annotation as a record type marked `@Annotation(function, field, ...)` and apply it with constant arguments (`@Route("/users", Get)`); it is checked metadata that does not change the generated code. A name that is not declared or imported as such a record is `error[E0408]: unknown annotation`. Processors that generate code from annotations are the later slices of ADR-0046. Decorators that wrap or replace a function do not exist. |
| Generic methods | `class A { id<T>(x: T): T }` works (ADR-0040), with bounds `T extends I`. Only an **interface** method may not be generic (`error[E0460]`). |
| Bit operators `& \| ^ ~ << >>` | Reserved for after 1.0 (ADR-0016): `6 & 3` is a syntax error today. No bit tricks on integers yet; `\|` already means union in type position. |
| 128-bit integers | `i128`/`u128` are `E0431` until post-1.0. |
| `number \| string`, untagged unions, intersection types | Tagged unions (1.9). No `&` in types. |
| Structural typing, object literals `{ a: 1 }`, `Record<K,V>`, index signatures | Named record types and a literal that names its type: `Point { x: 1, y: 2 }`. Use `Map<K, V>` (any `Hash` key: integers, `bool`, `string`, and records, unions, `Option`, arrays and classes with `hash` built from them) with `m.get(k): Option<V>`. |
| `any`, `unknown`, `object`, `number`, `Array<T>`, `Promise<T>` | `unknown type` (E0300). Use `int`/`float`, `T[]`, generics. |
| Conditional/mapped/template-literal types, `typeof`, `keyof`, `as` casts | None. Conversions are methods (`x.toI32()`). |
| `null`, `undefined`, `?.`, `??`, truthiness | `Option<T>`, `match`; conditions must be `bool`. |
| `throw`/`try`/`catch`/`finally` | `Result<T, E>` and `?`. |
| Inheritance, `abstract`, `protected`, getters/setters, `readonly`, static fields | Composition, interfaces; `private` exists. |
| Default, optional and rest parameters, overloads | Write separate functions. |
| Destructuring, array spread `[...a]`, tuples, `enum`, `10n` | Field access; build arrays with `push`; records; tagged unions with unit variants (`type Color = Red \| Green`). Record update `Point { ...p, y: 9 }` exists, but only with a named record type. |
| `switch`, C-style `for`, `for...in`, `++`/`--`, `===`, `var`, comma operator | `match`, `for (const x of xs)`, `while`, `+= 1`, `==`. |
| String indexing and methods: `s[0]`, `s.toUpperCase()` | The `string` API is small (`s.length`, `+`, `==`); `s[0]` is E0400 and `toUpperCase` is E0405 (no such method). See `docs/std.md` and the prelude. |
| Reflection, `eval`, prototype chain, `this` rebinding | None by design. |

### 2.1 Common mistakes coming from TypeScript

What the compiler says for the habits that come up on the first day, and what to write instead. Each row was checked with
the compiler; `orin explain <code>` has a short description of the more common codes.

| You wrote | The compiler says | Write instead |
|---|---|---|
| `for (let i = 0; i < n; i++)` | `` E0200 expected `const`, found `let` `` | `let i = 0; while (i < n) { ...; i += 1; }`, or `for (const x of xs)` over an array |
| `i++`, `i--` | `` E0200 expected expression, found `+` `` | `i += 1`, `i -= 1` |
| `a === b`, `a !== b` | `` E0200 expected expression, found `=` `` | `a == b`, `a != b` (structural, never reference equality) |
| `let count = 0;` at file level | `` E0200 expected declaration, found `let` `` | `const` at file level; keep mutable state in `main` or in a class |
| `const x = 5; x = 6;` | `` E0401 cannot assign to `x`: it is not declared with `let` `` | `let x = 5;` |
| `x: number`, `x: any`, `Promise<T>` | `` E0300 unknown type `number` `` | `int` or `float`; a concrete type or a generic `T`; no promises yet |
| `null`, `undefined` | `` E0200 expected expression, found `null` `` | `Option<T>`: `None` and `Some(x)` |
| `a?.b` | `` E0406 `?` requires a `Result`, found `Option<string>` `` | `match (a) { Some(v) => ..., None => ... }` or `a.unwrapOr(d)` |
| `return Ok(());` | `` E0200 expected expression, found `)` `` | `return Ok();` for `Result<void, E>` |
| `console.log(5)` | `` E0400 expected `string`, found `int` `` | `` console.log(`${n}`) `` |
| `"n=" + 5` | `` E0410 operands have different types `string` and `int` `` | `` `n=${5}` `` |
| `"ab".repeat(3)`, `s.toUpperCase()`, `s.padStart(5)` | `` E0405 no method `repeat` on type `string` `` | Strings have `length`, `substring`, `indexOf`, `includes`, `startsWith`, `endsWith`, `split`, `trim`, `charAt` and `+`; the rest is not in the language yet. Write a small function. |
| `xs.length()` | `` E0405 no method `length` on type `int[]` `` | `xs.length` (a property) |
| `m["a"] = 1` on a `Map` | `` E0400 cannot index into type `Map<string, int>` `` | `m.set("a", 1)` (the map must be declared with `let`), `m.get("a")` (an `Option`) |
| `s[0]` on a string | `` E0400 cannot index into type `string` `` | `s.charAt(0)` or `s.substring(0, 1)` |
| `function f(x: int) { return x; }` | `` E0400 cannot return a value from a function returning `void` `` | declare the result: `function f(x: int): int` (omitting it means `void`) |
| `if (a) {` / `while (n) {` with a non-`bool` | `` E0400 expected `bool`, found `int` `` | write the comparison: `n != 0` |
| `function f(x: int = 3)`, `x?: int` | `` E0200 expected `,` or `)`, found `=` `` | no default or optional parameters: pass every argument, or take an `Option<int>` parameter |
| `{ x: 1 }` object literal | `` E0200 expected expression, found `{` `` | declare `type P = { x: int; };` and write `P { x: 1 }`; fields end with `;` |
| `const f = function (x: int) { }` | `` E0200 expected expression, found `function` `` | `(x: int): int => x + 1` |
| `const p = P(1)` for a class | `` E0300 unresolved name `P` `` | `new P(1)` |
| `n += 1` for a field inside a method | `` E0300 unresolved name `n` `` | `this.n += 1` |
| `(x) => x + 1` | `` E0407 cannot infer the type of parameter `x` `` | `(x: int): int => x + 1` |
| `foo(1)` for a function in another file | `` E0300 unresolved name `foo` `` | `import { foo } from "./other";` and `export function foo` there |
| `import fs from "fs"` | `` E0200 expected `{`, found `fs` `` | named imports only: `import { readFile } from "std:fs";` (I/O needs a grant from `main(host: Host)`) |
| `function main(args: string[])` | `` E0412 `main` must be declared as `function main(): void` or `function main(host: Host): void` `` | program arguments come from `std:process` (`args`) with the grant from `host` |
| `const [a, b] = xs`, `const { x } = p`, `[...a, 1]` | `` E0200 expected identifier, found `[` `` | `xs[0]`, `p.x`, `a.concat([1])` |
| `switch`, `enum` | `` E0200 expected `;`, found `{` `` / `` expected declaration, found `enum` `` | `match (x) { ... }`, `type Color = Red \| Green;` |

## 3. Cheat sheet

| TypeScript | Orin |
|---|---|
| `number` | `int` (i64, traps on overflow) or `float` (f64) |
| `x: number \| undefined`, `x?: T` | `x: Option<T>` (`Some(v)` / `None`) |
| `x ?? d`, `x?.y` | `x.unwrapOr(d)`, `match (x) { Some(v) => ..., None => ... }` |
| `throw new Error(m)` / `try { } catch` | return `Err(m)`; handle with `match`; propagate with `?` |
| `Promise<T>`, `await` | not available |
| `string \| number` | `type T = S(string) \| N(int)` and `match` |
| `class B extends A` | composition, or `interface` + `implements` |
| `interface I { x: T }` (fields) | `interface I { x(): T }` (methods only), declared with `implements` |
| `const b = a` (shares the object) | `const b = a` (independent copy) |
| `a == b` on objects (reference) | structural: `a == b` compares the fields (records, unions, `Option`, arrays); a class needs `equals` or `implements Eq`; types with a `float` have no `==` (E0410) |
| `arr[i]` out of range gives `undefined` | `arr[i]` traps; `arr.get(i)` gives `Option<T>` |
| `arr.length` | `arr.length` (a `usize`) |
| `{ ...p, y: 9 }` | `Point { ...p, y: 9 }` |
| `new Map<string, number>()` | `new Map<string, int>()`; `m.get(k)` is an `Option` |
| `(x) => x + 1` | `(x: int): int => x + 1` (types may be inferred from context) |
| `` `${a}` `` | `` `${a}` ``, for primitives only |
| `i++` | `i += 1` |
| `if (x)` (truthy) | `if (x != 0)`, conditions must be `bool` |
| `switch (x) { case ... }` | `match (x) { 1 => ..., _ => ... }` (expression) |
| `x as T`, `parseInt` returning NaN | `x.toU8()` (traps if it does not fit); `parseInt(s)` returns `Option<int>` |
| `export function f` / `import { f } from "./m"` | the same; `./dir` imports `dir/module.or` |
| `fs.readFileSync(p)` (throws) | `readFile(fs, p)` returns `Result<string, string>`; the `fs` grant comes from `main(host: Host)` (no ambient file access, ADR-0027) |
| `@decorator` | built-in `@Test`, `@Deprecated`, `@Inline` only |
| `function f<T>(x: T)`, `class Box<T>` | the same; class methods may be generic too (not interface methods, E0460) |
| `(x: number) => number` (function type) | `(x: int) => int` |

## 4. Where to read more

- Syntax: `spec/01-syntax-and-grammar.md`. Types, numerics, `Option`/`Result`: `spec/02-types-and-errors.md`.
  Values, classes, interfaces: `spec/03-values-classes-interfaces.md`. Modules: `spec/04-modules-and-packages.md`.
- ADR-0002 object model (values, copy-on-write), ADR-0007 generics, ADR-0009 classes and inferred
  mutation, ADR-0011 closures, ADR-0016 1.0 scope (what is in, what is post-1.0, bit operators reserved),
  ADR-0017 concurrency design, ADR-0018 floats and `Map`, ADR-0019 interfaces, ADR-0022 integers and
  template literals, ADR-0024 annotations, ADR-0025 resources, ADR-0026 generic classes
  (all in `docs/decisions/`).
- `docs/known-limitations.md` for the current gaps, `docs/std.md` for the standard library,
  `docs/contracts.md` for `@Requires`/`@Ensures`/`@Invariant`.
