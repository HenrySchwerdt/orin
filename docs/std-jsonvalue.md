# std:jsonvalue — bounded opt-in JSON documents

Implements the document slice of the [JSON RFC](rfcs/json-completeness.md), using
[std:jsonnumber](std-jsonnumber.md) for exact numeric tokens. This is a separate
module: legacy `std:json.Json`/`JNum(int)` and both existing parsers retain their
behavior. No float conversion, decoders, pretty printer or protocol migration is
included. New values have independent variant names and type identities.

## API and representation

```typescript
type JsonValue = ValueNull | ValueBool(bool) | ValueNumber(JsonNumber)
  | ValueString(string) | ValueArray(JsonValue[]) | ValueObject(JsonMember[]);
type JsonMember = { key: string; value: JsonValue; };
type JsonDuplicatePolicy = RejectDuplicates | PreserveDuplicates;
type JsonReadOptions = { limits: JsonLimits; duplicates: JsonDuplicatePolicy; };
```

| Signature | Meaning |
|---|---|
| `defaultJsonLimits(): JsonLimits` | the explicit defaults below |
| `defaultJsonOptions(): JsonReadOptions` | default limits and RejectDuplicates |
| `parseDocument(text: string, options: JsonReadOptions): Result<JsonValue, JsonParseError>` | one complete UTF-8 JSON document, optional surrounding JSON whitespace |
| `writeDocument(value: JsonValue, limits: JsonLimits): Result<string, JsonWriteError>` | compact output; validates budgets and UTF-8 even for caller-built trees |

Objects are ordered member lists. Parsing in preserve mode and writing retain
member order and duplicate occurrences; no implicit map conversion takes place.
Numbers retain their exact validated ASCII spelling, including huge integers,
exponents, trailing zeros and negative zero. No numeric conversion takes place.
Only std:jsonnumber can construct/mutate its existing sealed JsonNumber type.

```typescript
import { parseDocument, writeDocument, defaultJsonOptions, defaultJsonLimits,
  JsonValue, JsonMember } from "std:jsonvalue";
import { numberFromInt } from "std:jsonnumber";
function main(): void {
  const value = parseDocument("{\"id\":9007199254740993,\"n\":1.00e+3}", defaultJsonOptions()).unwrap();
  console.log(writeDocument(value, defaultJsonLimits()).unwrap());
  const built = ValueObject([
    JsonMember { key: "port", value: ValueNumber(numberFromInt(8080)) },
  ]);
  console.log(writeDocument(built, defaultJsonLimits()).unwrap());
}
```

For duplicate preservation, import `JsonDuplicatePolicy` as well as
`JsonReadOptions`, and pass `JsonReadOptions { limits: defaultJsonLimits(),
duplicates: PreserveDuplicates }`. Default rejection compares **decoded UTF-8 key
bytes**: `"a"` and `"\u0061"` collide, as do literal/escaped representations of the
same non-ASCII key. Case and Unicode normalization are not applied. Duplicate
checks are scoped to each object; preserve mode does not build a duplicate index.
Writers always preserve supplied lists, irrespective of how values were built.

## Strict text and number rules

Numbers use the strict full-token JSON number grammar implemented by
std:jsonnumber. Leading plus/zeros, incomplete fractions/exponents, NaN and
Infinity are errors; large finite-text exponents are accepted within the token
budget without conversion or expansion. Surrounding whitespace is limited to
space, tab, LF and CR. Comments, BOM, trailing commas and trailing values are
rejected. Strings reject raw controls and unknown escapes.

The entire source is UTF-8 validated before syntax parsing. Escapes decode only
Unicode scalar values: valid surrogate pairs become four UTF-8 bytes, and lone
or mismatched surrogates are errors. There is no replacement-character fallback.
UTF-8 checks also apply to caller-built writer strings and keys. NUL is allowed
in a decoded string and written as `\u0000`; slash is emitted without escaping.
Other control bytes use `\b \f \n \r \t` or lowercase `\u00xx`.

`writeDocument(parseDocument(text, options), limits)` preserves numeric lexemes,
ordered members and decoded string values, not source whitespace or string-escape
spelling. For structural round trips, both operations must have sufficient
budgets and readers must preserve duplicates when the tree contains them. The
writer's output budget may exceed a reader's input budget; choose both explicitly.
This is not numeric equality or a canonical JSON/signing representation.

## Limits

JsonLimits is a value record with these public usize fields. All fields must be
positive and maxDepth must be <= 200, even if a field is unused in the operation.
Readers consume every budget except maxOutputBytes; writers consume every budget
except maxInputBytes. Defaults do not change based on machine, input or backend.

| Field | Default | Count |
|---|---:|---|
| maxInputBytes | 1,048,576 | complete source bytes, including whitespace |
| maxDepth | 64 | simultaneously open containers; root scalar 0, root container 1 |
| maxNodes | 100,000 | every value including containers; keys are not nodes |
| maxContainerItems | 10,000 | elements/members per container; duplicate members count |
| maxStringBytes | 262,144 | decoded bytes in one key or string value |
| maxDecodedStringBytes | 1,048,576 | aggregate decoded key/value-string bytes, occurrences included |
| maxNumberBytes | 1,024 | full numeric token bytes, including sign and exponent |
| maxOutputBytes | 4,194,304 | actual encoded output bytes, checked before append |

These are per-call work/storage limits, not an application-wide memory quota.
The source and caller-built tree already exist: the API cannot bound their
upstream allocation. Counters use remaining-budget comparisons before additions;
no limit arithmetic or malformed input is intended to trap. Allocation failure
retains runtime behavior; no streaming or OOM recovery is provided. The 200-depth
ceiling is a tested implementation limit, not a universal stack-size proof.
Shared subtrees count on each occurrence, matching their serialized expansion.

## Structured errors and precedence

```typescript
type JsonValueErrorKind = JsonSyntax | JsonInvalidUtf8 | JsonInvalidSurrogate
  | JsonDuplicateKey | JsonLimitExceeded | JsonInvalidLimits;
type JsonParseError = {
  kind: JsonValueErrorKind; offset: usize; line: usize; column: usize;
  limit: Option<string>;
};
type JsonWriteError = { kind: JsonValueErrorKind; limit: Option<string>; };
```

Parse offset is zero-based in source **bytes**, or source length at EOF; line
and column are 1-based byte coordinates, with LF advancing a line (CR alone does
not). Errors are fail-fast; no partially parsed value or partially written
string is returned. Writers have no source position because their tree may have
been built directly. Writer error kinds are InvalidLimits, LimitExceeded or
InvalidUtf8; syntax, surrogate and duplicate errors belong to parsing only.

Precedence is invalid options, input byte budget, whole-source UTF-8, then parsing
left to right. A bad UTF-8 byte later in a document can therefore precede an
earlier grammar error. JsonInvalidUtf8 points to the start of the first invalid
sequence, matching std:utf8.checkUtf8 (not necessarily its failing continuation).
Within parsing:

- Missing expected bytes/digits/terminators at EOF report source length. Other
  grammar errors point to the offending byte (`[01]` points to 2; `1e+` to EOF 3).
- Invalid hexadecimal escape digits report that digit or EOF. A complete high
  surrogate lacking a valid low surrogate reports its first backslash. If a
  started following `\u` is itself truncated/malformed, its digit/EOF syntax
  error is reported first. Lone low surrogates point to their backslash.
- Duplicates point to the second key's opening quote, after successfully decoding
  it. Its decoded-string budgets must therefore pass before a duplicate is known.
- LimitExceeded has Some of the exact field name above. Input limits point to
  the first excluded byte; depth to the disallowed opening delimiter; nodes and
  items to the next disallowed value/member. A key is checked against item count
  before it is decoded.
- String limits point to the source byte producing the first excessive decoded
  byte. All output bytes of one escape map to its backslash, so a four-byte
  surrogate-pair result exceeding a three-byte budget points to that backslash.
- Number scanning bounds the maximal candidate of digits/signs/dot/e/E before
  validating its full grammar, mirroring jsonNumber's size-before-syntax policy.
  A candidate exceeding maxNumberBytes reports its first excluded byte even
  when the candidate also contains an earlier numeric grammar error.

Other errors have limit None. Writer order is options, preorder node/depth/item
budgets, then field/value traversal in order. A string checks single/aggregate
size, UTF-8 and output emission in that order; a number checks token size before
output. A writer can reject an oversized array/object from its length before
visiting children. Reader and writer need not select the same limit when several
limits would be exceeded.

## Complexity and allocation

For n source bytes, parsing takes O(n) **expected** time, plus O(n) to locate
line/column on an error. Duplicate rejection uses the existing string Map, whose
non-cryptographic hash can degrade under adversarial collisions; no deterministic
linear or execution-time guarantee is claimed for that policy. Explicit input,
member and key budgets bound the exposed sizes. Preserve mode skips that index.
Parsing stores O(input + tree) bytes/records plus a depth-bounded stack. Decoded
strings use unique growable byte arrays and one final conversion, with an empty
literal fast path. Numeric token substrings are bounded before allocation.

Writing is O(nodes + visited string/number bytes + output bytes), using one
unique byte buffer and a final string conversion. Output storage is O(output),
plus the depth-bounded stack. Both operations avoid repeated whole-buffer copies,
including in checked builds: private buffer operations do not snapshot old(this)
per byte. Existing u8[] elements occupy eight-byte slots; compact strings occupy
one byte per byte. A single decoded string may temporarily hold both forms.
Default record constructors are O(1). Contracts check error/output bounds and
state counter invariants; no static proof of all recursive algorithms is claimed.

## Reproducing validation

```
sh tools/bootstrap.sh
ORIN2=build/bootstrap/orin2 sh tools/test_std.sh tests/std/jsonvalue_test.or
python3 tools/check_jsonvalue.py
python3 tools/run_tests.py --orinc build/bootstrap/orin2 --suite next --filter std_json
```

Tests cover independent known trees and writer vectors, exact numbers, all JSON
value kinds, decoded duplicate policies, Unicode/surrogate boundaries, malformed
and truncated inputs, byte/line/column positions, every limit at N/N+1, invalid
options, caller-built writer budgets/UTF-8, 200-container nesting, deterministic
structural laws, large escaped strings and many ordered keys. The check tool adds
independent Python trees and token-preserving input/writer references, C/LLVM
contracts on/off, C ASan/UBSan and deterministic string/number/object/duplicate
scaling. Sanitizer leak detection is disabled; no leak-freedom claim follows.

## Measured scaling (2026-10-16)

Apple M4 arm64, macOS, clang -O2, contracts off. Each process constructs a
controlled source, performs two parse/write rounds, verifies exact compact output
against that source, and checks an invalid suffix twice. The duplicate family
also checks strict rejection once. Unique objects use RejectDuplicates, including
its Map index; repeated-key objects use PreserveDuplicates for the round trips.
Wall times include construction, startup and all checks. Median of three runs
after one unrecorded warmup; checksum is twice the listed source byte count.

| Pattern | Source bytes | C seconds | LLVM seconds |
|---|---:|---:|---:|
| ASCII string | 65,538 | 0.005495 | 0.006689 |
| ASCII string | 262,146 | 0.008505 | 0.008540 |
| ASCII string | 1,048,578 | 0.031750 | 0.032068 |
| Exact-number array | 65,537 | 0.005985 | 0.005213 |
| Exact-number array | 262,145 | 0.013963 | 0.013730 |
| Exact-number array | 1,048,577 | 0.052636 | 0.051424 |
| Unique-key object (reject) | 42,571 | 0.008042 | 0.008973 |
| Unique-key object (reject) | 174,565 | 0.016627 | 0.015186 |
| Unique-key object (reject) | 731,621 | 0.056650 | 0.061703 |
| Repeated-key object (preserve) | 32,761 | 0.003506 | 0.003536 |
| Repeated-key object (preserve) | 131,065 | 0.009958 | 0.009750 |
| Repeated-key object (preserve) | 524,281 | 0.035026 | 0.035293 |

The sizing parameter is 64/256/1024 KiB; actual source sizes differ by pattern and
are listed. Benchmark limits are explicitly enlarged to accommodate the largest
strings and node/member counts: maxInputBytes and maxDecodedStringBytes are
2*n+64, maxStringBytes/maxNodes/maxContainerItems are n+64, with other defaults
retained. This measures validated larger configurations, not default acceptance
of a 1 MiB single string or 131,072-element array.

The final roughly 4x source-size steps take approximately 3.4–4.1x time across
these cases/backends, consistent with linear scans plus fixed costs. This is not
a proof or throughput promise. Adversarial hash collisions, peak memory,
contract-enabled performance, other platforms and larger sources were not measured.

Local evidence: 181 independent Python tree/token/writer vectors plus all nine
test groups pass on C/LLVM with contracts on/off and C ASan/UBSan (leak detection
disabled). The maximum supported 200-container path is included. Bootstrap reaches
stage2 == stage3 (11,007,284 bytes), with 141 default conformance tests passing.
All 13 focused std_json conformance cases pass, including the new checked document
smoke case and unchanged legacy fixtures. Four MCP inspection entries and the
runnable documentation example pass. Local platform evidence is macOS arm64;
Linux CI is still required before integration.
