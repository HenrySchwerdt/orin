# Known limitations
- Integers (ADR-0022): `i128` / `u128` are rejected (E0431); arrays of narrow integers use 8 bytes per element; `orin verify --contracts` models every integer width exactly (ADR-0036); `sort` comparators return `int`; no bitwise operators or shifts exist in the language. Template literals: no `\u` escapes, no tagged templates; the formatter prints them verbatim.
- The historical Orin-B subset is documented in [bootstrap-subset.md](bootstrap-subset.md).
  Current compiler sources use the full self-hosted language (see [rewrite.md](rewrite.md)), including
  closures, floats, annotations and generic bounds. Generic instantiation depth is limited to 32 (E0413);
  default type arguments remain unsupported (generic methods are supported, ADR-0040).
- Memory safety is not formally established; see architecture.md "Safety status".
- Early exits from inside expressions (`?`, diverging match arms) may leak temporaries (safe, not
  freed). A record has at most 64 fields and a variant at most 64 payload values (E0305, a compile-time error; ADR-0056 6.9).
- Orin-B had no hash maps; current compiler symbol tables use `Map` (for example `compiler/check/env.or`).
- Closures (ADR-0011, self-hosted compiler only): capture by value only (no mutation of captured names,
  E0401; no recursive arrows, E0300); no `function` expressions, default/rest parameters or generic arrows;
  an arrow as a `?:` branch needs parentheses; parameter types of an arrow need an expected function type
  (or annotations, E0407); builtin functions (`parseInt`, ...) and class methods cannot be used as values;
  Array methods: `indexOf` /
  `includes` only for `int`, `usize`, `bool`, `string` elements (E0405 otherwise); `sort` is O(n log n) with
  O(n) extra allocation per level; the callbacks' integer results must be `int` (`.toInt()` on lengths).
- Classes (ADR-0009, self-hosted compiler only): no inheritance (`extends`, E0408), interface methods that are generic (E0460; class methods may be generic, ADR-0040), static fields, getters/setters, `protected`. Private members are
  checked at compile time (E0405). Constructors initialise fields only through leading `this.f = e;`
  statements, parameter properties and field initializers (else E0411; `this` is unavailable until
  then, E0300). Mutating methods are inferred and use copy-on-write with ownership optimisations
  (ADR-0010). Shared receivers can still require shallow copies, including snapshots retained by
  checked `old(...)` contracts; mutation is not universally allocation-free. A call of a mutating method
  is hoisted before its statement, so it is rejected inside `&&`/`||` operands, `?:` branches and
  `while` conditions (E0408), runs before the other operands of the same statement, and its receiver
  may not contain side-effecting index expressions (E0408). Class values cannot be built with record
  literals outside their class (E0408). Method hover types on the call expression show the lowered type.
- Generic classes (ADR-0026): generic methods are allowed (ADR-0040) but an interface method may not be generic (E0460); static methods cannot use the class type parameters
  (E0461); several interface bounds per parameter (`T extends A & B`); instances are created on demand, so an instance method that is never
  called is only checked abstractly; a `?` in a mutating method with a result is hoisted like a mutating call.
- Concurrency, stage 0 (ADR-0017 Addendum A, docs/concurrency.md): a task is an OS thread (thousands fine, hundreds of thousands not; no
  M:N scheduler); no `async` / `await`, no timeouts or `select`, no cancellation beyond `rx.close()`, **no deadlock detection** (tasks that
  all wait hang); a panic does not unwind, so a trapped task leaks its heap and a panic in a scope *body* leaves running tasks running
  until the process ends; `exit` in a task ends the process and flushes only its own open files; sending a *named local* copies it (no
  last-use move yet); channel ends are copyable and closed explicitly (no "all senders gone"); the C parts (threads, monitors, transfer)
  are tested, not verified; Windows has no thread backend yet.
- Interfaces (ADR-0019, self-hosted compiler only): nominal conformance (`implements`), method signatures only
  (no fields, default methods, `extends`, type parameters: E0408), non-mutating methods only (a mutating
  implementation is E0418), several bounds per type parameter are allowed (`T extends A & B`). A class converts
  implicitly to the interfaces it declares (the only implicit conversion; not lifted over arrays); no
  downcasts, no `instanceof`, `==` on interface values is E0410. Interface values are boxed (one allocation
  per conversion, one indirect call per method call). Go-to-definition from a call on a bounded type parameter inside a generic body
  resolves to the interface method; hover shows the implementations of an interface.
- Companion modules (`./m.gen`, ADR-0046 S4) are filled by processors (S5): `check`, `compile`, `expand` run them through a helper
  executable, which needs a C compiler (without one `orin check` only reports W0490 and uses cached outputs). LSP, MCP, `orin test`,
  `orin graph` and `orin effects` do not expand a `.gen` import (E0300); a processor has a deadline and output limits but no memory
  limit; no OSIG `GENERATED_BY` edges; two compilers on one `.orin/processors` cache at once are unsupported; a companion cannot import another companion (one round of expansion). `@Json` is the example package `examples/json-codec` (integers only, no cross-module nesting), not part of `std`; see docs/annotation-processors.md.
- Built-in annotations (ADR-0024, self-hosted compiler only): `@Test`, `@Deprecated`, `@Inline` and
  `@Sealed` (record construction/update restriction outside the declaring module, ADR-0044) exist;
  user-defined annotations (ADR-0046 S1) are metadata only: records marked `@Annotation(targets..)`, constant
  arguments; processors (`@Processor(A)`, ADR-0046 S5) generate code into companion modules, and the tools know the uses (S2: go to definition, references, rename, hover, `orin api`, OSIG `ANNOTATED_WITH`, MCP `inspect`); any other `@Name` is E0408. `orin test` runs `void` tests that fail by
  trapping (no `Result` tests, fixtures, parameterised tests, parallel runs, coverage); it finds the tests of the
  modules the entry loads, builds with the C backend and needs a C compiler. `@Deprecated` warnings are not listed
  by the MCP `check` tool. `@Inline` is a hint (a recursive `@Inline` function is E0444; calls through function
  values and interface methods are not followed by that check).
- Capability grants (ADR-0027, std I/O unstable until the freeze): a grant is a resource handle, so it is a scope-function
  parameter only: a closure cannot capture one (E0452; take all grants with `useHost`, pass them as arguments, or use
  `withFileFs`), there is no `host.fs()` returning a grant, and at most 256 grants are live per task at once. `console.*` and
  `exit` need no grant (ambient output). Path scopes are checked lexically and through symbolic links at the time of the
  operation (no protection against races, hard links or mounts). `shell` (exported by `std:io`) requires a
  process grant with spawn authority, but the spawned command is outside Orin's grant restrictions. A denied
  operation that cannot return an `Err` traps. Network grants are implemented by `std:net` (ADR-0033), including
  listen/connect narrowing and `ORIN_DENY=net`; the environment family remains reserved.
- Effect inference (Stage B, `orin effects`, docs/capabilities.md): the summary is a sound over-approximation *per operation
  family*, not per resource (it does not say which file), and it is about the program text: native code, FFI, the OS and
  spawned children are outside it. Function values of unknown origin (a struct field, an array element, a call result), interface
  methods without an implementation and unresolved calls are `Unknown.*` effects, so a module that stores callbacks in data
  structures needs `Unknown` in its `[effects]` allowance. A closure counts for the module that writes it. A program that does
  not type-check has no summary. The `[effects]` policy is enforced by `orin check` / `compile` / `mir` / `verify`, not by the
  language server.
