# Orin Bootstrap Subset (Orin-B) — frozen contract v1

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
- Entry point: the entry file must contain `function main(): void`.
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
- `==`/`!=` only on `int`, `usize`, `bool`, `string` (both sides same type).
  `< <= > >=` only on `int`, `usize`. `&& || !` only on `bool`. `+` also concatenates two strings.
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

`import { readFile, writeFile, exists } from "std:fs";`
- `readFile(path: string): Result<string, string>`
- `writeFile(path: string, data: string): Result<void, string>`
- `exists(path: string): bool`

`import { args, exit } from "std:process";`
- `args(): string[]` (excludes the program name); `exit(code: int): void`.

`Result<void, E>` success value is written `Ok()`.

Beyond Orin-B (self-hosted compiler only; Stage 0 rejects the import with E0301): standard module
`std:io`, `import { readBytes, readLine, writeStdout, shell } from "std:io";`
- `readBytes(n: usize): Option<string>`: exactly `n` bytes from stdin, `None` if end of input is
  reached first (the bytes read so far are discarded); `readBytes(0)` is `Some("")`.
- `readLine(): Option<string>`: the next line without its `\n` (or `\r\n`), `None` at end of input.
  A final line without a newline is returned; an empty stream yields `None`.
- `writeStdout(s: string): void`: writes `s` to stdout without a newline and flushes. It shares
  the stdio buffer with `console.log`, so output order is preserved.
- `shell(cmd: string): int`: runs `cmd` with `/bin/sh -c`, returns the exit status (-1 if it could not
  run or was killed by a signal). Used by `orin mcp` (`test`/`build`, only with `--allow-exec`).
Strings are byte strings. Used by `orin lsp` (`compiler/lsp/stdio.or`); runtime in
`runtime/orin_runtime_io.h` (header-only, included by generated C of both backends).

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
| E0500 | `orin.toml` syntax error (beyond Orin-B; self-hosted compiler only, spec 04) |
| E0501 | import violates a module's `allowed_dependencies` rule in `orin.toml` (beyond Orin-B) |
| E0502 | `orin.toml` names a module that does not exist (no `module.or`) (beyond Orin-B) |
| E0503 | invalid `orin.toml` (unknown key/table, wrong value type, missing `[package] name`, an `[architecture]` flag set to `false`) (beyond Orin-B) |

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
