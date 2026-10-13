# Orin

**Native. Safe. Simple.** Orin is an experimental, statically typed, ahead-of-time compiled
language with TypeScript-familiar syntax, value semantics, compiler-inferred memory management
(no borrow checker, no tracing GC) and a self-hosted compiler. Design: [`spec/`](spec/spec.md).

> ⚠️ **Alpha, for experimentation only.** The language is incomplete and will change. Memory
> safety is backed by an independent ownership verifier, sanitizer-tested suites and partial Lean
> proofs, but it is **not** formally proven end to end — see the
> [safety status](docs/architecture.md#safety-status-honest-labelling-spec-07).

```ts
class Counter {
  constructor(public value: int) {}
  increment(): void { this.value += 1; }
}

function main(): void {
  let a = new Counter(0);
  const b = a;          // a snapshot, not a shared reference
  a.increment();
  console.log(a.value.toString() + " " + b.value.toString());   // 1 0
}
```

## Try it

Download a release package from the [Releases](../../releases) page (Linux x86-64, macOS arm64),
unpack it, and use `bin/orin` (requires a C compiler — `cc`, gcc or clang — on your PATH):

```bash
tar xzf orin-<version>-<platform>.tar.gz && cd orin-<version>-<platform>
bin/orin run examples/hello.or
bin/orin build examples/shapes.or -o shapes && ./shapes
bin/orin check examples/counter.or           # type-check only
bin/orin fmt --stdout examples/generics.or   # canonical formatting
bin/orin lsp                                 # language server (see editors/vscode)
```

`share/orin/orin-seed.c` is the self-hosted compiler itself as C: `cc -O2 -I lib/orin/runtime
share/orin/orin-seed.c lib/orin/runtime/*.c -o orin` rebuilds it without Rust.

## What works today
- Functions, records, tagged unions + `match`, `Option`/`Result` with `?`, arrays, strings,
  modules with enforced boundaries (`module.or`) and acyclic imports.
- Generics (monomorphised), classes with value semantics (mutating methods inferred).
- Checked arithmetic and bounds (defined traps, exit code 101).
- Tooling: `orin check --format=json`, `orin fmt`, `orin lsp` (diagnostics, definition, hover,
  references, rename, completion, formatting), VS Code extension in `editors/vscode`.

Not yet: closures, floats, maps, interfaces, annotations/contracts, concurrency.
Progress and roadmap: [`docs/progress.md`](docs/progress.md).

## Building from source
```bash
./tools/bootstrap.sh          # Rust stage 0 -> self-hosted orin1 -> orin2 -> stage3 (must match)
python3 tools/run_tests.py --orinc build/bootstrap/orin2 --suite all
```
