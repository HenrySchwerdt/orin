# Candidate "did you mean" diagnostics for TypeScript habits

_Collected 2026-10-13 while writing [ts-developers.md](ts-developers.md). Each line: what a TS
developer writes, the current message, the hint we want. Not implemented yet (roadmap step 3a)._

| TS habit | Current message | Wanted hint |
|---|---|---|
| `null` / `undefined` | E0200 expected expression, found `null` | use `Option<T>` / `None` |
| `throw new Error(..)` | E0200 expected `;`, found `new` | return `Err(..)` from a `Result` function |
| `try { } catch (e) { }` | E0200 expected `:`, found `.` (misleading) | no exceptions: `Result` + `?`, `match` |
| `a === b` | E0200 expected expression, found `=` | `==` (value equality on scalars/strings) |
| `i++` | E0200 expected expression, found `+` | `i += 1` |
| `a & b`, `a << n` | E0200 expected `;`, found `&` | bit operators are reserved for post-1.0 (ADR-0016) |
| `switch (x) {` | E0200 expected `;`, found `{` | `match (x) { ... }` |
| `typeof x`, `x instanceof C` | E0200 expected `,` or `)` | static types; `match` on tagged unions |
| `a ?? b` | E0200 expected `:`, found `;` | `a.unwrapOr(b)` |
| `async function` | E0200 expected declaration, found `async` | no async yet (ADR-0017 tasks) |
| `for (let i = ..; ..; ..)` | E0200 expected `const`, found `let` | `for (const x of xs)` / `while` |
| `x?: T`, `readonly x`, default params | E0200 (various) | `Option<T>` fields; values are immutable unless `let` |
| destructuring, spread, tuples, `10n`, getters | E0200 / E0100 | explicit fields, `concat`, records, `i64`/`u64` |
| `any`, `number`, `Array<T>`, `Promise`, `object` | E0300 unknown type `number` | `int` / `float`, `T[]`, `Option`, records |
| `a?.b` on an `Option` | E0406 `?` requires a `Result` | `?` propagates `Err`; use `match`/`map` for `Option` |
| `p == q` on a record, array, `Option` or union that contains a `float` or a function; on a class without `equals` | E0410 operator is not defined for type `P` (with the reason) | records, unions, `Option`, `Result` and arrays compare structurally (ADR-0034); give the class `equals` or `implements Eq`; compare floats by field |
| `console.log(1)` | E0400 expected `string`, found `int` | `` console.log(`${x}`) `` |
| `a[i]` with `int` index | E0400 expected `usize`, found `int` | `a[i.toUsize()]` |
| `import .. from "lodash"` | E0301 lists tried paths | npm packages are not supported |
| `enum E { A, B }` | E0200 expected declaration, found `enum` | `type E = A \| B` |

## Real issues found on the way (not just messages)
- `type Id = int | string;` is **accepted silently** and only fails at a use site; it is not a union of
  `int` and `string` (tagged unions only, ADR-0004). Should be an error at the declaration.
- Spec 01 still lists `enum` in the grammar, spec 02 lists "finite unions", and spec 01's "Not decided"
  still has string interpolation and generic methods (decided: ADR-0022 and ADR-0040; generic methods exist, E0460 only rejects them in interfaces). The `==` rules (E0410 where a type has no
  `Eq`) are in ADR-0018/0019/0034, spec 03 and the compiler; they belong in spec 02.
