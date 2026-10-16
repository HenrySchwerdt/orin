# RFC: complete JSON numbers and predictable application decoders

Status: **design only; coordinator review required before implementation**. Date:
2026-10-15. Evidence baseline: main `dddfd54c495221f58a97b1a0d261aa206247fca0`.
This proposes library APIs using existing language features. It changes no shipped
parser, value representation, compiler, verifier, runtime or protocol behavior.

## Problem and repository evidence

Applications need to read decimal/exponent values without corrupting integer IDs,
then validate configuration with useful field paths. Switching `JNum(int)` to a
float loses information; adding a variant breaks exhaustive matches. There are
also two distinct parsers, not one implementation to silently generalize:

| Evidence | Current behavior / affected callers |
|---|---|
| [stdlib/json.or](../../stdlib/json.or), `parseNumber`, `Json`, `asInt` | `JNum(int)`; decimals/exponents rejected; public parser excludes i64 minimum; ordered duplicate fields retained, `get` returns last |
| [compiler/json/parse.or](../../compiler/json/parse.or), `JsonCursor.number` | full i64 range; fractions validated then **truncated toward zero**; exponents rejected; string errors containing offsets |
| [compiler/json/json.or](../../compiler/json/json.or), [write.or](../../compiler/json/write.or) | separate union, exhaustive `jsonEq`/writer; writer contracts depend on parse-back equality |
| [compiler/lsp/handler.or](../../compiler/lsp/handler.or), [compiler/mcp/tools.or](../../compiler/mcp/tools.or) | integer positions, revisions and limits use `getInt`/`getPathInt`; a broad parser migration changes protocol inputs |
| [compiler/analysis/osig.or](../../compiler/analysis/osig.or), [compiler/tests/tooling_test.or](../../compiler/tests/tooling_test.or) | integer source coordinates, deterministic snapshots, variant-sensitive structural equality and minimum-integer round trips |
| [compiler/check/builtins.or](../../compiler/check/builtins.or), [runtime/orin_runtime.c](../../runtime/orin_runtime.c), [ADR-0018](../decisions/0018-floats-and-maps.md) | binary64 `float`, explicit integer conversions, `parseFloat`, `isFinite`; float-to-int can trap; `parseFloat` accepts non-JSON NaN/Infinity and can overflow/underflow |

A local C-backend probe of the baseline produced:

| Input | Public JSON | Internal JSON / explicit float conversion |
|---|---|---|
| `9007199254740993` | exact same integer | internal exact; `parseFloat` prints `9007199254740992.0` |
| `-9223372036854775808` | integer-out-of-range error | internal exact minimum integer |
| `1.0` / `1.9` | error at byte 1 | internal prints `1` for both |
| `1e3` | error at byte 1 | internal exponent error at byte 1 |
| `-0` | prints `0` | internal prints `0`; `parseFloat` preserves float negative zero |
| `1e999` / `1e-999` | rejected | `parseFloat` prints `Infinity` / `0.0` |

The probe was compiled against the matching JSON sources with an already-built
compiler; it is observational evidence, not a new conformance guarantee. Existing
[public number fixtures](../../tests/next/run/std_json_numbers.or),
[round trips](../../tests/next/run/std_json_roundtrip.or),
[float parsing](../../tests/next/run/float_parse.or) and
[float round trips](../../tests/next/run/float_round_trip_parse_print.or) provide
starting points for executable acceptance tests.

## Decision 1: preserve legacy Json; add a separate exact value type

Keep `std:json.Json`, `JNum(int)`, all existing constructors, exhaustive matches,
accessor signatures, `parse`, `stringify` and `pretty` unchanged. Keep the compiler's
internal Json unchanged in the first implementation. No aliasing between the two
existing unions or implicit numeric coercion is introduced.

Add the following **new exports of std:json** (names proposed, not implemented):

```typescript
type JsonValue = ValueNull | ValueBool(bool) | ValueNumber(JsonNumber)
  | ValueString(string) | ValueArray(JsonValue[]) | ValueObject(JsonMember[]);
type JsonMember = { key: string; value: JsonValue; };
@Sealed
type JsonNumber = { token: string; };
```

The sealed-number pattern already exists for Html in
[stdlib/html.or](../../stdlib/html.or): callers can read its token but cannot
forge a record literal or mutate the field outside its defining module. A checked
factory establishes syntax even with contracts disabled. No new annotation,
reflection, generic-method feature or arbitrary-precision runtime object is needed.

`JsonNumber` stores the **exact validated ASCII lexeme**, not a float or expanded
coefficient. Every numeric token, including small integers, uses this type in the
new tree. Thus `1`, `1.0`, `1e0`, `-0` and `-0.00` remain distinguishable. Accept huge
exponents within the token-byte limit without expanding them or converting them
to machine integers. Structural equality compares numeric tokens, not mathematical
equality. Decimal arithmetic, numeric canonicalization and mathematical equality
are separate future work.

This duplicates a small value vocabulary and requires explicit migration, but
preserves old exhaustive matches and integer assumptions. Rejected alternatives:

- `JNum(float)`: source/type break and rounded integer IDs above 2^53.
- Add `JFloat`/`JDecimal` to existing Json: exhaustive-match break, including compiler writers.
- Store only `int | float` in a new tree: large integers/decimal text still round or fail during parsing.
- Accept decimals and truncate: existing internal behavior is evidence of the problem, not the new policy.

A source-compatible in-place `parse` upgrade is impossible while its result type
cannot represent these values. Release notes must distinguish the legacy API from
the new complete-number API; do not advertise that existing `parse` now accepts decimals.

## Decision 2: strict grammar, explicit conversion, lossless numeric serialization

Number grammar, over ASCII bytes:

```text
number = '-'? ('0' | [1-9][0-9]*) ('.' [0-9]+)? ([eE] [+-]? [0-9]+)?
```

Reject `+1`, `01`, `.5`, `1.`, incomplete exponents, NaN, Infinity, hex, embedded
whitespace and trailing junk. The scanner validates the entire token before any
conversion. Never delegate syntax acceptance to `parseFloat`.

| Proposed export | Result / failure policy |
|---|---|
| `jsonNumber(text: string, maxBytes: usize): Result<JsonNumber, NumberError>` | exact full-token validation; zero budget is invalid limits; syntax/length errors carry token-relative byte offset |
| `numberFromInt(n: int): JsonNumber` | exact decimal including full i64 minimum; no float intermediary |
| `numberFromFloat(f: float): Result<JsonNumber, NumberError>` | reject non-finite; use existing round-trip spelling, preserve `-0.0`; makes no claim to recover a pre-rounding decimal |
| `numberAsInt(n: JsonNumber): Result<int, NumberError>` | exact mathematical integer in full i64 range; `1.00`/`1e3` succeed, `1.25` fails `NotIntegral`, out-of-range fails `IntegerRange`; no float-to-int trap |
| `numberToFloatRounded(n: JsonNumber): Result<float, NumberError>` | explicit binary64 rounding; reject infinity/overflow and nonzero values rounded to zero (`FloatUnderflow`); finite subnormals allowed; coefficient-zero tokens are zero, preserving negative sign |
| `parseDocument(text: string, options: JsonReadOptions): Result<JsonValue, JsonParseError>` | new strict parser with budgets below |
| `writeDocument(v: JsonValue, limits: JsonLimits): Result<string, JsonWriteError>` | deterministic compact output; numeric tokens emitted unchanged; checks depth, nodes, UTF-8 and output size even for caller-built values |

`NumberErrorKind` is `InvalidNumber | NumberLimit | InvalidLimits | NotIntegral |
IntegerRange | NonFinite | FloatOverflow | FloatUnderflow`; `NumberError` includes
`kind` and `offset: Option<usize>` (token byte or EOF where meaningful; None for
numeric range/conversion errors). The parser translates factory offsets to source
offsets. Error enums are new API, not extensions of legacy JsonError.

Exact integer conversion scans coefficient digits, decimal scale and exponent.
It first recognizes an all-zero coefficient, then uses saturated comparisons
against token length and 19-digit i64 bounds; a huge exponent must never cause
integer overflow or a huge allocation. Nonzero discarded decimal places mean
NotIntegral. Accumulate on the sign side, following the internal parser's existing
minimum-integer technique. O(token bytes), without constructing exponent-sized zeros.

`writeDocument(parseDocument(s, options))` preserves each number's lexeme, field
order and decoded strings, not whitespace or original string-escape spelling.
Writer/reader structural round trips require sufficient input/output limits and
a matching duplicate policy. No JSON canonicalization or byte-for-byte document
round trip is claimed. Pretty printing can follow after the compact path; no new
unchecked printer is part of the first slice.

## Decision 3: bounded strict input; duplicate and Unicode policies are explicit

Proposed defaults returned by `defaultJsonLimits()`:

| Limit | Default | Counting rule |
|---|---:|---|
| `maxInputBytes` | 1,048,576 | entire source including whitespace; reject before parsing |
| `maxDepth` | 64 | simultaneously open containers; root scalar depth 0, root array/object depth 1 |
| `maxNodes` | 100,000 | every value once, including containers; object keys are strings, not value nodes |
| `maxContainerItems` | 10,000 | per-array elements / per-object member occurrences, duplicates included |
| `maxStringBytes` | 262,144 | decoded bytes in one value string or key |
| `maxDecodedStringBytes` | 1,048,576 | aggregate decoded key and value-string bytes |
| `maxNumberBytes` | 1,024 | entire signed numeric token including exponent |
| `maxOutputBytes` | 4,194,304 | actual encoded output bytes, before every append |

All limits must be positive, with maxDepth <= 200; invalid options return an error.
Maximum depth is an implementation stack-safety ceiling, not a formal stack proof.
Use overflow-safe budget comparisons and check before allocating/appending. Limits
bound work per operation, not total application memory across repeated calls; allocator
failure still has runtime behavior. No streaming or recovery from OOM is promised.

`JsonReadOptions = { limits: JsonLimits; duplicates: JsonDuplicatePolicy; }`;
`defaultJsonOptions()` chooses `RejectDuplicates`. The only alternative initially
is `PreserveDuplicates`: preserve all members and order, never silently collapse.
Compare **decoded** keys, so `"a"` and `"\u0061"` collide; report the duplicate's
opening quote. Writers preserve an explicitly constructed member list.

The new parser validates UTF-8 and rejects lone/mismatched surrogate escapes.
This deliberately differs from legacy byte passthrough/replacement and applies
only to the opt-in API. No Unicode normalization or key case folding. String and
byte offsets continue to count bytes; line/column are 1-based with LF advancing
the line. `JsonParseError` includes a stable kind, zero-based `offset`, `line`,
`column`, and optional limit name. Syntax points at the first offending byte;
missing required digits/terminators at EOF point to source length. A token-byte
limit points at the first byte beyond the budget; depth at the disallowed opening
delimiter; node/item limits at the next disallowed value/member. Fail fast.

Target parser complexity: O(input bytes), using a temporary decoded-key hash set
per object for duplicate detection (expected linear, adversarial hash behavior
must be documented), O(input + tree) storage within budgets. Use existing Bytes/
ByteBuilder and maps; avoid repeated whole-buffer copies. The public writer needs
similar bounded builders; do not reuse legacy recursive concatenation unchecked.

## Decision 4: field-path-aware decoders, with ordinary Result composition

Add a proposed `std:jsondecode` library over JsonValue, separately from I/O:

```typescript
type PathSegment = Key(string) | Index(usize);
type DecodeError = {
  kind: DecodeErrorKind; path: PathSegment[];
  expected: string; actual: string;
};
```

Kinds: `MissingField | WrongType | NotIntegral | IntegerRange | FloatOverflow |
FloatUnderflow | UnknownField | DuplicateField | LimitExceeded | InvalidLimits |
InvalidSchema`. Paths are structural, never dot-split strings: a key `"a.b"` is
one Key, and an array index is Index. The formatter uses `/servers/1/port`, escapes
`~` as `~0` and `/` as `~1`, and uses the empty string for root. A missing field
includes the missing key in its path. `actual` contains only a type/range category,
not a raw secret or complete value. No byte offset is invented for caller-built
values; source spans are a separate optional future facility.

Small initial API, all fallible helpers returning `Result<..., DecodeError>`:

| Helper | Successful value / rule |
|---|---|
| `decodeRoot(value, limits)` | DecodeCursor; validates the tree against traversal budgets and rejects duplicate decoded keys, including on manually constructed trees |
| `requiredField(cursor, key)` | child cursor; missing is MissingField; non-object parent is WrongType |
| `optionalField(cursor, key)` | Option<DecodeCursor>; None means absent only; present null is Some and remains distinct |
| `decodeString(cursor)`, `decodeBool(cursor)`, `decodeNumber(cursor)` | string, bool, exact JsonNumber respectively; no string/number coercion |
| `decodeInt(cursor, min: int, max: int)` | exact integral int plus inclusive range; min > max is InvalidSchema, never a trap |
| `decodeFloatRounded(cursor)` | explicit rounded conversion with finite/underflow rules above |
| `decodeArray(cursor)` | child cursors with Index paths, within container budget |
| `checkFields(cursor, allowed: string[], policy: UnknownFieldPolicy)` | void; RejectUnknown or IgnoreUnknown must be explicit; reject first unknown in document order |

Cursor operations are value operations using existing language facilities. A
cursor carries the value, structural path and validated limits; it grants no I/O.
The DecodeCursor record is sealed; only root/navigation helpers construct it.
Root validation visits values depth-first in document order and validates UTF-8
in keys and strings. It is O(tree bytes/nodes), with expected-linear duplicate indexing.
Field lookup remains O(m + path depth) for m members; q lookups are O(q*m), not
magically O(m). `checkFields` may use an allowed-key map for expected O(m+k);
array cursors allocate O(elements * path depth). State those bounds, cap them,
and measure before adding an indexed object API. Repeated caller operations are
not covered by a hidden global work quota. Fail-fast errors keep ordering stable.

Illustrative future API example (not compilable until the proposed libraries exist):

```typescript
type Config = { endpoint: string; port: int; enabled: bool; };
function decodeConfig(v: JsonValue): Result<Config, DecodeError> {
  const root = decodeRoot(v, defaultJsonLimits())?;
  checkFields(root, ["endpoint", "port", "enabled"], RejectUnknown)?;
  const endpoint = decodeString(requiredField(root, "endpoint")?)?;
  const port = decodeInt(requiredField(root, "port")?, 1, 65535)?;
  const flag = optionalField(root, "enabled")?;
  let enabled = true;
  if (flag.isSome()) { enabled = decodeBool(flag.unwrap())?; }
  return Ok(Config { endpoint: endpoint, port: port, enabled: enabled });
}
// Caller first parseDocument(text, defaultJsonOptions()), then decodeConfig(value).
// Keep parse errors and decode errors separate; no implicit Result error conversion.
```

Nullable fields require an explicit ValueNull match; optional does not mean
nullable. Application validation adds domain constraints using the same path
segments. No `parse<T>`, annotation processor, reflection or automatic coercion.

## Migration and bounded delivery

1. Coordinator reviews this RFC, especially new-tree naming, strict defaults and
   lexeme equality. This PR alone authorizes no implementation.
2. Add exact numbers plus bounded parse/write and constructors, tests, docs and
   MCP API entries. Existing std:json fixtures and compiler protocol snapshots
   stay unchanged. Correct public i64-minimum rejection only as a separately
   identified bug fix with a deliberately updated golden.
3. Add decoders and one pure config example; no filesystem/process dependency.
4. Consider explicit bridges: `fromLegacy(Json, limits): Result<JsonValue, ...>`
   and `toLegacy(JsonValue, limits): Result<Json, ...>`. The latter uses exact
   numberAsInt, so `1.0` may become JNum(1); fractional/out-of-range values fail at
   their paths. Bridges lose lexeme distinctions explicitly. Existing legacy
   minimum-integer parse inconsistency remains a separately tracked limitation.
5. Audit compiler JSON consumers before any unification. Fraction truncation of
   protocol coordinates/limits deserves a separately reviewed rejection fix,
   not an unnoticed change bundled into the public library. Preserve integer
   JSON-RPC IDs, error behavior, OSIG equality and bootstrap consistency.

No arbitrary-precision arithmetic, decimal business arithmetic, streaming parser,
full protocol migration or frozen runtime/language change belongs in this slice.

## Future executable acceptance cases

These are concrete **future tests**, not assertions that this PR implements them.
All must run on C and LLVM with contracts on/off; malformed input must return Err.

| Case | Required result |
|---|---|
| `9007199254740993`, both i64 endpoints, `18446744073709551615` | exact token write-back; exact int conversion where in i64 range, otherwise IntegerRange |
| `1.00`, `1e3`, `1e-3`, `-0.00`, `1e999`, `1e-999` | unchanged numeric spelling on write; ints 1/1000/NotIntegral/0/IntegerRange/NotIntegral; float overflow/underflow reported rather than Infinity/zero for final two |
| `0e` followed by a huge valid exponent | zero converts to int 0 without exponent-sized allocation; token budget still enforced |
| `+1`, `01`, `.5`, `1.`, `1e`, `1e+`, `NaN`, `Infinity` | InvalidNumber; `1e+` reports EOF offset 3; `[01]` reports offset 2 |
| `{"a":1,"\u0061":2}` | default duplicate error at byte 7; preserve mode retains both members; decodeRoot rejects the duplicate path `/a` |
| root depth at/above limit; items/nodes/string/number/output at N and N+1 | exact boundary succeeds/fails with specified limit kind and bounded offset; no overflow/trap before rejection |
| invalid UTF-8; lone `\ud800`; valid paired surrogate | new API rejects first two and accepts pair; legacy behavior untouched |
| `{ "servers": [ {"port":80}, {"port":1.5} ] }` | NotIntegral at `/servers/1/port`; missing port same path with MissingField |
| absent/null/false optional bool; unknown keys; reversed min/max | None / WrongType / false; explicit unknown policy; InvalidSchema |
| keys `"a.b"`, `"a/b"`, `"~"`, `""` | distinct Key segments; display `/a.b`, `/a~1b`, `/~0`, `/` |
| construct number from NaN or Infinity; outside sealed record construction | factory Err(NonFinite); external literal/field assignment compile errors |

Example future test body:

```typescript
@Test function exactIntegerId(): void {
  const value = parseDocument("9007199254740993", defaultJsonOptions()).unwrap();
  assertEqString(writeDocument(value, defaultJsonLimits()).unwrap(),
    "9007199254740993", "ID spelling preserved");
  const cursor = decodeRoot(value, defaultJsonLimits()).unwrap();
  assertEq(decodeInt(cursor, 0, 9223372036854775807).unwrap(),
    9007199254740993, "ID never passes through float");
}
```

Use deterministic generated valid tokens and malformed mutations, including
exponent sign/digit boundaries and every truncation point. Check stable parse/write
structural laws within budgets; do not compare only paired encoders that can share
a bug. Measure 64 KiB/256 KiB/1 MiB documents with many small numbers and long
tokens, invalid suffixes, duplicate-heavy objects and deep containers. Report
wall time/allocation and hash-collision limits separately from linear-time goals.
Check bootstrap if embedding/resolver/compiler glue changes. No proof of these
algorithms is claimed by this design document.

## Approved first implementation slice: std:jsonnumber

Coordinator direction after RFC approval narrows the first delivery to sealed
JsonNumber, jsonNumber, numberFromInt, numberAsInt and error formatting, in a
separate `std:jsonnumber` module. Dedicated registration keeps legacy std:json
imports and its embedded source independent of the new implementation; existing
Json/JNum and both parsers are unchanged. Numeric type identities are therefore
owned by std:jsonnumber; a future JsonValue module can import/re-export them
rather than define a second number type. Float utilities, document parsing/writing,
decoders and bridges remain proposals, not shipped APIs. See
[the concrete number API](../std-jsonnumber.md) for this slice's contract.

## Approved document slice: std:jsonvalue

The bounded parser/compact-writer slice is a separate std:jsonvalue module,
consistent with the reviewed std:jsonnumber placement. It owns JsonValue,
JsonMember, document limits/options and document errors, and imports the existing
sealed number type instead of duplicating it. This keeps opt-in tree semantics
and stricter Unicode/duplicate policies distinct from both legacy parsers.
No JsonValue re-export or behavior change is added to std:json. Float conversion,
decoders and protocol migration remain deferred. See the
[document API and exact error policies](../std-jsonvalue.md).
