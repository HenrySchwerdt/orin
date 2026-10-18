- **`std:net` completes ADR-0048 (errors are `Err`, internals in `std:net/internal`).** `std:net` is unstable, so there are no
  wrappers. `recv(s, maxBytes, timeout)` and `recvUntil(s, maxBytes, deadline)` return `Result<Bytes, NetError>` instead of
  `RecvResult` (`RecvData(b)` is `Ok(b)`; `RecvEof` is `Err(e)` with `e.kind == Closed`, `RecvTimeout` is `Err(Timeout)`,
  `RecvReset` is `Err(Reset)`, `RecvError(e)` is `Err(e)`, also `Cancelled` and `InvalidArgument` for `maxBytes` 0); the types
  `RecvResult` and the variants `RecvData`, `RecvEof`, `RecvTimeout`, `RecvReset`, `RecvError` are gone. The readers return
  `Result<Fill, NetError>`: `StreamReader.readSome` is `Result<Bytes, NetError>`, and `readExact`, `readExactUntil`, `readUntil`,
  `readDelimitedUntil` give `Ok(Filled(b))`, `Ok(FillClosed(b))` (the short read before the peer closed), `Ok(FillLimit)` or `Err`;
  `FillTimeout` is `Err(Timeout)` and `FillError(e)` is `Err(e)` (variants removed), so a failure is signalled one way
  everywhere in the module (ADR-0048 rule 3). New predicates `isClosed(e)` and `isCancelled(e)`; `isDenied`, `isTimeout` and
  `isReset` test `e.kind`. `Accepted` is `@Sealed` (its token is the private field `_token`; `peer` stays readable), as ADR-0048
  rule 4.3 asks for hidden fields. The wait clamp and the text scanners moved to the internal module `std:net/internal`
  (`library/std/net_internal.or`, not API); the doc comments of the module are signature-first. Callers (`examples/http_server.or`,
  `tests/net`, `tests/concurrency/cancel_storm.or`, `tests/next`, the mutation checks, `apitable`, `docs/std.md`) are updated.
