# 6. Modules, imports, packages and preludes

Normative for `compiler/loader/` (resolution, module graph, preludes), `compiler/check/module.or`, `compiler/package/` (manifest,
workspace) and the checker's name resolution. Sources: `docs/bootstrap-subset.md` section 7, `docs/workspace.md`, `docs/architecture.md`
("Preludes"), ADR-0007 (generic imports), ADR-0047 (layout) and what `orin2` accepts. Rule ids `MOD-n`.

## 6.1 Files and modules

**MOD-1.** A **file** `x.or` is a unit; a **module** is a directory that contains `module.or`, whose file is the module's public face. Every
top-level declaration is private to its file unless marked `export`. Declaration order inside a file is irrelevant.
- Tests: `tests/run/modules_basic`, `tests/run/modules_diamond`, `tests/next/run/package_modules`, `tests/run/mutual_recursion.or`.

**MOD-2.** `import { a, B } from "path";` brings the named **exported** declarations of the target into the file's scope. The path is a
string literal and is one of: a relative path `./x`, `../x` (resolved against the importing file's directory to `x.or`, else `x/module.or`);
a standard module `std:name`; or a dependency name (MOD-14). There is no wildcard that brings all names into scope and no default
import. Importing a name that the target does not export (or that is private) is E0300.
- Tests: `tests/run/modules_basic`, `tests/errors/e0300_not_exported`, `tests/parse_edge/ok_import_alias.or`, `tests/parse_edge/ok_import_namespace.or`,
  `tests/next/errors/e0300_import_generic_not_exported`, `tests/next/errors/e0300_source_private_not_exported`.

**MOD-2a.** **Aliases** (ADR-0048 addendum). `import { exists as fileExists, empty as emptyBytes } from "path";` binds the export under the new name, for
types and values alike (the variants of an imported union keep their own names). `export { a as b } from "path";` re-exports under another name. The
alias is the only name the file gets; two bindings of one name stay E0304 (MOD-6), and an export the target lacks is E0300.
- Tests: `tests/next/run/import_alias.or`, `tests/next/run/import_alias_reexport`, `tests/next/errors/e0304_duplicate_import_alias.or`, `tests/next/errors/e0304_import_alias_collides_with_declaration.or`,
  `tests/next/errors/e0300_import_alias_unknown_name.or`.

**MOD-2b.** **Namespace imports** (ADR-0048 addendum). `import * as m from "path";` binds the name `m`, a compile-time namespace of the target's exports:
`m.f(..)` calls a function (`m.f<T>(..)` a generic one), `m.CONST` reads a constant, `m.T` names a type (`m.Box<int>`, `m.T[]`), and `m.Ctor(..)`, `m.Rec { .. }`,
`new m.C(..)` and the patterns `m.Variant(x)` use constructors; the same entity `import { x }` would bind, so the generated code is identical. `m` is not a
value: passing, storing, comparing, printing or calling it is E0400. A member the target does not export is E0300. Because `m.x` would otherwise mean
something else, a local, parameter, closure parameter, function, type or import named `m` in a file with `import * as m` is E0304 (rename one of them).
`import * from ".."` without `as` is E0200. Re-exports have no namespace form.
- Tests: `tests/next/run/namespace_import_std.or`, `tests/next/run/namespace_import_local`, `tests/next/errors/e0300_namespace_unknown_member.or`,
  `tests/next/errors/e0300_namespace_unknown_type.or`, `tests/next/errors/e0304_namespace_shadowed_by_local.or`, `tests/next/errors/e0304_namespace_shadowed_by_param.or`,
  `tests/next/errors/e0304_namespace_shadowed_by_closure_param.or`, `tests/next/errors/e0304_namespace_shadowed_by_function.or`,
  `tests/next/errors/e0304_namespace_shadowed_by_import.or`, `tests/next/errors/e0400_namespace_as_value.or`, `tests/next/errors/e0400_namespace_passed.or`,
  `tests/next/errors/e0400_namespace_printed.or`, `tests/next/errors/e0400_namespace_compared.or`, `tests/next/errors/e0400_namespace_called.or`,
  `tests/next/errors/e0200_import_star_without_as.or`.

**MOD-3.** A path that resolves to no file is E0301 (`cannot find module`). A path starting with `$` is reserved for the embedded preludes and is not an
importable path from source (it is reported as an unreadable file, E0301).
- Tests: `tests/errors/e0301_module_not_found.or`, `tests/next/errors/e0301_unknown_std_module.or`.

**MOD-4.** **Module boundary.** A file outside a module's directory may import only the module itself (its `module.or`), never a file inside it
(E0302). Files inside the directory import each other freely.
- Tests: `tests/errors/e0302_private_import`, `tests/run/modules_basic`.

**MOD-5.** Import cycles between files are rejected (E0303). The module graph is a DAG; diamonds (two paths to one file) are fine.
- Tests: `tests/errors/e0303_cycle`, `tests/run/modules_diamond`.

**MOD-6.** Names of one file's scope (its own declarations and its imported names) must be unique: a duplicate function, type, constant, variant or imported name,
or an import that collides with a local declaration, is E0304. A union type's variants are module-level constructors, so two union types of one file cannot share a variant name.
- Tests: `tests/errors/e0304_duplicate_function.or`, `tests/errors/e0304_duplicate_variant.or`, `tests/parse_edge/ok_unions.or`.

**MOD-7.** `export { a, B } from "path";` re-exports names without importing them into the file's own scope. Importing or re-exporting a union type also brings all its
variants into scope (ADR-0004). An exported function, type, constant or interface whose signature or field types mention a type declared in the same file without `export` is rejected with E0306 on the private name (ADR-0056 6.9); export the type or keep the declaration private. Private fields of a class, private methods and the fields of an `@Sealed` type are exempt (importers cannot construct or change a sealed value).
- Tests: `tests/errors/e0306_private_type_in_signature.or`, `tests/errors/e0306_private_type_in_exported_type.or`, `tests/run/modules_reexport_union`, `tests/next/run/generic_reexport`, `tests/next/run/iface_reexport`, `tests/parse_edge/ok_reexport_export_forms.or`.

**MOD-8.** Generic functions, generic types, interfaces and classes are imported and exported like any declaration; a generic function is instantiated in the importing program
(monomorphisation, chapter 3), so the importer sees the instantiation's errors, not the definition's. An interface is exported by name and conformance is nominal across modules.
- Tests: `tests/next/run/generic_modules`, `tests/next/run/iface_modules`, `tests/next/run/class_module`, `tests/next/run/genclass_module`,
  `tests/next/run/iface_generic_bound_modules`, `tests/next/errors/e0300_import_generic_not_exported`.

## 6.2 Standard modules

**MOD-9.** `std:name` imports a module of the standard library. The importable names are: `std:fs`, `std:process`, `std:io`, `std:math`, `std:path`, `std:json`,
`std:jsonnumber`, `std:jsonvalue`, `std:jsondecode`, `std:time`, `std:graph`, `std:test`, `std:host`, `std:bytes`, `std:encoding`, `std:utf8`, `std:url`, `std:collections`,
`std:http`, `std:seq`, `std:task`, `std:taskcore`, `std:net`, `std:text`, `std:html`, `std:ox`, `std:meta`, `std:metacore`, `std:metajson`. Any other `std:` name is E0301 and the
message lists these. Most modules are Orin source embedded in the compiler (`library/std/*.or`); `std:process` and `std:io` are C runtime built-ins and `std:fs` is Orin over C primitives. The modules that perform
I/O are **unstable** until the I/O freeze (docs/std.md); `std:math` (`library/collections/math.or`) is float-only.
- Tests: `tests/next/errors/e0301_unknown_std_module.or`, `tests/next/errors/std_unknown_module.or`, `tests/next/run/std_path_join.or`, `tests/next/run/std_json_parse_basic.or`,
  `tests/next/run/float_math_module.or`, `tests/next/errors/e0300_std_math_unknown_name.or`.

**MOD-10.** The raw primitive modules (`std:fsraw`, `std:clock`, `std:core`, `std:coreprobe` outside the runtime) are internal: only library code may import them; user code gets E0301.
- Tests: `tests/next/errors/e0301_resource_raw_import.or`, `tests/next/errors/e0301_grant_raw_import.or`, `tests/next/errors/e0301_core_ops_are_internal.or`,
  `tests/next/errors/e0301_task_primitives_are_internal.or`.

## 6.3 Preludes

**MOD-11.** Some names need no import. They come from **prelude roots** that the compiler embeds and loads into every program (unit names start with `$`, which marks internal code and lets
unused prelude functions be pruned): `library/core/` (`$std`: string search/split/trim/join, `parseInt`, integer and bool `toString`), `library/collections/` (`$array`: the array methods `map filter find findIndex some every reduce
forEach sort indexOf includes`, `Map` and `MapEntry`, the derivation helpers of `Eq`/`Ord`/`Hash`), and the runtime root. The language-level surface of the prelude is: the types `int i8 .. usize float f32 bool string void
Option Result Map MapEntry`, the constructors `Some None Ok Err`, the interfaces `Eq Ord Hash`, `console.log`, `console.error`, `String.fromCharCode`, `parseInt`, `parseFloat`, `parseI8 .. parseUsize`, and the built-in
methods of chapter 3. The prelude is part of the language: it is checked with the program and its generic functions are instantiated like user code. A user declaration may reuse a prelude name in its own scope.
- Tests: `tests/run/std_prelude_edges.or`, `tests/run/option_methods.or`, `tests/next/run/array_methods_in_generics.or`, `tests/next/run/map_basic_string_int.or`, `tests/next/run/eqord_map_keys.or`.

## 6.4 Packages (`orin.toml`)

A **package** is a directory with `orin.toml`. The manifest is a strict subset of TOML (`compiler/package/toml.or`); an unknown table or key is an error, never ignored.

```toml
[package]
name = "shop"                 # required
version = "0.1.0"             # default "0.0.0"
entry = "src/main.or"         # default; relative to the package root

[architecture]                # each flag is always on; `= false` is rejected
acyclic_modules = true
private_by_default = true
explicit_public_api = true

[contracts]
strict = true                 # strict contract-coverage warnings W0470/W0471 (ADR-0028)

[modules.users]               # a module = a directory under the entry file's directory ("." = root)
allowed_dependencies = ["database"]

[annotations]
processors = ["dep", "dep/module"]   # processors of dependencies that may run (ADR-0046)

[effects]                     # capability policy, chapter 5
allowed = ["Console.Write"]

[dependencies]
lib = { path = "../lib" }
router = { git = "https://example.org/router", tag = "v0.2.0" }
```

**MOD-12.** `[package]` requires `name`; `version` and `entry` are optional. A key outside the documented set, a wrong value type, a missing `[package]`, an `[architecture]` flag set to
`false` is E0503; a TOML syntax error (including an unterminated array) is E0500.
- Tests: `tests/next/errors/e0500_manifest_syntax`, `tests/next/errors/e0500_manifest_unterminated_array`, `tests/next/errors/e0503_manifest_unknown_key`,
  `tests/next/errors/e0503_manifest_architecture_off`, `tests/next/packages/shop`.

**MOD-13.** `[modules.x] allowed_dependencies = [..]` restricts which modules the files of module `x` may import: an import of any other module of the package is E0501. A
name that is not a module of the package (no directory, no `module.or`) in `[modules.x]`, `allowed_dependencies` or `[effects.x]` is E0502. The package's module graph is acyclic
(MOD-5). `orin check --deps` prints the module dependency graph.
- Tests: `tests/next/errors/e0501_disallowed_dependency`, `tests/next/errors/e0501_generated_import_disallowed`, `tests/next/errors/e0502_unknown_module`,
  `tests/next/errors/e0502_unknown_allowed_dependency`, `tests/next/run/package_modules`, `tests/next/packages/shop`.

**MOD-14.** A `[dependencies]` entry (`name = { path = "../x" }` or `{ git = "..", tag|rev = ".." }`; `[dev-dependencies]` for tests) makes `import { f } from "name";` resolve to the dependency's
`src/module.or`; its internal modules keep the privacy rules of MOD-4. Dependencies are source code, not a sandbox. Resolution is recorded in `orin.lock` (a build never updates it; `orin update` does).
- Tests: `tests/workspace_cli/ok/app` (a package with a path dependency), `tests/processors/dep_trusted`, `tests/processors/dep_untrusted`.

## 6.5 Workspaces (`orin-workspace.toml`)

**MOD-15.** A workspace root contains `orin-workspace.toml` with `[workspace] members = [..]` (required, non-empty; literal paths or a trailing `*` segment), `exclude`, `default-members`, and `[workspace.tools.<name>]`
(`path`, `type = "npm"`). Every member directory has an `orin.toml` with `[package]`; names are unique; a path dependency must point at a member; the member graph is acyclic; the lock
(`orin.lock`, written only by `orin workspace lock`) must match. Errors carry the span of the offending key: E0504 invalid manifest, E0505 invalid member path, E0506 duplicate name/path, E0507 ambiguous
or overlapping layout (nested workspace, nested member, an `exclude` matching nothing), E0508 bad dependency (non-member path, cycle), E0509 stale lock.
- Tests: `tests/workspace/ok/single`, `tests/workspace/ok/glob_order`, `tests/workspace/ok/topo_order`, `tests/workspace/ok/exclude`, `tests/workspace/ok/default_members`,
  `tests/workspace/fail/syntax`, `tests/workspace/fail/missing_members`, `tests/workspace/fail/absolute_path`, `tests/workspace/fail/dotdot_path`,
  `tests/workspace/fail/duplicate_name`, `tests/workspace/fail/duplicate_path`, `tests/workspace/fail/nested_workspace`, `tests/workspace/fail/exclude_matches_nothing`,
  `tests/workspace/fail/path_dep_non_member`, `tests/workspace/fail/dependency_cycle`, `tests/workspace/fail/stale_lockfile`, `tests/workspace_cli/ok`.

## 6.6 Repository layout (ADR-0047)

**MOD-16.** The source tree is organised as: `compiler/` (the compiler, an Orin package with `compiler/orin.toml`), `runtime/core/` and `runtime/platform/` (the C runtime and the L0 platform layer),
`library/core/`, `library/collections/` and `library/std/` (the embedded preludes and the `std:*` modules), `tooling/` (Orin-written tools), `tests/`, `docs/`, `formal/`, `bootstrap/` (the seed). The
public `std:*` import names, the virtual prelude roots (`$std`, `$array`, `$stdlib`) and the C ABI are independent of this layout. ADR-0047 itself is still marked "proposed"; phases 1 to 3 (workspace manifest,
workspace CLI, library/runtime moves) are in the tree.
- Tests: none (a description of the repository; `tools/bootstrap.sh` checks that the embedded preludes are current, `tools/embed_prelude.py --check`).

## Gaps: rules without a test

- MOD-2: no test shows an import of a name that is exported by `export { x } from` of a third module (only the union case, `modules_reexport_union`). MOD-2a/2b: a union type exported through a namespace is covered only for a local module.
- MOD-3: the `$`-path rejection has no test.
- MOD-6: no test for an import colliding with a local declaration or with another import (E0304 probed with `orin2`).
- MOD-11: the exact list of prelude names is the union of the prelude sources; no test pins it, and "a user declaration may reuse a prelude name" has no test.
- MOD-12: `version` and `entry` defaults have no direct test (`tests/next/packages/shop` uses the default entry).
- MOD-14: bare-name dependency imports are exercised only through `tests/processors/` and the workspace CLI journeys (`tools/test_cli.py`), not through the conformance runner; there is no negative test for a dependency's private file.
- MOD-15: E0504 for `members` of the wrong type is covered (`members_not_array`); E0507 for `default-members` that is not a member is `default_not_member`.
- MOD-16: description of the repository; no conformance test applies.
