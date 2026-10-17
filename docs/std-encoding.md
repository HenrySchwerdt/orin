# std:encoding

Design note: pure byte codecs using existing `Bytes` and `ByteBuilder`, without
new syntax or runtime primitives. Encoders produce ASCII strings; decoders consume
`Bytes`, and every decoder has a `<codec>DecodeText` twin that takes a `string` (the
same bytes, see ADR-0048 rule 7.2). This preserves byte offsets even for
non-ASCII and invalid UTF-8 input. This module is the one home of hex:
`Bytes.toHex()` is what `hexEncode` calls and the old `bytes.bytesFromHex` (an `Option`)
is deprecated in favour of `hexDecodeText`. Import it as a namespace, `import * as encoding`. These are data encodings, with no encryption,
authentication, constant-time or other cryptographic guarantees.

| Public signature | Behavior |
|---|---|
| `hexEncode(src: Bytes): string` | Lowercase hex, two digits per byte |
| `hexDecode(src: Bytes): Result<Bytes, EncodingError>` | Either case; no whitespace or prefix; even length required |
| `hexDecodeText(s: string): Result<Bytes, EncodingError>` | `hexDecode` of the bytes of `s` |
| `base64Encode(src: Bytes, padding: Padding): string` | RFC 4648 standard alphabet (`+/`) |
| `base64Decode(src: Bytes, padding: Padding): Result<Bytes, EncodingError>` | Strict standard alphabet |
| `base64DecodeText(s: string, padding: Padding): Result<Bytes, EncodingError>` | `base64Decode` of the bytes of `s` |
| `base64UrlEncode(src: Bytes, padding: Padding): string` | RFC 4648 URL alphabet (`-_`) |
| `base64UrlDecode(src: Bytes, padding: Padding): Result<Bytes, EncodingError>` | Strict URL alphabet |
| `base64UrlDecodeText(s: string, padding: Padding): Result<Bytes, EncodingError>` | `base64UrlDecode` of the bytes of `s` |
| `encodingErrorMessage(e: EncodingError): string` | Human-readable error with byte offset |

`Padding = Padded | Unpadded` (ADR-0048 rule 2.5; it replaces the `padded: bool` parameter).
`Padded` requires the exact canonical `=` suffix, including length divisible
by four. `Unpadded` forbids every `=` and accepts final groups of two or three
digits. Complete groups need no suffix in either mode. All decoders reject spaces,
line breaks, other non-alphabet bytes, mixed alphabets and nonzero unused pad bits.
Empty input succeeds. No malformed input traps or returns partially decoded data.

`EncodingError = { kind: EncodingErrorKind; offset: usize }`, where kinds are
`InvalidByte | InvalidLength | InvalidPadding | NonCanonical` (`position` was renamed `offset`, ADR-0048 rule 3.1).
Offsets are zero-based offsets into the supplied view, never backing storage:
an invalid byte points to that byte; forbidden/misplaced padding points to `=`
(or the first later data byte); noncanonical bits point to the last data digit;
length/suffix errors point to end of input (`src.length()`). Hex validates bytes
before checking length. Base64 validates bytes and padding placement before length,
then canonical bits. This defines error precedence for multiply malformed inputs.

All codecs take O(n) time and O(n) output/storage, including contracts enabled;
helpers and error formatting are O(1). Encoders append byte values, then convert
once to string. Decoders scan once for validation and once for output; neither
repeatedly copies a whole buffer. `u8[]` storage currently uses eight bytes per
element in the runtime; ASCII strings use one. No streaming API or allocation
failure recovery is provided. Callers needing a memory budget must bound
`src.length()` before conversion/decoding (and allow for expanded output). Contracts assert output sizes/error bounds and do
not claim static proofs of loop correctness.

## Reproducing validation

```
sh tools/bootstrap.sh
ORIN2=build/bootstrap/orin2 sh tools/test_std.sh tests/std/encoding_test.or
python3 tools/check_encoding.py
```

The seven test groups cover RFC 4648 vectors, both alphabets, all 256 input byte
values, every prefix/suffix of the 256-byte sequence (including nonzero storage
starts), strict malformed padding and lengths, exhaustive final-sextet pad bits,
and 3,000 deterministic arbitrary byte inputs with round trips and canonical
re-encoding checks. The validation tool additionally compares encoders with
Python's standard-library codecs on fixed inputs, runs the same test bodies on
C and LLVM with contracts on/off, and runs C with ASan/UBSan. Leak detection is
disabled for that sanitizer run; it is not a leak-freedom claim.

## Example

```typescript
import { fromString } from "std:bytes";
import { Unpadded, base64UrlEncode, base64UrlDecode, encodingErrorMessage } from "std:encoding";

function main(): void {
  const encoded = base64UrlEncode(fromString("hello"), Unpadded);
  console.log(encoded); // aGVsbG8
  const decoded = base64UrlDecode(fromString(encoded), Unpadded);
  if (decoded.isOk()) {
    console.log(decoded.unwrap().toRawString()); // hello
  } else {
    console.log(encodingErrorMessage(decoded.unwrapErr()));
  }
}
```

## Measured scaling (2026-10-15)

Apple M4 arm64, macOS, Apple clang 17 `-O2`, contracts off. The deterministic
benchmark constructs input byte `i` as `(i % 256) * 73 % 256`, then performs four
rounds of hex, padded standard Base64 and unpadded Base64URL encode/decode,
checking complete round trips. Wall times include process startup, construction,
conversion and equality checks; median of three runs after one warmup:

| Input bytes | C seconds | LLVM seconds | Checksum |
|---:|---:|---:|---:|
| 65,536 | 0.010569 | 0.011654 | 786,432 |
| 262,144 | 0.035950 | 0.037132 | 3,145,728 |
| 1,048,576 | 0.144742 | 0.152865 | 12,582,912 |

The largest size took about 4.0×/4.1× the middle-size time for 4× the input.
This is evidence consistent with linear construction, not a throughput promise
or a proof. Individual codecs, peak memory, streaming, input larger than 1 MiB,
other operating systems and contract-enabled performance were not benchmarked.
