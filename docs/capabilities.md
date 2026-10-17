# Capabilities: effect inference and the effect policy (Stage B)

Stage A ([ADR-0027](decisions/0027-stage-a-root-capabilities.md)) made I/O need a *grant* and recorded every primitive call
site. Stage B ([ADR-0021](decisions/0021-capabilities-and-io-provenance.md), [ADR-0037](decisions/0037-generic-capabilities-lineage-and-lean.md)
D2, graph 2 "primitive / effect graph") answers the question a call site cannot: **what may this function, module, package or
program do?** For every function the compiler infers the set of primitive effects it may perform *transitively*, with its
evidence and the call chain that explains each effect. No new syntax.

Effects confer no permission. Possessing a valid grant at the operation stays mandatory (ADR-0037 D2); the summary says what
the code may *do*, the grants a program holds are a separate matter.

One analysis serves everybody: `orin effects`, the OSIG `MAY_PERFORM` edges (and with them `orin diff`), the LSP hover and the
MCP `inspect` tool all consume the result of `inferEffects` (`compiler/analysis/effects.or`) over the semantic index; none of
them reasons about calls on its own. Source: `compiler/analysis/effects.or` (engine), `effectsum.or` (names, aggregation, text
and JSON), `effectpolicy.or` (policy); the command is `compiler/tools/effectscli.or`.

## The model

An **effect** is a compiler-owned primitive operation (the closed list of ADR-0037 D1; only the compiler defines them) with its
**direction** and the family of **grant** it needs:

| Operation | Direction | Grant | Written as |
|---|---|---|---|
| `Fs.ReadFile`, `Fs.Stat`, `Fs.Read` (a `File` read) | INPUT | `FsGrant` | `readFile`, `exists`, `file.read*` |
| `Fs.WriteFile`, `Fs.Write` (a `File` write / flush) | OUTPUT | `FsGrant` | `writeFile`, `file.write*` |
| `Fs.Open`, `Fs.Narrow` | CONTROL | `FsGrant` | `withFile` / `useFile`, `withUnder` / `withReadOnly` |
| `Process.Args` | INPUT | `ProcessGrant` | `args` |
| `Process.Spawn`, `Process.Narrow` | CONTROL | `ProcessGrant` | `shell`, `withArgsOnly` |
| `Process.Exit` | CONTROL | ambient | `exit` |
| `Stdio.Read` / `Stdio.Write` | INPUT / OUTPUT | `StdioGrant` | `readLine`, `readBytes` / `writeStdout` |
| `Clock.Now` | INPUT | `ClockGrant` | `nowMillis` |
| `Console.Write` | OUTPUT | ambient | `console.log`, `console.error` |
| `Host.Acquire` | CONTROL | `Host` | the `std:host` scope functions |

and four **UNKNOWN** kinds (`Unknown.*`, no direction, no grant):

| Kind | When |
|---|---|
| `Unknown.FunctionValue` | a function value of unknown origin is called (a local, a field, an array element, a call result) |
| `Unknown.Callback` | a function value of unknown origin is passed to a function that calls its parameter |
| `Unknown.Interface` | an interface method that no class of the program implements is called |
| `Unknown.Unresolved` | a call whose target the index could not map to a definition (none occurs today: `orin effects --check-purity` asserts it) |

**Evidence** of an effect of a function:

| Evidence | Meaning |
|---|---|
| `MUST` | a primitive call (or a call of a std scope function that performs one) written directly in the function's body, outside any closure. As everywhere in the OSIG, MUST is a *static occurrence*, not "on every path" |
| `MAY` | everything else that is known: inherited from a callee, written in a closure (attributed to the function that contains the closure), reached through an implementation of an interface method |
| `UNKNOWN` | the target is not known. UNKNOWN is never "pure": it is an effect of its own kind and it is inherited like any other |

The **explanation path** of an effect is the shortest call chain from the function to the function that performs the primitive,
with the place in each body (`file:line:col` relative to the package's source root) and, in the last step, the primitive call
itself. Ties are broken by source order, so the output is deterministic.

## Soundness: why a summary never misses an effect

The summary of a function contains every primitive operation an execution of it may perform (a sound over-approximation, the
property ADR-0037 D6 item 6 asks Lean to prove later; here it is argued and tested, `TESTED_ONLY`). The argument, per way an
effect can be reached:

* **Direct and method calls, constructors, calls through a bounded type parameter:** the callee's summary is inherited (MAY).
  The semantic index records one call site per call in every body of the program including the std library (the std scope
  functions are Orin code, so what they do is in the graph); a generic function is one def whose body is the union over its
  instances.
* **Interface calls:** the summary of an interface method is the union over *every* implementation the program declares
  (`implements`); `Unknown.Interface` when there is none. Because `implements` is the only way to convert a class to an
  interface (ADR-0019), no other target exists.
* **Closures:** the calls of a closure literal's body are recorded as MAY call sites of the function that contains the literal,
  *wherever* the closure is later called. A named function used as a value is a MAY edge of the function that takes it. So
  whoever runs a function value, its effects were already accounted where the value was made.
* **Calling a function value:** if the value is a parameter of the function, the function has *no effect of its own* for the
  call; it is parametric in that parameter (`callbacks` in the output). A caller that passes a closure literal or a named
  function inherits the effects from the literal / the function (previous point); a caller that passes its own parameter on
  becomes parametric in turn (fixed point); a caller that passes a value of any other origin gets `Unknown.Callback`. A call of a
  function value of any other origin is `Unknown.FunctionValue`. This is what makes `useHost(host, (fs, ...) => ...)` precise:
  the effects are those of the callback, and nothing is UNKNOWN. (The purity analysis uses the same rule: a function is pure
  *relative to its function arguments*.)
* **Recursion, mutual recursion:** the summaries are the least fixed point of the inheritance, computed by rounds (round r adds
  what a callee gained in round r-1). An effect is added to a function once, so cycles terminate, and every chain ends at a
  primitive call (the contract `EffectTable.consistent()`, checked after every `inferEffects` in the contract-checked compiler).
* **Attribution to modules:** the effects of a module are those of the code *written* in it, a closure counting for the
  module that contains it, not for the module that happens to run it; abstract interface methods and std library code belong
  to no module. This is what a policy needs ("what can the code of this module do").
* **Traps** (array bounds, `unwrap` of `None`, a failed contract, division by zero) are not effects, as in the purity analysis
  (a call of `std:test`'s `fail` / `assert*` is: it writes to stderr and exits).

### Remaining UNKNOWN sources, and what is not covered

* function values of unknown origin (struct fields, array elements, call results, captured function values inside a closure);
* interface methods with no implementation in the program, and calls the index cannot resolve (none today);
* **not an effect of the program text at all:** native code / FFI, the OS, a modified compiler or runtime, a spawned child
  process's own behaviour (`Process.Spawn` is CONTROL and a `ProcessGrant` is no sandbox, ADR-0037 D5), races (TOCTOU);
* a program that does not type-check has no summary (the index of a failed check has no call sites; the tools say so instead
  of claiming purity);
* the summary is *per operation family*, not per resource: it does not say which file is read (resource identity is ADR-0037 D3,
  not implemented).

### Agreement with the purity analysis

`compiler/check/purity.or` (E0416, contract purity) and the effect analysis see the same primitives, unknown calls and closures,
so: **a function that has an effect is impure, and a pure function has no effect.** Three things keep it that way:

1. the two builtin tables are tied by a contract: `ioOpOf` in `check/index/effects.or` ensures `result != "" ==> isIoBuiltin(b)` and
   that its operation is in the registry `primitiveEffects()`; the contract-checked compiler runs it on every compile;
2. `orin effects <entry> --check-purity` runs both analyses over the HIR and fails if a def has an effect although every
   function lowered from it is pure (and if any HIR function has no def in the index); `tools/test_effects.py`,
   `tools/test_capabilities.sh` and the unit tests run it over the demo packages, the capability programs and the compiler itself
   (`tools/test_effects.py --sweep` runs it over every conformance program);
3. the converse need not hold and does not: purity treats every interface call as unknown, the effect analysis takes the union
   over the implementations, so a function that only calls a pure implementation is impure for contracts and effect-free here.

## `orin effects`

```
orin effects <entry.or | package-dir> [--format=text|json] [--no-paths] [--summary] [--module <id>] [--function <name>]
             [--tests] [--check-purity]
```

Type-checks the program (std prelude not loaded, like `orin graph`; `@Test` functions are erased as in a build, ADR-0024,
unless `--tests` is given) and prints, in this order: the **entry point** `main`
(what running the program may do), the **package** (the union over the modules), every **module** (its effects with the
witness path of each, then every function of the module that has an effect or calls a function value of its parameters, with
its own paths). `--summary` stops at the modules, `--no-paths` drops the chains, `--module` (a module id, `.` or `(root)` for the
root) and `--function` filter. Exit code 0; 1 when the program does not check or when the `[effects]` policy is violated (the
violations are printed to stderr, see below); 2 for usage errors. `--check-purity` runs the agreement check above instead.

```
entry point (root)::main:
  Fs.ReadFile INPUT [MAY] FsGrant
      (root)::main  src/main.or:11:17
      -> store::loadConfig  src/store/store.or:5:13  <- performs Fs.ReadFile
  Host.Acquire CONTROL [MUST] Host
      (root)::main  src/main.or:10:3  <- performs Host.Acquire
  Unknown.FunctionValue [UNKNOWN]
      (root)::main  src/main.or:17:15
      -> dynamic::runDynamic  src/dynamic/dynamic.or:8:10  <- call of a function value of unknown origin
...
module util: pure
```

(`tests/osig/effects/app.effects.txt` is the full golden output of a package with a direct primitive, transitive calls, an
interface with an effectful and a pure implementation, recursion, an UNKNOWN call, a closure literal and `useHost`.)

`--format=json` (`effects/0.1`) has one line per module (`modules`) and per function (`functions`), so it diffs line by line:

```json
{"module":"store","effects":[{"operation":"Fs.ReadFile","direction":"INPUT","grant":"FsGrant","evidence":"MUST",
  "path":[{"function":"store::loadConfig","span":{"file":"src/store/store.or","line":5,"col":13,...},"route":"io"}]}],"functions":2}
{"function":"store::reload","module":"store","kind":"Function","span":{...},"summary":{"pure":false,"effects":[...],"callbacks":[]}}
```

`route` is how the next hop is reached: `io` (a primitive), `direct` / `method` / `constructor` / `bound` / `virtual` (a call),
`value` (a function used as a value), `impl` (an implementation of an interface method), or the UNKNOWN reason.
The output is deterministic (no absolute paths, no timestamps; modules sorted with `.` first, functions in source order).

### Other consumers of the same result

(The OSIG, the hover and `inspect` describe the source as written, `@Test` functions included, like every other view of the
semantic index; `orin effects`, `orin check` and `compile` describe and police the program a build ships.)

* **OSIG** (`osig/0.2`, [osig.md](osig.md)): one `MAY_PERFORM` edge per function and effect from the function to the `Effect` node
  (`~io:Fs.ReadFile`, or `~unknown` with the UNKNOWN kind as `via`); `evidence` MUST / MAY / UNKNOWN, `via` the direction,
  `next` the callee the effect is inherited from. `PERFORMS_IO` (call sites) stays.
* **`orin diff`** reports new and removed effects per function (with the path in the graph where the effect exists and, for a
  new direct effect, the entry points that now reach it) and per module; see [osig.md](osig.md).
* **LSP hover** on a function, method or constructor (a declaration or a call) appends the summary: ``- `Fs.ReadFile INPUT
  [MAY] FsGrant` via main::load -> ...`` or "none (pure)".
* **MCP `inspect`** returns `effects` for a symbol (`pure`, `effects` with `path`, `callbacks`) and for a module
  ([mcp.md](mcp.md)).

## The effect policy (`orin.toml`)

Prepares ADR-0037 D4. Absent configuration means **no restriction**.

```toml
[effects]                      # the package default
allowed = ["Console.Write", "Fs.Read"]

[effects.loader]               # one module (same ids as [modules.x]; "." for the root)
allowed = ["Fs"]

[effects.parser]               # a pure module
allowed = []
```

An `allowed` entry is an operation (`Fs.ReadFile`), a family (`Fs`: every operation of the family), a family wildcard (`Fs.*`),
`Unknown` / `Unknown.<kind>` (calls whose target is not known) or `*`. A module with a table of its own uses it, every other
module the package default (no default: unrestricted). The effects checked are those of the *module* (above): transitive, a
closure counting for its creator. **Unknown effects exceed every allowance that does not name `Unknown` (or `*`)**: an unknown
call may do anything.

| Code | Meaning |
|---|---|
| `E0473` | a module may perform an effect outside its allowance. Reported once per module and effect, at the call in the module that starts the path; the notes are the explanation path |
| `E0474` | an `allowed` entry names no effect the compiler knows (`knownEffectNames`) |
| `E0502` | an `[effects.<module>]` table names a module that does not exist (as for `[modules.x]`) |

E0474 and E0502 are located in `orin.toml` (the loader keeps the manifest's text in `Manifest.source`; `policySourceMap`
renders the policy diagnostics against the program's files plus the manifest). Before rewrite step 3e they kept the file id of
the manifest parse and were printed as a position in the program's first source file.
| `E0503` | malformed table: `allowed` is not an array of strings, an unknown key (also E0500 for a duplicate table) |

```
src/main.or:13:5: error[E0473]: module `(root)` may perform `Fs.WriteFile` (OUTPUT, MAY), but the package [effects] allows only [Console.Write, Fs.ReadFile, Host, Unknown]
  note: (root)::main  src/main.or:13:5
  note: -> store::saveConfig  src/store/store.or:11:3  <- performs Fs.WriteFile
```

It is checked by `orin check`, `compile`, `mir` and `verify` on the program a build ships (`@Test` functions erased), by
`orin effects` (printed after the summary; exit code 1), and not by the LSP (diagnostics there are the checker's). It costs one
more type check only when an `[effects]` table exists.

## The compiler's own summary (`orin effects compiler/main.or --summary`)

Only the front end's tooling layers perform effects; **the whole compiler pipeline is pure**: `syntax`, `package`, `check`,
`hir`, `lower`, `mir`, `opt`, `verify`, `cemit`, `llvm`, `fmt`, `json` and `diag` have no effect at all (the loader reads files only
through `Sources`, which takes the grant as a parameter).

| Module | Effects (direct = written there) |
|---|---|
| `loader` | `Fs.ReadFile`, `Fs.Stat`: only `Sources.read` / `Sources.exists` |
| `analysis` | none of its own; `Fs.ReadFile`, `Fs.Stat` only inherited (MAY) through `loader::Sources.read` / `Sources.exists` (`readText`, `resolveModulePath`, `loadOsigIn` and the program loads) |
| `tools` | `Fs.ReadFile`, `Fs.WriteFile`, `Console.Write`: the command-line drivers `orin fmt`, `orin graph` / `diff` (`osigcli.or`, `writeOut`) and `orin effects` (`effectscli.or`) |
| `lsp` | `Stdio.Read`, `Stdio.Write`, `Process.Spawn`, `Console.Write`; `Fs.*` only through `analysis` (and with it `loader::Sources`) |
| `mcp` | `Fs.ReadFile`, `Fs.Stat`, `Fs.WriteFile`, `Console.Write`; stdio and `Process.Spawn` through `lsp` |
| `testing` | `Fs.ReadFile`, `Fs.Stat`, `Fs.WriteFile`, `Console.Write`; `Process.Spawn` through `lsp::shellRun` |
| `vc` | `Fs.ReadFile`, `Fs.WriteFile` (the solver's files), `Process.Spawn` through `lsp::shellRun` |
| `(root)` (`main.or`) | `Host.Acquire`, `Process.Args`, `Process.Exit`, `Fs.ReadFile`, `Fs.WriteFile`, `Console.Write`; the rest through the modules above |

`main` may perform `Console.Write`, `Fs.ReadFile`, `Fs.Stat`, `Fs.WriteFile`, `Host.Acquire`, `Process.Args`, `Process.Exit`,
`Process.Spawn`, `Stdio.Read` and `Stdio.Write`; it does not use `Clock.Now`, and **nothing is UNKNOWN**. Findings of the
first run: (1) the one `shell` call of the compiler sits in `lsp/stdio.or` (`shellRun`), which `testing`, `vc` and `mcp` import:
the process-spawning primitive lives in the `lsp` module, an architectural oddity worth a module of its own (still so: there is
no `spawn(proc, executable, argv)` yet, ADR-0037 D5, so `shellRun` stays until it exists); (2) the `analysis` module, the facade
the language server uses, reached the file system in three places (`readText`, `resolveModulePath`, `loadOsigIn`) and wrote the
output of `orin graph` / `diff` (`writeOut`); (3) four modules print their own usage text with `console.error` and `exit` (`usage`
in `main`, `analysis`, `tools`, `testing`) instead of returning a status.

**The capability gate (rewrite step 3e).** Finding (2) is resolved: the three reads go through the loader's `Sources` (the
workspace hands its buffers to `Sources` with `Workspace.sources()`, `loadOsigIn` reads a snapshot with a `Sources` without
overlay), and the command-line drivers `orin graph` / `diff` / `effects` with their output file moved to `tools` (`osigcli.or`,
`effectscli.or`). Only `loader/sources` reads files and only the CLI layer (`tools`, the driver) writes them. `orin effects
compiler/main.or --module analysis` shows no effect of `analysis` itself: every effect of the module is `Fs.ReadFile` /
`Fs.Stat` with evidence MAY, and every explanation path ends in `loader::Sources.read` / `Sources.exists`. Pinned by
`tools/test_effects.py` ("compiler: analysis has no direct effect", "every file access of analysis goes through
loader::Sources"). Finding (3) no longer applies to `analysis` (its usage texts moved with the drivers).

The policy can express the table; for example (not enabled, `compiler/` has no `orin.toml`):

```toml
[effects]                         # default: pure
allowed = []
[effects.loader]
allowed = ["Fs.ReadFile", "Fs.Stat"]
[effects.vc]
allowed = ["Fs", "Process.Spawn"]
```

## Tests

`compiler/tests/effects_test.or` (direct, transitive, closures and function values, interfaces, recursion, `useHost` / `useFs`,
purity agreement, not-typed program, policy matching; `tools/test_tooling.sh`), `tools/test_effects.py` (the CLI goldens
`tests/osig/effects/app.*`, determinism, OSIG `MAY_PERFORM` invariants on four programs including the compiler, the diff
sections, the policy cases), the LSP hover tests in `compiler/tests/lsp_test.or` and `tools/protocol.sh lsp`, the MCP `inspect`
tests in `tools/protocol.sh mcp`, and `tools/test_capabilities.sh` (the inferred effects cover what the runtime denies).

## The Orbit capability manifest (`--target=wasm64-orbit`)

`orin compile <entry.or> -o out.c --target=wasm64-orbit` (C backend only; with `--backend=llvm`, `--stats-sites` or `--split` it is a
usage error, exit 2; `--target=native` is the default and changes nothing) appends a manifest for the Orbit WebAssembly runtime to
the generated C, as the very last lines: a custom section `orbit.manifest` whose payload is the UTF-8 JSON
`{"abi":1,"requires":[...],"producer":"orin"}` (host ABI section 6). It describes requirements and never authorises.

`requires` is derived from the effect set of `main` that `orin effects <entry> --summary` reports for the entry point:

| effect | capability |
|---|---|
| `Console.Write`, `Stdio.Write` | `log/v1` |
| `Clock.Now` | `clock/v1` |
| `Process.Exit`, `Process.Args`, `Stdio.Read`, `Host.Acquire` | none (handled in the guest: exit traps after recording the status, args are `["main"]`, stdin is empty) |
| `Unknown.*` (an unresolved call, e.g. of a function value) | no error; `clock/v1` is required as well (the safe over-approximation: the guest can import only `log/v1` and `clock/v1`) |
| anything else (`Fs.*`, `Process.Spawn`, `Net.*`, `Stream.*`, `Task.*`, `Channel.*`) | not available: error E0523 |

`log/v1` is always required (a runtime trap prints its message to stderr, which maps to the log capability); the list is sorted
without duplicates. E0523 is reported once per unavailable effect, located at the evidence the analysis has
(``error[E0523]: `main` needs Fs.ReadFile, which the wasm64-orbit target does not provide``). Implementation:
`compiler/analysis/orbit.or`; tests: `tools/test_effects.py` (section 5).
