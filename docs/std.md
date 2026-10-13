# Standard library overview

Status of the std modules of ADR-0016 (spec 08). Every public function has a doc comment in its
source with signature, errors/absence, behaviour and complexity (the spec 08 validation rule); this
page is the map. `orin mcp` `inspect` answers `std:path.join`, `std:json.parse`, ... from its built-in
API table (`compiler/mcp/apitable.or`).

| Module | Implemented in | Status |
|---|---|---|
| `std:fs`, `std:process`, `std:io` | C runtime built-ins (`runtime/orin_runtime*.c/.h`) | done, **unstable** until capabilities (ADR-0016 amendment, ADR-0021) |
| `std:path` | Orin, `stdlib/path.or` | done (POSIX, lexical) |
| `std:json` | Orin, `stdlib/json.or` | done, **integers only** |
| `std:time` | Orin, `stdlib/time.or` + one built-in (`nowMillis`) | clock, durations, UTC calendar; no `sleep`; clock access **unstable** until capabilities |
| `std:graph` | Orin, `stdlib/graph.or` | stop-gap functional API; becomes `Graph<T>`/`GraphId<T>` with generic classes |
| `std:math` | Orin, `array/math.or` (to move to `stdlib/`) | done (ADR-0018) |
| `Map<K, V>` | Orin prelude (`array/map.or`), built-in type | done (ADR-0018) |

## How the Orin-written modules are organised

`stdlib/*.or` is embedded into the compiler like the other preludes (`tools/embed_prelude.py` writes
`compiler/loader/embedded_stdlib.or`; run it after editing `stdlib/`, `tools/bootstrap.sh` checks it).
It is a *library root* (`PreludeRoot` with an empty `entry`): its files are served from memory under
`$stdlib/<name>.or` but, unlike `std/` and `array/`, **not** imported implicitly. The loader maps
`import ... from "std:path"` (also `std:json`, `std:time`, `std:graph`) to the unit `$stdlib/path`.
Programs that do not import a module pay nothing for it, and the leading `$` makes unused functions of
imported modules disappear in `compiler/opt/prune.or`. The sources use the full language (generics,
records, closures); only the compiler itself has to stay Orin-B. Type names in diagnostics show the
unit (`$stdlib/json.Json`).

The single new built-in is `nowMillis(): int` (`hir.BTimeNowMillis`, C function
`orin_time_now_millis` in `runtime/orin_runtime_io.h`, `orinl_time_now_millis` for the LLVM backend).
It is reachable as the internal module `std:clock`; `std:time` re-exports it. Use `std:time`.

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

## std:graph (spec 06 cyclic graphs)

A graph owner holds the nodes; edges are checked, non-owning ids, so no owning cycle ever exists.

```
type GraphId<T> = { tag: int; index: usize; gen: int }     // create only through add
type GraphError = StaleId | ForeignId
newGraph<T>(tag: int): Graph<T>
add(g, value): Added<T>                         // { graph, id }
get(g, id): Result<T, GraphError>
set(g, id, value) / remove(g, id) / addEdge(g, a, b): Result<Graph<T>, GraphError>
neighbors(g, id): Result<GraphId<T>[], GraphError>
size(g), contains(g, id), ids(g), graphErrorMessage(e)
```

Ids carry the graph tag, slot index and slot generation. `remove` bumps the generation, so every copy
of the removed node's id is stale (`Err(StaleId)`) even after the slot is reused; an id of another graph
(different tag, or an index beyond the graph) is `Err(ForeignId)`. Edges to removed nodes dangle and are
skipped by `neighbors`.

**Value semantics, functional API.** Classes cannot be generic yet (ADR-0009), so `Graph<T>` is a generic
record with free functions instead of the method syntax `g.add(v)` of spec 06; operations that change the
graph return the new graph and leave the argument untouched (an older copy keeps its nodes). Changing
operations are O(nodes) until in-place mutation of owned values lands (ADR-0010). The tag is passed by
the caller (`newGraph(tag)`): the language has no process-wide counter for automatic unique tags;
use a different tag per logical graph.

## Limitations

* No floats/`Map`: `JNum` is `int`, no `std:math`, `std:map`, edge weights, `sleep`, fractional seconds.
* Generic classes/methods do not exist yet, hence the functional `std:graph` API.
* Diagnostics print std types with their unit name (`$stdlib/graph.GraphId<int>`).
* `std:clock` is importable but internal.
