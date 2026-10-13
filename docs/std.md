# Standard library overview

Status of the std modules of ADR-0016 (spec 08). Every public function has a doc comment in its
source with signature, errors/absence, behaviour and complexity (the spec 08 validation rule); this
page is the map. `orin mcp` `inspect` answers `std:path.join`, `std:json.parse`, ... from its built-in
API table (`compiler/mcp/apitable.or`).

| Module | Implemented in | Status |
|---|---|---|
| `std:host` | Orin, `stdlib/host.or` over the grant primitives of `std:fsraw` | the root of authority: `Host`, scope functions that derive grants (ADR-0027); **unstable** until the I/O freeze |
| `std:fs` | Orin, `stdlib/fs.or` (scope API) over C runtime primitives (`std:fsraw`, internal) | done; takes an `FsGrant` first (ADR-0027), **unstable** until the owner confirms the I/O freeze (ADR-0016); resources and streaming: ADR-0025 |
| `std:process`, `std:io` | C runtime built-ins (`runtime/orin_runtime*.c/.h`) | done; `args`, `shell`, `readLine`, ... take a `ProcessGrant` / `StdioGrant` first (ADR-0027), **unstable** |
| `std:path` | Orin, `stdlib/path.or` | done (POSIX, lexical) |
| `std:json` | Orin, `stdlib/json.or` | done, **integers only** |
| `std:time` | Orin, `stdlib/time.or` + one built-in (`nowMillis`) | clock, durations, UTC calendar; no `sleep`; `nowMillis(clock: ClockGrant)` **unstable** (ADR-0027) |
| `std:graph` | Orin, `stdlib/graph.or` | `class Graph<T>` with generational, tagged `GraphId<T>` (ADR-0026) |
| `std:test` | Orin, `stdlib/test.or` | done (assertions for `@Test`, ADR-0024) |
| `std:math` | Orin, `array/math.or` (to move to `stdlib/`) | done (ADR-0018) |
| `Map<K, V>` | Orin prelude (`array/map.or`), built-in type | done (ADR-0018) |

## How the Orin-written modules are organised

`stdlib/*.or` is embedded into the compiler like the other preludes (`tools/embed_prelude.py` writes
`compiler/loader/embedded_stdlib.or`; run it after editing `stdlib/`, `tools/bootstrap.sh` checks it).
It is a *library root* (`PreludeRoot` with an empty `entry`): its files are served from memory under
`$stdlib/<name>.or` but, unlike `std/` and `array/`, **not** imported implicitly. The loader maps
`import ... from "std:path"` (also `std:json`, `std:time`, `std:graph`, `std:test`) to the unit `$stdlib/path`.
Programs that do not import a module pay nothing for it, and the leading `$` makes unused functions of
imported modules disappear in `compiler/opt/prune.or`. The sources use the full language (generics,
records, closures); only the compiler itself has to stay Orin-B. Type names in diagnostics show the
unit (`$stdlib/json.Json`).

The single new built-in is `nowMillis(clock: ClockGrant): int` (`hir.BTimeNowMillis`, C function
`orin_time_now_millis` in `runtime/orin_runtime_io.h`, `orinl_time_now_millis` for the LLVM backend).
It is reachable as the internal module `std:clock`; `std:time` re-exports it. Use `std:time`.

## std:host and capability grants (UNSTABLE until the I/O freeze, ADR-0021 Stage A, ADR-0027)

A program that performs I/O is `function main(host: Host): void`; `main(): void` has **no I/O authority** (calling any
std I/O function in it is a compile error, E0470). `Host` and the **grants** derived from it are resource handles
with the rules of `File` (a parameter only; not storable, returnable, capturable, copyable: E0450-E0452, and the
MIR verifier re-checks it). Grants come from scope functions, are revoked when the callback returns and are passed
to every std I/O function as the first argument:

```
useHost(host, (fs, proc, stdio, clock) => ...)   // all four root grants of the host policy (withHost returns a value)
useFs(host, fs => ...)  useProcess(host, proc => ...)  useStdio(host, stdio => ...)  useClock(host, clock => ...)
useUnder(fs, "data", sub => ...)   // narrowing: only paths inside data/ (also withUnder<T>); never widens
useReadOnly(fs, ro => ...)         // cannot create / write / truncate
useArgsOnly(proc, p => ...)        // `args` but no `shell`
```

Families (ADR-0027): `FsGrant` (`std:fs`), `ProcessGrant` (`std:process`: `args`, `shell`), `StdioGrant` (`std:io`),
`ClockGrant` (`std:time`: `nowMillis`); a network family is reserved (no `std:net` yet). **Ambient, no grant:**
`console.log`, `console.error` and `exit` (a library without grants can therefore still write to stdout / stderr: see
ADR-0027 D5). **Host policy:** by default every grant is what the OS process has; `ORIN_DENY=fs,process,...` (families
`fs process stdio clock net all`) denies families: an operation that returns a `Result` returns `Err("... denied by
the host policy (ORIN_DENY)")`, every other operation traps; a malformed `ORIN_DENY` traps at start. **Scopes:** a
narrowed `FsGrant` compares absolute normalised paths (`..`, `.`, `//`) and resolved symbolic links, and the opened
path is the checked one; relative paths resolve against the working directory (a filter, not a chroot). Not covered:
races (TOCTOU), hard links and mounts, `shell` (a spawned command is outside every grant), native code. A closure
cannot capture a grant: take all you need with `useHost`, pass grants as arguments, or use `withFileFs`.

## std:fs (UNSTABLE: every function takes an `FsGrant` first, ADR-0027)

Whole-file functions: `readFile(fs, path): Result<string, string>`, `writeFile(fs, path, data): Result<void, string>`,
`exists(fs, path): bool` (traps on a denied path: a `bool` cannot carry a denial).

Streaming through **resource handles** (ADR-0025, spec 06). `File` is a handle, not a value: it can only be a
function parameter. You get one as the parameter of the callback of a scope function, which opens the file, runs
the callback and closes the file on every path:

```
type FsError = string                       type FileMode = Read | Write | Append
withFile<T>(fs, path, mode, body: (file: File) => T): Result<T, FsError>
useFile(fs, path, mode, body: (file: File) => void): Result<void, FsError>      // body returns nothing
withFiles<T>(fs, pathA, modeA, pathB, modeB, body: (a: File, b: File) => T): Result<T, FsError>
useFiles(fs, pathA, modeA, pathB, modeB, body: (a: File, b: File) => void): Result<void, FsError>
withFileFs<T>(fs, path, mode, body: (file: File, fs: FsGrant) => T): Result<T, FsError>   // the body gets the grant again (nesting)
withUnder<T>(fs, dir, body: (sub: FsGrant) => T): T      useUnder(fs, dir, body)        // narrowing
withReadOnly<T>(fs, body: (ro: FsGrant) => T): T         useReadOnly(fs, body)

File.readLine(): Option<string>      // without "\n" / "\r\n"; None at end of file
File.read(n: usize): Option<string>  // up to n bytes; None only at end of file (n > 0); read(0) = Some("")
File.readAll(): string               // the rest of the file
File.write(s: string): void          File.writeLine(s: string): void       File.flush(): void
```

`Err` is returned when the file cannot be opened (the body does not run) or when any read, write, flush or the final
close failed (the file remembers its first error; the body's value is then dropped). Wrong-mode use (writing a
`Read` file) is such an error, not a compile error. Not allowed on a `File` (compile errors): storing it in a
record/class/array/`Option`/`Result`/`Map`, returning it, assigning it to a variable (`const g = f`), capturing it
in a closure (so a nested scope cannot use the outer handle: use `withFiles`), comparing it, converting it to a
string (E0450, E0451, E0452; `docs/decisions/0025-resources-and-streaming-fs.md`). A trap or `process.exit` inside
a body ends the process; the runtime flushes and closes open files in its exit hook. At most 256 files are open at
the same time. Example:

```
const n = withFile(fs, "log.txt", Read, f => {
  let lines: int = 0;
  while (f.readLine().isSome()) { lines += 1; }
  return lines;
});
useFiles(fs, "in.txt", Read, "out.txt", Write, (a, b) => { while (true) { const l = a.readLine(); if (l.isNone()) { return; } b.writeLine(l.unwrap()); } });
```

## std:path (POSIX, lexical)

Paths are byte strings with `/`; nothing touches the file system or the current directory; all functions
are total and O(n). Behaviour follows Node's `path.posix`.

`join(parts: string[]): string` (empty parts skipped, then `normalize`; `[]` -> `"."`; a later absolute
part does not reset), `normalize(p)` (`""` -> `"."`, `..` above the root of an absolute path is dropped,
leading `..` of relative paths kept, trailing `/` kept), `dirname(p)`, `basename(p)`, `extension(p)`
(`".txt"`; `""` for `.bashrc`, `..`, no dot), `stem(p)`, `withExtension(p, ext)`, `isAbsolute(p)`,
`resolveAgainst(base, p)`.

## std:json (integers only)

```
type Json = JNull | JBool(bool) | JNum(int) | JStr(string) | JArr(Json[]) | JObj(JField[])
type JField = { key: string; value: Json }
type JsonError = { message: string; offset: usize; line: usize; column: usize }   // 1-based line/column in bytes
```

`parse(text): Result<Json, JsonError>`, `stringify(j): string` (compact), `pretty(j, indent: usize): string`,
`quote(s)`, `formatError(e)` ("line L, column C: message"); builders `field(key, value)`; accessors (all
total, `None` on a wrong kind/missing key): `get`, `at`, `path`, `keys`, `asString`, `asInt`, `asBool`,
`asArray`, `asObject`, `isNull`, `getString`, `getInt`, `getBool`, `getArray`.

Rules: integers in -(2^63-1)..2^63-1 only; `1.5` / `1e3` are errors ("floats are not supported yet") until
floats exist; nesting > 200 is an error; `\uXXXX` and surrogate pairs decode to UTF-8 (lone surrogate ->
U+FFFD); raw control characters in strings are errors; duplicate keys are kept and `get` returns the last.
`parse(stringify(j))` round-trips. Codegen-based `parse<T>` is post-1.0 (ADR-0016).

## std:time

`nowMillis(clock: ClockGrant): int` (wall clock, ms since the Unix epoch, not monotonic; the grant comes from `useClock` / `useHost` of `std:host`). Durations are explicit-unit
records `Duration { millis }`: `milliseconds/seconds/minutes/hours/days(n)`, `toMillis`, `toSeconds`,
`addDuration`, `between(start, end)`, `plus(instant, d)`, `formatDuration` ("1h 2m 3s 5ms"). UTC calendar
(proleptic Gregorian, no zones): `fromMillis(instant): DateTime`, `toInstant(dt): Option<int>` (validates
the fields), `isLeapYear`, `daysInMonth`, `formatIso(instant)` ("2024-02-29T13:04:05.006Z").

## std:test (assertions, ADR-0024)

Assertions for `@Test` functions; see docs/testing.md. A failed assertion **traps**: it writes
`trap: <message>` to stderr and exits with status 101 (like every other trap), so it also works in
ordinary programs. All functions return `void`; `msg` ("" allowed) is part of the trap message.

`assert(cond: bool, msg)` ("assertion failed: msg"), `assertEq(actual: int, expected: int, msg)`,
`assertEqUsize`, `assertEqString` (values shown in quotes), `assertEqBool`
("assertEq failed: msg: expected 3, got 2"), `assertNear(actual: float, expected: float, tolerance: float,
msg)` (|actual - expected| <= tolerance; NaN always fails), `fail(msg)`. One `assertEq*` per type because
Orin has no generic equality or `toString`.

## std:graph (spec 06 cyclic graphs)

A graph owner holds the nodes; edges are checked, non-owning ids, so no owning cycle ever exists. `Graph<T>` is a
generic class (ADR-0026) and, like every class, a value: a copy is independent.

```
type GraphId<T> = { tag: int; index: usize; gen: int }     // obtain only through add (T is phantom)
type GraphError = StaleId | ForeignId
class Graph<T> {
  constructor(tag: int)
  size(): usize                                   contains(id): bool
  add(value: T): GraphId<T>                       // mutating, never fails
  get(id): Result<T, GraphError>
  set(id, value): Result<void, GraphError>        // mutating
  remove(id): Result<T, GraphError>               // mutating; returns the removed value
  addEdge(a, b): Result<void, GraphError>         // mutating, directed
  neighbors(id): Result<GraphId<T>[], GraphError>
  ids(): GraphId<T>[]
}
graphErrorMessage(e: GraphError): string
```

```ts
import { Graph } from "std:graph";
let g = new Graph<string>(1);
const a = g.add("alpha");
const b = g.add("beta");
g.addEdge(a, b).unwrap();
g.remove(a).unwrap();            // `a` is now stale: g.get(a) is Err(StaleId)
```

Ids carry the graph tag, slot index and slot generation. `remove` bumps the generation, so every copy of the
removed node's id is stale (`Err(StaleId)`) even after the slot is reused (freed slots are reused through a free
list); an id of another graph (different tag, or an index beyond the graph) is `Err(ForeignId)`. Edges to removed
nodes dangle and are skipped by `neighbors`. A failed operation leaves the graph unchanged. Fields are private.

**Value semantics.** `const h = g;` keeps the old nodes while `g` changes (an id removed in `g` is still valid in the
older `h`: ids identify a node of one *tag*). Mutating methods update in place when the graph is not shared, so
`add`, `get`, `set`, `remove`, `addEdge` are O(1); a shared graph is copied on the first change. The tag is passed
by the caller (`new Graph<T>(tag)`): the language has no process-wide counter for automatic unique tags; use a
different tag per logical graph. The old functional API (`newGraph`, `add(g, v)` returning `{graph, id}`, ...) was
removed with ADR-0026; the tests were migrated.

## Limitations

* No floats/`Map`: `JNum` is `int`, no `std:math`, `std:map`, edge weights, `sleep`, fractional seconds.
* Generic methods do not exist (E0460); `Graph<T>` has no edge weights and needs a caller-supplied tag.
* Diagnostics print std types with their unit name (`$stdlib/graph.GraphId<int>`).
* `std:clock` is importable but internal; so is `std:fsraw` (the raw open/close and grant primitives behind `std:fs` and `std:host`; only library code may import it).
* `std:fs` streaming: text/byte-string API without seek, no directory operations, at most 256 open files.
