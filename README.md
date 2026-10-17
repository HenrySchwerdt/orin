<p align="center">
  <img src="docs/assets/orin-logo-256.png" alt="Orin logo" width="160">
</p>

<h1 align="center">Orin</h1>

<p align="center"><b>Build with agents. Verify with the compiler. Understand the change.</b><br>
A TypeScript-familiar, natively compiled language for verifiable software engineering:<br>
value semantics, ownership checking, contracts, and semantic change analysis.</p>

Documentation: <https://orin-lang.github.io/orin-lang/> (built from [`docs/`](docs/website.md)).

> ⚠️ **Experimental alpha.** Orin is a research-driven language in early development. Expect
> missing features and breaking changes. Orin is **not a drop-in TypeScript replacement** and does not
> run arbitrary JavaScript or npm packages. See [what works today](#status) and the
> [honest safety status](docs/architecture.md#safety-status-honest-labelling-spec-07).

---

## Why Orin?

AI agents can produce code quickly. The harder question is whether a change respects the
system's invariants, security boundaries and intended behaviour — and whether reviewers can
understand its consequences.

**Orin's goal is verifiable, agent-driven software development.** It combines familiar
TypeScript-style syntax with explicit value semantics, native compilation, compiler-checked
ownership and contracts. Its **Orin Software Intelligence Graph (OSIG)** provides a foundation
for reviewing code changes semantically rather than only as textual diffs.

Orin is **not JavaScript or TypeScript with a different backend**: it deliberately uses stricter
semantics, and npm/Node.js compatibility is not implemented. The aim is a familiar development
experience, not a misleading promise of full ecosystem compatibility.

### What you can do today

- Compile a statically typed Orin program to native code (C backend and an LLVM IR backend).
- Write markup with OX, TSX-like syntax whose meaning a library provides: with `import ox from "std:html";`,
  `<Card title={t}>{body}</Card>` compiles to one fused string buffer, every dynamic value escaped by construction; other
  providers build widget trees or XML ([docs/ox.md](docs/ox.md), experimental).
- Use classes, interfaces, generics, closures, value-semantics collections, Option/Result,
  modules and packages.
- Check ownership in MIR, run tests, use contract clauses and verify a supported pure
  int/bool subset with Z3; see [contracts](docs/contracts.md) and [assurance](docs/assurance.md).
- Generate a semantic symbol/call graph and compare two program versions using
  `orin graph` and `orin diff`, including source locations and MUST/MAY/UNKNOWN call evidence.
  See [OSIG](docs/osig.md).
- Ask what a function, module or program may *do*: `orin effects` infers the transitive primitive effects (file, stdio,
  process, clock, console) with evidence and an explanation path, and `orin.toml` can restrict them per module
  (`[effects] allowed = [...]`). See [capabilities](docs/capabilities.md).

### Where we're going

Current source implements **root capability grants and effect-policy checks** (Stages A/B).
Grant-based std I/O checks authority at each operation; grants do not sandbox native code or spawned
commands. The std I/O APIs remain unstable pending the owner's freeze decision. See
[capabilities and their limits](docs/capabilities.md). Older published alpha packages may predate
APIs described on main.

The next major goal is **process-level data lineage**. With trusted
I/O boundaries and protocol/resource bindings, OSIG should eventually be able to trace
an input (such as an HTTP request or Kafka message) through service calls and field
transformations to an external output — and show how a PR changes that process.
The [capability design](docs/decisions/0021-capabilities-and-io-provenance.md) and
[verifiable-software roadmap](docs/decisions/0020-verifiable-software-roadmap.md) specify this work.

**Field-level lineage, cross-service process discovery and signed
`.orcert` attestations are planned, not shipping features.** Even when implemented,
static analysis may report MAY or UNKNOWN rather than claiming complete certainty.

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
stay cheap. Planned next: unboxing, escape analysis with stack allocation, and more verified optimisations.

**4. Safety you can check, with explicit limits.** Orin builds multiple layers of evidence rather
than claiming complete memory-safety proof for every compiler and runtime path:
- every compilation passes through an **independent ownership verifier** on an explicit memory IR
  (MIR) — ownership-rule violations in MIR are rejected before code generation; this does not detect every possible compiler bug;
- a **Lean 4 formal model** proves that the reference-counting machine never touches freed
  memory, that copy-on-write never changes what aliases observe, and that code accepted by the
  ownership checker is safe — **in the formal model** and for the core of the IR so far. The real
  verifier is cross-checked against that model by differential and mutation testing, not proved
  equal to it. Shape/type confusion (reading a field a value does not have) is outside the proof;
  this gap was hit once by a real compiler bug, and runtime field bounds checks are now the backstop
  ([finding F-shape](docs/assurance.md));
- the runtime has an Orin standard-library layer and an L0 platform boundary; further runtime
  implementation and verification work remains ([runtime plan](spec/19-runtime-and-platform-layer.md),
  [assurance ledger](docs/assurance.md)).

**5. Business rules you can specify and selectively verify.** Contract clauses can be checked
at runtime, and supported pure int/bool contracts can be sent to Z3. Other claims may remain
UNKNOWN; no blanket proof of arbitrary business logic is implied ([contracts](docs/contracts.md)):

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

**7. Built for agents and editors.** The toolchain includes a compiler, formatter,
language server (`orin lsp`), MCP server (`orin mcp`) and OSIG export/diff with compact,
structured, stable diagnostics — optimised for the total effort needed to reach correct code.

**8. Self-hosted.** The Orin compiler is written in Orin and compiles itself reproducibly
(stage 2 and stage 3 output are byte-identical).

## Status

| Area | Status |
|---|---|
| Self-hosted compiler, checked-in C bootstrap seed, C and LLVM IR backends | ✅ Implemented |
| Language: classes, generics, interfaces, closures, maps, floats, fixed-width integers, template literals, packages | ✅ Implemented (language frozen for 1.0, ADR-0016) |
| Copy-on-write value semantics, MIR ownership verification, resource-safe `File` handles | ✅ Implemented; safety evidence has documented limits |
| Formatter, diagnostics, language server, MCP, VS Code support, `orin test` | ✅ Implemented |
| Contract clauses + SMT verification | ✅ Supported subset; not universal proof |
| `orin graph`, `orin diff`, HTML PR report | ✅ OSIG v0.2 structural graph with transitive effect summaries |
| `orin effects`, `[effects]` policy in `orin.toml` (ADR-0037 D2, Stage B) | ✅ Implemented: sound over-approximation (UNKNOWN is never pure); per-operation-family, not per resource; no native-code guarantees |
| Compiler modernisation (ADR-0015) | 🚧 Underway |
| Root capabilities for the std I/O (`main(host: Host)`, narrowing, `ORIN_DENY`, path scopes; ADR-0027) | ✅ Implemented (Stage A; std I/O stays unstable until the freeze); not a sandbox against native code |
| Derived library capabilities, policy gates, HTTP/Kafka protocol bindings | 📋 Designed; not implemented |
| Inferred effects, field lineage, automatic cross-service process discovery | 📋 Planned |
| Concurrency, stage 0: `std:task` (structured `scope` / `spawn` / `join`, bounded channels, isolated tasks with move-or-copy transfer, grants moved into tasks; ADR-0017) | ✅ Implemented in Orin over a small C core (L0 threads + a temporary runtime interface that R3 ports); the C parts are tested only (ThreadSanitizer), see [concurrency](docs/concurrency.md); no `async` / `await`, no deadlock detection |
| Signed attestations (`.orcert`), M:N scheduler, further optimisation | 📋 Planned |

**Performance:** Native output does not automatically imply C-equivalent speed. Check
[benchmarks](docs/benchmarks.md) for workload-specific measurements, and
[assurance](docs/assurance.md) for the runtime safety/performance trade-offs.

The source of truth for exact feature status is [docs/progress.md](docs/progress.md).
The roadmap distinguishes implemented graph analysis from the future process/lineage
capabilities.

## Try it

Orin releases are pre-releases until 1.0 ([stability policy](docs/stability.md)) for Linux (x86-64, arm64) and
macOS (arm64, Intel); use the latest on the [releases page](https://github.com/orin-lang/orin-lang/releases)
(**0.1.0-beta.1** is the first with all four platforms), or build from source. New to Orin? Start with
[getting started](docs/getting-started.md) and the [tutorial](docs/tutorial/README.md). You need a C compiler
(`cc`, gcc or clang) on your PATH for the default backend. An LLVM IR backend is also implemented; see the
[build and backend documentation](docs/architecture.md). Details, options and troubleshooting:
[docs/install.md](docs/install.md).

**Homebrew** (macOS arm64 and Intel, Linux x86-64 and arm64):

```bash
brew install orin-lang/orin/orin
orin doctor        # checks the install and the C compiler, prints fixes
```

**One line (Linux, macOS)**: downloads the release for your platform, verifies its sha256, installs to
`~/.orin`:

```bash
curl -fsSL https://raw.githubusercontent.com/orin-lang/orin-lang/main/install.sh | sh
```

**Windows**: WSL2 works today ([docs/windows.md](docs/windows.md)); a native build is planned.

**Manual tarball**: download a package from [Releases](https://github.com/orin-lang/orin-lang/releases) and run it in place:

```bash
tar xzf orin-<version>-<platform>.tar.gz && cd orin-<version>-<platform>
bin/orin run examples/hello.or
bin/orin build examples/shapes.or -o shapes && ./shapes
bin/orin test examples/testing.or               # run @Test functions
bin/orin check examples/counter.or           # type-check only
bin/orin fmt --stdout examples/generics.or   # canonical formatting
```

### Packages

Start a project with `orin init hello`, then `cd hello` and `orin run`. Use `orin dev` for rebuilds,
`orin test` for project tests, and `orin add --path ../shared` for a library dependency. The release
CLI includes colored source diagnostics, project discovery, and cached native builds.
See the [CLI guide](docs/cli.md) for commands, dependencies, terminal options, and current limits.
From a source checkout, `./tools/orin` provides the same interface without changing your installation.

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

### Semantic change review (OSIG)

Use the structural graph and semantic diff in the current alpha:

```bash
bin/orin graph examples/shapes.or -o shapes.graph.json
bin/orin diff --base examples/osig/base --head examples/osig/head --format=html -o osig-diff.html
```

The two versions in `examples/osig` (in a source checkout: `tests/osig/accept`) contain a rename, a signature change and a new call path
from an entry point; the report shows all three (the rename only as a heuristic candidate). In a
PR workflow, compare the base and head versions of your package. OSIG currently reports symbols,
calls, imports, type relationships and contracts — **not** automatic HTTP/Kafka workflows
or field-level data lineage. See [docs/osig.md](docs/osig.md).

Editor support: see [`editors/vscode`](editors/vscode) (syntax highlighting + language server).

## Building from source

```bash
./tools/bootstrap.sh     # committed seed → orin0 → orin1 → orin2 → stage3 (stage2/3 must be identical)
tools/conformance.sh --orinc build/bootstrap/orin2 --suite all
```

The build needs only a C compiler, `python3`, `gzip` and `sha256sum`/`shasum`.
The Rust Stage 0 is retired (archived on the branch `archive/stage0-final`); the committed seed is the
single root. See [`docs/bootstrap.md`](docs/bootstrap.md).

## Learn more

- [Getting started](docs/getting-started.md), [tutorial](docs/tutorial/README.md) and [stability policy](docs/stability.md)
- [Documentation index](docs/README.md): current guides, implementation status, decisions and dated release evidence
- Coming from TypeScript? [Orin for TypeScript developers](docs/ts-developers.md): where code that looks the same behaves differently
- Language reference (normative, as implemented, rules traced to tests): [`docs/reference/`](docs/reference/README.md)
- Language specification (design RFC): [`spec/`](spec/spec.md)
- Architecture and safety status: [`docs/architecture.md`](docs/architecture.md)
- Design decisions (ADRs): [`docs/decisions/`](docs/decisions)
- Formal model: [`docs/formal.md`](docs/formal.md) · Memory IR: [`docs/mir.md`](docs/mir.md)
- Progress: [`docs/progress.md`](docs/progress.md) · roadmap: [`docs/roadmap.md`](docs/roadmap.md) · vision: [`docs/ORIN_VISION_ARCHITECTURE_ROADMAP.md`](docs/ORIN_VISION_ARCHITECTURE_ROADMAP.md) · trusted base: [`docs/tcb.md`](docs/tcb.md) · assurance ledger: [`docs/assurance.md`](docs/assurance.md)

## License

Orin is released under the [MIT License](LICENSE).
