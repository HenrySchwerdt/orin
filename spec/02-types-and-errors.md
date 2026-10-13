# 02 — Types, Numerics, and Errors

## Core types

- `int` is always signed `i64`, not pointer width.
- `float` is always `f64` (even though `f32` would be attractive for GPU workloads). `f32` is explicitly available.
- Fixed signed types: `i8`, `i16`, `i32`, `i64`, `i128`.
- Fixed unsigned types: `u8`, `u16`, `u32`, `u64`, `u128`.
- Machine-size types: `isize`, `usize`, whose width follows the target pointer width. `usize` is NOT the largest possible supported integer.
- Other primitives: `bool`, `string`, `void`; `bytes` is a standard-library abstraction backed by `u8` storage.
- Compound types: records, classes with value semantics, arrays `T[]`, tagged enums, finite unions, `Option<T>`, `Result<T,E>`, function types, and interfaces.

## Numerics

Integer literals adopt an expected integer type if representable; otherwise default to `int`. Floating literals adopt a compatible expected float type if representable under the accepted literal rules; otherwise default to `float`. Float literals are `1.5`, `1e9`, `2.5e-3` (no `.5`/`1.`); a literal is rounded to nearest (an `f32` literal via binary64, i.e. twice). There is no int/float literal coercion. Implemented in the self-hosted compiler: ADR-0015.

No implicit casts between already-typed numeric values. Ordinary integer arithmetic is checked; overflow/zero-divide causes a *defined trap* rather than UB. Use `checkedAdd` (returns `Option<T>`), `wrappingAdd`, etc. where defined. The compiler can remove checks only when it proves them redundant. No silent truncation.

`float` follows defined IEEE-754 behavior, including NaN/infinities (no traps; `NaN != NaN`; no `%`); `f.toInt()` truncates and traps on NaN/out-of-range; `toString` prints the shortest round-tripping digits (ADR-0015). Monetary APIs SHOULD use integer minor units or a separately designed decimal abstraction, not floating-point approximations.

## Type system

Types MUST be statically resolved, with local inference and predictable compile times. Permit simple parametric generics (e.g. `function first<T>(xs: T[]): Option<T>`), closed tagged unions, nominal named record/class types, and explicit interfaces. No `any`, unchecked casts, null, undefined, JS prototype chain, class inheritance, TS conditional/mapped/template literal types, or arbitrary compile-time type recursion.

Generic specialization/monomorphization is an implementation choice, bounded to avoid pathological code-size growth. Runtime interface dispatch, if introduced, MUST be explicit and ABI-defined. Method overloads are disallowed in the core.

## Absence and failure

```typescript
type Option<T> = Some(T) | None;
type Result<T, E> = Ok(T) | Err(E);

function load(path: string): Result<Config, ConfigError> {
  const text = fs.readFile(path)?;
  return json.parse<Config>(text);
}
```

All standard fallible APIs MUST return `Result<T,E>`. Missing-but-not-erroneous data uses `Option<T>`; the caller MUST explicitly handle absence. Postfix `?` only applies to `Result<T,E>`, extracting `Ok(value)` or returning an `Err` compatible with the enclosing function's declared error type. Error unions MUST use a predictable, unambiguous conversion rule; no implicit arbitrary coercion. `Result` is not a promise of exception-free native FFI or OOM; those belong to documented boundary rules.

No general `throws`/`catch` mechanism. A defined trap is distinct from a recoverable `Result` error; traps must preserve memory safety. Explicit panic/abort API, if any, remains OPEN.

## Array access

`array.get(index): Option<T>` is checked and recoverable. `array[index]` is bounds-checked and triggers a defined trap if invalid; it MUST never access arbitrary memory. `array.length` returns `usize`; literals such as `0` adopt the expected index type.
