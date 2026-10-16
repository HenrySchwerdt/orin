# Annotation processors, companion modules and `orin expand` (ADR-0046 S4, S5)

Status: processors run (S5). Two complete examples (S6): `examples/json-codec` (`@Json` / `@JsonName` codecs) and `examples/routes` (`@Route` table), both ordinary packages, not part of `std`.

## Writing a processor

```ts
// describe.or: the module that declares the annotation also declares its processor
import { Input, Output, MDecl, fn, named, ret, str, exportDecl, output, findAnnotation, annotationArg, constString } from "std:meta";

@Annotation(type, function)
export type Describe = { text: string; };

@Processor(Describe)
export function describeProc(input: Input): Output {
  let decls: MDecl[] = [];
  for (const d of input.decls) {
    const text = constString(annotationArg(findAnnotation(d.annotations, "Describe").unwrap(), "text").unwrap()).unwrapOr("");
    decls.push(exportDecl(fn("describe" + d.name, [], named("string"), [ret(str(d.name + " - " + text))]), true));
  }
  return output(decls);
}
```

`tests/next/run/processor_describe` is the complete, runnable example (annotation, annotated module, a `main` that imports
`./models.gen`).

Rules (E0448 when broken, reported by `orin check`/`compile` whether or not a `.gen` module is imported):

* `@Processor(A)` marks an **exported top-level function** `(input: Input): Output` with `Input` and `Output` imported from
  `std:meta`; not generic, not called `main`.
* `A` is an `@Annotation` record **declared in the same module**; there is **one processor per annotation**.
* The function and everything it calls must be **pure** in the sense of the contract checker (`compiler/check/purity.or`): no
  I/O built-in, no grant, no unknown function value. The signature gives the function no grant, so it cannot do I/O. The
  error text carries the explanation of the contract checker: `the processor `p` is not pure: `anno.p` -> `anno.shout`
  performs I/O (console.log) at anno.or:7:3`.

A processor runs only for modules that **import** its annotation and **use** it, and only when some module of the program
imports the companion `./m.gen` of that module (nothing is scanned or discovered).

## Execution

For each processor in use the compiler builds **one helper executable**: the processor module and its imports, `std:meta` and a
generated `main` module (`__orin_processor_main`, an overlay file next to the processor module) that reads the encoded `Input`
(one line of JSON, the text `orin expand --input` prints) from stdin, calls the processor and writes the encoded `Output`
to stdout. It is built the way `orin test` builds its executable (checker, MIR, ownership verifier, C backend, `--cc`,
`--runtime`). **One process per (processor, source module)** is run through the shell with:

| Limit | Default | Setting |
|---|---|---|
| deadline per run | 10 s | `--processor-timeout SECONDS` (0 = none); native deadline, `std:io.shellTimeout` |
| encoded output | 16 MiB | the output is piped through `head -c`, so a runaway processor cannot fill the disk |
| generated declarations | 10,000 per program (all runs together) | |
| capabilities | `ORIN_DENY=fs,process,clock,net` | everything but stdio, which the harness needs for `Input`/`Output`; a processor is pure and has no grant to use it anyway |

Any failure is **E0520** naming the processor, the annotation use, the module and the captured stderr, and there is never a
partially expanded program:

```
models.or:3:1: error[E0520]: processor `boomProc` (`@Boom` on `Thing`, module `./models`) failed: trapped (exit status 101)
  note: stderr: trap: index out of bounds
```

(`timed out after 2 s (--processor-timeout)`, `produced more than 16777216 bytes of output`, `exited with status N`, a C
compiler or loader error while building the helper, `exceeds the limit of 10000 generated declarations per program`; output
that does not decode is `the output of the processor `p` for ... is not usable: <path>: <problem>`.) A decoded output is
converted and checked exactly as in S4 (E0449, E0522, W0491, generated code is checked like hand-written code).

Options of `orin check`, `compile`, `expand`: `--processor-timeout S`, `--processor-cache DIR`, `--cc CMD` (default `cc`),
`--runtime DIR` (default `runtime/core`; the `orin` launcher passes both), `--verbose` (what was built, reused and run, on stderr).

## Cache

`<package root, else the entry's directory>/.orin/processors/<helper key>/` holds `helper` (the executable) and
`out-<input key>.json` (the `Output` of a successful run). The helper key hashes the cache format version, the generated main and
the path and text of every unit of the processor module's closure (the embedded `std` modules included, so a change of
`std:meta` builds a new helper); the input key hashes the encoded `Input`. Only successful runs are cached, an unchanged
program runs no processor and builds no helper (`--verbose`: `reused the output of `p` for module `./m``), and a changed
annotated module with the same processor reuses the helper (`reused the helper of `p``). The C compiler is not part of the key.
Two compilers using one cache directory at the same moment is not supported.

`orin check` (and anything that only needs diagnostics) uses the cache. Without a C compiler **and** without a cached helper it
reports **W0490** (`processors not run: no C compiler ... the companion module of module `./m` stays empty`) and the companion
stays empty, so its imports are E0300. `compile` and `expand` fail with E0520 instead.

## Trust

Processors of the package's own modules and of `std` run. A processor that comes from a **dependency** runs only when the
manifest lists the dependency or the module:

```toml
[annotations]
processors = ["lib", "other/render"]   # a dependency name, or dependency/module below its src
```

Otherwise **W0492** (`the processor `p` of `@A` was not run: it comes from the dependency `lib` and is not listed in `[annotations]
processors` of orin.toml`) is printed, the annotation stays metadata and the companion is empty. Fixtures:
`tests/processors/dep_untrusted`, `dep_trusted`, `dep_trusted_module`.

## Companion modules

`import { f } from "./models.gen"` imports the generated companion of the module `./models`. The companion is a virtual module
placed right after its source in the unit order. It sees all declarations of `models`, private ones included, and exports only
what the generated output marks exported.

Pipeline (only when the program has a `.gen` import, or for `orin expand`):

1. check the sub-program that does not depend on any `.gen` module, then the rules for processors (E0448);
2. build one `std:meta` `Input` per (annotation, source module), ordered by annotation module and name, with
   `freshBase = 10000 * (run index + 1)`;
3. take the `Output` of the run: the recorded output if one exists (test hook below), else the processor's;
4. convert it into AST (spans point at the annotation use of the first annotated declaration of the run);
5. check hygiene (E0449) and cycles (E0521);
6. check the whole program, then HIR, MIR and the backends as usual.

Diagnostics inside generated code carry the note "in code generated for `@Json` on `User` (companion module `./models.gen`; `orin expand` prints it)".

## Test hook (recorded outputs)

`models.gen.Json.json` next to `models.or` holds the recorded `Output` (format `orin.meta.output`, version 1; see docs/std-meta.md)
of the processor for `@Json` in `models`. **A recorded output wins over a processor of the same annotation**: nothing is built or
run for that run. Annotations without a processor and without a sidecar stay metadata. Generated imports may name only modules
the program has already loaded, and the `orin.toml` module rules apply (E0501).

## `orin expand`

`orin expand main.or` prints every companion (`// companion module ./models.gen`, `// generated for ...`) through the formatter,
running processors as needed; `orin expand --input main.or` prints the snapshots, one JSON document per line. Both are
deterministic (a processor is a pure function of its input).

## Limits

LSP, MCP, `orin test`, `orin graph`, `orin effects` do not expand (a `.gen` import is E0300 there). A processor has no memory limit
(deadline and output cap only). Generated code cannot use anonymous unions or bit operators. Contract text in snapshots is
whitespace-collapsed source. A processor module that itself depends on a companion cannot be verified and is E0448. A companion module cannot import another companion module (E0520), so generated code that needs another module's generated code is not possible; there is no `@Json` in `std` (it is the example `examples/json-codec`).
