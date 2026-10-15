# std:jsonnumber — exact JSON number values

This module implements only the first number-utility slice of the
[JSON RFC](rfcs/json-completeness.md). Existing `std:json.Json`, `JNum(int)`, public
and compiler-internal parsers remain unchanged. No document parser/writer,
decoders, float conversion or arithmetic is provided.

```typescript
@Sealed type JsonNumber = { token: string; };
type NumberError = { kind: NumberErrorKind; offset: Option<usize>; };
```

`token` is the exact ASCII input spelling. Only this module can construct or
change a JsonNumber, using existing `@Sealed` enforcement. The checked factory
validates even with contracts disabled. Values retain their immutable input
string; copying a value does not copy the token buffer. `1`, `1.00`, `1e0`, `-0`
and `-0.0` are distinct spellings; integer conversion can return the same integer
for them. There is no numeric equality/canonicalization operation.

| Signature | Behavior |
|---|---|
| `jsonNumber(text: string, maxBytes: usize): Result<JsonNumber, NumberError>` | strict full-token validation and positive byte budget |
| `numberFromInt(n: int): JsonNumber` | exact machine-integer spelling, including -9223372036854775808 |
| `numberAsInt(n: JsonNumber): Result<int, NumberError>` | exact mathematical integer in full i64 range; never rounds/truncates or converts through float |
| `numberErrorMessage(e: NumberError): string` | stable human-readable reason, with byte offset when present |

```typescript
import { jsonNumber, numberAsInt, numberFromInt } from "std:jsonnumber";
function main(): void {
  const n = jsonNumber("9.007199254740993e15", 1024).unwrap();
  console.log(n.token); // 9.007199254740993e15
  console.log(numberAsInt(n).unwrap().toString()); // 9007199254740993
  console.log(numberFromInt(-9223372036854775807 - 1).token);
}
```

## Grammar and errors

ASCII grammar: `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`.
No whitespace, leading plus, leading zeros, separators, NaN, Infinity, hex,
incomplete fraction/exponent, embedded NUL or trailing bytes are accepted.
An exponent may have leading zeros and any magnitude within the byte budget.

Current factory/conversion failures:

| Kind | Offset | Rule |
|---|---|---|
| `InvalidLimits` | None | maxBytes == 0; checked first |
| `NumberLimit` | Some(maxBytes) | input exceeds budget; checked before scanning syntax, even when the input is also malformed |
| `InvalidNumber` | Some(byte) | first offending byte, or input length for a missing digit at EOF |
| `NotIntegral` | None | valid nonzero decimal has a nonzero fractional remainder |
| `IntegerRange` | None | valid integral result is outside [-9223372036854775808, 9223372036854775807] |

Examples: `01` fails at 1, `-01` at 2, `1.` at EOF 2, `1e+` at EOF 3, `1e+x` at
3. Offsets count bytes, not Unicode characters. Conversion failures have no syntax
offset because their tokens are valid. Non-integrality is decided before range
when a value has a fractional remainder, including very large coefficients.
Every spelling of coefficient zero converts to 0, including negative zero and
arbitrarily large positive/negative exponents. The original token remains intact.

`NumberErrorKind` also contains `NonFinite | FloatOverflow | FloatUnderflow`,
reserved by the approved RFC. They are not emitted by these functions; keeping
the approved enum now avoids a later exhaustive-match break when separately
reviewed float utilities are added.

## Complexity, allocation and implementation limits

For n token bytes, validation is O(n), or O(1) for invalid/over-budget limits.
Integer conversion is O(n) with O(1) extra space. Factories/conversion allocate
only fixed-size value/result/error records; the validator retains the input
string. `numberFromInt` and error formatting are bounded by machine-int width and
fixed messages (O(1)), with short string allocation. Contract checks preserve
these bounds; no whole-token revalidation occurs inside a byte loop.

The converter counts significant coefficient digits, fractional digits and
trailing zeros. It scans exponent digits with saturation at token length + 20;
this threshold already implies range/non-integrality for a nonzero coefficient.
Existing runtime strings are bounded by 2^48 bytes (`str_alloc`), leaving ample
usize headroom for that addition. Decimal shift cancellation happens with counts,
not expanded strings; at most 19 resulting digits are accumulated on the negative
side to support i64 minimum. No float conversion, exponent-sized allocation or
whole-buffer copying occurs.

The input string already exists when the factory receives it: maxBytes does not
bound upstream input allocation. There is no hard module token cap beyond the
caller's budget and existing runtime string/memory limits. Allocation failure
retains runtime behavior; this is not an OOM recovery API. Contracts and tests
provide evidence, not a static proof of all loop arithmetic.

## Validation

```
sh tools/bootstrap.sh
ORIN2=build/bootstrap/orin2 sh tools/test_std.sh tests/std/jsonnumber_test.or
python3 tools/check_jsonnumber.py
python3 tools/run_tests.py --orinc build/bootstrap/orin2 --suite next --filter jsonnumber
```

Tests cover exact spellings, full i64 extrema and neighbors, values above 2^53,
decimal/exponent cancellation, non-integral/range precedence, huge exponents and
zero, all byte classes, every truncation of a representative token, budget
precedence, exact byte errors, 2,000 int round trips, 100,000-byte stress tokens,
and sealed construction/mutation compile errors. The check tool adds an
independent Python Decimal/regular-expression oracle, C/LLVM contracts on/off,
C ASan/UBSan, and deterministic scaling measurements. Float utilities, JSON tree
migration and any change to the legacy parser's i64-minimum behavior remain deferred.

## Measured scaling (2026-10-15)

Apple M4 arm64, macOS, clang `-O2`, contracts off. n is the repeated zero/nine
run length; four slightly larger tokens exercise a huge positive exponent,
zero with huge negative exponent, fractional/exponent cancellation to 1, and an
invalid suffix. Sixteen rounds validate every token and convert valid ones.
Process startup and construction of the shared input strings are included.
Median of three runs after one unrecorded warmup; checksum is 48 in every case:

| n bytes | C seconds | LLVM seconds |
|---:|---:|---:|
| 65,536 | 0.009165 | 0.009400 |
| 262,144 | 0.018748 | 0.016759 |
| 1,048,576 | 0.057718 | 0.056840 |

The largest 4x input step took 3.1x/3.4x time, consistent with linear scans plus
fixed startup/construction overhead. This is not a proof or throughput promise.
Peak memory, individual operations, contract-enabled performance, input beyond
1 MiB runs and other operating systems were not measured.

Local verification: 2,007 independently generated cases (seed 20261015) plus all
seven test groups passed on C/LLVM with contracts on/off, and on C ASan/UBSan
(leak detection disabled). The independent oracle uses Python's full-match regex
and exact Decimal values; generated astronomic exponents beyond Decimal's own
storage limit are classified symbolically against the bounded generated
coefficient lengths, without expansion. Bootstrap reached stage2 == stage3
(10,980,860 bytes) and passed 141 default conformance tests. Two sealed-type
negative cases and all 12 existing std_json conformance cases passed. MCP
inspection of the four functions and the runnable example also passed.
