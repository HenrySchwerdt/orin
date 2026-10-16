# Companion modules and `orin expand` (ADR-0046 S4)

Status: expansion works on recorded outputs; processors are not executed yet (S5).

## Companion modules

`import { f } from "./models.gen"` imports the generated companion of the module `./models`. The companion is a virtual module
placed right after its source in the unit order. It sees all declarations of `models`, private ones included, and exports only
what the generated output marks exported. Without recorded outputs it is an empty module.

Pipeline (only when the program has a `.gen` import, or for `orin expand`):

1. check the sub-program that does not depend on any `.gen` module;
2. build one `std:meta` `Input` per (annotation, source module), ordered by annotation module and name, with
   `freshBase = 10000 * (run index + 1)`;
3. take the `Output` of the run from the test hook;
4. convert it into AST (spans point at the annotation use of the first annotated declaration of the run);
5. check hygiene (E0449) and cycles (E0521);
6. check the whole program, then HIR, MIR and the backends as usual.

Diagnostics inside generated code carry the note "in code generated for `@Json` on `User` (companion module `./models.gen`; `orin expand` prints it)".

## Test hook

`models.gen.Json.json` next to `models.or` holds the recorded `Output` (format `orin.meta.output`, version 1; see docs/std-meta.md)
of the processor for `@Json` in `models`. Annotations without a sidecar stay metadata. Generated imports may name only modules
the program has already loaded, and the `orin.toml` module rules apply (E0501).

## `orin expand`

`orin expand main.or` prints every companion (`// companion module ./models.gen`, `// generated for ...`) through the formatter;
`orin expand --input main.or` prints the snapshots, one JSON document per line. Both are deterministic.

## Limits of S4

LSP, MCP, `orin test`, `orin graph`, `orin effects` do not expand (a `.gen` import is E0300 there). Generated code cannot use
anonymous unions or bit operators. Contract text in snapshots is whitespace-collapsed source.
