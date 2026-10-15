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
| `std:bytes` | Orin, `stdlib/bytes.or` | `Bytes`, `ByteBuilder`, `ByteReader`; provable-std layer 1 (ADR-0030), contract standard |
| `std:url` | Orin, `stdlib/url.or` | percent encode/decode over bytes or strict UTF-8, ordered query pairs; explicit plus mode and structured byte offsets; [API and policies](std-url.md) |
| `std:utf8` | Orin, `stdlib/utf8.or` | validated decoding, encoding, `Utf8String` ("always valid UTF-8"), `CodePointCursor`; ADR-0030 |
| `std:collections` | Orin, `stdlib/collections.or` | `IntSet`, `StringSet`, `Deque<T>`, `SortedMap<V>`, `SortedStringMap<V>`, `PriorityQueue<T>`; ADR-0030 |
| `std:http` | Orin, `stdlib/http.or` | the **pure** part of HTTP/1.1: `Request`, `Response`, `Headers`, `Status`, an incremental request and response parser (smuggling-safe, limits as parameters) and a serializer with a round-trip contract; the sockets are `std:net` (ADR-0033); `examples/http_server.or` joins them; ADR-0030 |
| `std:net` | Orin, `stdlib/net.or` over the network primitives of `std:fsraw` (L0: ADR-0033) | blocking TCP: `Listener`, `Stream` (resources), `connect`, `resolve`, `readExact`, `readUntil`, deadlines, half-close; takes a `NetGrant` first, narrowed by `useListen` / `useConnect`; **unstable** (ADR-0033, below) |
| `std:seq` | Orin, `stdlib/seq.or` | `range(lo, hi)`, `sum(xs)`, `sumBy(xs, f)`: pure aggregates for contracts and code; `orin verify --contracts` reads them as bounded quantifiers and recursive sums (ADR-0036) |
| `std:text` | Orin, `stdlib/text.or` | `trimBlankLines`, `dedent` (common indentation *prefix*, as Python's `textwrap.dedent`), `indentLines`, `normalizeNewlines`, `isBlankLine`, `leadingIndent`: pure byte-oriented text layout for diagnostics, documentation and CLIs (UTF-8 bytes are preserved; code points belong to `std:utf8`) |
| `std:html` | Orin, `stdlib/html.or` | `Html` (`@Sealed`), `escape`, `safeUrl`, `escapeUrl`, `joinAll`, `trustHtml`, `text`, `fragment`, `render`, `document`: HTML escaping and the URL-scheme rule; the OX provider `ox()` (`import ox from "std:html";`, ADR-0044); below, "std:html" |
| `std:ox` | Orin, `stdlib/ox.or` (types only) | `Markup<R>`, `Components<R>`, `AttrRule`, `Escape`: the protocol an OX provider's `ox()` returns (ADR-0044, docs/ox.md); below, "std:ox" |
| `std:taskcore` | Orin, `stdlib/taskcore.or` | the pure bookkeeping of `std:task` (`Ring` = one channel buffer, `Ledger` = one scope's task table), invariants and contracts, tested and mutated without threads; import `std:task` |
| `std:task` | Orin, `stdlib/task.or` over L0 thread / monitor primitives and a small temporary C interface (`std:fsraw`, internal) | **stage 0, unstable** (ADR-0017 Addendum A): `scope`, `spawn`, `TaskHandle.join`, bounded channels, grant delegation, `parallelMap`, the work-stealing fork/join pool `forkJoin` / `forkJoinUntil` / `parallelism`; see docs/concurrency.md |
| `parallel()` on arrays | Orin prelude (`array/parallel.or`, loaded only for a file that calls it) over `std:task`'s pool | parallel array pipelines (ADR-0039): `map`, `filter`, `reduce`, `some`, `every`, `find`, `findIndex`, `toArray`; below, "Parallel pipelines" |
| `std:test` | Orin, `stdlib/test.or` | done (assertions for `@Test`, ADR-0024) |
| `std:math` | Orin, `array/math.or` (to move to `stdlib/`) | done (ADR-0018) |
| `Map<K, V>` | Orin prelude (`array/map.or`), built-in type | done (ADR-0018) |

## How the Orin-written modules are organised

`stdlib/*.or` is embedded into the compiler like the other preludes (`tools/embed_prelude.py` writes
`compiler/loader/embedded_stdlib.or`; run it after editing `stdlib/`, `tools/bootstrap.sh` checks it).
It is a *library root* (`PreludeRoot` with an empty `entry`): its files are served from memory under
`$stdlib/<name>.or` but, unlike `std/` and `array/`, **not** imported implicitly. The loader maps
`import ... from "std:path"` (also `std:json`, `std:time`, `std:graph`, `std:test`, `std:bytes`, `std:utf8`, `std:url`, `std:collections`, `std:http`, `std:seq`, `std:net`, `std:text`, `std:html`) to the unit `$stdlib/path`.
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
`ClockGrant` (`std:time`: `nowMillis`), `NetGrant` (`std:net`, ADR-0033; `useNet(host, ...)`). **Ambient, no grant:**
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

## Provable std, layer 1 (ADR-0030 §3): `std:bytes`, `std:utf8`, `std:collections`

Pure safe Orin: no C, no new built-ins, no language change. They are the first modules under the contract and
class standard of ADR-0030 §3 (summary):

* every class carries real `@Invariant`s (record invariants are not checked at run time, so all stateful logic is in
  classes) that `orin test` and `--check-contracts` verify after every public method;
* every public method states `@Requires` / `@Ensures`; helpers that contracts call are loops (no closures,
  `map`/`filter`/`every`, no function calling itself from its own contract: those do not terminate or are
  rejected as impure under `--check-contracts`);
* no tautologies; every public function has `@Test` coverage including edge cases (`tests/std/*_test.or`);
* tests run twice: with contract checking (the `orin test` default) and with `--no-contracts` (the logic must not
  depend on the contracts). `tools/test_std.sh` does both; `tools/test_std.sh --mutate` adds the **mutation check**
  (`tools/mutate_std.py`): 60 deliberately broken one-line variants of the three modules, each of which must make a
  test or a contract fail (CI step "Provable std").

Contract counts (clauses in the source): `std:bytes` 3 invariants + 6 `@Requires` + 85 `@Ensures`;
`std:utf8` 2 + 5 + 49; `std:collections` 19 + 5 + 157 (the collection operations are total, so almost none needs a
precondition: absent keys and empty containers answer `None`/`false`). The two B-tree maps are generated from one
template (`tools/sorted_map.tmpl`, `tools/gen_sorted_map.py`; `tools/test_std.sh` checks the generated region is current).
**Algorithm rule** (project owner, 2026-10-13): the std uses the best known algorithm for the job with its full
invariants; if the contract tooling cannot state an invariant, find a formulation that works or report the exact
tooling gap, never ship a weaker algorithm for the sake of a simpler contract. Every choice below was measured against
the simpler alternative.

### std:bytes

A byte is a `u8`. `Bytes` is an immutable view `data[start .. start+len)` of a `u8[]` (arrays are copy-on-write
values, so `slice` shares storage and is O(1)); invariant `start + len <= data.length`.

```
class Bytes                                           // new Bytes(data: u8[], start, len) @Requires(start + len <= data.length)
  length(): usize            isEmpty(): bool          // O(1)
  get(i): Option<u8>         at(i): u8                // get never traps; at: @Requires(i < length())
  slice(lo, hi): Bytes       trySlice(lo, hi): Option<Bytes>   // O(1); slice: @Requires(lo <= hi && hi <= length())
  concat(o): Bytes           equals(o): bool          startsWith(p): bool     indexOf(b: u8): Option<usize>   // O(n)
  toArray(): u8[]            toRawString(): string    toHex(): string          // O(n)
emptyBytes()  bytesFromArray(u8[])  bytesFromInts(int[]) @Requires(allBytes(xs))  bytesFromString(s)  bytesFromHex(s): Option<Bytes>
allBytes(xs: int[]): bool

class ByteBuilder                                     // invariant: capacity >= length
  length()  reserved()  byteAt(i)  reserve(extra)  clear()  build(): Bytes
  appendU8(u8)  appendU16be/le(u16)  appendU32be/le(u32)  appendBytes(Bytes)  appendString(s)   // amortised O(1) per byte

type ReadError = { position: usize; needed: usize; remaining: usize }
class ByteReader                                      // invariant: pos <= src.length(): the cursor never passes the end
  position()  remaining()  isAtEnd()  peekAt(offset): Option<u8>
  readU8(): Result<u8, ReadError>      readU16be/le(): Result<u16, ReadError>     readU32be/le(): Result<u32, ReadError>
  readExact(n): Result<Bytes, ReadError>   skip(n): Result<void, ReadError>   rest(): Bytes
readErrorMessage(e)
```

Contracts that matter: every `read*` is `Ok` **iff** at least that many bytes remain (`result.isOk() ==
(old(this.remaining()) >= n)`), advances the cursor by exactly the bytes read on `Ok` and leaves it unchanged on
`Err`, and the value read equals the bytes at the old cursor (`readU16be` = `b0 * 256 + b1`, ...). Builder appends
grow the length by exactly the bytes appended and put the right bytes at the end. `slice` states its first and last
byte; `concat` states length and both seams. There are no bitwise operators in Orin, so multi-byte values use `*`,
`/` and `%` on `int`. `reserve` is bookkeeping (`capacity`): the runtime has no array reserve, arrays still grow
geometrically on `push`. A `u8` array element costs 8 bytes at run time (ADR-0022); strings are the compact form
(`toRawString` / `bytesFromString` are O(n) conversions, byte for byte, no validation).

### std:utf8

Orin strings are byte strings that are only *expected* to hold UTF-8; `Utf8String` makes it a type.

```
type Utf8ErrorKind = InvalidLead | TruncatedSequence | InvalidContinuation | Overlong | Surrogate | TooLarge
type Utf8Error = { position: usize; length: usize; kind: Utf8ErrorKind }
validate(b: Bytes): Result<Utf8String, Utf8Error>        validateString(s: string): Result<Utf8String, Utf8Error>   // O(n)
checkUtf8(s): Result<void, Utf8Error>   isValidUtf8(s): bool   utf8ErrorMessage(e)  encode(s: Utf8String): Bytes
isScalarValue(cp: int): bool   utf8Len(cp): int  @Requires(isScalarValue(cp))   encodeCodePoint(cp): Option<string>
fromCodePoints(cps: int[]): Option<Utf8String>

@Invariant(isValidUtf8(this.text))
class Utf8String                                          // new Utf8String(text) validates and traps on invalid input
  asString()  byteLength()  isEmpty()  toBytes()  codePointCount()  codePoints(): int[]  codePointAt(i): Option<int>
  isCharBoundary(i)  concat(o): Utf8String  trySlice(lo, hi): Option<Utf8String>   // slices only at boundaries
@Invariant(pos <= src.byteLength() && src.isCharBoundary(pos))
class CodePointCursor    hasNext()  position()  next(): Option<int>               // O(1) per code point
```

Validation is **table-driven** (Bjoern Hoehrmann's DFA: a 256-entry byte-class table and a 9-state transition table, kept
as string constants because Orin has no constant arrays; runs of ASCII bytes skip the tables), one pass, no allocation:
1 MB validates in about 1 ms (ASCII text 0.6 ms, mixed 1 ms, CJK 1.2 ms) against 22 / 16 / 9 ms for the earlier
per-sequence decoder (`scanSeq`), which is kept for the error path only: when the DFA rejects, `scanSeq` classifies the
first bad sequence (kind, length), and a contract on the DFA pass requires the two to agree at the reported offset.
`tests/std/utf8_dfa_test.or` is a differential test against an independent reference written from Table 3-7 as byte
ranges: exhaustive over all 1- and 2-byte inputs, every first byte with boundary bytes after it for 3 and 4 bytes, and
random longer inputs; verdict and error position must match. Decoding follows RFC 3629 / Unicode Table 3-7 exactly
(table in the source header): rejected are lone continuation
bytes and `F8..FF` (`InvalidLead`), `C0`, `C1`, `E0 80..9F`, `F0 80..8F` (`Overlong`), `ED A0..BF` (`Surrogate`), `F5..F7`
and `F4 90..BF` (`TooLarge`), cut-off sequences (`TruncatedSequence`) and a wrong continuation byte
(`InvalidContinuation`). Noncharacters (`U+FFFE`, `U+FDD0`...) are valid scalar values and accepted. `position` is the
byte offset of the first invalid sequence, i.e. the length of the longest valid prefix; `length` is the maximal invalid
prefix there (1..3). The constructor of `Utf8String` validates in **every** build (not only with contract checking),
so the invariant cannot be bypassed; `validate` therefore scans twice (O(2n)). `concat` of valid strings is valid;
`trySlice` answers `None` unless both ends are code point boundaries, so slicing cannot split a character. Tests
(`tests/std/utf8_test.or`) are hand-written vectors in the style of Markus Kuhn's UTF-8 decoder stress test: boundary
values, every continuation byte, every lead byte followed by a space, truncations, overlong forms of `/` and NUL,
the surrogate range and CESU-8 pairs, above `U+10FFFF`, impossible bytes, error positions, and an encode/decode
round trip over all code points up to `U+0898` and a stride through the rest.

### std:seq

```
range(lo: usize, hi: usize): usize[]          // lo, lo + 1, .., hi - 1; empty when hi <= lo
sum(xs: int[]): int                           // 0 for the empty array
sumBy<T>(xs: T[], f: (x: T) => int): int      // the sum of f over the elements
```

Pure functions (ADR-0031 A4), written for contracts: `range(1, xs.length).every(i => xs[i - 1] <= xs[i])` is "sorted",
`sum(this.balances) == old(sum(this.balances))` is conservation, `this.total == sumBy(this.items, it => it.price * it.qty)`
ties a total to its line items. Under `--check-contracts` they run as written (`range` allocates the index array, so a
quantifier over `n` indices costs O(n) per evaluation); `orin verify --contracts` does not run them, it reads
`range(a, b).every(..)` / `.some(..)` as a bounded quantifier and `sum` / `sumBy` as the recursive sum with the store lemma
(docs/contracts.md "Quantifiers and sums"). `sum` and `range` carry loop invariants and are proved by the verifier
itself; `sumBy` is generic and so outside the fragment. Tests: `tests/std/seq_test.or`, `tests/contracts/verify_quantifiers.or`,
`tests/next/run/contracts_quantifiers_seq.or`.

### std:collections

```
class IntSet / StringSet          // on Map; invariants: map size == key count, every stored flag true
  size() isEmpty() has(x) add(x): bool remove(x): bool clear() toArray()   // expected O(1); add/remove say whether the set changed
  isSubsetOf(o) union(o) intersection(o) difference(o)                       // O(n + m)
class Deque<T>                    // ring buffer, doubling from 4 slots, wrap by conditional subtraction; invariants:
                                  // len <= capacity, head in range, a filler value exists exactly when there is storage
  size() isEmpty() capacity() pushBack(x) pushFront(x) popFront() popBack() front() back() get(i) clear() toArray()   // amortised O(1)
class SortedMap<V>                // int keys: a B-tree in an arena; new SortedMap<V>(minDegree) with minDegree >= 2, use 16
class SortedStringMap<V>          // the same with string keys in compareStrings order (byte-wise lexicographic)
  size() isEmpty() height() has(k) get(k): Option<V> put(k, v): bool remove(k): Option<V>   // all O(t log_t n) = O(log n)
  firstKey() lastKey() floorKey(k) ceilKey(k)   popFirst() popLast(): Option<SortedEntry<V>>  keyArray() valueArray() clear()
class PriorityQueue<T>            // 4-ary min-heap in three parallel arrays; invariants: equal lengths, heap property (strict,
                                  // on (priority, insertion number)), every insertion number < the counter, which never decreases
  size() isEmpty() minPriority() peek() push(priority: int, value: T) pop(): Option<PQEntry<T>> allAtLeast(p) clear()   // push/pop O(log n)
```

Contracts: `add`/`put` return whether the key was new and the size grows by exactly 1 in that case (`result ==>
size == old(size) + 1`, `!result ==> size == old(size)`), `has(k)` holds afterwards; `remove` makes `has(k)` false and
shrinks the size by exactly 1 iff the key was present; `get` is `Some` iff `has`; `floorKey`/`ceilKey` return a present
key on the right side of `k` and, on `None`, the first/last key proves there is none; `popFirst`/`popLast` return
`old(firstKey())` / `old(lastKey())` and the remaining keys are strictly beyond it; `PriorityQueue.pop` returns the
priority `old(minPriority())`, shrinks the size by 1 and every remaining priority is `>=` it (`allAtLeast`), `push`
makes `minPriority` equal `min(priority, old(minPriority()))`; equal priorities leave first-in first-out. Deque pushes
grow the size by 1 and make the pushed end present, pops shrink it by 1 iff non-empty. Set operations state subset
relations (`union` contains both operands, `intersection` is contained in both, `difference` is disjoint from the
other and sizes add up).

**Algorithms, invariants and measurements** (single run, `cc -O2`, one 4-core machine under load; relative numbers matter):

| Structure | Algorithm | Invariants (checked after every public method) | Measured against the simpler version |
|---|---|---|---|
| `SortedMap`, `SortedStringMap` | B-tree of minimum degree t (CLRS: top-down insert that splits full nodes, top-down delete that borrows or merges so every node entered has >= t keys), nodes in an arena `nodes[]` addressed by index, a free list for merged nodes, no parent pointers: a plain copy-on-write value. Every operation including `floorKey`/`ceilKey`/`popFirst`/`popLast` is one root-to-leaf pass, O(t log_t n); iterative everywhere (explicit stacks) | keys sorted in each node and bounded by the separators above; every non-root node holds t-1..2t-1 keys (root <= 2t-1, inner root >= 1); all leaves at the same depth; size == number of keys; every node id in range and reached exactly once (no dangling or shared ids, no cycles); free list distinct, unreachable, and reachable + free == arena size; `height()` is logarithmic (`2 t^(h-1) - 1 <= n`) | 20,000 random inserts + lookups + removals: sorted array 1782 ms, B-tree t=4 76 ms, t=8 37 ms, **t=16 31 ms**, t=32 42 ms, t=64 52 ms. t=16 is the recommended degree. 200,000 operations of each kind: 758 ms. The sorted-array version is kept as `tests/std/spec_sorted.or`, the executable specification: `tests/std/sorted_btree_test.or` drives both with the same random operation sequences (degrees 2, 3, 5, 16, tiny and large key ranges, int and string keys) and requires identical answers for every operation |
| `PriorityQueue` | 4-ary implicit heap, struct of arrays (priorities, insertion numbers, values), hole-based sifting (one write per level), FIFO among equal priorities through the insertion number | equal array lengths; every entry leaves strictly before its up to four children (`isMinHeap4`); insertion numbers below a monotone counter | 200,000 random pushes + pops: boxed binary heap with swaps 300 ms, binary SoA hole 164 ms, **4-ary SoA hole 122 ms**, 8-ary 137 ms |
| `Deque` | ring buffer with doubling growth, wrap by conditional subtraction, no per-element allocation | `len <= capacity`, head in range, filler exists iff there is storage | 500,000 push/pop rounds: `Option<T>` slots with `%` 128 ms, **plain slots 84 ms** (see the gap below) |
| `IntSet`, `StringSet` | the prelude's open-addressing hash map (`Map<K, bool>`, expected O(1)); `union` copies the larger set and inserts the smaller, `intersection` walks the smaller and probes the larger | map size == key count, every flag true | reviewed: a hash set is the best known structure and the prelude map is already open addressing with an index table; no change |
| `Bytes`, `ByteBuilder`, `ByteReader` | views over one shared `u8[]` (O(1) slices, cursor reads without copying), geometric `push` growth | `start + len <= data.length`; `pos <= length`; `capacity >= length` | reviewed: `concat` by `push` loop 108 ms vs built-in `slice` + `concat` 104 ms for 20 x 1 MB (no gain), `equals` 1.9 ms/MB, `bytesFromString` 1.2 ms/MB, `toRawString` 6 ms/MB (one 1-byte string per byte: see the gap below); no change |
| `std:utf8` | Hoehrmann DFA + ASCII runs (see above) | `Utf8String`: `isValidUtf8(text)`; cursor: position on a code point boundary | 1 MB: DFA 0.6 / 1.0 / 1.2 ms (ASCII / mixed / CJK) vs decoder 22 / 16 / 9 ms |

### Limitations of this layer (language friction, honest list)

* `Map<K, V>` needs a *concrete* key type (`int`, `usize`, `bool`, `string`; E0400 for a type parameter) and a type
  parameter has no `==`, `<` or hash (E0410). So there is no generic `Set<T>` or `SortedMap<K, V>`: the sets and maps are
  specialised by key class (`IntSet`/`StringSet`, `SortedMap<V>`/`SortedStringMap<V>`); `Deque<T>`, the values `V` and the
  queue elements `T` are generic.
* The same missing `==` on type parameters means the contracts of the generic containers cannot say "the value that
  comes back is the one that was put in" (`get` after `put`, the popped element is the pushed one); they state sizes,
  membership, key/priority order and presence. The tests check the values on `int` and `string` instances and against
  naive reference models on pseudo-random operation sequences.
* A contract cannot call a function value (E0416), so a comparator closure stored in a class could not appear in the heap
  invariant: `PriorityQueue<T>` takes an explicit `int` priority until the Eq/Ord ADR lands. A `T extends Ranked`
  interface would do for ordered classes, but cannot cover `int`/`string` without wrapper classes.
* **Tooling gaps found while applying the algorithm rule** (feed ADR-0031 A and the Eq/Ord/Hash constraints ADR):
  1. no equality/ordering/hash on type parameters (E0410, E0400 for `Map<K, _>`): no generic `Set<T>`, `SortedMap<K, V>`,
     comparator queue; the B-tree needed a code generator to exist for two key types; contracts cannot say "the same
     value comes back";
  2. no uninitialised or default value for a type parameter (a `MaybeUninit`/`default<T>()` or a `T[]` with capacity):
     the ring buffer must either box every slot in `Option<T>` (statable invariant "exactly the live slots are Some",
     but an allocation per element) or hold a filler value in dead slots (fast, the invariant cannot name the dead slots);
  3. no constant arrays or tables (top-level `const` must be a literal, E0408): the DFA tables are string constants read
     with `charCodeAt`;
  4. no bulk byte primitives: ~~no `u8[]` <-> string conversion~~ (now `bytesToString` / `stringToBytes`, docs/benchmarks.md fix 3), no array `reserve`/capacity,
     no `memcmp`/`memchr`-style search, no bitwise operators or shifts (so no power-of-two masks and no bit-parallel
     validators), no `slice` view type that avoids the array header;
  5. contracts cannot call a function value, so comparator-based structures cannot state their invariants;
  6. generic *contract helpers over records of a generic type* work (`btreeIntShapeOk<V>`), but a recursive structure has to
     be an arena with indices plus explicit-stack loops: there is no termination measure checking for loops
     (`@Decreases` is only type-checked) and `orin verify --contracts` proves only some of these clauses (arrays, classes and
     loops are in its fragment since ADR-0036, but loop invariants and recursive structures are mostly missing; counts in
     docs/assurance.md), so most invariants here are run-time checks (tests, `--check-contracts`), not proofs;
  7. a mutating method cannot be called inside `&&`/`||`/`?:` or on a temporary (E0408/E0401), and `private constructor` is
     rejected (E0411).
* There are no private constructors (`private constructor` is rejected with E0411), so `Bytes` and `Utf8String` have public
  constructors whose requirements are checked: `Bytes` by `@Requires` (a violation is still memory safe: every access is
  bounds checked), `Utf8String` by always-on validation, the B-tree maps by `@Requires(minDegree >= 2)`.
* No bitwise operators or shifts (multi-byte integers use `*`, `/`, `%`); no array `reserve`; a `u8` array element
  occupies 8 bytes; `@Test` has no "expected trap" form (`tests/std/expect_trap/` and `tools/test_std.sh` fill that gap).
* Mutating methods cannot be called inside `&&`, `||` or `?:` (E0408), nor on a temporary (E0401): `let r = new ByteReader(b);`.

## std:http (ADR-0030 §3, layer "protocols"): the pure message layer of HTTP/1.1

`std:http` is the **pure** part of HTTP/1.1 (RFC 9110, RFC 9112): message types, an incremental **request parser**, an
incremental **response parser** and a **serializer**, all over `std:bytes`. No sockets, no I/O, no grants, no L0 change:
the module imports nothing but `std:bytes` and has no grant parameter, so it performs no I/O: the purity inference of ADR-0031 A4 confirms it, because the serializers call the parser inside an `@Ensures` and E0416 would reject an impure function there. The network
part (`std:net`, a server loop) follows ADR-0033 and only has to move bytes in and out of these functions.

**Request smuggling.** Two parsers on one path that disagree about where a message ends or what a header says are the
root of request smuggling and response splitting (RFC 9112 §6.3, §11.2, §11.3). This module refuses every such
ambiguity instead of guessing, with a distinct reason and the byte position (table below), so a front end and a back
end built on it cannot be driven apart by `Content-Length` + `Transfer-Encoding`, a duplicate or non-numeric length,
`Transfer-Encoding : chunked`, obs-fold, a bare LF or CR, or a chunk size that overflows. Header injection is
impossible by construction: `Headers` validates names and values in its constructor and in `add`/`set`, and the
serializer can only write a `Headers`.

### API

```
// types
type HttpVersion = Http10 | Http11
type Method = Get | Head | Post | Put | Delete | Connect | Options | Trace | Patch | Ext(string)   // Ext: any other token
type HttpError = { position: usize; reason: HttpReason; message: string }      // 34 reasons: BadMethod ... UnexpectedEof
type ParseResult<T> = NeedMore | Done(T, usize) | Failed(HttpError)             // Done(message, bytes of THIS chunk used)
class Headers      // invariants: names are tokens, values contain no CR/LF/NUL/other control, no leading/trailing blank
  new Headers(names: string[], values: string[])      // validates in EVERY build (traps)
  count()  nameAt(i)  valueAt(i)  countOf(n)  has(n)  get(n): Option<string>  getAll(n): string[]   // names case-insensitive
  add(n, v): Result<void, HeaderError>  set(n, v)  remove(n): usize  equals(o)                       // add/set validate first
class Status       // invariant: 100 <= code <= 599, reason phrase has no CR/LF/NUL
  new Status(code, reason)  code()  reason()  hasNoBody()  equals(o);   standardStatus(code)  makeStatus(code, reason)
class Request      // invariant: requestProblem(...) == "" (valid method and target, one Host on HTTP/1.1, unambiguous
  new Request(method, target, version, headers, body: Bytes, trailers)  // framing that matches the body); traps otherwise
  method() target() version() headers() body() trailers() isChunked() equals(o);   makeRequest(...): Result<Request, string>
class Response     // invariant: responseProblem(...) == "" ; forHead = response to a HEAD request
  new Response(status, version, headers, body, trailers, forHead)  status() version() headers() body() trailers()
  isBodyless() isForHead() isChunked() equals(o);   makeResponse(...): Result<Response, string>
// limits
class Limits       // new Limits(maxStartLine, maxHeaderCount, maxHeaderLine, maxHeaderBytes, maxChunkLine, maxBody); defaultLimits()
// incremental parsers (state machine, see below)
class RequestParser   { new RequestParser(limits)  feed(chunk: Bytes): ParseResult<Request>  atEof()  reset()
                        isIdle() isDone() isFailed() consumed() stateName() }
class ResponseParser  { new ResponseParser(limits, forHead)   feed(chunk): ParseResult<Response>  atEof()  reset() ... }
parseRequest(data, limits)  parseResponse(data, limits, forHead)  parseResponseToEof(data, limits, forHead)   // one-shot
// serializer: parse(serialize(m)) == m
serializeRequest(r): Bytes   serializeRequestChunked(r, chunkSize)   serializeResponse(r)   serializeResponseChunked(r, chunkSize)
// helpers
methodName  methodFromToken  isToken  isFieldValue  isReasonPhrase  isHostValue  isValidTarget  parseContentLength  eqIgnoreCase
requestProblem  responseProblem  headerErrorMessage  reasonName  reasonText  stateName  edgeAllowed  hexString
```

```ts
import { RequestParser, Done, NeedMore, Failed, defaultLimits, methodName } from "std:http";
let p = new RequestParser(defaultLimits());
match (p.feed(bytesFromString("GET /a HTT"))) { NeedMore => ..., Done(q, used) => ..., Failed(e) => ... }  // NeedMore
match (p.feed(bytesFromString("P/1.1\r\nHost: h\r\n\r\nGET /b"))) {
  Done(q, used) => { /* q is GET /a; the chunk's remaining bytes (from `used`) start the next message */ p.reset(); }
  ...
}
```

### Incremental contract

`feed(chunk)` accepts bytes in **arbitrary chunks** (as `recv` delivers them). `NeedMore`: every byte of the chunk was
consumed into the parser state. `Done(message, used)`: the message is complete after `used` bytes of *this* chunk; the
rest of the chunk is the start of the next pipelined message (`reset()` first). `Failed(e)`: refused; the parser is
sticky-failed until `reset()`. A partial message is never returned as complete, a message split anywhere (every byte
position, 1-byte chunks, random and empty chunks) gives the identical result (same kind, same total, same error
reason and position, same message: `tests/std/http_split_test.or`). Error positions are 0-based offsets from the first
byte of the message: the offending byte; for a limit the first byte over it; for a rule over a whole line (duplicate
field, `Content-Length` syntax, `Host`) the first byte of that line; for rules over the whole head (both
`Content-Length` and `Transfer-Encoding`, missing `Host`, body limit of a `Content-Length`) the CR of the empty line;
for a request-target shape error the first byte of the target. `atEof()` (the peer closed the connection): `Done` for a
response whose body is delimited by the close (no `Content-Length`, no chunking, RFC 9112 §6.3 rule 8), otherwise
`Failed(UnexpectedEof)` at the number of bytes received; `isIdle()` tells a clean close between messages from a cut-off
one. A response to a HEAD request (`forHead`), and every 1xx, 204 and 304 response, has no body whatever its headers say.

### Limits (parameters, `@Requires` and class invariants of `Limits`)

| Parameter | Default | Range | Error at the first byte over it |
|---|---|---|---|
| `maxStartLine` (request line / status line) | 8192 | 16 .. 1 MiB | `StartLineTooLong` |
| `maxHeaderCount` (header fields; trailer fields separately) | 100 | 1 .. 65536 | `TooManyHeaders` |
| `maxHeaderLine` (one header line, without CRLF) | 8192 | 16 .. 1 MiB | `HeaderLineTooLong` |
| `maxHeaderBytes` (start line .. empty line; the trailer section separately) | 65536 | 64 .. 64 MiB | `HeadersTooLarge` |
| `maxChunkLine` (chunk-size line incl. extension) | 1024 | 8 .. 65536 | `ChunkLineTooLong` |
| `maxBody` (decoded body) | 1 MiB | 0 .. 2^40 | `BodyTooLarge` |

The upper ranges are chosen so that the chunk-size arithmetic `size * 16 + 15` can never overflow: a chunk size is
checked digit by digit against the remaining body allowance, so `FFFFFFFFFFFFFFFF` is refused at the sixth digit.

### Rules enforced (reason name, RFC section)

| Rule | Reason | RFC |
|---|---|---|
| bare LF or bare CR where CRLF is required (start line, header lines, chunk lines, chunk end, trailers) | `BareLf`, `BareCr` | 9112 §2.2 |
| obs-fold (a header line starting with SP or HTAB), also after the request line | `ObsFold` | 9112 §5.2 |
| whitespace between a field name and the colon; missing colon; empty or non-token name | `SpaceBeforeColon`, `MissingColon`, `BadHeaderName` | 9112 §5.1 |
| NUL, DEL or any other control character in a field value, reason phrase, chunk extension | `BadHeaderValue`, `BadStatusLine`, `BadChunkExtension` | 9110 §5.5 |
| invalid method token; a single SP between the three parts; `HTTP/1.0` and `HTTP/1.1` only | `BadMethod`, `BadTarget`, `BadVersion`, `UnsupportedVersion` | 9112 §3 |
| request-target shape: origin-form, absolute-form, `*` only for OPTIONS, authority-form only for CONNECT; only 0x21..0x7E, no fragment | `BadTarget` | 9112 §3.2 |
| status code: exactly three digits, 100..599 | `BadStatusCode`, `BadStatusLine` | 9112 §4 |
| `Content-Length` and `Transfer-Encoding` together | `ContentLengthWithTransferEncoding` | 9112 §6.3 |
| duplicate `Content-Length` (even equal values), a list, a sign, hex, more than 18 digits | `DuplicateContentLength`, `BadContentLength` | 9112 §6.3 |
| `Transfer-Encoding` other than exactly `chunked`, a duplicate, on HTTP/1.0 | `UnsupportedTransferEncoding`, `DuplicateTransferEncoding` | 9112 §6.1 |
| `Content-Length` / `Transfer-Encoding` in a 1xx or 204 response | `ForbiddenFraming` | 9110 §8.6 |
| chunk size: empty, not hexadecimal (`-1`, `+5`, `0x5`), overflowing the body limit; chunk not followed by CRLF | `BadChunkSize`, `BodyTooLarge`, `BadChunkTerminator` | 9112 §7.1 |
| chunk extensions are skipped (control characters refused); trailers parsed with the same field rules, not merged into the headers, framing fields (`Content-Length`, `Transfer-Encoding`, `Trailer`, `Host`) refused | `ForbiddenTrailer` | 9110 §6.5.1 |
| an HTTP/1.1 request needs exactly one valid `Host` | `MissingHost`, `DuplicateHost`, `BadHost` | 9112 §3.2 |

Deliberately stricter than the RFC where leniency is only a smuggling risk: no leading empty lines before the request
line (`BadMethod` at byte 0), no repeated `Content-Length` even if the values are equal, no transfer coding but
`chunked`, no raw non-ASCII bytes in the request-target.

### Serializer and the round-trip contract

`serializeRequest(r)`, `serializeResponse(r)` (and the `...Chunked(r, chunkSize)` forms) write the start line, the
fields in order, the empty line and the body (`Content-Length`/close-delimited bodies as they are, chunked bodies as
chunks of at most `chunkSize` bytes with the trailers). They add or change nothing: the framing already is
consistent with the body, because `Request` and `Response` enforce that in their constructor and invariant
(`requestProblem`, `responseProblem`). **Round-trip contract** (an `@Ensures` of each serializer, checked by `orin
test` on every call): the parser accepts the output, with limits that fit it, and returns a message equal to the
input, `parse(serialize(m)) == m`. A bodyless response (HEAD, 1xx, 204, 304) is written without body bytes.
`tests/std/http_prop_test.or` also checks the output byte for byte against a naive string-building reference
serializer and the round trip for random messages (1000), random chunk sizes and 1-byte and random input chunking.

### State machine and contracts

The parser is a table of 23 explicit states (`stateName`): `METHOD TARGET VERSION CODE REASON START_LF HDR_LINE HDR_NAME
HDR_OWS HDR_VALUE HDR_LF HEAD_END_LF BODY CHUNK_SIZE CHUNK_BWS CHUNK_EXT CHUNK_SIZE_LF CHUNK_DATA CHUNK_CR CHUNK_LF
BODY_CLOSE DONE ERROR` (the diagram is at the top of `stdlib/http.or`). The transition relation is the function
`edgeAllowed(src, dst)`; every state change goes through one private method that `@Requires` the edge, so a checked
build traps on a transition that is not in the diagram. The class invariant ties state to data (the state is one of the
23; `ERROR` iff an error is stored; header lists parallel and within the count limit; line length within its limit;
bytes consumed within the header budget while in the head; at most one `Content-Length`, `Transfer-Encoding` and
`Host` seen; pending body bytes only in a body state; `BODY` has Content-Length framing; a response parser never in
`METHOD`/`TARGET`). Every step has `@Ensures` progress (the cursor moves or the parser fails), which is the
termination argument of `feed`.

### Algorithm and measured throughput

One forward pass, no backtracking, no look-ahead, no regular expressions. Bytes are classified by a 256-entry table
(`HTTP_CLASS`: control, LF, CR, HTAB, SP, obs-text, other VCHAR, `:`, `;`, token symbol, letter, hex letter, digit,
numbered so that "token character" is `class >= 10` and "may occur in a field value" is `class >= 3`) and a
256-entry hex-value table; Orin has no constant arrays or bitwise operators, so both are string constants read with
`charCodeAt`, like the DFA tables of `std:utf8`; `tests/std/http_test.or` recomputes every entry from the RFC
character sets. Runs of ordinary bytes (a method, a name, a value) are scanned in a tight loop, converted to a string
once per token and handled once per run; the state changes once per token. Bodies are never copied byte by byte: a body
that arrives in one chunk is a slice of the input (O(1)). The scanner reads the input through a 4096-byte window
(`chunk.slice(w, we).toArray()`): indexing a `u8[]` is two orders of magnitude cheaper than calling `Bytes.at` per byte.

Contract counts (`stdlib/http.or`, 2977 lines): 34 `@Invariant`, 49 `@Requires`, 131 `@Ensures`.

Throughput (`tests/std/bench/http_bench.or`, production build without contract checks, 1 MB = 1048576 bytes; corpus: a
763-byte browser GET with 15 headers and a 160-byte cookie, a curl GET, a 544-byte JSON POST with a bearer token, a
725-byte chunked PUT with a trailer; 4 cores shared with other workers, so read the numbers as indicative):

| Workload (production build) | Messages | MB/s | Messages/s |
|---|---|---|---|
| browser GET (763 B, 15 headers), one chunk | 20,000 | 55.7 | 76,000 |
| curl GET (83 B), one chunk | 50,000 | 29.7 | 376,000 |
| JSON POST with bearer token (544 B), one chunk | 20,000 | 68.7 | 132,000 |
| chunked PUT with trailer (725 B), one chunk | 20,000 | 79.0 | 114,000 |
| **mixed corpus, one chunk** | 40,000 | **61.8** | 123,000 |
| mixed corpus, 64-byte chunks | 20,000 | 44.4 | 84,000 |
| mixed corpus, 1-byte chunks (worst case) | 2,000 | 1.3 | 2,400 |
| response 200 with 512-byte body | 20,000 | 110.8 | 120,000 |
| serialize the JSON POST | 20,000 | 126.5 | 247,000 |

With contract checking (`--check-contracts`: every invariant after every public method, the round-trip contract of
the serializer) the parser reaches 20-33 MB/s (23 MB/s mixed) and the serializer 4 MB/s, which is why the build used
for deployment is the unchecked one and the tests run both. Before the window and `void`-step rewrite the same corpus
ran at 26 MB/s.

What the numbers are made of (gprof of the generated C): about a quarter of the time is building the strings of names,
values and the target (before the built-in `bytesToString`: one `String.fromCharCode` + append per byte, 7 ns; since then one runtime copy), a tenth the
copy of the window, the rest scanning, the validation that makes `Headers`/`Request` valid by construction (the parser
output goes through the same constructors as user code) and allocation. Two measured facts about the object model shaped
the code: a *mutating method with a result* allocates a pair `(this, result)` per call (the first version, with
`advance(): usize` steps, spent half its time there, 26 MB/s; steps that return `void` and leave the cursor in a field
gave 2x), and `s = s + t` on a field copies while `s += t` appends in place (100,000 one-byte feeds: 275 ms against 1 ms).

### Tests

`tests/std/http_test.or` (24 `@Test`: character classes against the RFC sets, methods, targets, `Headers`, `Status`,
construction rules, valid messages, chunk extensions, trailers, pipelining, reset), `http_reject_test.or` (32: every
rejection with its reason and position, the smuggling vectors CL+TE, duplicate and conflicting `Content-Length`,
`Transfer-Encoding :`, obs-fold, chunk-size overflow, negative and overlong chunk sizes, all limits, responses, EOF,
the state machine API), `http_split_test.or` (9: 62 request and 24 response messages, valid, invalid and
partial, fed one-shot, split at every byte position, in 1-byte and random chunks, plus messages larger than the
scanner window), `http_prop_test.or` (7: serializer round trip and differential test against a naive serializer,
differential test of the parser against an executable specification, `refRequest`, on random messages and on mutations,
and the fuzz harness). **Fuzzing**: 20,000 random mutations of valid requests (flip, insert, delete, duplicate, swap,
truncate, special bytes, CRLF to LF/CR, whitespace around the colon), 10,000 of responses and 10,000 random garbage inputs;
none may trap, the parser and the specification must agree on accept and refuse, one-shot and random chunking must
agree, and everything accepted survives parse, serialize, parse unchanged. Five more tests in `tests/std/expect_trap/`
must trap in every build (constructors of `Headers`, `Status`, `Request`, `Response`, `Limits`).
`tools/mutate_std.py --module http`: 41 mutants of the parser, rules, limits, serializer and constructors, all killed
(`41 mutants, 41 killed with contracts on: 18 by a contract violation, 23 by tests; 34 of them are also killed without contracts by the first test file that kills them, 5 by the trap tests of the constructors (which run without contracts by design), and 2 (`reset` keeping its error, `consumed` counting the chunk) only show up in that file as contract violations`).

### Not covered

HTTP/2 and HTTP/3, TLS, sockets and every other I/O (ADR-0033), content codings (`gzip`, `Transfer-Encoding` other than
`chunked`), `Expect: 100-continue` and interim-response handling (a 1xx response is returned as a response; the caller
resets the parser), `Upgrade`/CONNECT tunnels (the response to CONNECT is not special-cased), `Connection` and
keep-alive decisions, URI parsing beyond the shape of the request-target, cookies, caching and every header semantic
other than framing and `Host`, streaming bodies (a body is collected, up to `maxBody`), and proofs: the contracts are
checked at run time and by tests; `orin verify --contracts` does not cover strings, arrays, classes or loops (ADR-0031 B).

### Friction found (language and tooling)

* Mutating methods that returned a value allocated a result pair per call (and copied a receiver held in a field); fixed in the
  optimiser (in/out receivers, docs/mir.md v1.10: 8-13x on a call loop, http_parse 2x). The hot path still uses `void` methods and a
  cursor field, which is no longer necessary. `s = s + t` on a field is now an in-place append as well. A big class with nested mutating calls and no private constructors forced the shape of `MessageParser`.
* No constant arrays (tables are string constants), no bitwise operators (class codes are ordered so ranges replace
  masks), no `u8[]` capacity (the bulk bytes-to-string primitive exists since the performance pass: `bytesToString`, `stringToBytes`).
* Orin values are copied, so a random number generator or any other stateful helper must be one class whose methods
  mutate `this`; a helper function cannot advance the caller's generator.
* Top-level `const` must be a literal (no `+` of two strings); `from` is a keyword (a parameter named `from` is an error);
  a mutating call is not allowed inside `&&`, `||`, `?:` or a `while` condition.
* The result variant is `Failed`, not `Err`, because `Err` is the constructor of `Result` and a module that uses both
  could not tell them apart.
* A constructor of a class with an invariant must check in every build (`enforce`), because `@Requires` is erased
  without `--check-contracts` and there are no private constructors; the guards that run in every build are loops
  (`allTokens`, `allFieldValues`: a closure call per element is too slow on the parser's hot path), while the clauses use
  `every`/`some`/`filter` now that ADR-0031 A has landed (`Headers.has`, `countOf`, `getAll`).
* The round-trip contract calls the parser inside an `@Ensures`; that is allowed because the parser is pure, but the
  checked build then parses every serialized message once more.

## std:net (ADR-0033): blocking TCP

```ts
import { Host, useNet } from "std:host";
import { useListener, useAccepted, useConnection, useListen, useConnect, recv, sendAll, StreamReader, resolve } from "std:net";

function main(host: Host): void {
  useNet(host, net => {                                    // the root NetGrant (ORIN_DENY=net: every operation refused)
    useListen(net, "127.0.0.1", 8080, l => {               // narrowed: may listen on exactly 127.0.0.1:8080
      useListener(l, "127.0.0.1", 8080, 64, ln => {        // Err(NetError) if refused, in use, ...
        useAccepted(ln, 1000, (s, peer) => {               // Err(timeout) if nobody came within 1 s
          const r = recv(s, 4096, 1000);                   // RecvData(Bytes) | RecvEof | RecvTimeout | RecvReset | RecvError
          sendAll(s, ..., 1000);                           // all bytes, whole-call deadline
        });
      });
    });
    useConnect(net, "*.example.com", 443, 443, c => {      // narrowed: only names below example.com, port 443
      useConnection(c, "api.example.com", 443, 2000, s => { ... });
    });
  });
}
```

| Function | Meaning |
|---|---|
| `useNet / withNet(host, body)` (`std:host`) | the root `NetGrant` (may listen and connect anywhere the host policy allows) |
| `useListen / withListen(net, addr, port, body)` | narrowed grant: listen on exactly `addr:port` (an address literal; port 0 = any) |
| `useConnect / withConnect(net, hostPattern, portLo, portHi, body)` | narrowed grant: connect to / resolve names matching `"*"`, `"*.sfx"` or an exact text, on those ports |
| `useListener / withListener(net, addr, port, backlog, body: (Listener) => ..)` | bind (SO_REUSEADDR), run body, close; `Err(NetError)` |
| `useAccepted / withAccepted(ln, timeoutMs, body: (Stream, Peer) => ..)` | accept (TCP_NODELAY), run body, close the stream; `Err` on timeout (`isTimeout`) |
| `useConnection / withConnection(net, host, port, timeoutMs, body: (Stream) => ..)` | connect, run body, close |
| `useListenerNet`, `useConnectionBeside` | variants whose body also receives the `NetGrant` / the `Listener` again (a closure cannot capture a handle): client and server in one process |
| `recv(s, maxBytes, timeoutMs): RecvResult` | one wait, 1..min(maxBytes, 64 KiB) bytes, one copy into a fresh `u8[]` (never one string per byte) |
| `send(s, data, timeoutMs)` / `sendAll(s, data, timeoutMs)` | one attempt (partial write reported) / all bytes, deadline for the whole call |
| `shutdownWrite(s)` | half-close (FIN); a graceful close is this, a bounded drain with `recv`, then the scope ends |
| `StreamReader(cap)`: `readExact(s, n, ms)`, `readUntil(s, delim, limit, ms)`, `readSome`, `buffered`, `unread`, `take` | read-ahead buffer next to the stream (a stream cannot be stored); results `Filled | FillClosed | FillLimit | FillTimeout | FillError`; at most `cap` bytes are ever buffered, `readUntil` receives at most `limit - buffered` bytes at a time; the ms is a deadline for the whole call |
| `nowMillis(s)` | monotonic clock via a live stream (deadlines without a clock grant) |
| `resolve(net, name): Result<string[], NetError>` | numeric addresses; the grant's scope must cover `name` |
| `Peer { host, port }`, `portOf(ln)`, `isDenied / isTimeout / isReset(e)` | values |

**Security properties.** *Statically* (checker, MIR verifier): every network function needs a `NetGrant` / `Listener` /
`Stream` first (E0470 missing, E0471 wrong family; this now holds for any function whose first parameter is a grant);
`Listener` and `Stream` are resources: not storable, copyable, returnable or capturable (E0450-E0452), closed on every path
(verifier); the raw primitives are in the internal `std:fsraw` (E0301). *At run time* (L0 checks before any system call,
CBMC-verified: recv / send buffer bounds, narrowing never widens, refusal before any syscall): handle identity (magic, kind,
live), `ORIN_DENY=net`, the scope of the grant (listen address and port, connect host pattern and port range), mandatory
timeouts (0..3,600,000 ms), partial writes reported, `recv` never writes past its capacity (and the runtime clamps it to
64 KiB), no `SIGPIPE`; the runtime traps on a forged, stale, closed or wrong-kind handle. *Not at all:* DNS rebinding (the
scope is checked against the host text the program supplies), the OS resolver's own timeout, bandwidth, number of
connections, a process that bypasses the runtime (native code, ADR-0021 "Native threat model"), TOCTOU on the host's
networking configuration.

**Server demo** (`examples/http_server.or`, `tools/test_net.sh`): `GET /health`, `POST /echo`, request limits (line 2048,
50 headers, head 16 KiB, body 64 KiB), a deadline for the whole request, idle and send timeouts, 100 requests per
connection, graceful close after an error answer. It listens on loopback only through a grant narrowed to that address.
One connection at a time (no tasks, ADR-0017): a slow client holds the server until a deadline passes. Indicative
throughput on the loopback, one keep-alive connection, sequential requests from a Python client: about 20,000 requests/s
(single core, verbose logging on).

### What a server needs from ADR-0033 (all of it is now provided; this was the list that shaped the API)

The parser and serializer are transport-agnostic: a server loop is `recv` -> `feed` -> handle -> `serialize` -> `send`.
What ADR-0033 provides is enough to do that *correctly*; what it lacks to do it *well* and *safely*:

1. **A bulk path from the L0 receive buffer to `Bytes`.** `recv(stream, buf, cap, timeout_ms, out_len)` fills a C
   buffer; `std:net` must turn it into a `Bytes` without a per-byte loop. Today a `u8[]` can only be built by `push`
   (about 8 ns per byte, a third of the parser's own cost) and an element takes 8 bytes. Needed: an L1 primitive
   "new `u8[]` / `Bytes` from the first `len` bytes of a raw buffer" (one `memcpy`), and the reverse for `send`
   (`Bytes` slice `[off, off+len)` to the L0 buffer, so partial writes resend the tail without copying the rest).
2. **A tagged receive result**: `Data(n)` | `Eof` (orderly close, 0 bytes) | `Timeout` | `Reset`/error. `atEof()` must
   be called on `Eof` only; a timeout is not an end of message (the server answers 408 or closes).
3. **A monotonic clock and a deadline for the whole head.** Per-call timeouts do not stop a slowloris client that
   sends one byte per `timeout - 1` ms; the limits of `std:http` bound bytes, not time. The server needs a monotonic
   clock (`std:time.nowMillis` is the wall clock) or a `recv` variant that takes an absolute deadline, to cut off a
   request whose head or body is not complete within a total budget; also an idle timeout between pipelined
   messages (`isIdle()` tells a clean close from a cut-off one).
4. **Half-close.** `net_close` alone makes the OS send RST when unread request bytes remain, which can discard the
   response (for example the `413`/`400` sent after a refused message). A graceful close needs
   `shutdown(stream, write)` then a bounded drain then `close`: one more L0 function.
5. **Per-connection scope with resources.** Streams are resources (ADR-0025: not storable, not capturable), so the
   server is `acceptEach(listener, timeout, (stream) => ...)` with the `RequestParser`, a normal value, living beside the
   stream inside the callback. The listener grant should narrow to `addr:port` as in the ADR; the accepted stream
   should carry the peer address as a value (for logs and `Forwarded` checks).
6. **One connection at a time until ADR-0017 lands**: a slow client blocks every other, so the first server is only
   safe behind the timeouts of items 3-4; keep-alive needs an idle timeout shorter than the header deadline.
7. **Socket options in `tcp_listen`**: `SO_REUSEADDR` on by default, `TCP_NODELAY` per stream, a backlog parameter
   (already in the ADR). `Expect: 100-continue` only needs `send` before the body is read, but then the parser must
   hand back the head before the body: a streaming/head-only mode of `std:http` (a follow-up of this module, not an
   L0 change), which large uploads need as well (today a body is collected up to `maxBody`).
8. **TLS later** only needs the same two byte interfaces (`Bytes` in, `Bytes` out): the parser does not change.

None of this changes `std:http` itself; items 1, 3 and 4 are L0/L1 additions (about 40 lines of C with contracts), the
rest is `std:net` design.

## std:ox: the OX provider protocol

`std:ox` (`stdlib/ox.or`) holds only types: `Markup<R>` (a provider that serialises markup to text: `wrap`, `embed`,
`embedAll`, `text`, `attr`, attribute `rules`, the static `escapes` table, `voidTags`, `voidEnd`, `rawTextTags`,
`presenceAttrs`), `Components<R>` (a provider that builds values: `fragment`, `text`), `AttrRule` and `Escape`. A provider
module exports `function ox()` returning one such literal; the compiler reads it (ADR-0044, docs/ox.md).

## std:html: escaping and rendering for OX

`std:html` (`stdlib/html.or`, pure Orin, no platform calls) is the HTML provider of OX (ADR-0044): `import ox from
"std:html";` selects it, and its `ox()` literal holds every HTML rule (escape table, void and raw-text elements, URL and
event attributes). Markup compiles to calls of the functions below, and the only way to put a `string` into HTML is
through them. `Html` is *rendered, trusted HTML* and `@Sealed`: only OX, `trustHtml` and this module construct it (the
compiler rejects the record literal `Html { .. }` and an assignment to `.html` outside the module), so text from the
outside can reach the page only escaped, and raw markup is always a visible `trustHtml(...)` call.

### API

| Function | Result |
|---|---|
| `type Html = { html: string }` | rendered, trusted HTML |
| `escape(s): string` | `& < > " '` become `&amp; &lt; &gt; &quot; &#39;`; every other byte is copied unchanged |
| `safeUrl(s): string` | `s`, or `"about:invalid#orin-unsafe-url"` when `s` has a scheme other than `http`, `https`, `mailto`, `tel` |
| `escapeUrl(s): string` | `escape(safeUrl(s))`: a URL as a quoted attribute value |
| `joinAll(xs: Html[]): string` | the concatenation of `x.html` (children from `{items.map(..)}`), in one accumulating string |
| `trustHtml(raw): Html` | raw HTML, **not** escaped: the explicit, auditable escape hatch |
| `text(s): Html` | `Html { html: escape(s) }` |
| `empty(): Html`, `fragment(xs): Html` | no markup; several elements one after the other |
| `render(h): string`, `document(h): string`, `isEmpty(h): bool` | `h.html`; `"<!DOCTYPE html>" + h.html`; `h.html == ""` |
| `needsEscape(s)`, `hasSafeScheme(u)`, `isSafeUrl(u)` | predicates used by the contracts (exported so that they can be tested and used in other contracts) |

`ox()` names `trustHtml`, `render`, `joinAll`, `escape` and `escapeUrl` as the provider functions (`wrap`, `embed`,
`embedAll`, `text` / `attr`, the URL rule); the first three are `@Inline`.

### Escaping

`escape` covers HTML **text** and **quoted attribute values** (double or single quotes). The five characters are ASCII,
so UTF-8 multi-byte sequences never contain them and are copied byte for byte. `escape` is not idempotent on purpose
(`&amp;` becomes `&amp;amp;`): it is applied exactly once, when a string becomes `Html`. When `s` contains none of the
five characters `escape` returns `s` itself after one scan (no allocation, the common case); otherwise it copies the runs
between the special characters with `substring` and appends the entities, so the work is O(n) and the number of
allocations does not depend on the number of special characters.

### The URL rule

URL-valued attributes (`href`, `src`, `action`, ...) are a second context: `javascript:` is harmless in text and
dangerous in `href`. `safeUrl` applies the rule of Go's `html/template`: if `s` contains a `:` that comes before any `/`,
`?` or `#`, the text before it, ASCII-lowercased, must be exactly `http`, `https`, `mailto` or `tel`; otherwise the result
is the constant `about:invalid#orin-unsafe-url`. A URL without such a `:` is relative and returned unchanged (`/a:b`,
`?q=a:b`, `#frag:x`). The check compares the *whole* scheme text, so ` javascript:`, `java\tscript:` and `\x01javascript:`
are rejected (a browser strips such characters and would run them), and so are `data:`, `vbscript:`, `file:` and the empty
scheme `:x`. `safeUrl` does not escape: use `escapeUrl` for the attribute value.

### Contracts

Every exported function has `@Ensures`; the executable ones (checked by `orin test`, trapping on violation):

* `escape`: the result contains none of `<`, `>`, `"`, `'`; `result.length >= s.length`; `!needsEscape(s) ==> result == s`;
  `needsEscape(s) ==> result.length > s.length`.
* `safeUrl`: `result == s || result == "about:invalid#orin-unsafe-url"`; `isSafeUrl(result)`;
  `hasSafeScheme(s) ==> result == s`; `!hasSafeScheme(s) ==> result` is the constant. `escapeUrl`: equals `escape(safeUrl(s))`,
  so it contains none of `<>"'` either.
* `joinAll`: empty gives `""`, one element gives its `html`, and the result starts with the first and ends with the last
  element (so no element is skipped at the ends). `text`, `trustHtml`, `fragment`, `render`, `document`, `isEmpty`: the
  equation of the table above.

### Tests

`tests/std/html_test.or` (18 tests; with and without contract checks): every function; edge cases of `escape` (empty,
only specials, specials first, last and adjacent, UTF-8 around a special, long strings); the URL rule (upper and mixed case
schemes, relative URLs with a `:` after `/`, `?` or `#`, leading whitespace and control characters, a tab or NUL in place of
a letter, prefixes and extensions of an allowed scheme, `data:`); and **differential tests** of `escape` against
`escapeSpec`, the char-by-char reference kept in the test file: all 256 single bytes (alone and inside a string), 3000
pseudo-random mixes of the special characters, letters, entities and multi-byte UTF-8, and long strings. A generated-URL
test checks that `safeUrl` is the identity or the constant and that `isSafeUrl` always holds for the result.
`tools/mutate_std.py --module html`: 41 mutants (dropped or wrong entities, off-by-one in the run copying, `javascript` or
`data` accepted, `tel`/`mailto` rejected, case-sensitive or length-agnostic scheme comparison, the `/`, `?`, `#` cut-offs,
empty scheme accepted, `safeUrl` or `escapeUrl` skipping a step, `joinAll` skipping the first or last element, wrong
`document`/`text`/`trustHtml`/`fragment`/`isEmpty`), all killed with and without contracts (23 by a contract violation).

### Not guaranteed

* `escape` is for HTML text and quoted attribute values only. It does **not** make a string safe inside `<script>`,
  `<style>`, an event-handler attribute (`onclick="..."`), an unquoted attribute value, a tag or attribute name, or a
  comment; those contexts need their own encoders (or must not be fed with untrusted data).
* `safeUrl` is an allow-list of four schemes; it does not parse or normalise the URL (no percent-decoding, no host
  checks) and does not validate that the rest is a well-formed URL.
* `trustHtml` is the only raw path: what is passed to it is the caller's responsibility. The guarantee "a string is never
  markup unless escaped or trusted" is partly enforced by the compiler (no `Html { .. }` literals, no `.html` assignment
  outside this module), not by this module alone.
* The input is treated as bytes; an invalid UTF-8 byte sequence is copied unchanged (validate with `std:utf8` first when
  the encoding matters).
* The contracts are checked at run time and by tests; `orin verify --contracts` does not cover strings, arrays or loops.

## Parallel pipelines: `parallel()` (ADR-0039)

```ts
const total = xs.parallel().filter(x => x % 3 == 0).map(x => x * 2).reduce((a, b) => a + b, 0);
const big = orders.parallel().filter(o => o.qty > 10).toArray();     // Order = { id: int; qty: int; price: float }
const hit = xs.parallel().findIndex(x => x > limit);                 // Option<usize>: the same index as xs.findIndex(..)
```

`xs.parallel()` returns a view `Parallel<T>`. Its methods: `map(f)` and `filter(p)` return a view, `reduce(f, init)`, `some(p)`,
`every(p)`, `find(p)`, `findIndex(p)` return what the sequential method returns, `toArray()` returns the elements. No import is
needed (the prelude `array/parallel.or` is loaded for every file that calls `parallel()`); parallelism is explicit, the compiler
never parallelises on its own.

**Semantics: the result of the sequential chain.** The input is split into chunks of 4,096 consecutive elements (fixed: it does
not depend on the number of processors). `map` and `filter` keep the order. `reduce` folds every chunk from left to right and
then folds `init` with the chunk results from left to right, so for an associative reducer it equals the sequential fold, and
because the grouping is fixed even a float `reduce` gives the same bits on every machine and with every thread count. `some`,
`every`, `find`, `findIndex` give the sequential answer: chunks after the first hit are cancelled, chunks before it always run.
Inputs below 8,192 elements, and every input with `ORIN_THREADS=1`, run on the calling task, chunk by chunk, with the same result.

**Rules (compile errors and warnings).**

| Code | Rule |
|---|---|
| E0484 | every function given to a parallel operation is an arrow function or a named function and **pure** (no I/O, no impure call, no call of a function value); the message names the effect and where it happens |
| E0485 | the reducer of a parallel `reduce` is a built-in associative operator: `+` (integers, floats, strings), `*`, `&&`, `||`, min / max (`a < b ? a : b` and the other orders and comparisons, `Math.min` / `Math.max`), parameters in either order. A user-defined reducer needs a proved associativity law (ADR-0039 §3.2), a later step |
| E0486 | the input element type is a scalar (integers, floats, `bool`) or a record whose fields are all scalars. The workers read the input without copying it, which needs elements without counted references until borrow inference exists (ADR-0039 §4). Stages may produce any type (`map(x => x.toString())` is fine) |
| W0480 | a parallel float `reduce` (`+`, `*`, min, max): float arithmetic is not associative, so the result may differ from the sequential `reduce` in the last bits (it is the same everywhere else) |
| W0481 | a parallel integer `reduce` with signed `+`, or with `*`: a chunk's partial result can overflow (and trap) where the sequential fold does not, or the reverse. Unsigned `+` cannot differ (every partial sum is at most the total), so it gives no warning |

**Runtime.** The work-stealing fork/join pool of `std:task` (`forkJoin`, `forkJoinUntil`, docs/concurrency.md "Fork/join
pool"). Threads: `ORIN_THREADS` (1 to 1,024) or the processors online. The input array is *lent* to the worker tasks: it is
pinned (its reference counts frozen) while they run and shared instead of copied; results are built by the workers and moved
back; values the closures capture are copied to each worker. A trap in a closure traps the program with the closure's own
message; which element traps first is not defined when several would. With the optimiser, a chain becomes one fused loop per
chunk (`orin compile --fuse-report` lists them).

**Limits.** No parallel `sort`, `forEach`, `indexOf` / `includes` yet (ADR-0039 order 4); no user reducers; element types as
above; a pool lives for one call (worker threads are started per operation, about 80 us each); a parallel `some` / `every` /
`find` / `findIndex` whose predicate can trap may trap on an element after the first match, where the sequential method stops.

## Limitations

* No floats/`Map`: `JNum` is `int`, no `std:math`, `std:map`, edge weights, `sleep`, fractional seconds.
* Generic methods do not exist (E0460); `Graph<T>` has no edge weights and needs a caller-supplied tag.
* Diagnostics print std types with their unit name (`$stdlib/graph.GraphId<int>`).
* `std:clock` is importable but internal; so is `std:fsraw` (the raw open/close and grant primitives behind `std:fs` and `std:host`; only library code may import it).
* `std:fs` streaming: text/byte-string API without seek, no directory operations, at most 256 open files.

## std:encoding

Strict byte-based Hex, Base64 and Base64URL codecs with explicit padding policy
and structured errors containing byte offsets. See [API, errors and complexity](std-encoding.md).
