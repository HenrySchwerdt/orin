# 10. Diagnostics index

Every diagnostic code that `compiler/` can emit, with its meaning and the conformance tests that pin it. Format of a diagnostic:
`path:line:col: error[CODE]: message` (warnings `warning[CODE]`) on stderr; errors make the exit status 1, warnings never change it.
Sources: `compiler/` (grep of every emitted code), `docs/bootstrap-subset.md` section 9 (meanings; this chapter follows the
implementation where they differ), and the `// error:` / `// warns:` headers of `tests/errors`, `tests/next/errors` and
`tests/next/run`. Conventions: see [README](README.md).

Tests column: up to three tests; `+N` is the number of further tests in the same directories with the code in their header. A
name without suffix in `tests/errors`, `tests/next/errors`, `tests/next/run` is a file `<name>.or` or a directory with `main.or`.
Codes whose tests column says "none" are listed again in the Gaps section.

| Code | Meaning | Tests |
|---|---|---|
| E0100 | lexical error | tests/errors/e0100_bad_char.or, tests/next/errors/e0100_hex_literal_too_large.or, tests/next/errors/ox_unclosed.or +11 |
| E0200 | syntax error | tests/errors/e0200_missing_expression.or, tests/next/errors/e0200_template_two_expressions.or, tests/next/errors/ts_dev_e0200_throw.or +15 |
| E0201 | `var` is not allowed (use `const` or `let`) | tests/errors/e0201_var.or |
| E0300 | unresolved name / not exported | tests/errors/e0300_not_exported, tests/next/errors/e0300_generated_private_not_exported, tests/next/errors/ts_dev_e0300_any.or +26 |
| E0301 | module file not found | tests/errors/e0301_module_not_found.or, tests/next/errors/e0301_resource_raw_import.or, tests/next/errors/ts_dev_e0301_npm_import.or +7 |
| E0302 | import of a private file inside another module | tests/errors/e0302_private_import |
| E0303 | import cycle | tests/errors/e0303_cycle |
| E0304 | duplicate definition | tests/errors/e0304_duplicate_function.or, tests/next/errors/e0304_duplicate_type_param.or, tests/next/errors/e0304_interface_duplicate_method.or +6 |
| E0400 | type mismatch | tests/errors/e0400_arg_type.or, tests/next/errors/e0400_int_mix_i32_float.or, tests/next/errors/ts_dev_e0400_union_alias.or +79 |
| E0401 | assignment/mutation of an immutable binding | tests/errors/e0401_assign_const.or, tests/next/errors/e0401_closure_nested_assign_captured.or, tests/next/errors/ts_dev_e0401_param_push.or +19 |
| E0402 | non-exhaustive or invalid match | tests/errors/e0402_int_no_wildcard.or, tests/next/errors/e0402_match_float.or, tests/next/errors/ts_dev_e0402_nonexhaustive.or +6 |
| E0403 | missing return | tests/errors/e0403_if_without_else.or, tests/next/errors/e0403_closure_missing_return.or, tests/next/errors/e0403_generic_missing_return.or +2 |
| E0404 | wrong number of arguments | tests/errors/e0404_method_args.or, tests/next/errors/e0404_conversion_takes_no_arguments.or, tests/next/errors/e0404_wrapping_arity.or +12 |
| E0405 | unknown field, method or variant | tests/errors/e0405_unknown_field.or, tests/next/errors/e0405_genclass_unknown_method.or, tests/next/errors/std_graph_private_field.or +27 |
| E0406 | invalid use of `?` | tests/errors/e0406_mismatched_error_type.or, tests/errors/e0406_question_on_option.or, tests/next/errors/ts_dev_e0406_question_option.or +2 |
| E0407 | cannot infer type | tests/errors/e0407_empty_array.or, tests/next/errors/e0407_generic_function_value_uninferred.or, tests/next/errors/e0407_uninferable_return_only.or +8 |
| E0408 | a construct the language does not support: `extends` on classes, interface fields / default methods / generics / `extends`, a bound on a `type`, class record literals, mutating call in a condition, `@Invariant` on a generic record, an unknown annotation (ADR-0046), a type parameter named like a built-in | tests/errors/e0408_generic_function.or, tests/next/errors/e0408_interface_default_method.or, tests/next/errors/ts_dev_e0408_interface_field.or +19 |
| E0409 | `break`/`continue` outside a loop | tests/errors/e0409_break_outside_loop.or, tests/errors/e0409_continue_outside_loop.or |
| E0410 | invalid operand types for operator | tests/errors/e0410_and_on_ints.or, tests/next/errors/e0410_genclass_invariant_uses_equality_on_param.or, tests/next/errors/ts_dev_e0410_record_eq.or +20 |
| E0411 | missing/duplicate/unknown record literal field | tests/errors/e0411_duplicate_field.or, tests/next/errors/e0411_class_field_assigned_late.or, tests/next/errors/e0411_generic_record_unknown_field.or +4 |
| E0412 | invalid or missing `main` | tests/errors/e0412_main_returns_int.or, tests/errors/e0412_missing_main.or, tests/next/errors/e0412_main_host_and_more.or +1 |
| E0413 | generic instantiation limit exceeded | tests/next/errors/e0413_genclass_polymorphic_recursion.or, tests/next/errors/e0413_polymorphic_recursion.or, tests/next/errors/e0413_polymorphic_recursion_explicit.or +1 |
| E0414 | contract expression is not `bool` (`@Decreases`: not `int`/`usize`) | tests/next/errors/e0414_decreases_not_int.or, tests/next/errors/e0414_loop_invariant_not_bool.or, tests/next/errors/e0414_requires_not_bool.or +1 |
| E0415 | invalid use of `result`-scope features in a contract: `old(..)` outside `@Ensures` or nested, `==>` outside a contract expression, `?` in a contract, a parameter named `result` hiding it | tests/next/errors/e0415_implies_outside_contract.or, tests/next/errors/e0415_old_nested.or, tests/next/errors/e0415_try_in_contract.or +2 |
| E0416 | impure contract expression: I/O or other effect, mutating call, call of a function that is not provably pure (inferred over the call graph; pure closures are allowed, ADR-0031 A4) | tests/next/errors/e0416_builtin_io_in_contract.or, tests/next/errors/e0416_io_in_contract.or, tests/next/errors/time_monotonic_impure_contract.or +7 |
| E0417 | class does not implement an interface method / type does not satisfy a bound (any of the bounds of `T extends A & B`) | tests/next/errors/e0417_bound_not_declared.or, tests/next/errors/e0417_missing_method.or, tests/next/errors/e0417_second_bound_unsatisfied.or +14 |
| E0418 | method implementing an interface method mutates its receiver | tests/next/errors/e0418_genclass_mutating_implementation.or, tests/next/errors/e0418_mutating_implementation.or, tests/next/errors/ts_dev_e0418_mutating_interface_method.or |
| E0430 | integer literal does not fit its type (`const x: i8 = 128`, a `u64`-only literal above 2^63-1 used as another type) | tests/next/errors/e0430_big_literal_as_i32.or, tests/next/errors/e0430_int_literal_negative_i8_underflow.or, tests/next/errors/ts_dev_e0430_literal_range.or +7 |
| E0431 | the 128-bit integer types `i128` / `u128` (and `toI128`, `parseU128`, ...) are not supported yet | tests/next/errors/e0431_i128_type.or, tests/next/errors/e0431_to_i128.or, tests/next/errors/e0431_u128_param.or |
| E0432 | a value that is not `string`, an integer, `float`, `f32` or `bool` interpolated in a template literal | tests/next/errors/e0432_template_array.or, tests/next/errors/e0432_template_option.or, tests/next/errors/ts_dev_e0432_interpolate_record.or +2 |
| E0440 | annotation on a declaration it does not apply to (`@Test` on a method or class, `@Inline` on a class or type, `@Deprecated` on a constant, field, constructor, import or statement; `@Annotation` on anything but a record type ... | tests/next/errors/e0440_annotation_before_loop.or, tests/next/errors/e0440_inline_on_class.or, tests/next/errors/ox_sealed_non_record.or +10 |
| E0441 | wrong annotation arguments: `@Test(..)` / `@Inline(..)` take none, `@Deprecated` needs exactly one string literal; `@Annotation(..)` needs one or more distinct target words (`function method class type interface field const`) ... | tests/next/errors/e0441_annotation_def_unknown_target.or, tests/next/errors/e0441_user_annotation_missing_argument.or, tests/next/errors/e0441_user_annotation_wrong_type.or +9 |
| E0442 | duplicate annotation on one declaration (built-in or user-defined) | tests/next/errors/e0442_duplicate_deprecated.or, tests/next/errors/e0442_duplicate_inline.or, tests/next/errors/e0442_duplicate_user_annotation.or |
| E0443 | invalid `@Test` function: generic, has parameters, or does not return `void` | tests/next/errors/e0443_test_generic.or, tests/next/errors/e0443_test_with_grant_param.or, tests/next/errors/e0443_test_with_parameter.or +1 |
| E0444 | `@Inline` function that is part of a call cycle (recursive) | tests/next/errors/e0444_inline_direct_recursion.or, tests/next/errors/e0444_inline_mutual_recursion.or |
| E0445 | a `@Test` function is called or used as a value (tests are only run by `orin test` and erased from ordinary builds) | tests/next/errors/e0445_call_test_function.or, tests/next/errors/e0445_test_function_as_value.or |
| E0446 | a field of an `@Annotation` record has a type an annotation cannot hold (allowed: `bool`, `int`, `usize`, `float`, `f32`, `string`, a union of payload-free tags, and arrays and `Option`s of those), or the record is generic | tests/next/errors/e0446_annotation_field_record_type.or, tests/next/errors/e0446_annotation_field_union_with_payload.or, tests/next/errors/e0446_annotation_generic.or |
| E0447 | an `@Annotation` definition takes a reserved name (`Test`, `Deprecated`, `Inline`, `Sealed`, `Annotation`, `Processor`, `Requires`, `Ensures`, `Invariant`, `Decreases`, `Rule`), or an identifier starts with `__g` (reserved for generated code) (ADR-0046) | tests/next/errors/e0447_generated_prefix.or, tests/next/errors/e0447_reserved_annotation_name.or |
| E0448 | invalid `@Processor(A)`: not an exported top-level function `(input: Input): Output` with both types from `std:meta`, generic, called `main`, `A` not an `@Annotation` record declared in the same module, a second processor for `A` ... | tests/processors/impure, tests/processors/bad_signature, tools/test_processors.py |
| E0449 | a companion module (`./m.gen`) generates one name more than once and at least one of them is exported (ADR-0046 S4) | tests/next/errors/e0449_duplicate_export, tests/next/errors/e0449_exported_and_private |
| E0450 | a resource handle (grant, `Host`, file) in a position that would store or copy it: variable other than a parameter, field, array, `Option`, `Result`, type argument, function type, closure result, comparison or alias | tests/next/errors/e0450_channel_of_grant.or, tests/next/errors/e0450_resource_closure_result.or, tests/next/errors/ts_dev_e0450_file_in_record.or +26 |
| E0451 | a resource handle used in a statement or branch whose use cannot be tracked (expression statement, conditional argument): a handle must be consumed exactly once on every path | tests/next/errors/e0451_resource_conditional_argument.or, tests/next/errors/e0451_resource_statement.or |
| E0452 | a closure or task body captures a resource handle (also transitively and inside array-method callbacks) | tests/next/errors/e0452_grant_captured.or, tests/next/errors/e0452_resource_captured.or, tests/next/errors/e0452_resource_captured_nested_scope.or +3 |
| E0460 | a generic method on an interface (ADR-0040 allows them on classes) | tests/next/errors/e0460_interface_generic_method.or |
| E0461 | a static method of a generic class uses the class type parameter | tests/next/errors/e0461_genclass_static_uses_param.or |
| E0470 | a capability-requiring built-in or `std:` function called without a grant (or `Host`) as first argument, or with a non-grant | tests/next/errors/e0470_args_without_host.or, tests/next/errors/e0470_main_without_host.or, tests/next/errors/e0470_stdin_without_host.or +4 |
| E0471 | a grant of the wrong family for the operation (e.g. a `ProcessGrant` for a file operation) | tests/next/errors/e0471_host_is_not_a_file_grant.or, tests/next/errors/e0471_wrong_grant_kind.or, tests/next/errors/time_monotonic_wrong_grant.or +1 |
| E0472 | `main` takes a parameter other than `host: Host` of type `Host` from `std:host`; grants never come from the caller | tests/next/errors/e0472_main_fs_param.or |
| E0473 | a module may perform an effect outside its `[effects]` allowance in `orin.toml` (transitive; the notes carry the explanation path) | tools/test_effects.py |
| E0474 | an `[effects]` `allowed` entry names no effect the compiler knows | tools/test_effects.py |
| E0475 | a type does not satisfy `Eq` / `Ord` / `Hash`: a type argument for a `T extends Eq/Ord/Hash` bound (function or class), a `Map` key that is not `Hash` (a record with a `float`, a function value, a class without `hash`, ...) | tests/next/errors/e0475_eq_bound_class_without_equals.or, tests/next/errors/e0475_map_key_array_type_annotation.or, tests/next/errors/e0475_unbounded_param_to_bounded_function.or +10 |
| E0476 | an explicit `equals` / `compare` / `hash` of a class cannot be used: wrong signature (`equals(other: C): bool`, `compare(other: C): int`, `hash(): usize`), static, private or mutating ... | tests/next/errors/e0476_equals_mutates_receiver.or, tests/next/errors/e0476_equals_wrong_signature.or, tests/next/errors/e0476_implements_hash_with_explicit_equals.or +2 |
| E0477 | two bounds of one type parameter (`T extends A & B`) declare a method of the same name with different signatures; a call on a `T` could not tell which is meant | tests/next/errors/e0477_conflicting_bound_members.or, tests/next/errors/e0477_conflicting_bound_params.or |
| E0480 | internal task primitive given a resource handle; not reachable from user code | none |
| E0481 | a task body captures the `Scope` it is spawned in | tests/next/errors/e0481_task_captures_scope.or |
| E0482 | `channel(0)`: capacity must be at least 1 | tests/next/errors/e0482_channel_zero.or |
| E0483 | a task body captures a resource handle; delegate with `spawnFs` and friends | tests/next/errors/e0483_task_captures_grant.or |
| E0484 | a function given to a `parallel()` operation is impure or not an arrow/named function | tests/next/errors/e0484_parallel_function_value.or, tests/next/errors/e0484_parallel_impure.or, tests/next/errors/e0484_parallel_impure_callee.or |
| E0485 | the reducer of a parallel `reduce` is not a built-in associative operator | tests/next/errors/e0485_parallel_reducer.or, tests/next/errors/e0485_parallel_reducer_function.or |
| E0486 | the input element type of `parallel()` is not a scalar or a flat record of scalars | tests/next/errors/e0486_parallel_element_type.or, tests/next/errors/e0486_parallel_nested_record.or |
| E0490 | markup without `import ox from "M"`, or the provider `ox()` is not a single `Markup`/`Components` literal | tests/next/errors/ox_no_provider.or, tests/next/errors/ox_provider_not_literal |
| E0491 | component or member tag error: unknown, not a function, unknown/missing attribute, bad slot, spread field without parameter | tests/next/errors/ox_attr_and_slot.or, tests/next/errors/ox_member_unknown.or, tests/next/errors/ox_unknown_attr.or +11 |
| E0492 | a value of a type that cannot be used there in markup (slot child type, `bool` without presence attributes, spread of a non-record) | tests/next/errors/ox_bool_child.or, tests/next/errors/ox_slot_child_type, tests/next/errors/ox_spread_presence +5 |
| E0493 | markup attribute or content that must be static (event handler attributes, `<script>`/`<style>` content, `convert: None` rules) | tests/next/errors/ox_event_handler.or, tests/next/errors/ox_script_dynamic.or, tests/next/errors/ox_static_only_rule +2 |
| E0494 | malformed element: children of a void element, invalid tag or attribute name | tests/next/errors/ox_bad_tag.or, tests/next/errors/ox_void_children.or |
| E0495 | record literal or field assignment of a `@Sealed` type outside its module | tests/next/errors/jsondecode_sealed_assign.or, tests/next/errors/jsonnumber_sealed_literal.or, tests/next/errors/ox_sealed_user +4 |
| E0500 | `orin.toml` syntax error (beyond Orin-B; self-hosted compiler only, spec 04) | tests/next/errors/e0500_manifest_syntax, tests/next/errors/e0500_manifest_unterminated_array |
| E0501 | import violates a module's `allowed_dependencies` rule in `orin.toml` (beyond Orin-B) | tests/next/errors/e0501_disallowed_dependency, tests/next/errors/e0501_generated_import_disallowed |
| E0502 | `orin.toml` names a module that does not exist (no `module.or`), in `[modules.x]` or `[effects.x]` (beyond Orin-B) | tests/next/errors/e0502_unknown_allowed_dependency, tests/next/errors/e0502_unknown_module |
| E0503 | invalid `orin.toml` (unknown key/table, wrong value type, missing `[package] name`, an `[architecture]` flag set to `false`, a malformed `[effects]` table) (beyond Orin-B) | tests/next/errors/e0503_manifest_architecture_off, tests/next/errors/e0503_manifest_unknown_key |
| E0504 | invalid workspace manifest (`orin-workspace.toml`): syntax, unknown key or table, wrong value type, missing or empty `members`, bad tool entry | tests/workspace/fail/empty_members, tests/workspace/fail/syntax, tests/workspace/fail/unknown_key |
| E0505 | invalid workspace member or tool path (absolute, `..`, backslash, trailing slash, misplaced wildcard, member without `orin.toml`) | tests/workspace/fail/absolute_path, tests/workspace/fail/dotdot_path, tests/workspace/fail/member_without_manifest |
| E0506 | duplicate package name or duplicate member path in a workspace | tests/workspace/fail/duplicate_name, tests/workspace/fail/duplicate_path |
| E0507 | ambiguous workspace layout: nested workspace or member, `exclude` matching nothing, default member that is not a member, tool inside a member | tests/workspace/fail/default_not_member, tests/workspace/fail/nested_workspace, tests/workspace/fail/exclude_matches_nothing |
| E0508 | bad workspace dependency: path dependency to a non-member, or a dependency cycle | tests/workspace/fail/dependency_cycle, tests/workspace/fail/path_dep_non_member |
| E0509 | `orin.lock` is stale or unreadable (changed version, missing or unknown member) | tests/workspace/fail/stale_lockfile |
| E0520 | a processor run failed or its output is unusable. Failed run (ADR-0046 S5): the helper trapped (exit 101), timed out (`--processor-timeout`), exited with a status, wrote more than 16 MiB, could not be built (C compiler or loader error) ... | tests/next/errors/e0520_anonymous_union, tests/next/errors/e0520_not_json, tests/next/errors/e0520_wrong_version +9 |
| E0521 | cyclic companion: `./a.gen` imported while `a` is loading, or a module that runs a processor depends on a companion (ADR-0046 S4) | tests/next/errors/e0521_direct_cycle, tests/next/errors/e0521_transitive |
| E0522 | a processor reported an error diagnostic (ADR-0046 S4) | tests/next/errors/e0522_processor_error |
| E0523 | `orin compile --target=wasm64-orbit`: `main` may perform an effect the Orbit target does not provide (`Fs.*`, `Process.Spawn`, `Net.*`, `Stream.*`; `Task.*` and `Channel.*` are available since ADR-0055 rev. tasks); one error per effect, located at its evidence (analysis/orbit.or) | tools/test_effects.py |
| W0440 | **warning** (never fails a build): use of a `@Deprecated` symbol; printed as `warning[W0440]`, JSON `"severity":"warning"`, LSP severity 2 with the Deprecated tag | tests/next/run/annotations_deprecated.or, tools/test_annotations.py |
| W0450 | **warning**: `@Invariant` of a class or record that mentions no `this` (constrains no state) | tests/next/run/contract_quality_invariant.or |
| W0451 | **warning**: `@Ensures` that mentions neither `result` nor (non-static method) `this`; parameters are immutable, so it cannot fail | tests/next/run/contract_quality_ensures.or |
| W0452 | **warning**: syntactically trivially true contract (`true`, `x == x`, `x <= x`, `x >= x`, `a.length >= 0`, `s.length >= 0`, `m.size >= 0`, literal comparisons) | tests/next/run/contract_quality_invariant.or, tests/next/run/contract_quality_trivial.or |
| W0460 | **warning** (`orin verify --contracts`, solver-proved): clause valid without premises | tests/contracts/quality_vc.or, tools/test_verify_contracts.py |
| W0461 | **warning** (`orin verify --contracts`): the `@Requires` of a function are unsatisfiable | tests/contracts/quality_vc.or, tools/test_verify_contracts.py |
| W0462 | **warning** (`orin verify --contracts`): `@Ensures` implied by the `@Requires` alone | tests/contracts/quality_vc.or, tools/test_verify_contracts.py |
| W0470 | **warning**, strict mode only: class with state and no `@Invariant` | tests/next/run/contract_quality_strict.or |
| W0471 | **warning**, strict mode only: public method that mutates `this` and has no `@Ensures` | tests/next/run/contract_quality_strict.or |
| W0480 | **warning**: a parallel float `reduce` may differ from the sequential fold in the last bits | tests/next/run/par_float_reduce.or |
| W0481 | **warning**: a parallel integer `reduce` with signed `+` or with `*` can overflow in a chunk where the sequential fold does not | tests/next/run/par_ops.or |
| W0490 | **warning**: processors not run: `orin check` has no C compiler and no cached output for a processor; the companion module stays empty (ADR-0046 S5) | tools/test_processors.py |
| W0491 | **warning**: a processor reported a warning (ADR-0046 S4) | tools/test_processors.py |
| W0492 | **warning**: the processor of an annotation from a dependency was not run because `[annotations] processors` of orin.toml does not list it (ADR-0046 S5) | tests/processors/dep_untrusted, tools/test_processors.py |

93 codes: 79 errors, 14 warnings.

## Gaps: rules without a test

Codes with no test in `tests/errors`, `tests/next/errors`, `tests/next/run` (`// warns:`) or the other suites cited above:

- E0480: internal task primitive given a resource handle; not reachable from user code

Codes pinned only by a tool script (not by the conformance runner): E0473, E0474, E0523 (`tools/test_effects.py`), E0448 and W0490-W0492
(`tools/test_processors.py`), W0440 (text and JSON: `tools/test_annotations.py`), W0460-W0462 (`tests/contracts/quality_vc.or`,
`tools/test_verify_contracts.py`), E0504-E0509 (`tests/workspace/fail`, run by `tools/test_packages.sh`).
