# ADR-0033: L0 network primitives for `std:net`

Status: accepted (2026-10-14; implemented, with the amendment at the end). Amends the closed L0 list of spec 19 §2 (an ADR is required for
every new platform function). Related: ADR-0021 (primitive operations Bind / Accept / Connect /
StreamRead / StreamWrite, handle identity), ADR-0027 (Stage A: root grants as resource handles),
ADR-0030 (the trust boundary is L0 only), ADR-0025 (resources).

## Decision

### 1. New L0 functions (blocking, IPv4/IPv6 TCP first)

| Function | Operation (ADR-0021) | Handle checked |
|---|---|---|
| `orin_platform_tcp_listen(grant, addr, port, backlog, out_fd)` | Bind | a listen grant whose scope covers `addr:port` |
| `orin_platform_tcp_accept(listener, out_fd, out_peer)` | Accept | listener handle created by `tcp_listen` |
| `orin_platform_tcp_connect(grant, host_addr, port, timeout_ms, out_fd)` | Connect | a connect grant whose scope covers the remote endpoint |
| `orin_platform_stream_recv(stream, buf, cap, timeout_ms, out_len)` | StreamRead | stream handle from accept/connect |
| `orin_platform_stream_send(stream, data, len, out_sent)` | StreamWrite | same |
| `orin_platform_net_close(handle)` | — | any network handle; idempotent |
| `orin_platform_dns_resolve(grant, name, out_addrs)` | Connect (lookup) | a connect grant whose scope covers `name` |

UDP comes in a later amendment.

**Rules:**
- every function takes a handle; there is no ambient socket;
- every function validates the handle's identity and scope at run time, and refuses with
  `ORIN_PLATFORM_EPERM` before any syscall;
- every function has an ACSL contract (`requires`/`ensures`/`assigns`) in `orin_platform.h`,
  like the file functions;
- `recv` never writes past `cap`, and `send` reports partial writes; both are CBMC-checked for
  buffer bounds;
- timeouts are mandatory parameters, with no infinite default.

### 2. Grants (Orin side, `std:host` / `std:net`)

- `host.net()` gives the root network grant (ADR-0027). The root grant can only be narrowed:
  - `listenGrant(addr, port)`
  - `connectGrant(hostPattern, portRange)`
- Listener and stream handles are resources: they cannot be copied, are closed on scope exit, and
  cannot escape through closures or fields (ADR-0025).
- OSIG: every call of a network primitive is a `PERFORMS_IO` edge with direction (IN for
  recv/accept, OUT for send/connect) and the handle's identity, as in ADR-0021.

### 3. Budget and assurance

- About 220 lines of C and 100 lines of header (mostly contracts).
- L0 stays under its budget of 1,000 CODE lines (contracts and comments excluded: the budget limits trusted code, not
  its specification; ADR-0030 §1). `tools/verify_platform.sh` checks this and prints code lines and total lines.
- Assurance: the buffer and bounds properties are CBMC-verified. Socket behaviour itself is
  OS-trusted and tested. A loopback test suite runs in CI on Linux and macOS.

## Consequences

`std:net` and `std:http` (ADR-0030 §3) can be written in safe Orin on top of this. The HTTP parser
does not depend on it: it is a pure function over `std:bytes` and can be built first.

## Amendment (2026-10-14): what the implementation needed

The functions of §1 keep their roles. Differences and additions (all in `platform/orin_platform.{h,c}`):

- **Handles are records.** `grant`, `listener` and `stream` are `orin_platform_net` records owned by the caller (the
  runtime keeps the table and the generation counter): magic, kind, live fd, a `deny` flag set from `ORIN_DENY=net`, and for a
  grant two scopes (listen, connect). Every function checks magic, kind, liveness and `deny`, then the scope, and refuses
  with `ORIN_PLATFORM_EPERM` before any system call. Replaces "out_fd".
- **Tagged recv result.** `stream_recv` returns `0` (data, `1..cap` bytes) or `NET_EOF` / `NET_TIMEOUT` / `NET_RESET`
  or an errno code. Why: `std:http` must tell an orderly close from a timeout and from a reset (docs/std.md).
- **Mandatory timeouts everywhere.** `accept`, `recv`, `send` and `connect` take `timeout_ms` in `0..3,600,000`, otherwise
  `EINVAL`. Why: no infinite wait; `send` needs it as much as `recv` (a peer that never reads).
- **`net_shutdown(stream, how)`.** Why: a graceful close is `shutdown(write)`, a bounded drain, then close; a bare close
  can RST and discard the response that was just sent.
- **`net_narrow(parent, what, host, lo, hi, out)`.** Why: the decision "the narrowed scope is inside the parent's"
  is the security-critical part of the model and belongs at the checked boundary with a CBMC harness. A request outside
  the parent's scope yields a grant that reaches nothing (like `useUnder`).
- **`monotonic_millis()`.** Why: whole-request deadlines (a slowloris client sends a byte per `timeout - 1` ms). The wall
  clock can jump; the runtime exposes it only through a live net handle.
- **Socket options as parameters.** `listen(opt & 1)`: `SO_REUSEADDR`; `accept` / `connect (opt & 1)`: `TCP_NODELAY`.
  Sockets are non-blocking inside and every wait is a `poll` with the caller's timeout; close-on-exec; no `SIGPIPE`.
- **Peer address as a value.** `accept` writes the numeric peer address (text) and port.
- **`dns_resolve`** returns the numeric addresses as `\n`-separated text (no structure arrays across the boundary).
- **Bulk buffer path.** L0 works on a plain byte buffer (`recv` into it, `send` from it). The runtime copies between
  that buffer and an Orin `u8[]` in one loop in C (`netRecv` / `netSend`); there is never one string per byte.

Honest limits found:
- **The DNS lookup is not bounded by the timeout.** A name given to `connect`, and `dns_resolve`, call the OS resolver
  (`getaddrinfo`) first, which has its own (long) timeout. A servers that only listens never resolves. Bounding it would
  need a thread or `getaddrinfo_a` (not portable to macOS); documented, not fixed.
- **DNS rebinding is not covered.** A connect scope is checked against the host text the program supplies; the addresses
  the resolver then returns are trusted. Scope an IP literal where this matters.
- **Host patterns match program-supplied text** (exact, `*`, `*.suffix`; ASCII case-insensitive). `example.com.` (trailing
  dot) and alternative spellings of an address do not match; this fails closed.
- Listening takes a numeric address only (no DNS); IPv4 and IPv6; UDP is still a later amendment.
- Not enforced: bandwidth, connection count, the OS's own backlog and port rules, TOCTOU between scope check and use on a
  handle table that a hostile native library could write.
