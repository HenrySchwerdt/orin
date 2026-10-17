# std:json/decode

Pure field validation over `std:json`. `decodeRoot(value, limits)` validates
caller-built trees, then returns a sealed `DecodeCursor` for navigation. No I/O,
coercion, floating-point conversion, or source offsets are introduced. The runnable
[pure config example](../examples/json_config.or) separates parsing/output from
`decodeConfig(JsonValue): Result<Config, DecodeError>`.

## API

`decodeErrorMessage(e: DecodeError): string` renders "<JSON Pointer or (root)>: <cause>: expected E, found A"; it contains the path but never an input value.

Import enum types as well as functions to bring their constructors into scope.

| API | Result |
|---|---|
| `decodeRoot(value: JsonValue, limits: JsonLimits)` | `Result<DecodeCursor, DecodeError>`; validates the whole tree and rejects duplicate keys |
| `cursorValue(cursor)` | `JsonValue` copy |
| `cursorPath(cursor)` | `PathSegment[]` copy |
| `requiredField(cursor, key)` | `Result<DecodeCursor, DecodeError>`; absence is `DecodeMissingField` |
| `optionalField(cursor, key)` | `Result<Option<DecodeCursor>, DecodeError>`; only absence is `None`; null is `Some` |
| `decodeString(cursor)` | `Result<string, DecodeError>` |
| `decodeBool(cursor)` | `Result<bool, DecodeError>` |
| `decodeNumber(cursor)` | `Result<JsonNumber, DecodeError>` preserving the exact token |
| `decodeInt(cursor, min: int, max: int)` | `Result<int, DecodeError>`; exact integral conversion and inclusive range |
| `decodeArray(cursor)` | `Result<DecodeCursor[], DecodeError>` with indexed child paths |
| `checkFields(cursor, allowed: string[], policy: UnknownFieldPolicy)` | `Result<void, DecodeError>`; explicit `RejectUnknown` or `IgnoreUnknown` |
| `formatPath(path: PathSegment[])` | JSON Pointer string; root is `""` |

`DecodeCursor` wraps private state with read-only accessors. Callers cannot
construct or assign its state. Values, paths, and limits are captured using COW;
mutating an input or getter result does not mutate a cursor. The opaque state
avoids exposing a mutable array through a sealed record's array methods.

## Errors and paths

`DecodeError` contains `kind`, `path: PathSegment[]`, `expected`, and `actual`.
Kinds are `DecodeMissingField`, `DecodeWrongType`, `DecodeNotIntegral`,
`DecodeIntegerRange`, `DecodeUnknownField`, `DecodeDuplicateField`,
`DecodeLimitExceeded`, `DecodeInvalidLimits`, and `DecodeInvalidSchema`.
`DecodeFloatOverflow` and `DecodeFloatUnderflow` reserve the RFC categories;
there is no float decoder in this slice. Prefixes avoid constructor collisions
with `std:json/number` when importing both enum types.

A path contains `Key(string)` and `Index(usize)`. Dotted keys remain literal.
`formatPath([Key("a/b~"), Index(1)])` is `/a~1b~0/1`. Empty key is `/`.
Escaping replaces `~` with `~0` and `/` with `~1`; it does not URI-percent-encode.
`Key("1")` and `Index(1)` have different structural types although both print
`/1`. Missing fields include the absent key in their error path.

`expected` and `actual` contain fixed category/limit descriptions, never leaf
values or numeric tokens. Paths intentionally contain field names; callers
should apply their own policy when logging potentially sensitive schema names.
There are no invented offsets for trees without source locations.

## Validation, budgets and ordering

All eight `JsonLimits` fields must be positive and `maxDepth <= 200`.
`maxInputBytes` and `maxOutputBytes` are checked for valid configuration but
are not traversal/formatter budgets. The existing tree and caller's schema are
already allocated; this API does not bound their construction or runtime OOM.

Root validation visits nodes depth-first in document order. It counts every
value node, checks container depth/length before visiting children, and checks
string/key single and aggregate decoded byte limits before UTF-8 validation.
Invalid/oversized keys fail at their parent path; valid keys enter the path,
then duplicate detection precedes child validation. Strings and keys must be
strict UTF-8. Keys compare exact decoded bytes without Unicode normalization.
Duplicates fail even if a parser previously preserved them. Numbers already
carry the sealed `JsonNumber` grammar guarantee; root checks token length
without numeric conversion. Depth counts enclosing containers, matching the
JSON document API (200 nested arrays with a scalar leaf are permitted).

Field lookup first requires an object, then validates the query name's UTF-8
and `maxStringBytes`, then searches. Query names are schema input, not newly
decoded tree data: a missing query may add one bounded key to an error path even
when the tree's aggregate string budget is exhausted. Absence creates no cursor.
`decodeInt` rejects reversed bounds before checking the value's type; it reports
non-integral numbers separately from machine/custom range failures. No float
intermediary or overflowing range subtraction is used.

`checkFields` first requires an object, checks schema entry count against
`maxContainerItems`, then validates each schema name's single size/UTF-8,
aggregate size against `maxDecodedStringBytes`, and uniqueness. These schema
budgets are separate per-call allowances. Schema validation also runs with
`IgnoreUnknown`. With `RejectUnknown`, the first unknown key in document order
fails after schema validation. Empty allowed lists are valid. Repeated helper
calls have no hidden global quota.

## Complexity and verification

Let N be tree nodes, B string/key/token bytes, d path depth, m object members,
k array children, and S schema bytes. Root traversal is O(N+B) expected time
with per-object hash indexes, O(d) traversal stack plus live duplicate indexes.
The success path uses one mutable path stack; errors retain the final path.
Adversarial hash collisions can worsen map operations.

Field lookup scans m members plus string comparison bytes and query UTF-8;
a successful child or missing-field error copies O(d) path segments. q lookups
repeat that scan. Scalar helpers use O(1) COW getters; exact integer conversion
scans its token. `decodeArray` stores O(k*d) path segments and k cursors.
`checkFields` is expected O(S + member-key bytes + m), plus O(d) for an error
path; schema storage is O(S + allowed count). `formatPath` is linear in path
bytes and segments, allocating the escaped result (at most twice key bytes,
plus separators and decimal index digits). Arbitrary caller-supplied paths
are byte-escaped without UTF-8 validation; decoder-produced paths are valid.
Getter copies are O(1) until mutation triggers COW.

Run `python3 tools/check_jsondecode.py`. It checks the eight std test groups,
120 independently generated structural/error-pointer cases on C and LLVM with
contracts enabled/disabled, C ASan/UBSan, and checksum-checked measurements for
root validation, repeated last-field lookup, and array cursor path depth.
Measurements include construction and process startup; they are evidence of
bounded behavior, not isolated microbenchmarks or throughput guarantees.

Example local medians (seconds, three runs, clang `-O2`, contracts off):

| Workload | Sizes | C | LLVM |
|---|---|---|---|
| 40 root validations + child-array materializations | 1k / 4k / 16k values | .0094 / .0141 / .0405 | .0046 / .0113 / .0414 |
| 200 last-field lookups | 1k / 4k / 16k members | .0023 / .0038 / .0095 | .0026 / .0041 / .0100 |
| 20 arrays of 1k cursors | depth 10 / 40 / 160 | .0031 / .0041 / .0075 | .0033 / .0042 / .0078 |

These include process startup and fixture construction. The depth fixture
explicitly uses `maxDepth=200`; default limits intentionally stop at 64.
