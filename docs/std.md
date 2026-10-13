# Standard library overview

Status of the std modules of ADR-0016 (spec 08). Every public function has a doc comment in its
source with signature, errors/absence, behaviour and complexity (the spec 08 validation rule); this
page is the map. `orin mcp` `inspect` answers `std:path.join`, `std:json.parse`, ... from its built-in
API table (`compiler/mcp/apitable.or`).

| Module | Implemented in | Status |
|---|---|---|
| `std:fs` | Orin, `stdlib/fs.or` (scope API) over C runtime primitives (`std:fsraw`, internal) | done, **unstable** until capabilities (ADR-0016 amendment, ADR-0021); resources and streaming: ADR-0025 |
| `std:process`, `std:io` | C runtime built-ins (`runtime/orin_runtime*.c/.h`) | done |
| `std:path` | Orin, `stdlib/path.or` | done (POSIX, lexical) |
| `std:json` | Orin, `stdlib/json.or` | done, **integers only** |
| `std:time` | Orin, `stdlib/time.or` + one built-in (`nowMillis`) | clock, durations, UTC calendar; no `sleep`; clock access **unstable** until capabilities |
| `std:graph` | Orin, `stdlib/graph.or` | `class Graph<T>` with generational, tagged `GraphId<T>` (ADR-0026) |
| `std:bytes` | Orin, `stdlib/bytes.or` | `Bytes`, `ByteBuilder`, `ByteReader`; provable-std layer 1 (ADR-0030), contract standard |
| `std:utf8` | Orin, `stdlib/utf8.or` | validated decoding, encoding, `Utf8String` ("always valid UTF-8"), `CodePointCursor`; ADR-0030 |
| `std:collections` | Orin, `stdlib/collections.or` | `IntSet`, `StringSet`, `Deque<T>`, `SortedMap<V>`, `SortedStringMap<V>`, `PriorityQueue<T>`; ADR-0030 |
| `std:test` | Orin, `stdlib/test.or` | done (assertions for `@Test`, ADR-0024) |
| `std:math` | Orin, `array/math.or` (to move to `stdlib/`) | done (ADR-0018) |
| `Map<K, V>` | Orin prelude (`array/map.or`), built-in type | done (ADR-0018) |

## How the Orin-written modules are organised

`stdlib/*.or` is embedded into the compiler like the other preludes (`tools/embed_prelude.py` writes
`compiler/loader/embedded_stdlib.or`; run it after editing `stdlib/`, `tools/bootstrap.sh` checks it).
It is a *library root* (`PreludeRoot` with an empty `entry`): its files are served from memory under
`$stdlib/<name>.or` but, unlike `std/` and `array/`, **not** imported implicitly. The loader maps
`import ... from "std:path"` (also `std:json`, `std:time`, `std:graph`, `std:test`, `std:bytes`, `std:utf8`, `std:collections`) to the unit `$stdlib/path`.
Programs that do not import a module pay nothing for it, and the leading `$` makes unused functions of
imported modules disappear in `compiler/opt/prune.or`. The sources use the full language (generics,
records, closures); only the compiler itself has to stay Orin-B. Type names in diagnostics show the
unit (`$stdlib/json.Json`).

The single new built-in is `nowMillis(): int` (`hir.BTimeNowMillis`, C function
`orin_time_now_millis` in `runtime/orin_runtime_io.h`, `orinl_time_now_millis` for the LLVM backend).
It is reachable as the internal module `std:clock`; `std:time` re-exports it. Use `std:time`.

## std:fs (UNSTABLE: signatures may gain a capability parameter, ADR-0021)

Whole-file functions (unchanged): `readFile(path): Result<string, string>`, `writeFile(path, data): Result<void, string>`,
`exists(path): bool`.

Streaming through **resource handles** (ADR-0025, spec 06). `File` is a handle, not a value: it can only be a
function parameter. You get one as the parameter of the callback of a scope function, which opens the file, runs
the callback and closes the file on every path:

```
type FsError = string                       type FileMode = Read | Write | Append
withFile<T>(path, mode, body: (file: File) => T): Result<T, FsError>
useFile(path, mode, body: (file: File) => void): Result<void, FsError>      // body returns nothing
withFiles<T>(pathA, modeA, pathB, modeB, body: (a: File, b: File) => T): Result<T, FsError>
useFiles(pathA, modeA, pathB, modeB, body: (a: File, b: File) => void): Result<void, FsError>

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
const n = withFile("log.txt", Read, f => {
  let lines: int = 0;
  while (f.readLine().isSome()) { lines += 1; }
  return lines;
});
useFiles("in.txt", Read, "out.txt", Write, (a, b) => { while (true) { const l = a.readLine(); if (l.isNone()) { return; } b.writeLine(l.unwrap()); } });
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

`nowMillis(): int` (wall clock, ms since the Unix epoch, not monotonic). Durations are explicit-unit
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
  (`tools/mutate_std.py`): 44 deliberately broken one-line variants of the three modules, each of which must make a
  test or a contract fail (CI step "Provable std").

Contract counts (clauses in the source): `std:bytes` 3 invariants + 6 `@Requires` + 85 `@Ensures`;
`std:utf8` 2 + 5 + 47; `std:collections` 14 + 0 + 150 (every collection operation is total, so none needs a
precondition: absent keys and empty containers answer `None`/`false`).

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

Decoding follows RFC 3629 / Unicode Table 3-7 exactly (table in the source header): rejected are lone continuation
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

### std:collections

```
class IntSet / StringSet          // on Map; invariants: map size == key count, every stored flag true
  size() isEmpty() has(x) add(x): bool remove(x): bool clear() toArray()   // expected O(1); add/remove say whether the set changed
  isSubsetOf(o) union(o) intersection(o) difference(o)                       // O(n + m)
class Deque<T>                    // ring buffer, doubling from 4 slots; invariants: len <= capacity, head in range,
                                  // exactly the len slots from head (mod capacity) hold Some, the others None
  size() isEmpty() capacity() pushBack(x) pushFront(x) popFront() popBack() front() back() get(i) clear() toArray()   // amortised O(1)
class SortedMap<V>                // int keys; sorted array: invariants keys.length == vals.length, keys strictly increasing
class SortedStringMap<V>          // the same with string keys in compareStrings order (byte-wise lexicographic)
  size() isEmpty() has(k) get(k): Option<V> put(k, v): bool remove(k): Option<V>           // O(log n) search; put/remove shift: O(n)
  firstKey() lastKey() floorKey(k) ceilKey(k)   popFirst() popLast(): Option<SortedEntry<V>>  keyArray() valueArray() clear()
class PriorityQueue<T>            // binary min-heap; invariants: heap property (strict, on (priority, insertion number)),
                                  // every insertion number < the counter, which never decreases
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

**Why a sorted array and not a tree.** The invariant "keys strictly increasing, same length as the values" is a two-line
loop and the representation is fully visible to it; binary search is a dozen lines. A balanced tree would need balance
and order invariants over a recursive structure that loop-only contract helpers cannot express simply, and the O(n)
insert is a shift of 8-byte slots. Lookups are O(log n); put/remove are O(n) worst case, O(1) at the largest key.

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
  invariant: `PriorityQueue<T>` takes an explicit `int` priority. A `T extends Ranked` interface would do for ordered
  classes, but cannot cover `int`/`string` without wrapper classes.
* There are no private constructors (`private constructor` is rejected with E0411), so `Bytes` and `Utf8String` have public
  constructors whose requirements are checked: `Bytes` by `@Requires` (a violation is still memory safe: every access is
  bounds checked), `Utf8String` by always-on validation.
* No bitwise operators or shifts (multi-byte integers use `*`, `/`, `%`); no array `reserve`; a `u8` array element
  occupies 8 bytes; `@Test` has no "expected trap" form (`tests/std/expect_trap/` and `tools/test_std.sh` fill that gap).
* Mutating methods cannot be called inside `&&`, `||` or `?:` (E0408), nor on a temporary (E0401): `let r = new ByteReader(b);`.

## Limitations

* No floats/`Map`: `JNum` is `int`, no `std:math`, `std:map`, edge weights, `sleep`, fractional seconds.
* Generic methods do not exist (E0460); `Graph<T>` has no edge weights and needs a caller-supplied tag.
* Diagnostics print std types with their unit name (`$stdlib/graph.GraphId<int>`).
* `std:clock` is importable but internal; so is `std:fsraw` (the raw open/close primitives behind `std:fs`; only library code may import it).
* `std:fs` streaming: text/byte-string API without seek, no directory operations, at most 256 open files.
