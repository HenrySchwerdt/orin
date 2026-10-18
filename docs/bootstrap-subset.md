# Orin Bootstrap Subset (Orin-B) — frozen contract v1

> **Historical.** This is the contract of the Rust Stage 0, which is retired (it lives on the branch
> `archive/stage0-final`, commit `ec1ba3e`; see `docs/bootstrap.md`). `compiler/` is **no longer
> restricted to Orin-B**: it may use any language feature the current seed compiles. The diagnostics table
> below stays valid until it moves to `docs/diagnostics.md` in a later cleanup PR.

This is the **frozen language subset** implemented by the Stage 0 compiler (`bootstrap/`, Rust)
and used to write the Stage 1 compiler (`compiler/`, Orin). It is a strict subset of the
language in `spec/`; every program accepted here must keep its meaning in full Orin.
Deviations / interpretations of OPEN spec points are recorded in `docs/decisions/`.

Do **not** extend this subset without an ADR. If something is missing, write the Orin code
differently.

## 1. Lexical

- UTF-8 source, extension `.or`. Comments `// ...` and `/* ... */` (not nested).
- Identifiers: `[A-Za-z_][A-Za-z0-9_]*`.
- Keywords: `const let function return if else while for of break continue type import
  export from match true false`. Reserved (error if used): `var` (dedicated error E0201),
  `class interface enum new this null undefined async await`.
- Integer literals: decimal `123`, hex `0x7F`; `_` is not allowed. Value must fit in i64.
  No float literals in Orin-B.
- String literals: double quotes only. Escapes: `\n \t \r \0 \\ \" \'` and `\xHH`.
  Strings are byte strings (UTF-8 bytes passed through unchanged).
- Punctuation: `( ) { } [ ] , ; : . ... ? => = += -= *= /= %= + - * / % == != < <= > >= && || ! |`.

## 2. Declarations (top level only)

```ts
import { a, B } from "./path";          // relative module, or "std:fs" / "std:process"
export function f(x: int, s: string): bool { ... }
function g(): void { ... }               // private to the file's module
export type Point = { x: int; y: int; }; // nominal record
type Shape = Circle(int) | Rect(int, int) | Empty;  // tagged union
type Name = string;                      // alias (transparent)
export const MAX: int = 10;              // top-level const: literal initializer only
export { f, Point } from "./other";      // re-export (used in module.or)
```

- A `type` whose right side is `{ ... }` declares a nominal record. Fields end with `;`.
- A `type` whose right side contains `|` or a `Name(...)` member declares a **tagged union**;
  each member is a *variant*: `Name` or `Name(T1, T2, ...)`. Variant names are module-level
  value names (constructors) and must be unique in their module. Importing or re-exporting a
  union type also brings all its variants into scope (ADR-0004).
- Otherwise a `type` is a transparent alias.
- Generic type parameters (`type X<T>`, `function f<T>`) are parsed but rejected
  (E0408) in Orin-B (the self-hosted compiler accepts them, see ADR-0007; Stage 0 does not). Built-in generic types: `T[]`, `Option<T>`, `Result<T, E>`.
- Top-level `const` initializers must be a literal (`int` possibly negated, `string`, `bool`).
- Entry point: the entry file defines `function main(): void` or `function main(host: Host): void` (the forms and errors are in [reference/04](reference/04-expressions-statements.md), EXP-19).
- Duplicate names in one module → E0304. Declaration order does not matter at top level
  (functions and types may be mutually recursive).

## 3. Types

`int` (i64), `usize` (u64 on all Orin-B targets), `bool`, `string`, `void`,
`T[]`, `Option<T>`, `Result<T, E>`, named records, named tagged unions.
Recursive types are allowed (all non-scalar values are heap objects).

- No implicit conversions. Integer literals adopt the expected integer type (`int` or
  `usize`) if one is known, else `int`. In a binary operator, a literal operand adopts the
  type of the other operand.
- `[]`, `None`, `Ok(..)`, `Err(..)` need an expected type when it cannot be inferred
  (E0407), e.g. `let xs: int[] = [];`.

## 4. Statements

```ts
const x = e;  const x: T = e;  let y = e;  let y: T = e;   // initializer required
place = e;  place += e;  -= *= /= %=                       // place rooted at a `let` local
if (c) { } else if (d) { } else { }
while (c) { }
for (const x of array) { }        // iterates over a snapshot of the array value
break;  continue;  return;  return e;
e;                                // expression statement
{ ... }                           // nested block
```

- Block scoping, no hoisting. Shadowing an outer-block name is allowed; redeclaring in the
  same block is E0304.
- A *place* is `local`, `place.field`, or `place[index]`. Assignment requires the root to be a
  `let` local (E0401 otherwise). Function parameters are immutable.
- Value semantics: `const b = a; a.x = 1;` leaves `b` unchanged (copy-on-write).
- Non-void functions must return on every path (E0403). Conservative rule: the last
  statement of the body (recursively through if/else and match blocks) must return or diverge;
  `while (true)` without `break` diverges.

## 5. Expressions (precedence high → low)

1. Primary: literal, name, `( e )`, `[a, b]`, record literal `Point { x: 1, y: 2 }`,
   record update `Point { ...p, y: 3 }` (spread must come first), `match`.
2. Postfix: call `f(a)`, member `e.f` / `e.m(a)`, index `e[i]`, propagate `e?`.
3. Unary: `!e`, `-e`.
4. `* / %`  5. `+ -`  6. `< <= > >=`  7. `== !=`  8. `&&`  9. `||`  10. `c ? a : b` (right-assoc).

- Postfix `?` vs conditional: after a postfix expression, `?` is **postfix propagation** if
  the next token cannot start an expression (`) ] } , ; . ? :` or EOF); otherwise it starts a
  conditional expression (ADR-0003).
- Arithmetic on `int`/`usize` is checked: overflow, underflow, division/modulo by zero trap.
- `==`/`!=` need both sides of the same type with an `Eq` instance (ADR-0034): the integer types, `bool`, `string`, `float`/`f32`
  (IEEE) natively, and records, unions, `Option`, `Result`, arrays and classes (with `equals` or `implements Eq`) structurally; a type
  with a function or `Map` component, or a class without an instance, is E0410. `< <= > >=` need an `Ord` instance: the integer types
  and floats natively, and `bool`, `string` (byte-wise), records, unions, `Option`, `Result`, arrays and classes (with `compare`) by
  derivation. `&& || !` only on `bool`. `+` also concatenates two strings.
- Calls: `f(args)` for functions; `Name(args)` for variant construction; nullary variant is
  just `Name`.
- `e?` requires `e: Result<T, E>` inside a function returning `Result<U, E>` (same `E`); the
  value is `T` (E0406 otherwise).
- Record literal must list every field exactly once unless a spread is given (E0411).

### Match

```ts
const n = match (shape) {
  Circle(r) => r * r * 3,
  Rect(w, h) => w * h,
  Empty => 0,
};
match (opt) {
  Some(v) => { console.log(v); },
  None => { return; },
}
```

- Patterns: `Variant`, `Variant(p1, p2)` where each sub-pattern is a binding name or `_`,
  wildcard `_`, int/string/bool literal (scrutinee of that type). Binding sub-patterns only bind;
  nested variant patterns are not in Orin-B.
- Arms are separated by `,`; a trailing `,` is allowed; a comma after a block arm is optional.
- Arm body is an expression or a block. In expression position, each block arm must
  diverge (end in `return`/`break`/`continue`) — its type is then ignored.
- Matches on unions/Option/Result must be exhaustive (or have `_`); matches on
  int/string/bool must have `_` (E0402).

## 6. Built-in API (Orin-B core)

Global objects/functions (no import needed): `console.log(s: string): void`,
`console.error(s: string): void`, `String.fromCharCode(c: int): string`,
`parseInt(s: string): Option<int>` (decimal, optional leading `-`, no whitespace).

**Since ADR-0027 (capability grants) every function below that touches the outside world takes the grant that
authorises it as its first argument; the grant comes from `main(host: Host)` through `std:host`.** The signatures are the
ones listed here with the extra leading parameter; `main()` without `host` has no I/O authority (E0470).

`import { readFile, writeFile, exists, FsGrant } from "std:fs";`
- `readFile(fs: FsGrant, path: string): Result<string, string>`
- `writeFile(fs: FsGrant, path: string, data: string): Result<void, string>`
- `exists(fs: FsGrant, path: string): bool`

`import { args, exit, ProcessGrant } from "std:process";`
- `args(proc: ProcessGrant): string[]` (excludes the program name); `exit(code: int): void` (needs no grant).

`Result<void, E>` success value is written `Ok()`.

Beyond Orin-B (self-hosted compiler only; Stage 0 rejects the import with E0301): standard module
`std:io`, `import { readBytes, readLine, writeStdout, shell } from "std:io";` (a `StdioGrant` first; `shell` takes the `ProcessGrant`)
- `readBytes(stdio, n: usize): Option<string>`: exactly `n` bytes from stdin, `None` if end of input is
  reached first (the bytes read so far are discarded); `readBytes(0)` is `Some("")`.
- `readLine(stdio): Option<string>`: the next line without its `\n` (or `\r\n`), `None` at end of input.
  A final line without a newline is returned; an empty stream yields `None`.
- `writeStdout(stdio, s: string): void`: writes `s` to stdout without a newline and flushes. It shares
  the stdio buffer with `console.log`, so output order is preserved.
- `shell(proc, cmd: string): int`: runs `cmd` with `/bin/sh -c`, returns the exit status (-1 if it could not
  run or was killed by a signal). Used by `orin mcp` (`test`/`build`, only with `--allow-exec`).
Strings are byte strings. Used by `orin lsp` (`compiler/lsp/stdio.or`); runtime in
`runtime/core/orin_runtime_io.h` (header-only, included by generated C of both backends).

Methods/properties:

| Receiver | Member | Type / behaviour |
|---|---|---|
| `string` | `.length` | `usize` (bytes) |
| | `.charCodeAt(i: usize)` | `int` byte value; trap if out of range |
| | `.charAt(i: usize)` | `string` of one byte; trap if out of range |
| | `.substring(a: usize, b: usize)` | `string`; trap unless `a <= b <= length` |
| | `.indexOf(s: string)` | `Option<usize>` |
| | `.includes(s)`, `.startsWith(s)`, `.endsWith(s)` | `bool` |
| | `.split(sep: string)` | `string[]` (sep must be non-empty, else trap) |
| | `.trim()` | `string` (ASCII whitespace) |
| `T[]` | `.length` | `usize` |
| | `xs[i]` (i: `usize`) | `T`; trap if out of range |
| | `.get(i: usize)` | `Option<T>` |
| | `.push(v: T)` | `void`; receiver must be a mutable place |
| | `.pop()` | `Option<T>`; receiver must be a mutable place |
| | `.slice(a: usize, b: usize)` | `T[]`; trap unless `a <= b <= length` |
| | `.concat(ys: T[])` | `T[]` |
| `string[]` | `.join(sep: string)` | `string` |
| `int` | `.toString()` / `.toUsize()` | `string` / `usize` (trap if negative) |
| `usize` | `.toString()` / `.toInt()` | `string` / `int` (trap if > i64 max) |
| `bool` | `.toString()` | `"true"` / `"false"` |
| `Option<T>` | `.isSome() .isNone()` `.unwrap()` `.unwrapOr(d: T)` | `unwrap` traps on `None` |
| `Result<T,E>` | `.isOk() .isErr()` `.unwrap()` `.unwrapErr()` | unwrap traps on wrong variant |

## 7. Modules

- `import { names } from "./rel/path"` resolves (relative to the importing file's directory)
  to `rel/path.or`, else `rel/path/module.or`. `../` is allowed.
- Only declarations marked `export` (or re-exported) can be imported (E0300 otherwise).
- **Module boundary:** a directory containing `module.or` is a module. A file outside that
  directory may only import the directory itself (i.e. its `module.or`), never a file inside
  it (E0302).
- Import cycles between files are rejected (E0303).

## 8. Runtime behaviour

- Program output: `console.log` writes the string plus `\n` to stdout.
- A **trap** prints `trap: <reason>` to stderr and exits with status **101**.
- `exit(n)` flushes stdout and exits with status `n`.
- Evaluation order is left to right; `&&`, `||`, `?:` short-circuit.

## 9. Diagnostics

Format: `path:line:col: error[CODE]: message` on stderr, exit status 1. Codes:

| Code | Meaning |
|---|---|
| E0100 | lexical error |
| E0200 | syntax error |
| E0201 | `var` is not allowed (use `const` or `let`) |
| E0300 | unresolved name / not exported |
| E0301 | module file not found |
| E0302 | import of a private file inside another module |
| E0303 | import cycle |
| E0304 | duplicate definition |
| E0400 | type mismatch |
| E0401 | assignment/mutation of an immutable binding |
| E0402 | non-exhaustive or invalid match |
| E0403 | missing return |
| E0404 | wrong number of arguments |
| E0405 | unknown field, method or variant |
| E0406 | invalid use of `?` |
| E0407 | cannot infer type |
| E0408 | feature not supported in Orin-B |
| E0409 | `break`/`continue` outside a loop |
| E0410 | invalid operand types for operator |
| E0411 | missing/duplicate/unknown record literal field |
| E0412 | invalid or missing `main` |
| E0413 | generic instantiation limit exceeded (self-hosted compiler only, ADR-0007) |
| E0414 | contract expression is not `bool` (`@Decreases`: not `int`/`usize`) — beyond Orin-B (ADR-0012, `docs/contracts.md`) |
| E0415 | invalid use of `result`-scope features in a contract: `old(..)` outside `@Ensures` or nested, `==>` outside a contract expression, `?` in a contract, a parameter named `result` (or a variable `loopIndex` in a `for .. of` invariant) hiding it — beyond Orin-B (ADR-0012) |
| E0416 | impure contract expression: I/O or other effect, mutating call, call of a function that is not provably pure (inferred over the call graph; pure closures are allowed, ADR-0031 A4) — beyond Orin-B (ADR-0012) |
| E0417 | class does not implement an interface method / type does not satisfy a bound (self-hosted compiler only, ADR-0019) |
| E0418 | method implementing an interface method mutates its receiver (self-hosted compiler only, ADR-0019) |
| E0430 | integer literal does not fit its type (`const x: i8 = 128`, a `u64`-only literal above 2^63-1 used as another type) — beyond Orin-B (ADR-0022) |
| E0431 | the 128-bit integer types `i128` / `u128` (and `toI128`, `parseU128`, ...) are not supported yet — beyond Orin-B (ADR-0022) |
| E0432 | a value that is not `string`, an integer, `float`, `f32` or `bool` interpolated in a template literal — beyond Orin-B (ADR-0022) |
| E0440 | annotation on a declaration it does not apply to (`@Test` on a method or class, `@Inline` on a class or type, `@Deprecated` on a constant, field, constructor, import or statement; `@Annotation` on anything but a record type; a user annotation on a target missing from its `@Annotation(..)` list, or on a constructor, import or statement) — beyond Orin-B (ADR-0024, ADR-0046) |
| E0441 | wrong annotation arguments: `@Test(..)` / `@Inline(..)` take none, `@Deprecated` needs exactly one string literal; `@Annotation(..)` needs one or more distinct target words (`function method class type interface field const`); an argument of a user annotation that is missing, surplus, of the wrong type or not a constant — beyond Orin-B (ADR-0024, ADR-0046) |
| E0442 | duplicate annotation on one declaration (built-in or user-defined) — beyond Orin-B (ADR-0024, ADR-0046) |
| E0443 | invalid `@Test` function: generic, has parameters, or does not return `void` — beyond Orin-B (ADR-0024) |
| E0444 | `@Inline` function that is part of a call cycle (recursive) — beyond Orin-B (ADR-0024) |
| E0445 | a `@Test` function is called or used as a value (tests are only run by `orin test` and erased from ordinary builds) — beyond Orin-B (ADR-0024) |
| E0446 | a field of an `@Annotation` record has a type an annotation cannot hold (allowed: `bool`, `int`, `usize`, `float`, `f32`, `string`, a union of payload-free tags, and arrays and `Option`s of those), or the record is generic — beyond Orin-B (ADR-0046) |
| E0447 | an `@Annotation` definition takes a reserved name (`Test`, `Deprecated`, `Inline`, `Sealed`, `Annotation`, `Processor`, `Requires`, `Ensures`, `Invariant`, `Decreases`, `Rule`), or an identifier starts with `__g` (reserved for generated code) (ADR-0046) |
| E0475 | a type does not satisfy `Eq` / `Ord` / `Hash`: a type argument for a `T extends Eq/Ord/Hash` bound (function or class), a `Map` key that is not `Hash` (a record with a `float`, a function value, a class without `hash`, ...) — beyond Orin-B (ADR-0034) |
| E0476 | an explicit `equals` / `compare` / `hash` of a class cannot be used: wrong signature (`equals(other: C): bool`, `compare(other: C): int`, `hash(): usize`), static, private or mutating; or `implements Ord` / `Hash` next to an explicit `equals` without the matching `compare` / `hash` — beyond Orin-B (ADR-0034) |
| E0477 | two bounds of one type parameter (`T extends A & B`) declare a method of the same name with different signatures (self-hosted compiler only) |
| W0440 | **warning** (never fails a build): use of a `@Deprecated` symbol; printed as `warning[W0440]`, JSON `"severity":"warning"`, LSP severity 2 with the Deprecated tag — beyond Orin-B (ADR-0024) |
| W0450 | **warning**: `@Invariant` of a class or record that mentions no `this` (constrains no state) — beyond Orin-B (ADR-0028) |
| W0451 | **warning**: `@Ensures` that mentions neither `result` nor (non-static method) `this`; parameters are immutable, so it cannot fail — beyond Orin-B (ADR-0028) |
| W0452 | **warning**: syntactically trivially true contract (`true`, `x == x`, `x <= x`, `x >= x`, `a.length >= 0`, `s.length >= 0`, `m.size >= 0`, literal comparisons) — beyond Orin-B (ADR-0028) |
| W0460 | **warning** (`orin verify --contracts`, solver-proved): clause valid without premises — beyond Orin-B (ADR-0028) |
| W0461 | **warning** (`orin verify --contracts`): the `@Requires` of a function are unsatisfiable — beyond Orin-B (ADR-0028) |
| W0462 | **warning** (`orin verify --contracts`): `@Ensures` implied by the `@Requires` alone — beyond Orin-B (ADR-0028) |
| W0470 | **warning**, strict mode only: class with state and no `@Invariant` — beyond Orin-B (ADR-0028) |
| W0471 | **warning**, strict mode only: public method that mutates `this` and has no `@Ensures` — beyond Orin-B (ADR-0028) |
| E0473 | a module may perform an effect outside its `[effects]` allowance in `orin.toml` (transitive; the notes carry the explanation path) — beyond Orin-B (ADR-0037 D2/D4, docs/capabilities.md) |
| E0474 | an `[effects]` `allowed` entry names no effect the compiler knows — beyond Orin-B (docs/capabilities.md) |
| E0448 | invalid `@Processor(A)`: not an exported top-level function `(input: Input): Output` with both types from `std:meta`, generic, called `main`, `A` not an `@Annotation` record declared in the same module, a second processor for `A`, `@Processor` on anything but a function, or a processor that is not pure (the message carries the explanation of check/purity.or, e.g. `performs I/O (console.log)`) (ADR-0046 S5) |
| E0449 | a companion module (`./m.gen`) generates one name more than once and at least one of them is exported (ADR-0046 S4) |
| E0520 | a processor run failed or its output is unusable. Failed run (ADR-0046 S5): the helper trapped (exit 101), timed out (`--processor-timeout`), exited with a status, wrote more than 16 MiB, could not be built (C compiler or loader error), or the output has more than 10,000 generated declarations; the message names the processor, the annotation use and the module, the note carries the captured stderr. Unusable output (also the recorded output of the test hook): not JSON, wrong format or version, missing key, unknown declaration kind, invalid identifier, unsupported construct, import of a module the program has not loaded, unknown diagnostic reference (ADR-0046 S4) |
| E0521 | cyclic companion: `./a.gen` imported while `a` is loading, or a module that runs a processor depends on a companion (ADR-0046 S4) |
| E0522 | a processor reported an error diagnostic (ADR-0046 S4) |
| W0490 | **warning**: processors not run: `orin check` has no C compiler and no cached output for a processor; the companion module stays empty (ADR-0046 S5) |
| W0491 | **warning**: a processor reported a warning (ADR-0046 S4) |
| W0492 | **warning**: the processor of an annotation from a dependency was not run because `[annotations] processors` of orin.toml does not list it (ADR-0046 S5) |
| E0500 | `orin.toml` syntax error (beyond Orin-B; self-hosted compiler only, spec 04) |
| E0501 | import violates a module's `allowed_dependencies` rule in `orin.toml` (beyond Orin-B) |
| E0502 | `orin.toml` names a module that does not exist (no `module.or`), in `[modules.x]` or `[effects.x]` (beyond Orin-B) |
| E0503 | invalid `orin.toml` (unknown key/table, wrong value type, missing `[package] name`, an `[architecture]` flag set to `false`, a malformed `[effects]` table) (beyond Orin-B) |

Beyond Orin-B (self-hosted compiler only), contract clauses `@Requires`, `@Ensures`, `@Invariant`,
`@Decreases`, `@Rule` (ADR-0012) reuse existing codes where the failure is not specific to
contracts: E0200 (a clause in the wrong place, e.g. `@Ensures` on a class), E0300 (`result` outside
`@Ensures`, or in a `void` function; unknown names), E0408 (a `@Name` that is neither a contract clause,
a built-in annotation (`@Test`, `@Deprecated`, `@Inline` of ADR-0024), nor an `@Annotation` record declared or imported
in the module (ADR-0046); `@Invariant` on a generic record).

## 10. Clarifications (v1.1, from conformance-suite review)

- `/` truncates toward zero; `%` result has the sign of the dividend (`-17 / 5 == -3`, `-17 % 5 == -2`).
- `split` follows JS: `"a,,b".split(",")` → `["a", "", "b"]`; `"".split(",")` → `[""]`;
  leading/trailing separators produce empty strings. `trim` strips ` \t\n\r` (and `\v \f`).
- `parseInt`: optional `-`, then ≥1 decimal digit, nothing else; `""`, `" 5"`, overflow → `None`.
- Expected types flow into `?:` branches, match arms, call arguments, array elements, record
  fields, `return` values and `push` arguments.
- `Result<void, E>` success pattern is `Ok()` (arity 0).
- `Name { ...base }` with no overrides is allowed. Trailing commas are allowed in array literals,
  call arguments, record literals and match arms. Negative int literal patterns are allowed.
- A new local is not in scope in its own initializer: `const x = x + 1;` in an inner block reads
  the outer `x`.
- Top-level `const` type annotation is optional (literal type: `int`, `string`, `bool`).
- `match` on `bool` requires `_` like other literal matches.
- Error code choices: mixing `int`/`usize` or an `int` index → E0400; non-bool/non-number
  operands (`"a" - "b"`, `!1`, `1 && 2`) → E0410; unknown type name → E0300; unknown field in a
  record literal → E0411; unknown field in `p.z` → E0405; duplicate variant names across unions
  in one module → E0304; `const r = Ok(1);` → E0407; reserved words used as names → E0200;
  literal pattern of the wrong type → E0400.
- `writeFile` to a missing directory returns `Err(message)`.
