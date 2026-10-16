- **std:collections, graph, bytes, encoding, utf8, seq, text and the array/map/math preludes follow ADR-0048 (collection vocabulary, codecs, error shape).**
  Renames keep the old name for one release as an `@Deprecated` wrapper (warning W0440): `SortedMap`/`SortedStringMap`
  `put` -> `set`, `keyArray`/`valueArray` -> `keys`/`values` (new: `entries`, `first`, `last`), `PQEntry` -> `PqEntry`,
  `Graph.contains` -> `has` (new `isEmpty`), `ByteBuilder.reserved` -> `capacity` (new `isEmpty`), `ByteReader.rest` -> `takeRest`,
  `appendU16be/le`, `appendU32be/le`, `readU16be/le`, `readU32be/le` -> `...U16Be/Le`, `...U32Be/Le`,
  `emptyBytes`/`bytesFromArray`/`bytesFromInts`/`bytesFromString` -> `empty`/`fromArray`/`fromInts`/`fromString` (use
  `import * as bytes`), `utf8Len` -> `encodedLength`, `checkUtf8` -> `validate`, `isValidUtf8` -> `isValid`,
  `validateString` -> `Utf8String.tryFrom`, `readErrorMessage`/`ReadError` -> `bytesErrorMessage`/`BytesError`.
  New: `Bytes.includes`, `Bytes.indexOfBytes(needle, begin)`, `std:encoding.hexDecodeText`/`base64DecodeText`/`base64UrlDecodeText`
  (string overloads of the decoders). **Breaking, no wrapper possible:** the `base64*` functions take `Padding = Padded |
  Unpadded` instead of a `bool`; the error records `EncodingError`, `Utf8Error` and `BytesError` use `offset` instead of
  `position` (and `Utf8Error`/`EncodingError` put `kind` first); `GraphError` is now `{ kind: GraphErrorKind }`
  (match on `e.kind`); `utf8.validate(bytes)` is now `utf8.decode(bytes)` and the name `validate` checks a string
  (`Result<void, Utf8Error>`); `bytesFromHex` is deprecated in favour of `encoding.hexDecodeText` (a `Result`; std:bytes
  cannot import std:encoding, so it is no thin wrapper). The prelude hooks `indexOfStr`/`includesStr`/`hashStr`/`eqStr`
  are now `...String` (internal). Public doc comments are signature-first with errors and cost; `compiler/mcp/apitable.or`
  lists the new `std:encoding` and `std:graph` signatures.
