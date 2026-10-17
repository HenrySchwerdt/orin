# std:url — percent components and query pairs

`import { percentEncode, percentDecode, parseQuery, stringifyQuery, QueryPair, PlusAsSpace, PercentSpace } from "std:url";`

This pure Orin module needs no capabilities. It handles components and query bodies; it does not parse
whole URLs, resolve hosts, normalize paths, or promise browser/WHATWG URL behavior. Strings in Orin
are byte strings. All lengths and error offsets here count bytes, not Unicode code points.

## API

```typescript
type UrlErrorKind = TruncatedEscape | InvalidHex | InvalidUtf8;
type UrlError = { kind: UrlErrorKind; offset: usize; };
type QueryPair = { key: string; value: string; };
type QueryEncodeErrorKind = InvalidKeyUtf8 | InvalidValueUtf8;
type QueryEncodeError = { kind: QueryEncodeErrorKind; pairIndex: usize; offset: usize; };
type FormSpace = PlusAsSpace | PercentSpace;

percentEncode(s: string, space: FormSpace): string
percentEncodeBytes(b: Bytes, space: FormSpace): string
percentDecode(s: string, space: FormSpace): Result<string, UrlError>
percentDecodeBytes(s: string, space: FormSpace): Result<Bytes, UrlError>
parseQuery(s: string, space: FormSpace): Result<QueryPair[], UrlError>
stringifyQuery(pairs: QueryPair[], space: FormSpace): Result<string, QueryEncodeError>
urlErrorMessage(e: UrlError): string
queryEncodeErrorMessage(e: QueryEncodeError): string
```

The space mode is a required argument of type `FormSpace` (ADR-0048 rule 2.5; it replaces the `spaceAsPlus` /
`plusAsSpace` booleans, which had opposite polarity in encoders and decoders). Use `PercentSpace` for ordinary
percent components and `PlusAsSpace` for query form-style spaces: with `PlusAsSpace` encoding writes ASCII space as
`+` and decoding reads a raw `+` as a space. Encoding leaves only ASCII letters, digits and `-._~` unchanged; all
other bytes become uppercase `%HH`, except that `PlusAsSpace` emits `+` for ASCII space. Literal `+` always
encodes as `%2B`. UTF-8 text is encoded byte by byte: `percentEncode("café 🐈", PercentSpace)` produces
`caf%C3%A9%20%F0%9F%90%88`. No Unicode normalization occurs. The two encoders also accept invalid
UTF-8 and NUL; a Bytes view encodes only its selected bytes.

Decoding accepts either hex case, performs one decoding pass, and leaves other raw bytes unchanged.
`PercentSpace` preserves a raw `+`; `PlusAsSpace` changes it to space, while `%2B` still becomes literal
plus. `percentDecode("a+%2B%2520", PlusAsSpace)` yields `a +%20`. The Bytes decoder permits every decoded byte.
The text decoder validates the complete decoded component using `std:utf8.validate`, rejecting
invalid leading/continuation bytes, overlong forms, surrogates, truncated sequences and values above
U+10FFFF. Raw invalid UTF-8 is rejected too. Neither decoder strips whitespace or replaces bad bytes.

A malformed percent escape returns `TruncatedEscape` if fewer than two following bytes remain in the
component, otherwise `InvalidHex` if either digit is not hex. Its offset points to `%`. Escapes are
validated before decoded UTF-8 within each component, so `%FF%Q0` reports `InvalidHex` at byte 3.
`InvalidUtf8` points to the **original input location of the first byte of the invalid decoded
sequence**, whether literal or `%HH`: `a%20%80` reports byte 4. On the UTF-8 error path the module
translates the validator's decoded offset back to the source with one linear scan. It does not
allocate a per-byte offset table.

## Query policy

Pass a query body, excluding `?` and fragment delimiters:

```typescript
const pairs = parseQuery("a=1&a=2&flag&=x&plus=a+b%2Bc", PlusAsSpace).unwrap();
// [{key:"a", value:"1"}, {key:"a", value:"2"}, {key:"flag", value:""},
//  {key:"", value:"x"}, {key:"plus", value:"a b+c"}]
const wire = stringifyQuery(pairs, PlusAsSpace).unwrap();
// a=1&a=2&flag=&=x&plus=a+b%2Bc
```

The parser splits at raw `&`, then the first raw `=` in each field, **before decoding**. Encoded
separators are data. Additional `=` bytes belong to the value. Empty fields (including leading,
trailing and consecutive `&`) are skipped: `""` and `"&&"` both produce `[]`. Bare keys have an empty
value; `flag` and `flag=` are equivalent. Empty keys are retained: `=x` is one pair and `=` is one
empty key/value pair. Duplicates retain source order; there is no Map conversion or sorting. Semicolon,
`?` and `#` have no delimiter meaning. Raw spaces and controls are accepted as UTF-8 bytes; applications
should impose their own field policy.

Keys and values are strict UTF-8. Parse errors use absolute offsets in the whole query body. Fields
are processed in source order, keys before values, with the component error precedence above. No
partial pairs are returned on error. The serializer also validates keys and values; its error has a `kind`
(`InvalidKeyUtf8` or `InvalidValueUtf8`), the zero-based pair index, and the invalid sequence's byte offset **within
that key/value**; `queryEncodeErrorMessage` renders it (`invalid UTF-8 in value in pair 0 at byte 4`).
(`QueryEncodeError` replaces the old `inValue: bool` field with `kind`, per ADR-0048 rule 3.1.) It always emits `key=value` joined by `&`, with no leading `?`. It retains pair order
and encodes all separators within keys and values. An empty list emits `""`; one empty pair emits `"="`.

For valid UTF-8 pairs, `parseQuery(stringifyQuery(pairs, mode).unwrap(), mode)` preserves every pair.
Arbitrary wire queries normalize on serialization (bare keys gain `=`, empty fields disappear, escape
case becomes uppercase, unreserved escapes become literal). For arbitrary bytes,
`percentDecodeBytes(percentEncodeBytes(b, mode), mode)` returns the same bytes. Text round trips require
valid UTF-8; byte encoding is intentionally more permissive than text decoding.

## Cost and validation

Every operation is linear in bytes processed, plus pair count for query serialization; error paths
are linear too. No loop grows a string with repeated concatenation. Output uses geometric byte-array
growth through `ByteBuilder`; `reserve` is not assumed to preallocate. Encoding emits at most three
bytes per input byte. Decoding emits at most the encoded input length. All encode/decode operations
allocate O(n) buffer/result storage. Bytes encoding additionally copies to a raw string; Bytes decoding
uses a temporary raw string then copies into Bytes. Text decoding uses a builder and final string.
Parsing allocates an ordered pair array, component buffers and strings; it scans source ranges without
copying encoded substrings. Serialization allocates temporary component encodings, one result buffer
and the final string. Errors can leave partially built temporary buffers to be reclaimed. No view
of mutable storage is exposed. `urlErrorMessage` allocates a bounded message in O(1) for machine offsets.
These bounds describe normal builds; runtime allocation exhaustion follows the ordinary Orin trap policy.

Length/error-bound contracts complement tests; they are not a claim of a full static correctness proof.
`tests/std/url_test.or` checks known vectors, malformed percent/UTF-8, original offsets, all 256 byte
round trips, both plus modes, pair round trips, duplicate ordering and normalization. Run:

```sh
ORIN2=build/bootstrap/orin2 tools/test_std.sh tests/std/url_test.or
python3 bench/url/check.py --orin build/bootstrap/orin2
```

The second command executes the same assertions through C and LLVM, contracts on and off, and runs a
small repeatable benchmark; see [bench/url/README.md](../bench/url/README.md). No external service is used.
