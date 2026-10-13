<p align="center">
  <img src="docs/assets/orin-logo-256.png" alt="Orin logo" width="160">
</p>

<h1 align="center">Orin</h1>

<p align="center"><b>Native. Safe. Simple.</b><br>
A statically typed, natively compiled language with TypeScript-familiar syntax,<br>
memory safety without a borrow checker or garbage collector, and a self-hosted compiler.</p>

> ⚠️ **Experimental alpha.** Orin is a research-driven language in early development. Expect
> missing features and breaking changes. See [what works today](#status) and the
> [honest safety status](docs/architecture.md#safety-status-honest-labelling-spec-07).

---

## Why Orin?

Today you usually have to pick two of three:

| | Easy to write | Fast & native | Memory-safe without GC |
|---|---|---|---|
| TypeScript / JavaScript | ✅ | ❌ (VM, JIT) | ✅ (GC) |
| Go / Java / C# | ✅ | ✅/〰️ | ✅ (GC) |
| Rust | 〰️ (borrow checker, lifetimes) | ✅ | ✅ |
| C / C++ | 〰️ | ✅ | ❌ |

**Orin aims for all three.** You write code that looks like TypeScript; the compiler produces a
native executable and works out memory management by itself — no `free`, no lifetimes, no
borrow annotations, no tracing garbage collector.

And because more and more code is written *with* AI agents, Orin is designed to be easy for
both humans and agents to read, write, check and review.

## The core ideas

**1. Familiar syntax, strict semantics.** Orin reads like TypeScript (`const`, `let`, `function`,
classes, `=>`, `map`/`filter`), but without JavaScript's pitfalls: no `null`/`undefined`, no
`any`, no implicit coercions, no `var`, no exceptions. Absence is `Option<T>`, failure is
`Result<T, E>` with `?` propagation, and every `match` must be exhaustive.

**2. Values, not shared mutable objects.** Records, arrays and classes are *values*:

```ts
class Counter {
  constructor(public value: int) {}
  increment(): void { this.value += 1; }
}

let a = new Counter(0);
const b = a;        // b is an independent snapshot
a.increment();      // a.value == 1, b.value == 0 — no spooky action at a distance
```

**3. The compiler manages memory (OIM — "Orin Inferred Memory").** Under the hood, values are
reference-counted and copied lazily (copy-on-write). The compiler infers ownership, moves values
at their last use and updates in place when nothing else can observe it — so value semantics
stay cheap. Planned next: unboxing, region allocation and more verified optimisations.

**4. Safety you can check, not just trust.** Memory safety is treated as a *theorem*, not a
marketing claim:
- every compilation passes through an **independent ownership verifier** on an explicit memory IR
  (MIR) — a compiler bug that would break memory safety is caught before code is generated;
- a **Lean 4 formal model** proves that the reference-counting machine never touches freed
  memory, that copy-on-write never changes what aliases observe, and that code accepted by the
  ownership checker is safe (for the core of the IR so far);
- the runtime will move into Orin itself on top of a tiny, separately verified platform layer,
  shrinking what has to be trusted ([spec 19](spec/19-runtime-and-platform-layer.md)).

**5. Business rules you can prove.** Contract clauses state what code must do and are proven by
a compiler pass (planned, [spec 15](spec/15-contracts-invariants-and-formal-verification.md)):

```ts
@Invariant(this.balance >= 0)
class BankAccount {
  balance: int;

  @Requires(amount > 0 && amount <= this.balance)
  @Ensures(this.balance == old(this.balance) - amount)
  withdraw(amount: int): void {
    this.balance -= amount;
  }
}
```

**6. Modules with real boundaries.** A directory with a `module.or` is a module; only what it
exports is visible, private files can't be imported from outside, and module dependencies must
form a DAG — enforced by the compiler, so architecture doesn't erode.

**7. Built for agents and editors.** One semantic engine powers the compiler, the formatter, the
language server (`orin lsp`) and an MCP server (`orin mcp`, in progress) with compact,
structured, stable diagnostics — optimised for the total effort needed to reach correct code.

**8. Self-hosted.** The Orin compiler is written in Orin and compiles itself reproducibly
(stage 2 and stage 3 output are byte-identical).

## Status

| Area | State |
|---|---|
| Self-hosted compiler, reproducible bootstrap | ✅ |
| Core language: functions, records, tagged unions + `match`, `Option`/`Result`/`?`, arrays, strings, modules | ✅ |
| Generics, classes with value semantics | ✅ |
| Memory IR + independent ownership verifier + ownership optimisation | ✅ |
| Lean proofs: RC machine safety, copy-on-write, ownership-checker soundness (IR core) | ✅ partial |
| `orin fmt`, `orin check --format=json`, `orin lsp`, VS Code extension | ✅ |
| Closures + array API, LLVM backend, `orin mcp`, runtime in Orin | 🚧 in progress |
| Packages (`orin.toml`, enforced module architecture rules, API snapshots) | ✅ |
| Floats, maps, interfaces, annotations & contracts, concurrency | 📋 planned |

Performance today: roughly 1.1–2.7× the run time of equivalent C on our
[benchmarks](docs/benchmarks.md) (mixed against Go). Closing that gap without weakening safety
is a core goal.

## Try it

Download a package from [Releases](../../releases) (Linux x86-64, macOS arm64). You need a C
compiler (`cc`, gcc or clang) on your PATH — Orin currently compiles to C, LLVM is coming.

```bash
tar xzf orin-<version>-<platform>.tar.gz && cd orin-<version>-<platform>
bin/orin run examples/hello.or
bin/orin build examples/shapes.or -o shapes && ./shapes
bin/orin test examples/testing.or                # run the @Test functions (docs/testing.md)
bin/orin check examples/counter.or           # type-check only
bin/orin fmt --stdout examples/generics.or   # canonical formatting
```

### Packages

A directory with an `orin.toml` is a package; `check`, `compile`, `build` and `run` accept it in
place of a file and use the manifest's `entry` (default `src/main.or`).

```toml
[package]
name = "shop"
version = "0.1.0"            # entry = "src/main.or" by default

[architecture]
acyclic_modules = true       # private_by_default / explicit_public_api: always on
[modules.payments]           # module = directory (with module.or) relative to the entry's directory
allowed_dependencies = ["users", "database"]
```

```bash
bin/orin run myshop/                          # build + run the package
bin/orin check --deps myshop/                 # module -> imports summary (add --format=json)
bin/orin api myshop/ > api.txt                # public API snapshot (signatures per module)
bin/orin api --check api.txt myshop/          # exit 1 if the public API changed
```

A module with an `allowed_dependencies` rule may only import the listed modules (E0501); unknown
module names in the manifest are E0502; manifest syntax errors are E0500 and invalid manifests
E0503. The rules also apply when you check a single file inside the package (editors, MCP).

Editor support: see [`editors/vscode`](editors/vscode) (syntax highlighting + language server).

## Building from source

```bash
./tools/bootstrap.sh     # committed seed → orin0 → orin1 → orin2 → stage3 (stage2/3 must be identical)
python3 tools/run_tests.py --orinc build/bootstrap/orin2 --suite all
```

The default build needs only a C compiler, `python3`, `gzip` and `sha256sum`/`shasum` — no Rust.
`./tools/bootstrap.sh --from-stage0` bootstraps from the Rust Stage 0 instead (needs `cargo`, as do
the Rust unit tests); both roots produce a byte-identical compiler. See
[`docs/bootstrap.md`](docs/bootstrap.md).

## Learn more

- Language specification: [`spec/`](spec/spec.md)
- Architecture and safety status: [`docs/architecture.md`](docs/architecture.md)
- Design decisions (ADRs): [`docs/decisions/`](docs/decisions)
- Formal model: [`docs/formal.md`](docs/formal.md) · Memory IR: [`docs/mir.md`](docs/mir.md)
- Progress: [`docs/progress.md`](docs/progress.md) · roadmap: [`docs/roadmap.md`](docs/roadmap.md) · vision: [`docs/ORIN_VISION_ARCHITECTURE_ROADMAP.md`](docs/ORIN_VISION_ARCHITECTURE_ROADMAP.md) · trusted base: [`docs/tcb.md`](docs/tcb.md) · assurance ledger: [`docs/assurance.md`](docs/assurance.md)

## License

Orin is released under the [MIT License](LICENSE).
