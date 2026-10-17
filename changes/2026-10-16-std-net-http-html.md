- **`std:net`, `std:http` and `std:html` follow ADR-0048 (migration steps 2, 3, 4, 5, 6).** Breaking where no deprecated
  wrapper is possible; `std:net` is unstable and changes without wrappers.
  `std:net`: `parsePeer(text)` returns `Result<Peer, NetError>` (no port-0 sentinel; `Err(InvalidPeer)` with the byte
  offset). `NetError` is `{ kind: NetErrorKind; code; offset }` with `NetErrorKind = Denied | Closed | Timeout | Reset |
  InvalidArgument | InvalidPeer | Os`; the `message` field is gone, use `netErrorMessage(e)`; `makeError(code)` is
  `netErrorFromCode(code)`. Every `timeoutMs: int` is `timeout: Duration` (`std:time`: pass `milliseconds(2000)` where you
  passed `2000`). `nowMillis(stream)` is `monotonicMillis(stream)`. `findFrom`, `recvWithin` and `recvIsError` are no longer
  exported (`findFrom` becomes `Bytes.indexOfBytes` with the bytes module; a private copy stays until then).
  `std:http`: `HttpReason` is `HttpErrorKind` and its `Bad*` variants are `Invalid*` (`BadHeaderName` and `BadHeaderValue`
  are `InvalidFieldName` and `InvalidFieldValue`); `HttpError` is `{ kind; offset }` (was `{ position; reason; message }`),
  its text is `httpErrorMessage(e)`, and `reasonName` / `reasonText` are `httpErrorKindName` / `httpErrorKindText`. The
  six-argument class `Limits` is the record `HttpLimits { maxStartLine, maxHeaderCount, maxHeaderLine, maxHeaderBytes,
  maxChunkLine, maxBody }` (`defaultLimits()` returns it, `isValidLimits(l)` checks it, the parsers trap on invalid limits);
  `forHead: bool` of the response parsers is `to: ResponseTo` (`ToHead | ToOther`). The twins of the trapping constructors
  are `Status.tryNew(code, reason)`, `Request.tryNew(RequestParts)`, `Response.tryNew(ResponseParts)` and `tryHeaders(names,
  values)`, with typed errors (`HttpError`, `HeaderError { kind }`) instead of `string`; `makeStatus`, `makeRequest`,
  `makeResponse` and `headersFromLists` stay one release as `@Deprecated` wrappers, as do `reasonName`, `reasonText`,
  `HttpReason` and `Headers.count()` (now `size()`, plus `isEmpty()`). `standardReason(code)` returns `Option<string>`.
  `requestProblem`, `responseProblem`, `allTokens` and `allFieldValues` are private; the other rule helpers stay exported
  but are marked internal (the loader has no `std:http/internal` yet). Doc comments are signature-first.
  `std:html`: `text` is `fromText`, `joinAll` is `renderAll`, `document` is `renderDocument`, `needsEscape` is
  `hasSpecialChars`; the old names stay one release as `@Deprecated` wrappers. `docs/std.md`, the MCP API table and the
  tests follow.
