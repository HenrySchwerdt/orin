# 3. Types

Normative for the checker as built (`compiler/check/`, HIR types in `compiler/hir/hir.or`). Sources: ADR-0003, 0004, 0007,
0009, 0011, 0018, 0019, 0022, 0026, 0034 and what `build/bootstrap/orin2` accepts. Rule ids are `TYP-n`; a test
named under a rule exercises it (see the [README](README.md) for the conventions).

Every type is one of: a **scalar** (integers, `bool`, `float`, `f32`), a **value aggregate** (`string`, arrays, records, tagged
unions, `Option`, `Result`, `Map`, class instances, interface values, function values) or a **resource handle** (chapter 5, not a
value). All aggregates have **value semantics** (TYP-14): copying never shares mutable state.

## 3.1 Integers

**TYP-1.** The integer types are `i8 i16 i32 i64 u8 u16 u32 u64 isize usize`, and `int`, which is another name for `i64`
(`const b: int = a` accepts an `i64`). `usize` and `isize` are pointer-width (64 bit) types that are *distinct* types from `u64`
and `i64`: mixing them is E0400. `usize` is the type of `length`, `size`, indices and `charCodeAt` arguments.
- Tests: `tests/next/run/int_isize_usize_alias.or`, `tests/next/run/int_types_basic.or`,
  `tests/next/errors/e0400_usize_is_not_u64.or`, `tests/next/errors/e0400_isize_is_not_i64.or`,
  `tests/next/errors/e0400_index_with_i32.or`, `tests/errors/e0400_index_int.or`, `tests/errors/e0400_usize_as_int.or`.

**TYP-2.** `i128` and `u128` (and `toI128`, `toU128`, `parseI128`, `parseU128`) are reserved and rejected with E0431.
- Tests: `tests/next/errors/e0431_i128_type.or`, `tests/next/errors/e0431_u128_param.or`, `tests/next/errors/e0431_to_i128.or`.

**TYP-3.** An integer literal has the integer type expected where it occurs (annotation, parameter, field, the other operand of a
binary operator, array element, return value), otherwise `int`. A literal that does not fit its type is E0430; a negative
literal where an unsigned type is expected is E0400; a literal never becomes a float (`let x: float = 1;` is E0400). A "big"
literal (2^63 to 2^64-1) is valid only as `u64` or `usize`.
- Tests: `tests/next/run/int_types_basic.or`, `tests/next/run/int_u64_full_range.or`,
  `tests/next/errors/e0430_int_literal_i8_overflow.or`, `tests/next/errors/e0430_int_literal_u16_overflow.or`,
  `tests/next/errors/e0430_int_literal_negative_i8_underflow.or`, `tests/next/errors/e0430_const_literal_range.or`,
  `tests/next/errors/e0430_pattern_literal_range.or`, `tests/next/errors/e0430_negative_big_literal.or`,
  `tests/next/errors/e0400_negative_literal_unsigned.or`, `tests/next/errors/e0400_negative_literal_u64.or`,
  `tests/next/errors/e0400_int_literal_as_float.or`, `tests/run/int_usize_literals.or`.

**TYP-4.** There are no implicit numeric conversions. Mixing two integer types (or an integer and a float, or `float` and `f32`) in an
operator, argument, assignment, return or array element is E0400 ("convert explicitly"). Conversions are methods on every integer
type: `toI8 toI16 toI32 toI64 toIsize toU8 toU16 toU32 toU64 toUsize toInt` and `toFloat`, `toF32`. A conversion that cannot
fail is free; one that can fail **traps** (`trap: integer conversion out of range`, exit 101) when the value is outside the target
range.
- Tests: `tests/next/run/int_conversions.or`, `tests/next/errors/e0400_int_mix_i32_i64.or`, `tests/next/errors/e0400_int_mix_i32_float.or`,
  `tests/next/errors/e0400_int_assign_wrong_width.or`, `tests/next/errors/e0400_int_argument_wrong_width.or`,
  `tests/next/errors/e0400_int_return_wrong_width.or`, `tests/next/errors/e0400_array_element_width.or`,
  `tests/next/errors/e0400_float_int_mix.or`, `tests/next/errors/e0400_float_f32_mix.or`,
  `tests/next/run/int_trap_conv_i16_to_i8.or`, `tests/next/run/int_trap_conv_negative_to_u32.or`,
  `tests/next/run/int_trap_conv_u64_to_i64.or`, `tests/next/run/int_trap_conv_int_to_usize_unchanged.or`,
  `tests/run/toint_trap.or`, `tests/run/tousize_trap.or`.

**TYP-5.** Arithmetic is checked. `+ - * /` and unary `-` on every integer type trap when the result leaves the type's range
(`trap: integer overflow`; `usize`/`u64` report `usize overflow` / `usize underflow`). Division or remainder by zero traps
(`division by zero` / `modulo by zero`). `MIN / -1` traps for every signed width; `MIN % -1` is 0 for the narrow widths and
traps for `i64`. `/` truncates toward zero and `%` has the sign of the dividend. A compound assignment (`x += 1`) is the same operation.
- Tests: `tests/run/overflow_add.or`, `tests/run/overflow_sub.or`, `tests/run/overflow_mul.or`, `tests/run/overflow_usize_sub.or`,
  `tests/run/div_zero_trap.or`, `tests/run/mod_zero_trap.or`, `tests/run/arith_boundaries.or`, `tests/run/arith_basic.or`,
  `tests/next/run/int_trap_i32_add_overflow.or`, `tests/next/run/int_trap_i8_negate_min.or`,
  `tests/next/run/int_trap_i32_div_min_by_minus_one.or`, `tests/next/run/int_trap_u32_division_by_zero.or`,
  `tests/next/run/int_trap_i16_remainder_by_zero.or`, `tests/next/run/int_trap_u8_sub_underflow.or`,
  `tests/next/run/int_trap_u64_add_overflow.or`, `tests/next/run/int_trap_compound_assign_narrow.or`.

**TYP-6.** `wrappingAdd/Sub/Mul` (modular), `checkedAdd/Sub/Mul` (`Option<T>`, `None` on overflow) and `saturatingAdd/Sub/Mul` exist
on every integer type; the argument has the receiver's type. There is no `wrappingNeg`, `*Div`, `abs`, `min`, `max` or `pow` for integers.
There are no bitwise operators and no shifts.
- Tests: `tests/next/run/int_wrapping_checked_saturating.or`, `tests/next/errors/e0400_wrapping_argument_type.or`,
  `tests/next/errors/e0404_wrapping_arity.or`, `tests/next/errors/e0405_wrapping_div_not_provided.or`,
  `tests/next/errors/e0405_int_sqrt.or`, `tests/parse_edge/err0200_binary_bitor.or`.

**TYP-7.** `toString()` prints decimal. `parseInt(s): Option<int>` and `parseI8 .. parseUsize` take `-? digits` only (no `+`, no
spaces, never `-` for unsigned types) and return `None` on any other text or on overflow.
- Tests: `tests/run/parse_int.or`, `tests/next/run/int_parse.or`, `tests/next/errors/e0400_parse_i32_result_is_option.or`,
  `tests/next/errors/e0400_parse_u8_wrong_argument.or`, `tests/run/tostring_conv.or`.

**TYP-8.** Comparison `== != < <= > >=` is defined on each integer type with its own order (unsigned for `u64`/`usize`); `-` on an
unsigned type is E0410; `!` and `&&`/`||` on integers are E0410.
- Tests: `tests/run/comparisons.or`, `tests/next/errors/e0410_negate_unsigned.or`, `tests/errors/e0410_and_on_ints.or`,
  `tests/errors/e0410_not_on_int.or`, `tests/next/errors/e0400_int_mix_u8_int_comparison.or`.

## 3.2 Floats

**TYP-9.** `float` is IEEE-754 binary64 and `f32` binary32. A float literal has the expected float type, else `float`. `+ - * /`
and unary `-` follow IEEE and never trap (`1.0 / 0.0` is `Infinity`, `0.0 / 0.0` is `NaN`); each `f32` operation is rounded to
binary32. `%` is E0410. `==`/`!=` and `< <= > >=` follow IEEE (`NaN != NaN`, `0.0 == -0.0`).
- Tests: `tests/next/run/float_arithmetic_ops.or`, `tests/next/run/float_nan_infinity.or`, `tests/next/run/float_neg_zero_and_signs.or`,
  `tests/next/run/f32_basic.or`, `tests/next/run/f32_accumulate.or`, `tests/next/errors/e0410_float_rem.or`,
  `tests/next/errors/e0410_float_rem_assign.or`, `tests/next/errors/e0410_float_not.or`,
  `tests/next/errors/e0400_float_literal_as_int.or`, `tests/next/errors/e0400_float_argument_int.or`.

**TYP-10.** Float methods: `toString()` (shortest digits that round-trip, JavaScript-like layout, `NaN`, `Infinity`, `-0.0`),
`toInt()` (truncates; **traps** on NaN, infinities and values outside `int`), `round()` (half away from zero), `floor()`, `ceil()`,
`sqrt()`, `abs()`, `pow(y)`, `isNaN()`, `isFinite()`, `toF32()` / `toFloat()`. `parseFloat(s): Option<float>` accepts
`-? digits (. digits)? ([eE] [+-]? digits)?`, `Infinity`, `-Infinity`, `NaN`. `std:math` adds `PI`, `E`, `min`, `max`.
- Tests: `tests/next/run/float_to_string_shortest.or`, `tests/next/run/float_parse.or`, `tests/next/run/float_round_trip_parse_print.or`,
  `tests/next/run/float_int_conversions.or`, `tests/next/run/float_math_edge_cases.or`, `tests/next/run/float_math_module.or`,
  `tests/next/run/float_toint_trap_nan.or`, `tests/next/run/float_toint_trap_inf.or`, `tests/next/run/float_toint_trap_range.or`,
  `tests/next/errors/e0405_float_unknown_method.or`, `tests/next/errors/e0400_float_to_int_width.or`.

**TYP-11.** `float` and `f32` are not `Eq`/`Ord`/`Hash` as a component or a bound (NaN): a record, union, array or `Option`
containing one has no `==`/`<` (E0410), cannot be a `Map` key (E0400/E0475) and does not satisfy an `Eq` bound (E0475). `==` on a bare
`float` works. A float cannot be matched on (E0402).
- Tests: `tests/next/errors/ts_dev_e0410_record_eq.or`, `tests/next/errors/ts_dev_e0410_option_eq.or`,
  `tests/next/errors/e0410_record_with_float_equality.or`, `tests/next/errors/e0402_match_float.or`,
  `tests/next/errors/e0400_map_key_float.or`, `tests/next/errors/e0475_eq_bound_record_with_float.or`,
  `tests/next/errors/e0475_ord_bound_float_argument.or`, `tests/next/errors/e0475_map_key_record_with_float.or`.

## 3.3 bool and string

**TYP-12.** `bool` has the values `true` and `false`. `&&` and `||` evaluate the right operand only when needed. `!`, `&&`, `||`
accept `bool` only (E0410); an `if`/`while`/`?:` condition must be `bool` (E0400). `toString()` is `"true"`/`"false"`.
- Tests: `tests/run/bool_logic.or`, `tests/run/logical_shortcircuit.or`, `tests/errors/e0410_and_on_ints.or`,
  `tests/errors/e0410_not_on_int.or`, `tests/next/errors/ts_dev_e0400_if_condition.or`.

**TYP-13.** A `string` is an immutable byte string (UTF-8 bytes pass through unchanged). `length` is a `usize` byte count. `+`
concatenates two strings, `==`/`!=`/`<`/`<=`/`>`/`>=` compare byte-wise, indexing `s[i]` is E0400. Methods:
`charCodeAt(i)`, `charAt(i)`, `substring(a, b)`, `indexOf(s): Option<usize>`, `includes`, `startsWith`, `endsWith`,
`split(sep)` (JavaScript semantics; an empty separator traps), `trim()` (ASCII white space); on `string[]`, `join(sep)`;
`String.fromCharCode(n)`. An out-of-range `charAt`, `charCodeAt` or `substring` traps. `-` on strings is E0410.
- Tests: `tests/run/string_basic.or`, `tests/run/string_search.or`, `tests/run/string_split.or`, `tests/run/string_trim.or`,
  `tests/run/string_charcode.or`, `tests/run/string_charat_trap.or`, `tests/run/string_charcode_trap.or`,
  `tests/run/string_substring_trap.or`, `tests/run/string_split_empty_trap.or`, `tests/run/array_join.or`,
  `tests/errors/e0410_string_minus.or`, `tests/next/run/bytes_string_bulk.or`.

## 3.4 Aggregates and value semantics

**TYP-14.** Arrays, records, unions, `Option`, `Result`, `Map`, strings and class instances are **values**: `const b = a;` then
changing `a` leaves `b` unchanged. (The implementation copies lazily, copy-on-write; the copy is not observable.) A function
parameter is an immutable value. A closure captures a snapshot (TYP-24). An interface value holds a snapshot of the class value.
- Tests: `tests/run/value_semantics_record.or`, `tests/run/value_semantics_function.or`, `tests/run/array_value_semantics.or`,
  `tests/next/run/class_copy_independence.or`, `tests/next/run/map_value_semantics.or`, `tests/next/run/iface_value_snapshot.or`,
  `tests/next/run/generic_mutation.or`, `tests/next/run/float_value_semantics.or`.

**TYP-15.** Arrays: `T[]`, literal `[a, b]` (all elements the expected element type). `xs[i]` needs a `usize` index and traps when
out of bounds; `length` is `usize`; `push(v)` and `pop(): Option<T>` mutate and need a mutable place (E0401); `get(i): Option<T>`,
`slice(a, b)` (traps unless `a <= b <= length`), `concat(ys)`; the prelude adds `map filter find findIndex some every reduce forEach sort`
(and `indexOf`/`includes` for element types with equality). An empty literal needs an expected type (E0407). `Circle[]` is not a
`Shape[]` (no array covariance, E0400). `for (const x of xs)` iterates over a snapshot of the array.
- Tests: `tests/run/array_basic.or`, `tests/run/array_oob_trap.or`, `tests/run/array_push_pop.or`, `tests/run/array_slice_concat.or`,
  `tests/run/array_slice_trap_end.or`, `tests/run/array_for_of_snapshot.or`, `tests/run/array_nested.or`,
  `tests/next/run/array_map_filter_chain.or`, `tests/next/run/array_reduce_foreach.or`, `tests/next/run/array_sort_stable.or`,
  `tests/next/run/array_find_some_every.or`, `tests/next/run/array_index_of_includes.or`, `tests/errors/e0407_empty_array.or`,
  `tests/errors/e0401_push_const.or`, `tests/errors/e0401_push_param.or`, `tests/next/errors/e0400_array_not_covariant.or`.

**TYP-16.** A record type `type P = { x: int; y: string; };` is **nominal**: two record types with the same fields are different
types. A literal `P { x: 1, y: "a" }` lists every field exactly once (E0411 for a missing, duplicate or unknown field) unless it
starts with a spread `P { ...base, y: "b" }`, which copies the remaining fields. A field is assigned (`p.x = 1`) only through a
mutable place (a `let` local, E0401 otherwise). Records have no methods.
- Tests: `tests/run/record_basic.or`, `tests/run/record_nested_assign.or`, `tests/run/record_update_spread.or`,
  `tests/run/record_in_array.or`, `tests/errors/e0411_missing_field.or`, `tests/errors/e0411_duplicate_field.or`,
  `tests/errors/e0411_unknown_field.or`, `tests/errors/e0401_field_assign_const.or`, `tests/errors/e0401_assign_const.or`.

**TYP-17.** A tagged union is `type U = A | B(int) | C(string, bool);`: each member is a *variant* with positional payload types. A
variant name is a module-level constructor and must be unique per module (E0304); importing a union type imports its variants. A
nullary variant is used as a bare name, a payload variant is called (`B(3)`). Unions may be recursive and generic. There are no
untagged unions and no `enum`.
- Tests: `tests/run/union_basic.or`, `tests/run/union_recursive.or`, `tests/run/modules_reexport_union`,
  `tests/errors/e0304_duplicate_variant.or`, `tests/next/run/generic_list_union.or`, `tests/next/run/generic_tree.or`.

**TYP-18.** `Option<T>` is `Some(T) | None`, `Result<T, E>` is `Ok(T) | Err(E)`; both are ordinary unions with built-in constructors
and methods: `isSome() isNone() unwrap() unwrapOr(d)` and `isOk() isErr() unwrap() unwrapErr()`; `unwrap` on the wrong variant
traps. `None`, `Ok(..)`, `Err(..)` need an expected type when it cannot be inferred (E0407). A `Result<void, E>` succeeds with
`Ok()`. An `Option` is never implicitly unwrapped (`const x: int = parseInt(s)` is E0400).
- Tests: `tests/run/option_methods.or`, `tests/run/result_methods.or`, `tests/run/option_unwrap_trap.or`,
  `tests/run/result_unwrap_trap.or`, `tests/run/result_unwraperr_trap.or`, `tests/run/match_option_result.or`,
  `tests/errors/e0407_none_infer.or`, `tests/errors/e0407_ok_infer.or`, `tests/errors/e0400_option_as_value.or`.

**TYP-19.** Postfix `?` (chapter 4) is defined on `Result<T, E>` only, inside a function whose result type is `Result<U, E>` with the
same `E`; on an `Option`, outside such a function, or with a different error type it is E0406.
- Tests: `tests/run/result_propagation.or`, `tests/errors/e0406_question_on_option.or`, `tests/errors/e0406_question_in_non_result_fn.or`,
  `tests/errors/e0406_mismatched_error_type.or`, `tests/next/run/closure_result_question.or`.

**TYP-20.** `void` is the type of a function with no result type, and `T` in `Result<T, E>`. It is also accepted as a type argument of
a generic function, method or class (ADR-0040): a closure with no result instantiates `T = void` (`run(() => { ... })`, `s.spawn(f)`),
and inside such an instance `Option<void>`, `void[]` and class fields of type `T` are allowed; `void` has no run-time representation
there. Written directly as a value, a variable, a parameter type, an array element or the payload of `Some` outside a generic instance
it is E0400.
**TYP-20a.** A method of a class may declare its own type parameters, with bounds (`m<U extends Eq>(x: U): U`); they are inferred or
given explicitly (`obj.m<int>(x)`), and the method is monomorphised per instance. A method of an **interface** may not be generic: a
virtual call cannot pick a monomorphised instance, and declaring one is E0460 (the only remaining use of E0460).
- Tests (TYP-20a): `tests/next/run/generic_methods.or`, `tests/next/run/generic_methods_contracts.or`,
  `tests/next/run/void_type_args_basic.or`, `tests/next/run/void_type_args_class.or`, `tests/next/errors/e0460_interface_generic_method.or`.
- Tests: `tests/run/void_early_return.or`, `tests/run/match_option_result.or` (`Ok()` with `Result<void, E>`).

## 3.5 Map

**TYP-21.** `Map<K, V>` is a built-in generic value type created by `new Map<K, V>()` (the type arguments may be omitted when the expected
type is a `Map`, else E0407). `K` must be `Hash` (TYP-35): the integers, `bool`, `string`, and records, unions, `Option`, `Result` and
arrays of those, or a class with `hash`; a key that can never be hashed (`float`, a function) is E0400 where the type is written, a
composite key that contains one is E0475. `V` may be any value type. Methods: `get(k): Option<V>`, `has(k): bool`, `set(k, v)` and
`delete(k): bool` (mutating: the receiver must be a mutable place, E0401), `keys()`, `values()`, `entries()` (arrays of `MapEntry<K, V>
= { key: K; value: V; }`), and the read-only field `size: usize` (assigning it is E0401). Iteration order is insertion order; overwriting
keeps the position, deleting and re-inserting moves the key to the end. A `Map` is not comparable (E0410). A `Map` call that mutates
cannot appear in a condition (E0408).
- Tests: `tests/next/run/map_basic_string_int.or`, `tests/next/run/map_iteration_order.or`, `tests/next/run/map_delete_and_rebuild.or`,
  `tests/next/run/map_new_forms_and_params.or`, `tests/next/run/map_int_usize_bool_keys.or`, `tests/next/run/map_value_semantics.or`,
  `tests/next/run/eqord_map_keys.or`, `tests/next/errors/e0400_map_get_wrong_key.or`, `tests/next/errors/e0400_map_set_wrong_value.or`,
  `tests/next/errors/e0400_new_map_one_type_arg.or`, `tests/next/errors/e0407_new_map_uninferable.or`,
  `tests/next/errors/e0401_map_set_on_const.or`, `tests/next/errors/e0401_map_size_assign.or`,
  `tests/next/errors/e0410_map_equality.or`, `tests/next/errors/e0408_map_delete_in_condition.or`,
  `tests/next/errors/e0475_map_key_record_with_float.or`, `tests/next/errors/e0405_map_unknown_method.or`.

## 3.6 Function types and closures

**TYP-22.** A function type is `(name: T, ...) => R` and is compared structurally by parameter and result types (names are
documentation). A top-level function can be used as a value (`const g = double;`). Function values are immutable and have no
equality (`==` is E0410). A function value is called like a function (arity E0404, argument types E0400).
- Tests: `tests/next/run/closure_function_values.or`, `tests/next/run/closure_type_aliases.or`, `tests/next/errors/e0410_function_equality.or`,
  `tests/next/errors/e0404_function_value_call_arity.or`, `tests/next/errors/e0400_function_value_argument_type.or`,
  `tests/next/errors/e0400_function_type_mismatch.or`, `tests/next/errors/e0400_call_non_function_local.or`.

**TYP-23.** An arrow function is `x => e`, `(x: T, y) => e`, `(x: T): R => e`, or with a block body. A parameter type may be omitted
only when an expected function type is known (E0407 otherwise). The result type is the declared one, else the expected one, else
inferred from the body; the `return`s of a block body must agree (E0400) and every path must return (E0403). Wrong parameter
count against the expected type is E0404.
- Tests: `tests/next/run/closure_basic.or`, `tests/next/run/closure_void_and_zero_params.or`, `tests/next/run/closure_higher_order.or`,
  `tests/next/errors/e0407_arrow_param_needs_type.or`, `tests/next/errors/e0400_closure_inconsistent_returns.or`,
  `tests/next/errors/e0400_closure_return_type_mismatch.or`, `tests/next/errors/e0403_closure_missing_return.or`,
  `tests/next/errors/e0404_arrow_param_count.or`, `tests/next/errors/e0304_duplicate_arrow_param.or`.

**TYP-24.** A closure captures the **current values** of the outer locals it mentions, at creation time (a snapshot). Captured names
are immutable inside the closure (assignment, `push` or a mutating call is E0401); a later change to the outer variable is not seen by
the closure, and a closure cannot modify an outer variable. A closure cannot refer to itself (E0300). Results leave a closure through
its return value, not through assignment. A resource handle cannot be captured (E0452, chapter 5).
- Tests: `tests/next/run/closure_capture_snapshot.or`, `tests/next/run/closure_snapshot_array.or`, `tests/next/run/closure_nested_capture.or`,
  `tests/next/run/closure_scoping_shadowing.or`, `tests/next/errors/e0401_closure_assign_captured.or`,
  `tests/next/errors/e0401_closure_nested_assign_captured.or`, `tests/next/errors/e0401_closure_push_captured.or`,
  `tests/next/errors/e0300_closure_self_reference.or`, `tests/next/errors/ts_dev_e0401_closure_assign.or`.

## 3.7 Generics

**TYP-25.** Generic functions `function f<A, B>(..)`, generic record types, generic tagged unions, generic aliases
(`type List<T> = T[];`) and generic classes (TYP-33) take type parameters. Type parameters are plain distinct names (E0304) that do not
reuse a built-in type name (E0408). A type application needs exactly as many arguments as parameters (E0400); a non-generic type
given arguments is E0400; a generic type used without arguments is E0400.
- Tests: `tests/next/run/generic_identity.or`, `tests/next/run/generic_pair.or`, `tests/next/run/generic_alias.or`,
  `tests/next/run/generic_either.or`, `tests/next/run/generic_nested.or`, `tests/next/errors/e0304_duplicate_type_param.or`,
  `tests/next/errors/e0408_type_param_shadows_builtin.or`, `tests/next/errors/e0400_type_args_too_few.or`,
  `tests/next/errors/e0400_type_args_too_many.or`, `tests/next/errors/e0400_nongeneric_type_with_args.or`,
  `tests/next/errors/e0400_generic_type_without_args.or`.

**TYP-26.** Calls infer type arguments from the arguments and from the expected type; explicit arguments `f<int>(x)` are allowed.
An argument that cannot be inferred (a return-only type parameter, an empty literal, a nullary generic variant, a generic function
value without expected type) is E0407; conflicting inferences or a mismatch with explicit arguments are E0400; the wrong number of
explicit arguments is E0400.
- Tests: `tests/next/run/generic_first.or`, `tests/next/run/generic_explicit_args.or`, `tests/next/run/generic_infer_expected.or`,
  `tests/next/run/generic_defer_inference.or`, `tests/next/errors/e0407_uninferable_return_only.or`,
  `tests/next/errors/e0407_nullary_generic_variant.or`, `tests/next/errors/e0407_generic_function_value_uninferred.or`,
  `tests/next/errors/e0400_conflicting_inference.or`, `tests/next/errors/e0400_explicit_type_arg_mismatch.or`,
  `tests/next/errors/e0400_explicit_type_args_arity.or`, `tests/next/errors/e0404_generic_call_arity.or`.

**TYP-27.** A generic function or type is checked **once, abstractly**, at its definition, with opaque type parameters: inside the
body a `T` value supports only binding, passing, returning and storing in arrays, records, `Option`, `Result`; `==`, `<`, `+`
(E0410), methods and fields (E0405), `match` on a `T` (E0402) and literals typed `T` (E0400) are rejected unless the parameter has a bound
that provides them (TYP-28, TYP-35). Each distinct instantiation is then compiled separately (monomorphisation), so there is no run-time cost.
An instantiation chain that does not terminate (polymorphic recursion) is E0413.
- Tests: `tests/next/run/generic_opaque_ops.or`, `tests/next/run/generic_multiple_instances.or`, `tests/next/run/generic_deep_instances.or`,
  `tests/next/run/generic_recursion.or`, `tests/next/errors/e0410_eq_on_type_param.or`, `tests/next/errors/e0410_add_on_type_param.or`,
  `tests/next/errors/e0410_lt_on_type_param.or`, `tests/next/errors/e0405_method_on_type_param.or`,
  `tests/next/errors/e0405_field_on_type_param.or`, `tests/next/errors/e0402_match_on_type_param.or`,
  `tests/next/errors/e0400_generic_body_type_mismatch.or`, `tests/next/errors/e0413_polymorphic_recursion.or`,
  `tests/next/errors/e0413_infinite_type_instantiation.or`.

**TYP-28.** A type parameter of a generic function, class or method may have **one or several bounds**, `T extends I` or `T extends A & B`,
where each bound is an interface (TYP-29) or `Eq`/`Ord`/`Hash` (TYP-35). The opaque `T` then has the methods of every bound, and converts
to each bound interface. Every instantiation is checked against all bounds, in order; the first one the argument does not satisfy is the
error: the argument must be a class that implements the interface (nominally), the interface itself, or a parameter bounded by it (E0417),
and for `Eq`/`Ord`/`Hash` it must have the instance (E0475 / E0476). The order of the bounds is not significant, `Ord` and `Hash` imply `Eq`,
and `T extends Ord & Hash` works with derived and explicit instances alike. A member lookup on `T` searches all bounds; two bounds that
declare a method of the same name with different parameter or result types are E0477 at the declaration (the same signature in both is fine),
and the same bound twice is E0304. A method that no bound declares is E0405. A bound that names no interface is E0400 (or E0300 if unknown);
a bound on a `type` is E0408.
- Tests: `tests/next/run/genclass_bounds.or`, `tests/next/run/iface_bound_calls_bound.or`, `tests/next/run/iface_static_bound_sum.or`,
  `tests/next/run/iface_generic_bound_modules`, `tests/next/errors/e0417_bound_violation_builtin.or`,
  `tests/next/errors/e0417_genclass_bound_inferred.or`, `tests/next/errors/e0417_bound_not_declared.or`,
  `tests/next/errors/e0400_bound_not_interface.or`, `tests/next/errors/e0300_bound_unknown_interface.or`,
  `tests/next/errors/e0408_bound_on_generic_type.or`, `tests/next/errors/e0405_method_not_in_bound.or`,
  `tests/next/run/multi_bounds_ord_hash.or`, `tests/next/run/multi_bounds_class_and_interface.or`, `tests/next/run/multi_bounds_methods.or`,
  `tests/next/errors/e0417_second_bound_unsatisfied.or`, `tests/next/errors/e0417_second_bound_unsatisfied_class.or`,
  `tests/next/errors/e0475_second_bound_hash_unsatisfied.or`, `tests/next/errors/e0477_conflicting_bound_members.or`,
  `tests/next/errors/e0477_conflicting_bound_params.or`, `tests/next/errors/e0304_duplicate_bound.or`,
  `tests/next/errors/e0405_multi_bound_no_such_member.or`.

## 3.8 Interfaces

**TYP-29.** `interface I { m(a: T): R; }` declares method signatures only. Conformance is **nominal**: `class C implements I` requires, for each
interface method, a public, non-static instance method of `C` with identical parameter and result types (E0417 with the required and the
found signature). A class that does not declare `implements I` never converts to `I` (E0417 at the use), however similar it is. The
implementing method must not mutate its receiver (E0418). An interface has no fields, default bodies, `extends`, type parameters or generic
methods (E0408), and a duplicate method name is E0304.
- Tests: `tests/next/run/iface_basic_dispatch.or`, `tests/next/run/iface_multiple_interfaces.or`, `tests/next/run/iface_empty_interface.or`,
  `tests/next/errors/e0417_missing_method.or`, `tests/next/errors/e0417_wrong_param_type.or`, `tests/next/errors/e0417_wrong_return_type.or`,
  `tests/next/errors/e0417_wrong_param_count.or`, `tests/next/errors/e0417_not_declared_implements.or`,
  `tests/next/errors/e0417_private_method_does_not_implement.or`, `tests/next/errors/e0417_static_method_does_not_implement.or`,
  `tests/next/errors/ts_dev_e0417_structural.or`, `tests/next/errors/e0418_mutating_implementation.or`,
  `tests/next/errors/e0408_interface_field.or`, `tests/next/errors/e0408_interface_default_method.or`,
  `tests/next/errors/e0408_interface_extends.or`, `tests/next/errors/e0408_interface_generic.or`,
  `tests/next/errors/e0304_interface_duplicate_method.or`, `tests/next/errors/e0300_implements_unknown_interface.or`,
  `tests/next/errors/e0400_implements_non_interface.or`.

**TYP-30.** An interface name is a type (`Shape`, `Shape[]`, `Option<Shape>`, a parameter, a field). A value of a class type `C` converts
**implicitly** to every interface `C` declares, wherever a value is checked against an expected type (initialiser, argument, return,
assignment, array element, record field, `Some(..)`). This is the only implicit conversion in the language. It is not applied
element-wise (`Circle[]` is not a `Shape[]`), an interface does not convert to another interface or back to a class, there are no
downcasts, and `==` on interface values is E0410. The interface value holds a snapshot of the class value; its methods are called as `s.area()`.
- Tests: `tests/next/run/iface_array_of_values.or`, `tests/next/run/iface_assign_and_reassign.or`, `tests/next/run/iface_in_option.or`,
  `tests/next/run/iface_in_record_and_class.or`, `tests/next/run/iface_cond_and_match.or`, `tests/next/run/iface_value_snapshot.or`,
  `tests/next/errors/e0400_interface_to_class.or`, `tests/next/errors/e0400_interface_to_other_interface.or`,
  `tests/next/errors/e0400_array_not_covariant.or`, `tests/next/errors/e0410_eq_on_interface_values.or`,
  `tests/next/errors/e0405_field_of_interface_value.or`, `tests/next/errors/e0405_unknown_interface_method.or`,
  `tests/next/errors/e0400_interface_as_record_literal.or`.

## 3.9 Classes

**TYP-31.** `class C { fields; constructor(..) { .. } methods }` declares a **nominal value type** with copy semantics (a copy is a
snapshot; there is no shared identity). Instances are created with `new C(args)` (also `new C<T>(args)`); a record literal for a class is
E0408 outside its own body. A field has a type and an optional initialiser; constructor parameters may be marked `public`/`private` to declare
fields. Every field must be definitely assigned before the constructor returns and before `this` is used other than as a top-level
`this.f = e;` statement (E0411). Members are public by default; `private` members are accessible only inside the class body (E0405
otherwise). Methods are called `x.m(a)`; `static` methods are called `C.s(a)`. `this` outside a class, in a static method or before
initialisation is E0300.
- Tests: `tests/next/run/class_stack.or`, `tests/next/run/class_ctor_body.or`, `tests/next/run/class_field_initializers.or`,
  `tests/next/run/class_param_properties.or`, `tests/next/run/class_private_fields.or`, `tests/next/run/class_static_methods.or`,
  `tests/next/run/class_copy_independence.or`, `tests/next/run/class_in_array.or`, `tests/next/run/class_module`,
  `tests/next/errors/e0411_class_missing_field_init.or`, `tests/next/errors/e0411_class_field_assigned_late.or`,
  `tests/next/errors/e0408_class_record_literal.or`, `tests/next/errors/e0405_class_private_field.or`,
  `tests/next/errors/e0405_class_private_method.or`, `tests/next/errors/e0405_class_unknown_field.or`,
  `tests/next/errors/e0405_class_unknown_method.or`, `tests/next/errors/e0405_class_instance_method_as_static.or`,
  `tests/next/errors/e0404_class_ctor_arity.or`, `tests/next/errors/e0404_class_method_arity.or`,
  `tests/next/errors/e0300_class_this_outside.or`, `tests/next/errors/e0300_class_this_in_static.or`,
  `tests/next/errors/e0300_class_this_before_init.or`, `tests/next/errors/e0300_class_new_unknown.or`,
  `tests/next/errors/e0400_class_new_non_class.or`.

**TYP-32.** Whether a method **mutates** is inferred: a method mutates if its body assigns to a `this` place, calls a mutating built-in
(`push`, `pop`, `set`, `delete`) on a `this` place, or calls a mutating method on `this` or a `this` place. Calling a mutating method
needs a mutable receiver place (a `let` local, a `let` field path, or `this` inside a mutating method); on a `const`, a parameter, a
`for` variable or a temporary it is E0401. A mutating method that returns a value, or uses `?`, is allowed. `this` in a non-mutating
method is immutable. A mutating call cannot appear in a condition of `if`/`while`/`?:` (E0408). The inferred mutability of exported
methods is part of the module's public API.
- Tests: `tests/next/run/class_counter_value_semantics.or`, `tests/next/run/class_mutating_calls_mutating.or`,
  `tests/next/run/class_mutating_with_result.or`, `tests/next/run/class_mutating_result_try.or`, `tests/next/run/class_nested_field_mutation.or`,
  `tests/next/run/mutating_result.or`, `tests/next/errors/e0401_class_const_receiver.or`, `tests/next/errors/e0401_class_param_receiver.or`,
  `tests/next/errors/e0401_class_for_var_receiver.or`, `tests/next/errors/e0401_class_temporary_receiver.or`,
  `tests/next/errors/e0408_class_mut_call_in_condition.or`, `tests/next/errors/ts_dev_e0401_const_mutating_call.or`.

**TYP-33.** A class has no inheritance (`extends` is E0408), no `protected`, getters/setters, overloads, abstract members, static fields
(E0408); a class method may be generic (ADR-0040), an interface method may not (E0460). A **generic class** `class Box<T extends I> { .. }` is
instantiated per type-argument list (`Box<int>` and `Box<string>` are distinct types, E0400 on mixing); its type parameters are not in
scope in static methods (E0461), may carry bounds (`T extends A & B`), and every instantiation is checked (E0417); a class needs its type arguments
(`Box` alone is E0400) and exactly as many as it has parameters.
- Tests: `tests/next/errors/e0408_class_extends.or`, `tests/next/errors/ts_dev_e0408_extends.or`, `tests/next/errors/e0460_interface_generic_method.or`,
  `tests/next/errors/e0461_genclass_static_uses_param.or`,
  `tests/next/errors/e0408_genclass_extends.or`, `tests/next/run/genclass_basic.or`, `tests/next/run/genclass_multi_params.or`,
  `tests/next/run/genclass_implements.or`, `tests/next/run/genclass_storage.or`, `tests/next/run/genclass_module`,
  `tests/next/errors/e0400_genclass_instances_are_distinct_types.or`, `tests/next/errors/e0400_genclass_without_type_arguments.or`,
  `tests/next/errors/e0400_genclass_too_many_type_arguments.or`, `tests/next/errors/e0400_genclass_nongeneric_type_arguments.or`,
  `tests/next/errors/e0300_genclass_param_out_of_scope.or`.

## 3.10 Equality, ordering and hashing

**TYP-34.** `Eq`, `Ord` and `Hash` are built-in interfaces (no import; a user interface of the same name wins). `Ord` and `Hash` imply `Eq`.
`Eq` gives `==`, `!=` and `equals(other): bool`; `Ord` gives `< <= > >=` and `compare(other): int`; `Hash` gives `hash(): usize`.
- Tests: `tests/next/run/eqord_generic_bounds.or`, `tests/next/run/eqord_edge_cases.or`, `tests/next/run/eqord_derive_records.or`,
  `tests/next/errors/e0405_hash_method_on_eq_bound.or`, `tests/next/errors/e0410_ord_operator_on_eq_bound.or`.

**TYP-35.** (Tier 1, derivation.) The integer types, `usize`, `bool` and `string` are `Eq + Ord + Hash` (`false < true`, strings byte-wise).
Records, tagged unions, `Option`, `Result` and arrays are derived structurally: `Eq`/`Hash` when all components are, `Ord`
lexicographically when all are (fields in order; a union by variant position, `None` before `Some`, `Ok` before `Err`, then payload;
arrays element by element, then by length). Derived instances need no declaration and are available on concrete types without
generics (`a == b`, `a < b`). Function values, interface values, resource handles, `Map` and anything containing `float`/`f32` have
no instance: `==`/`<` on them is E0410, a bound or key is E0475.
- Tests: `tests/next/run/eqord_derive_records.or`, `tests/next/run/eqord_derive_unions_arrays.or`, `tests/next/run/eqord_declaration_order.or`,
  `tests/next/run/eqord_map_keys.or`, `tests/next/errors/e0410_function_equality.or`, `tests/next/errors/e0410_resource_compared.or`,
  `tests/next/errors/e0475_option_of_function.or`, `tests/next/errors/e0475_eq_bound_record_with_function.or`,
  `tests/next/errors/e0475_unbounded_param_to_bounded_function.or`.

**TYP-36.** (Tier 2, classes.) A class declares `equals(other: C): bool`, `compare(other: C): int` and/or `hash(): usize` (public,
non-static, non-mutating) and then satisfies the bound; `==` and `<` call them. `implements Eq`/`Ord`/`Hash` without the method requests
the structural instance of the fields (E0475 if a field has none). An explicit `equals` next to `implements Hash` without `hash` (or `Ord` without
`compare`), or an explicit method with a wrong signature, is E0476. A class without the method has no `==` (E0410). Records and unions
have no methods, so tier 2 is limited to classes. Tier 3 (law proofs for explicit instances) is not implemented.
- Tests: `tests/next/run/eqord_class_tier2.or`, `tests/next/run/eqord_contracts.or`, `tests/next/errors/e0476_equals_wrong_signature.or`,
  `tests/next/errors/e0476_equals_private.or`, `tests/next/errors/e0476_equals_mutates_receiver.or`,
  `tests/next/errors/e0476_implements_hash_with_explicit_equals.or`, `tests/next/errors/e0475_eq_bound_class_without_equals.or`,
  `tests/next/errors/e0475_implements_ord_with_float_field.or`, `tests/next/errors/e0475_ord_bound_hash_only.or`,
  `tests/next/errors/e0475_genclass_hash_bound_float.or`.

## 3.11 Type names and aliases

**TYP-37.** `type N = T;` (T not a record body or union) declares a **transparent alias**: `N` and `T` are the same type. Records and unions are
nominal. A name is resolved in the declaring module, then through imports, then the prelude; an unknown type name is E0300.
- Tests: `tests/next/run/closure_type_aliases.or`, `tests/next/run/generic_alias.or`, `tests/errors/e0300_unknown_type.or`,
  `tests/next/errors/ts_dev_e0400_nominal.or`, `tests/next/errors/ts_dev_e0400_union_alias.or`.

## Gaps: rules without a test

- TYP-3: that a literal adopts the type of the *other operand* of a binary operator has no dedicated test (`int_types_basic` uses it incidentally).
- TYP-5: `usize underflow` / `usize overflow` messages are asserted only through `// stderr:` on the u64 tests; the exact trap text for `MIN % -1` on `i64` has no test.
- TYP-9: `f32` rounding of every operation is shown by `f32_accumulate` only statistically.
- TYP-13: `split` with leading and trailing separators (JavaScript semantics) is covered by `string_split`, but `trim` of `\v \f` has no test.
- TYP-14: that a function parameter is immutable has a test only for `push` (`e0401_push_param`), not for field or index assignment.
- TYP-15: `slice` order trap and `get(i)` out of range for the `usize` boundary: `array_slice_trap_order` exists, `get` has no trap test (it returns `None`).
- TYP-20: no test fixes the E0400 for `void` outside a result type (a variable, `Option<void>`, an array element); only the behaviour was probed with `orin2`.
- TYP-21: the "mutating call in a condition" rule for `Map` is tested (`e0408_map_delete_in_condition`); there is no test that `entries()` order equals insertion order after `delete` of the first key.
- TYP-27: no test that an unused generic body with a type error is still reported (`e0400_generic_body_type_mismatch` covers the used case only).
- TYP-33: static fields (E0408) and `protected`/getters have no negative test.
- TYP-36: tier 3 (law proofs) and `@Property` tests are not implemented (ADR-0034 "What remains").
