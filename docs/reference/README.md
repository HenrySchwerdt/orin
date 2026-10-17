# Orin language reference

A normative, concise reference of the language **as implemented on `main`** (self-hosted compiler in `compiler/`, bootstrap
binary `build/bootstrap/orin2`). It is written from the implementation and checked against it; where an ADR or another guide
disagrees with the implementation, this reference follows the implementation and the difference is listed under
[Known discrepancies](#known-discrepancies). Status: draft (roadmap 3.8, `docs/roadmaps/orin-1.0.md`). The design RFC in
[`spec/`](../../spec/spec.md) is not normative for the implemented language.

## Chapters

1. [Lexical structure](01-lexical.md): characters, comments, identifiers, keywords, literals, punctuation.
2. [Grammar](02-grammar.md): EBNF, operator precedence and associativity (`OpTable`), the `?` disambiguation.
3. [Types](03-types.md): scalars, strings, arrays, records, unions, `Option`/`Result`, `Map`, classes, interfaces, generics, `Eq`/`Ord`/`Hash`.
4. [Expressions and statements](04-expressions-statements.md): evaluation order, patterns and `match`, control flow, traps.
5. [Ownership, resources, capabilities and effects](05-ownership-resources-capabilities.md): value semantics, resource handles, grants, `Host`, effect policy.
6. [Modules, packages and preludes](06-modules-packages.md): imports/exports, `orin.toml`, workspaces, preludes, `std:` modules.
7. [Annotations and contracts](07-annotations-contracts.md): built-in and user annotations, processors, `@Requires`/`@Ensures`/`@Invariant`/`@Decreases`/`@Rule`, `--check-contracts`, `orin verify`.
8. [Concurrency surface](08-concurrency.md): `std:task` scopes, channels, timed waits, `select`, `sleep`, `parallel()`.
9. [OX markup](09-ox.md): syntax, providers, components, slots, safety.
10. [Diagnostics index](10-diagnostics.md): every `E0xxx` / `W0xxx` code the compiler emits, with its conformance tests.

## Conventions

- **Rules** carry an id (`LEX-1`, `GRM-3`, `TYP-12`, `EXP-5`, `OWN-`/`RES-`/`CAP-`/`EFF-`, `MOD-`, `ANN-`/`CON-`, `TSK-`, `OX-`) in
  bold at the start of a paragraph. A rule states what the compiler accepts, rejects (with the code) or guarantees.
- **Traceability.** Every rule is followed by a `Tests:` line. A test path is repo-relative and names a conformance test in one of:
  `tests/run` and `tests/errors` (Orin-B suite; error tests have a `// error: E0xxx` header), `tests/next/run` and
  `tests/next/errors` (beyond Orin-B; headers `// flags:`, `// stderr:`, `// warns:`, `// exit:`). Many tests are directories
  with a `main.or`. Other suites that are cited are named for what they are: `tests/concurrency` (run by
  `tools/test_concurrency.sh`), `tests/contracts` (inputs of `tools/test_verify_contracts.py`), `tests/processors`
  (`tools/test_processors.py`), `tests/workspace` (`tools/test_packages.sh`), `tests/std` (`orin test`), `tests/next/deny`
  (`tools/test_capabilities.sh`), `compiler/tests` (the compiler's own unit tests) and the `test_` scripts in `tools/`.
  `tests/parse_edge` is a differential corpus whose outcomes are not asserted by name; it is cited only where its behaviour was
  verified against `orin2` when the chapter was written.
- **Gaps.** A rule that has no test is not listed with an invented one; it goes in the chapter's section
  **Gaps: rules without a test**, together with behaviour that is stated in a guide but pinned by nothing.
- **Pending features.** Generic methods and `void` as a type argument (ADR-0040) are marked *landing in PR (pending)*; the
  reference describes the behaviour on `main` (E0460, `Do` flavours of generic functions) until that PR merges.
- **Checking.** `python3 tools/check_reference.py` verifies that every test path cited in `docs/reference/*.md` exists. It does
  not run the tests; the suites do that (`tools/run_tests.py`, `tools/ci_local.sh`).

## Known discrepancies

Places where a guide, ADR or spec text disagrees with what the compiler does. The reference follows the compiler.

1. **Equality and ordering.** `docs/bootstrap-subset.md` section 5 allows `==` only on `int`, `usize`, `bool`, `string` and `<`
   only on `int`/`usize`. The compiler (ADR-0034) derives `Eq`/`Ord`/`Hash` structurally for all fixed-width integers, records,
   unions, `Option`, `Result`, arrays and classes with the methods; types with a float component are excluded (E0475, and `==`
   on them is E0410). See chapter 3.
2. **`Map` keys.** ADR-0018 limits keys to `int`, `usize`, `bool`, `string`; the compiler accepts any `Hash` key (E0475 otherwise).
3. **Lexical list of the bootstrap subset** allows only `0x` hex and omits `&`, `...`, `==>` and `@` from the punctuation; the lexer
   also accepts `0X` and leading zeros in decimals. Chapter 1 lists the real set.
4. **Annotations.** `docs/contracts.md` says any other `@Name` is E0408 and that user annotations are post-1.0. User-defined
   annotations, `@Sealed` and `@Processor` are implemented (ADR-0046, ADR-0044); E0408 remains for an unknown name.
5. **ADR-0047 status.** The ADR is marked proposed, but its phases 1 to 3 (workspace manifest, CLI, library and runtime moves) are
   in the tree. Chapter 6 describes what is implemented.
6. **Privacy.** `private_by_default` does not stop a private type from appearing in an exported signature: an importer can read
   its fields through the exported function's result.
7. **Orin-B wording in messages.** The E0402 message no longer says "in Orin-B"; the diagnostic table in
   `docs/bootstrap-subset.md` still describes E0408 as "feature not supported in Orin-B".
8. **`tests/parse_edge`** names (`err0100_bad_float`, `err0200_fn_arrow_expr`) are historical; the files no longer produce
   those codes, and the corpus asserts nothing by name.
9. **Generic methods.** `docs/concurrency.md` and `docs/std.md` explain several API shapes (free functions, `Do` flavours) by
   E0460 (no generic methods). ADR-0040 changes this; pending, see above.
10. **Entry point.** `docs/bootstrap-subset.md` line 51 says the entry file must contain `function main(): void`; the compiler also
    accepts `main(host: Host): void`. A grant-typed parameter is E0472, any other parameter or result type is E0412.

## Maintenance

Change the language, change its chapter in the same PR: add or update the rule, cite the test that pins it, and run
`python3 tools/check_reference.py`. A diagnostic added to `compiler/` needs a row in chapter 10.
