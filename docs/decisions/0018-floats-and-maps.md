# ADR-0018: Floating-point numbers (`float`, `f32`) and the built-in `Map<K, V>`

Status: accepted (2026-10-13). Scope: the self-hosted compiler (`compiler/`), the C runtime, the
std prelude. Stage 0 is frozen and rejects all of this; the compiler's own source stays Orin-B
(no floats, no maps; see ADR-0014). Spec: 02 (types), 08 (std:map, std:math), 19 (R1: prefer Orin).

## Floats

**Types and literals.** `float` is IEEE-754 binary64, `f32` binary32 (spec 02). Literals are
`1.5`, `1e9`, `2.5e-3`, `1.5E+10`: digits, then a fraction and/or an exponent. `.5` and `1.` are lexical
errors (E0100; the canonical spelling is `0.5`, and `1.toString()` keeps meaning "member of an int").
A literal has the expected float type (`float` or `f32`), else `float`. There is **no** implicit
int <-> float conversion and no literal coercion: `let x: float = 1;` and `1.5 + 2` are E0400.
The compiler never evaluates a float (Orin-B has none): `EFloat`/`XFloat` carry the literal's
canonical decimal text (a `.0` is inserted before an exponent without fraction) and the backends emit
it: C parses it as a `double`; LLVM IR accepts decimal `double` constants and rounds correctly. An
`f32` literal is therefore rounded twice (decimal -> double -> float) in *both* backends.

**Operations.** `+ - * /` (IEEE, never trap; `1.0 / 0.0` is `Infinity`, `0.0 / 0.0` is `NaN`),
unary `-`, comparisons and `==`/`!=` with IEEE semantics (`NaN != NaN`, `0.0 == -0.0`). `%` is not
provided (E0410). `f32` operations are performed in binary64 and rounded to binary32 after every operation
(exact for `+ - * / sqrt` since 53 >= 2*24+2). Floats cannot be matched on (E0402), are not `Map` keys
(E0400) and have no `indexOf`/`includes`.
Methods: `toString()`, `toInt()`, `round()`, `floor()`, `ceil()`, `sqrt()`, `abs()`, `pow(y)`,
`isNaN()`, `isFinite()`, `toF32()` (float), `toFloat()` (f32); `int`/`usize`: `toFloat()`, `toF32()`.
`f.toInt()` truncates toward zero and **traps** ("float to int out of range") on NaN, +-Infinity and values
outside `int`. `round` is half away from zero (C `round`). `parseFloat(s): Option<float>` takes
`-? digits (. digits)? ([eE] [+-]? digits)?`, `Infinity`, `-Infinity` and `NaN` (nothing else: no sign `+`,
spaces, hex, `.5`, `5.`); overflow gives +-Infinity.
`std:math` (`array/math.or`, Orin): `sqrt abs min max pow floor ceil round` on `float`, `PI`, `E`.
`min`/`max` return NaN if either argument is NaN.

**`toString` algorithm.** Find the smallest precision p in 1..17 such that `strtod(sprintf("%.{p-1}e", x)) == x`
(for `f32`: `strtof` of the same text, p in 1..9): those are the shortest round-tripping decimal digits. They
are laid out like JavaScript: positional notation when the decimal exponent k satisfies -7 < k < 21
(`0.000001`, `123456.0`; an integral value always gets `.0`), else `d.ddde+XX` / `d.ddde-XX` (`1e+21`,
`1.5e-7`, no padding of the exponent). `NaN`, `Infinity`, `-Infinity`, `-0.0`. The result round-trips through
`parseFloat`.

**Representation.** MIR gets the scalar type `MFloat` (an `f32` is an `MFloat` holding a value exactly
representable in binary32; `IBuiltin(BF32Round)` after each `f32` operation). Operand `OFloat(text)`.
`IBinary`/`IUnary` work on `MFloat` operands with the IEEE operators. Slots (arrays, struct fields,
closures environments, `Option<float>`) store the 64-bit pattern; an `float[]` is a non-reference array
like `int[]`. The verifier treats `MFloat` as a scalar class of its own (docs/mir.md v1.4). C: `double`
locals, `orin_f2s`/`orin_s2f` for slots, generated C sets `#pragma STDC FP_CONTRACT OFF`; LLVM: `double`
(`fadd`, `fcmp oeq/une/olt/..`, `llvm.sqrt/floor/ceil/round/fabs/pow`). Programs that use `pow` need `-lm`
(all repository tools pass it). The legacy HIR -> C backend rejects floats (like closures).

## Map<K, V>

**Surface.** `Map<K, V>` is a built-in generic *value* type (copy-on-write like arrays and records;
`const b = a; a.set(k, v);` leaves `b` unchanged). Keys: any `Hash` type (*amended 2026-10-18*, ADR-0034: the integer types, `bool`, `string`, records, unions, `Option`, `Result`, arrays and
classes with `hash`; the original rule was `int`, `usize`, `bool`, `string` only); a key that can never be hashed (`float`, a function) is
E0400, a composite containing one is E0475. Canonical constructor: **`new Map<K, V>()`** (JS-familiar; the type arguments may be omitted when the
expected type is a `Map`, else E0407); `Map<K,V>.empty()` is not provided. API: `get(k): Option<V>`,
`has(k): bool`, `set(k, v)` and `delete(k): bool` (mutating: the receiver must be a `let` place, like
`push`), `size: usize` (a read-only field), `keys(): K[]`, `values(): V[]`, `entries(): MapEntry<K, V>[]` with
`MapEntry<K, V> = { key: K; value: V; }`. Iteration order is insertion order; overwriting a key keeps its
position, deleting and re-inserting moves it to the end. Maps are not comparable (`==` is E0410), `for..of`
iterates `keys()`/`entries()` arrays, generic code over a *type parameter* key is accepted when the parameter is `K extends Hash` (ADR-0034; it was E0400 when this ADR
was written), otherwise it is rejected; `V` may be anything.

**Implementation: Orin prelude code, not a C object kind** (spec 19 R1/R3: keep the TCB small; the table is
verifiable Orin over arrays and uses no new runtime object kind, no new RC/COW code and no new MIR). The
prelude file `array/map.or` (unit `$array/map`, always loaded like the array API) declares the generic records
`Map<K, V> = { size, _keys, _vals, _live, _tab }` (insertion-ordered entry arrays plus an open-addressing index
table of entry numbers with linear probing; deleted entries are tombstones that are compacted when they
outnumber live ones; the table doubles at load 1/2) and the generic functions `mapGet/mapHas/mapSet/mapDelete/...`.
Hashing and equality of the key class cannot be written in a generic body (`==` on `K` is rejected), so the
checker redirects the two stubs `keyHash<K>` / `keyEq<K>` to the non-generic functions `hashInt/hashUsize/hashBool/
hashStr` / `eqInt/..` when it instantiates them (`check/types.or`, `instFunc`). Strings hash with a polynomial
hash over `charCodeAt` modulo a prime (no overflow traps); `int` keys are scrambled by a multiplicative hash.
The checker maps the names `Map` / `MapEntry` to those prelude types (a user type of that name wins), validates
the key class, and rewrites `m.get(k)` etc. to calls of the prelude functions. Mutating calls use the class
mechanism of ADR-0009 (`m = mapSet(m, k, v)` as a hoisted statement), so with the owned-parameter optimisation
(ADR-0010) a unique map is updated in place: 100 000 inserts do zero COW copies. Costs: `get/has/set/delete` O(1) expected;
`keys/values/entries` O(n); copying a shared map on first write O(n).

## Alternatives rejected

* Map as a runtime object kind in C (fastest, but new RC/COW/destroy code in the TCB, a new MIR/verifier
  surface and slower bootstrap of the formal story).
* Float literal values in the AST (the compiler is Orin-B and has no floats; text is exact and backend-neutral).
* A separate `f32` MIR type (doubles verifier/emitter work for no semantic gain).
* Shortest-digits via Ryu/Grisu in the runtime: more code than the `%.{p}e` search for the same output.

## Consequences / limitations

`std:math` functions are float-only (no int `abs`/`min`/`max` yet); `f32` literal and `int -> f32` conversions
may double-round; no `%` on floats; no float patterns. *Amended 2026-10-18:* `Map` keys are no longer limited to four classes; any `Hash` key is accepted (ADR-0034: the
integer types, `bool`, `string`, records, unions, `Option`, `Result`, arrays and classes with `hash`; `float`/functions are E0400 where
the type is written, a composite containing one is E0475), and `Map<K, V>` helpers with `K extends Hash` work in generic code. MIR v1.4 adds `MFloat`/`OFloat`.
