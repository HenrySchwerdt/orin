# Beta diagnostics audit: first-day TypeScript mistakes (2026-10-17)

Scope: what a TypeScript developer sees in the first hour of 0.1.0-beta.1. About 75 small broken programs were run
through `orin check` (compiler of main, `--diagnostic-style=rich`) and the `orin` launcher (`dist/orin-cli.sh`) was driven
against a scratch package. Probe sources are not committed (`build/diag-probe/`). Related, older list:
[ts-diagnostics.md](../ts-diagnostics.md) (candidate hints, not implemented). Known wording issue: docs/reference/README.md
discrepancy 7.

Method: **good** = states the problem, points at the right token, the fix follows from the text. **confusing** = correct
but a newcomer cannot tell what to write. **misleading** = names the wrong thing or an internal concept.

`Diagnostic` already has `notes: string[]` and the rich renderer prints them as `note:` lines (compiler/diag/diag.or:17,
compiler/diag/terminal.or:254), so every hint below is a `notes.push(..)` with no format change. No check/ or loader/
file was edited; all proposals are for their owners. Parser (`compiler/syntax/`) items are marked P.

## 1. Verdicts per probe

| # | Program (TS habit) | Message (code, span) | Verdict |
|---|---|---|---|
| 1 | call `readFile` without import | E0300 unresolved name `readFile` (the name) | confusing: no hint that `std:fs` exists |
| 2 | `const x = 5; x = 6;` | E0401 cannot assign to `x`: it is not declared with `let` (the `x`) | good |
| 3 | `const x: int = "hello"` | E0400 expected `int`, found `string` (the literal) | good |
| 4 | call undefined `foo(3)` | E0300 unresolved name `foo` | good |
| 5 | `for (let i = 0; i < 3; i++)` | E0200 expected `const`, found `let` at `let`; then E0200 expected expression, found `+` | confusing: first message is accurate but says nothing about C-style loops; the second is noise |
| 6 | `Ok(())` | E0200 expected expression, found `)` | confusing: should say `Ok()` |
| 7 | top-level `let count = 0;` | E0200 expected declaration, found `let` | confusing |
| 8 | `"ab".repeat(3)` | E0405 no method `repeat` on type `string` | confusing: no list of what exists |
| 9 | missing return on one path | E0403 function `f` does not return a value on every path (function name) | good |
| 10 | `x: number` | E0300 unknown type `number` (twice, once per use) | confusing: no suggestion |
| 11 | `x: any` | E0300 unknown type `any` | confusing |
| 12 | `undefined` / `null` | E0200 expected expression, found `undefined` | confusing |
| 13 | `a === 1` | E0200 expected expression, found `=` (second `=`) | confusing, wrong token |
| 14 | `a?.length` on Option | E0406 `?` requires a `Result`, found `Option<string>` | confusing: reads as a type problem, not as "no optional chaining" |
| 15 | `async function` | E0200 expected declaration, found `async` | confusing |
| 16 | class field without type `x;` | E0200 expected `(` or `:` in class member, found `;` | good enough |
| 17 | `console.log(5)` | E0400 expected `string`, found `int` | confusing: no template-literal hint |
| 18 | `"n=" + 5` | E0410 operands have different types `string` and `int` | good, hint would help |
| 19 | `number[]` | E0300 unknown type `number` | same as 10 |
| 20 | `console.log("hi")` without `;` | E0200 expected `;`, found `}` (at the next token) | good (span after the statement is a known compromise) |
| 21 | `try { } catch (e) { }` | E0200 expected `:`, found `.` | misleading (known, ts-diagnostics.md) |
| 22 | `(x) => x + 1` | E0407 cannot infer the type of parameter `x`; add a type annotation | good |
| 23 | `var x` | E0201 `var` is not allowed; use `const` or `let` | good |
| 24 | `xs.length()` | E0405 no method `length` on type `int[]` | confusing: `length` is a property |
| 25 | `export default` | E0200 expected declaration, found `default` | confusing |
| 26 | `{ x: 1, y: 2 }` | E0200 expected expression, found `{` | confusing |
| 27 | `while (n)` with int | E0400 expected `bool`, found `int` | good |
| 28 | `m["a"] = 1` on Map | E0400 cannot index into type `Map<string, int>` | confusing: no hint `get`/`set` |
| 29 | `add(1)` for 2 params | E0404 function `add` expects 2 argument(s), found 1 | good |
| 30 | no `main` | E0412 entry file must define `function main(): void` | good |
| 31 | `s[0]` on string | E0400 cannot index into type `string` | confusing |
| 32 | `import {x} from "./nonexistent"` | E0301 cannot find module (tried `nonexistent.or` and `nonexistent/module.or`) | good |
| 33 | `switch (x) {` | E0200 expected `;`, found `{` | misleading |
| 34 | `enum Color {..}` | E0200 expected declaration, found `enum` | confusing |
| 35 | `type P = { x: int, y: int }` | E0200 expected `;`, found `,` | confusing: record fields end with `;` |
| 36 | `private x: int` in a class | accepted | fine |
| 37 | `const xs: int[] = []; xs.push(1)` | E0401 cannot call `push` on `xs`: it is not declared with `let` | good |
| 38 | `[...a, 2]`, `const [a, b] = ..`, `const {x} = ..` | E0200 expected expression, found `...` / expected identifier, found `[` | confusing |
| 39 | `fetch(..)` | E0300 unresolved name `fetch` | acceptable |
| 40 | `s.padStart(5)`, `s.toLowerCase()`, `s.replace(..)`, `s.slice(1)` | E0405 no method .. on type `string` | confusing (see 8) |
| 41 | `xs.slice(1)` | E0404 method `slice` expects 2 argument(s), found 1 | good |
| 42 | `function main(args: string[])` | E0412 `main` must be declared as `function main(): void` or `function main(host: Host): void` | good |
| 43 | `function f(x: int) { return x; }` | E0400 cannot return a value from a function returning `void` (at the expression) | confusing: the fix is on the signature |
| 44 | `x?: int`, `y: int = 3` | E0200 expected `:`, found `?` / expected `,` or `)`, found `=` | confusing |
| 45 | `x: int \| string` parameter | E0200 expected `,` or `)`, found `\|` | confusing |
| 46 | `const c = C(1)` for a class | E0300 unresolved name `C` | confusing: needs `new` |
| 47 | `n += 1` for a field inside a method | E0300 unresolved name `n` | confusing: needs `this.` |
| 48 | `a == null`, `typeof a == ".."`, `i++` | E0200 expected expression, found `null` / expected `)`, found `a` / found `+` | confusing |
| 49 | `import fs from "fs"` | E0200 expected `{`, found `fs` | confusing |
| 50 | `new Array(3)` | E0300 unknown class `Array` | confusing |
| 51 | `const o: Option<int>; o.value` | E0405 no field `value` on type `Option<int>` | confusing: no pointer to `match` / `unwrap` |
| 52 | `const f = function (x: int) {}` | E0200 expected expression, found `function` | confusing |
| 53 | `for (const k of 0..3)` | E0100 unexpected `..`; did you mean `...`? | misleading: `...` is the spread, not a range |
| 54 | `Result` value assigned to `int` | E0400 expected `int`, found `Result<int, string>` | good |
| 55 | `nested pattern Some(Circle(r))` | E0402 sub-patterns must be a binding name or `_` in Orin-B | misleading (internal name) |
| 56 | `class B extends A`, generic interface | E0408 ... not supported in Orin 1.0 (ADR-0019/0026) | good, but "(ADR-0019)" means nothing to a newcomer |
| 57 | `console.log("a", "b")` | E0404 `console.log` expects 1 argument(s), found 2 | good |
| 58 | `readFile("a")` with `import { readFile } from "std:fs"` | E0470 function `readFile` needs a `FsGrant` as its first argument: ... (ADR-0027) ... | confusing for a beginner: long, mentions ADR |
| 59 | `enum`-like generic method, `class A { id<T>() }` | E0460 (covered by tests/next/errors/ts_dev_e0460_generic_method.or) | good |

Launcher (`dist/orin-cli.sh`):

| Invocation | Before | Verdict |
|---|---|---|
| `orin`, `orin help`, `orin --help` | help text, exit 0 | good |
| `orin foo` | `Unknown command 'foo'. Run 'orin --help'` exit 2 | good, now with hints for `new`, `install`, `start`, `watch`, `format`, `lint`, `tsc`, `*.or` |
| `orin help foo` | `Usage: orin foo -- see the compiler command reference in docs/`, exit 0 | misleading: accepted any word. Now the same unknown-command error |
| `orin run missing.or` | `Building missing`, then E0301 `cannot read 'missing.or': cannot read 'missing.or': ...` with an empty source frame | confusing: now `error: File not found: missing.or` before anything is built |
| `orin build` / `test` / `check` / `run` outside a project | `No Orin project found. Run orin init to create one, or pass a .or file.` | good |
| `orin test nothing.or` | `cannot read <cwd>/orin.toml` | misleading: now `File not found: nothing.or` |
| `orin explain E0401` | `No extended explanation is available for this code yet.` | confusing: the diagnostic table has about 60 codes, only 4 were explained. Now 14 (the ones in the table above) |
| `orin explain E0999` | same | now names the code |
| `orin -V` | unknown command | now prints the version (`--version` and `version` as before) |
| `orin build a.or b.or` | `Expected one source path.` | good |
| missing C compiler (`CC=nonexistentcc`) | `C compiler 'nonexistentcc' was not found. Run 'orin doctor' for installation help.` | good |

## 2. Proposals for compiler/check, compiler/loader and the parser

Format: file:line (at the commit of this audit), current text, proposed text (`msg`) and optional hint (`note:`).

### Top 6 (highest value for the cheapest change)

1. **compiler/check/pattern.or:150, E0402** (known, README discrepancy 7).
   Current: `sub-patterns must be a binding name or `_` in Orin-B`.
   Proposed msg: `nested patterns are not supported; a variant pattern takes only names or `_` (for example `Some(x)`)`.
   Note: `match on the inner value in a second match`.
2. **compiler/check/expr.or:3386, 3467, 3481, 4217, 4311, 4507, E0405 "no method .. on type `string`" (and array).**
   Current: `no method `repeat` on type `string``. Add a note listing what exists. For `string`: `string has: length,
   charAt, charCodeAt, substring, indexOf, includes, startsWith, endsWith, split, trim, toString; build text with
   template literals`. For arrays: the list from compiler/check/builtins.or. For `length` called as a method
   (`xs.length()`, `s.length()`): msg `` `length` is a property, write `xs.length` ``. Single change point: a helper
   `methodHint(ty, name)` called from the diag sites. ("toUpperCase", "padStart", "repeat", "replace", "slice" and
   "toLowerCase" all hit this on day one.)
3. **compiler/check/expr.or:2470 (and 3510, ops.or:653), E0300 unresolved name.** Current: `unresolved name `x``.
   Add notes by case: the name is a field of the enclosing class and we are in a method: `did you mean `this.n`?`;
   the name is a class and the use is a call: `use `new C(..)``; the name is exported by a std module (`readFile`, `join`, ...): `add `import { readFile } from "std:fs";``; the name is a known JS global (`fetch`, `require`,
   `setTimeout`, `Math`, `JSON`, `Promise`): `Orin has no JavaScript globals; see docs/ts-developers.md`.
   A did-you-mean by edit distance 1-2 against the names in scope is the generic fallback.
4. **compiler/check/expr.or:1987 and compiler/check/types.or (unknown type), E0300.** Current: `unknown type `number``.
   Notes: `number` -> `use `int` (64-bit integer) or `float``; `any`/`unknown`/`object` -> `use a concrete type, or a
   generic `T``; `Promise`/`Array<T>` -> `async is not available; arrays are written `T[]``; `string[]`, `boolean`
   -> `bool`; `undefined`/`void` as a value type -> `Option<T>`. Also report it once per annotation, not once per use
   (probe 10 prints it twice).
5. **compiler/check/stmt.or:394, E0400 "cannot return a value from a function returning `void`".** The function has
   no result type, which is almost always the real mistake. Proposed msg: `cannot return a value from `f`: it has no
   result type (it returns `void`)`; note: `declare the result type, for example `function f(x: int): int``.
   (The span should be the function's missing return position or add a secondary note at `f`.)
6. **compiler/check/expr.or:1812, E0406 "`?` requires a `Result`, found `Option<..>`".** When the operator is written
   `?.` (the next token is `.`), add the note: `Orin has no optional chaining; use `match (a) { Some(v) => .., None => .. }`
   or `a.unwrapOr(default)``. The parser knows the `.` follows; if easier, do it in the parser as a distinct E0200.

### Other check/loader proposals

7. **compiler/check/expr.or:1766 and 3590, E0400 "cannot index into type `Map<..>`"**. Note for `Map`: `use `m.get(k)`
   (returns an Option) and `m.set(k, v)``; for `string`: `use `s.charAt(i)` or `s.substring(a, b)``; for a record
   or class: `use `.field``.
8. **compiler/check/expr.or (E0400 expected `string`, found `int`)** when the expected type is the argument of
   `console.log`: note `use a template literal: console.log(`${n}`)`. Same for E0410 at compiler/check/ops.or:515 when
   one side is `string` and the other is `int`/`float`/`bool`: note `build strings with a template literal: `n=${n}``.
9. **compiler/check/expr.or:3641, E0300 "unknown class `Array`"**: note `arrays are literals: `[]`, `[1, 2]`, type
   `int[]`; push with `xs.push(v)` on a `let``.
10. **compiler/check/expr.or (E0405 "no field `value` on type `Option<int>`")**: note `inspect an Option with `match`,
    or use `unwrap()` (traps on None) / `unwrapOr(d)``. Same for `Result`.
11. **compiler/check/call.or:147 and 157, E0470/E0471 (needs a `FsGrant`)**. Current message is one long sentence with
    "(ADR-0027)". Proposed msg: `function `readFile` needs a file-system grant as its first argument`; note: `declare
    `function main(host: Host): void` and pass `host.fs`; a program whose main has no `host` has no I/O authority`
    (verify the exact accessor with the std docs before using). ADR numbers belong in `orin explain`, not in the text.
12. **compiler/check/collect.or:365, 369, types.or:322, classes.or:276 (E0408 "... not supported in Orin 1.0 (ADR-00xx)")**:
    move the ADR number to a note; keep the main message free of it: `generic interfaces are not supported`, note
    `see ADR-0019`. Same for "`extends`" which already names the alternative (`use composition`).
13. **compiler/check/decls.or:338, E0412 "entry file must define `function main(): void`"**: add `in <file>`; a newcomer who
    runs `orin run helper.or` gets no hint that the file name matters.
14. **compiler/check/checker.or:98, E0403**: add a note at the end of the function span: `add a `return` or an `else`
    branch`, and put the span on the closing `}` of the body rather than the name (editor squiggles then show where the
    return is missing).
15. **compiler/loader (E0301 cannot find module)** is good. One extra hint for a bare name that looks like an npm
    package (`"lodash"`, `"react"`, `"fs"`, `"path"`): note `npm packages are not available; the standard library is
    imported as "std:fs", "std:path", ... (docs/std.md)`. The parser rejects `import fs from "fs"` before that
    (see P5), so both parts are needed.

### Parser (compiler/syntax/parser.or, lexer.or), all E0200 unless noted

P1. **`for (let i = 0; ...)`, parser.or:1921 `expectKw("const")`.** If the next keyword is `let`, or the token after `(`
    is `let`/`var`/`;`, report once and stop (no cascade, see probe 5): msg `Orin has no C-style `for` loop`; note
    `use `for (const x of xs)` over an array, or `let i = 0; while (i < n) { ..; i += 1; }``.
P2. **`===` / `!==`.** Where the parser reports `expected expression, found `=`` right after `==`: msg `` `===` does not
    exist; use `==` `` (it is value equality, ADR-0034). Same for `!==`.
P3. **`i++` / `i--`.** After an expression statement followed by `+ +`: msg `` `++` does not exist; write `i += 1` ``.
P4. **`null`, `undefined`.** Parser.or errAt site at `expected expression`: for the identifiers/keywords `null` and
    `undefined` say: `no `null` or `undefined`; use `Option<T>` with `None` and `Some(x)``. ts-diagnostics.md already
    lists this; covered by tests/next/errors/ts_dev_e0200_null.or (expected text must change with it).
P5. **Declaration-level words** (parser.or:1222 `errExpected("declaration")`): `async`, `enum`, `export default`,
    `let` at file level, `namespace`, `declare`, `abstract`: one table token -> message:
    `async` -> `async functions are not available; use `scope`/`spawn` tasks (ADR-0017)` ; `enum` -> `use a tagged
    union: `type Color = Red | Green;``; `let` -> `file-level declarations are `const`, functions, types and classes`;
    `default` -> `there are no default exports; write `export function name``.
    `import fs from "fs"` (expected `{`, found `fs`): msg `imports are named: `import { name } from "module"``.
P6. **`Ok(())`** (expression parser, `errExpected("expression")` at `)` after `(` ): note `for a Result<void, E>
    write `Ok()``.
P7. **Record type with commas**: `type P = { x: int, y: int }` gives `expected `;`, found `,``. Either accept `,` as a
    separator (the better fix; TypeScript allows both `;` and `,` in object types) or add the note `fields end with `;``.
    The tutorial writes `{ x: int; y: int; }`, so the last `;` is also required: `{ x: int; y: int }` fails with
    `expected `;`, found `}``. Accepting both would remove a whole class of day-one errors.
P8. **E0100 `unexpected `..`; did you mean `...`?` (lexer.or:1107)** suggests the spread operator for a range. Orin has
    no range expression; the hint should be `there is no range syntax; use a `while` loop`.
P9. **`switch`, `try`/`catch`, `typeof`, `instanceof`, `x?: T`, `y: T = v`, `A | B` in a parameter, `function (..) {}`,
    `{ x: 1 }` object literal, destructuring, spread, `export default`**: all report a generic "expected X, found Y".
    All have an entry in ts-diagnostics.md; a single keyword/token table in the parser (token -> note) would cover them.
    Notes: `switch` -> `use `match (x) { .. }``; `try` -> `no exceptions: return `Err(..)` and propagate with `?``;
    `typeof`/`instanceof` -> `types are static; match on a tagged union`; `{ x: 1 }` -> `declare a record type and write
    `P { x: 1 }``; destructuring -> `read fields with `p.x` / `xs[0]``; `function (..) {..}` expression -> `use an arrow
    function `(x: int): int => ..``.

## 3. Message wording that already reads well (keep)

E0401 (`not declared with `let``), E0404, E0407, E0201, E0301 (lists tried paths), E0403, E0412 for `main(args)`.

## 4. Implemented in this change

- `dist/orin-cli.sh`: unknown command hints, `orin help <unknown>` is an error, missing file/directory is reported by the
  launcher, `orin explain` covers 14 codes and names the code when none is available, `-V` prints the version;
  `tools/test_cli.py` (`test_help_and_usage`) covers them.
- `docs/ts-developers.md` section 2.1: 29-row table "what you wrote / what the compiler says / what to write".
