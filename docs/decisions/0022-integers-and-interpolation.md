# ADR-0022: Fixed-width integers and template-literal interpolation

Status: accepted (2026-10-13). Scope: the self-hosted compiler (`compiler/`), the C runtime, the VS Code grammar.
Stage 0 is frozen and rejects all of this (template literals and integer literals above 2^63-1 are lexical errors there);
the compiler's own source stays Orin-B (ADR-0014). Spec: 02 (types, numerics). Closes the two remaining expression-level
rows of ADR-0016 ("Integers", "String interpolation").

## Integers

**Types.** `i8 i16 i32 i64 u8 u16 u32 u64 isize usize`; `int` is an alias of `i64` (the checker resolves both names to the same
type, error messages say `int`). `usize` and `isize` are pointer-width types distinct from `u64` / `i64`: `u64 = usize` is
`E0400` like any other mix. The 64-bit target is the only one, so `isize` / `usize` are 64 bits wide. `usize` behaves exactly as before
(the only array index type, the type of `length` / `size`, literals adopt it); an `isize` is `i64` with another name for the
type checker. `i128` / `u128`: see "128-bit" below.

**Literals.** An integer literal has the expected integer type, else `int`. Expected types come from annotations, parameters,
fields, the other operand of a binary operator and so on (the existing literal-hint mechanism, now for every integer type). A
literal that does not fit is **`E0430`** at compile time (`const x: i8 = 128`, `f(65536)` for a `u16` parameter, a match pattern
`300` on a `u8`, a `const` initialiser); a negative literal for an unsigned type is `E0400` (as it already was for `usize`). The
literal range is `0 .. 2^63-1` for the lexer's plain integer (`KInt`); the lexer additionally accepts `2^63 .. 2^64-1`
(decimal or hex) as a `KBigInt` token whose value is the 64-bit pattern, parsed to the new AST node `EBigInt`; such a literal is
valid only where the expected type is `u64` or `usize` (else `E0430`), and `-9223372036854775808` is accepted for `int` / `isize` / `i64`.
Larger literals are `E0100`. Literal *patterns* above `2^63-1` are `E0200` (compare with `==` instead; patterns on `u64` accept the plain
range `0 .. 2^63-1`). Literals never convert between integer and float (ADR-0018 stays).

**No implicit conversions.** Mixing two integer types in an operator, passing one where another is declared, assigning,
returning, or putting into an array of another element type is `E0400` ("cannot mix `i32` and `int`; convert explicitly"); integer
to float likewise. Conversions are explicit methods on every integer type: `toI8 toI16 toI32 toI64 toIsize toU8 toU16 toU32 toU64
toUsize` and `toInt` (= `toI64`), plus `toFloat` / `toF32` (existing). A conversion that cannot fail (widening, same range,
`u64`<->`usize`, `i64`<->`isize`) costs nothing; one that can fail **traps** (exit 101, `trap: integer conversion out of range`) if the
value is outside the target range. The pre-existing `int.toUsize()` / `usize.toInt()` keep their messages (`negative int to
usize`, `usize too large for int`). Methods stay methods (no `as` casts, no generic `convert<T>`).

**Arithmetic.** `+ - * / %` and unary `-` on every integer type; overflow of the result type **traps** (`trap: integer overflow`;
`usize` / `u64` keep `usize overflow` / `usize underflow` from the 64-bit unsigned operations), as `int` always did. Division
or remainder by zero traps (`division by zero` / `modulo by zero`); `MIN / -1` traps (`integer overflow`) for every signed
width (for the narrow ones the 64-bit quotient 2^(n-1) is out of range). `MIN % -1` is `0` for the narrow types and traps for
`i64` (unchanged). Comparisons are the usual ones on the type's own order (unsigned for `u64` / `usize`). There are no bitwise
operators and no shifts in the language (the lexer has no `&`, `|` as binary operators), so none were added. Explicit
`wrappingAdd/Sub/Mul` (modular), `checkedAdd/Sub/Mul` (`Option<T>`, `None` on overflow) and `saturatingAdd/Sub/Mul` (clamp to the
type's range) exist on every integer type; the argument has the receiver's type. No `wrappingNeg`, `*Div`, `abs`, `min`, `max`, `pow`
yet (std:math is float-only, ADR-0018).

**Parsing and printing.** `toString()` prints decimal. `parseInt(s): Option<int>` is unchanged; the generalisation is one
free function per type, `parseI8 parseI16 parseI32 parseI64 parseIsize parseU8 parseU16 parseU32 parseU64 parseUsize`
(`(s: string): Option<T>`, the same grammar as `parseInt`: `-? digits`, `None` on anything else or when out of range; a `-` is
never accepted for unsigned types), matching the shape of `parseInt` / `parseFloat`. A generic `parse<T>` would need type-argument
dispatch on a built-in, which the checker has only for user generics.

**Representation.** Values are unboxed scalars like `float`. MIR stays at its scalar types (docs/mir.md v1.6 changes no type):
`i64`, `isize` and every type narrower than 64 bits are an `MInt` holding the sign- (or zero-) extended value; `u64` and `usize` are an
`MUsize`. After a `+ - * /` or `-` on a narrow type (`i8 i16 i32 u8 u16 u32`) the lowering emits `IBuiltin(BIntRange, [v, lo, hi])`: the 64-bit
checked operation cannot overflow on narrow operands (a `u32 * u32` that exceeds `i64` traps in the 64-bit multiply, which is
also correct: it is out of range for `u32`), and the range check traps if the result leaves the type's range. No new MIR
instruction, type or verifier rule: seven new `Builtin`s (`BIntRange BIntConv BUIntConv BIntId BIntOp BIntChk BParseIntK`) and
one relaxation, `OUsize(n)` holds a 64-bit *pattern* so a negative `n` is a `u64` literal above 2^63-1 (the wf rule `OUsize >= 0` is
dropped). The C backend calls `orin_range_i` / `orin_conv_i` / `orin_conv_u` (static inline in `orin_runtime.h`) and `orin_int_op` /
`orin_int_chk` / `orin_parse_int_k` (out of line, `orin_runtime.c`, `__int128` internally); the LLVM backend emits the range
checks as inline helpers and calls the runtime for the rest. Slots (array elements, record fields, closure environments,
`Option<T>` payloads, vtable arguments) store the 64-bit pattern, so an array of `u8` uses 8 bytes per element (a compact `bytes`
type is the library abstraction of spec 02, not this ADR). `ORIN_STATS` counters of integer programs are unchanged (no new
allocation, retain or release). Generics monomorphise over the new types like over `int`; the Map and `indexOf`/`includes`
prelude helpers that need `==` are shared by integer class (`Int` helpers for everything held in an `MInt`, `Usize` helpers for
`u64` / `usize`); `Map<K, V>` keys may be any integer type. The legacy HIR -> C backend rejects programs that use the new types
(like closures and floats).

**Contracts.** Runtime contract checks (`--check-contracts`) work on every width (they are ordinary checked expressions).
`orin verify --contracts` models only `int` / `i64` and `bool` (unbounded integers plus an i64 range assumption, ADR-0020 D1); a
function whose parameters, result or locals use another integer width gets `UNKNOWN` with the reason ("only int/i64 and bool
... other integer widths are not modelled yet"). Modelling `i32` etc. needs per-width range obligations (a later step of ADR-0020).

**Interfaces, closures, classes.** Nothing special: the values are scalars of the MIR classes above; closure and vtable calls
pass them as `int64_t` / `uint64_t` exactly as `int` / `usize`.

### 128-bit: not in 1.0 (error E0431)

`i128` / `u128` are accepted by the lexer as identifiers but rejected with **`E0431`** ("the 128-bit integer type is not
supported yet") wherever a type is resolved, and `toI128` / `toU128` / `parseI128` / `parseU128` give the same error. Reason: the C
backend could use `__int128` and LLVM `i128`, but the 128-bit value has no home in the existing design: every storage
location of the runtime is a 64-bit slot (arrays, struct fields, closure environments, `Option` payloads, the `refmask`
protocol), MIR scalars and operands (`OInt`) are 64 bits and the verifier's operand classes are 64-bit classes, the LLVM
`smul.with.overflow.i128` lowers to `__muloti4`, which libgcc does not provide, and the float / Map / contracts machinery would each need a second
"wide scalar" path. Doing it properly means two-slot or boxed scalars across lowering, verifier, both emitters and the
runtime, which is out of proportion for a type with no use in the language's own libraries; the error keeps the names reserved
and the migration path open (a `MWide` scalar class and two-slot storage). Programs needing more than 64 bits use `u64` pairs or a library
big-integer type until then.

## Template literals

**Syntax** (TypeScript lexing rules). `` `text ${expression} text` ``: delimited by backticks; escapes are those of string literals
(`\n \t \r \0 \\ \" \' \xHH`) plus `` \` `` and `\$`; a `$` not followed by `{` is literal; a raw newline is part of the text (CRLF is
read as LF); `${` opens an interpolation holding any expression, closed by the matching `}` (braces of record literals, blocks
of arrow functions, strings containing `}` and **nested template literals** inside the expression are handled; comments are
allowed inside). `\uXXXX` escapes and tagged templates do not exist. Errors: unterminated literal / interpolation and bad
escapes are `E0100`; an empty or malformed interpolation is `E0200`; a template literal is not a pattern (`E0200`).

**Lexer/parser.** The lexer emits `KTplFull` (no interpolation) or `KTplHead`, the interpolation's own tokens, `KTplMid`..., `KTplTail`;
a stack of brace depths decides which `}` closes an interpolation. The parser builds `ETemplate(parts, exprs)` (`n+1` cooked text
parts around `n` expressions) whose expressions carry exact source positions, so the semantic index (hover, go to definition,
references, rename, completion scope) sees identifiers inside `${}` like anywhere else. `scanComments` (formatter) skips
comments inside templates.

**Types.** Each interpolated expression must have type `string`, any integer type, `float`, `f32` or `bool`; those convert
implicitly with their `toString` (integers: decimal; floats: the ADR-0018 algorithm; bool: `true` / `false`). Any other type is
**`E0432`** at the expression: "cannot interpolate a value of type `T` ... convert it explicitly (call `.toString()`)". `+`
concatenation stays valid and unchanged; `` `${a}${b}` `` is not special-cased beyond its lowering.

**Lowering.** The checker turns a template into a left-nested chain of string `+` (`"" + ..` parts are dropped, a single
`${s}` is `s`, an empty template is `""`), converting each interpolated value with the matching to-string built-in. The MIR
lowering of `a + b` already appends onto an owned left operand in place (`IStrAppend`), so a template with any number of parts
allocates one buffer (amortised growth) and does one append per part: linear, no repeated copying, no new built-in. Evaluation
order is left to right. Contract expressions (`@Requires` ...) may contain templates (erasure and runtime checks rewrite them).

**Formatter.** One canonical form: a template literal is printed exactly as written, including the expressions inside `${}`
(no reflow, no conversion to `+`); the code around it is formatted as usual. Idempotent by construction.

**VS Code.** The TextMate grammar (`editors/vscode/syntaxes/orin.tmLanguage.json`) scopes template literals as
`string.template.orin` with embedded expressions (`meta.template.expression.orin`, nested templates and braces supported,
escapes), plus the new type names and float literals; `editors/vscode/test/grammar.test.js` has tests.

## Alternatives rejected

* Implicit integer widening (`u8 -> i32` etc.): the spec forbids implicit casts, and mixed-width arithmetic is the classic source of
  silent bugs; explicit `toX` methods are cheap to write and trap-checked.
* A type per width in MIR (`MI8` ... `MU32`) with per-width C and LLVM operations: ten times the emitter and verifier surface
  for no semantic gain over "64-bit operation + range check".
* `as` casts or a generic `convert<T>(x)`: a new syntax / checker feature; methods follow `toFloat` / `toUsize` and are discoverable by
  hover and completion.
* Wrapping as the default for narrow types (C style): contradicts spec 02 ("ordinary integer arithmetic is checked").
* Template literals lowered to a new `concat` built-in or a rope: the append chain is already linear; a built-in would add TCB and
  a MIR/verifier surface for nothing.
* Re-formatting the interpolated expressions: the layout engine's width logic does not apply inside a literal that may span
  lines; verbatim printing is idempotent and unsurprising.

## Consequences / limitations

* Arrays of narrow integers use 8 bytes per element; an `u8[]` is not a byte buffer.
* `sort` takes a comparator returning `int`: `(a, b) => (a - b).toInt()` for narrower element types.
* `i128` / `u128` unsupported (E0431). `toString` of `u64` above 2^63 works; `float`-to-integer conversions other than `float.toInt()`
  (to `int`) do not exist (`f.toInt().toI32()`).
* `orin verify --contracts` does not model widths other than `int` / `i64`.
* The compiler's own source cannot use any of this (Orin-B; Stage 0 builds it), so templates are not yet used inside `compiler/`.
* New diagnostics: E0430 (integer literal out of range for its type), E0431 (128-bit integer types not supported yet), E0432
  (value of this type cannot be interpolated). MIR v1.6: no new type; `OUsize` is a 64-bit pattern; seven built-ins.
