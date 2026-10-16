# ADR-0048: Standard library API conventions

Status: accepted (2026-10-16). Conventions apply to new std code immediately; the migration of existing names (section 9) starts after ADR-0047 has moved `std/`, `stdlib/` and `array/` to `library/`.

Evidence: [docs/audits/2026-10-16-std-api.md](../audits/2026-10-16-std-api.md) (about 590 public items in 28 units, every finding with `file:line`). Finding ids such as N1 or E3 below refer to that audit.

## Motivation

The standard library grew module by module, and each module is internally reasonable, but a developer who has learned one module cannot predict the next one. The audit counted five spellings of "how many elements" (N1), two opposite meanings of `at` (N2), four return shapes of `remove` (N3), six ways to signal failure (E1), five error payload shapes (E3), three JSON value models (M1), three conventions for "hidden" fields (U3), about 25 API twins that exist only because `void` could not be a type argument (U4), and zero uses of the accepted `Eq/Ord/Hash` constraints (G1). Spec 08 already states the goal ("JavaScript/TypeScript-familiar names, no nullable results, no throw-on-ordinary-failure"); this ADR turns it into rules a reviewer can check.

Where the library already has a clear majority, the rule follows the majority, so most of the migration is renaming the minority.

## 1. Names

1. Functions, methods, fields and parameters are lowerCamelCase; types, classes, interfaces and variants are UpperCamelCase; exported constants are UPPER_SNAKE_CASE (`PI`, `E` stay as they are). Acronyms are written as words: `Utf8`, `Http`, `Json`, `Url`, `U16Be` (not `U16be`, not `PQEntry`).
2. A name does not repeat its module. Inside `std:utf8` it is `validate`, not `isValidUtf8`; inside `std:bytes` it is `empty()`, not `emptyBytes()`. Exception: error renderers and error types (rule 4.3) and names that would otherwise collide with a prelude builtin. Callers write `utf8.validate(..)` via `import * as utf8`, and the docs show that form.
3. Module-level exports avoid words that are also module names (`text`, `path`, `ox`) and bare, overly generic verbs (`plus`, `between`) unless the module is always imported as a namespace. `json.path` becomes `json.getPath`; `net.nowMillis` (a monotonic clock) becomes `net.monotonicMillis` so it no longer shadows `time.nowMillis`.
4. Spelling of type words: `String` and `Int` in type-specialised names (`StringSet`, `indexOfString`), never `Str`.

### 1.1 The collection vocabulary

One word per concept, for builtins and std classes alike:

| Concept | Name | Shape |
|---|---|---|
| element count of a sequence (string, Array, Bytes, ByteBuilder) | `length` | property on builtins, `length()` on classes |
| element count of a keyed or unordered collection (Map, sets, Deque, SortedMap, PriorityQueue, Graph, Headers) | `size` | property on builtins, `size()` on classes |
| emptiness | `isEmpty()` | |
| membership in a keyed collection | `has(k): bool` | `Graph.contains` becomes `has` |
| search in a sequence | `includes(x): bool`, `indexOf(x): Option<usize>` | |
| checked read | `get(k): Option<V>` | absence is never a trap |
| contract read (caller proves the index) | `at(i): T` with `@Requires` | `json.at` (which returns `Option`) becomes `json.getIndex`; `ByteBuilder.byteAt`, `Headers.nameAt/valueAt` keep the `At` suffix |
| associate key with value | `set(k, v)` | `SortedMap.put` becomes `set` |
| add to a set or graph | `add(x)` | |
| remove by key | `remove(k)` | maps return `Option<V>`, sets return `bool`, multi-maps (`Headers`) return the removed count; builtin `Map.delete` gains the `remove` spelling |
| append to a sequence | `push` / `pop` (Array, PriorityQueue); `pushFront/pushBack/popFront/popBack` (Deque) | |
| ends of an ordered collection | `first()/last()`, `popFirst()/popLast()` | Deque keeps `front/back` because both ends are mutable |
| empty everything | `clear()` | |
| copy out | `toArray()` for linear containers, `keys()/values()/entries()` for keyed ones | `SortedMap.keyArray/valueArray` become `keys/values` |
| capacity | `capacity()` | `ByteBuilder.reserved()` becomes `capacity()` |

### 1.2 Verbs

| Situation | Name |
|---|---|
| predicate | `is*` by default; `has*` for membership or presence; `can*` for permission. A function returning `bool` that is not a predicate (for example "was it sent") returns a `Result` or a named variant instead. |
| text to value | `parse*` (returns `Result<T, E>`; `Option<T>` only for the numeric builtins `parseInt` and friends) |
| value to text | `stringify` for text formats (JSON, query strings), `format*` for human-oriented text (dates), `serialize*` for wire bytes (HTTP), `render` for markup |
| codecs | `<codec>Encode` / `<codec>Decode` (`hexEncode`, `base64Decode`, `percentEncode`); `std:utf8` uses bare `encode`/`decode` because the module is the codec |
| conversion | `toX()` makes a new value (copy), `asX()` returns a cheap view of the same data; a free function building a value of the module's main type from something else is `fromX(..)` (`bytes.fromHex`, `utf8.fromCodePoints`, `time.fromMillis`), and its inverse is `toX` |
| canonical empty value | `empty()` (module-scoped) |
| default configuration | `defaultX()` where `X` is the record's name without the module prefix: `json.defaultLimits()`, `http.defaultLimits()` |
| validating constructor | see rule 3.2 |
| scoped resource | `withX(grant, .., body)` (see section 6) |

## 2. Parameters

1. The subject comes first (`json.get(j, key)`, `path.join(base, part)`); for methods the receiver is the subject.
2. A capability grant comes first, before the subject, for every function that needs authority (`fs.readFile(fs, path)`). Delegation to a task is the one exception: the scope is the subject, so `spawnFs(scope, fs, body)` stays.
3. A callback comes last. When there are two, the main one comes last (`forkJoinUntil(chunks, workers, hit, body)`).
4. Options come last, as a record with a `defaultX()` constructor (`parseDocument(text, options)`), never as a positional `bool`. A function with more than three parameters of the same type takes a record (`new Limits(6 x usize)` becomes `HttpLimits { .. }`, `makeRequest(6 args)` takes `RequestParts`).
5. A two-valued option that is genuinely binary is a named variant pair, not a `bool`: `Padding = Padded | Unpadded`, `FormSpace = PlusAsSpace | PercentSpace` (this also removes the opposite polarity of `spaceAsPlus` and `plusAsSpace`, P3).
6. Durations are `Duration`, not `timeoutMs: int` or `seconds: int` (P5). Ports are `u16`-ranged `int` checked by contract; sizes and indices are `usize`.

## 3. Failure

The six idioms of finding E1 collapse to three, each with a fixed meaning:

| Situation | Signal |
|---|---|
| a value that may legitimately be absent (lookup, search, empty pop) | `Option<T>` |
| an operation that can fail for a reason the caller handles (I/O, parsing, validation of outside input, denied grants) | `Result<T, XError>` |
| a caller bug (index out of range, invariant broken, misuse of an API) | trap, stated as `@Requires` (or `enforce()` for constructors) and documented as "traps" |

1. No sentinel values: no `-1`, `0` port, `""` meaning "ok", or `-2` meaning timeout. `net.parsePeer` returns `Result<Peer, NetError>`; `http.requestProblem` returns `Option<string>` (and becomes internal, section 7); `io.shell`/`shellTimeout` return `Result<int, ProcessError>` with a `Timeout` kind. ADR-0045's sentinel choice is superseded by this rule.
2. A trap is never the answer to ordinary outside failure. `fs.exists` and `fs.listDir` return `Result` like `fs.readFile`.
3. Trapping/validating twins follow one rule: the trapping form is the constructor or the plain name (`new Status(..)`, `slice(..)`), the `Result` (or `Option`) form is `tryX` (`Status.tryNew`, `trySlice`, `Utf8String.tryFrom`, `http.tryHeaders`). `make*` and `validate*` are retired as twin names.
4. Mutators that may be refused return `Result<void, XError>`; mutators that may be a no-op return `bool` meaning "changed" (sets, `Headers.remove`'s count is the multi-map form). `Sender.send` returns `Result<void, SendError>` with a `Closed` kind instead of a bare `bool`.

### 3.1 Error types

1. One error type per module, named `<Module>Error` (`FsError`, `NetError`, `JsonError`, `HttpError`), with a `kind: <Module>ErrorKind` field. Operation-specific types (`ReadError`, `DecodeError`, `QueryEncodeError`) are allowed only when the module has several independent failure families, and then they follow the same shape.
2. Every error record has `kind`, and, where it applies, `offset: usize` (a byte offset into the input; `position` is renamed) and `length: usize`. Context such as a path or a JSON path is a named field (`path`, `field`). No `message: string` field: the text is derived.
3. Every error type has a renderer `<module>ErrorMessage(e): string` (`fsErrorMessage`, `jsonErrorMessage`). `json.formatError` becomes `jsonErrorMessage`; `JsonParseError`, `JsonWriteError`, `DecodeError` and `QueryEncodeError` gain one.
4. Kind variants are bare UpperCamel words describing the cause (`InvalidHex`, `Overlong`, `Denied`, `Timeout`), using `Invalid*` (not `Bad*`) for malformed input. `HttpReason` becomes `HttpErrorKind`.
5. `string` is never an error type in a public API (`FsError = string`, `make* -> Result<_, string>` are migrated).

## 4. Mutability and ownership

1. Mutators are methods on a `let` receiver that return `void`, `bool`, `Option` or `Result` as in rule 3.4. A method that returns a new value never mutates the receiver; a method that mutates never looks like a getter (`ByteReader.rest()` becomes `takeRest()`).
2. Value-producing operations on collections return new values (`union`, `concat`, `slice`, `sort`); there is no in-place `sort`.
3. "Hidden" has one spelling: `private` on classes. Records that must stay opaque use `@Sealed` with `_`-prefixed fields. Public fields on std classes are not allowed (`Sender.ch`, `Scope.tab`, `TaskHandle.{tab,idx,res}` become private).

## 5. Generics and constraints

1. Once the checker implements ADR-0034, type-specialised families become one generic API: `Set<T extends Hash>` (with `type IntSet = Set<int>` and `type StringSet = Set<string>` kept as aliases), `SortedMap<K extends Ord, V>`, `Array.indexOf/includes` for `T extends Eq`, one `assertEq<T extends Eq>`, `compare` via `Ord` instead of `compareStrings`.
2. Until then, new specialised names follow rule 1.4 so they can become aliases later without another rename.
3. Type parameter names: `T` (element), `U` (second element), `K`/`V` (keys/values), `R` (callback result), `E` (error).

## 6. Scoped resources and tasks

Per ADR-0040 the `with*`/`use*`, `scope*`/`scope*Do` and `spawn`/`spawnDo` twins become one function each once generic methods and `void` type arguments are implemented: `withX(grant, .., body: (x) => T): T` with `T = void` allowed. The `use*` and `*Do` names stay one release as `@Deprecated` wrappers.

## 7. Module cut

1. **One JSON module.** `std:json` becomes the exact, bounded model of `std:jsonvalue` (with `jsonnumber` and `jsondecode` as its submodules `std:json/number` and `std:json/decode`). The integer-only legacy `Json` moves to `std:json/legacy` with `@Deprecated` and gets a `toValue/fromValue` bridge. This is what `docs/rfcs/json-completeness.md` proposed.
2. **One home per codec.** Hex lives in `std:encoding`; `Bytes.toHex` and `bytes.fromHex` become thin wrappers with the same error type. All decoders accept the same input type (`Bytes`, with a `string` convenience overload named `<codec>DecodeText`).
3. **Internals are not API.** Helpers that exist only to state contracts (`collections.btree*`, `lowerBound*`, `isMinHeap4`, `allTrue`, most of `http`'s rule predicates, `array/parallel.or` chunk helpers, `array/map.or` hash hooks) and the whole of `std:taskcore` move to `<module>/internal` submodules. User code importing an `internal` module gets a warning (enforced by the loader once ADR-0047's library layout is in place). If contracts need visibility the language does not have yet, that is a language follow-up, not a reason to publish helpers.
4. **String utilities belong to strings.** `toLowerCase`, `toUpperCase`, `replace`, `eqIgnoreCase` (spec 08) join the string builtins; `http.toLowerAscii` becomes internal. `net.findFrom` becomes `Bytes.indexOfBytes(needle, from)`.
5. **Re-exports:** a module re-exports exactly the grant and handle types its functions take (`std:fs` re-exports `FsGrant`, `File`), never functions of another module.
6. **Parallel APIs:** `xs.parallel().map(..)` is the data-parallel pipeline and `forkJoin` the task-parallel primitive; `parallelMap` is deprecated.

## 8. Documentation

1. Every public item has a doc comment in its source, signature first, in this form:

   ```orin
   // get(key): Option<V> -- the value stored under key, or None. O(log n).
   ```

   followed by errors/absence, traps, and complexity/allocation. Longer narrative and examples live in `docs/std-<module>.md`; the source comment is the reference, the md file is the guide.
2. `compiler/mcp/apitable.or` is generated from these comments and the exported signatures (no hand-written table), so the API table cannot drift (N21, M8).
3. `docs/std.md`'s claim that every function is documented becomes a CI check, added together with the generator (a new `orin doc --check` mode).

## 9. Migration

- Old names stay one release as `@Deprecated` wrappers wherever the rename is mechanical; the deprecation message names the replacement. Modules marked unstable (`fs`, `host`, `net`, `task`, the monotonic part of `time`) change without wrappers.
- Order, one PR per row, each with tests and a `docs/std-*.md` update:
  1. Docs backfill and the `apitable` generator (no API change).
  2. Collection vocabulary (section 1.1) and verbs (1.2), with wrappers.
  3. Error shape (section 3.1): `offset`, renderers, typed errors, `string` errors removed.
  4. Sentinels and traps on ordinary failure (section 3, rules 1 and 2).
  5. Options records and `Duration` (section 2).
  6. Internals to `internal` submodules (section 7.3, 7.4).
  7. JSON consolidation (section 7.1).
  8. `Eq/Ord/Hash` generics (section 5) and ADR-0040 twins (section 6), each when the checker feature lands.
- The compiler embeds the library (`compiler/loader/embedded_*.or`), so every row regenerates the embedding with `tools/embed_prelude.py` and must keep the bootstrap fixed point.
- Work starts after ADR-0047 has moved the library directories, so that the renames and the moves are not mixed in one PR (ADR-0047: "do not combine semantic compiler changes with bulk renames").

## Consequences

- A developer can guess names across modules: `size()`, `get -> Option`, `tryX -> Result`, `<module>ErrorMessage(e)`.
- The audit's section (d) lists about 60 renames and reshapes; most keep a deprecated alias for one release.
- Reviews of new std APIs check this ADR; deviations need a sentence in the module's doc explaining why.
