# 4. Expressions and statements

Normative for the checker (`compiler/check/stmt.or`, `expr.or`, `match.or`, `pattern.or`, `ops.or`, `body.or`) and the
lowering. Syntax is in [chapter 2](02-grammar.md); types in [chapter 3](03-types.md). Rule ids are `EXP-n`.

## 4.1 Scopes and bindings

**EXP-1.** `const x = e;` binds an immutable name, `let x = e;` a mutable one; both require an initialiser, take an optional type
annotation (`const x: T = e;`) and bind one name. A name is visible from the end of its declaration to the end of the enclosing block
(no hoisting: using it earlier is E0300). The new name is **not** in scope in its own initialiser: in an inner block `const x = x + 1;`
reads the outer `x`. An inner block may shadow an outer name (a local may also shadow a parameter of the function); redeclaring a name in
the same block (also a duplicate match binding or a duplicate arrow parameter) is E0304. Function parameters are immutable.
- Tests: `tests/run/shadowing.or`, `tests/errors/e0304_duplicate_local.or`, `tests/errors/e0300_unresolved_name.or`,
  `tests/errors/e0401_assign_param.or`, `tests/next/errors/e0304_duplicate_arrow_param.or`.

**EXP-2.** A top-level `const` has an optional type annotation and an initialiser; the initialiser of a top-level constant must be a
literal (an integer, possibly negated, a float, a string or a boolean; no call, no operator), otherwise E0408. A top-level constant is immutable and may be
exported.
- Tests: `tests/run/top_level_const.or`, `tests/errors/e0400_const_type.or`, `tests/parse_edge/err0200_const_top_noinit.or`.

**EXP-3.** Names are resolved in this order: local scope, the module's declarations, its imports, then the prelude (chapter 6). An unknown
value is E0300 `unresolved name` (a function: `unresolved function`), an unknown type E0300.
- Tests: `tests/errors/e0300_unresolved_name.or`, `tests/errors/e0300_unresolved_function.or`, `tests/errors/e0300_unknown_type.or`,
  `tests/next/errors/e0300_template_unknown_name.or`.

## 4.2 Assignment and places

**EXP-4.** Assignment `place = e;` and `place op= e;` (`+= -= *= /= %=`) is a statement. A **place** is a local, `place.field` or
`place[index]`. The root of a place must be a `let` local (or `this` inside a mutating method, chapter 3): assigning to a `const`, a
parameter, a `for` variable, a captured variable or a non-place expression is E0401. The value must have the place's type (E0400).
A compound assignment is defined for the integer types and `float`/`f32` (`+=` also for `string`); on other types it is E0410. The
right side is evaluated before the assignment takes effect, after the sub-expressions of the place (EXP-23).
- Tests: `tests/errors/e0401_assign_const.or`, `tests/errors/e0401_compound_const.or`, `tests/errors/e0401_field_assign_const.or`,
  `tests/errors/e0400_assign_type.or`, `tests/run/record_nested_assign.or`, `tests/run/assign_scalar_effectful.or`,
  `tests/next/errors/e0410_float_rem_assign.or`, `tests/next/run/str_append_num.or`.

**EXP-5.** Assigning to an element or field assigns to the value stored in the root local; other values that were copied from it earlier
are unaffected (value semantics, chapter 3). `xs[i] = v` traps when `i` is out of range.
- Tests: `tests/run/array_value_semantics.or`, `tests/run/value_semantics_record.or`, `tests/run/array_oob_trap.or`.

## 4.3 Statements

**EXP-6.** `if (c) { .. } else if (d) { .. } else { .. }` and `while (c) { .. }` require a `bool` condition (E0400). `for (const x of xs)
{ .. }` iterates an **array** (strings and maps are not iterable: use `keys()`/`entries()`; E0400) over a snapshot taken when the loop
starts, so changing the array in the body does not change the iteration; the loop variable is immutable and scoped to the body.
`break;` and `continue;` act on the innermost loop and are E0409 outside one.
- Tests: `tests/run/while_break_continue.or`, `tests/run/nested_loops.or`, `tests/run/array_for_of.or`, `tests/run/array_for_of_snapshot.or`,
  `tests/errors/e0409_break_outside_loop.or`, `tests/errors/e0409_continue_outside_loop.or`, `tests/errors/e0400_arg_type.or`.

**EXP-7.** `return e;` must have the function's result type (E0400); `return;` is for `void` functions; returning a value from a `void`
function is E0400. A non-`void` function must return on every path (E0403). The rule is conservative: the last statement of the body
(recursively through `if`/`else` and `match` arms) must return or diverge; a `while (true)` without a `break` diverges; an `if` without
`else` does not count.
- Tests: `tests/run/void_early_return.or`, `tests/errors/e0400_return_type.or`, `tests/errors/e0403_missing_return.or`,
  `tests/errors/e0403_if_without_else.or`, `tests/next/errors/e0403_closure_missing_return.or`, `tests/next/errors/e0403_generic_missing_return.or`,
  `tests/run/while_break_continue.or`.

**EXP-8.** An expression statement may be any expression; its value is discarded. A statement that is a `match` expression needs no `;`.
A bare block `{ .. }` is a statement with its own scope.
- Tests: `tests/run/match_option_result.or`, `tests/parse_edge/ok_match_stmt_noterm.or`, `tests/parse_edge/ok_blocks.or`.

## 4.4 Calls, members and indexing

**EXP-9.** A call `f(args)` checks the argument count (E0404) and each argument against the parameter type (E0400); calling a non-function
is E0400; an unknown function is E0300. Arguments are evaluated left to right, then the call happens. Method calls `x.m(args)` look
the method up on the receiver's type (E0405 when there is none); `x.f` reads a field (E0405 for an unknown or private field). Function
parameters are passed by value (EXP-24). A tagged-union variant with a payload is called like a function, a payload-free variant is a bare name.
- Tests: `tests/errors/e0404_too_few_args.or`, `tests/errors/e0404_too_many_args.or`, `tests/errors/e0404_method_args.or`,
  `tests/errors/e0400_arg_type.or`, `tests/errors/e0405_unknown_field.or`, `tests/errors/e0405_unknown_method.or`,
  `tests/run/recursion.or`, `tests/run/mutual_recursion.or`, `tests/run/union_basic.or`.

**EXP-10.** `xs[i]` indexes an array with a `usize` (E0400 for another integer type); it traps when `i >= length`. A string cannot be
indexed (use `charAt`/`charCodeAt`).
- Tests: `tests/errors/e0400_index_int.or`, `tests/next/errors/e0400_index_with_i32.or`, `tests/run/array_oob_trap.or`.

## 4.5 Operators

**EXP-11.** Operand types of the binary operators (both sides the same type; no implicit conversion, chapter 3):

| Operator | Operand types | Result |
|---|---|---|
| `+` `-` `*` `/` | any one integer type, `float`, `f32`; `+` also `string` | the operand type |
| `%` | any one integer type | the operand type (E0410 for floats) |
| `<` `<=` `>` `>=` | a type with `Ord` (integers, `bool`, `string`, and derived records, unions, `Option`, `Result`, arrays, classes with `compare`); `float`/`f32` | `bool` |
| `==` `!=` | a type with `Eq`; `float`/`f32` | `bool` |
| `&&` `\|\|` | `bool` | `bool` (short-circuit) |
| unary `!` | `bool` | `bool` |
| unary `-` | signed integer, `float`, `f32` | the operand type |

Any other combination is E0410 ("operator is not defined for type ..."); two different operand types are E0400 (integer widths) or E0410.
Integer literals adopt the type of the other operand.
- Tests: `tests/run/arith_basic.or`, `tests/run/comparisons.or`, `tests/run/bool_logic.or`, `tests/errors/e0410_and_on_ints.or`,
  `tests/errors/e0410_not_on_int.or`, `tests/errors/e0410_string_minus.or`, `tests/next/errors/ts_dev_e0410_mixed_plus.or`,
  `tests/next/errors/e0410_negate_unsigned.or`, `tests/next/errors/e0410_float_rem.or`, `tests/next/errors/e0410_eq_on_interface_values.or`,
  `tests/next/errors/e0410_function_equality.or`, `tests/next/errors/e0410_map_equality.or`, `tests/next/run/eqord_derive_records.or`.

**EXP-12.** `&&` and `||` evaluate the right operand only if the left does not decide the result; a trap or effect in the skipped operand
does not happen. `c ? a : b` evaluates `c`, then exactly one branch; both branches must have the same type (E0400).
- Tests: `tests/run/logical_shortcircuit.or`, `tests/run/conditional_expr.or`, `tests/errors/e0400_arg_type.or`.

**EXP-13.** Operator precedence, associativity and the `?` / `?:` disambiguation are those of [chapter 2](02-grammar.md) (GRM-10 to GRM-12).
- Tests: `tests/run/arith_precedence.or`, `tests/run/question_vs_conditional.or`.

## 4.6 Postfix `?` (error propagation)

**EXP-14.** In a function (or closure) whose result type is `Result<U, E>`, `e?` where `e: Result<T, E>` evaluates `e`; on `Ok(v)` the
value of `e?` is `v` (type `T`); on `Err(x)` the function returns `Err(x)` immediately. The error types must be identical. `?` on an
`Option`, in a function that does not return a `Result`, with a different error type, or inside a contract is an error (E0406, E0415 in a
contract). `?` works in a mutating class method that returns a `Result`.
- Tests: `tests/run/result_propagation.or`, `tests/errors/e0406_question_on_option.or`, `tests/errors/e0406_question_in_non_result_fn.or`,
  `tests/errors/e0406_mismatched_error_type.or`, `tests/next/run/closure_result_question.or`, `tests/next/run/class_mutating_result_try.or`,
  `tests/next/errors/e0415_try_in_contract.or`, `tests/next/errors/ts_dev_e0406_question_mismatch.or`.

## 4.7 Match and patterns

**EXP-15.** `match (e) { pattern => body, .. }` evaluates `e` once and runs the first arm whose pattern matches. The result type is the
type of the arms, which must agree (E0400); an arm body is an expression or a block. In expression position (the value is used) a block
arm has no value and must end in `return`, `break` or `continue`; in statement position block arms may complete normally. A later arm
after a catch-all is accepted without a warning.
- Tests: `tests/run/match_diverging_arms.or`, `tests/run/match_option_result.or`, `tests/run/match_literals.or`,
  `tests/next/run/closure_match_body.or`, `tests/next/run/class_match_arm_call.or`, `tests/next/run/iface_cond_and_match.or`.

**EXP-16.** Patterns: `_` (anything, no binding); an integer literal (optionally negative) or string or `true`/`false` against a scalar of that
type; a variant name; a variant with sub-patterns `V(p1, p2)`. A sub-pattern is a binding name or `_` (nested variant patterns are rejected,
E0402); the sub-patterns bind the payload by value to new immutable locals scoped to the arm. A bare name in pattern position must be a
variant of the scrutinee's type (E0405 otherwise): `_` is the only catch-all. The arity of a variant pattern must match the variant (E0402).
An integer literal pattern must fit the scrutinee's type (E0430). Floats, template literals, maps and values of a type parameter cannot be
matched (E0402/E0200).
- Tests: `tests/run/match_literals.or`, `tests/run/match_option_result.or`, `tests/run/union_basic.or`, `tests/next/errors/e0430_pattern_literal_range.or`,
  `tests/next/errors/e0402_match_float.or`, `tests/next/errors/e0402_match_map.or`, `tests/next/errors/e0402_match_on_type_param.or`,
  `tests/parse_edge/err0200_match_pattern_or.or`, `tests/parse_edge/ok_match_ident_pattern_default.or`.

**EXP-17.** A match must be **exhaustive**. On a tagged union, `Option` or `Result` every variant must be covered or a `_` arm present; on
`int`, `string`, `bool` and the other scalars a `_` arm is required (E0402). A missing variant is reported by name.
- Tests: `tests/errors/e0402_nonexhaustive_union.or`, `tests/errors/e0402_option_missing_none.or`, `tests/errors/e0402_int_no_wildcard.or`,
  `tests/errors/e0402_string_no_wildcard.or`, `tests/next/errors/ts_dev_e0402_nonexhaustive.or`.

## 4.8 Template literals (interpolation)

**EXP-18.** `` `text ${e} text` `` has type `string`. Each interpolated expression must have type `string`, an integer type, `float`, `f32` or
`bool`; it is converted with its `toString` (integers decimal, floats by the shortest round-trip algorithm, `true`/`false`). Any other type
(array, record, `Option`, function, ...) is E0432 and must be converted explicitly. Expressions are evaluated left to right; the literal
may contain nested templates and any expression, including calls and arrow functions. A template literal is not a pattern (E0200), an
empty `${}` or two expressions in one is E0200.
- Tests: `tests/next/run/template_basic.or`, `tests/next/run/template_in_context.or`, `tests/next/run/template_lexing.or`,
  `tests/next/errors/e0432_template_array.or`, `tests/next/errors/e0432_template_record.or`, `tests/next/errors/e0432_template_option.or`,
  `tests/next/errors/e0432_template_function_value.or`, `tests/next/errors/ts_dev_e0432_interpolate_record.or`,
  `tests/next/errors/e0200_template_empty_interpolation.or`, `tests/next/errors/e0200_template_two_expressions.or`,
  `tests/next/errors/e0200_template_as_pattern.or`, `tests/next/errors/e0400_template_nested_expression_type_error.or`.

## 4.9 Entry point

**EXP-19.** The entry file of a program (the file given to `orin compile`/`check`, or a package's `entry`) defines `main` in exactly one of two forms, and **this is the only place that lists them**: `function main(): void` (no authority) and
`function main(host: Host): void` (chapter 5). Any other signature (a result type, other parameters, more than one parameter), or no `main`,
is E0412; a grant-typed parameter such as `main(fs: FsGrant)` is E0472.
- Tests: `tests/errors/e0412_missing_main.or`, `tests/errors/e0412_main_returns_int.or`, `tests/errors/e0412_main_with_params.or`,
  `tests/next/errors/e0412_main_host_and_more.or`, `tests/next/errors/e0472_main_fs_param.or`.

## 4.10 Evaluation order and traps

**EXP-20.** Evaluation is strict and sequential. Within an expression, operands are evaluated **left to right** (`a + b * c` evaluates `a`,
then `b`, then `c`, whatever the precedence); call arguments, array elements and record-literal fields (in the order written, not the
declaration order) are evaluated left to right before the call or construction; the condition of `?:` before its branch.
- Tests: `tests/next/run/ox_member_tags.or` (attribute order), `tests/next/run/ox_spread_intrinsic.or` (a print shows the order), `tests/next/run/str_append_num.or`.

**EXP-21.** In an assignment `xs[i] = e;`, the sub-expressions of the place (`xs`, `i`) are evaluated before `e`.
- Tests: none (probed with `orin2`; see Gaps).

**EXP-22.** A **trap** ends the program with the message on stderr and exit status 101; stdout produced before the trap is kept. The traps
of the language are: integer overflow, division or modulo by zero, failed integer or float conversion, array and string index/slice
out of range, `charAt`/`substring`/`split` misuse, `unwrap` on the wrong variant, out-of-memory, a failed run-time contract
(`--check-contracts`), `process.exit` aside. Traps are not catchable, and (apart from the unwinding of a task, chapter 8) nothing runs
after a trap.
- Tests: `tests/run/overflow_add.or`, `tests/run/array_oob_trap.or`, `tests/run/option_unwrap_trap.or`, `tests/run/result_unwrap_trap.or`,
  `tests/run/div_zero_trap.or`, `tests/run/string_charat_trap.or`, `tests/run/core_oom_trap.or`, `tests/next/run/int_trap_i32_add_overflow.or`,
  `tests/next/run/float_toint_trap_nan.or`, `tests/next/run/contracts_requires_violation.or`.

**EXP-23.** Division and remainder by a constant zero, and other traps, are *run-time* traps: the checker does not reject them.
- Tests: `tests/run/div_zero_trap.or`, `tests/run/mod_zero_trap.or`.

**EXP-24.** Arguments are passed by value. The language has no references: a callee cannot change the caller's variable, a returned
aggregate is independent of the argument it was built from. How often a value is physically copied (reference counting, copy-on-write,
last-use moves) is an optimisation and not observable (chapter 5).
- Tests: `tests/run/value_semantics_function.or`, `tests/run/owned_param_semantics.or`, `tests/run/ownership_edges.or`,
  `tests/next/run/owned_param_linear.or`.

## Gaps: rules without a test

- EXP-2: no negative test that a non-literal top-level `const` initialiser is E0408 (probed with `orin2`: `const f = (a) => a;` and calls are rejected).
- EXP-3: the order local, module, imports, prelude (and shadowing of a prelude name by a module declaration) has no test; module-level resolution is covered by chapter 6 rules.
- EXP-6: `for ... of` over a string or a map as a negative test (E0400) does not exist.
- EXP-8: an expression statement that is not a call (`1 + 2;`) is accepted; no test pins this.
- EXP-15: the "arm after a catch-all is accepted" behaviour has no test.
- EXP-16: the E0402 arity error for a variant pattern and the E0405 for a non-variant name pattern have no test of their own; the E0402 for nested patterns is only a message ("nested patterns are not supported; a variant pattern binds only names or `_`").
- EXP-20: no conformance test fixes operand, argument and element evaluation order of plain expressions; only the OX attribute tests print the order.
- EXP-21: assignment target before right-hand side has no test.
- EXP-22: traps for `slice(a, b)` with `a > b` exist (`array_slice_trap_order`); there is no test for every trap listed (e.g. a failed `process.exit` flush).
