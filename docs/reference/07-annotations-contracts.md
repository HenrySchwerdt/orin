# 7. Annotations and contracts

Normative. Sources: ADR-0024 (built-in annotations), ADR-0046 (user-defined annotations and processors),
ADR-0012 / ADR-0028 / ADR-0029 / ADR-0031 (contracts), `docs/contracts.md`, `docs/annotation-processors.md`,
`compiler/syntax/rules.or` (`annotationAllowed`, `clauseAllowed`). Conventions: see [README](README.md).

An *annotation* is `@Name` or `@Name(args)` before a declaration. There are three disjoint families:

1. **contract clauses** `@Requires @Ensures @Invariant @Decreases @Rule` (a closed set with their own grammar and AST node);
2. **built-in annotations** `@Test @Deprecated @Inline @Sealed @Annotation @Processor`;
3. **user annotations**, declared with `@Annotation` (ADR-0046).

The names of families 1 and 2 are reserved (rule ANN-9).

## 7.1 Placement

**ANN-1. Placement table.** A clause or annotation is accepted only before the constructs below; elsewhere it is E0200
(clauses) or E0440 (annotations).

| Annotation | Before | Violation |
|---|---|---|
| `@Requires` | function, method, constructor | E0200 |
| `@Ensures` | function, method | E0200 |
| `@Invariant` | class, record `type`, `while` / `for` loop | E0200 |
| `@Decreases` | function, method, loop | E0200 |
| `@Rule("ID")` | function, method, constructor, class, any `type` | E0200 |
| `@Test` | top-level `function` | E0440 |
| `@Inline` | function, method | E0440 |
| `@Deprecated("msg")` | function, method, class, type, interface | E0440 (on `const` and on a field) |
| `@Sealed` | record `type` | E0440 |
| `@Annotation(targets)` | record `type` | E0440 (on a union) |
| `@Processor(A)` | exported top-level function | E0448 |
| user `@A` | one of the targets the definition of `A` lists | E0440 |

Tests: tests/next/errors/e0200_contract_before_statement.or, tests/next/errors/e0200_contract_ensures_on_class.or,
tests/next/errors/e0200_contract_requires_on_loop.or, tests/next/errors/e0440_annotation_before_loop.or,
tests/next/errors/e0440_annotation_on_constructor.or, tests/next/errors/e0440_annotation_on_import.or,
tests/next/errors/e0440_annotation_def_on_union.or, tests/next/errors/e0440_deprecated_on_const.or,
tests/next/errors/e0440_deprecated_on_field.or, tests/next/errors/e0440_inline_on_class.or,
tests/next/errors/e0440_inline_on_type.or, tests/next/errors/e0440_test_on_class.or,
tests/next/errors/e0440_test_on_method.or, tests/next/errors/e0440_user_annotation_on_constructor.or,
tests/next/errors/e0440_user_annotation_wrong_target.or.

**ANN-2. Mixing and order.** Clauses and annotations may be mixed in any order before one declaration; the formatter
prints annotations first, then clauses, one per line. Loop clauses are statements directly before the loop.
Tests: tests/next/run/contracts_erased.or, tests/next/run/contracts_static_and_generic.or.

**ANN-3. Unknown annotation.** An `@Name` that is none of the reserved names and has no `@Annotation` declaration in scope is
E0408; so is a name that resolves to a record that is not an `@Annotation`.
Tests: tests/next/errors/e0408_annotation_unsupported.or, tests/next/errors/e0408_unknown_annotation_on_class.or,
tests/next/errors/e0408_annotation_not_an_annotation_record.or.

**ANN-4. Duplicates.** The same annotation twice on one declaration is E0442.
Tests: tests/next/errors/e0442_duplicate_deprecated.or, tests/next/errors/e0442_duplicate_inline.or,
tests/next/errors/e0442_duplicate_user_annotation.or.

## 7.2 Built-in annotations

**ANN-5. `@Test`.** A `@Test` function is top-level, not generic, returns `void`, and takes no parameter or exactly one
`host: Host`; otherwise E0443. A `@Test` function is type-checked and erased from ordinary builds (output byte-identical
with and without it); it cannot be called or used as a value (E0445). `orin test` runs it; failure is a trap.
Tests: tests/next/run/annotations_test_erased.or, tests/next/errors/e0443_test_generic.or,
tests/next/errors/e0443_test_returns_value.or, tests/next/errors/e0443_test_with_parameter.or,
tests/next/errors/e0443_test_with_grant_param.or, tests/next/errors/e0445_call_test_function.or,
tests/next/errors/e0445_test_function_as_value.or, tests/next/errors/e0441_test_with_argument.or,
tools/test_annotations.py, tools/test_annotation_erasure.py.

**ANN-6. `@Inline`.** Takes no argument (E0441); a hint with no semantic effect (C: `static inline`, LLVM: `alwaysinline`).
A directly or mutually recursive `@Inline` function is E0444.
Tests: tests/next/run/annotations_inline.or, tests/next/errors/e0441_inline_with_argument.or,
tests/next/errors/e0444_inline_direct_recursion.or, tests/next/errors/e0444_inline_mutual_recursion.or.

**ANN-7. `@Deprecated("message")`.** Exactly one string-literal argument (E0441 for none, two or a non-string). A use of
the declaration from another declaration warns W0440 with the message; the program otherwise behaves normally.
Tests: tests/next/run/annotations_deprecated.or, tests/next/errors/e0441_deprecated_non_string.or,
tests/next/errors/e0441_deprecated_two_arguments.or, tests/next/errors/e0441_deprecated_without_message.or,
tools/test_annotations.py (the W0440 text and JSON form).

**ANN-8. `@Sealed`.** On a record type: outside its defining module the record cannot be built with a literal and its
fields cannot be assigned (E0495); the module's functions are the only way. See chapter 9.
Tests: tests/next/errors/jsondecode_sealed_literal.or, tests/next/errors/jsondecode_sealed_assign.or.

**ANN-9. Reserved names.** `Test Deprecated Inline Sealed Annotation Processor Requires Ensures Invariant Decreases Rule`
cannot be the name of an `@Annotation` record (E0447), and identifiers starting with `__g` are reserved for generated
code (E0447).
Tests: tests/next/errors/e0447_reserved_annotation_name.or, tests/next/errors/e0447_generated_prefix.or.

## 7.3 User-defined annotations (ADR-0046)

**ANN-10. Definition.** `@Annotation(function, class, ...)` before a non-generic record type `A` declares an annotation
named `A`. Targets are a comma-separated subset of `function method class type interface field const`; an unknown or
duplicate target is E0441. Fields may be `bool`, `int`, `usize`, `float`, `f32`, `string`, a union of payload-free tags, and
arrays and `Option`s of those; any other field type, and a generic definition, is E0446.
Tests: tests/next/run/user_annotations, tests/next/errors/e0441_annotation_def_unknown_target.or,
tests/next/errors/e0446_annotation_field_record_type.or, tests/next/errors/e0446_annotation_field_union_with_payload.or,
tests/next/errors/e0446_annotation_generic.or.

**ANN-11. Use.** `@A(v1, ...)` supplies the fields positionally; each argument is a constant expression (literal, tag, array
or `Option` of constants, or a top-level `const` of those) of the field type. Missing, extra, ill-typed or non-constant
arguments, and an unknown tag, are E0441. A use on a target the definition does not list is E0440.
Tests: tests/next/errors/e0441_user_annotation_missing_argument.or, tests/next/errors/e0441_user_annotation_too_many_arguments.or,
tests/next/errors/e0441_user_annotation_wrong_type.or, tests/next/errors/e0441_user_annotation_not_constant.or,
tests/next/errors/e0441_user_annotation_nonconstant_const.or, tests/next/errors/e0441_user_annotation_unknown_tag.or,
tests/next/errors/e0440_user_annotation_wrong_target.or.

**ANN-12. Processors.** `@Processor(A)` marks an exported, non-generic top-level function `(input: Input): Output` (types
from `std:meta`, not named `main`) in the module that declares `A`; one processor per annotation. The function and everything
it calls must be pure (the contract purity rule, 7.4); otherwise, and for any wrong placement or signature, E0448.
Tests: tests/processors/impure, tests/processors/bad_signature, tools/test_processors.py.

**ANN-13. Companion modules.** A processor runs only for modules that import its annotation and use it, and only when some
module imports the companion `./m.gen`. The generated declarations are checked like hand-written code. A companion cannot
import another companion (E0520); two generated declarations of one name where one is exported are E0449; a module that uses
a processor annotation and imports a generated module in a cycle is E0521; a diagnostic of severity error reported by the processor itself is E0522
(severity warning: W0491); a processor that traps, exceeds 10 s, 16 MiB of output or 10,000 declarations, or whose output
is malformed, is E0520.
Tests: tests/next/run/processor_describe, tests/next/run/companion_basic, tests/next/run/companion_import_order,
tests/next/run/companion_package, tests/next/run/companion_runs, tests/next/errors/e0449_duplicate_export,
tests/next/errors/e0449_exported_and_private, tests/next/errors/e0520_import_of_companion,
tests/next/errors/e0520_not_json, tests/next/errors/e0520_wrong_format, tests/next/errors/e0520_wrong_version,
tests/next/errors/e0520_unknown_decl_kind, tests/next/errors/e0520_bad_identifier,
tests/next/errors/e0520_keyword_name, tests/next/errors/e0520_missing_key, tests/next/errors/e0520_bit_operator,
tests/next/errors/e0520_anonymous_union, tests/next/errors/e0520_unknown_diag_ref,
tests/next/errors/e0520_unloaded_import, tests/next/errors/e0521_direct_cycle, tests/next/errors/e0521_transitive,
tests/next/errors/e0522_processor_error, tests/processors/trap, tests/processors/timeout, tests/processors/too_big,
tests/processors/too_many, tests/processors/json_bad.

**ANN-14. Processor trust.** A processor that comes from a dependency runs only when the dependency or its module is listed in
`[annotations] processors` of the root `orin.toml`; otherwise W0492 and the companion stays empty. Without a C compiler the
processors are not run: W0490 under `check`, E0520 under `compile`. W0491 is a warning reported by a processor.
Tests: tests/processors/dep_trusted, tests/processors/dep_trusted_module, tests/processors/dep_untrusted,
tests/processors/deplib, tools/test_processors.py.

## 7.4 Contract clauses (ADR-0012)

**CON-1. Typing.** `@Requires`, `@Ensures` and `@Invariant` expressions are `bool`; `@Decreases` is an integer (`int` or
`usize`). Otherwise E0414. Clauses are type-checked on every build, in the scope of the declaration (parameters, `this`).
Tests: tests/next/errors/e0414_requires_not_bool.or, tests/next/errors/e0414_ensures_string.or,
tests/next/errors/e0414_loop_invariant_not_bool.or, tests/next/errors/e0414_decreases_not_int.or,
tests/next/errors/e0300_contract_unknown_name.or.

**CON-2. `result` and `old`.** `result` is in scope only in `@Ensures` (and not for a `void` function); elsewhere it is E0300.
`old(e)` is only allowed in `@Ensures` and not nested (E0415). A parameter named `result` in a function with `@Ensures`
is E0415. `==>` outside a contract and `?` inside one are E0415.
Tests: tests/next/errors/e0415_old_in_requires.or, tests/next/errors/e0415_old_nested.or,
tests/next/errors/e0415_result_param_clash.or, tests/next/errors/e0415_implies_outside_contract.or,
tests/next/errors/e0415_try_in_contract.or, tests/next/run/contracts_result_param.or, tests/next/run/contracts_old_in_function.or,
tests/next/run/contracts_method_old_violation.or.

**CON-3. Purity.** A contract expression may call only pure functions and pure closures. It must not perform I/O (including
clock reads), mutate (`push`, `pop`, a mutating method), or call a function value of unknown origin; the violation is E0416
and its message names the chain of calls and the operation. A function that calls its function-typed parameter is pure
relative to its argument; `every`/`some`/`map`/`filter` with a pure lambda are allowed.
Tests: tests/next/errors/e0416_io_in_contract.or, tests/next/errors/e0416_builtin_io_in_contract.or,
tests/next/errors/e0416_io_transitive.or, tests/next/errors/e0416_io_transitive_location.or,
tests/next/errors/e0416_clock_in_contract.or, tests/next/errors/e0416_mutating_method_in_contract.or,
tests/next/errors/e0416_closure_in_contract.or, tests/next/errors/e0416_closure_io_in_every.or,
tests/next/errors/e0416_function_value_param.or, tests/next/errors/time_monotonic_impure_contract.or,
tests/next/run/contracts_pure_closures.or, tests/next/run/contracts_quantifiers_seq.or.

**CON-4. Erasure.** Without `--check-contracts` clauses generate no code and a violating program behaves as if they were
absent (generated C and LLVM IR byte-identical with and without the clause lines).
Tests: tests/next/run/contracts_erased.or, tests/next/run/contracts_erased_violation_ignored.or,
tests/next/run/contracts_closure_erased.or, tests/next/run/genclass_contracts_erased.or, tools/test_contract_erasure.py.

**CON-5. Run-time checking.** With `--check-contracts` a function or method checks `@Requires` on entry and `@Ensures` on
every return (including early `?` returns); a constructor checks its `@Requires` after the leading `this.f = e;`
initialisations; class `@Invariant`s are checked at the end of constructors and after every non-private, non-static method.
A violation prints the report of CON-7 and exits with status 101. Calls made from inside a clause are not checked.
Tests: tests/next/run/contracts_check_ok.or, tests/next/run/contracts_requires_violation.or,
tests/next/run/contracts_ensures_violation.or, tests/next/run/contracts_ensures_implication_violation.or,
tests/next/run/contracts_ctor_requires_violation.or, tests/next/run/contracts_ctor_invariant_violation.or,
tests/next/run/contracts_invariant_violation.or, tests/next/run/contracts_self_call_terminates.or,
tests/next/run/contracts_iface.or, tests/next/run/int_contracts_runtime.or, tests/next/run/eqord_contracts.or,
tests/next/run/genclass_contracts_ok.or, tests/next/run/genclass_contracts_requires_violation.or,
tests/next/run/genclass_contracts_ensures_violation.or, tests/next/run/genclass_contracts_invariant_violation.or.

**CON-6. Record invariants.** An `@Invariant` on a record type is checked under `--check-contracts` at every record literal
of that type (including spreads), after every write through a place that passes through such a record (field assignment,
compound assignment, nested places, array elements, `push`/`pop` on an array field), and at every `return` of a function
whose result type is the record (unless the returned expression is a literal).
Tests: tests/next/run/contracts_record_ok.or, tests/next/run/contracts_record_literal_violation.or,
tests/next/run/contracts_record_assign_violation.or, tests/next/run/contracts_record_push_violation.or,
tests/next/run/contracts_record_return_violation.or.

**CON-7. Violation report.** On stderr, first line `trap: contract violated: @Kind(expr) at file:line`, then `function:`,
`values:` (the maximal non-literal operands), `blame:` (the caller for `@Requires`, the callee for `@Ensures`/`@Invariant`)
and `action:` (`FIX_CODE` or `NEEDS_DECISION`) lines.
Tests: tests/next/run/contracts_report_requires.or, tests/next/run/contracts_report_ensures.or,
tests/next/run/contracts_report_invariant.or, tests/next/run/contracts_report_values.or.

**CON-8. `@Rule`.** `@Rule("ID")` attaches an identifier to a declaration; it has no run-time effect and is carried to the
results of `orin verify --contracts`.
Tests: tests/next/run/contracts_erased.or, tests/contracts/verify_basic.or.

**CON-9. Quality warnings (syntactic).** Always on: W0450 an `@Invariant` without `this`; W0451 an `@Ensures` that mentions
neither `result` nor (in a non-static method) `this`; W0452 a trivially true contract expression. Never an error. W0470 and
W0471 appear only under `--strict-contracts` or `[contracts] strict = true` (class with state and no `@Invariant`; public
mutating method without `@Ensures`).
Tests: tests/next/run/contract_quality_clean.or, tests/next/run/contract_quality_invariant.or,
tests/next/run/contract_quality_ensures.or, tests/next/run/contract_quality_trivial.or,
tests/next/run/contract_quality_nonstrict.or, tests/next/run/contract_quality_strict.or.

**CON-10. Static verification.** `orin verify --contracts entry.or` discharges `ensures`, `call-precondition`, `invariant`,
`bounds`, `unwrap` and `loop-invariant` obligations with z3 and reports VERIFIED, REFUTED (real counterexample) or UNKNOWN
(never upgraded); `@Decreases` is always UNKNOWN. Exit status is 1 if a clause is REFUTED. Findings W0460 (tautology),
W0461 (unsatisfiable `@Requires`), W0462 (`@Ensures` follows from `@Requires`) are reported as warnings. The expected status
per function is the `// expect:` header of each input.
Tests: tests/contracts/verify_basic.or, tests/contracts/verify_arrays.or, tests/contracts/verify_classes.or,
tests/contracts/verify_data.or, tests/contracts/verify_generics.or, tests/contracts/verify_int_widths.or,
tests/contracts/verify_loops.or, tests/contracts/verify_quantifiers.or, tests/contracts/verify_selfref.or,
tests/contracts/verify_soundness.or, tests/contracts/quality_vc.or, tools/test_verify_contracts.py.

## Gaps: rules without a test

- Placement of `@Invariant`/`@Decreases`/`@Rule` on every listed target is not exercised one by one: no test for `@Rule` on a
  method, constructor or `type` that must be accepted, and none for E0200 on `@Requires` before a class.
- `@Deprecated` on class, type and interface (accepted) has no dedicated test; only the function case runs.
- `@Sealed` on a non-record type and E0440 for `@Sealed` elsewhere are untested.
- W0440: the exact text and the use sites that warn are checked by `tools/test_annotations.py`, not by the conformance suites.
- W0491 (processor-reported warning), W0492 and W0490 are covered only by `tools/test_processors.py`, not by `tests/next`.
- E0448 individual sub-cases (generic processor, processor named `main`, two processors for one annotation, processor calling a
  companion) have one shared test directory (tests/processors/bad_signature) and no per-case conformance test.
- Contract placement on interface methods and the exact scope of `this` in a constructor `@Requires` are only implied by
  tests/next/run/contracts_iface.or and tests/next/run/contracts_ctor_requires_violation.or.
- Run-time checking of loop `@Invariant` and of `@Decreases` does not exist (parsed and type-checked only); no test pins this.
- A field assignment whose place contains an index with a call (`xs[next()].f = v`) is not checked for record invariants; no test.
- The JSON form of the verify report and the `--strict` exit status are only covered by `tools/test_verify_contracts.py`.
